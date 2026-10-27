//! A minimal terminal multiplexer with one to three panes, no detach.
//!
//! With no arguments, runs claude on the left, codex on the top right, and
//! opencode on the bottom right. Ctrl-] moves focus to the next pane. A
//! command runs alone with unchanged input and no chrome; separate two or
//! three commands with a lone :: to split them.
//! Each program has its own pty and Ghostty terminal. The focused pane's
//! input modes are mirrored onto the host, and only dirty rows redraw.
//!
//!   granite
//!   granite htop
//!   granite claude :: codex
//!   granite claude :: codex :: opencode

use std::error::Error;
use std::ffi::{CString, OsString};
use std::fs::{File, OpenOptions};
use std::io::Write as _;
use std::os::unix::ffi::OsStrExt as _;
use std::path::Path;
use std::process::ExitCode;
use std::sync::atomic::{AtomicBool, Ordering};

use granite::mux::{self, HOLD_TIMEOUT_MS, Mux, Winsize, now_ms, read, write_all};
use libghostty_vt::log::{Level, Logger};

const FRAME_MS: i64 = 16;
const HOST_REPLY_TIMEOUT_MS: i64 = 1000;

static WINCH_PENDING: AtomicBool = AtomicBool::new(false);

extern "C" fn on_sigwinch(_: libc::c_int) {
    WINCH_PENDING.store(true, Ordering::Relaxed);
}

fn flush(m: &mut Mux) {
    write_all(libc::STDOUT_FILENO, &m.take_output());
}

fn errno() -> i32 {
    std::io::Error::last_os_error().raw_os_error().unwrap_or(0)
}

//------------------------------------------------------------------------
// Logging

/// Ghostty logs through libghostty's log hook, and stderr is the host
/// terminal, so logs would land on the screen. They go to the file named by
/// GRANITE_LOG, or nowhere.
struct FileLogger(File);

impl Logger for FileLogger {
    fn log(&self, level: Level, scope: &str, message: &str) {
        let level = match level {
            Level::Error => "error",
            Level::Warning => "warning",
            Level::Info => "info",
            _ => "debug",
        };
        let scope = if scope.is_empty() { "default" } else { scope };
        let _ = (&self.0).write_all(format!("{level}({scope}): {message}\n").as_bytes());
    }
}

fn setup_logging() {
    let Some(path) = std::env::var_os("GRANITE_LOG") else { return };
    let Ok(file) = OpenOptions::new().create(true).append(true).open(path) else { return };
    // SAFETY: No other thread uses libghostty.
    let _ = unsafe { libghostty_vt::set_logger(Some(Box::new(FileLogger(file)))) };
}

//------------------------------------------------------------------------
// Host terminal setup

fn restore_host(m: &mut Mux, orig: &libc::termios) {
    m.write_restore();
    flush(m);
    unsafe { libc::tcsetattr(libc::STDIN_FILENO, libc::TCSAFLUSH, orig) };
}

fn setup_host(orig: &libc::termios) {
    let mut raw = *orig;
    unsafe {
        libc::cfmakeraw(&mut raw);
        libc::tcsetattr(libc::STDIN_FILENO, libc::TCSAFLUSH, &raw);
    }
    write_all(libc::STDOUT_FILENO, b"\x1b[?1049h\x1b[2J");
}

/// Ask the host for its colors and grapheme clustering mode; see
/// `mux::use_host_replies_for`.
fn query_host(m: &mut Mux) -> Result<(), Box<dyn Error>> {
    write_all(libc::STDOUT_FILENO, &mux::host_queries());

    let mut buf = [0u8; 4096];
    let mut len = 0;
    let deadline = now_ms() + HOST_REPLY_TIMEOUT_MS;
    while len < buf.len() && !mux::host_replies_done(&buf[..len]) {
        let left = deadline - now_ms();
        if left <= 0 {
            break;
        }
        let mut fds = [libc::pollfd { fd: libc::STDIN_FILENO, events: libc::POLLIN, revents: 0 }];
        let ready = unsafe { libc::poll(fds.as_mut_ptr(), 1, left as libc::c_int) };
        if ready < 0 {
            if errno() == libc::EINTR {
                continue;
            }
            return Err(std::io::Error::last_os_error().into());
        }
        if ready == 0 {
            break;
        }
        let n = read(libc::STDIN_FILENO, &mut buf[len..]);
        if n <= 0 {
            break;
        }
        len += n as usize;
    }
    m.use_host_replies(&buf[..len])?;
    Ok(())
}

fn host_size() -> Winsize {
    let mut ws = Winsize { ws_row: 0, ws_col: 0, ws_xpixel: 0, ws_ypixel: 0 };
    unsafe { libc::ioctl(libc::STDOUT_FILENO, libc::TIOCGWINSZ, &mut ws) };
    ws
}

fn resize(m: &mut Mux) -> Result<(), Box<dyn Error>> {
    m.resize(host_size())?;
    for p in &m.panes {
        if let Some(pty) = p.pty() {
            let ws = p.ws();
            unsafe { libc::ioctl(pty, libc::TIOCSWINSZ, &ws) };
        }
    }
    Ok(())
}

//------------------------------------------------------------------------

fn main() -> ExitCode {
    match run() {
        Ok(status) => ExitCode::from(status),
        Err(e) => {
            eprintln!("granite: {e}");
            ExitCode::FAILURE
        }
    }
}

fn run() -> Result<u8, Box<dyn Error>> {
    let args: Vec<OsString> = std::env::args_os().collect();
    let mut commands: Vec<Vec<OsString>> =
        ["claude", "codex", "opencode"].iter().map(|c| vec![OsString::from(c)]).collect();
    if args.len() > 1 {
        commands.clear();
        let mut start = 1;
        for (i, arg) in args.iter().enumerate().skip(1) {
            if arg != "::" {
                continue;
            }
            if commands.len() == 2 || i == start || i + 1 == args.len() {
                eprintln!("granite: expected cmd args... [:: cmd args... [:: cmd args...]]");
                return Ok(2);
            }
            commands.push(args[start..i].to_vec());
            start = i + 1;
        }
        commands.push(args[start..].to_vec());
    }

    if unsafe { libc::isatty(libc::STDIN_FILENO) == 0 || libc::isatty(libc::STDOUT_FILENO) == 0 } {
        eprintln!("granite: stdin and stdout must be a terminal");
        return Ok(1);
    }
    setup_logging();

    let argvs: Vec<Vec<CString>> = commands
        .iter()
        .map(|cmd| cmd.iter().map(|a| CString::new(a.as_bytes())).collect())
        .collect::<Result<_, _>>()?;
    let labels: Vec<String> = commands
        .iter()
        .map(|cmd| {
            let path = Path::new(&cmd[0]);
            path.file_name().unwrap_or(path.as_os_str()).to_string_lossy().into_owned()
        })
        .collect();
    let labels: Vec<&str> = labels.iter().map(String::as_str).collect();
    let mut m = Mux::new(host_size(), &labels)?;

    let result = spawn_and_run(&mut m, &argvs);
    if result.is_err() {
        for p in &m.panes {
            if let (Some(pid), None) = (p.pid, p.status) {
                unsafe {
                    libc::kill(pid, libc::SIGTERM);
                    libc::waitpid(pid, std::ptr::null_mut(), 0);
                }
            }
        }
    }
    for p in &m.panes {
        if let Some(pty) = p.pty() {
            unsafe { libc::close(pty) };
        }
    }
    result
}

fn spawn_and_run(m: &mut Mux, argvs: &[Vec<CString>]) -> Result<u8, Box<dyn Error>> {
    let term_name = c"TERM";
    let term_value = c"xterm-256color";
    for (i, argv) in argvs.iter().enumerate() {
        let mut ptrs: Vec<*const libc::c_char> = argv.iter().map(|a| a.as_ptr()).collect();
        ptrs.push(std::ptr::null());
        let others: Vec<i32> = m.panes.iter().filter_map(|p| p.pty()).collect();
        let mut ws = m.panes[i].ws();
        let mut pty: libc::c_int = -1;
        let pid = unsafe {
            libc::forkpty(&mut pty, std::ptr::null_mut(), std::ptr::null_mut(), &mut ws)
        };
        if pid < 0 {
            return Err("forkpty failed".into());
        }
        if pid == 0 {
            unsafe {
                // Later children must not retain earlier children's masters.
                for fd in others {
                    libc::close(fd);
                }
                libc::setenv(term_name.as_ptr(), term_value.as_ptr(), 1);
                libc::execvp(ptrs[0], ptrs.as_ptr());
                libc::perror(ptrs[0]);
                libc::_exit(127);
            }
        }
        m.panes[i].set_pty(Some(pty));
        m.panes[i].pid = Some(pid);
    }
    resize(m)?;

    let mut orig = std::mem::MaybeUninit::<libc::termios>::uninit();
    if unsafe { libc::tcgetattr(libc::STDIN_FILENO, orig.as_mut_ptr()) } != 0 {
        return Err(std::io::Error::last_os_error().into());
    }
    let orig = unsafe { orig.assume_init() };
    setup_host(&orig);
    let result = event_loop(m);
    restore_host(m, &orig);
    result
}

fn event_loop(m: &mut Mux) -> Result<u8, Box<dyn Error>> {
    query_host(m)?;

    unsafe {
        let mut action: libc::sigaction = std::mem::zeroed();
        action.sa_sigaction = on_sigwinch as extern "C" fn(libc::c_int) as libc::sighandler_t;
        libc::sigemptyset(&mut action.sa_mask);
        action.sa_flags = 0;
        libc::sigaction(libc::SIGWINCH, &action, std::ptr::null_mut());
    }

    let count = m.panes.len();
    let mut last_render: i64 = 0;
    let mut buf = vec![0u8; 65536];
    let mut live = count;
    while live > 0 {
        if WINCH_PENDING.swap(false, Ordering::Relaxed) {
            resize(m)?;
        }
        let now = now_ms();
        m.expire_holds(now)?;
        if m.needs_render() && now - last_render >= FRAME_MS {
            m.render()?;
            last_render = now;
        }
        if !m.output().is_empty() {
            flush(m);
        }

        let mut timeout: i64 = -1;
        if m.needs_render() {
            timeout = (FRAME_MS - (now - last_render)).max(0);
        }
        for p in &m.panes {
            if p.held() {
                let left = (HOLD_TIMEOUT_MS - (now - p.held_since())).max(0);
                timeout = if timeout < 0 { left } else { timeout.min(left) };
            }
        }
        let mut fds = vec![libc::pollfd { fd: libc::STDIN_FILENO, events: libc::POLLIN, revents: 0 }];
        for p in &m.panes {
            fds.push(libc::pollfd { fd: p.pty().unwrap_or(-1), events: libc::POLLIN, revents: 0 });
        }
        // Raw poll lets SIGWINCH interrupt the wait.
        if unsafe { libc::poll(fds.as_mut_ptr(), fds.len() as libc::nfds_t, timeout as libc::c_int) } < 0 {
            if errno() == libc::EINTR {
                continue;
            }
            break;
        }
        if fds[0].revents & libc::POLLIN != 0 {
            let n = read(libc::STDIN_FILENO, &mut buf);
            if n <= 0 {
                break;
            }
            m.input(&buf[..n as usize]);
        }
        for (i, fd) in fds[1..].iter().enumerate() {
            if fd.revents & (libc::POLLIN | libc::POLLHUP) == 0 {
                continue;
            }
            let n = read(fd.fd, &mut buf);
            if n > 0 {
                m.panes[i].feed(&buf[..n as usize]);
                continue;
            }
            let p = &mut m.panes[i];
            let mut status: libc::c_int = 0;
            unsafe { libc::waitpid(p.pid.unwrap(), &mut status, 0) };
            p.status = Some(exit_status(status));
            unsafe { libc::close(fd.fd) };
            p.set_pty(None);
            p.set_held(false);
            live -= 1;
            if count > 1 {
                m.chrome_dirty = true;
            }
            if count > 1 && m.focus() == i {
                m.focus_next();
            }
        }
    }
    // Preserve a short-lived child's final output, including held output.
    for p in &m.panes {
        p.set_held(false);
    }
    if m.needs_render() {
        m.render()?;
    }
    flush(m);
    for p in &mut m.panes {
        if p.status.is_none() {
            let mut status: libc::c_int = 0;
            unsafe { libc::waitpid(p.pid.unwrap(), &mut status, 0) };
            p.status = Some(exit_status(status));
        }
    }
    Ok(m.panes.iter().filter_map(|p| p.status).find(|&s| s != 0).unwrap_or(0))
}

fn exit_status(status: libc::c_int) -> u8 {
    if libc::WIFSIGNALED(status) {
        return 128u8.wrapping_add(libc::WTERMSIG(status) as u8);
    }
    libc::WEXITSTATUS(status) as u8
}
