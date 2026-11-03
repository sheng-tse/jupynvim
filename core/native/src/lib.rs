//! libjupynvim: the in-process library of jupynvim. Neovim loads it through
//! LuaJIT's FFI and calls the small C ABI of `include/jupynvim.h`, so Rust
//! computes and Lua only paints. Threads: every function is called from one
//! thread (Neovim's main thread); submitted jobs run on the library's own
//! worker threads, and a finished batch writes one byte to the wake fd
//! (coalesced however many jobs finish) so the caller knows to collect the
//! results with `jnv_poll`. Memory: every `jnv_buf` the library hands out
//! belongs to the caller until it calls `jnv_buf_free`; input passed to a
//! submit without the copy flag is read in place and stays the caller's. The
//! library never writes to stdout or stderr and never unwinds into the
//! caller: a panic is caught and becomes a status with its message.
//!
//! The exports below are the header's functions, one each, in header order.
//! Each body runs inside [`panic::guard`] and answers a safe default (NULL,
//! 0, -1 or `JNV_PANIC`) should anything inside panic. A NULL context is
//! accepted everywhere: `jnv_wake_fd` -1, `jnv_workers` 0, `jnv_close` does
//! nothing, `jnv_call`, `jnv_submit` and `jnv_cancel` `JNV_EINVAL`,
//! `jnv_poll` 0. A context pointer after `jnv_close` is freed memory and is
//! never passed again.

pub mod abi;
pub mod jobs;
pub mod mathgrammar;
pub mod palette;
pub mod panic;
pub mod pool;
pub mod wake;

use std::ffi::c_char;
use std::os::fd::{IntoRawFd, OwnedFd};
use std::ptr::{null, null_mut};
use std::sync::atomic::AtomicBool;
use std::sync::Mutex;

use abi::{JnvBuf, JnvDone, CANCELLED, EINVAL, EKIND, ERR, OK, PANIC, SIZEOF_BUF, SIZEOF_DONE};
use jobs::{JobCx, JobErr};
use panic::guard;
use pool::{lock, Pool};

/// `jnv_ctx`: a worker pool, and the wake socket's read end until the
/// caller takes it with `jnv_wake_fd` (closed with the context otherwise).
pub struct JnvCtx {
    pool: Pool,
    wake_fd: Mutex<Option<OwnedFd>>,
}

/// The library's version, NUL-terminated for C; one address for the life
/// of the process.
static VERSION: &str = concat!(env!("CARGO_PKG_VERSION"), "\0");

/// `(major << 16) | minor`: ABI 1.1.
#[no_mangle]
pub extern "C" fn jnv_abi_version() -> u32 {
    guard(|| (abi::ABI_MAJOR << 16) | abi::ABI_MINOR).unwrap_or(0)
}

/// The library's version (the plugin's), a static NUL-terminated string.
#[no_mangle]
pub extern "C" fn jnv_version() -> *const c_char {
    guard(|| VERSION.as_ptr() as *const c_char).unwrap_or(null())
}

/// The size of `jnv_buf` (`JNV_SIZEOF_BUF`) or `jnv_done`
/// (`JNV_SIZEOF_DONE`) as this library lays them out; 0 for anything else.
#[no_mangle]
pub extern "C" fn jnv_sizeof(which: u32) -> usize {
    guard(|| match which {
        SIZEOF_BUF => std::mem::size_of::<JnvBuf>(),
        SIZEOF_DONE => std::mem::size_of::<JnvDone>(),
        _ => 0,
    })
    .unwrap_or(0)
}

/// 1 when this library runs `kind`, else 0.
#[no_mangle]
pub extern "C" fn jnv_kind_supported(kind: u32) -> i32 {
    guard(|| jobs::supported(kind) as i32).unwrap_or(0)
}

/// Buffers handed out and not yet freed, process wide.
#[no_mangle]
pub extern "C" fn jnv_live_buffers() -> u64 {
    guard(abi::live).unwrap_or(0)
}

/// Free a buffer the library returned. NULL does nothing.
///
/// # Safety
/// `buf` is NULL or a buffer from this library that was not freed yet.
#[no_mangle]
pub unsafe extern "C" fn jnv_buf_free(buf: *mut JnvBuf) {
    // SAFETY: the caller's contract above.
    let _ = guard(|| unsafe { abi::buf_free(buf) });
}

/// Open a context with `workers` worker threads (0: automatic, 1 to 64
/// exact). `*err` is set to NULL first; on failure returns NULL and, when
/// `err` is not NULL, puts a message buffer in `*err`.
///
/// # Safety
/// `err` is NULL or valid for one pointer write.
#[no_mangle]
pub unsafe extern "C" fn jnv_open(workers: u32, err: *mut *mut JnvBuf) -> *mut JnvCtx {
    let r = guard(|| {
        if !err.is_null() {
            // SAFETY: valid for a write (the caller's contract).
            unsafe { *err = null_mut() };
        }
        match Pool::new(workers) {
            Ok((pool, fd)) => Ok(Box::into_raw(Box::new(JnvCtx { pool, wake_fd: Mutex::new(Some(fd)) }))),
            Err(e) => Err(format!("cannot start the worker pool: {e}")),
        }
    });
    match r {
        Ok(Ok(ctx)) => ctx,
        Ok(Err(msg)) | Err(msg) => {
            if !err.is_null() {
                // SAFETY: as above.
                unsafe { *err = abi::error_buf(&msg) };
            }
            null_mut()
        }
    }
}

/// Hand the wake socket's read end (close-on-exec) to the caller, who
/// watches it and closes it. The first call returns it, later calls -1.
///
/// # Safety
/// `ctx` is NULL or an open context.
#[no_mangle]
pub unsafe extern "C" fn jnv_wake_fd(ctx: *mut JnvCtx) -> i32 {
    guard(|| {
        // SAFETY: NULL or an open context (the caller's contract).
        let Some(c) = (unsafe { ctx.as_ref() }) else { return -1 };
        lock(&c.wake_fd).take().map(IntoRawFd::into_raw_fd).unwrap_or(-1)
    })
    .unwrap_or(-1)
}

/// The number of worker threads.
///
/// # Safety
/// `ctx` is NULL or an open context.
#[no_mangle]
pub unsafe extern "C" fn jnv_workers(ctx: *const JnvCtx) -> u32 {
    guard(|| {
        // SAFETY: NULL or an open context (the caller's contract).
        unsafe { ctx.as_ref() }.map(|c| c.pool.workers() as u32).unwrap_or(0)
    })
    .unwrap_or(0)
}

/// Close a context without waiting: queued jobs are dropped without
/// completions, running jobs are told to stop, idle workers exit, the wake
/// socket's write end is closed and the handle is freed. NULL does nothing.
///
/// # Safety
/// `ctx` is NULL or an open context, which is never used again.
#[no_mangle]
pub unsafe extern "C" fn jnv_close(ctx: *mut JnvCtx) {
    let _ = guard(|| {
        if ctx.is_null() {
            return;
        }
        // SAFETY: a handle from jnv_open, closed once (the caller's contract).
        let c = unsafe { Box::from_raw(ctx) };
        c.pool.close();
        drop(c);
    });
}

/// Run `kind` on the calling thread (bounded work only). `*out` is set to
/// NULL first; the result or an error message goes to `*out` (dropped when
/// `out` is NULL). Returns the job's status; `JNV_EINVAL` for a NULL
/// context or NULL data with a length; `JNV_EKIND` with a message for a kind
/// this library does not run; `JNV_PANIC` with the panic's message.
///
/// # Safety
/// `ctx` is NULL or an open context; `data` is NULL or valid for `len`
/// bytes during the call; `out` is NULL or valid for one pointer write.
#[no_mangle]
pub unsafe extern "C" fn jnv_call(
    ctx: *mut JnvCtx,
    kind: u32,
    data: *const c_char,
    len: usize,
    out: *mut *mut JnvBuf,
) -> i32 {
    // SAFETY: the caller's contract above.
    match guard(|| unsafe { call(ctx, kind, data, len, out) }) {
        Ok(status) => status,
        Err(msg) => {
            if !out.is_null() {
                // SAFETY: valid for a write (the caller's contract).
                unsafe { *out = abi::error_buf(&msg) };
            }
            PANIC
        }
    }
}

/// The body of `jnv_call`, run inside its guard.
///
/// # Safety
/// The contract of `jnv_call`.
unsafe fn call(ctx: *mut JnvCtx, kind: u32, data: *const c_char, len: usize, out: *mut *mut JnvBuf) -> i32 {
    if !out.is_null() {
        // SAFETY: valid for a write (the caller's contract).
        unsafe { *out = null_mut() };
    }
    let put = |bytes: Vec<u8>| {
        if !out.is_null() {
            // SAFETY: as above.
            unsafe { *out = abi::buf_from_vec(bytes) };
        }
    };
    if ctx.is_null() || (data.is_null() && len > 0) {
        return EINVAL;
    }
    if !jobs::supported(kind) {
        put(format!("unsupported job kind {kind}").into_bytes());
        return EKIND;
    }
    let input: &[u8] = if data.is_null() {
        &[]
    } else {
        // SAFETY: non-null and valid for len bytes during the call.
        unsafe { std::slice::from_raw_parts(data as *const u8, len) }
    };
    let cancel = AtomicBool::new(false);
    match jobs::run(kind, input, &JobCx { cancel: &cancel }) {
        Ok(Some(v)) => {
            put(v);
            OK
        }
        Ok(None) => OK,
        Err(JobErr::Err(m)) => {
            put(m.into_bytes());
            ERR
        }
        Err(JobErr::Cancelled) => {
            put(b"cancelled".to_vec());
            CANCELLED
        }
    }
}

/// Queue a job for the workers. `flags`: a priority (`JNV_PRIO_*`) plus
/// optionally `JNV_FLAG_COPY`. On success `*job` is the new id (from 1,
/// increasing). `JNV_EINVAL` for a NULL context or `job`, NULL data with a
/// length, an unknown flag bit or priority 3; `JNV_EKIND` for a kind this
/// library does not run; `JNV_ESHUTDOWN` after close.
///
/// # Safety
/// `ctx` is NULL or an open context; `job` is NULL or valid for a write;
/// `data` is NULL with `len` 0 or valid for `len` bytes, and without
/// `JNV_FLAG_COPY` stays valid and unchanged until `jnv_poll` returned the
/// job's completion, or for the rest of the process after `jnv_close`.
#[no_mangle]
pub unsafe extern "C" fn jnv_submit(
    ctx: *mut JnvCtx,
    kind: u32,
    flags: u32,
    data: *const c_char,
    len: usize,
    job: *mut u64,
) -> i32 {
    guard(|| {
        // SAFETY: NULL or an open context (the caller's contract).
        let Some(c) = (unsafe { ctx.as_ref() }) else { return EINVAL };
        if job.is_null() {
            return EINVAL;
        }
        // SAFETY: the data contract above is the pool's.
        match unsafe { c.pool.submit(kind, flags, data as *const u8, len) } {
            Ok(id) => {
                // SAFETY: non-null and valid for a write.
                unsafe { *job = id };
                OK
            }
            Err(status) => status,
        }
    })
    .unwrap_or(PANIC)
}

/// Cancel a job: a queued one completes `JNV_CANCELLED` at once, a running
/// one is told to stop. `JNV_ENOJOB` when the id is neither queued nor
/// running, `JNV_EINVAL` for a NULL context.
///
/// # Safety
/// `ctx` is NULL or an open context.
#[no_mangle]
pub unsafe extern "C" fn jnv_cancel(ctx: *mut JnvCtx, job: u64) -> i32 {
    guard(|| {
        // SAFETY: NULL or an open context (the caller's contract).
        unsafe { ctx.as_ref() }.map(|c| c.pool.cancel(job)).unwrap_or(EINVAL)
    })
    .unwrap_or(PANIC)
}

/// Move up to `cap` completions into `out`, in completion order, and return
/// how many. Each `result` (NULL when the job has none) now belongs to the
/// caller. Re-arms the wake first. A NULL context, a NULL `out` or a `cap`
/// of 0 moves nothing and returns 0.
///
/// # Safety
/// `ctx` is NULL or an open context; `out` is NULL or valid for `cap`
/// writes of `jnv_done`.
#[no_mangle]
pub unsafe extern "C" fn jnv_poll(ctx: *mut JnvCtx, out: *mut JnvDone, cap: usize) -> usize {
    guard(|| {
        // SAFETY: NULL or an open context (the caller's contract).
        let Some(c) = (unsafe { ctx.as_ref() }) else { return 0 };
        if out.is_null() || cap == 0 {
            return 0;
        }
        let done = c.pool.poll(cap);
        let n = done.len();
        for (i, d) in done.into_iter().enumerate() {
            let result = d.result.map(abi::buf_from_vec).unwrap_or(null_mut());
            // SAFETY: i < n <= cap, and out is valid for cap writes.
            unsafe { out.add(i).write(JnvDone { job: d.job, kind: d.kind, status: d.status, result }) };
        }
        n
    })
    .unwrap_or(0)
}
