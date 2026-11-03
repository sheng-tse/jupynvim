//! The C ABI types and constants of `include/jupynvim.h`, and the result
//! buffers handed to the caller.
//!
//! Every value here mirrors the header. Adding a constant bumps
//! [`ABI_MINOR`]; changing or removing one bumps [`ABI_MAJOR`].

use std::sync::atomic::{AtomicU64, Ordering};

/// ABI major version: a loader requires an equal major.
pub const ABI_MAJOR: u32 = 1;
/// ABI minor version: a loader requires at least the minor it was built for.
pub const ABI_MINOR: u32 = 1;

// Status codes (`int32_t`), returned by functions and in `jnv_done.status`.
/// Success.
pub const OK: i32 = 0;
/// The job failed; the result holds the message.
pub const ERR: i32 = 1;
/// The job panicked; the result holds the panic message.
pub const PANIC: i32 = 2;
/// The job was cancelled; the result holds "cancelled".
pub const CANCELLED: i32 = 3;
/// An argument is invalid (NULL handle, NULL data with a length, bad flags).
pub const EINVAL: i32 = 4;
/// The job kind is not supported by this library.
pub const EKIND: i32 = 5;
/// The context is closed.
pub const ESHUTDOWN: i32 = 6;
/// No queued or running job has that id.
pub const ENOJOB: i32 = 7;

// Submit flags: a priority in the low two bits, plus option bits.
/// Work for what is on screen now; runs first.
pub const PRIO_VISIBLE: u32 = 0;
/// The default lane.
pub const PRIO_NORMAL: u32 = 1;
/// Work nobody waits for; runs last.
pub const PRIO_BACKGROUND: u32 = 2;
/// Copy the input during `jnv_submit` instead of reading it in place.
pub const FLAG_COPY: u32 = 256;
/// The bits of the flags that hold the priority (not part of the header).
pub const PRIO_MASK: u32 = 3;

// Job kinds. 0x0001 to 0x00ff are the diagnostics in `jobs`, 0x0800 to
// 0x08ff the palette's (ABI 1.1).
/// No work, no result.
pub const KIND_NOP: u32 = 1;
/// A copy of the input.
pub const KIND_ECHO: u32 = 2;
/// The wrapping u64 sum of the input bytes, little endian.
pub const KIND_BYTESUM: u32 = 3;
/// The address the job read its input from, u64 little endian.
pub const KIND_PTR: u32 = 4;
/// Sleep for a u32 little endian number of milliseconds, honoring cancel.
pub const KIND_SLEEP: u32 = 5;
/// Panic with the input in the message.
pub const KIND_PANIC: u32 = 6;
/// n bytes (u64 little endian input) where byte i is i % 251.
pub const KIND_FILL: u32 = 7;
/// Derive the palette's color tokens from a colorscheme's highlight groups
/// (text in, text out; see `palette::wire`).
pub const KIND_PALETTE: u32 = 2048;
/// The highlight groups the palette rules read and the token names, as text.
pub const KIND_PALETTE_SCHEMA: u32 = 2049;
/// `#rrggbb #rrggbb [target]` in; out, the first color if it reads on the
/// second at the target contrast, else the palette's text or canvas color.
pub const KIND_PALETTE_READABLE: u32 = 2050;

// Selectors of `jnv_sizeof`.
/// `jnv_sizeof(SIZEOF_BUF)` is the size of [`JnvBuf`].
pub const SIZEOF_BUF: u32 = 1;
/// `jnv_sizeof(SIZEOF_DONE)` is the size of [`JnvDone`].
pub const SIZEOF_DONE: u32 = 2;

/// Every enum name and value of the header, in header order.
pub const C_CONSTANTS: &[(&str, i64)] = &[
    ("JNV_OK", OK as i64),
    ("JNV_ERR", ERR as i64),
    ("JNV_PANIC", PANIC as i64),
    ("JNV_CANCELLED", CANCELLED as i64),
    ("JNV_EINVAL", EINVAL as i64),
    ("JNV_EKIND", EKIND as i64),
    ("JNV_ESHUTDOWN", ESHUTDOWN as i64),
    ("JNV_ENOJOB", ENOJOB as i64),
    ("JNV_PRIO_VISIBLE", PRIO_VISIBLE as i64),
    ("JNV_PRIO_NORMAL", PRIO_NORMAL as i64),
    ("JNV_PRIO_BACKGROUND", PRIO_BACKGROUND as i64),
    ("JNV_FLAG_COPY", FLAG_COPY as i64),
    ("JNV_KIND_NOP", KIND_NOP as i64),
    ("JNV_KIND_ECHO", KIND_ECHO as i64),
    ("JNV_KIND_BYTESUM", KIND_BYTESUM as i64),
    ("JNV_KIND_PTR", KIND_PTR as i64),
    ("JNV_KIND_SLEEP", KIND_SLEEP as i64),
    ("JNV_KIND_PANIC", KIND_PANIC as i64),
    ("JNV_KIND_FILL", KIND_FILL as i64),
    ("JNV_KIND_PALETTE", KIND_PALETTE as i64),
    ("JNV_KIND_PALETTE_SCHEMA", KIND_PALETTE_SCHEMA as i64),
    ("JNV_KIND_PALETTE_READABLE", KIND_PALETTE_READABLE as i64),
    ("JNV_SIZEOF_BUF", SIZEOF_BUF as i64),
    ("JNV_SIZEOF_DONE", SIZEOF_DONE as i64),
];

/// `jnv_buf`: bytes owned by the library until the caller frees them with
/// `jnv_buf_free`.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct JnvBuf {
    pub ptr: *const u8,
    pub len: usize,
}

/// `jnv_done`: one completion returned by `jnv_poll`. `result` is NULL when
/// the job has no result; otherwise the caller owns it.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct JnvDone {
    pub job: u64,
    pub kind: u32,
    pub status: i32,
    pub result: *mut JnvBuf,
}

/// The allocation behind every [`JnvBuf`] pointer. `head` comes first, so a
/// pointer to an `OwnedBuf` is a valid pointer to its `JnvBuf`. The Vec is
/// kept whole (no `into_boxed_slice`), so handing over a result never
/// shrinks or copies it.
#[repr(C)]
pub(crate) struct OwnedBuf {
    head: JnvBuf,
    // Never read: it owns the bytes `head` points at and frees them on drop.
    #[allow(dead_code)]
    data: Vec<u8>,
}

static LIVE: AtomicU64 = AtomicU64::new(0);

/// Hand a Vec to the caller as a `jnv_buf`. Never returns NULL; an empty Vec
/// gives a dangling, non-null, never read pointer with length 0.
pub fn buf_from_vec(data: Vec<u8>) -> *mut JnvBuf {
    let head = JnvBuf { ptr: data.as_ptr(), len: data.len() };
    let p = Box::into_raw(Box::new(OwnedBuf { head, data })) as *mut JnvBuf;
    LIVE.fetch_add(1, Ordering::Relaxed);
    p
}

/// Free a buffer made by [`buf_from_vec`]. NULL is a no-op.
///
/// # Safety
/// `p` is NULL or a pointer returned by [`buf_from_vec`] that was not freed.
pub unsafe fn buf_free(p: *mut JnvBuf) {
    if p.is_null() {
        return;
    }
    drop(Box::from_raw(p as *mut OwnedBuf));
    LIVE.fetch_sub(1, Ordering::Relaxed);
}

/// A buffer holding an error message.
pub fn error_buf(msg: &str) -> *mut JnvBuf {
    buf_from_vec(msg.as_bytes().to_vec())
}

/// Buffers handed out and not yet freed, process wide.
pub fn live() -> u64 {
    LIVE.load(Ordering::Relaxed)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::mem::{offset_of, size_of};
    use std::ptr::null_mut;
    use std::sync::Mutex;

    // The live-buffer counter is process wide; tests that read it run one at a time.
    static LIVE_LOCK: Mutex<()> = Mutex::new(());

    fn lock() -> std::sync::MutexGuard<'static, ()> {
        LIVE_LOCK.lock().unwrap_or_else(|e| e.into_inner())
    }

    #[test]
    fn struct_layout_matches_the_header() {
        assert_eq!(size_of::<JnvBuf>(), 16);
        assert_eq!(size_of::<JnvDone>(), 24);
        assert_eq!(offset_of!(JnvBuf, ptr), 0);
        assert_eq!(offset_of!(JnvBuf, len), 8);
        assert_eq!(offset_of!(JnvDone, job), 0);
        assert_eq!(offset_of!(JnvDone, kind), 8);
        assert_eq!(offset_of!(JnvDone, status), 12);
        assert_eq!(offset_of!(JnvDone, result), 16);
        assert_eq!(offset_of!(OwnedBuf, head), 0);
    }

    #[test]
    fn abi_version_is_one_one() {
        assert_eq!(ABI_MAJOR, 1);
        assert_eq!(ABI_MINOR, 1);
    }

    #[test]
    fn c_constants_list_every_header_enum() {
        let expected: &[(&str, i64)] = &[
            ("JNV_OK", OK as i64),
            ("JNV_ERR", ERR as i64),
            ("JNV_PANIC", PANIC as i64),
            ("JNV_CANCELLED", CANCELLED as i64),
            ("JNV_EINVAL", EINVAL as i64),
            ("JNV_EKIND", EKIND as i64),
            ("JNV_ESHUTDOWN", ESHUTDOWN as i64),
            ("JNV_ENOJOB", ENOJOB as i64),
            ("JNV_PRIO_VISIBLE", PRIO_VISIBLE as i64),
            ("JNV_PRIO_NORMAL", PRIO_NORMAL as i64),
            ("JNV_PRIO_BACKGROUND", PRIO_BACKGROUND as i64),
            ("JNV_FLAG_COPY", FLAG_COPY as i64),
            ("JNV_KIND_NOP", KIND_NOP as i64),
            ("JNV_KIND_ECHO", KIND_ECHO as i64),
            ("JNV_KIND_BYTESUM", KIND_BYTESUM as i64),
            ("JNV_KIND_PTR", KIND_PTR as i64),
            ("JNV_KIND_SLEEP", KIND_SLEEP as i64),
            ("JNV_KIND_PANIC", KIND_PANIC as i64),
            ("JNV_KIND_FILL", KIND_FILL as i64),
            ("JNV_KIND_PALETTE", KIND_PALETTE as i64),
            ("JNV_KIND_PALETTE_SCHEMA", KIND_PALETTE_SCHEMA as i64),
            ("JNV_KIND_PALETTE_READABLE", KIND_PALETTE_READABLE as i64),
            ("JNV_SIZEOF_BUF", SIZEOF_BUF as i64),
            ("JNV_SIZEOF_DONE", SIZEOF_DONE as i64),
        ];
        assert_eq!(C_CONSTANTS, expected);
        // The values the header spells out.
        let values: Vec<i64> = C_CONSTANTS.iter().map(|c| c.1).collect();
        assert_eq!(
            values,
            vec![0, 1, 2, 3, 4, 5, 6, 7, 0, 1, 2, 256, 1, 2, 3, 4, 5, 6, 7, 2048, 2049, 2050, 1, 2]
        );
        let mut names: Vec<&str> = C_CONSTANTS.iter().map(|c| c.0).collect();
        names.sort_unstable();
        names.dedup();
        assert_eq!(names.len(), C_CONSTANTS.len(), "duplicate names");
        assert_eq!(PRIO_MASK, 3);
    }

    #[test]
    fn buffer_round_trip_keeps_bytes_and_counts_live() {
        let _g = lock();
        let base = live();
        let mut v = Vec::with_capacity(100);
        v.extend_from_slice(&[1u8, 0, 255]);
        let data_ptr = v.as_ptr();
        let p = buf_from_vec(v);
        assert!(!p.is_null());
        assert_eq!(live(), base + 1);
        unsafe {
            assert_eq!((*p).len, 3);
            // The Vec is kept as is: no shrink, no copy.
            assert_eq!((*p).ptr, data_ptr);
            assert_eq!(std::slice::from_raw_parts((*p).ptr, (*p).len), &[1u8, 0, 255]);
            buf_free(p);
        }
        assert_eq!(live(), base);
        unsafe { buf_free(null_mut()) };
        assert_eq!(live(), base);
    }

    #[test]
    fn empty_vec_gives_a_non_null_pointer() {
        let _g = lock();
        let base = live();
        let p = buf_from_vec(Vec::new());
        assert!(!p.is_null());
        unsafe {
            assert!(!(*p).ptr.is_null());
            assert_eq!((*p).len, 0);
        }
        assert_eq!(live(), base + 1);
        unsafe { buf_free(p) };
        assert_eq!(live(), base);
    }

    #[test]
    fn error_buf_holds_the_message() {
        let _g = lock();
        let base = live();
        let p = error_buf("unknown kind 9");
        unsafe {
            assert_eq!(
                std::slice::from_raw_parts((*p).ptr, (*p).len),
                b"unknown kind 9"
            );
            buf_free(p);
        }
        assert_eq!(live(), base);
    }

    #[test]
    fn many_buffers_balance() {
        let _g = lock();
        let base = live();
        let ps: Vec<*mut JnvBuf> = (0..1000).map(|i| buf_from_vec(vec![i as u8; i])).collect();
        assert_eq!(live(), base + 1000);
        for (i, p) in ps.into_iter().enumerate() {
            unsafe {
                assert_eq!((*p).len, i);
                buf_free(p);
            }
        }
        assert_eq!(live(), base);
    }
}
