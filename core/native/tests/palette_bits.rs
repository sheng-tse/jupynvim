//! The color math to the last bit, with this platform's own C library: for
//! 300 colors (tests/fixtures/palette/bits.json) the 64-bit patterns of
//! OKLab, OKLCH, the way back at a shifted lightness, the relative
//! luminance, the contrast against `#222436` and CIELAB L* must equal the
//! reference's. The 8-bit results the other tests pin would hide a change
//! in rounding that moves a bisection boundary only on some colors; this
//! test shows it on every one.
//!
//! The color math takes `pow`, `atan2`, `cos` and `sin` from the C library,
//! and those round their last bit differently on different platforms.
//! `bits_libm.json` holds every call the reference made with the answers its
//! C library gave. Two tests use it:
//!
//! - the unit test `palette::libm_replay::tests` answers the calls from the
//!   recorded table, so it proves the port is the reference's to the last
//!   bit on any platform;
//! - this test runs the library as built, with this platform's C library:
//!   each recorded call is asked here, and every color whose calls are all
//!   answered the same as recorded must give bits.json's values exactly.
//!   Colors that use a call this C library rounds differently cannot be
//!   checked here (the replay covers them).
//!
//! A port that is wrong fails by a value that differs, whatever the C
//! library. What the floors below guard is that the check does not pass by
//! checking nothing: a C library that is within a rounding error of the
//! reference's (every mainstream one is) must leave most colors checkable,
//! so each of the four functions must answer at least three quarters of its
//! recorded calls as recorded and at least two thirds of the colors must be
//! checked. A binding to the wrong function, swapped arguments or a lower
//! precision answers far fewer and fails them. The floors are set from
//! four versions of three C libraries (see `SAME_NUM`) and a unit test holds
//! those numbers.

#[path = "support/minijson.rs"]
mod minijson;

use std::collections::HashSet;
use std::hint::black_box;
use std::path::PathBuf;

use jupynvim::palette::color::{contrast, lstar, oklab, oklch, oklch_to_rgb, parse_rgb, rel_lum, Rgb};
use minijson::J;

// The C library's cosine and sine, called through a function pointer so
// they are never fused into one sincos call (see color.rs).
extern "C" {
    #[link_name = "cos"]
    fn c_cos(x: f64) -> f64;
    #[link_name = "sin"]
    fn c_sin(x: f64) -> f64;
}

fn fixture(name: &str) -> J {
    let p = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures/palette").join(name);
    let s = std::fs::read_to_string(&p).unwrap_or_else(|e| panic!("reading {}: {e}", p.display()));
    minijson::parse(&s).unwrap_or_else(|e| panic!("{}: {e}", p.display()))
}

/// The f64 whose bits are the 16 hex digits of `s`.
fn b(s: &str) -> f64 {
    f64::from_bits(u64::from_str_radix(s, 16).unwrap_or_else(|e| panic!("bad bit pattern {s}: {e}")))
}

fn hexes<'a>(e: &'a J, key: &str, n: usize) -> Vec<&'a str> {
    let a = e.get(key).and_then(J::as_arr).unwrap_or_else(|| panic!("no array {key}"));
    assert_eq!(a.len(), n, "{key} has {n} values");
    a.iter().map(|v| v.as_str().unwrap_or_else(|| panic!("{key}: not a string"))).collect()
}

/// One recorded C library call: the function, its argument bits and the
/// result bits.
struct Call<'a> {
    f: &'a str,
    args: Vec<&'a str>,
    result: &'a str,
}

impl Call<'_> {
    /// This platform's answer, as bits.
    fn here(&self) -> u64 {
        let a: Vec<f64> = self.args.iter().map(|s| b(s)).collect();
        let v = match (self.f, a.as_slice()) {
            ("pow", [x, y]) => black_box(*x).powf(black_box(*y)),
            ("atan2", [y, x]) => black_box(*y).atan2(black_box(*x)),
            // SAFETY: `cos` and `sin` from the C math library take and
            // return a double, read no memory and at most set errno.
            ("cos", [x]) => unsafe { black_box(c_cos as unsafe extern "C" fn(f64) -> f64)(black_box(*x)) },
            ("sin", [x]) => unsafe { black_box(c_sin as unsafe extern "C" fn(f64) -> f64)(black_box(*x)) },
            _ => panic!("bits_libm.json: {} with {} arguments", self.f, a.len()),
        };
        v.to_bits()
    }
}

fn calls(doc: &J) -> Vec<Call<'_>> {
    let prims = doc.get("prims").and_then(J::as_arr).expect("an array of prims");
    prims
        .iter()
        .enumerate()
        .map(|(n, e)| {
            let a = e.as_arr().unwrap_or_else(|| panic!("prims[{n}] is not a list"));
            let s: Vec<&str> =
                a.iter().map(|v| v.as_str().unwrap_or_else(|| panic!("prims[{n}]: not a string"))).collect();
            let want = match s[0] {
                "pow" | "atan2" => 4,
                "cos" | "sin" => 3,
                other => panic!("prims[{n}]: unknown function {other}"),
            };
            assert_eq!(s.len(), want, "prims[{n}] is [function, arguments, result]");
            Call { f: s[0], args: s[1..s.len() - 1].to_vec(), result: s[s.len() - 1] }
        })
        .collect()
}

/// The entries of `p` of a case (or pinned color) as indices, checked as
/// `libm_replay::recorded` checks them: whole numbers, each one of the `n`
/// recorded calls, strictly increasing (so none twice).
fn entries(e: &J, n: usize, what: &str) -> Vec<usize> {
    let a = e.get("p").and_then(J::as_arr).unwrap_or_else(|| panic!("bits_libm.json: {what} has no list p"));
    let mut out: Vec<usize> = Vec::with_capacity(a.len());
    for v in a {
        let i = v.as_f64().unwrap_or_else(|| panic!("bits_libm.json: {what}: p holds a non-number"));
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

/// The recorded calls this platform's C library answers differently.
fn differing(calls: &[Call<'_>]) -> HashSet<usize> {
    calls
        .iter()
        .enumerate()
        .filter(|(_, c)| c.here() != u64::from_str_radix(c.result, 16).expect("hex"))
        .map(|(i, _)| i)
        .collect()
}

/// The four functions, in the order `Live` counts them.
const FUNCTIONS: [&str; 4] = ["pow", "atan2", "cos", "sin"];

/// The floors a C library must meet for the live check to count: each
/// function answers at least `SAME_NUM` of `SAME_DEN` of its recorded calls
/// as recorded, and at least `MIN_CASES` of the 300 colors are checked.
///
/// Measured (aarch64, the recorded calls of bits_libm.json), calls answered
/// differently and colors checked:
///
/// | C library      | pow | atan2 | cos | sin | colors checked |
/// |----------------|-----|-------|-----|-----|----------------|
/// | macOS          |   0 |     0 |   0 |   0 |            300 |
/// | glibc 2.41     |   3 |     2 |   6 |  14 |            279 |
/// | glibc 2.31     |   3 |     1 |   6 |  14 |            280 |
/// | musl 1.2.5     |   5 |    44 |   7 |  15 |            234 |
///
/// Of 301 atan2 calls musl answers 257 as recorded (85.4%, the lowest share
/// of any function on any of the four); of the 3,096 pow calls none
/// answers more than 5 differently. `MIN_CASES` is two thirds of 300, 34
/// colors under musl's count. A binding to another function, swapped
/// arguments or a lower precision answers far fewer than three quarters
/// (`the_floors_hold_for_the_c_libraries_measured_and_fail_a_wrong_binding`).
const SAME_NUM: usize = 3;
const SAME_DEN: usize = 4;
const MIN_CASES: usize = 200;

/// What the live check found: how many recorded calls of each function there
/// are and how many this C library answers differently, and how many colors
/// it could check.
struct Live {
    total: [usize; 4],
    differ: [usize; 4],
    checked: usize,
}

impl Live {
    /// `Err` with the reason when this C library leaves too little to check.
    fn floors(&self) -> Result<(), String> {
        for (k, f) in FUNCTIONS.iter().enumerate() {
            let (total, differ) = (self.total[k], self.differ[k]);
            assert!(total > 0, "bits_libm.json holds no {f} calls");
            if differ * SAME_DEN > total * (SAME_DEN - SAME_NUM) {
                return Err(format!(
                    "this C library answers only {} of the {total} recorded {f} calls as recorded; at least {SAME_NUM}/{SAME_DEN} are needed (a binding to the wrong function, swapped arguments or a lower precision looks like this; see bits_libm.json)",
                    total - differ
                ));
            }
        }
        if self.checked < MIN_CASES {
            return Err(format!(
                "this C library answers {} of the recorded calls differently and leaves {} cases to check live; at least {MIN_CASES} are needed (see bits_libm.json)",
                self.differ.iter().sum::<usize>(),
                self.checked
            ));
        }
        Ok(())
    }
}

#[test]
fn the_color_math_is_the_references_to_the_last_bit() {
    let fx = fixture("bits.json");
    let libm = fixture("bits_libm.json");
    let cases = fx.get("cases").and_then(J::as_arr).expect("an array of cases");
    let lcases = libm.get("cases").and_then(J::as_arr).expect("an array of cases in bits_libm.json");
    assert_eq!(cases.len(), 300, "colors in the fixture");
    assert_eq!(lcases.len(), 300, "colors in bits_libm.json");
    let calls = calls(&libm);
    let differ = differing(&calls);
    let bg = Rgb(0x22, 0x24, 0x36);
    let (mut values, mut checked, mut mismatches) = (0usize, 0usize, Vec::new());
    let mut skipped: Vec<&str> = Vec::new();
    for (e, l) in cases.iter().zip(lcases) {
        let name = e.get("c").and_then(J::as_str).expect("a color");
        assert_eq!(l.get("c").and_then(J::as_str), Some(name), "same colors in the same order");
        if entries(l, calls.len(), name).iter().any(|i| differ.contains(i)) {
            skipped.push(name);
            continue;
        }
        checked += 1;
        let c = parse_rgb(name).unwrap_or_else(|| panic!("not #rrggbb: {name}"));
        let mut check = |what: &str, i: usize, got: f64, want: &str| {
            values += 1;
            if got.to_bits() != u64::from_str_radix(want, 16).expect("hex") {
                mismatches.push(format!("{name} {what} {i}: got {:016x} want {want}", got.to_bits()));
            }
        };
        for (i, w) in hexes(e, "oklab", 3).into_iter().enumerate() {
            check("oklab", i, oklab(c)[i], w);
        }
        let lch = oklch(c);
        for (i, w) in hexes(e, "oklch", 3).into_iter().enumerate() {
            check("oklch", i, lch[i], w);
        }
        let shift = b(e.get("shift").and_then(J::as_str).expect("a shift"));
        let back = oklch_to_rgb((lch[0] + shift).clamp(0.0, 1.0), lch[1], lch[2]);
        for (i, (got, w)) in [back.r, back.g, back.b].into_iter().zip(hexes(e, "shifted_rgb", 3)).enumerate() {
            check("shifted_rgb", i, got, w);
        }
        check("rel_lum", 0, rel_lum(c), e.get("rel_lum").and_then(J::as_str).expect("rel_lum"));
        check("contrast_222436", 0, contrast(c, bg), e.get("contrast_222436").and_then(J::as_str).expect("contrast"));
        check("lstar", 0, lstar(c), e.get("lstar").and_then(J::as_str).expect("lstar"));
    }
    let count = |f: &str| differ.iter().filter(|&&i| calls[i].f == f).count();
    let live = Live {
        total: FUNCTIONS.map(|f| calls.iter().filter(|c| c.f == f).count()),
        differ: FUNCTIONS.map(count),
        checked,
    };
    println!(
        "live on this C library: {checked} of 300 cases, {values} values, {} mismatches; it answers {} of {} recorded calls differently (pow {}, atan2 {}, cos {}, sin {})",
        mismatches.len(),
        differ.len(),
        calls.len(),
        live.differ[0],
        live.differ[1],
        live.differ[2],
        live.differ[3]
    );
    let mut order: Vec<usize> = differ.iter().copied().collect();
    order.sort_unstable();
    for i in order {
        let c = &calls[i];
        println!("differs: {} {} recorded {} here {:016x}", c.f, c.args.join(" "), c.result, c.here());
    }
    if checked < 300 {
        println!("not checked live: {}", skipped.join(" "));
    }
    let n = mismatches.len();
    let shown: Vec<&String> = mismatches.iter().take(20).collect();
    assert!(mismatches.is_empty(), "{n} of {values} values differ (first 20):\n{shown:#?}");
    assert_eq!(values, checked * 12, "12 values per checked color");
    if let Err(why) = live.floors() {
        panic!("{why}");
    }
}

/// A list `p` is read as `libm_replay::recorded` reads it: a malformed
/// fixture stops this test with a message that names the entry, instead of
/// a color being checked against the wrong calls (or none).
#[test]
fn a_good_list_of_entries_is_read() {
    let e = minijson::parse(r#"{"p": [0, 3, 4]}"#).expect("json");
    assert_eq!(entries(&e, 5, "#123456"), vec![0, 3, 4]);
    let e = minijson::parse(r#"{"p": []}"#).expect("json");
    assert!(entries(&e, 5, "#123456").is_empty());
}

#[test]
#[should_panic(expected = "bits_libm.json: #123456: entry 1.5 is not one of the 5 recorded calls")]
fn an_entry_that_is_not_a_whole_number_is_refused() {
    entries(&minijson::parse(r#"{"p": [0, 1.5]}"#).expect("json"), 5, "#123456");
}

#[test]
#[should_panic(expected = "bits_libm.json: #123456: entry 5 is not one of the 5 recorded calls")]
fn an_entry_past_the_recorded_calls_is_refused() {
    entries(&minijson::parse(r#"{"p": [0, 5]}"#).expect("json"), 5, "#123456");
}

#[test]
#[should_panic(expected = "bits_libm.json: #123456: entry -1 is not one of the 5 recorded calls")]
fn a_negative_entry_is_refused() {
    entries(&minijson::parse(r#"{"p": [-1]}"#).expect("json"), 5, "#123456");
}

#[test]
#[should_panic(expected = "bits_libm.json: #123456: p is not strictly increasing at 3")]
fn an_entry_twice_is_refused() {
    entries(&minijson::parse(r#"{"p": [0, 3, 3]}"#).expect("json"), 5, "#123456");
}

#[test]
#[should_panic(expected = "bits_libm.json: #123456: p is not strictly increasing at 2")]
fn entries_out_of_order_are_refused() {
    entries(&minijson::parse(r#"{"p": [0, 3, 2]}"#).expect("json"), 5, "#123456");
}

#[test]
#[should_panic(expected = "bits_libm.json: #123456: p holds a non-number")]
fn an_entry_that_is_not_a_number_is_refused() {
    entries(&minijson::parse(r#"{"p": ["1"]}"#).expect("json"), 5, "#123456");
}

/// The floors keep the numbers measured on the C libraries above and still
/// fail a C library that answers too little as recorded.
#[test]
fn the_floors_hold_for_the_c_libraries_measured_and_fail_a_wrong_binding() {
    let libm = fixture("bits_libm.json");
    let calls = calls(&libm);
    let total = FUNCTIONS.map(|f| calls.iter().filter(|c| c.f == f).count());
    assert_eq!(total, [3096, 301, 302, 302], "recorded pow, atan2, cos and sin calls");
    let live = |differ: [usize; 4], checked: usize| Live { total, differ, checked };
    // Measured: all four pass.
    for (name, differ, checked) in [
        ("macOS", [0, 0, 0, 0], 300),
        ("glibc 2.41", [3, 2, 6, 14], 279),
        ("glibc 2.31", [3, 1, 6, 14], 280),
        ("musl 1.2.5", [5, 44, 7, 15], 234),
    ] {
        assert_eq!(live(differ, checked).floors(), Ok(()), "{name}");
    }
    // Edges: three quarters of a function's calls, two thirds of the colors.
    assert_eq!(live([0, 75, 0, 0], 234).floors(), Ok(()), "75 of 301 atan2 calls differ: 75.1% are as recorded");
    let e = live([0, 76, 0, 0], 234).floors().expect_err("76 of 301 atan2 calls differ");
    assert!(e.contains("only 225 of the 301 recorded atan2 calls"), "{e}");
    assert_eq!(live([0, 0, 0, 0], MIN_CASES).floors(), Ok(()));
    let e = live([0, 0, 0, 0], MIN_CASES - 1).floors().expect_err("199 colors checked");
    assert!(e.contains("leaves 199 cases to check live; at least 200 are needed"), "{e}");
    // Wrong bindings: a function that answers (almost) none as recorded.
    for (k, f) in FUNCTIONS.iter().enumerate() {
        let mut differ = [0; 4];
        differ[k] = total[k];
        let e = live(differ, 0).floors().expect_err(f);
        assert!(e.contains(&format!("only 0 of the {} recorded {f} calls", total[k])), "{f}: {e}");
    }
    let mut differ = [0; 4];
    differ[0] = total[0] / 2;
    assert!(live(differ, 300).floors().is_err(), "half of the pow calls differ");
}

/// The two colors `color.rs` pins, the way back from OKLCH, with this
/// platform's C library. On a C library whose `sin` rounds the angle of
/// either differently the colors using it are not checked here (the replay
/// test pins them for every platform). The hazard this guards, a fused
/// sincos call that rounds another way than the separate calls, shows only
/// where the C library's two disagree, which is Apple's.
#[test]
fn the_pinned_way_back_is_the_references_on_this_c_library() {
    let libm = fixture("bits_libm.json");
    let calls = calls(&libm);
    let differ = differing(&calls);
    let pinned = libm.get("pinned").and_then(J::as_arr).expect("an array of pinned colors");
    assert_eq!(pinned.len(), 2, "two pinned colors");
    let (mut checked, mut mismatches) = (0usize, Vec::new());
    for e in pinned {
        let name = e.get("c").and_then(J::as_str).expect("a color");
        if entries(e, calls.len(), name).iter().any(|i| differ.contains(i)) {
            continue;
        }
        checked += 1;
        let c = parse_rgb(name).unwrap_or_else(|| panic!("not #rrggbb: {name}"));
        let lch = hexes(e, "lch", 3);
        let got = oklch(c);
        for (i, w) in lch.iter().enumerate() {
            if got[i].to_bits() != b(w).to_bits() {
                mismatches.push(format!("{name} oklch {i}: got {:016x} want {w}", got[i].to_bits()));
            }
        }
        let [l, ch, h] = [b(lch[0]), b(lch[1]), b(lch[2])];
        let back = oklch_to_rgb(l, ch, h);
        for (i, (got, w)) in [back.r, back.g, back.b].into_iter().zip(hexes(e, "rgb", 3)).enumerate() {
            if got.to_bits() != b(w).to_bits() {
                mismatches.push(format!("{name} back {i}: got {:016x} want {w}", got.to_bits()));
            }
        }
    }
    println!("pinned on this C library: {checked} of 2 colors, {} mismatches", mismatches.len());
    assert!(mismatches.is_empty(), "{} values differ:\n{mismatches:#?}", mismatches.len());
}
