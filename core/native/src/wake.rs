//! The wake socket: how worker threads tell Neovim's main loop that results
//! are ready.
//!
//! A Unix socket pair; the caller watches the read end (a luv pipe in
//! Neovim) and the library writes one byte per batch. A pending flag
//! coalesces: once a byte is written, further signals write nothing until
//! the caller's next poll resets the flag, so a burst of completions costs
//! one wake. Poll resets the flag before it collects, so a completion pushed
//! after a collect always writes a new byte (no lost wake).
//!
//! SIGPIPE can never reach the host: the write end is nonblocking, has
//! `SO_NOSIGPIPE` on Apple platforms and writes with `MSG_NOSIGNAL` on
//! Linux (and the other Unixes), and every write happens under the lock
//! that [`Wake::close`] takes, so no write ever follows a close.

use std::io;
use std::os::fd::OwnedFd;
use std::os::unix::net::UnixStream;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Mutex, MutexGuard};

/// The write side of the wake socket.
pub struct Wake {
    tx: Mutex<Option<UnixStream>>,
    pending: AtomicBool,
    writes: AtomicU64,
}

/// Lock, recovering from poisoning: nothing here may panic outside a guard.
fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

impl Wake {
    /// A new wake socket: the [`Wake`] (write end) and the read end for the
    /// caller. Both ends are close-on-exec.
    pub fn new() -> io::Result<(Wake, OwnedFd)> {
        let (rx, tx) = UnixStream::pair()?;
        tx.set_nonblocking(true)?;
        #[cfg(target_vendor = "apple")]
        {
            use std::os::fd::AsRawFd;
            let one: libc::c_int = 1;
            // SAFETY: a valid socket fd and a c_int option value of the right size.
            let rc = unsafe {
                libc::setsockopt(
                    tx.as_raw_fd(),
                    libc::SOL_SOCKET,
                    libc::SO_NOSIGPIPE,
                    &one as *const libc::c_int as *const libc::c_void,
                    std::mem::size_of::<libc::c_int>() as libc::socklen_t,
                )
            };
            if rc != 0 {
                return Err(io::Error::last_os_error());
            }
        }
        let wake = Wake {
            tx: Mutex::new(Some(tx)),
            pending: AtomicBool::new(false),
            writes: AtomicU64::new(0),
        };
        Ok((wake, OwnedFd::from(rx)))
    }

    /// Tell the caller results are ready: one byte, unless one is already
    /// pending or the socket is closed. Never blocks, never fails.
    pub fn signal(&self) {
        if self.pending.swap(true, Ordering::SeqCst) {
            return;
        }
        let g = lock(&self.tx);
        if let Some(s) = g.as_ref() {
            match write_byte(s) {
                Ok(()) => {
                    self.writes.fetch_add(1, Ordering::Relaxed);
                }
                // A full buffer holds unread bytes, so a wake is on its way;
                // a broken pipe means the caller closed its end and wants no
                // more wakes. Either way there is nothing to do.
                Err(e)
                    if e.kind() == io::ErrorKind::WouldBlock
                        || e.kind() == io::ErrorKind::BrokenPipe => {}
                // Anything else wrote nothing and no byte is waiting: re-arm
                // so the next completion tries again.
                Err(_) => self.pending.store(false, Ordering::SeqCst),
            }
        }
    }

    /// Re-arm: the next [`signal`](Wake::signal) writes a byte again. Called
    /// by poll before it collects.
    pub fn reset(&self) {
        self.pending.store(false, Ordering::SeqCst);
    }

    /// Close the write end. Later signals do nothing. The caller's read end
    /// sees end of file once it has read what was written.
    pub fn close(&self) {
        *lock(&self.tx) = None;
    }

    /// Bytes written so far (tests and diagnostics).
    pub fn writes(&self) -> u64 {
        self.writes.load(Ordering::Relaxed)
    }
}

/// Write one byte without raising SIGPIPE (`MSG_NOSIGNAL`: Linux and every
/// other Unix that is not Apple's). Retries when interrupted by a signal.
#[cfg(not(target_vendor = "apple"))]
fn write_byte(s: &UnixStream) -> io::Result<()> {
    use std::os::fd::AsRawFd;
    let b = [1u8];
    loop {
        // SAFETY: a valid socket fd and a 1-byte buffer that outlives the call.
        let n = unsafe {
            libc::send(s.as_raw_fd(), b.as_ptr() as *const libc::c_void, 1, libc::MSG_NOSIGNAL)
        };
        if n == 1 {
            return Ok(());
        }
        if n == 0 {
            return Err(io::ErrorKind::WriteZero.into());
        }
        let e = io::Error::last_os_error();
        if e.kind() != io::ErrorKind::Interrupted {
            return Err(e);
        }
    }
}

/// Write one byte. On Apple platforms SIGPIPE is off for this socket through
/// `SO_NOSIGPIPE`, set in [`Wake::new`]. Retries when interrupted by a signal.
#[cfg(target_vendor = "apple")]
fn write_byte(s: &UnixStream) -> io::Result<()> {
    use std::io::Write;
    loop {
        match (&*s).write(&[1u8]) {
            Ok(1) => return Ok(()),
            Ok(_) => return Err(io::ErrorKind::WriteZero.into()),
            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(e),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{ErrorKind, Read};
    use std::os::unix::io::AsRawFd;
    use std::os::unix::net::UnixStream;
    use std::sync::Arc;
    use std::time::{Duration, Instant};

    fn pair() -> (Wake, UnixStream) {
        let (w, fd) = Wake::new().expect("wake pair");
        let rx = UnixStream::from(fd);
        rx.set_nonblocking(true).unwrap();
        (w, rx)
    }

    /// Bytes readable right now, and whether the peer is closed.
    fn drain(rx: &UnixStream) -> (usize, bool) {
        let mut total = 0;
        let mut buf = [0u8; 4096];
        loop {
            match (&*rx).read(&mut buf) {
                Ok(0) => return (total, true),
                Ok(n) => total += n,
                Err(e) if e.kind() == ErrorKind::WouldBlock => return (total, false),
                Err(e) if e.kind() == ErrorKind::Interrupted => continue,
                Err(e) => panic!("read: {e}"),
            }
        }
    }

    #[test]
    fn one_signal_gives_one_byte() {
        let (w, rx) = pair();
        assert_eq!(drain(&rx), (0, false));
        w.signal();
        assert_eq!(drain(&rx), (1, false));
        assert_eq!(w.writes(), 1);
    }

    #[test]
    fn signals_without_reset_coalesce_into_one_byte() {
        let (w, rx) = pair();
        for _ in 0..1000 {
            w.signal();
        }
        assert_eq!(drain(&rx), (1, false));
        assert_eq!(w.writes(), 1);
    }

    #[test]
    fn signals_from_many_threads_coalesce() {
        let (w, rx) = pair();
        let w = Arc::new(w);
        let hs: Vec<_> = (0..8)
            .map(|_| {
                let w = w.clone();
                std::thread::spawn(move || {
                    for _ in 0..10_000 {
                        w.signal();
                    }
                })
            })
            .collect();
        for h in hs {
            h.join().unwrap();
        }
        assert_eq!(drain(&rx), (1, false));
        assert_eq!(w.writes(), 1);
    }

    #[test]
    fn reset_rearms_for_a_second_byte() {
        let (w, rx) = pair();
        w.signal();
        w.reset();
        w.signal();
        w.signal();
        assert_eq!(drain(&rx), (2, false));
        assert_eq!(w.writes(), 2);
    }

    #[test]
    fn signal_after_close_is_a_no_op() {
        let (w, rx) = pair();
        w.close();
        w.reset();
        w.signal();
        w.reset();
        w.signal();
        assert_eq!(w.writes(), 0);
        // The write end is gone: the reader sees end of file, no byte.
        assert_eq!(drain(&rx), (0, true));
        w.close();
    }

    #[test]
    fn close_after_a_byte_still_delivers_it_then_eof() {
        let (w, rx) = pair();
        w.signal();
        w.close();
        w.reset();
        w.signal();
        assert_eq!(drain(&rx), (1, true));
        assert_eq!(w.writes(), 1);
    }

    #[test]
    fn hundred_thousand_cycles_never_block() {
        // The read end is never read, so the socket buffer fills; a blocking
        // write end would hang here.
        let (w, _rx) = pair();
        let t = Instant::now();
        for _ in 0..100_000 {
            w.signal();
            w.reset();
        }
        let el = t.elapsed();
        assert!(el < Duration::from_secs(1), "{el:?}");
        assert!(w.writes() >= 1 && w.writes() <= 100_000, "{}", w.writes());
    }

    #[test]
    fn signal_with_reader_gone_does_not_fail() {
        let (w, rx) = pair();
        drop(rx);
        for _ in 0..3 {
            w.signal();
            w.reset();
        }
        assert_eq!(w.writes(), 0);
    }

    #[test]
    fn an_unexpected_write_error_rearms_for_the_next_signal() {
        let (w, _rx) = pair();
        // Put a read-only descriptor where the write end was: a write now
        // fails with an error that is neither WouldBlock nor BrokenPipe
        // (EBADF for write, ENOTSOCK for send), so no byte is waiting.
        unsafe {
            let ro = libc::open(
                c"/dev/null".as_ptr(),
                libc::O_RDONLY | libc::O_CLOEXEC,
            );
            assert!(ro >= 0);
            let g = w.tx.lock().unwrap();
            let tx = g.as_ref().unwrap().as_raw_fd();
            assert_eq!(libc::dup2(ro, tx), tx);
            libc::close(ro);
        }
        w.signal();
        assert_eq!(w.writes(), 0);
        assert!(!w.pending.load(Ordering::SeqCst), "a failed write must re-arm");
        w.signal();
        assert!(!w.pending.load(Ordering::SeqCst));
        assert_eq!(w.writes(), 0);
    }

    #[test]
    fn descriptors_have_the_right_flags() {
        let (w, rx) = pair();
        unsafe {
            let fdflags = libc::fcntl(rx.as_raw_fd(), libc::F_GETFD);
            assert!(fdflags >= 0);
            assert!(fdflags & libc::FD_CLOEXEC != 0, "read end must be close-on-exec");
            let g = w.tx.lock().unwrap();
            let tx = g.as_ref().unwrap().as_raw_fd();
            let fl = libc::fcntl(tx, libc::F_GETFL);
            assert!(fl >= 0 && fl & libc::O_NONBLOCK != 0, "write end must be nonblocking");
            let txfd = libc::fcntl(tx, libc::F_GETFD);
            assert!(txfd & libc::FD_CLOEXEC != 0, "write end must be close-on-exec");
            #[cfg(target_vendor = "apple")]
            {
                let mut v: libc::c_int = 0;
                let mut l = std::mem::size_of::<libc::c_int>() as libc::socklen_t;
                let rc = libc::getsockopt(
                    tx,
                    libc::SOL_SOCKET,
                    libc::SO_NOSIGPIPE,
                    &mut v as *mut libc::c_int as *mut libc::c_void,
                    &mut l,
                );
                assert_eq!(rc, 0);
                assert!(v != 0, "SO_NOSIGPIPE must be set on the write end");
            }
        }
    }
}
