//! Time budgets for the math grammar: the fixture documents, the numbering
//! and macro passes, and adversarial inputs that make a naive scan of an
//! unclosed delimiter quadratic. One test measures everything in sequence, so
//! the timings never compete for the cores, and prints a table.
//!
//! Every run is timed with the CPU time of the calling thread
//! (`CLOCK_THREAD_CPUTIME_ID`), not the wall clock: the grammar is single
//! threaded and its work is the same whether the machine is idle or running a
//! hundred other jobs, but a wall clock also counts every moment the thread
//! waits for a core, and on a busy machine that is most of the time. (On a
//! machine at a load average of 35 to 167, 6 of 28 wall-clock runs of this
//! test failed on a grammar that is linear; the same runs timed in CPU time
//! stayed between 1.4 and 2.5 for a ratio that is 2 when linear.) The
//! calibration below is timed the same way.
//!
//! Every number is the minimum of several runs (the least disturbed one). An
//! adversarial case must stay under its absolute budget at 256 KiB and must
//! grow by no more than 3.0 times when doubled to 512 KiB (linear growth is
//! about 2, quadratic about 4). The ratio is the check that does not depend
//! on the machine. The two sizes are run alternately, one run of each in turn,
//! in rounds of five pairs, and each keeps its own minimum within a round, so
//! both see the same stretch of the machine: a thread that is moved to a
//! slower core, or whose caches another job is thrashing, slows the runs on
//! both sides of the ratio. The ratio of a round is its fastest large run over
//! its fastest small run, and the lowest ratio of any round counts (see
//! `paired_ratio` for why a round is not judged on the minimums of the rounds
//! before it).
//!
//! The absolute budgets are for a release build on the machine they were
//! measured on. Another machine or a slower core gets them multiplied by how
//! much slower it runs a fixed workload that has nothing to do with the
//! grammar (`Calibration`: a byte scan, small allocations and a hash map,
//! timed in the same process), and never less than the budgets as written. A
//! debug build gets three times as much. The workload is timed again before
//! each number is taken (the table prints the factor of each row), so that a
//! budget follows the speed the runs have now: a slower core slows the
//! workload and the grammar alike. It does not follow every slowdown. Under
//! load the cases A15 to A17 (crafted multi-star names, a large working set
//! full of pointers) run at about twice their time in streaks of up to 21
//! runs while the workload does not slow down (A17 at 256 KiB: a plateau of
//! 34 ms against 13 to 17 ms), and the cause is not known. Those three cases
//! get more rounds than the others (`ROUNDS_BIG`).
//!
//! A machine that is busy with other work during all the runs of a number
//! (CPU time does not remove the cache and memory contention of a neighbour)
//! inflates it, so a number over its limit is measured again, in as many
//! rounds of runs as its case allows (`ROUNDS` by default, `ROUNDS_BIG` for
//! A15 to A17), keeping the minimum. More rounds run only while a case is
//! over its limit, so a passing run costs the same whatever the count, and a
//! genuine regression stays over the limit in every round (a quadratic scan
//! misses the budgets by orders of magnitude), so the retries cost it nothing.

use jupynvim::mathgrammar::ams::{REF_BUDGET_BASE, REF_BUDGET_FACTOR};
use jupynvim::mathgrammar::{
    extract_document, extract_math, katex_newcommand, prepare_document, prepare_tex,
    prepare_tex_for, Engine, Kind, MacroScope, Math,
};
use std::collections::HashMap;
use std::hint::black_box;
use std::sync::OnceLock;
use std::time::Instant;

const FIXTURE: &str = concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../tests/fixtures/markdown/md-fixture.md"
);

/// A run longer than this many times its budget ends the repeats: the case
/// has failed already and more runs would only slow the failure report.
const GIVE_UP: f64 = 50.0;

const KIB: usize = 1024;
const RATIO_MAX: f64 = 3.0;

/// The budget of P4c to P4f at 256 KiB, in ms (twice it at 512 KiB): the level of P8 to P12, each of which reads
/// every byte a bounded number of times too (measured 3.1 ms for P4c and P4d since deviation D9 keeps what the engines
/// do not see in the rows, 1.8 and 1.9 ms before).
const PERF_D7_MS: f64 = 6.0;
/// P10's budget at 256 KiB, in ms on the machine the budgets were measured on (the one at 512 KiB is twice it):
/// 6 ms, as P9's, the budget of the plan (section 5).
const BUDGET_P10_SMALL: f64 = 6.0;
/// P11's budget at 256 KiB, in ms (twice it at 512 KiB): the level of P9 and P10, since the rule reads every byte
/// of the line-terminator `\verb` tokens a bounded number of times.
const BUDGET_P11_SMALL: f64 = 6.0;
/// P12's budget at 256 KiB, in ms (twice it at 512 KiB), for both rows: the same level.
const BUDGET_P12_SMALL: f64 = 6.0;

/// Rounds of runs a number gets while it is over its limit.
const ROUNDS: usize = 4;

/// Rounds for the cases whose runs show a slow mode that the calibration does
/// not follow (A15 to A17, see the module documentation).
const ROUNDS_BIG: usize = 8;

/// A debug build (the workspace's dev profile, opt-level 1) runs this code
/// about one and a half times slower than a release build.
fn scale() -> f64 {
    if cfg!(debug_assertions) {
        3.0
    } else {
        1.0
    }
}

/// The calibration workload's time on the machine the budgets were measured on
/// (an Apple M3 Max), in milliseconds, for a release and for a debug build.
const NOMINAL_CALIBRATION_MS: f64 = 0.46;
const NOMINAL_CALIBRATION_DEBUG_MS: f64 = 0.58;

/// The most the budgets are stretched for a slow machine. Past it a number is
/// a real regression or a machine too slow to measure anything.
const MAX_FACTOR: f64 = 8.0;

/// Milliseconds on the clock every run is timed with: the CPU time the
/// calling thread has used (user and system), so the time it waits for a core
/// is not counted. Only the difference of two readings means anything. Where
/// the platform has no such clock the wall clock stands in (the readings of
/// one run all come from the same clock).
fn now_ms() -> f64 {
    static CPU_CLOCK: OnceLock<bool> = OnceLock::new();
    static START: OnceLock<Instant> = OnceLock::new();
    if *CPU_CLOCK.get_or_init(|| thread_cpu_ms().is_some()) {
        if let Some(ms) = thread_cpu_ms() {
            return ms;
        }
    }
    START.get_or_init(Instant::now).elapsed().as_secs_f64() * 1000.0
}

/// The calling thread's CPU time in milliseconds, or `None` without the clock.
fn thread_cpu_ms() -> Option<f64> {
    let mut ts = libc::timespec {
        tv_sec: 0,
        tv_nsec: 0,
    };
    // SAFETY: `ts` is a valid `timespec` for `clock_gettime` to write.
    let rc = unsafe { libc::clock_gettime(libc::CLOCK_THREAD_CPUTIME_ID, &mut ts) };
    (rc == 0).then(|| ts.tv_sec as f64 * 1000.0 + ts.tv_nsec as f64 / 1e6)
}

/// How long `f` takes on the clock of `now_ms`, in milliseconds.
fn time_ms<F: FnMut()>(f: &mut F) -> f64 {
    let t = now_ms();
    f();
    now_ms() - t
}

/// A fixed workload of the kind the grammar does, independent of it: a scan
/// over bytes with a data dependent branch, a few thousand small strings and a
/// hash map of them. Returns a value that depends on all of it.
fn calibration_workload(bytes: &[u8], words: &[String]) -> usize {
    let mut counts = [0usize; 4];
    let mut depth = 0i64;
    for &b in bytes {
        match b {
            b'\\' => counts[0] += 1,
            b'{' => {
                depth += 1;
                counts[1] += 1;
            }
            b'}' => {
                depth -= 1;
                counts[2] += 1;
            }
            b'\n' if depth > 0 => counts[3] += 2,
            _ => counts[3] += usize::from(b > b'm'),
        }
    }
    let mut map: HashMap<String, usize> = HashMap::new();
    for (i, w) in words.iter().enumerate() {
        let mut key = String::with_capacity(w.len() + 8);
        key.push_str("\\ref{");
        key.push_str(w);
        key.push('}');
        *map.entry(key).or_insert(0) += i;
    }
    counts.iter().sum::<usize>() + map.len() + depth.unsigned_abs() as usize
}

/// The calibration workload and its inputs, built once.
struct Calibration {
    bytes: Vec<u8>,
    words: Vec<String>,
}

impl Calibration {
    fn new() -> Self {
        let mut state = 0x2545_f491_4f6c_dd1du64;
        let mut next = move || {
            state ^= state << 13;
            state ^= state >> 7;
            state ^= state << 17;
            state
        };
        let alphabet = b"abcdefghijklmnopqrstuvwxyz{}\\\n  ";
        let bytes: Vec<u8> = (0..256 * KIB)
            .map(|_| alphabet[(next() % alphabet.len() as u64) as usize])
            .collect();
        let words: Vec<String> = (0..4000)
            .map(|i| letters(i + (next() % 7) as usize))
            .collect();
        Calibration { bytes, words }
    }

    /// How much slower than the reference machine this one runs the workload
    /// right now, at least 1 and at most `MAX_FACTOR`: the fastest of many
    /// runs, so a busy moment does not count; and that fastest time. It is
    /// measured again before each number is taken, so that a budget follows
    /// the speed the runs have now: a slower core slows this workload and the
    /// grammar alike. It cannot follow a slowdown that only the large cases
    /// show: under load A15 to A17 run at about twice their time in streaks of
    /// up to 21 runs while this workload does not slow down, which is why
    /// those cases get more rounds (`ROUNDS_BIG`).
    fn measure(&self) -> (f64, f64) {
        let mut best = f64::MAX;
        for _ in 0..25 {
            best = best.min(time_ms(&mut || {
                black_box(calibration_workload(
                    black_box(&self.bytes),
                    black_box(&self.words),
                ));
            }));
        }
        let nominal = if cfg!(debug_assertions) {
            NOMINAL_CALIBRATION_DEBUG_MS
        } else {
            NOMINAL_CALIBRATION_MS
        };
        ((best / nominal).clamp(1.0, MAX_FACTOR), best)
    }

    /// The factor every budget is multiplied by: the debug scale and the machine factor of now.
    fn k(&self) -> f64 {
        scale() * self.measure().0
    }
}

/// One line of the table: the number (`not run` for a run that was never
/// made, which `paired_ratio` reports as `f64::MAX`), its budget, the ratio (or
/// `-`) and the factor the budget was stretched by.
fn row(name: &str, size: usize, ms: f64, budget: f64, ratio: &str, k: f64) {
    let time = if ms < f64::MAX {
        format!("{ms:.3}")
    } else {
        "not run".to_string()
    };
    println!(
        "{:<36} {:>9} {:>10} {:>10.3} {:>7} {:>7.2}",
        name,
        size,
        time,
        budget,
        ratio,
        k / scale()
    );
}

/// The fastest of `runs` runs of `f`, in milliseconds, starting from `best`;
/// it stops after the first run that is more than `GIVE_UP` times `budget_ms`.
fn fastest<F: FnMut()>(runs: usize, budget_ms: f64, best: f64, f: &mut F) -> f64 {
    let mut best = best;
    for _ in 0..runs {
        let ms = time_ms(f);
        best = best.min(ms);
        if ms > budget_ms * GIVE_UP {
            break;
        }
    }
    best
}

/// The fastest of `runs` runs each of `small` and `large` in milliseconds,
/// run alternately (one of each in turn) so that both see the same stretch
/// of the machine; it stops after the first run that is more than `GIVE_UP`
/// times its budget.
fn fastest_pair<S: FnMut(), L: FnMut()>(
    runs: usize,
    budgets: (f64, f64),
    small: &mut S,
    large: &mut L,
) -> (f64, f64) {
    let (mut t_small, mut t_large) = (f64::MAX, f64::MAX);
    for _ in 0..runs {
        let ms = time_ms(small);
        t_small = t_small.min(ms);
        if ms > budgets.0 * GIVE_UP {
            break;
        }
        let ms = time_ms(large);
        t_large = t_large.min(ms);
        if ms > budgets.1 * GIVE_UP {
            break;
        }
    }
    (t_small, t_large)
}

/// What `paired_ratio` measured.
struct Pair {
    /// The fastest run of the smaller input over all rounds, in milliseconds.
    small: f64,
    /// The fastest run of the larger input over all rounds.
    large: f64,
    /// The lowest ratio of the larger over the smaller of any one round.
    ratio: f64,
}

impl Pair {
    /// Whether the larger input was run at all: `paired_ratio` makes no run
    /// of it once a run of the smaller one is more than `GIVE_UP` times its
    /// budget, and then `large` and `ratio` hold no measurement.
    fn large_ran(&self) -> bool {
        self.large < f64::MAX
    }

    /// The one failure line for a larger input that was not run: the test
    /// fails whenever that happens, and says why in place of printing the
    /// placeholder as a time and a ratio.
    fn not_run_failure(&self, name: &str, small_budget: f64, large_kib: usize) -> String {
        format!(
            "{name} made no run at {large_kib} KiB: the run of the smaller input took {:.3} ms, over {GIVE_UP} times its budget {small_budget:.3} ms",
            self.small
        )
    }
}

/// `runs` runs each of `small` and `large`, run alternately, as a round; the
/// ratio of a round is its fastest large run over its fastest small run. While
/// no round has a ratio within `RATIO_MAX` (and, with `absolute`, while either
/// fastest run over all rounds is over its budget): up to `rounds` rounds.
///
/// A round is judged on its own, not on the minimums of all rounds so far:
/// when the speed of the runs changes halfway through a round (under load
/// A15 to A17 run at about twice their time in streaks of up to 21 runs), the
/// small input can get one run before the change and the large one none;
/// keeping that fast run would hold the ratio over the limit in every later
/// round. A quadratic scan has a ratio of 4 in every round (and misses the
/// absolute budget of the smaller input by orders of magnitude first).
fn paired_ratio<S: FnMut(), L: FnMut()>(
    runs: usize,
    rounds: usize,
    budgets: (f64, f64),
    absolute: bool,
    mut small: S,
    mut large: L,
) -> Pair {
    let mut pair = Pair {
        small: f64::MAX,
        large: f64::MAX,
        ratio: f64::MAX,
    };
    for _ in 0..rounds {
        let (s, l) = fastest_pair(runs, budgets, &mut small, &mut large);
        pair.small = pair.small.min(s);
        pair.large = pair.large.min(l);
        pair.ratio = pair.ratio.min(l / s.max(1e-6));
        let within = !absolute || (pair.small <= budgets.0 && pair.large <= budgets.1);
        let spent = pair.small > budgets.0 * GIVE_UP || pair.large > budgets.1 * GIVE_UP;
        if (pair.ratio <= RATIO_MAX && within) || spent {
            break;
        }
    }
    pair
}

/// The fastest of `runs` runs of `f` in milliseconds; while that is over
/// `budget_ms`, up to `rounds` rounds of `runs` runs in all (none after a
/// run that is more than `GIVE_UP` times the budget).
fn min_ms<F: FnMut()>(runs: usize, rounds: usize, budget_ms: f64, mut f: F) -> f64 {
    let mut best = f64::MAX;
    for _ in 0..rounds {
        best = fastest(runs, budget_ms, best, &mut f);
        if best <= budget_ms || best > budget_ms * GIVE_UP {
            break;
        }
    }
    best
}

fn fixture() -> String {
    std::fs::read_to_string(FIXTURE).unwrap_or_else(|e| panic!("reading {FIXTURE}: {e}"))
}

/// `unit` repeated until the text holds at least `size` bytes.
fn repeat_to(unit: &str, size: usize) -> String {
    let mut s = String::with_capacity(size + unit.len());
    while s.len() < size {
        s.push_str(unit);
    }
    s
}

/// 0, 1, ..., 25, 26, ... as `a`, `b`, ..., `z`, `aa`, `ab`, ... (base 26,
/// letters only).
fn letters(mut i: usize) -> String {
    let mut v = Vec::new();
    loop {
        v.push(b'a' + (i % 26) as u8);
        i /= 26;
        if i == 0 {
            break;
        }
        i -= 1;
    }
    v.reverse();
    String::from_utf8(v).unwrap_or_default()
}

/// One adversarial family: a name, the text at a size, and the count of
/// maths the text must hold (the shape of each family finds none, which
/// proves the case measures the failing path and not a quick success).
struct Case {
    name: &'static str,
    build: fn(usize) -> String,
    /// The budget at 256 KiB in a release build on the reference machine.
    budget_ms: f64,
    /// Rounds of runs the case gets while it is over its limit.
    rounds: usize,
}

/// `\( a ` repeated: no close ever.
fn a1(size: usize) -> String {
    repeat_to("\\( a ", size)
}

fn a2(size: usize) -> String {
    repeat_to("\\[ a ", size)
}

fn a3(size: usize) -> String {
    repeat_to("\\\\( a ", size)
}

/// Doubled openers each followed by a blank line, one close at the very end.
fn a4(size: usize) -> String {
    let mut s = repeat_to("\\\\( a\n\n", size);
    s.push_str("\\\\)");
    s
}

fn a5(size: usize) -> String {
    repeat_to("\\begin{x} a ", size)
}

/// As many `\begin{x}` (each followed by a blank line) as `\end{x}`: every
/// begin finds an end, far away, and the blank line between them rejects it.
fn a6(size: usize) -> String {
    let unit = "\\begin{x} a\n\n";
    let n = size / (unit.len() + "\\end{x}".len()) + 1;
    format!("{}{}", unit.repeat(n), "\\end{x}".repeat(n))
}

/// Environments with a different name each: none closes.
fn a7(size: usize) -> String {
    let mut s = String::with_capacity(size + 32);
    let mut i = 0;
    while s.len() < size {
        s.push_str("\\begin{");
        s.push_str(&letters(i));
        s.push_str("} a ");
        i += 1;
    }
    s
}

/// Backtick runs of length 1, 2, 3, ... in one paragraph: no run is ever
/// closed by another of its length.
fn a8(size: usize) -> String {
    let mut s = String::with_capacity(size + 64);
    let mut n = 1;
    while s.len() < size {
        s.push_str(&"`".repeat(n));
        s.push_str(" a ");
        n += 1;
    }
    s
}

fn a9(size: usize) -> String {
    repeat_to("$5 and ", size)
}

fn a10(size: usize) -> String {
    repeat_to("<a ", size)
}

/// Doubled openers on consecutive lines, the blank line only just before the
/// one close: every opener looks through all the lines below it for a blank.
fn a11(size: usize) -> String {
    let mut s = repeat_to("\\\\( a\n", size);
    s.push_str("\n\\\\)");
    s
}

/// Environments on consecutive lines, the blank line only just before the
/// first `\end{x}`: every begin finds its end behind the blank line.
fn a12(size: usize) -> String {
    let unit = "\\begin{x} a\n";
    let n = size / (unit.len() + "\\end{x}".len()) + 1;
    format!("{}\n{}", unit.repeat(n), "\\end{x}".repeat(n))
}

/// Environments with a different multi-star name each (`abc**`, a pattern
/// that matches several names): none closes. Before the names were looked up
/// in a trie, each one was tested against every distinct name of the text.
fn a13(size: usize) -> String {
    let mut s = String::with_capacity(size + 32);
    let mut i = 0;
    while s.len() < size {
        s.push_str("\\begin{");
        s.push_str(&letters(i));
        s.push_str("**} a ");
        i += 1;
    }
    s
}

/// As A13 with the stars first (`**abc`): the pattern starts with a repeating
/// atom, so a filter on a literal prefix of the pattern keeps every name.
fn a14(size: usize) -> String {
    let mut s = String::with_capacity(size + 32);
    let mut i = 0;
    while s.len() < size {
        s.push_str("\\begin{**");
        s.push_str(&letters(i));
        s.push_str("} a ");
        i += 1;
    }
    s
}

/// One name with a quarter of the text in starred atoms (`x*` + `a*` times
/// N) and one key of half of it (`x*` + `a` times M): the pattern keeps every
/// prefix of the key alive, so the walk over the trie goes the whole length
/// of the key with a state set of N / 64 words at every byte. Unbounded, that
/// is M * N / 64 word steps: 134 million at 256 KiB, four times as many at 512
/// KiB. (With a node in the trie for every byte of a key it was also a memory
/// of M * N / 8 bytes, 1 GiB at 256 KiB; the trie is path-compressed now, and
/// the time is what the work budget ends.)
fn a15(size: usize) -> String {
    format!(
        "\\begin{{x*{}}} \\begin{{x*{}}}",
        "a*".repeat(size / 4),
        "a".repeat(size / 2)
    )
}

/// Keys `x*` + a word of at most four runs (`a^i b^j a^k b^l`) in the first
/// third of the text, then distinct names `x*a*b*a*b*` + four starred letters
/// that no key holds, which match every key: the work of the names alone is
/// their number times the number of keys (about 1e9 units at 256 KiB, 4e9 at
/// 512 KiB).
fn a16(size: usize) -> String {
    let mut s = String::with_capacity(size + 64);
    let mut len = 0;
    'keys: loop {
        for a in 0..=len {
            for b in 0..=(len - a) {
                for c in 0..=(len - a - b) {
                    let d = len - a - b - c;
                    s.push_str(&format!(
                        "\\begin{{x*{}{}{}{}}} ",
                        "a".repeat(a),
                        "b".repeat(b),
                        "a".repeat(c),
                        "b".repeat(d)
                    ));
                    if s.len() > size / 3 {
                        break 'keys;
                    }
                }
            }
        }
        len += 1;
    }
    let mut j = 0;
    while s.len() < size {
        let mut name = String::from("x*a*b*a*b*");
        let mut v = j;
        for _ in 0..4 {
            name.push((b'c' + (v % 24) as u8) as char);
            name.push('*');
            v /= 24;
        }
        s.push_str(&format!("\\begin{{{name}}} "));
        j += 1;
    }
    s
}

/// One key of half the text (`x*` + `a` repeated) and many distinct names
/// (`x*a*` + two starred letters that no key holds) that each stay alive all
/// along it: every name walks the whole key, one state word per byte. Unbounded
/// that is the number of names times the length of the key, 900 million steps
/// at 256 KiB.
fn a17(size: usize) -> String {
    let mut s = String::with_capacity(size + 64);
    s.push_str("\\begin{x*");
    s.push_str(&"a".repeat(size / 2));
    s.push_str("} ");
    let mut j = 0;
    while s.len() < size {
        let (c, d) = (b'c' + (j % 24) as u8, b'c' + (j / 24 % 24) as u8);
        let e = b'c' + (j / 576 % 24) as u8;
        s.push_str(&format!(
            "\\begin{{x*a*{}*{}*{}*}} ",
            c as char, d as char, e as char
        ));
        j += 1;
    }
    s
}

const CASES: [Case; 17] = [
    Case {
        name: "A1 unclosed \\(",
        build: a1,
        budget_ms: 4.0,
        rounds: ROUNDS,
    },
    Case {
        name: "A2 unclosed \\[",
        build: a2,
        budget_ms: 4.0,
        rounds: ROUNDS,
    },
    Case {
        name: "A3 unclosed \\\\(",
        build: a3,
        budget_ms: 4.0,
        rounds: ROUNDS,
    },
    Case {
        name: "A4 \\\\( blank lines, late close",
        build: a4,
        budget_ms: 4.0,
        rounds: ROUNDS,
    },
    Case {
        name: "A5 unclosed \\begin{x}",
        build: a5,
        budget_ms: 4.0,
        rounds: ROUNDS,
    },
    Case {
        name: "A6 \\begin{x} blank lines, ends",
        build: a6,
        budget_ms: 4.0,
        rounds: ROUNDS,
    },
    Case {
        name: "A7 distinct unclosed names",
        build: a7,
        budget_ms: 4.0,
        rounds: ROUNDS,
    },
    Case {
        name: "A8 growing backtick runs",
        build: a8,
        budget_ms: 4.0,
        rounds: ROUNDS,
    },
    Case {
        name: "A9 $5 and",
        build: a9,
        budget_ms: 4.0,
        rounds: ROUNDS,
    },
    Case {
        name: "A10 unclosed <a",
        build: a10,
        budget_ms: 4.0,
        rounds: ROUNDS,
    },
    Case {
        name: "A11 \\\\( lines, late blank",
        build: a11,
        budget_ms: 4.0,
        rounds: ROUNDS,
    },
    Case {
        name: "A12 \\begin{x} lines, late blank",
        build: a12,
        budget_ms: 4.0,
        rounds: ROUNDS,
    },
    Case {
        name: "A13 distinct <letters>** names",
        build: a13,
        budget_ms: 24.0,
        rounds: ROUNDS,
    },
    Case {
        name: "A14 distinct **<letters> names",
        build: a14,
        budget_ms: 24.0,
        rounds: ROUNDS,
    },
    Case {
        name: "A15 multi-star name, deep key",
        build: a15,
        budget_ms: 22.0,
        rounds: ROUNDS_BIG,
    },
    Case {
        name: "A16 names that match every key",
        build: a16,
        budget_ms: 24.0,
        rounds: ROUNDS_BIG,
    },
    Case {
        name: "A17 many names along one long key",
        build: a17,
        budget_ms: 40.0,
        rounds: ROUNDS_BIG,
    },
];

/// The pipeline the fixture budgets measure.
fn pipeline(src: &str) -> usize {
    let ex = extract_document(&[src]);
    let doc = prepare_document(&ex, Engine::Katex);
    doc.prepared.len()
}

/// 2,000 numbered displays and 2,000 inline references to them.
fn numbering_input() -> Vec<Math> {
    let mut maths = Vec::new();
    for i in 0..2000 {
        let tex = format!("\\begin{{align}}a\\label{{l{i}}}\\\\b\\end{{align}}");
        maths.push(Math {
            raw: tex.clone(),
            tex,
            display: true,
            block: true,
            kind: Kind::Env,
        });
    }
    for i in 0..2000 {
        let tex = format!("\\eqref{{l{i}}}");
        maths.push(Math {
            raw: format!("\\({tex}\\)"),
            tex,
            display: false,
            block: false,
            kind: Kind::Paren,
        });
    }
    maths
}

/// `n` numbered displays, `multline` and `eqnarray` in turn, each labelled on a numbered row, then `n`
/// references to them: every display has its own MathJax text (deviation D6).
fn own_forms_input(n: usize) -> Vec<Math> {
    let mut maths = Vec::new();
    for i in 0..n {
        let tex = if i % 2 == 0 {
            format!("\\begin{{multline}}a\\\\b\\label{{l{i}}}\\end{{multline}}")
        } else {
            format!("\\begin{{eqnarray}}a &=& b\\label{{l{i}}}\\\\c &=& d\\end{{eqnarray}}")
        };
        maths.push(Math {
            raw: tex.clone(),
            tex,
            display: true,
            block: true,
            kind: Kind::Env,
        });
    }
    for i in 0..n {
        let tex = format!("\\eqref{{l{i}}}");
        maths.push(Math {
            raw: format!("\\({tex}\\)"),
            tex,
            display: false,
            block: false,
            kind: Kind::Paren,
        });
    }
    maths
}

/// 2,000 formulas of which every hundredth defines a macro.
fn macro_input() -> Vec<String> {
    (0..2000)
        .map(|i| {
            if i % 100 == 0 {
                format!("\\newcommand{{\\mac{}}}[1]{{#1^2}}", letters(i / 100))
            } else {
                format!("x_{i} + \\alpha \\cdot \\frac{{a}}{{b}}")
            }
        })
        .collect()
}

/// One math of `\verb` after `\verb`, each with a delimiter of its own that
/// no later character of the line repeats, on one line, of at least `size`
/// bytes: no `\verb` finds its closing delimiter, so a search for it that
/// reads to the end of the line makes the whole quadratic in the number of
/// `\verb` (32,000 of them in 256 KiB), and a definition after them is the
/// one the rule has to find.
fn verb_cell(size: usize) -> String {
    let mut s = String::with_capacity(size + 64);
    let mut c = 0x100u32;
    while s.len() < size {
        if let Some(d) = char::from_u32(c) {
            s.push_str("\\verb");
            s.push(d);
        }
        c += 1;
    }
    s.push_str("\\newcommand{\\R}{x}");
    s
}

/// One math of `\url{` after `\href{`, none of the groups ever closed, a `%` and a line end in each
/// (an address reads `%` as a character, and the line end is what a comment would stop at), of at
/// least `size` bytes, then a definition. KaTeX reads nothing after a group that is never closed, so
/// the rule reads each byte once and rewrites nothing; a scan that gave up on an unclosed group at its
/// word and went on from there would read to the end of the text for every one of them (13,000 in
/// 256 KiB) and be quadratic.
fn url_cell(size: usize) -> String {
    let mut s = String::with_capacity(size + 64);
    while s.len() < size {
        s.push_str("\\url{a%b\n\\href{c\n");
    }
    s.push_str("\\newcommand{\\R}{x}");
    s
}

/// One math of `\verb` tokens whose delimiter is a line terminator, of at least `size` bytes, then a definition. The
/// unit is `\verb<LF>ab<LF>` (a token: the text between the two line feeds) and `\verb<CR>cd<LF>` (a carriage return
/// as the delimiter meets a line feed first, so it is no token and `\verb` is a control word). The rule finds the
/// next line terminator for each of them; a search that reads on to the end of the text for the second kind, which
/// finds no closing delimiter, is quadratic in the number of units (about 16,000 in 256 KiB). The definition at the
/// end is real and is rewritten.
fn verb_line_cell(size: usize) -> String {
    let mut s = String::with_capacity(size + 64);
    while s.len() < size {
        s.push_str("\\verb\nab\n\\verb\rcd\n");
    }
    s.push_str("\\newcommand{\\R}{x}");
    s
}

/// One math of `\includegraphics` with brackets and an address after each other, of at least `size` bytes, then a
/// definition. The unit is `\includegraphics[width=1cm,%c<LF>{x}]{a%b} `: a comment in the brackets (which ends at
/// the line feed, so the `]` after the group is real), a group in them, and an address with a `%` in it. Every
/// byte is read once; the definition at the end is real and is rewritten.
fn graphics_cell(size: usize) -> String {
    let mut s = String::with_capacity(size + 64);
    while s.len() < size {
        s.push_str("\\includegraphics[width=1cm,%c\n{x}]{a%b} ");
    }
    s.push_str("\\newcommand{\\R}{x}");
    s
}

/// One math of `\includegraphics[` after each other, none of the brackets ever closed, of at least `size` bytes,
/// then a definition. The unit is `\includegraphics[a{b}%c<LF>`. KaTeX reads nothing after brackets that are never
/// closed, so the scan ends at the end of the text for the first one and the rule rewrites nothing; a scan that
/// went on from the word after them would read the rest of the text for each of them (about 11,000 in 256 KiB) and
/// be quadratic.
fn graphics_open_cell(size: usize) -> String {
    let mut s = String::with_capacity(size + 64);
    while s.len() < size {
        s.push_str("\\includegraphics[a{b}%c\n");
    }
    s.push_str("\\newcommand{\\R}{x}");
    s
}

/// One math of realistic definitions, a macro cell of a notebook, of at least
/// `size` bytes: per unit a `\newcommand` and a `\def` and a `\let` with ASCII
/// names, a body that holds `\mathbb`, `\left` and `\varphi`, a `\newcommand`
/// whose body holds a non-ASCII character, and a note after the last one.
/// Every name is distinct.
fn macro_cell(size: usize) -> String {
    let mut s = String::with_capacity(size + 256);
    let mut i = 0;
    while s.len() < size {
        let name = letters(i);
        i += 1;
        s.push_str(&format!(
            "\\newcommand{{\\Rq{name}}}{{\\mathbb{{R}}^{{n}}}} \\def\\nq{name}#1{{\\left\\lVert #1\\right\\rVert}} \\let\\pq{name}\\varphi \\newcommand{{\\Nq{name}}}{{\u{2115}}} % note\n"
        ));
    }
    s
}

/// A display with one long tag and a label, then `\ref{a}` and `\eqref{a}`
/// maths until the source (delimiters counted) holds `size` bytes: in a
/// reference that copies the tag into every reference, the prepared TeX is
/// the number of references times the length of the tag.
fn tag_blowup(size: usize, tag_len: usize) -> (Vec<Math>, usize) {
    let mut maths = Vec::new();
    let tex = format!("x \\tag{{{}}}\\label{{a}}", "T".repeat(tag_len));
    let mut bytes = tex.len() + 4;
    maths.push(Math {
        raw: format!("$${tex}$$"),
        tex,
        display: true,
        block: true,
        kind: Kind::Dollars,
    });
    let mut i = 0;
    while bytes < size {
        let tex = if i % 2 == 0 { "\\ref{a}" } else { "\\eqref{a}" };
        bytes += tex.len() + 2;
        maths.push(Math {
            raw: format!("${tex}$"),
            tex: tex.to_string(),
            display: false,
            block: false,
            kind: Kind::Dollar,
        });
        i += 1;
    }
    (maths, bytes)
}

/// What deviation D7 reads in a row of a numbered `multline`, once: a tag, a label and a skip word in a comment and
/// an escaped tag (none of them seen), then a label and a tag with a group in it (seen; the tag moves).
const D7_UNIT: &str = "% \\tag{c} \\label{c} \\nonumber\n{u\\\\tag{e}} \\label{k} \\tag{a{b}} x ";

/// One numbered `multline` of `size` bytes made of [`D7_UNIT`], with a row break after every `per_row` units (0: the
/// units are one row) and a last row `b`, then a reference to its label `k`. Returns the maths and the number of
/// units.
fn multline_cell(size: usize, per_row: usize) -> (Vec<Math>, usize) {
    let mut tex = String::from("\\begin{multline}");
    let mut units = 0;
    while tex.len() < size {
        tex.push_str(D7_UNIT);
        units += 1;
        if per_row > 0 && units % per_row == 0 {
            tex.push_str("\\\\ ");
        }
    }
    tex.push_str("\\\\ b\\end{multline}");
    let maths = vec![
        Math {
            raw: format!("$${tex}$$"),
            tex,
            display: true,
            block: true,
            kind: Kind::Dollars,
        },
        Math {
            raw: "$\\eqref{k}$".to_string(),
            tex: "\\eqref{k}".to_string(),
            display: false,
            block: false,
            kind: Kind::Dollar,
        },
    ];
    (maths, units)
}

/// What deviation D9 reads in a row of a numbered `align`, once: a comment that holds braces, a row break, a tag, a
/// label and a skip word, a row commented out on a line of its own (none of them seen), an escaped label (a row break
/// and the text `label{e}` in a group, not seen either), the near miss `\notag_` and a label the engines see; then a
/// row break with a row-spacing argument (deviation D10). Every row is numbered and its seen label refers to it; the
/// last row, the break's argument alone, is dropped.
const D9_UNIT: &str =
    "x &= y % } \\\\ \\tag{c} \\label{c} \\nonumber\n% p &= q \\\\\n{u\\\\label{e}} \\notag_ \\label{k} \\\\[2pt]\n";

/// One numbered `align` of `size` bytes made of [`D9_UNIT`] rows, then a reference to the label `k` of its last row.
/// Returns the maths and the number of rows.
fn align_cell(size: usize) -> (Vec<Math>, usize) {
    let mut tex = String::from("\\begin{align}");
    let mut units = 0;
    while tex.len() < size {
        tex.push_str(D9_UNIT);
        units += 1;
    }
    tex.push_str("\\end{align}");
    let maths = vec![
        Math {
            raw: format!("$${tex}$$"),
            tex,
            display: true,
            block: true,
            kind: Kind::Dollars,
        },
        Math {
            raw: "$\\eqref{k}$".to_string(),
            tex: "\\eqref{k}".to_string(),
            display: false,
            block: false,
            kind: Kind::Dollar,
        },
    ];
    (maths, units)
}

/// The row pair of deviation D9 (P4e): `inputs` are the 256 and the 512 KiB cells of [`align_cell`] with their
/// number of rows. Under both engines every row must be numbered, each once, what the engines do not see must stay
/// (the commented label and the escaped one in every row), each row must follow its break directly, and the reference
/// must print the last row's number; then each size is timed as P4c is.
fn d9_row(failures: &mut Vec<String>, k: f64, inputs: [(Vec<Math>, usize); 2]) {
    for (maths, rows) in &inputs {
        for engine in [Engine::Katex, Engine::MathJax] {
            let out = prepare_tex_for(maths.iter(), engine);
            let t = out.first().map(String::as_str).unwrap_or_default();
            let last = format!(" \\tag{{{rows}}}\\end{{align*}}");
            let want_ref = format!("\\text{{({rows})}}");
            // the oracle's text of a row (gen_cases.mjs json --doc on a cell of three units):
            // `x &= y % } \\ \tag{c} \label{c} \nonumber<LF>% p &= q \\<LF>{u\\label{e}} \notag_   \tag{n}`
            let numbered = t.matches("   \\tag{").count();
            let kept = t
                .matches("% } \\\\ \\tag{c} \\label{c} \\nonumber\n")
                .count();
            let escaped = t.matches("{u\\\\label{e}} \\notag_   \\tag{").count();
            let spaced = t.matches(" \\\\[2pt]\n").count();
            if !t.ends_with(&last)
                || numbered != *rows
                || kept != *rows
                || escaped != *rows
                || spaced + 1 != *rows
                || out.get(1) != Some(&want_ref)
            {
                failures.push(format!(
                    "P4e: {rows} rows, {numbered} numbered, {kept} comments and {escaped} escaped labels kept, \
                     {spaced} breaks with their argument, last row {:?}, reference {:?} ({engine:?}, {} KiB)",
                    t.get(t.len().saturating_sub(40)..),
                    out.get(1),
                    maths.first().map_or(0, |m| m.tex.len()) / KIB
                ));
            }
        }
    }
    time_prepare_pair(failures, k, "P4e", "P4e D9 align rows", PERF_D7_MS, &inputs);
}

/// What deviation D11 reads in a row, once: a label taken out from between two pairs of letters that are no control
/// word (no blank stands in its place), so the text written so far is one run of letters as long as the row.
const D11_UNIT: &str = "xy\\label{k}";

/// The second row of [`flalign_cell`]: a label taken out from between a control word and a letter and one from between
/// a row break in a group and a bracket (a blank stands in each place, deviation D11), and a `\nonumber`, so the row
/// has no tag and the MathJax text writes `\notag` there (deviation D6).
const D11_LAST_ROW: &str = " \\alpha\\label{m}b {u\\\\\\label{n}[q]} \\nonumber";

/// One numbered `flalign` of `size` bytes: a first row of [`D11_UNIT`]s, then [`D11_LAST_ROW`], then references to
/// the labels `k` and `m`. Returns the maths and the number of units.
fn flalign_cell(size: usize) -> (Vec<Math>, usize) {
    let mut tex = String::from("\\begin{flalign}");
    let mut units = 0;
    while tex.len() < size {
        tex.push_str(D11_UNIT);
        units += 1;
    }
    tex.push_str("\\\\");
    tex.push_str(D11_LAST_ROW);
    tex.push_str("\\end{flalign}");
    let mut maths = vec![Math {
        raw: format!("$${tex}$$"),
        tex,
        display: true,
        block: true,
        kind: Kind::Dollars,
    }];
    for tex in ["\\eqref{k}", "\\eqref{m}"] {
        maths.push(Math {
            raw: format!("${tex}$"),
            tex: tex.to_string(),
            display: false,
            block: false,
            kind: Kind::Dollar,
        });
    }
    (maths, units)
}

/// The row pair of deviation D11 (P4f): `inputs` are the 256 and the 512 KiB cells of [`flalign_cell`] with their
/// number of units. Under both engines the first row must be every unit's letters with nothing between them and its
/// tag, the second row must hold the two blanks of D11 and no tag, the MathJax text must be the unstarred `flalign`
/// with `\notag` on the second row (deviation D6) and the references must print (1) and (??); then each size is timed
/// as P4c is.
fn d11_row(failures: &mut Vec<String>, k: f64, inputs: [(Vec<Math>, usize); 2]) {
    for (maths, units) in &inputs {
        for engine in [Engine::Katex, Engine::MathJax] {
            let out = prepare_tex_for(maths.iter(), engine);
            let (env, notag) = match engine {
                Engine::Katex => ("flalign*", ""),
                Engine::MathJax => ("flalign", " \\notag"),
            };
            // the oracle's text of a cell of three units (gen_cases.mjs json --doc), the units repeated
            let want = format!(
                "\\begin{{{env}}}{} \\tag{{1}} \\\\ \\alpha b {{u\\\\ [q]}} {notag}\\end{{{env}}}",
                "xy".repeat(*units)
            );
            let t = out.first().map(String::as_str).unwrap_or_default();
            let refs = [out.get(1), out.get(2)];
            if t != want
                || refs
                    != [
                        Some(&"\\text{(1)}".to_string()),
                        Some(&"\\text{(??)}".to_string()),
                    ]
            {
                failures.push(format!(
                    "P4f: {units} units, text ends {:?}, want {:?}, references {refs:?} ({engine:?}, {} KiB)",
                    t.get(t.len().saturating_sub(60)..),
                    want.get(want.len().saturating_sub(60)..),
                    maths.first().map_or(0, |m| m.tex.len()) / KIB
                ));
            }
        }
    }
    time_prepare_pair(
        failures,
        k,
        "P4f",
        "P4f D11 take-outs, flalign",
        PERF_D7_MS,
        &inputs,
    );
}

/// One row pair of deviation D7 (P4c and P4d, written as P10 is): `inputs` are the 256 and the 512 KiB cells of
/// [`multline_cell`] with their number of units. Under both engines every seen tag must end on the last row (as many
/// as there are units) and the reference must print the first one's whole group (deviation D8); each size is timed
/// against its budget (`small` times the machine factor `k`, twice it at 512 KiB) and the growth from 256 to 512 KiB
/// against `RATIO_MAX`.
fn d7_row(
    failures: &mut Vec<String>,
    k: f64,
    id: &str,
    label: &str,
    small: f64,
    inputs: [(Vec<Math>, usize); 2],
) {
    for (maths, units) in &inputs {
        for engine in [Engine::Katex, Engine::MathJax] {
            let out = prepare_tex_for(maths.iter(), engine);
            let last_row = out
                .first()
                .and_then(|t| t.rsplit(" \\\\ ").next())
                .unwrap_or_default();
            let moved = last_row.matches(" \\tag{a{b}}").count();
            if moved != *units || out.get(1).map(String::as_str) != Some("\\text{(a{b})}") {
                failures.push(format!(
                    "{id}: {moved} of {units} tags on the last row, reference {:?} ({engine:?}, {} KiB)",
                    out.get(1),
                    maths.first().map_or(0, |m| m.tex.len()) / KIB
                ));
            }
        }
    }
    time_prepare_pair(failures, k, id, label, small, &inputs);
}

/// Times `prepare_tex_for` under MathJax on the 256 and the 512 KiB maths of `inputs` (the first math's TeX is the
/// size), each against its budget (`small` times the machine factor `k`, twice it at 512 KiB), and the growth from
/// 256 to 512 KiB against `RATIO_MAX` (P4c to P4f).
fn time_prepare_pair(
    failures: &mut Vec<String>,
    k: f64,
    id: &str,
    label: &str,
    small: f64,
    inputs: &[(Vec<Math>, usize); 2],
) {
    let size = |n: usize| inputs[n].0.first().map_or(0, |m| m.tex.len());
    let budgets = (small * k, small * 2.0 * k);
    let pair = paired_ratio(
        5,
        ROUNDS,
        budgets,
        true,
        || {
            black_box(prepare_tex_for(
                black_box(inputs[0].0.iter()),
                Engine::MathJax,
            ));
        },
        || {
            black_box(prepare_tex_for(
                black_box(inputs[1].0.iter()),
                Engine::MathJax,
            ));
        },
    );
    for (n, (ms, budget)) in [(pair.small, budgets.0), (pair.large, budgets.1)]
        .into_iter()
        .enumerate()
    {
        let ran = n == 0 || pair.large_ran();
        let ratio_col = if n == 1 && ran {
            format!("{:.2}", pair.ratio)
        } else {
            "-".to_string()
        };
        row(label, size(n), ms, budget, &ratio_col, k);
        if ran && ms > budget {
            failures.push(format!(
                "{id} took {ms:.3} ms at {} KiB, budget {budget:.3} ms",
                size(n) / KIB
            ));
        }
    }
    if !pair.large_ran() {
        failures.push(pair.not_run_failure(id, budgets.0, size(1) / KIB));
    } else if pair.ratio > RATIO_MAX {
        failures.push(format!(
            "{id} grew {:.2} times from 256 to 512 KiB, limit {RATIO_MAX}",
            pair.ratio
        ));
    }
}

/// One row pair of the KaTeX rule's table (P11 and P12, written as P10 is): `inputs` are the 256 and the 512 KiB
/// cell, each one math whose last part is `\newcommand{\R}{x}`. The output must be the input with that definition
/// rewritten to `\renewcommand` (`rewritten`), or the input itself, and each size is timed against its budget
/// (`small` times the machine factor `k`, twice it at 512 KiB) and the growth from 256 to 512 KiB against
/// `RATIO_MAX`.
fn rule_row(
    failures: &mut Vec<String>,
    k: f64,
    id: &str,
    label: &str,
    small: f64,
    inputs: [String; 2],
    rewritten: bool,
) {
    for t in &inputs {
        let want = if rewritten {
            t.replace("\\newcommand{\\R}{x}", "\\renewcommand{\\R}{x}")
        } else {
            t.clone()
        };
        let mut defined = std::collections::HashSet::new();
        if katex_newcommand(t, &mut defined) != want {
            let what = if rewritten {
                "is not rewritten and nothing else changes"
            } else {
                "was rewritten"
            };
            failures.push(format!(
                "{id}: the definition at the end {what} ({} KiB)",
                t.len() / KIB
            ));
        }
    }
    let budgets = (small * k, small * 2.0 * k);
    let pair = paired_ratio(
        5,
        ROUNDS,
        budgets,
        true,
        || {
            black_box(katex_newcommand(
                black_box(&inputs[0]),
                &mut std::collections::HashSet::new(),
            ));
        },
        || {
            black_box(katex_newcommand(
                black_box(&inputs[1]),
                &mut std::collections::HashSet::new(),
            ));
        },
    );
    for (n, (ms, budget)) in [(pair.small, budgets.0), (pair.large, budgets.1)]
        .into_iter()
        .enumerate()
    {
        let ran = n == 0 || pair.large_ran();
        let ratio_col = if n == 1 && ran {
            format!("{:.2}", pair.ratio)
        } else {
            "-".to_string()
        };
        row(label, inputs[n].len(), ms, budget, &ratio_col, k);
        if ran && ms > budget {
            failures.push(format!(
                "{id} took {ms:.3} ms at {} KiB, budget {budget:.3} ms",
                inputs[n].len() / KIB
            ));
        }
    }
    if !pair.large_ran() {
        failures.push(pair.not_run_failure(id, budgets.0, inputs[1].len() / KIB));
    } else if pair.ratio > RATIO_MAX {
        failures.push(format!(
            "{id} grew {:.2} times from 256 to 512 KiB, limit {RATIO_MAX}",
            pair.ratio
        ));
    }
}

#[test]
fn budgets() {
    let cal = Calibration::new();
    let (factor, calibration_ms) = cal.measure();
    let mut failures: Vec<String> = Vec::new();
    println!();
    println!(
        "calibration {calibration_ms:.3} ms, machine factor {factor:.2}, debug scale {:.1} (measured again before each number)",
        scale()
    );
    println!(
        "{:<36} {:>9} {:>10} {:>10} {:>7} {:>7}",
        "name", "size", "min_ms", "budget_ms", "ratio", "factor"
    );

    // P1: the fixture document.
    let md = fixture();
    let k = cal.k();
    let budget = 0.25 * k;
    let ms = min_ms(31, ROUNDS, budget, || {
        black_box(pipeline(black_box(&md)));
    });
    row("P1 md-fixture.md", md.len(), ms, budget, "-", k);
    if ms > budget {
        failures.push(format!("P1 took {ms:.3} ms, budget {budget:.3} ms"));
    }

    // P2: the fixture repeated to at least 5,000 lines.
    let mut big = String::new();
    while big.lines().count() < 5000 {
        if !big.is_empty() {
            big.push('\n');
        }
        big.push_str(&md);
    }
    let k = cal.k();
    let budget = 1.0 * k;
    let ms = min_ms(15, ROUNDS, budget, || {
        black_box(pipeline(black_box(&big)));
    });
    row(
        "P2 md-fixture.md to 5000 lines",
        big.len(),
        ms,
        budget,
        "-",
        k,
    );
    if ms > budget {
        failures.push(format!("P2 took {ms:.3} ms, budget {budget:.3} ms"));
    }

    // P3: the adversarial inputs at 256 KiB and 512 KiB.
    for case in &CASES {
        let small = (case.build)(256 * KIB);
        let found = extract_math(&small).maths.len();
        if found != 0 {
            failures.push(format!(
                "{} holds {found} maths: the case no longer exercises the failing scan",
                case.name
            ));
        }
        let mut run_small = || {
            black_box(extract_math(black_box(&small)));
        };
        let k = cal.k();
        let budget = case.budget_ms * k;
        let t_small = min_ms(5, case.rounds, budget, &mut run_small);
        let over = t_small > budget;
        if over {
            failures.push(format!(
                "{} took {t_small:.3} ms at {} KiB, budget {budget:.3} ms",
                case.name,
                small.len() / KIB
            ));
            row(case.name, small.len(), t_small, budget, "skipped", k);
            continue;
        }
        let large = (case.build)(512 * KIB);
        let mut run_large = || {
            black_box(extract_math(black_box(&large)));
        };
        // The two sizes again, one run of each in turn, in rounds while no round has a ratio
        // within the limit. (The 256 KiB number above is the one the budget is checked on.)
        let pair = paired_ratio(
            5,
            case.rounds,
            (budget, budget * 4.0),
            false,
            &mut run_small,
            &mut run_large,
        );
        let (t_small, t_large, ratio) = (pair.small, pair.large, pair.ratio);
        row(
            case.name,
            small.len(),
            t_small,
            budget,
            &format!("{ratio:.2}"),
            k,
        );
        println!(
            "{:<36} {:>9} {:>10.3} {:>10} {:>7}",
            "",
            large.len(),
            t_large,
            "",
            ""
        );
        if ratio > RATIO_MAX {
            failures.push(format!(
                "{} grew {ratio:.2} times from 256 to 512 KiB, limit {RATIO_MAX}",
                case.name
            ));
        }
    }

    // P4: numbering and label resolution.
    let maths = numbering_input();
    let k = cal.k();
    let budget = 2.0 * k;
    let ms = min_ms(11, ROUNDS, budget, || {
        black_box(prepare_tex(black_box(maths.iter())));
    });
    row("P4 prepare_tex 2000+2000", maths.len(), ms, budget, "-", k);
    if ms > budget {
        failures.push(format!("P4 took {ms:.3} ms, budget {budget:.3} ms"));
    }

    // P4b: the MathJax text of 2,000 and of 4,000 numbered multline and eqnarray displays with as many references
    // (deviation D6): the rows are written once and rewrapped, the references resolved once more for the MathJax
    // text. Run alternately; the time follows the count.
    let inputs = [own_forms_input(2000), own_forms_input(4000)];
    for maths in &inputs {
        let n = maths.len() / 2;
        let mj = prepare_tex_for(maths.iter(), Engine::MathJax);
        let own = mj
            .iter()
            .filter(|t| t.starts_with("\\begin{multline*}") || t.starts_with("\\begin{eqnarray*}"))
            .count();
        if own != n || mj.get(n).map(String::as_str) != Some("\\text{(1)}") {
            failures.push(format!(
                "P4b: {own} of {n} displays in their own starred form, first reference {:?}",
                mj.get(n)
            ));
        }
    }
    let k = cal.k();
    let budgets = (2.5 * k, 5.0 * k);
    let pair = paired_ratio(
        5,
        ROUNDS,
        budgets,
        true,
        || {
            black_box(prepare_tex_for(
                black_box(inputs[0].iter()),
                Engine::MathJax,
            ));
        },
        || {
            black_box(prepare_tex_for(
                black_box(inputs[1].iter()),
                Engine::MathJax,
            ));
        },
    );
    let ratio = pair.ratio;
    for (n, (ms, budget)) in [(pair.small, budgets.0), (pair.large, budgets.1)]
        .into_iter()
        .enumerate()
    {
        let ran = n == 0 || pair.large_ran();
        let ratio_col = if n == 1 && ran {
            format!("{ratio:.2}")
        } else {
            "-".to_string()
        };
        let count = inputs[n].len();
        row(
            "P4b prepare_tex_for MathJax",
            count,
            ms,
            budget,
            &ratio_col,
            k,
        );
        if ran && ms > budget {
            failures.push(format!(
                "P4b took {ms:.3} ms for {count} maths, budget {budget:.3} ms"
            ));
        }
    }
    if !pair.large_ran() {
        failures.push(format!(
            "P4b made no run of {} maths: the run of {} took {:.3} ms, over {GIVE_UP} times its budget {:.3} ms",
            inputs[1].len(),
            inputs[0].len(),
            pair.small,
            budgets.0
        ));
    } else if ratio > RATIO_MAX {
        failures.push(format!(
            "P4b grew {ratio:.2} times from 4,000 to 8,000 maths, limit {RATIO_MAX}"
        ));
    }

    // P4c and P4d (deviation D7): one numbered multline whose rows hold what D7 reads, tags in comments and after a
    // backslash, labels and tags with groups in them, every seen tag moved to the last row: the units in one row of
    // 256 and 512 KiB (P4c), and in rows of four units each (P4d). Each byte is read a bounded number of times.
    let k = cal.k();
    d7_row(
        &mut failures,
        k,
        "P4c",
        "P4c D7 one multline row",
        PERF_D7_MS,
        [multline_cell(256 * KIB, 0), multline_cell(512 * KIB, 0)],
    );
    let k = cal.k();
    d7_row(
        &mut failures,
        k,
        "P4d",
        "P4d D7 multline rows",
        PERF_D7_MS,
        [multline_cell(256 * KIB, 4), multline_cell(512 * KIB, 4)],
    );
    // P4e (deviation D9): one numbered align of 256 and 512 KiB whose rows hold what the engines do not see (comments
    // with braces, row breaks, tags, labels and skip words, rows commented out, escaped labels) beside a label they
    // see, each row after a break with its argument. The rows are split, read and written, and the leftover labels
    // read again, each byte a bounded number of times.
    let k = cal.k();
    d9_row(
        &mut failures,
        k,
        [align_cell(256 * KIB), align_cell(512 * KIB)],
    );
    // P4f (deviations D11 and D6): one numbered flalign of 256 and 512 KiB whose first row is one run of labels taken
    // out from between letters, so the text written grows as one run of letters; each take-out reads only the text
    // copied since the one before it. Its second row has the two take-outs that leave a blank and the MathJax text's
    // `\notag`.
    let k = cal.k();
    d11_row(
        &mut failures,
        k,
        [flalign_cell(256 * KIB), flalign_cell(512 * KIB)],
    );

    // P6: references to a long tag. The output is a constant times the source,
    // not the number of references times the length of the tag, and the time
    // follows it.
    // The references copy at most REF_BUDGET_FACTOR times the TeX of the maths
    // plus REF_BUDGET_BASE bytes of tag, so the output is the source, those
    // copies and the few bytes a reference adds to itself.
    let mut inputs = Vec::new();
    for size in [256 * KIB, 512 * KIB] {
        let (maths, source_bytes) = tag_blowup(size, 16 * KIB);
        let out = prepare_tex(maths.iter());
        let out_bytes: usize = out.iter().map(String::len).sum();
        let limit = (REF_BUDGET_FACTOR + 2) * source_bytes + REF_BUDGET_BASE;
        if out_bytes > limit {
            failures.push(format!(
                "P6 prepared {out_bytes} bytes from a {source_bytes} byte source at {} KiB, limit {limit}",
                size / KIB
            ));
        }
        // and the budget is used: a tag this long is copied until it is spent
        if out_bytes < 2 * source_bytes {
            failures.push(format!(
                "P6 prepared only {out_bytes} bytes from a {source_bytes} byte source: the references no longer copy the tag"
            ));
        }
        inputs.push((size, maths, source_bytes));
    }
    // linear in the size: 8 ms at 256 KiB, run alternately like the cases above
    let k = cal.k();
    let budgets = (8.0 * k, 16.0 * k);
    let pair = paired_ratio(
        5,
        ROUNDS,
        budgets,
        true,
        || {
            black_box(prepare_tex(black_box(inputs[0].1.iter())));
        },
        || {
            black_box(prepare_tex(black_box(inputs[1].1.iter())));
        },
    );
    let ratio = pair.ratio;
    for (n, (ms, budget)) in [(pair.small, budgets.0), (pair.large, budgets.1)]
        .into_iter()
        .enumerate()
    {
        let (size, _, source_bytes) = &inputs[n];
        let ran = n == 0 || pair.large_ran();
        let ratio_col = if n == 1 && ran {
            format!("{ratio:.2}")
        } else {
            "-".to_string()
        };
        row(
            "P6 refs to a long tag",
            *source_bytes,
            ms,
            budget,
            &ratio_col,
            k,
        );
        if ran && ms > budget {
            failures.push(format!(
                "P6 took {ms:.3} ms at {} KiB, budget {budget:.3} ms",
                size / KIB
            ));
        }
    }
    if !pair.large_ran() {
        failures.push(pair.not_run_failure("P6", budgets.0, inputs[1].0 / KIB));
    } else if ratio > RATIO_MAX {
        failures.push(format!(
            "P6 grew {ratio:.2} times from 256 to 512 KiB, limit {RATIO_MAX}"
        ));
    }

    // P7: distinct multi-star names at 4 MiB, sixteen times the size of the
    // cases above: the index of hundreds of thousands of names no longer fits in
    // the caches, so a time that grows faster than the size shows here and not
    // at 256 KiB (0.19 s on the reference machine, 20 times the 256 KiB time
    // for sixteen times the text).
    // (Only when nothing above has failed: a scan that is quadratic would take
    // minutes at this size, and the cases above have already named it.)
    for (name, build) in [
        ("P7 A13 at 4 MiB", a13 as fn(usize) -> String),
        ("P7 A14 at 4 MiB", a14),
    ] {
        if !failures.is_empty() {
            break;
        }
        let text = build(4096 * KIB);
        let k = cal.k();
        let budget = 450.0 * k;
        let ms = min_ms(3, ROUNDS, budget, || {
            black_box(extract_math(black_box(&text)));
        });
        row(name, text.len(), ms, budget, "-", k);
        if ms > budget {
            failures.push(format!("{name} took {ms:.3} ms, budget {budget:.3} ms"));
        }
    }

    // P5: the macro scope.
    let texts = macro_input();
    let k = cal.k();
    let budget = 1.0 * k;
    let ms = min_ms(11, ROUNDS, budget, || {
        let mut scope = MacroScope::new(Engine::Katex);
        for t in &texts {
            black_box(scope.next(black_box(t)));
        }
    });
    row("P5 MacroScope::next 2000", texts.len(), ms, budget, "-", k);
    if ms > budget {
        failures.push(format!("P5 took {ms:.3} ms, budget {budget:.3} ms"));
    }

    // P8: one math of realistic definitions (a macro cell of any size), for each
    // engine. Every definition is on the exact, cached path (ASCII names, a
    // body with `\mathbb`, `\left` and `\varphi`, a body with a non-ASCII
    // character, a note after the last one), so the scope stays followed and
    // the work is the walk plus the one check over the bytes of each
    // definition: a single linear pass. A check that rescans the math for
    // every definition is quadratic and misses the budget at once.
    for (engine, label) in [(Engine::Katex, "KaTeX"), (Engine::MathJax, "MathJax")] {
        let mut inputs = Vec::new();
        for size in [256 * KIB, 512 * KIB] {
            let text = macro_cell(size);
            // one untimed run: the scope follows all of it (a walk that stopped early would time nothing)
            let mut scope = MacroScope::new(engine);
            let r = scope.next(&text);
            if !r.affecting || scope.is_opaque() {
                failures.push(format!(
                    "P8 {label}: the {} KiB macro cell is {}, not followed",
                    size / KIB,
                    if scope.is_opaque() {
                        "opaque"
                    } else {
                        "unaffecting"
                    }
                ));
            }
            inputs.push(text);
        }
        let k = cal.k();
        let budgets = (6.0 * k, 12.0 * k);
        let pair = paired_ratio(
            5,
            ROUNDS,
            budgets,
            true,
            || {
                let mut scope = MacroScope::new(engine);
                black_box(scope.next(black_box(&inputs[0])));
            },
            || {
                let mut scope = MacroScope::new(engine);
                black_box(scope.next(black_box(&inputs[1])));
            },
        );
        // the 256 KiB number is also held to a third of its budget: a scan that is not one
        // linear pass is over it long before it is over the budget
        let target = 2.0 * k;
        let mut small = pair.small;
        for _ in 0..ROUNDS {
            if small <= target {
                break;
            }
            small = fastest(5, target, small, &mut || {
                let mut scope = MacroScope::new(engine);
                black_box(scope.next(black_box(&inputs[0])));
            });
        }
        let ratio = pair.ratio;
        for (n, (ms, budget)) in [(small, budgets.0), (pair.large, budgets.1)]
            .into_iter()
            .enumerate()
        {
            let ran = n == 0 || pair.large_ran();
            let ratio_col = if n == 1 && ran {
                format!("{ratio:.2}")
            } else {
                "-".to_string()
            };
            row(
                &format!("P8 macro cell {label}"),
                inputs[n].len(),
                ms,
                budget,
                &ratio_col,
                k,
            );
            if ran && ms > budget {
                failures.push(format!(
                    "P8 {label} took {ms:.3} ms at {} KiB, budget {budget:.3} ms",
                    inputs[n].len() / KIB
                ));
            }
        }
        if small > target {
            failures.push(format!(
                "P8 {label} took {small:.3} ms at 256 KiB, over {target:.3} ms: the scope is not one linear pass"
            ));
        }
        if !pair.large_ran() {
            failures.push(pair.not_run_failure(
                &format!("P8 {label}"),
                budgets.0,
                inputs[1].len() / KIB,
            ));
        } else if ratio > RATIO_MAX {
            failures.push(format!(
                "P8 {label} grew {ratio:.2} times from 256 to 512 KiB, limit {RATIO_MAX}"
            ));
        }
    }

    // P9: the KaTeX rule on a hostile line of `\verb`, each with a delimiter that does not come back
    // on the line. The rule reads the verbatim text of a `\verb` up to its delimiter on the same
    // line; a search that reads to the end of the line for every one that has none is quadratic,
    // so the maths below time the rule at its worst (the `\newcommand` at the end is rewritten).
    {
        let inputs = [verb_cell(256 * KIB), verb_cell(512 * KIB)];
        for t in &inputs {
            let mut defined = std::collections::HashSet::new();
            if !katex_newcommand(t, &mut defined).ends_with("\\renewcommand{\\R}{x}") {
                failures
                    .push("P9: the definition after the \\verb text is not rewritten".to_string());
            }
        }
        let k = cal.k();
        let budgets = (6.0 * k, 12.0 * k);
        let pair = paired_ratio(
            5,
            ROUNDS,
            budgets,
            true,
            || {
                black_box(katex_newcommand(
                    black_box(&inputs[0]),
                    &mut std::collections::HashSet::new(),
                ));
            },
            || {
                black_box(katex_newcommand(
                    black_box(&inputs[1]),
                    &mut std::collections::HashSet::new(),
                ));
            },
        );
        for (n, (ms, budget)) in [(pair.small, budgets.0), (pair.large, budgets.1)]
            .into_iter()
            .enumerate()
        {
            let ran = n == 0 || pair.large_ran();
            let ratio_col = if n == 1 && ran {
                format!("{:.2}", pair.ratio)
            } else {
                "-".to_string()
            };
            row(
                "P9 rule on verb text",
                inputs[n].len(),
                ms,
                budget,
                &ratio_col,
                k,
            );
            if ran && ms > budget {
                failures.push(format!(
                    "P9 took {ms:.3} ms at {} KiB, budget {budget:.3} ms",
                    inputs[n].len() / KIB
                ));
            }
        }
        if !pair.large_ran() {
            failures.push(pair.not_run_failure("P9", budgets.0, inputs[1].len() / KIB));
        } else if pair.ratio > RATIO_MAX {
            failures.push(format!(
                "P9 grew {:.2} times from 256 to 512 KiB, limit {RATIO_MAX}",
                pair.ratio
            ));
        }
    }

    // P10: the KaTeX rule on `\url{` and `\href{` after each other, none of the groups closed. KaTeX
    // reads the address of each with `%` an ordinary character and reads nothing after a group that
    // never closes, so the rule's scan of one ends at the end of the text; were it to go on from the
    // word after an unclosed group it would read the rest of the text for each of them, quadratic.
    // The definition at the end lies inside the first group and is not rewritten.
    {
        let inputs = [url_cell(256 * KIB), url_cell(512 * KIB)];
        for t in &inputs {
            let mut defined = std::collections::HashSet::new();
            if katex_newcommand(t, &mut defined) != *t {
                failures.push(
                    "P10: the definition inside the unclosed group was rewritten".to_string(),
                );
            }
        }
        let mut defined = std::collections::HashSet::new();
        if !katex_newcommand("\\url{a%b} \\newcommand{\\R}{x}", &mut defined)
            .ends_with("\\renewcommand{\\R}{x}")
        {
            failures
                .push("P10: the definition after a closed address is not rewritten".to_string());
        }
        let k = cal.k();
        let budgets = (BUDGET_P10_SMALL * k, BUDGET_P10_SMALL * 2.0 * k);
        let pair = paired_ratio(
            5,
            ROUNDS,
            budgets,
            true,
            || {
                black_box(katex_newcommand(
                    black_box(&inputs[0]),
                    &mut std::collections::HashSet::new(),
                ));
            },
            || {
                black_box(katex_newcommand(
                    black_box(&inputs[1]),
                    &mut std::collections::HashSet::new(),
                ));
            },
        );
        for (n, (ms, budget)) in [(pair.small, budgets.0), (pair.large, budgets.1)]
            .into_iter()
            .enumerate()
        {
            let ran = n == 0 || pair.large_ran();
            let ratio_col = if n == 1 && ran {
                format!("{:.2}", pair.ratio)
            } else {
                "-".to_string()
            };
            row(
                "P10 rule on unclosed \\url",
                inputs[n].len(),
                ms,
                budget,
                &ratio_col,
                k,
            );
            if ran && ms > budget {
                failures.push(format!(
                    "P10 took {ms:.3} ms at {} KiB, budget {budget:.3} ms",
                    inputs[n].len() / KIB
                ));
            }
        }
        if !pair.large_ran() {
            failures.push(pair.not_run_failure("P10", budgets.0, inputs[1].len() / KIB));
        } else if pair.ratio > RATIO_MAX {
            failures.push(format!(
                "P10 grew {:.2} times from 256 to 512 KiB, limit {RATIO_MAX}",
                pair.ratio
            ));
        }
    }

    // P11: the KaTeX rule on `\verb` tokens whose delimiter is a line terminator, the kind that is a token and
    // the kind that is none (`\verb<CR>` meets a line feed first), after each other. The definition at the end
    // is real and is rewritten.
    rule_row(
        &mut failures,
        cal.k(),
        "P11",
        "P11 rule on line-end verb",
        BUDGET_P11_SMALL,
        [verb_line_cell(256 * KIB), verb_line_cell(512 * KIB)],
        true,
    );

    // P12: the KaTeX rule on `\includegraphics` with closed brackets and addresses (a), and on brackets that
    // are never closed (b). In (a) every byte is read once and the definition at the end is rewritten; in (b)
    // the scan ends at the end of the text for the first one and nothing is rewritten.
    rule_row(
        &mut failures,
        cal.k(),
        "P12a",
        "P12a rule on closed includegraphics",
        BUDGET_P12_SMALL,
        [graphics_cell(256 * KIB), graphics_cell(512 * KIB)],
        true,
    );
    rule_row(
        &mut failures,
        cal.k(),
        "P12b",
        "P12b rule on unclosed includegraphics",
        BUDGET_P12_SMALL,
        [graphics_open_cell(256 * KIB), graphics_open_cell(512 * KIB)],
        false,
    );

    assert!(
        failures.is_empty(),
        "{} budget failures\n{}",
        failures.len(),
        failures.join("\n")
    );
}
