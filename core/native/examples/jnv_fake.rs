//! A fake libjupynvim for the loader tests. Standalone: it never links the
//! real library. It exports every function of `include/jupynvim.h`, and
//! what it answers depends on the `JNV_FAKE` environment variable, read at
//! each call:
//!
//! - `abi_major`: `jnv_abi_version` reports ABI 2.0 (a major the loader refuses);
//! - `version`: `jnv_version` reports "0.0.0-fake";
//! - `sizeof`: `jnv_sizeof` reports 99;
//! - `signal`: `jnv_abi_version` ends the process that calls it with
//!   SIGUSR2, as a library that kills whatever loads it would (a signal
//!   for which the system writes no crash report);
//! - `kill`: `jnv_abi_version` ends it with SIGKILL, as macOS does to a
//!   process that maps a library page whose code signature fails;
//! - `hang`: `jnv_abi_version` never returns (it sleeps), as a library
//!   whose load deadlocks would;
//! - anything else (`ok`): the correct answers, ABI 1.1, the package
//!   version, 16 and 24.
//!
//! `jnv_open` always fails with "fake library: no worker pool" (a buffer of
//! this library's own, freed by its `jnv_buf_free`). Everything else is
//! inert: no kind is supported, no buffer is live, there is no wake fd and
//! no worker, close does nothing, call and submit answer `JNV_EINVAL` (4),
//! cancel `JNV_ENOJOB` (7), poll 0.

use std::ffi::c_char;
use std::ptr::null_mut;

/// `jnv_buf`.
#[repr(C)]
pub struct FakeBuf {
    ptr: *const u8,
    len: usize,
}

/// `jnv_done`, for `jnv_poll`'s signature.
#[repr(C)]
pub struct FakeDone {
    job: u64,
    kind: u32,
    status: i32,
    result: *mut FakeBuf,
}

/// `jnv_ctx`: never made, only named.
#[repr(C)]
pub struct FakeCtx {
    _opaque: [u8; 0],
}

/// The allocation behind a buffer of this library: the head comes first.
#[repr(C)]
struct Owned {
    head: FakeBuf,
    data: Vec<u8>,
}

const EINVAL: i32 = 4;
const ENOJOB: i32 = 7;

fn mode_is(m: &str) -> bool {
    std::env::var("JNV_FAKE").map(|v| v == m).unwrap_or(false)
}

extern "C" {
    fn raise(sig: i32) -> i32;
}

#[cfg(target_os = "macos")]
const SIGUSR2: i32 = 31;
#[cfg(not(target_os = "macos"))]
const SIGUSR2: i32 = 12;
const SIGKILL: i32 = 9;

#[no_mangle]
pub extern "C" fn jnv_abi_version() -> u32 {
    if mode_is("signal") {
        // SAFETY: raise only sends a signal to this process.
        unsafe { raise(SIGUSR2) };
    }
    if mode_is("kill") {
        // SAFETY: as above.
        unsafe { raise(SIGKILL) };
    }
    if mode_is("hang") {
        loop {
            std::thread::sleep(std::time::Duration::from_secs(3600));
        }
    }
    if mode_is("abi_major") {
        2 << 16
    } else {
        (1 << 16) | 1
    }
}

#[no_mangle]
pub extern "C" fn jnv_version() -> *const c_char {
    if mode_is("version") {
        c"0.0.0-fake".as_ptr()
    } else {
        concat!(env!("CARGO_PKG_VERSION"), "\0").as_ptr() as *const c_char
    }
}

#[no_mangle]
pub extern "C" fn jnv_sizeof(which: u32) -> usize {
    if mode_is("sizeof") {
        return 99;
    }
    match which {
        1 => 16,
        2 => 24,
        _ => 0,
    }
}

#[no_mangle]
pub extern "C" fn jnv_kind_supported(_kind: u32) -> i32 {
    0
}

#[no_mangle]
pub extern "C" fn jnv_live_buffers() -> u64 {
    0
}

/// # Safety
/// `buf` is NULL or a buffer from this library that was not freed yet.
#[no_mangle]
pub unsafe extern "C" fn jnv_buf_free(buf: *mut FakeBuf) {
    if !buf.is_null() {
        // SAFETY: made by jnv_open below as a Box<Owned> (the caller's contract).
        drop(unsafe { Box::from_raw(buf as *mut Owned) });
    }
}

/// # Safety
/// `err` is NULL or valid for one pointer write.
#[no_mangle]
pub unsafe extern "C" fn jnv_open(_workers: u32, err: *mut *mut FakeBuf) -> *mut FakeCtx {
    if !err.is_null() {
        let data = b"fake library: no worker pool".to_vec();
        let head = FakeBuf { ptr: data.as_ptr(), len: data.len() };
        let buf = Box::into_raw(Box::new(Owned { head, data })) as *mut FakeBuf;
        // SAFETY: valid for a write (the caller's contract).
        unsafe { *err = buf };
    }
    null_mut()
}

/// # Safety
/// Never reads `ctx`.
#[no_mangle]
pub unsafe extern "C" fn jnv_wake_fd(_ctx: *mut FakeCtx) -> i32 {
    -1
}

/// # Safety
/// Never reads `ctx`.
#[no_mangle]
pub unsafe extern "C" fn jnv_workers(_ctx: *const FakeCtx) -> u32 {
    0
}

/// # Safety
/// Never reads `ctx`.
#[no_mangle]
pub unsafe extern "C" fn jnv_close(_ctx: *mut FakeCtx) {}

/// # Safety
/// `out` is NULL or valid for one pointer write.
#[no_mangle]
pub unsafe extern "C" fn jnv_call(
    _ctx: *mut FakeCtx,
    _kind: u32,
    _data: *const c_char,
    _len: usize,
    out: *mut *mut FakeBuf,
) -> i32 {
    if !out.is_null() {
        // SAFETY: valid for a write (the caller's contract).
        unsafe { *out = null_mut() };
    }
    EINVAL
}

/// # Safety
/// Never reads its pointers.
#[no_mangle]
pub unsafe extern "C" fn jnv_submit(
    _ctx: *mut FakeCtx,
    _kind: u32,
    _flags: u32,
    _data: *const c_char,
    _len: usize,
    _job: *mut u64,
) -> i32 {
    EINVAL
}

/// # Safety
/// Never reads `ctx`.
#[no_mangle]
pub unsafe extern "C" fn jnv_cancel(_ctx: *mut FakeCtx, _job: u64) -> i32 {
    ENOJOB
}

/// # Safety
/// Never reads its pointers.
#[no_mangle]
pub unsafe extern "C" fn jnv_poll(_ctx: *mut FakeCtx, _out: *mut FakeDone, _cap: usize) -> usize {
    0
}
