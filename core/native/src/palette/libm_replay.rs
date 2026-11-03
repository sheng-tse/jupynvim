//! Test machinery: the C library's answers, replayed.
//!
//! The color math takes four functions from the C library, `pow`, `atan2`,
//! `cos` and `sin`, and each rounds its last bit its own way on each
//! platform. Everything else it does (`+ - * /`, `sqrt`, `mul_add`, `%`,
//! `copysign`, rounding) is exact IEEE arithmetic, the same everywhere. So
//! the reference's bits (tests/fixtures/palette/bits.json) are a function of
//! the port and of those four functions' answers, and `bits_libm.json`
//! records the answers the reference's own C library gave: every call the
//! reference made for the 300 colors of `bits.json` and for the two colors
//! `color.rs` pins, with argument and result bits, and per color the calls
//! it makes.
//!
//! With a [`Table`] installed on a thread (see [`run`]), the wrappers in
//! `color.rs` (`pow_c`, `atan2_c`, `cos_ref`, `sin_ref`) answer from it and
//! never reach the C library. A call the table does not hold is recorded in
//! `misses` and answered with NaN, so a port that makes a call the reference
//! did not make cannot go unnoticed. The tests run on every platform and
//! prove the port is the reference's to the last bit on any C library; the
//! integration test `palette_bits` then checks this platform's own C
//! library wherever it answers the same as the recorded one.
//!
//! The calls a table is never asked are the ones CPython never makes to the
//! C library and that every C library answers exactly (C99 Annex F): a power
//! with a base of 0 or 1, a power to the 0, any argument that is not finite,
//! and `atan2` with a zero first argument.

use std::cell::RefCell;
use std::collections::{HashMap, HashSet};

use super::color::Rgb;
use super::testjson::{self, J};

/// A C library function the color math uses.
#[derive(Copy, Clone, PartialEq, Eq, Hash, Debug)]
pub(crate) enum Prim {
    Pow,
    Atan2,
    Cos,
    Sin,
}

/// A call: the function and its argument bits. `pow` is `(x, y)`, `atan2`
/// is `(y, x)`, `cos` and `sin` are `(x, 0)`.
pub(crate) type Key = (Prim, u64, u64);

/// The answers installed on a thread, with what was asked of them.
pub(crate) struct Table {
    map: HashMap<Key, u64>,
    /// The calls that were answered.
    pub(crate) used: HashSet<Key>,
    /// The calls the table did not hold, in the order they were made.
    pub(crate) misses: Vec<Key>,
}

impl Table {
    /// A table that answers exactly `entries` (call, result bits).
    pub(crate) fn new(entries: impl IntoIterator<Item = (Key, u64)>) -> Table {
        Table { map: entries.into_iter().collect(), used: HashSet::new(), misses: Vec::new() }
    }

    /// A table that holds no answer at all.
    pub(crate) fn empty() -> Table {
        Table::new([])
    }
}

thread_local! {
    static ACTIVE: RefCell<Option<Table>> = const { RefCell::new(None) };
}

/// Install `t` on this thread, run `f`, and take the table back. A panic in
/// `f` uninstalls it as well.
pub(crate) fn run<R>(t: Table, f: impl FnOnce() -> R) -> (R, Table) {
    struct Uninstall;
    impl Drop for Uninstall {
        fn drop(&mut self) {
            let _ = ACTIVE.try_with(|a| {
                if let Ok(mut a) = a.try_borrow_mut() {
                    *a = None;
                }
            });
        }
    }
    ACTIVE.with(|a| {
        let mut a = a.borrow_mut();
        assert!(a.is_none(), "a table is already installed on this thread");
        *a = Some(t);
    });
    let guard = Uninstall;
    let r = f();
    let t = ACTIVE.with(|a| a.borrow_mut().take()).expect("the installed table is still there");
    drop(guard);
    (r, t)
}

/// The recorded answer to `k`, NaN (and a recorded miss) when the table has
/// none; `None` when no table is installed on this thread.
fn answer(k: Key) -> Option<f64> {
    ACTIVE.with(|a| {
        let mut a = a.borrow_mut();
        let t = a.as_mut()?;
        Some(match t.map.get(&k) {
            Some(&v) => {
                t.used.insert(k);
                f64::from_bits(v)
            }
            None => {
                t.misses.push(k);
                f64::NAN
            }
        })
    })
}

/// The answer for `x ** y`, or `None` when the C library is to be asked:
/// no table, or a power CPython never hands to the C library (base 0 or 1,
/// exponent 0, a value that is not finite).
pub(crate) fn pow(x: f64, y: f64) -> Option<f64> {
    if x == 0.0 || x == 1.0 || y == 0.0 || !x.is_finite() || !y.is_finite() {
        return None;
    }
    answer((Prim::Pow, x.to_bits(), y.to_bits()))
}

/// As [`pow`], for `atan2(y, x)`: never a zero or non-finite `y`, never a
/// non-finite `x`.
pub(crate) fn atan2(y: f64, x: f64) -> Option<f64> {
    if y == 0.0 || !y.is_finite() || !x.is_finite() {
        return None;
    }
    answer((Prim::Atan2, y.to_bits(), x.to_bits()))
}

/// As [`pow`], for `cos(x)`: never a value that is not finite.
pub(crate) fn cos(x: f64) -> Option<f64> {
    if !x.is_finite() {
        return None;
    }
    answer((Prim::Cos, x.to_bits(), 0))
}

/// As [`cos`], for `sin(x)`.
pub(crate) fn sin(x: f64) -> Option<f64> {
    if !x.is_finite() {
        return None;
    }
    answer((Prim::Sin, x.to_bits(), 0))
}

/// One of the two colors `color.rs` pins: the way back from OKLCH.
pub(crate) struct Pinned {
    pub(crate) c: Rgb,
    /// L, C and h of the color, as bits.
    pub(crate) lch: [u64; 3],
    /// The red, green and blue channels the way back gives, as bits.
    pub(crate) rgb: [u64; 3],
    /// The entries of [`Recorded::prims`] its forward and way back calls use.
    pub(crate) p: Vec<usize>,
}

/// The contents of `bits_libm.json`.
pub(crate) struct Recorded {
    /// Every recorded call with its result bits.
    pub(crate) prims: Vec<(Key, u64)>,
    /// The 300 colors of `bits.json`, in its order, with the entries of
    /// `prims` each one's computation uses.
    pub(crate) cases: Vec<(Rgb, Vec<usize>)>,
    pub(crate) pinned: Vec<Pinned>,
}

fn hex64(v: &J, what: &str) -> u64 {
    let s = v.as_str().unwrap_or_else(|| panic!("bits_libm.json: {what} is not a string"));
    if s.len() != 16 {
        panic!("bits_libm.json: {what} is not 16 hex digits: {s:?}");
    }
    u64::from_str_radix(s, 16).unwrap_or_else(|e| panic!("bits_libm.json: {what} is not hex ({e}): {s:?}"))
}

fn color(v: &J, what: &str) -> Rgb {
    let s = v.as_str().unwrap_or_else(|| panic!("bits_libm.json: {what} is not a string"));
    super::color::parse_rgb(s).unwrap_or_else(|| panic!("bits_libm.json: {what} is not #rrggbb: {s:?}"))
}

fn indices(v: &J, n: usize, what: &str) -> Vec<usize> {
    let a = v.as_arr().unwrap_or_else(|| panic!("bits_libm.json: {what} has no list p"));
    let mut out: Vec<usize> = Vec::with_capacity(a.len());
    for i in a {
        let i = i.as_f64().unwrap_or_else(|| panic!("bits_libm.json: {what}: p holds a non-number"));
        if i < 0.0 || i.fract() != 0.0 || i as usize >= n {
            panic!("bits_libm.json: {what}: entry {i} is not one of the {n} recorded calls");
        }
        let i = i as usize;
        if out.last().is_some_and(|&l| l >= i) {
            panic!("bits_libm.json: {what}: p is not strictly increasing at {i}");
        }
        out.push(i);
    }
    out
}

fn triple(v: &J, key: &str, what: &str) -> [u64; 3] {
    let a = v.get(key).and_then(J::as_arr).unwrap_or_else(|| panic!("bits_libm.json: {what} has no list {key}"));
    if a.len() != 3 {
        panic!("bits_libm.json: {what}: {key} has {} values, not 3", a.len());
    }
    [hex64(&a[0], what), hex64(&a[1], what), hex64(&a[2], what)]
}

/// Read `tests/fixtures/palette/bits_libm.json`; any malformed entry panics
/// naming the file and the entry.
pub(crate) fn recorded() -> Recorded {
    let p = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures/palette/bits_libm.json");
    let s = std::fs::read_to_string(&p).unwrap_or_else(|e| panic!("reading {}: {e}", p.display()));
    let doc = testjson::parse(&s).unwrap_or_else(|e| panic!("{}: {e}", p.display()));
    let list = |k: &str| -> Vec<J> {
        doc.get(k)
            .and_then(J::as_arr)
            .unwrap_or_else(|| panic!("bits_libm.json has no list {k}"))
            .to_vec()
    };
    let mut prims = Vec::new();
    for (n, e) in list("prims").iter().enumerate() {
        let what = format!("prims[{n}]");
        let a = e.as_arr().unwrap_or_else(|| panic!("bits_libm.json: {what} is not a list"));
        let f = a.first().and_then(J::as_str).unwrap_or_else(|| panic!("bits_libm.json: {what} has no function"));
        let (prim, args) = match f {
            "pow" => (Prim::Pow, 2),
            "atan2" => (Prim::Atan2, 2),
            "cos" => (Prim::Cos, 1),
            "sin" => (Prim::Sin, 1),
            other => panic!("bits_libm.json: {what}: unknown function {other:?}"),
        };
        if a.len() != args + 2 {
            panic!("bits_libm.json: {what}: {f} takes {args} arguments and has {} fields", a.len() - 2);
        }
        let x = hex64(&a[1], &what);
        let y = if args == 2 { hex64(&a[2], &what) } else { 0 };
        prims.push(((prim, x, y), hex64(&a[a.len() - 1], &what)));
    }
    let mut cases = Vec::new();
    for (n, e) in list("cases").iter().enumerate() {
        let what = format!("cases[{n}]");
        let c = color(e.get("c").unwrap_or_else(|| panic!("bits_libm.json: {what} has no c")), &what);
        cases.push((c, indices(e.get("p").unwrap_or(&J::Null), prims.len(), &what)));
    }
    let mut pinned = Vec::new();
    for (n, e) in list("pinned").iter().enumerate() {
        let what = format!("pinned[{n}]");
        let c = color(e.get("c").unwrap_or_else(|| panic!("bits_libm.json: {what} has no c")), &what);
        pinned.push(Pinned {
            c,
            lch: triple(e, "lch", &what),
            rgb: triple(e, "rgb", &what),
            p: indices(e.get("p").unwrap_or(&J::Null), prims.len(), &what),
        });
    }
    Recorded { prims, cases, pinned }
}

/// A table of exactly the entries `entries` of `rec.prims`.
pub(crate) fn table(rec: &Recorded, entries: &[usize]) -> Table {
    Table::new(entries.iter().map(|&i| rec.prims[i]))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::palette::color::{contrast, lstar, oklab, oklch, oklch_to_rgb, rel_lum};

    fn fixture(name: &str) -> J {
        let p = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures/palette").join(name);
        let s = std::fs::read_to_string(&p).unwrap_or_else(|e| panic!("reading {}: {e}", p.display()));
        testjson::parse(&s).unwrap_or_else(|e| panic!("{}: {e}", p.display()))
    }

    fn bits(s: &str) -> u64 {
        u64::from_str_radix(s, 16).unwrap_or_else(|e| panic!("bad bit pattern {s}: {e}"))
    }

    fn strs<'a>(e: &'a J, key: &str, n: usize) -> Vec<&'a str> {
        let a = e.get(key).and_then(J::as_arr).unwrap_or_else(|| panic!("no list {key}"));
        assert_eq!(a.len(), n, "{key} has {n} values");
        a.iter().map(|v| v.as_str().unwrap_or_else(|| panic!("{key}: not a string"))).collect()
    }

    /// What `palette_bits` computes for one color, named: OKLab, OKLCH, the
    /// way back at a shifted lightness, relative luminance, contrast against
    /// `#222436` and CIELAB L*.
    fn computed(c: Rgb, shift: f64) -> Vec<(&'static str, usize, u64)> {
        let mut out = Vec::new();
        let lab = oklab(c);
        let lch = oklch(c);
        let back = oklch_to_rgb((lch[0] + shift).clamp(0.0, 1.0), lch[1], lch[2]);
        for (name, vals) in [("oklab", lab.to_vec()), ("oklch", lch.to_vec()), ("shifted_rgb", vec![back.r, back.g, back.b])] {
            for (i, v) in vals.into_iter().enumerate() {
                out.push((name, i, v.to_bits()));
            }
        }
        out.push(("rel_lum", 0, rel_lum(c).to_bits()));
        out.push(("contrast_222436", 0, contrast(c, Rgb(0x22, 0x24, 0x36)).to_bits()));
        out.push(("lstar", 0, lstar(c).to_bits()));
        out
    }

    /// bits.json's values for one color, in the order of [`computed`].
    fn wanted(e: &J) -> Vec<(&'static str, usize, u64)> {
        let mut out = Vec::new();
        for (name, n) in [("oklab", 3), ("oklch", 3), ("shifted_rgb", 3)] {
            for (i, s) in strs(e, name, n).into_iter().enumerate() {
                out.push((name, i, bits(s)));
            }
        }
        for name in ["rel_lum", "contrast_222436", "lstar"] {
            out.push((name, 0, bits(e.get(name).and_then(J::as_str).unwrap_or_else(|| panic!("no {name}")))));
        }
        out
    }

    /// With each color's own recorded answers (and no C library call at
    /// all) the port gives bits.json's 3,600 values to the last bit, and a
    /// color makes exactly the calls its entry lists. So the port is the
    /// reference's on any C library.
    #[test]
    fn bits_json_replays_to_the_last_bit_on_any_c_library() {
        let rec = recorded();
        let fx = fixture("bits.json");
        let cases = fx.get("cases").and_then(J::as_arr).expect("an array of cases");
        assert_eq!(cases.len(), 300, "colors in bits.json");
        assert_eq!(rec.cases.len(), 300, "colors in bits_libm.json");
        let (mut values, mut problems) = (0usize, Vec::new());
        let (mut mismatches, mut missing, mut unused) = (0usize, 0usize, 0usize);
        for (e, (rc, entries)) in cases.iter().zip(&rec.cases) {
            let name = e.get("c").and_then(J::as_str).expect("a color");
            assert_eq!(*rc, super::super::color::parse_rgb(name).expect("#rrggbb"), "same colors in the same order");
            let shift = f64::from_bits(bits(e.get("shift").and_then(J::as_str).expect("a shift")));
            let (got, t) = run(table(&rec, entries), || computed(*rc, shift));
            for ((what, i, g), (_, _, w)) in got.into_iter().zip(wanted(e)) {
                values += 1;
                if g != w {
                    mismatches += 1;
                    problems.push(format!("{name} {what} {i}: got {g:016x} want {w:016x}"));
                }
            }
            for (p, x, y) in &t.misses {
                missing += 1;
                problems.push(format!("{name} missing {p:?} {x:016x} {y:016x}"));
            }
            if t.used.len() != entries.len() {
                unused += entries.len().saturating_sub(t.used.len());
                problems.push(format!("{name} unused {} of {} entries", entries.len() - t.used.len(), entries.len()));
            }
        }
        // The library never prints, not even its tests (source_rules.rs scans
        // every file under src/), so the summary line is a value the test
        // compares: a failure shows the real numbers in its message.
        let line = format!(
            "libm replay: {} cases, {values} values, {mismatches} mismatches, {missing} missing calls, {unused} unused entries",
            cases.len()
        );
        let shown: Vec<&String> = problems.iter().take(40).collect();
        assert!(problems.is_empty(), "{line}\n{} problems (first 40):\n{shown:#?}", problems.len());
        assert_eq!(line, "libm replay: 300 cases, 3600 values, 0 mismatches, 0 missing calls, 0 unused entries");
        assert_eq!(values, 3600, "300 colors x 12 values");
    }

    /// The calls CPython never hands to the C library are never looked up.
    #[test]
    fn special_values_never_reach_the_table() {
        assert_eq!(pow(2.0, 3.0), None);
        assert_eq!(atan2(1.0, 1.0), None);
        assert_eq!(cos(0.5), None);
        assert_eq!(sin(0.5), None);
        let (r, t) = run(Table::empty(), || {
            [
                pow(0.0, 1.0 / 3.0),
                pow(1.0, 2.4),
                pow(2.0, 0.0),
                pow(f64::NAN, 2.0),
                pow(2.0, f64::INFINITY),
                atan2(0.0, -1.0),
                atan2(-0.0, 1.0),
                atan2(f64::INFINITY, 1.0),
                atan2(1.0, f64::NAN),
                cos(f64::INFINITY),
                sin(f64::NAN),
            ]
        });
        assert!(r.iter().all(Option::is_none), "{r:?}");
        assert!(t.misses.is_empty() && t.used.is_empty(), "{:?}", t.misses);
        // and the colors that only make such calls
        let ((lab, lch), t) = run(Table::empty(), || (oklab(Rgb(0, 0, 0)), oklch(Rgb(0, 0, 0))));
        assert_eq!(lab, [0.0, 0.0, 0.0]);
        assert_eq!(lch, [0.0, 0.0, 0.0]);
        assert!(t.misses.is_empty(), "{:?}", t.misses);
    }

    /// A call the table does not hold is a miss and the answer is NaN, so
    /// the result cannot be right by accident.
    #[test]
    fn a_missing_call_is_reported_and_poisons_the_result() {
        let (v, t) = run(Table::empty(), || pow(2.0, 3.0));
        assert!(v.is_some_and(f64::is_nan), "{v:?}");
        assert_eq!(t.misses, vec![(Prim::Pow, 2.0f64.to_bits(), 3.0f64.to_bits())]);
        // the way back asks for a cosine and a sine of the hue in radians
        let want = oklch_to_rgb(0.5, 0.1, 30.0);
        let (got, t) = run(Table::empty(), || oklch_to_rgb(0.5, 0.1, 30.0));
        let rad = 30.0f64.to_radians().to_bits();
        assert_eq!(t.misses, vec![(Prim::Cos, rad, 0), (Prim::Sin, rad, 0)]);
        // (the NaN a miss makes is absorbed by the clamp to the gamut, which
        // gives white; the point is that it is not the real color)
        assert_ne!([got.r.to_bits(), got.g.to_bits(), got.b.to_bits()], [want.r.to_bits(), want.g.to_bits(), want.b.to_bits()]);
    }

    /// The table is per thread: another thread, and a test running next to
    /// this one, still reach the C library.
    #[test]
    fn a_table_answers_only_its_own_thread() {
        let t = Table::new([((Prim::Cos, 0.5f64.to_bits(), 0), 1.0f64.to_bits())]);
        let (here, t) = run(t, || {
            let other = std::thread::spawn(|| cos(0.5)).join().expect("the other thread ends");
            (cos(0.5), other)
        });
        assert_eq!(here.0, Some(1.0));
        assert_eq!(here.1, None);
        assert!(t.misses.is_empty());
        assert_eq!(cos(0.5), None, "uninstalled again");
    }
}
