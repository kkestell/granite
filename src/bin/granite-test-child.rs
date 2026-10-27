//! Scripted child for tests/live.rs; not a user-facing granite command.
use std::io::Write;
use std::sync::atomic::{AtomicBool, Ordering};

fn write(data: impl AsRef<[u8]>) {
    granite::mux::write_all(libc::STDOUT_FILENO, data.as_ref());
}
fn sleep(ms: i32) {
    unsafe {
        libc::poll(std::ptr::null_mut(), 0, ms);
    }
}
fn raw_mode() {
    unsafe {
        let mut t = std::mem::zeroed();
        if libc::tcgetattr(0, &mut t) == 0 {
            libc::cfmakeraw(&mut t);
            libc::tcsetattr(0, libc::TCSANOW, &t);
        }
    }
}
fn read_byte(timeout: i32) -> Option<u8> {
    let mut fd = libc::pollfd {
        fd: 0,
        events: libc::POLLIN,
        revents: 0,
    };
    let mut b = 0;
    unsafe {
        if libc::poll(&mut fd, 1, timeout) <= 0 {
            return None;
        }
        (libc::read(0, (&mut b as *mut u8).cast(), 1) == 1).then_some(b)
    }
}
static WINCH: AtomicBool = AtomicBool::new(false);
extern "C" fn on_winch(_: libc::c_int) {
    WINCH.store(true, Ordering::Relaxed);
}
fn print_size() {
    let mut ws: libc::winsize = unsafe { std::mem::zeroed() };
    unsafe {
        libc::ioctl(1, libc::TIOCGWINSZ, &mut ws);
    }
    write(format!("\x1b[H\x1b[2Ksize {}x{}", ws.ws_col, ws.ws_row));
}
const MODES: &[u8] = b"\x1b[?1h\x1b[?1000h\x1b[?1006h\x1b[?2004h\x1b[?1004h\x1b=\x1b[>1u\x1b[5 q";
fn run(args: &[String]) -> u8 {
    match args.get(1).map(String::as_str) {
        Some("exit") => {
            write(&args[3]);
            args[2].parse().unwrap()
        }
        Some("kill") => {
            write("killed");
            unsafe {
                libc::kill(libc::getpid(), libc::SIGTERM);
            }
            sleep(1000);
            1
        }
        Some("hold") => {
            raw_mode();
            write("before");
            sleep(200);
            write(b"\x1b[?2026h\x1b[2;1Hheld-1");
            sleep(300);
            write(b" held-2\x1b[?2026l");
            read_byte(10_000);
            0
        }
        Some("hold-forever") => {
            raw_mode();
            write("start");
            sleep(100);
            write(b"\x1b[?2026h\x1b[2;1Hstuck");
            read_byte(10_000);
            0
        }
        Some("burst") => {
            raw_mode();
            for i in 0..args[2].parse::<u32>().unwrap() {
                write(format!("line {i}\r\n"));
            }
            write("done");
            read_byte(10_000);
            0
        }
        Some("size") => {
            raw_mode();
            unsafe {
                let mut sa: libc::sigaction = std::mem::zeroed();
                sa.sa_sigaction = on_winch as *const () as usize;
                libc::sigemptyset(&mut sa.sa_mask);
                libc::sigaction(libc::SIGWINCH, &sa, std::ptr::null_mut());
            }
            print_size();
            loop {
                if WINCH.swap(false, Ordering::Relaxed) {
                    print_size();
                }
                if read_byte(50) == Some(b'q') {
                    return 0;
                }
            }
        }
        Some("modes") => {
            raw_mode();
            write(MODES);
            write("ready");
            while let Some(b) = read_byte(10_000) {
                if b == b'q' {
                    return 0;
                }
                write(format!("\r\ngot {b}"));
            }
            1
        }
        Some("input") => {
            raw_mode();
            let label = &args[2];
            let status = args[4].parse().unwrap();
            let mut file = args.get(5).map(|p| std::fs::File::create(p).unwrap());
            if args[3] == "modes" {
                write(MODES);
            }
            write(format!("\x1b]0;{label}\x07{label} ready"));
            while let Some(b) = read_byte(10_000) {
                if let Some(file) = &mut file {
                    let _ = file.write_all(&[b]);
                }
                if b == b'q' {
                    return status;
                }
                write(format!("\r\n{label} got {b}"));
            }
            1
        }
        Some("query") => {
            raw_mode();
            // DA1 goes last: its reply marks the end of the replies.
            write(
                b"\x1b[3;5H\x1b]10;?\x1b\\\x1b]11;?\x07\x1b]4;1;?\x1b\\\x1b[6n\x1b[?2027$p\x1b[c",
            );
            let mut replies = Vec::new();
            while replies.len() < 1024 {
                let Some(b) = read_byte(2000) else {
                    break;
                };
                replies.push(b);
                if b == b'c' && replies.windows(3).any(|s| s == b"\x1b[?") {
                    break;
                }
            }
            if std::fs::write(&args[2], replies).is_err() {
                return 1;
            }
            write("queried");
            0
        }
        _ => 2,
    }
}
fn main() -> std::process::ExitCode {
    run(&std::env::args().collect::<Vec<_>>()).into()
}
