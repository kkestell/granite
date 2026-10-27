//! granite-record: runs a program in a pty and passes its input and output
//! through unchanged, while logging the output to a file with each read()
//! as its own record (see recording.rs). Recordings in zig/test/recordings
//! are replayed by the round-trip test.
//!
//!   granite-record zig/test/recordings/claude.rec claude

use std::ffi::CString;
use std::os::unix::ffi::OsStrExt as _;
use std::process::ExitCode;
use std::sync::atomic::{AtomicBool, Ordering};

use granite::mux::{Winsize, write_all};
use granite::recording::{self, Record, Size};

static WINCH_PENDING: AtomicBool = AtomicBool::new(false);

extern "C" fn on_sigwinch(_: libc::c_int) {
    WINCH_PENDING.store(true, Ordering::Relaxed);
}

fn host_size() -> Winsize {
    let mut ws = Winsize { ws_row: 0, ws_col: 0, ws_xpixel: 0, ws_ypixel: 0 };
    unsafe { libc::ioctl(libc::STDOUT_FILENO, libc::TIOCGWINSZ, &mut ws) };
    ws
}

fn log(fd: libc::c_int, record: Record) {
    let mut buf = Vec::new();
    recording::write(&mut buf, record);
    write_all(fd, &buf);
}

fn main() -> ExitCode {
    let args: Vec<CString> = std::env::args_os()
        .map(|a| CString::new(a.as_bytes()).unwrap_or_default())
        .collect();
    if args.len() < 3 {
        eprintln!("usage: granite-record <file> <command> [args...]");
        return ExitCode::from(2);
    }
    if unsafe { libc::isatty(libc::STDIN_FILENO) == 0 || libc::isatty(libc::STDOUT_FILENO) == 0 } {
        eprintln!("granite-record: stdin and stdout must be a terminal");
        return ExitCode::from(1);
    }
    let mut cmd: Vec<*const libc::c_char> = args[2..].iter().map(|a| a.as_ptr()).collect();
    cmd.push(std::ptr::null());

    let file = unsafe {
        libc::open(args[1].as_ptr(), libc::O_WRONLY | libc::O_CREAT | libc::O_TRUNC, 0o644 as libc::c_uint)
    };
    if file < 0 {
        unsafe { libc::perror(args[1].as_ptr()) };
        return ExitCode::from(1);
    }
    let status = record(file, &cmd);
    unsafe { libc::close(file) };
    status
}

fn record(file: libc::c_int, cmd: &[*const libc::c_char]) -> ExitCode {
    let mut ws = host_size();
    write_all(file, recording::MAGIC);
    log(file, Record::Size(Size { cols: ws.ws_col, rows: ws.ws_row }));

    let mut pty: libc::c_int = -1;
    let pid = unsafe { libc::forkpty(&mut pty, std::ptr::null_mut(), std::ptr::null_mut(), &mut ws) };
    if pid < 0 {
        unsafe { libc::perror(c"forkpty".as_ptr()) };
        return ExitCode::from(1);
    }
    if pid == 0 {
        unsafe {
            libc::execvp(cmd[0], cmd.as_ptr());
            libc::perror(cmd[0]);
            libc::_exit(127);
        }
    }

    let mut orig = std::mem::MaybeUninit::<libc::termios>::uninit();
    if unsafe { libc::tcgetattr(libc::STDIN_FILENO, orig.as_mut_ptr()) } != 0 {
        unsafe { libc::perror(c"tcgetattr".as_ptr()) };
        return ExitCode::from(1);
    }
    let orig = unsafe { orig.assume_init() };
    let mut raw = orig;
    unsafe {
        libc::cfmakeraw(&mut raw);
        libc::tcsetattr(libc::STDIN_FILENO, libc::TCSAFLUSH, &raw);

        let mut action: libc::sigaction = std::mem::zeroed();
        action.sa_sigaction = on_sigwinch as extern "C" fn(libc::c_int) as libc::sighandler_t;
        libc::sigemptyset(&mut action.sa_mask);
        action.sa_flags = 0;
        libc::sigaction(libc::SIGWINCH, &action, std::ptr::null_mut());
    }

    let mut buf = vec![0u8; 65536];
    loop {
        if WINCH_PENDING.swap(false, Ordering::Relaxed) {
            let new = host_size();
            unsafe { libc::ioctl(pty, libc::TIOCSWINSZ, &new) };
            log(file, Record::Size(Size { cols: new.ws_col, rows: new.ws_row }));
        }

        let mut fds = [
            libc::pollfd { fd: libc::STDIN_FILENO, events: libc::POLLIN, revents: 0 },
            libc::pollfd { fd: pty, events: libc::POLLIN, revents: 0 },
        ];
        if unsafe { libc::poll(fds.as_mut_ptr(), 2, -1) } < 0 {
            if std::io::Error::last_os_error().raw_os_error() == Some(libc::EINTR) {
                continue;
            }
            break;
        }

        if fds[0].revents & libc::POLLIN != 0 {
            let n = unsafe { libc::read(libc::STDIN_FILENO, buf.as_mut_ptr().cast(), buf.len()) };
            if n <= 0 {
                break;
            }
            write_all(pty, &buf[..n as usize]);
        }

        if fds[1].revents & (libc::POLLIN | libc::POLLHUP) != 0 {
            let n = unsafe { libc::read(pty, buf.as_mut_ptr().cast(), buf.len()) };
            if n <= 0 {
                break;
            }
            write_all(libc::STDOUT_FILENO, &buf[..n as usize]);
            log(file, Record::Output(&buf[..n as usize]));
        }
    }
    unsafe { libc::tcsetattr(libc::STDIN_FILENO, libc::TCSAFLUSH, &orig) };

    let mut status: libc::c_int = 0;
    unsafe { libc::waitpid(pid, &mut status, 0) };
    if libc::WIFSIGNALED(status) {
        return ExitCode::from(128u8.wrapping_add(libc::WTERMSIG(status) as u8));
    }
    ExitCode::from(libc::WEXITSTATUS(status) as u8)
}
