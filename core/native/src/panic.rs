//! The panic guard: no panic ever unwinds into the caller or prints.
//!
//! Every export and every worker job runs inside [`guard`]. A process-wide
//! hook, installed once, records the message of a panic raised inside a
//! guard on that thread instead of printing it (Neovim's stderr reaches the
//! terminal, so a printed panic would corrupt the screen). Outside any guard
//! the hook defers to the previous one, which only happens in a test harness.

use std::any::{Any, TypeId};
use std::cell::{Cell, RefCell};
use std::panic::{self, AssertUnwindSafe, PanicHookInfo};
use std::sync::Once;

/// What the hook recorded about the last panic it saw inside a guard on
/// this thread.
struct Record {
    /// The payload's type and text: [`guard`] uses the record only for a
    /// payload it describes.
    ty: TypeId,
    text: String,
    /// The text plus " at <file>:<line>".
    msg: String,
}

/// This thread's guards: how many are running, and whether LAST may hold
/// a record. It has no destructor, so it is always there and cheap to reach:
/// a guard on the common path (no panic) reaches it once on entry and once
/// on exit, and never reaches LAST, whose destructor makes every access pay
/// a check. Every export runs a guard, so this is on every FFI call.
struct Guards {
    depth: Cell<u32>,
    held: Cell<bool>,
}

thread_local! {
    static GUARDS: Guards = const { Guards { depth: Cell::new(0), held: Cell::new(false) } };
    static LAST: RefCell<Option<Record>> = const { RefCell::new(None) };
}

static INSTALL: Once = Once::new();

/// The payload as text, or "panic" when it is not a string.
fn payload_text(payload: &(dyn Any + Send)) -> String {
    if let Some(s) = payload.downcast_ref::<&str>() {
        (*s).to_string()
    } else if let Some(s) = payload.downcast_ref::<String>() {
        s.clone()
    } else {
        "panic".to_string()
    }
}

/// The payload's concrete type (through the vtable, not the reference's).
fn type_of(payload: &(dyn Any + Send)) -> TypeId {
    let any: &dyn Any = payload;
    any.type_id()
}

fn describe(info: &PanicHookInfo<'_>) -> Record {
    let payload = info.payload();
    let text = payload_text(payload);
    let mut msg = text.clone();
    if let Some(loc) = info.location() {
        msg.push_str(&format!(" at {}:{}", loc.file(), loc.line()));
    }
    Record { ty: type_of(payload), text, msg }
}

fn install() {
    INSTALL.call_once(|| {
        let prev = panic::take_hook();
        panic::set_hook(Box::new(move |info| {
            // try_with: the hook may run while thread locals are torn down.
            let inside = GUARDS.try_with(|g| g.depth.get() > 0).unwrap_or(false);
            if inside {
                put_last(describe(info));
            } else {
                prev(info);
            }
        }));
    });
}

/// Take what the hook recorded on this thread, if anything. Never panics:
/// LAST may be gone (thread exit) or, in theory, borrowed.
fn take_last() -> Option<Record> {
    if !GUARDS.try_with(|g| g.held.replace(false)).unwrap_or(true) {
        return None;
    }
    match LAST.try_with(|l| l.try_borrow_mut().map(|mut slot| slot.take())) {
        Ok(Ok(rec)) => rec,
        // still there, so still held
        Ok(Err(_)) => {
            let _ = GUARDS.try_with(|g| g.held.set(true));
            None
        }
        Err(_) => None,
    }
}

/// Keep a record on this thread (the hook's, or one put back). Never
/// panics, for the same reasons.
fn put_last(rec: Record) {
    let stored = LAST
        .try_with(|l| match l.try_borrow_mut() {
            Ok(mut slot) => {
                *slot = Some(rec);
                true
            }
            Err(_) => false,
        })
        .unwrap_or(false);
    if stored {
        let _ = GUARDS.try_with(|g| g.held.set(true));
    }
}

/// Run `f`, turning a panic into `Err(message)`. The message is the panic's
/// payload followed by " at <file>:<line>" where it was raised; a payload
/// the hook never saw (raised with `resume_unwind`, which runs no hook) is
/// reported as its text alone. Nothing is printed.
pub fn guard<R>(f: impl FnOnce() -> R) -> Result<R, String> {
    install();
    // A record already here belongs to an enclosing guard whose panic is
    // still unwinding: this guard runs in a destructor during that unwind.
    // It is set aside so this guard never reports it, and put back at the
    // end so the enclosing guard still reports its panic with the location.
    let held = GUARDS
        .try_with(|g| {
            g.depth.set(g.depth.get() + 1);
            g.held.get()
        })
        .unwrap_or(false);
    let saved = if held { take_last() } else { None };
    let out = match panic::catch_unwind(AssertUnwindSafe(f)) {
        Ok(v) => Ok(v),
        Err(payload) => {
            let text = payload_text(&*payload);
            // The record belongs to this payload only when it describes it: a
            // panic the guarded code caught itself leaves a record behind,
            // and a later resume_unwind must not be reported with it.
            let msg = match take_last() {
                Some(rec) if rec.ty == type_of(&*payload) && rec.text == text => rec.msg,
                _ => text,
            };
            // Dropping a payload runs its destructor, which could itself
            // panic; that must not unwind out of the guard either. It runs
            // while depth still counts this guard, so the hook stays silent.
            if let Err(again) = panic::catch_unwind(AssertUnwindSafe(move || drop(payload))) {
                std::mem::forget(again);
                let _ = take_last();
            }
            Err(msg)
        }
    };
    let held = GUARDS
        .try_with(|g| {
            g.depth.set(g.depth.get().saturating_sub(1));
            g.held.get()
        })
        .unwrap_or(false);
    // Nothing this guard leaves (the record of a panic the guarded code
    // caught itself) reaches a later guard, the enclosing one included.
    if held {
        let _ = take_last();
    }
    if let Some(rec) = saved {
        put_last(rec);
    }
    out
}

/// Guards active on this thread (tests only).
#[cfg(test)]
pub(crate) fn depth() -> u32 {
    GUARDS.try_with(|g| g.depth.get()).unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn values_pass_through() {
        assert_eq!(guard(|| 42), Ok(42));
        assert_eq!(guard(|| String::from("x")), Ok(String::from("x")));
        assert_eq!(depth(), 0);
    }

    #[test]
    fn panic_message_holds_payload_and_location() {
        let n = 7;
        let r: Result<(), String> = guard(|| panic!("boom {n}"));
        let m = r.unwrap_err();
        assert!(m.contains("boom 7"), "{m}");
        assert!(m.contains("panic.rs"), "{m}");
        assert_eq!(depth(), 0);
    }

    #[test]
    fn static_str_payload() {
        let m = guard(|| -> u8 { panic!("static text") }).unwrap_err();
        assert!(m.starts_with("static text at "), "{m}");
        assert!(m.contains("panic.rs:"), "{m}");
    }

    #[test]
    fn non_string_payload_still_reports() {
        let m = guard(|| std::panic::panic_any(5u32)).unwrap_err();
        assert!(m.starts_with("panic at "), "{m}");
        assert!(m.contains("panic.rs"), "{m}");
    }

    #[test]
    fn nested_guards() {
        let r = guard(|| {
            assert_eq!(depth(), 1);
            let inner: Result<(), String> = guard(|| {
                assert_eq!(depth(), 2);
                panic!("inner")
            });
            assert_eq!(depth(), 1);
            let m = inner.unwrap_err();
            assert!(m.contains("inner"), "{m}");
            "outer ok"
        });
        assert_eq!(r, Ok("outer ok"));

        let r: Result<(), String> = guard(|| {
            let inner = guard(|| 5);
            assert_eq!(inner, Ok(5));
            panic!("outer after inner")
        });
        let m = r.unwrap_err();
        assert!(m.contains("outer after inner"), "{m}");
        assert_eq!(depth(), 0);
    }

    #[test]
    fn a_stale_message_never_leaks_into_a_later_guard() {
        let _ = guard(|| -> () { panic!("first") });
        let m = guard(|| -> () { panic!("second") }).unwrap_err();
        assert!(m.contains("second") && !m.contains("first"), "{m}");
    }

    #[test]
    fn a_handled_inner_panic_is_not_reported_for_a_later_resume_unwind() {
        // The inner panic runs the hook (inside the guard, so it is recorded)
        // and is caught by the guarded code itself; resume_unwind then
        // unwinds without running the hook. The guard reports the payload
        // that reached it, never the handled panic's record.
        let m = guard(|| -> () {
            let _ = std::panic::catch_unwind(|| panic!("handled inside"));
            std::panic::resume_unwind(Box::new(String::from("the real one")))
        })
        .unwrap_err();
        assert_eq!(m, "the real one", "guard reported: {m}");
        // The same with a payload that is not a string.
        let m = guard(|| -> () {
            let _ = std::panic::catch_unwind(|| panic!("handled inside"));
            std::panic::resume_unwind(Box::new(5u32))
        })
        .unwrap_err();
        assert_eq!(m, "panic", "guard reported: {m}");
        // Two payloads that are not strings have the same text ("panic"):
        // their types tell them apart.
        let m = guard(|| -> () {
            let _ = std::panic::catch_unwind(|| std::panic::panic_any(1u8));
            std::panic::resume_unwind(Box::new(5u32))
        })
        .unwrap_err();
        assert_eq!(m, "panic", "guard reported: {m}");
        // And a string payload whose text only starts like the handled one.
        let m = guard(|| -> () {
            let _ = std::panic::catch_unwind(|| panic!("handled inside"));
            std::panic::resume_unwind(Box::new("handled"))
        })
        .unwrap_err();
        assert_eq!(m, "handled", "guard reported: {m}");
        assert_eq!(depth(), 0);
    }

    #[test]
    fn a_panic_after_a_handled_one_reports_its_own_location() {
        let m = guard(|| -> () {
            let _ = std::panic::catch_unwind(|| panic!("handled inside"));
            let here = line!() + 1;
            panic!("{}", format!("own {here}"))
        })
        .unwrap_err();
        let here: u32 = m.split_whitespace().nth(1).unwrap().parse().unwrap();
        assert_eq!(m, format!("own {here} at {}:{here}", file!()));
    }

    #[test]
    fn a_payload_whose_destructor_panics_never_unwinds_out() {
        struct Bomb;
        impl Drop for Bomb {
            fn drop(&mut self) {
                panic!("drop bomb");
            }
        }
        let m = guard(|| std::panic::panic_any(Bomb)).unwrap_err();
        assert!(m.starts_with("panic at "), "{m}");
        assert!(!m.contains("drop bomb"), "{m}");
        assert_eq!(depth(), 0);
        // The destructor's panic leaves nothing behind for an enclosing guard
        // whose own unwind (resume_unwind) never runs the hook.
        let m = guard(|| -> () {
            assert!(guard(|| std::panic::panic_any(Bomb)).is_err());
            std::panic::resume_unwind(Box::new(9u8))
        })
        .unwrap_err();
        assert_eq!(m, "panic");
        assert_eq!(depth(), 0);
    }

    #[test]
    fn guard_works_inside_a_thread_local_destructor() {
        use std::sync::mpsc;
        use std::time::Duration;
        struct Probe(mpsc::Sender<Result<(), String>>);
        impl Drop for Probe {
            fn drop(&mut self) {
                let r: Result<(), String> = guard(|| panic!("in tls dtor"));
                let _ = self.0.send(r);
            }
        }
        thread_local! {
            static PROBE: RefCell<Option<Probe>> = const { RefCell::new(None) };
        }
        let (tx, rx) = mpsc::channel();
        std::thread::spawn(move || {
            // Registered before LAST, so at thread exit LAST is usually torn
            // down first and the guard runs without it.
            PROBE.with(|p| *p.borrow_mut() = Some(Probe(tx)));
            assert_eq!(guard(|| 1), Ok(1));
        })
        .join()
        .unwrap();
        let r = rx.recv_timeout(Duration::from_secs(5)).expect("the destructor ran");
        let m = r.unwrap_err();
        assert!(m.contains("in tls dtor"), "{m}");
    }

    #[test]
    fn guard_called_by_a_destructor_during_unwind_keeps_the_location() {
        // The panic below is recorded, then unwinds through D's destructor,
        // which runs a guard of its own; the outer guard still reports the
        // panic with its location.
        struct D;
        impl Drop for D {
            fn drop(&mut self) {
                let _ = guard(|| 1);
            }
        }
        let m = guard(|| -> () {
            let _d = D;
            panic!("outer")
        })
        .unwrap_err();
        assert!(m.starts_with("outer at ") && m.contains("panic.rs:"), "guard reported: {m}");
        // The same when the destructor's guard catches a panic of its own.
        struct E;
        impl Drop for E {
            fn drop(&mut self) {
                assert!(guard(|| -> () { panic!("inner") }).is_err());
            }
        }
        let m = guard(|| -> () {
            let _e = E;
            panic!("outer again")
        })
        .unwrap_err();
        assert!(m.starts_with("outer again at ") && m.contains("panic.rs:"), "guard reported: {m}");
        assert_eq!(depth(), 0);
    }

    #[test]
    fn formatted_and_static_payloads_keep_their_location() {
        let x = 3;
        let m = guard(|| -> () { panic!("fmt {x}") }).unwrap_err();
        assert!(m.starts_with("fmt 3 at ") && m.contains("panic.rs:"), "{m}");
        let m = guard(|| -> () { panic!("{}", "via fmt") }).unwrap_err();
        assert!(m.starts_with("via fmt at ") && m.contains("panic.rs:"), "{m}");
        let m = guard(|| -> () { std::panic::panic_any(String::from("owned")) }).unwrap_err();
        assert!(m.starts_with("owned at ") && m.contains("panic.rs:"), "{m}");
        let s: Option<u8> = None;
        let m = guard(|| s.unwrap()).unwrap_err();
        assert!(m.contains("None") && m.contains("panic.rs:"), "{m}");
    }

    #[test]
    fn a_record_left_by_an_earlier_guard_never_reaches_a_later_one() {
        // The record of a panic the guarded code caught itself has the same
        // payload type and text as the later resume_unwind, so only clearing
        // it keeps the later guard from reporting it.
        let r = guard(|| {
            let _ = std::panic::catch_unwind(|| panic!("same text"));
            1
        });
        assert_eq!(r, Ok(1));
        let m = guard(|| -> () { std::panic::resume_unwind(Box::new("same text")) }).unwrap_err();
        assert_eq!(m, "same text", "guard reported: {m}");
        // The same when the earlier guard ran inside the later one: what it
        // leaves must not describe the enclosing guard's own unwind.
        let m = guard(|| -> () {
            let inner = guard(|| {
                let _ = std::panic::catch_unwind(|| panic!("same text"));
                1
            });
            assert_eq!(inner, Ok(1));
            std::panic::resume_unwind(Box::new("same text"))
        })
        .unwrap_err();
        assert_eq!(m, "same text", "guard reported: {m}");
        assert_eq!(depth(), 0);
    }

    #[test]
    fn depth_is_back_to_zero_on_every_thread() {
        let hs: Vec<_> = (0..8)
            .map(|i| {
                std::thread::spawn(move || {
                    for j in 0..50 {
                        let r: Result<i32, String> = guard(|| {
                            if (i + j) % 2 == 0 {
                                panic!("t{i} j{j}")
                            }
                            j
                        });
                        match r {
                            Ok(v) => assert_eq!(v, j),
                            Err(m) => assert!(m.contains(&format!("t{i} j{j}")), "{m}"),
                        }
                    }
                    depth()
                })
            })
            .collect();
        for h in hs {
            assert_eq!(h.join().unwrap(), 0);
        }
        assert_eq!(depth(), 0);
    }
}
