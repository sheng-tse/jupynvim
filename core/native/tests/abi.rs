//! The C boundary, called the way a C caller (LuaJIT's FFI) calls it: through
//! the exported `jnv_*` functions only, with raw pointers.
//!
//! Every test holds `LOCK` for its whole run, so the process-wide buffer
//! counter (`jnv_live_buffers`) only moves for the test that reads it.

use std::ffi::{c_char, CStr};
use std::path::PathBuf;
use std::ptr::{null, null_mut};
use std::sync::{Mutex, MutexGuard};
use std::time::{Duration, Instant};

use jupynvim::abi::*;
use jupynvim::*;

#[path = "support/minijson.rs"]
mod minijson;
use minijson::J;

static LOCK: Mutex<()> = Mutex::new(());

/// SLEEP 2000 as a borrowed input that stays valid for the rest of the
/// process, as the header asks of input still in flight at `jnv_close`.
static SLEEP_2000: [u8; 4] = 2000u32.to_le_bytes();

/// Holds the lock and checks, when the test ends without a failure, that
/// every buffer it was handed was freed.
struct Live {
    _g: MutexGuard<'static, ()>,
    base: u64,
}

fn start() -> Live {
    let g = LOCK.lock().unwrap_or_else(|e| e.into_inner());
    Live { _g: g, base: jnv_live_buffers() }
}

impl Drop for Live {
    fn drop(&mut self) {
        if !std::thread::panicking() {
            assert_eq!(jnv_live_buffers(), self.base, "a buffer was not freed");
        }
    }
}

/// A buffer's bytes, copied out.
unsafe fn bytes(b: *const JnvBuf) -> Vec<u8> {
    assert!(!b.is_null(), "expected a buffer, got NULL");
    let b = &*b;
    assert!(!b.ptr.is_null(), "a buffer's pointer is never NULL");
    std::slice::from_raw_parts(b.ptr, b.len).to_vec()
}

/// A buffer's bytes as text, and the buffer freed.
unsafe fn take_text(b: *mut JnvBuf) -> String {
    let s = String::from_utf8_lossy(&bytes(b)).into_owned();
    jnv_buf_free(b);
    s
}

/// A context with `workers` workers; panics with the library's message when
/// it cannot open.
fn open(workers: u32) -> *mut JnvCtx {
    let mut err: *mut JnvBuf = null_mut();
    let ctx = unsafe { jnv_open(workers, &mut err) };
    if ctx.is_null() {
        panic!("jnv_open failed: {}", unsafe { take_text(err) });
    }
    assert!(err.is_null(), "a successful open leaves *err NULL");
    ctx
}

/// `jnv_call` with a byte slice; returns the status and the output buffer.
fn call(ctx: *mut JnvCtx, kind: u32, data: &[u8]) -> (i32, *mut JnvBuf) {
    let mut out: *mut JnvBuf = null_mut();
    let st = unsafe { jnv_call(ctx, kind, data.as_ptr() as *const c_char, data.len(), &mut out) };
    (st, out)
}

fn submit(ctx: *mut JnvCtx, kind: u32, flags: u32, data: &[u8]) -> u64 {
    let mut job = 0u64;
    let st = unsafe { jnv_submit(ctx, kind, flags, data.as_ptr() as *const c_char, data.len(), &mut job) };
    assert_eq!(st, OK, "jnv_submit status");
    job
}

/// Wait up to `ms` for `fd` to become readable; true when it did.
fn wait_readable(fd: i32, ms: i32) -> bool {
    let end = Instant::now() + Duration::from_millis(ms as u64);
    loop {
        let left = end.saturating_duration_since(Instant::now()).as_millis().max(1) as i32;
        let mut p = libc::pollfd { fd, events: libc::POLLIN, revents: 0 };
        let r = unsafe { libc::poll(&mut p, 1, left) };
        if r > 0 {
            return true;
        }
        if r == 0 || std::io::Error::last_os_error().kind() != std::io::ErrorKind::Interrupted {
            return false;
        }
    }
}

/// Poll until the completions of `n` jobs have come back (2 s limit).
fn poll_n(ctx: *mut JnvCtx, n: usize) -> Vec<JnvDone> {
    let end = Instant::now() + Duration::from_secs(2);
    let mut got = Vec::new();
    let empty = JnvDone { job: 0, kind: 0, status: -1, result: null_mut() };
    while got.len() < n {
        let mut out = [empty; 8];
        let k = unsafe { jnv_poll(ctx, out.as_mut_ptr(), out.len()) };
        assert!(k <= out.len());
        got.extend_from_slice(&out[..k]);
        if got.len() < n {
            assert!(Instant::now() < end, "only {} of {n} jobs came back in 2 s", got.len());
            std::thread::sleep(Duration::from_millis(1));
        }
    }
    got
}

#[test]
fn abi_version_is_one_one() {
    let _l = start();
    assert_eq!(jnv_abi_version(), 0x0001_0001);
    assert_eq!(jnv_abi_version() >> 16, ABI_MAJOR);
    assert_eq!(jnv_abi_version() & 0xffff, ABI_MINOR);
}

#[test]
fn version_is_the_package_version() {
    let _l = start();
    let p = jnv_version();
    assert!(!p.is_null());
    let v = unsafe { CStr::from_ptr(p) }.to_str().unwrap();
    assert_eq!(v, env!("CARGO_PKG_VERSION"));
    // Static: the same pointer every time.
    assert_eq!(jnv_version(), p);
}

#[test]
fn the_library_version_equals_jupynvim_core() {
    let _l = start();
    let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../Cargo.toml");
    let toml = std::fs::read_to_string(path).expect("core/Cargo.toml");
    // The first `version = "` line is the package's (install.lua reads the same line).
    let line = toml
        .lines()
        .find(|l| l.starts_with("version = \""))
        .expect("a version line in core/Cargo.toml");
    let core = line.trim_start_matches("version = \"").split('"').next().unwrap();
    assert_eq!(
        env!("CARGO_PKG_VERSION"),
        core,
        "core/native/Cargo.toml and core/Cargo.toml must carry the same version"
    );
}

#[test]
fn sizeof_matches_the_rust_structs() {
    let _l = start();
    assert_eq!(jnv_sizeof(SIZEOF_BUF), 16);
    assert_eq!(jnv_sizeof(SIZEOF_DONE), 24);
    assert_eq!(jnv_sizeof(SIZEOF_BUF), std::mem::size_of::<JnvBuf>());
    assert_eq!(jnv_sizeof(SIZEOF_DONE), std::mem::size_of::<JnvDone>());
    for which in [0, 3, 99, u32::MAX] {
        assert_eq!(jnv_sizeof(which), 0, "jnv_sizeof({which})");
    }
}

#[test]
fn kind_supported_answers_for_every_diagnostic_kind() {
    let _l = start();
    for k in KIND_NOP..=KIND_FILL {
        assert_eq!(jnv_kind_supported(k), 1, "kind {k}");
    }
    for k in [0, 8, 0x00ff, 0x0100, 0x0700, u32::MAX] {
        assert_eq!(jnv_kind_supported(k), 0, "kind {k}");
    }
}

#[test]
fn kind_supported_answers_for_the_palette_kinds() {
    let _l = start();
    for k in [KIND_PALETTE, KIND_PALETTE_SCHEMA, KIND_PALETTE_READABLE] {
        assert_eq!(jnv_kind_supported(k), 1, "kind {k}");
    }
    assert_eq!((KIND_PALETTE, KIND_PALETTE_SCHEMA, KIND_PALETTE_READABLE), (0x0800, 0x0801, 0x0802));
    for k in [0x07ff, 0x0803, 0x0900, 0x0801 + 0x10000] {
        assert_eq!(jnv_kind_supported(k), 0, "kind {k}");
    }
}

#[test]
fn buf_free_of_null_does_nothing() {
    let _l = start();
    unsafe { jnv_buf_free(null_mut()) };
}

#[test]
fn open_sets_err_null_first_and_reports_failures() {
    let _l = start();
    // *err is set to NULL first, whatever it held.
    let mut err: *mut JnvBuf = std::ptr::NonNull::dangling().as_ptr();
    let ctx = unsafe { jnv_open(1, &mut err) };
    assert!(!ctx.is_null());
    assert!(err.is_null());
    assert_eq!(unsafe { jnv_workers(ctx) }, 1);
    unsafe { jnv_close(ctx) };

    // Automatic: one core stays free, at least 1 and at most 4.
    let ctx = open(0);
    let n = unsafe { jnv_workers(ctx) };
    assert!((1..=4).contains(&n), "auto workers {n}");
    unsafe { jnv_close(ctx) };

    let ctx = open(64);
    assert_eq!(unsafe { jnv_workers(ctx) }, 64);
    unsafe { jnv_close(ctx) };

    // More than 64 fails with a message.
    let mut err: *mut JnvBuf = std::ptr::NonNull::dangling().as_ptr();
    let ctx = unsafe { jnv_open(65, &mut err) };
    assert!(ctx.is_null());
    let msg = unsafe { take_text(err) };
    assert!(msg.contains("65") && msg.contains("64"), "{msg}");
    // A NULL err is accepted and nothing leaks.
    assert!(unsafe { jnv_open(65, null_mut()) }.is_null());
}

#[test]
fn call_nop_has_no_buffer() {
    let _l = start();
    let ctx = open(1);
    // *out is set to NULL first, whatever it held.
    let mut out: *mut JnvBuf = std::ptr::NonNull::dangling().as_ptr();
    let st = unsafe { jnv_call(ctx, KIND_NOP, b"x".as_ptr() as *const c_char, 1, &mut out) };
    assert_eq!(st, OK);
    assert!(out.is_null());
    unsafe { jnv_close(ctx) };
}

#[test]
fn call_echo_keeps_nul_bytes_and_empty_input() {
    let _l = start();
    let ctx = open(1);
    let data = b"a\0b\0\0c\xff";
    let (st, out) = call(ctx, KIND_ECHO, data);
    assert_eq!(st, OK);
    assert_eq!(unsafe { bytes(out) }, data);
    unsafe { jnv_buf_free(out) };

    // Empty input with a real pointer.
    let (st, out) = call(ctx, KIND_ECHO, b"");
    assert_eq!(st, OK);
    assert_eq!(unsafe { bytes(out) }, b"");
    unsafe { jnv_buf_free(out) };

    // NULL with length 0 is an empty input.
    let mut out: *mut JnvBuf = null_mut();
    let st = unsafe { jnv_call(ctx, KIND_ECHO, null(), 0, &mut out) };
    assert_eq!(st, OK);
    assert_eq!(unsafe { bytes(out) }, b"");
    unsafe { jnv_buf_free(out) };
    unsafe { jnv_close(ctx) };
}

#[test]
fn call_bytesum_and_ptr() {
    let _l = start();
    let ctx = open(1);
    let data = [1u8, 2, 3, 255, 0, 200];
    let (st, out) = call(ctx, KIND_BYTESUM, &data);
    assert_eq!(st, OK);
    let b = unsafe { bytes(out) };
    assert_eq!(u64::from_le_bytes(b.try_into().unwrap()), 461);
    unsafe { jnv_buf_free(out) };

    // PTR: the call reads the caller's bytes in place.
    let doc = vec![7u8; 4096];
    let (st, out) = call(ctx, KIND_PTR, &doc);
    assert_eq!(st, OK);
    let b = unsafe { bytes(out) };
    assert_eq!(u64::from_le_bytes(b.try_into().unwrap()), doc.as_ptr() as usize as u64);
    unsafe { jnv_buf_free(out) };
    unsafe { jnv_close(ctx) };
}

#[test]
fn call_rejects_a_null_ctx_and_null_data_with_a_length() {
    let _l = start();
    let mut out: *mut JnvBuf = std::ptr::NonNull::dangling().as_ptr();
    let st = unsafe { jnv_call(null_mut(), KIND_ECHO, b"abc".as_ptr() as *const c_char, 3, &mut out) };
    assert_eq!(st, EINVAL);
    assert!(out.is_null());

    let ctx = open(1);
    let mut out: *mut JnvBuf = std::ptr::NonNull::dangling().as_ptr();
    let st = unsafe { jnv_call(ctx, KIND_ECHO, null(), 3, &mut out) };
    assert_eq!(st, EINVAL);
    assert!(out.is_null());
    unsafe { jnv_close(ctx) };
}

#[test]
fn every_export_taking_a_ctx_accepts_null() {
    let _l = start();
    let ctx: *mut JnvCtx = null_mut();
    unsafe {
        assert_eq!(jnv_wake_fd(ctx), -1);
        assert_eq!(jnv_workers(ctx), 0);
        jnv_close(ctx);
        let mut out: *mut JnvBuf = null_mut();
        assert_eq!(jnv_call(ctx, KIND_NOP, null(), 0, &mut out), EINVAL);
        assert!(out.is_null());
        let mut job = 0u64;
        assert_eq!(jnv_submit(ctx, KIND_NOP, PRIO_NORMAL, null(), 0, &mut job), EINVAL);
        assert_eq!(job, 0);
        assert_eq!(jnv_cancel(ctx, 1), EINVAL);
        let mut done = [JnvDone { job: 0, kind: 0, status: -1, result: null_mut() }; 4];
        assert_eq!(jnv_poll(ctx, done.as_mut_ptr(), done.len()), 0);
        assert_eq!(done[0].status, -1, "nothing written");
    }
}

#[test]
fn poll_with_null_out_or_cap_zero_moves_nothing() {
    let _l = start();
    let ctx = open(1);
    let fd = unsafe { jnv_wake_fd(ctx) };
    assert!(fd >= 0);
    let id = submit(ctx, KIND_ECHO, PRIO_NORMAL, b"kept");
    // The wake byte follows the published completion.
    assert!(wait_readable(fd, 2000), "no wake within 2 s");
    let mut done = [JnvDone { job: 0, kind: 0, status: -1, result: null_mut() }; 4];
    unsafe {
        assert_eq!(jnv_poll(ctx, null_mut(), 4), 0);
        assert_eq!(jnv_poll(ctx, done.as_mut_ptr(), 0), 0);
        assert_eq!(done[0].status, -1, "nothing written");
    }
    // The job is still there for the next real poll.
    let got = poll_n(ctx, 1);
    assert_eq!(got[0].job, id);
    assert_eq!(got[0].status, OK);
    assert_eq!(unsafe { bytes(got[0].result) }, b"kept");
    unsafe {
        jnv_buf_free(got[0].result);
        libc::close(fd);
        jnv_close(ctx);
    }
}

#[test]
fn call_of_an_unknown_kind_is_ekind_with_a_message() {
    let _l = start();
    let ctx = open(1);
    for kind in [0u32, 8, 0x0100, 0x0803, u32::MAX] {
        let (st, out) = call(ctx, kind, b"x");
        assert_eq!(st, EKIND, "kind {kind}");
        let msg = unsafe { take_text(out) };
        assert!(msg.contains("kind") && msg.contains(&kind.to_string()), "{msg}");
    }
    unsafe { jnv_close(ctx) };
}

#[test]
fn call_reports_job_errors_with_their_message() {
    let _l = start();
    let ctx = open(1);
    let (st, out) = call(ctx, KIND_SLEEP, b"abc");
    assert_eq!(st, ERR);
    let msg = unsafe { take_text(out) };
    assert!(msg.contains("SLEEP wants 4 bytes"), "{msg}");
    unsafe { jnv_close(ctx) };
}

#[test]
fn call_of_panic_is_status_2_with_the_message() {
    let _l = start();
    let ctx = open(1);
    let (st, out) = call(ctx, KIND_PANIC, b"boom");
    assert_eq!(st, PANIC);
    assert_eq!(st, 2);
    let msg = unsafe { take_text(out) };
    assert!(msg.contains("jnv test panic: boom"), "{msg}");
    // The context still works afterwards.
    let (st, out) = call(ctx, KIND_ECHO, b"after");
    assert_eq!(st, OK);
    assert_eq!(unsafe { take_text(out) }, "after");
    unsafe { jnv_close(ctx) };
}

#[test]
fn call_with_out_null_never_leaks() {
    let _l = start();
    let ctx = open(1);
    let base = jnv_live_buffers();
    unsafe {
        let d = b"payload";
        let p = d.as_ptr() as *const c_char;
        assert_eq!(jnv_call(ctx, KIND_ECHO, p, d.len(), null_mut()), OK);
        assert_eq!(jnv_call(ctx, KIND_NOP, p, d.len(), null_mut()), OK);
        assert_eq!(jnv_call(ctx, KIND_PANIC, p, d.len(), null_mut()), PANIC);
        assert_eq!(jnv_call(ctx, KIND_SLEEP, p, d.len(), null_mut()), ERR);
        assert_eq!(jnv_call(ctx, 0, p, d.len(), null_mut()), EKIND);
        assert_eq!(jnv_call(ctx, KIND_ECHO, null(), 1, null_mut()), EINVAL);
    }
    assert_eq!(jnv_live_buffers(), base);
    unsafe { jnv_close(ctx) };
}

#[test]
fn wake_fd_is_handed_over_once_and_signals_a_finished_job() {
    let _l = start();
    let ctx = open(1);
    let fd = unsafe { jnv_wake_fd(ctx) };
    assert!(fd >= 0, "wake fd {fd}");
    assert_eq!(unsafe { jnv_wake_fd(ctx) }, -1, "the read end is handed over once");
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFD) };
    assert!(flags >= 0 && flags & libc::FD_CLOEXEC != 0, "close-on-exec");

    let id = submit(ctx, KIND_ECHO, PRIO_VISIBLE, b"hello\0world");
    assert!(id >= 1);
    assert!(wait_readable(fd, 2000), "no wake within 2 s");
    let mut byte = [0u8; 1];
    let n = unsafe { libc::read(fd, byte.as_mut_ptr() as *mut libc::c_void, 1) };
    assert_eq!(n, 1);
    let mut done = [JnvDone { job: 0, kind: 0, status: -1, result: null_mut() }; 4];
    let k = unsafe { jnv_poll(ctx, done.as_mut_ptr(), done.len()) };
    assert_eq!(k, 1);
    assert_eq!(done[0].job, id);
    assert_eq!(done[0].kind, KIND_ECHO);
    assert_eq!(done[0].status, OK);
    assert_eq!(unsafe { bytes(done[0].result) }, b"hello\0world");
    unsafe {
        jnv_buf_free(done[0].result);
        libc::close(fd);
        jnv_close(ctx);
    }
}

#[test]
fn submit_validates_and_numbers_jobs_from_one() {
    let _l = start();
    let ctx = open(1);
    let d = b"x";
    let p = d.as_ptr() as *const c_char;
    let mut job = 0u64;
    unsafe {
        assert_eq!(jnv_submit(ctx, KIND_NOP, PRIO_NORMAL, p, 1, null_mut()), EINVAL, "NULL job");
        assert_eq!(jnv_submit(ctx, KIND_NOP, 3, p, 1, &mut job), EINVAL, "priority 3");
        assert_eq!(jnv_submit(ctx, KIND_NOP, 4, p, 1, &mut job), EINVAL, "unknown flag bit");
        assert_eq!(jnv_submit(ctx, KIND_NOP, 1 << 31, p, 1, &mut job), EINVAL, "high flag bit");
        assert_eq!(jnv_submit(ctx, KIND_NOP, PRIO_NORMAL, null(), 1, &mut job), EINVAL, "NULL data");
        assert_eq!(jnv_submit(ctx, 0, PRIO_NORMAL, p, 1, &mut job), EKIND, "kind 0");
    }
    assert_eq!(job, 0, "no id for a refused submit");
    let a = submit(ctx, KIND_NOP, PRIO_VISIBLE, d);
    let b = submit(ctx, KIND_NOP, PRIO_NORMAL | FLAG_COPY, d);
    let c = submit(ctx, KIND_NOP, PRIO_BACKGROUND, d);
    assert_eq!((a, b, c), (1, 2, 3));
    let mut got = poll_n(ctx, 3);
    got.sort_by_key(|x| x.job);
    for (x, id) in got.iter().zip([1u64, 2, 3]) {
        assert_eq!(x.job, id);
        assert_eq!(x.kind, KIND_NOP);
        assert_eq!(x.status, OK);
        assert!(x.result.is_null(), "NOP has no result");
    }
    unsafe { jnv_close(ctx) };
}

#[test]
fn submitted_ptr_is_borrowed_or_copied() {
    let _l = start();
    let ctx = open(1);
    let doc = vec![1u8; 1000];
    let a = submit(ctx, KIND_PTR, PRIO_NORMAL, &doc);
    let b = submit(ctx, KIND_PTR, PRIO_NORMAL | FLAG_COPY, &doc);
    let got = poll_n(ctx, 2);
    let addr = |id: u64| {
        let d = got.iter().find(|x| x.job == id).unwrap();
        assert_eq!(d.status, OK);
        let b = unsafe { bytes(d.result) };
        u64::from_le_bytes(b.try_into().unwrap())
    };
    assert_eq!(addr(a), doc.as_ptr() as usize as u64);
    assert_ne!(addr(b), doc.as_ptr() as usize as u64);
    for d in &got {
        unsafe { jnv_buf_free(d.result) };
    }
    unsafe { jnv_close(ctx) };
}

#[test]
fn cancel_queued_running_and_unknown() {
    let _l = start();
    let ctx = open(1);
    let running = submit(ctx, KIND_SLEEP, PRIO_NORMAL, &SLEEP_2000);
    // Give the single worker time to take it.
    std::thread::sleep(Duration::from_millis(30));
    let queued = submit(ctx, KIND_ECHO, PRIO_NORMAL, b"never");
    assert_eq!(unsafe { jnv_cancel(ctx, queued) }, OK);
    assert_eq!(unsafe { jnv_cancel(ctx, queued) }, ENOJOB, "already gone");
    assert_eq!(unsafe { jnv_cancel(ctx, 999_999) }, ENOJOB);
    let t = Instant::now();
    assert_eq!(unsafe { jnv_cancel(ctx, running) }, OK);
    let got = poll_n(ctx, 2);
    assert!(t.elapsed() < Duration::from_millis(500), "running cancel took {:?}", t.elapsed());
    for d in &got {
        assert_eq!(d.status, CANCELLED, "job {}", d.job);
        assert_eq!(unsafe { bytes(d.result) }, b"cancelled");
        unsafe { jnv_buf_free(d.result) };
    }
    let kinds: Vec<(u64, u32)> = got.iter().map(|d| (d.job, d.kind)).collect();
    assert!(kinds.contains(&(queued, KIND_ECHO)) && kinds.contains(&(running, KIND_SLEEP)), "{kinds:?}");
    unsafe { jnv_close(ctx) };
}

#[test]
fn close_with_a_running_job_returns_at_once() {
    let _l = start();
    let ctx = open(1);
    let _ = submit(ctx, KIND_SLEEP, PRIO_NORMAL, &SLEEP_2000);
    // Queued behind it, dropped by close without a completion.
    let _ = submit(ctx, KIND_SLEEP, PRIO_NORMAL, &SLEEP_2000);
    std::thread::sleep(Duration::from_millis(30));
    let t = Instant::now();
    unsafe { jnv_close(ctx) };
    let took = t.elapsed();
    assert!(took < Duration::from_millis(5), "jnv_close took {took:?}");
}

/// Open descriptors of this process, counted over 0 to 4095 (a new
/// descriptor takes the lowest free number, far below 4096 here).
fn open_fds() -> usize {
    (0..4096).filter(|&fd| unsafe { libc::fcntl(fd, libc::F_GETFD) } >= 0).count()
}

/// Read `fd` until end of file, for at most `ms`; true when end of file
/// came. Wake bytes still in the socket are read and skipped on the way.
fn reads_eof_within(fd: i32, ms: u64) -> bool {
    let end = Instant::now() + Duration::from_millis(ms);
    loop {
        let left = end.saturating_duration_since(Instant::now()).as_millis() as i32;
        if left == 0 || !wait_readable(fd, left) {
            return false;
        }
        let mut b = [0u8; 64];
        let n = unsafe { libc::read(fd, b.as_mut_ptr() as *mut libc::c_void, b.len()) };
        if n == 0 {
            return true;
        }
        if n < 0 && std::io::Error::last_os_error().kind() != std::io::ErrorKind::Interrupted {
            return false;
        }
    }
}

#[test]
fn close_shuts_the_context_down_and_frees_it() {
    let _l = start();
    // The caller took the wake fd. Closing shuts the pool down (the running
    // job is told to stop, the queued one is dropped) and closes the wake
    // socket's write end, so the read end reaches end of file. A wake byte
    // the stopped job wrote just before the write end closed may come first.
    let ctx = open(1);
    let fd = unsafe { jnv_wake_fd(ctx) };
    assert!(fd >= 0, "wake fd {fd}");
    let _ = submit(ctx, KIND_SLEEP, PRIO_NORMAL, &SLEEP_2000);
    let _ = submit(ctx, KIND_SLEEP, PRIO_NORMAL, &SLEEP_2000);
    std::thread::sleep(Duration::from_millis(30));
    unsafe { jnv_close(ctx) };
    assert!(reads_eof_within(fd, 1000), "no end of file on the wake fd within 1 s of jnv_close");
    unsafe { libc::close(fd) };

    // The caller never took the wake fd: an open context holds both ends of
    // the wake socket, and closing it frees the handle and both ends.
    let before = open_fds();
    let ctx = open(1);
    assert_eq!(open_fds(), before + 2, "an open context holds the two ends of the wake socket");
    unsafe { jnv_close(ctx) };
    assert_eq!(open_fds(), before, "jnv_close leaves no descriptor behind");

    // The same with a job still running: its worker outlives the handle, yet
    // jnv_close itself closes the write end, before that worker exits.
    let ctx = open(1);
    let _ = submit(ctx, KIND_SLEEP, PRIO_NORMAL, &SLEEP_2000);
    std::thread::sleep(Duration::from_millis(30));
    unsafe { jnv_close(ctx) };
    assert_eq!(open_fds(), before, "jnv_close with a running job leaves no descriptor behind");
}

#[test]
fn ten_thousand_echo_round_trips_leave_no_buffer() {
    let _l = start();
    let ctx = open(2);
    let base = jnv_live_buffers();
    for i in 0..10_000u32 {
        let (st, out) = call(ctx, KIND_ECHO, &i.to_le_bytes());
        assert_eq!(st, OK);
        unsafe { jnv_buf_free(out) };
    }
    let ids: Vec<u64> = (0..1000u32).map(|i| submit(ctx, KIND_ECHO, PRIO_NORMAL | FLAG_COPY, &i.to_le_bytes())).collect();
    let got = poll_n(ctx, ids.len());
    assert_eq!(jnv_live_buffers(), base + ids.len() as u64);
    for d in &got {
        unsafe { jnv_buf_free(d.result) };
    }
    assert_eq!(jnv_live_buffers(), base);
    unsafe { jnv_close(ctx) };
}

// ---- the palette kinds (0x0800 to 0x0802) ----

fn palette_fixture(name: &str) -> J {
    let p = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures/palette").join(name);
    let s = std::fs::read_to_string(&p).unwrap_or_else(|e| panic!("reading {}: {e}", p.display()));
    minijson::parse(&s).unwrap_or_else(|e| panic!("{}: {e}", p.display()))
}

/// The group names of a schema result (the lines between `groups N` and
/// `tokens M`), the token names after it and the known ports after those
/// (the lines after `ports P`, verbatim: `<key> <source> <label>`).
fn schema_names(schema: &str) -> (Vec<String>, Vec<String>, Vec<String>) {
    let lines: Vec<&str> = schema.lines().collect();
    assert_eq!(lines[0], "JNP 1");
    let ng: usize = lines[1].strip_prefix("groups ").expect("groups line").parse().expect("a count");
    let groups: Vec<String> = lines[2..2 + ng].iter().map(|s| s.to_string()).collect();
    let nt: usize = lines[2 + ng].strip_prefix("tokens ").expect("tokens line").parse().expect("a count");
    let tokens: Vec<String> = lines[3 + ng..3 + ng + nt].iter().map(|s| s.to_string()).collect();
    let np: usize = lines
        .get(3 + ng + nt)
        .and_then(|l| l.strip_prefix("ports "))
        .expect("ports line")
        .parse()
        .expect("a count");
    let ports: Vec<String> = lines[4 + ng + nt..4 + ng + nt + np].iter().map(|s| s.to_string()).collect();
    assert_eq!(lines.len(), 4 + ng + nt + np, "nothing after the ports");
    (groups, tokens, ports)
}

/// The derive input of the approved user case, written the way the Lua side
/// writes it: tokyonight storm, dark, the terminal answering `#222436`, the
/// groups of the schema that `user_hl.json` has.
fn user_input_text(groups: &[String], set: bool) -> String {
    let dump = palette_fixture("user_hl.json");
    let mut s = String::from("JNP 1\nkind dark\nname tokyonight-storm\nterm #222436\n");
    if set {
        s.push_str("set\n");
    }
    for g in groups {
        let Some(v) = dump.get(g) else { continue };
        let c = |attr: &str| v.get(attr).and_then(J::as_str).unwrap_or("-").to_string();
        let (fg, bg) = (c("fg"), c("bg"));
        if fg != "-" || bg != "-" {
            s.push_str(&format!("g {g} {fg} {bg}\n"));
        }
    }
    s
}

#[test]
fn call_palette_kinds() {
    let _l = start();
    let ctx = open(1);

    // 2049: the schema, whatever the input.
    let (st, out) = call(ctx, KIND_PALETTE_SCHEMA, b"ignored");
    assert_eq!(st, OK);
    let schema = unsafe { take_text(out) };
    assert!(schema.starts_with("JNP 1\ngroups 37\nNormal\n"), "{schema}");
    let (groups, tokens, ports) = schema_names(&schema);
    assert_eq!((groups.len(), tokens.len()), (37, 35));
    assert_eq!(tokens[0], "canvas");
    assert_eq!(tokens[34], "quote_bar");
    assert_eq!(ports.len(), 19);
    assert_eq!(ports[0], "tokyonight-storm enkia.tokyo-night-1.1.2 Tokyo Night Storm");
    let (st, out) = call(ctx, KIND_PALETTE_SCHEMA, b"");
    assert_eq!(st, OK);
    assert_eq!(unsafe { take_text(out) }, schema, "the same schema for any input");

    // 2048: the user fixture derives the approved tokens, without `set`.
    let text = user_input_text(&groups, false);
    let (st, out) = call(ctx, KIND_PALETTE, text.as_bytes());
    assert_eq!(st, OK);
    let res = unsafe { take_text(out) };
    assert!(res.starts_with("JNP 1\ntheme "), "{res}");
    assert!(res.lines().any(|l| l.starts_with("t text #c0caf5 ")), "{res}");
    assert!(res.lines().any(|l| l == "kind dark"));
    assert!(res.lines().any(|l| l == "canvas_source terminal"));
    assert!(res.lines().any(|l| l == "port tokyonight-storm"));
    let expected = palette_fixture("user_tokens.json");
    let tlines: Vec<&str> = res.lines().filter(|l| l.starts_with("t ")).collect();
    assert_eq!(tlines.len(), 35);
    for (line, name) in tlines.iter().zip(&tokens) {
        let want = expected.get(name).and_then(J::as_str).unwrap_or_else(|| panic!("no expected {name}"));
        let mut it = line.splitn(5, ' ');
        assert_eq!((it.next(), it.next(), it.next()), (Some("t"), Some(name.as_str()), Some(want)), "{line}");
        let source = it.next().unwrap_or("");
        assert!(["override", "group", "port", "formula", "derived"].contains(&source), "{line}");
    }

    // The same input again gives the same bytes (nothing in it moves).
    let (st, out) = call(ctx, KIND_PALETTE, text.as_bytes());
    assert_eq!(st, OK);
    assert_eq!(unsafe { take_text(out) }, res);

    // Malformed input: JNV_ERR with the line.
    for (bad, line) in [
        ("JNP 1\nkind dark\ng Normal red -\n", 3),
        ("kind dark\n", 1),
        ("JNP 1\nkind dusk\n", 2),
        ("JNP 1\nkind dark\no nope #ffffff\n", 3),
    ] {
        let (st, out) = call(ctx, KIND_PALETTE, bad.as_bytes());
        assert_eq!(st, ERR, "{bad:?}");
        let msg = unsafe { take_text(out) };
        assert!(msg.contains("palette input line"), "{msg}");
        assert!(msg.starts_with(&format!("palette input line {line}: ")), "{bad:?}: {msg}");
    }
    let (st, out) = call(ctx, KIND_PALETTE, b"");
    assert_eq!(st, ERR);
    assert!(unsafe { take_text(out) }.contains("palette input line"));

    // 2050: a readable color is a 7-character line; one that already reads is kept.
    let (st, out) = call(ctx, KIND_PALETTE_READABLE, b"#7aa2f7 #ffff00");
    assert_eq!(st, OK);
    let c = unsafe { take_text(out) };
    assert_eq!(c.len(), 8, "{c:?}");
    assert!(c.ends_with('\n'));
    let c = c.trim_end();
    assert_eq!(c.len(), 7, "{c:?}");
    assert!(c.starts_with('#') && c[1..].bytes().all(|b| b.is_ascii_hexdigit()), "{c:?}");
    let (st, out) = call(ctx, KIND_PALETTE_READABLE, b"#c0caf5 #222436");
    assert_eq!(st, OK);
    assert_eq!(unsafe { take_text(out) }, "#c0caf5\n");
    let (st, out) = call(ctx, KIND_PALETTE_READABLE, b"#c0caf5");
    assert_eq!(st, ERR);
    assert!(unsafe { take_text(out) }.starts_with("palette readable: "));

    // The same kinds through submit and poll.
    let job = submit(ctx, KIND_PALETTE_SCHEMA, FLAG_COPY | PRIO_VISIBLE, b"");
    let done = poll_n(ctx, 1);
    assert_eq!((done[0].job, done[0].kind, done[0].status), (job, KIND_PALETTE_SCHEMA, OK));
    assert_eq!(unsafe { take_text(done[0].result) }, schema);
    unsafe { jnv_close(ctx) };
}

#[test]
fn a_palette_derived_with_set_becomes_the_one_readable_uses() {
    let _l = start();
    let ctx = open(1);
    let (st, out) = call(ctx, KIND_PALETTE_SCHEMA, b"");
    assert_eq!(st, OK);
    let (groups, _, _) = schema_names(&unsafe { take_text(out) });

    // No palette was set in this process: white or black.
    let (st, out) = call(ctx, KIND_PALETTE_READABLE, b"#1c1f31 #222436");
    assert_eq!(st, OK);
    assert_eq!(unsafe { take_text(out) }, "#ffffff\n");

    // Without `set` nothing changes.
    let (st, out) = call(ctx, KIND_PALETTE, user_input_text(&groups, false).as_bytes());
    assert_eq!(st, OK);
    unsafe { jnv_buf_free(out) };
    let (_, out) = call(ctx, KIND_PALETTE_READABLE, b"#1c1f31 #222436");
    assert_eq!(unsafe { take_text(out) }, "#ffffff\n");

    // With `set` the library keeps it: the light text and the dark canvas of the user's palette.
    let (st, out) = call(ctx, KIND_PALETTE, user_input_text(&groups, true).as_bytes());
    assert_eq!(st, OK);
    unsafe { jnv_buf_free(out) };
    let (_, out) = call(ctx, KIND_PALETTE_READABLE, b"#1c1f31 #222436");
    assert_eq!(unsafe { take_text(out) }, "#c0caf5\n");
    let (_, out) = call(ctx, KIND_PALETTE_READABLE, b"#7aa2f7 #ffff00");
    assert_eq!(unsafe { take_text(out) }, "#222436\n");
    let (_, out) = call(ctx, KIND_PALETTE_READABLE, b"#808080 #ffffff 3.0");
    assert_eq!(unsafe { take_text(out) }, "#808080\n");
    unsafe { jnv_close(ctx) };
}
