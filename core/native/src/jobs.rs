//! The job kinds: what a worker (or `jnv_call`) runs for a kind number.
//!
//! Kinds 0x0001 to 0x00ff are diagnostics, always built: the release check
//! and the tests use them to prove the boundary, the worker pool and the
//! wake path. Later features add their kinds in their own ranges (see the
//! header) and extend [`supported`] and [`run`].

use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use crate::abi::{
    KIND_BYTESUM, KIND_ECHO, KIND_FILL, KIND_NOP, KIND_PANIC, KIND_PTR, KIND_SLEEP,
};

/// The most bytes a FILL job makes (1 GiB).
pub const FILL_MAX: u64 = 1 << 30;

/// What a job can see besides its input.
pub struct JobCx<'a> {
    /// Set by `jnv_cancel` (or `jnv_close`) while the job runs; long jobs
    /// check it and stop with [`JobErr::Cancelled`].
    pub cancel: &'a AtomicBool,
}

/// How a job fails.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum JobErr {
    /// Status ERR with this message as the result.
    Err(String),
    /// Status CANCELLED with the message "cancelled".
    Cancelled,
}

/// Whether this library runs `kind`.
pub fn supported(kind: u32) -> bool {
    (KIND_NOP..=KIND_FILL).contains(&kind)
}

/// Run `kind` on `input`. `Ok(None)` is success without a result. Callers
/// reject unsupported kinds before this; it still answers them with an error.
pub fn run(kind: u32, input: &[u8], cx: &JobCx) -> Result<Option<Vec<u8>>, JobErr> {
    match kind {
        KIND_NOP => Ok(None),
        KIND_ECHO => copy_of(input).map(Some),
        KIND_BYTESUM => {
            let sum = input.iter().fold(0u64, |a, &b| a.wrapping_add(b as u64));
            Ok(Some(sum.to_le_bytes().to_vec()))
        }
        KIND_PTR => Ok(Some((input.as_ptr() as usize as u64).to_le_bytes().to_vec())),
        KIND_SLEEP => sleep(input, cx),
        KIND_PANIC => panic!("jnv test panic: {}", String::from_utf8_lossy(input)),
        KIND_FILL => fill(input),
        _ => Err(JobErr::Err(format!("unknown kind {kind}"))),
    }
}

/// A fallible copy: an allocation failure becomes an error, never an abort
/// of the host process.
fn copy_of(input: &[u8]) -> Result<Vec<u8>, JobErr> {
    let mut v = Vec::new();
    v.try_reserve_exact(input.len())
        .map_err(|_| JobErr::Err(format!("out of memory copying {} bytes", input.len())))?;
    v.extend_from_slice(input);
    Ok(v)
}

/// SLEEP: exactly 4 bytes, u32 LE milliseconds. Sleeps in slices of at most
/// 1 ms and checks the cancel flag before each one, so a cancel is noticed
/// within about a millisecond. The result is the milliseconds actually slept
/// (u32 LE), measured on the monotonic clock.
fn sleep(input: &[u8], cx: &JobCx) -> Result<Option<Vec<u8>>, JobErr> {
    let ms = match <[u8; 4]>::try_from(input) {
        Ok(b) => u32::from_le_bytes(b),
        Err(_) => return Err(JobErr::Err("SLEEP wants 4 bytes (u32 milliseconds)".to_string())),
    };
    let total = Duration::from_millis(ms as u64);
    let slice = Duration::from_millis(1);
    let start = Instant::now();
    let mut slept = Duration::ZERO;
    while slept < total {
        if cx.cancel.load(Ordering::Relaxed) {
            return Err(JobErr::Cancelled);
        }
        std::thread::sleep(slice.min(total - slept));
        slept = start.elapsed();
    }
    let ms_slept = u32::try_from(slept.as_millis()).unwrap_or(u32::MAX);
    Ok(Some(ms_slept.to_le_bytes().to_vec()))
}

/// FILL: exactly 8 bytes, u64 LE n with n at most [`FILL_MAX`]; the result is
/// n bytes where byte i is i % 251. One period is written, then the filled
/// prefix (always a whole number of periods) is doubled, so the work is a
/// few large copies at memory speed.
fn fill(input: &[u8]) -> Result<Option<Vec<u8>>, JobErr> {
    let n = match <[u8; 8]>::try_from(input) {
        Ok(b) => u64::from_le_bytes(b),
        Err(_) => return Err(JobErr::Err("FILL wants 8 bytes (u64 length)".to_string())),
    };
    if n > FILL_MAX {
        return Err(JobErr::Err(format!(
            "FILL wants at most 1 GiB ({FILL_MAX} bytes), got {n}"
        )));
    }
    let n = n as usize;
    let mut v = Vec::new();
    v.try_reserve_exact(n)
        .map_err(|_| JobErr::Err(format!("out of memory making {n} bytes")))?;
    let period: [u8; 251] = std::array::from_fn(|i| i as u8);
    v.extend_from_slice(&period[..n.min(period.len())]);
    while v.len() < n {
        // v.len() is a multiple of 251 here, so v[len + j] = v[j] keeps
        // byte i equal to i % 251.
        let take = v.len().min(n - v.len());
        v.extend_from_within(..take);
    }
    Ok(Some(v))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::Arc;
    use std::time::{Duration, Instant};

    fn run_free(kind: u32, input: &[u8]) -> Result<Option<Vec<u8>>, JobErr> {
        let cancel = AtomicBool::new(false);
        run(kind, input, &JobCx { cancel: &cancel })
    }

    fn u64le(v: &[u8]) -> u64 {
        u64::from_le_bytes(v.try_into().expect("8 bytes"))
    }

    #[test]
    fn supported_kinds() {
        assert!(!supported(0));
        for k in 1..=7 {
            assert!(supported(k), "{k}");
        }
        assert!(!supported(8));
        assert!(!supported(0x100));
        assert!(!supported(u32::MAX));
        assert_eq!(KIND_FILL, 7);
    }

    #[test]
    fn nop_gives_no_result() {
        assert_eq!(run_free(KIND_NOP, b"anything"), Ok(None));
        assert_eq!(run_free(KIND_NOP, b""), Ok(None));
    }

    #[test]
    fn echo_copies_the_input() {
        assert_eq!(run_free(KIND_ECHO, b"a\0b"), Ok(Some(b"a\0b".to_vec())));
        assert_eq!(run_free(KIND_ECHO, b""), Ok(Some(Vec::new())));
    }

    #[test]
    fn bytesum_is_a_wrapping_u64_le_sum() {
        let r = run_free(KIND_BYTESUM, &[1, 2, 255]).unwrap().unwrap();
        assert_eq!(r.len(), 8);
        assert_eq!(u64le(&r), 258);
        assert_eq!(u64le(&run_free(KIND_BYTESUM, b"").unwrap().unwrap()), 0);
        let big = vec![200u8; 1 << 20];
        assert_eq!(
            u64le(&run_free(KIND_BYTESUM, &big).unwrap().unwrap()),
            200 * (1 << 20)
        );
    }

    #[test]
    fn ptr_reports_the_address_read() {
        let data = vec![9u8; 64];
        let r = run_free(KIND_PTR, &data).unwrap().unwrap();
        assert_eq!(u64le(&r), data.as_ptr() as u64);
        let r = run_free(KIND_PTR, &data[5..]).unwrap().unwrap();
        assert_eq!(u64le(&r), data.as_ptr() as u64 + 5);
    }

    #[test]
    fn sleep_sleeps_and_reports_milliseconds() {
        let t = Instant::now();
        let r = run_free(KIND_SLEEP, &20u32.to_le_bytes()).unwrap().unwrap();
        let el = t.elapsed();
        assert!(el >= Duration::from_millis(20), "{el:?}");
        assert!(el < Duration::from_millis(500), "{el:?}");
        let slept = u32::from_le_bytes(r.as_slice().try_into().unwrap());
        assert!((20..500).contains(&slept), "{slept}");
        assert_eq!(run_free(KIND_SLEEP, &0u32.to_le_bytes()), Ok(Some(0u32.to_le_bytes().to_vec())));
    }

    #[test]
    fn sleep_cancelled_from_another_thread_within_50ms() {
        let cancel = Arc::new(AtomicBool::new(false));
        let c2 = cancel.clone();
        let setter = std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(20));
            let at = Instant::now();
            c2.store(true, Ordering::Relaxed);
            at
        });
        let start = Instant::now();
        let r = run(KIND_SLEEP, &5000u32.to_le_bytes(), &JobCx { cancel: &cancel });
        let done = Instant::now();
        let set_at = setter.join().unwrap();
        assert_eq!(r, Err(JobErr::Cancelled));
        let lag = done.duration_since(set_at);
        assert!(lag < Duration::from_millis(50), "noticed after {lag:?}");
        assert!(done.duration_since(start) < Duration::from_millis(1000));
    }

    #[test]
    fn sleep_with_cancel_already_set_returns_at_once() {
        let cancel = AtomicBool::new(true);
        let t = Instant::now();
        let r = run(KIND_SLEEP, &5000u32.to_le_bytes(), &JobCx { cancel: &cancel });
        assert_eq!(r, Err(JobErr::Cancelled));
        assert!(t.elapsed() < Duration::from_millis(50));
    }

    #[test]
    fn sleep_rejects_wrong_input_lengths() {
        let want = Err(JobErr::Err("SLEEP wants 4 bytes (u32 milliseconds)".to_string()));
        assert_eq!(run_free(KIND_SLEEP, b""), want);
        assert_eq!(run_free(KIND_SLEEP, &[1, 0, 0]), want);
        assert_eq!(run_free(KIND_SLEEP, &[1, 0, 0, 0, 0]), want);
    }

    #[test]
    fn panic_kind_panics_and_guard_catches_it() {
        let m = crate::panic::guard(|| run_free(KIND_PANIC, b"boom")).unwrap_err();
        assert!(m.contains("jnv test panic: boom"), "{m}");
        assert!(m.contains("jobs.rs"), "{m}");
        let m = crate::panic::guard(|| run_free(KIND_PANIC, &[0xff, b'x'])).unwrap_err();
        assert!(m.contains("jnv test panic: \u{fffd}x"), "{m}");
    }

    #[test]
    fn fill_pattern() {
        let n: u64 = 1000;
        let v = run_free(KIND_FILL, &n.to_le_bytes()).unwrap().unwrap();
        assert_eq!(v.len(), 1000);
        for i in [0usize, 1, 249, 250, 251, 252, 501, 502, 753, 999] {
            assert_eq!(v[i] as usize, i % 251, "index {i}");
        }
        assert!(v.iter().enumerate().all(|(i, &b)| b as usize == i % 251));
        let v = run_free(KIND_FILL, &(251u64 * 3).to_le_bytes()).unwrap().unwrap();
        assert_eq!(v.len(), 753);
        assert_eq!(v[752], 250);
        assert_eq!(run_free(KIND_FILL, &0u64.to_le_bytes()), Ok(Some(Vec::new())));
        let v = run_free(KIND_FILL, &1u64.to_le_bytes()).unwrap().unwrap();
        assert_eq!(v, vec![0u8]);
        let v = run_free(KIND_FILL, &(64u64 << 20).to_le_bytes()).unwrap().unwrap();
        assert_eq!(v.len(), 64 << 20);
        assert_eq!(v[12345] as usize, 12345 % 251);
        assert_eq!(v[(64 << 20) - 1] as usize, ((64 << 20) - 1) % 251);
    }

    #[test]
    fn fill_rejects_bad_input() {
        let want_len = Err(JobErr::Err("FILL wants 8 bytes (u64 length)".to_string()));
        assert_eq!(run_free(KIND_FILL, b""), want_len);
        assert_eq!(run_free(KIND_FILL, &[0; 7]), want_len);
        assert_eq!(run_free(KIND_FILL, &[0; 9]), want_len);
        let over = (1u64 << 30) + 1;
        match run_free(KIND_FILL, &over.to_le_bytes()) {
            Err(JobErr::Err(m)) => assert!(m.contains("1 GiB"), "{m}"),
            other => panic!("expected an error, got {other:?}"),
        }
        assert!(matches!(run_free(KIND_FILL, &u64::MAX.to_le_bytes()), Err(JobErr::Err(_))));
    }

    #[test]
    fn unknown_kind_is_an_error() {
        for k in [0u32, 8, 0x100, u32::MAX] {
            assert_eq!(
                run_free(k, b"x"),
                Err(JobErr::Err(format!("unknown kind {k}")))
            );
        }
    }
}
