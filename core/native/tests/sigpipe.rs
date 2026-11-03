//! A closed wake fd never raises SIGPIPE in the host, whatever the host's
//! signal setup. Neovim ignores SIGPIPE today; this binary restores the
//! default action (terminate) first, so a wake byte written to a closed peer
//! without the library's protections kills it with signal 13 and cargo
//! reports the test binary killed. Passing means the process survived.

use std::ffi::c_char;
use std::ptr::null_mut;
use std::time::{Duration, Instant};

use jupynvim::abi::*;
use jupynvim::*;

#[test]
fn a_closed_wake_fd_never_raises_sigpipe() {
    unsafe {
        assert_ne!(libc::signal(libc::SIGPIPE, libc::SIG_DFL), libc::SIG_ERR);
        // The default action is in place for the rest of the test.
        let mut old: libc::sigaction = std::mem::zeroed();
        assert_eq!(libc::sigaction(libc::SIGPIPE, std::ptr::null(), &mut old), 0);
        assert_eq!(old.sa_sigaction, libc::SIG_DFL, "SIGPIPE is at its default action");
        let mut set: libc::sigset_t = std::mem::zeroed();
        libc::sigemptyset(&mut set);
        libc::sigaddset(&mut set, libc::SIGPIPE);
        assert_eq!(libc::pthread_sigmask(libc::SIG_UNBLOCK, &set, null_mut()), 0);

        let ctx = jnv_open(1, null_mut());
        assert!(!ctx.is_null());
        let fd = jnv_wake_fd(ctx);
        assert!(fd >= 0);
        // The caller closes its end: every wake byte now goes to a closed peer.
        assert_eq!(libc::close(fd), 0);

        let d = b"x";
        for round in 0..3 {
            let mut job = 0u64;
            let st = jnv_submit(ctx, KIND_NOP, PRIO_NORMAL, d.as_ptr() as *const c_char, d.len(), &mut job);
            assert_eq!(st, OK);
            // Each poll re-arms the wake, so each completion writes again.
            let end = Instant::now() + Duration::from_secs(2);
            let mut done = [JnvDone { job: 0, kind: 0, status: -1, result: null_mut() }; 4];
            loop {
                let k = jnv_poll(ctx, done.as_mut_ptr(), done.len());
                if k > 0 {
                    assert_eq!(k, 1, "round {round}");
                    assert_eq!(done[0].job, job, "round {round}");
                    assert_eq!(done[0].status, OK, "round {round}");
                    break;
                }
                assert!(Instant::now() < end, "round {round}: the job did not come back in 2 s");
                std::thread::sleep(Duration::from_millis(1));
            }
        }
        jnv_close(ctx);
    }
}
