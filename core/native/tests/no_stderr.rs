//! The library never writes to stderr, panics included (Neovim's stderr
//! reaches the terminal, so a printed panic would corrupt the screen).
//!
//! Its own binary without the test harness (`harness = false`): the harness
//! captures what a test thread's panics print, so a printing panic hook
//! would land in the capture buffer and never reach fd 2. Here nothing is
//! captured, as inside Neovim. fd 2 is redirected to a pipe around the
//! library calls, and the pipe must stay empty. A control then panics
//! outside any guard with fd 2 redirected the same way and must find the
//! panic message in its pipe, which proves the check can see a print.

use std::ffi::c_char;
use std::process::exit;
use std::ptr::null_mut;
use std::time::{Duration, Instant};

use jupynvim::abi::*;
use jupynvim::*;

/// fd 2 redirected to a pipe; holds the saved fd 2 and the pipe's read end.
struct Redirect {
    saved: i32,
    rd: i32,
}

fn redirect_stderr() -> Redirect {
    let mut fds = [0i32; 2];
    unsafe {
        assert_eq!(libc::pipe(fds.as_mut_ptr()), 0, "pipe");
        // Read without blocking: nothing may hang if a write end survives.
        let fl = libc::fcntl(fds[0], libc::F_GETFL);
        assert!(fl >= 0 && libc::fcntl(fds[0], libc::F_SETFL, fl | libc::O_NONBLOCK) == 0);
        let saved = libc::dup(2);
        assert!(saved >= 0, "dup(2)");
        assert_eq!(libc::dup2(fds[1], 2), 2, "dup2 onto fd 2");
        libc::close(fds[1]);
        Redirect { saved, rd: fds[0] }
    }
}

/// Put fd 2 back and return what the pipe received meanwhile.
fn restore(r: Redirect) -> Vec<u8> {
    let mut got = Vec::new();
    unsafe {
        assert_eq!(libc::dup2(r.saved, 2), 2, "restore fd 2");
        libc::close(r.saved);
        let mut buf = [0u8; 4096];
        loop {
            let n = libc::read(r.rd, buf.as_mut_ptr() as *mut libc::c_void, buf.len());
            if n > 0 {
                got.extend_from_slice(&buf[..n as usize]);
            } else if n < 0 && std::io::Error::last_os_error().kind() == std::io::ErrorKind::Interrupted {
                continue;
            } else {
                break;
            }
        }
        libc::close(r.rd);
    }
    got
}

/// The library calls that can panic or fail, with fd 2 redirected. Returns
/// a description of anything that went wrong besides printing.
fn library_calls() -> Vec<String> {
    let mut problems = Vec::new();
    unsafe {
        // A failing open builds an error message.
        let mut err: *mut JnvBuf = null_mut();
        if !jnv_open(65, &mut err).is_null() {
            problems.push("jnv_open(65) did not fail".to_string());
        }
        jnv_buf_free(err);

        let ctx = jnv_open(1, null_mut());
        if ctx.is_null() {
            problems.push("jnv_open(1) failed".to_string());
            return problems;
        }

        // A panic on the calling thread.
        let d = b"sync boom";
        let mut out: *mut JnvBuf = null_mut();
        let st = jnv_call(ctx, KIND_PANIC, d.as_ptr() as *const c_char, d.len(), &mut out);
        if st != PANIC || out.is_null() {
            problems.push(format!("jnv_call PANIC gave status {st}"));
        }
        jnv_buf_free(out);

        // A panic on a worker thread.
        let d = b"async boom";
        let mut job = 0u64;
        let st = jnv_submit(ctx, KIND_PANIC, PRIO_NORMAL | FLAG_COPY, d.as_ptr() as *const c_char, d.len(), &mut job);
        if st != OK {
            problems.push(format!("jnv_submit PANIC gave status {st}"));
        } else {
            let end = Instant::now() + Duration::from_secs(5);
            let mut done = [JnvDone { job: 0, kind: 0, status: -1, result: null_mut() }; 4];
            loop {
                let k = jnv_poll(ctx, done.as_mut_ptr(), done.len());
                if k > 0 {
                    if k != 1 || done[0].job != job || done[0].status != PANIC {
                        problems.push(format!("the PANIC job came back as {:?}", &done[..k]));
                    }
                    for d in &done[..k] {
                        jnv_buf_free(d.result);
                    }
                    break;
                }
                if Instant::now() > end {
                    problems.push("the PANIC job did not come back in 5 s".to_string());
                    break;
                }
                std::thread::sleep(Duration::from_millis(1));
            }
        }
        jnv_close(ctx);
    }
    problems
}

fn main() {
    let mut failed = 0;

    let r = redirect_stderr();
    let problems = library_calls();
    let printed = restore(r);
    for p in &problems {
        println!("FAIL {p}");
        failed += 1;
    }
    if printed.is_empty() {
        println!("ok the library wrote nothing to stderr (sync panic, worker panic, failed open)");
    } else {
        println!(
            "FAIL the library wrote {} bytes to stderr:\n{}",
            printed.len(),
            String::from_utf8_lossy(&printed)
        );
        failed += 1;
    }

    // Control: outside any guard the hook defers to the default one, which
    // prints to fd 2; the same redirect must catch it.
    let r = redirect_stderr();
    let joined = std::thread::spawn(|| panic!("no_stderr control panic outside any guard")).join();
    let printed = restore(r);
    let text = String::from_utf8_lossy(&printed);
    if joined.is_err() && text.contains("no_stderr control panic outside any guard") {
        println!("ok control: an unguarded panic reaches the redirected fd 2");
    } else {
        println!("FAIL control: the redirect did not see an unguarded panic (got {text:?})");
        failed += 1;
    }

    if failed > 0 {
        println!("no_stderr: {failed} checks failed");
        exit(1);
    }
    println!("no_stderr: all checks passed");
}
