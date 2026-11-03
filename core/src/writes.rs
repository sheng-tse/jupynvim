// Writes to the user's files that the backend's exit waits for.
//
// A notebook save, a file write, or a file browser's mkdir, rename or
// removal (a recursive one included) that is running when the backend
// begins to exit (stdin closed, SIGTERM, SIGHUP) is finished before the
// process ends, so no file is left cut short and no tree half removed:
// each such change holds the gate while it runs, and the exit closes the
// gate, then waits until no change holds it (up to a limit). A change asked
// for once the gate is closed is refused. Everything else still running at
// exit is dropped after a short grace (main.rs).

use parking_lot::{Condvar, Mutex};
use std::time::{Duration, Instant};

pub struct Gate {
    state: Mutex<GateState>,
    idle: Condvar,
}

struct GateState {
    /// writes running now
    running: usize,
    /// set by close(): no write starts any more
    closed: bool,
}

/// One write in progress; the gate counts it until it is dropped.
pub struct Hold<'a> {
    gate: &'a Gate,
}

impl Gate {
    pub const fn new() -> Gate {
        Gate { state: Mutex::new(GateState { running: 0, closed: false }), idle: Condvar::new() }
    }

    /// A write may start: Some while the gate is open, None once the exit
    /// has begun.
    pub fn hold(&self) -> Option<Hold<'_>> {
        let mut s = self.state.lock();
        if s.closed {
            return None;
        }
        s.running += 1;
        Some(Hold { gate: self })
    }

    /// Closes the gate, then waits until no write runs or `limit` has
    /// passed. Returns how many writes still run.
    pub fn close(&self, limit: Duration) -> usize {
        let deadline = Instant::now() + limit;
        let mut s = self.state.lock();
        s.closed = true;
        while s.running > 0 {
            if self.idle.wait_until(&mut s, deadline).timed_out() {
                break;
            }
        }
        s.running
    }
}

impl Drop for Hold<'_> {
    fn drop(&mut self) {
        let mut s = self.gate.state.lock();
        s.running -= 1;
        if s.running == 0 {
            self.gate.idle.notify_all();
        }
    }
}

static GATE: Gate = Gate::new();

/// Called by a write to the user's files before it starts; keep the result
/// until the write has ended. None: the backend is exiting, do not write.
pub fn hold() -> Option<Hold<'static>> {
    GATE.hold()
}

/// The exit: no write starts from now on, and the ones running are waited
/// for, up to `limit`. Returns how many still run.
pub fn close(limit: Duration) -> usize {
    GATE.close(limit)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{Duration, Instant};

    /// A gate that lives as long as the test process (threads borrow it).
    fn gate() -> &'static Gate {
        Box::leak(Box::new(Gate::new()))
    }

    // W1: with no write running, the exit does not wait
    #[test]
    fn w1_no_write_no_wait() {
        let g = gate();
        let t = Instant::now();
        assert_eq!(g.close(Duration::from_secs(5)), 0);
        assert!(t.elapsed() < Duration::from_millis(100), "the exit waited {:?} with no write running", t.elapsed());
    }

    // W2: a write running when the exit begins is waited for, and no new
    // write starts while the exit waits
    #[test]
    fn w2_the_exit_waits_for_a_running_write() {
        let g = gate();
        let w = g.hold().expect("a write before the exit was refused");
        let closer = std::thread::spawn(move || {
            let t = Instant::now();
            let left = g.close(Duration::from_secs(10));
            (left, t.elapsed())
        });
        // once the exit has begun, a new write is refused
        let deadline = Instant::now() + Duration::from_secs(5);
        while g.hold().is_some() {
            assert!(Instant::now() < deadline, "writes were still allowed 5 s after the exit began");
            std::thread::sleep(Duration::from_millis(1));
        }
        std::thread::sleep(Duration::from_millis(300));
        assert!(!closer.is_finished(), "the exit did not wait for the write still running");
        drop(w);
        let (left, took) = closer.join().unwrap();
        assert_eq!(left, 0, "a write was counted as still running after it ended");
        assert!(took >= Duration::from_millis(300) && took < Duration::from_secs(5), "the exit took {took:?}");
        assert!(g.hold().is_none(), "a write was allowed after the exit");
    }

    // W3: the wait is bounded: a write that never ends holds the exit up
    // only until the limit, and is reported
    #[test]
    fn w3_the_wait_is_bounded() {
        let g = gate();
        let _w = g.hold().unwrap();
        let _w2 = g.hold().unwrap();
        let t = Instant::now();
        assert_eq!(g.close(Duration::from_millis(200)), 2, "the writes still running were not counted");
        let took = t.elapsed();
        assert!(took >= Duration::from_millis(200) && took < Duration::from_secs(2), "the exit waited {took:?}");
    }

    // W4: every write ended counts once, also when they end on other
    // threads at the same time
    #[test]
    fn w4_many_writes_on_many_threads() {
        let g = gate();
        let threads: Vec<_> = (0..8)
            .map(|_| {
                std::thread::spawn(move || {
                    for _ in 0..1000 {
                        let w = g.hold().expect("a write was refused before the exit");
                        drop(w);
                    }
                })
            })
            .collect();
        for t in threads {
            t.join().unwrap();
        }
        let t = Instant::now();
        assert_eq!(g.close(Duration::from_secs(5)), 0);
        assert!(t.elapsed() < Duration::from_millis(100), "the count did not come back to 0");
    }
}
