//! SIGWINCH delivered through a pipe, so that a resize arriving while the
//! event loop is busy still wakes its next poll. A flag checked before
//! polling would miss a signal that lands between the check and the poll.

use std::os::fd::RawFd;
use std::sync::atomic::{AtomicI32, Ordering};

static WRITE_END: AtomicI32 = AtomicI32::new(-1);

extern "C" fn on_sigwinch(_: libc::c_int) {
    let fd = WRITE_END.load(Ordering::Relaxed);
    if fd < 0 {
        return;
    }
    unsafe {
        let saved = *libc::__error();
        let byte = 1u8;
        libc::write(fd, (&raw const byte).cast(), 1);
        *libc::__error() = saved;
    }
}

/// Install the SIGWINCH handler and return the pipe's read end, which
/// becomes readable after each SIGWINCH.
pub fn install() -> std::io::Result<RawFd> {
    let mut fds = [0; 2];
    if unsafe { libc::pipe(fds.as_mut_ptr()) } != 0 {
        return Err(std::io::Error::last_os_error());
    }
    for fd in fds {
        unsafe {
            libc::fcntl(fd, libc::F_SETFL, libc::fcntl(fd, libc::F_GETFL) | libc::O_NONBLOCK);
            libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC);
        }
    }
    WRITE_END.store(fds[1], Ordering::Relaxed);
    unsafe {
        let mut action: libc::sigaction = std::mem::zeroed();
        action.sa_sigaction = on_sigwinch as extern "C" fn(libc::c_int) as libc::sighandler_t;
        libc::sigemptyset(&mut action.sa_mask);
        action.sa_flags = 0;
        libc::sigaction(libc::SIGWINCH, &action, std::ptr::null_mut());
    }
    Ok(fds[0])
}

/// Whether a SIGWINCH arrived since the last call. Empties the pipe.
pub fn take(read_end: RawFd) -> bool {
    let mut buf = [0u8; 64];
    let mut any = false;
    while unsafe { libc::read(read_end, buf.as_mut_ptr().cast(), buf.len()) } > 0 {
        any = true;
    }
    any
}
