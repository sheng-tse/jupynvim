//! Color math for the palette: CSS colors, compositing, WCAG contrast with
//! VS Code's constants, and OKLab / OKLCH.
//!
//! The expected palettes the tests pin were computed in Python (CPython
//! 3.14) from the same formulas, in 8-bit colors, and a bisection that lands
//! one step off moves a token. So every function here repeats Python's
//! computation operation for operation in f64: the same constants, the same
//! order of additions and multiplications, `powf` for every power (a cube is
//! `powf(3.0)`, a cube root `powf(1.0 / 3.0)` of the magnitude with the sign
//! copied back), Python's own hypot for the chroma (`hypot_ref`), the C
//! library's `cos` and `sin` one at a time, and a channel rounded to 8 bits
//! with ties to even, as Python's `round`.
//!
//! `pow`, `atan2`, `cos` and `sin` are the only C library calls, and each
//! goes through one of four wrappers (`pow_c`, `atan2_c`, `cos_ref`,
//! `sin_ref`); everything else is exact IEEE arithmetic, the same on every
//! platform. Given the same answers from those four functions every value
//! is Python's to the last bit on any platform: the unit tests answer them
//! from the table recorded with the reference's results
//! (`palette::libm_replay`, tests/fixtures/palette/bits_libm.json). The
//! last bit of the C library's own answer is the platform's, and the
//! integration test `palette_bits` checks this platform's C library
//! wherever it answers the same as the recorded one. Channels are 0 to 255
//! (`f64` while a color is computed), alpha 0 to 1.

/// An opaque 8-bit color.
#[derive(Copy, Clone, PartialEq, Eq, Debug, Hash)]
pub struct Rgb(pub u8, pub u8, pub u8);

/// A color while it is computed: channels 0 to 255, alpha 0 to 1.
#[derive(Copy, Clone, PartialEq, Debug)]
pub struct Rgba {
    pub r: f64,
    pub g: f64,
    pub b: f64,
    pub a: f64,
}

impl Rgba {
    pub const fn new(r: f64, g: f64, b: f64, a: f64) -> Rgba {
        Rgba { r, g, b, a }
    }
}

impl Rgb {
    /// `#rrggbb`, lower case.
    pub fn hex(self) -> String {
        format!("#{:02x}{:02x}{:02x}", self.0, self.1, self.2)
    }

    pub fn to_rgba(self) -> Rgba {
        Rgba::new(self.0 as f64, self.1 as f64, self.2 as f64, 1.0)
    }

    /// From `0xRRGGBB` (the top byte is ignored).
    pub const fn from_u32(v: u32) -> Rgb {
        Rgb((v >> 16) as u8, (v >> 8) as u8, v as u8)
    }

    /// `0xRRGGBB`.
    pub const fn to_u32(self) -> u32 {
        ((self.0 as u32) << 16) | ((self.1 as u32) << 8) | self.2 as u32
    }
}

fn hex_byte(h: &[u8]) -> Option<u8> {
    let s = std::str::from_utf8(h).ok()?;
    u8::from_str_radix(s, 16).ok()
}

/// A CSS color: `#rgb`, `#rgba`, `#rrggbb`, `#rrggbbaa`, `rgb(r, g, b)` or
/// `rgba(r, g, b, a)` (separated by commas, blanks or `/`), surrounding
/// blanks ignored. Anything else is `None`.
pub fn parse(s: &str) -> Option<Rgba> {
    let s = s.trim();
    if let Some(h) = s.strip_prefix('#') {
        let h = h.as_bytes();
        if !h.iter().all(u8::is_ascii_hexdigit) {
            return None;
        }
        let mut full = [0u8; 8];
        let n = match h.len() {
            3 | 4 => {
                for (i, &c) in h.iter().enumerate() {
                    full[2 * i] = c;
                    full[2 * i + 1] = c;
                }
                2 * h.len()
            }
            6 | 8 => {
                full[..h.len()].copy_from_slice(h);
                h.len()
            }
            _ => return None,
        };
        let r = hex_byte(&full[0..2])? as f64;
        let g = hex_byte(&full[2..4])? as f64;
        let b = hex_byte(&full[4..6])? as f64;
        let a = if n == 8 { hex_byte(&full[6..8])? as f64 / 255.0 } else { 1.0 };
        return Some(Rgba::new(r, g, b, a));
    }
    let rest = s.strip_prefix("rgba(").or_else(|| s.strip_prefix("rgb("))?;
    let inner = &rest[..rest.find(')')?];
    let parts: Vec<&str> =
        inner.split(|c: char| c == ',' || c == '/' || c.is_whitespace()).filter(|p| !p.is_empty()).collect();
    if parts.len() < 3 {
        return None;
    }
    let num = |p: &str| p.parse::<f64>().ok();
    let a = if parts.len() > 3 { num(parts[3])? } else { 1.0 };
    Some(Rgba::new(num(parts[0])?, num(parts[1])?, num(parts[2])?, a))
}

/// Exactly `#rrggbb` (either case), the form colors take on the wire.
pub fn parse_rgb(s: &str) -> Option<Rgb> {
    let h = s.strip_prefix('#')?.as_bytes();
    if h.len() != 6 || !h.iter().all(u8::is_ascii_hexdigit) {
        return None;
    }
    Some(Rgb(hex_byte(&h[0..2])?, hex_byte(&h[2..4])?, hex_byte(&h[4..6])?))
}

/// One channel to 8 bits: clamped to [0, 255], then rounded with ties to
/// even.
fn q8(v: f64) -> u8 {
    v.min(255.0).max(0.0).round_ties_even() as u8
}

/// The 8-bit color of `c`; alpha is dropped.
pub fn quantize(c: Rgba) -> Rgb {
    Rgb(q8(c.r), q8(c.g), q8(c.b))
}

/// `fg` composited over the opaque `bg`.
pub fn over(fg: Rgba, bg: Rgb) -> Rgba {
    let a = fg.a;
    Rgba::new(
        fg.r * a + bg.0 as f64 * (1.0 - a),
        fg.g * a + bg.1 as f64 * (1.0 - a),
        fg.b * a + bg.2 as f64 * (1.0 - a),
        1.0,
    )
}

/// What `c` looks like drawn on `under`, in 8 bits: composited when it is
/// translucent (alpha below 0.999), else only rounded.
pub fn flat(c: Rgba, under: Rgb) -> Rgb {
    if c.a < 0.999 {
        quantize(over(c, under))
    } else {
        quantize(c)
    }
}

/// `c` with its alpha scaled by `f` (VS Code's `transparent`).
pub fn vs_transparent(c: Rgba, f: f64) -> Rgba {
    Rgba::new(c.r, c.g, c.b, c.a * f)
}

/// The WCAG linearization of a channel (0 to 255) with VS Code's
/// threshold, 0.03928.
pub(crate) fn lin_wcag(v: f64) -> f64 {
    let v = v / 255.0;
    if v <= 0.03928 {
        v / 12.92
    } else {
        pow_c((v + 0.055) / 1.055, 2.4)
    }
}

/// WCAG 2.0 relative luminance, as VS Code's Color.getRelativeLuminance.
pub fn rel_lum(c: Rgb) -> f64 {
    0.2126 * lin_wcag(c.0 as f64) + 0.7152 * lin_wcag(c.1 as f64) + 0.0722 * lin_wcag(c.2 as f64)
}

/// The WCAG contrast ratio of two colors, 1 to 21, symmetric.
pub fn contrast(a: Rgb, b: Rgb) -> f64 {
    let (la, lb) = (rel_lum(a), rel_lum(b));
    let (hi, lo) = if la >= lb { (la, lb) } else { (lb, la) };
    (hi + 0.05) / (lo + 0.05)
}

/// CIELAB lightness L* (0 to 100) of an 8-bit color, from the same relative
/// luminance Y as the contrast ratio: `116 * Y^(1/3) - 16` above the
/// threshold 216/24389, else the linear part `24389/27 * Y`.
pub fn lstar(c: Rgb) -> f64 {
    let y = rel_lum(c);
    if y > 216.0 / 24389.0 {
        116.0 * pow_c(y, 1.0 / 3.0) - 16.0
    } else {
        (24389.0 / 27.0) * y
    }
}

/// The sRGB linearization OKLab starts from (threshold 0.04045).
fn lin_srgb(v: f64) -> f64 {
    let v = v / 255.0;
    if v <= 0.04045 {
        v / 12.92
    } else {
        pow_c((v + 0.055) / 1.055, 2.4)
    }
}

/// The real cube root as Python's `copysign(abs(x) ** (1 / 3), x)`: the
/// magnitude to the power 1/3, with the sign copied back.
fn cbrt_ref(x: f64) -> f64 {
    pow_c(x.abs(), 1.0 / 3.0).copysign(x)
}

/// `x` cubed as Python's `x ** 3` computes it: the magnitude to the power
/// 3.0, negated for a negative `x`.
fn cube_ref(x: f64) -> f64 {
    if x < 0.0 {
        -pow_c(-x, 3.0)
    } else {
        pow_c(x, 3.0)
    }
}

/// OKLab `[L, a, b]` of an 8-bit color.
pub fn oklab(c: Rgb) -> [f64; 3] {
    let (r, g, b) = (lin_srgb(c.0 as f64), lin_srgb(c.1 as f64), lin_srgb(c.2 as f64));
    let l = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b;
    let m = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b;
    let s = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b;
    let (l_, m_, s_) = (cbrt_ref(l), cbrt_ref(m), cbrt_ref(s));
    [
        0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_,
        1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_,
        0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_,
    ]
}

/// OKLab L of an 8-bit color.
pub fn l_of(c: Rgb) -> f64 {
    oklab(c)[0]
}

/// `(x * y, the exact error of that product)`.
fn dl_mul(x: f64, y: f64) -> (f64, f64) {
    let z = x * y;
    (z, x.mul_add(y, -z))
}

/// `(a + b, the exact error of that sum)`, for `|a| >= |b|`.
fn dl_fast_sum(a: f64, b: f64) -> (f64, f64) {
    let x = a + b;
    (x, (a - x) + b)
}

/// The exponent `frexp` gives: `v = m * 2^e` with `m` in [0.5, 1), for a
/// finite `v` other than 0.
fn frexp_exp(v: f64) -> i32 {
    let bits = v.abs().to_bits();
    let e = (bits >> 52) as i32;
    if e == 0 {
        // subnormal: the highest set bit of the mantissa
        (63 - bits.leading_zeros() as i32) - 1073
    } else {
        e - 1022
    }
}

/// `2^k` exactly, for k in [-1074, 1023].
fn pow2(k: i32) -> f64 {
    if k >= -1022 {
        f64::from_bits(((k + 1023) as u64) << 52)
    } else {
        f64::from_bits(1u64 << (k + 1074))
    }
}

/// Python's hypot for two coordinates, in order: CPython 3.14's
/// `vector_norm` (Modules/mathmodule.c), a sum of squares scaled by a power
/// of two, compensated, with a corrected square root. Only exact IEEE
/// operations (`mul_add`, `sqrt`), so it gives the same bits everywhere.
fn vector_norm(mut v: [f64; 2], max: f64, found_nan: bool) -> f64 {
    if max.is_infinite() {
        return max;
    }
    if found_nan {
        return f64::NAN;
    }
    if max == 0.0 {
        return max;
    }
    let max_e = frexp_exp(max);
    if max_e < -1023 {
        for x in v.iter_mut() {
            *x /= f64::MIN_POSITIVE;
        }
        return f64::MIN_POSITIVE * vector_norm(v, max / f64::MIN_POSITIVE, found_nan);
    }
    let scale = pow2(-max_e);
    let (mut csum, mut frac1, mut frac2) = (1.0f64, 0.0f64, 0.0f64);
    for x in v {
        let x = x * scale;
        let (pr_hi, pr_lo) = dl_mul(x, x);
        let (sm_hi, sm_lo) = dl_fast_sum(csum, pr_hi);
        csum = sm_hi;
        frac1 += pr_lo;
        frac2 += sm_lo;
    }
    let mut h = (csum - 1.0 + (frac1 + frac2)).sqrt();
    let (pr_hi, pr_lo) = dl_mul(-h, h);
    let (sm_hi, sm_lo) = dl_fast_sum(csum, pr_hi);
    csum = sm_hi;
    frac1 += pr_lo;
    frac2 += sm_lo;
    let x = csum - 1.0 + (frac1 + frac2);
    h += x / (2.0 * h);
    h / scale
}

/// `sqrt(x^2 + y^2)` as Python's `math.hypot` computes it. The C library's
/// hypot (what `f64::hypot` calls) is another function: on macOS it gives
/// another last bit for the chroma of about one 8-bit color in seven.
pub(crate) fn hypot_ref(x: f64, y: f64) -> f64 {
    let v = [x.abs(), y.abs()];
    let (mut max, mut found_nan) = (0.0f64, false);
    for c in v {
        found_nan |= c.is_nan();
        if c > max {
            max = c;
        }
    }
    vector_norm(v, max, found_nan)
}

/// OKLCH `[L, C, h]` of an 8-bit color, h in degrees in [0, 360).
pub fn oklch(c: Rgb) -> [f64; 3] {
    let [l, a, b] = oklab(c);
    let ch = hypot_ref(a, b);
    let h = atan2_c(b, a).to_degrees().rem_euclid(360.0);
    [l, ch, h]
}

/// The gamma encoding back to a channel: clamped to [0, 1] first.
fn enc(v: f64) -> f64 {
    let v = v.min(1.0).max(0.0);
    255.0 * (if v <= 0.0031308 { 12.92 * v } else { 1.055 * pow_c(v, 1.0 / 2.4) - 0.055 })
}

/// An OKLab color back to sRGB channels (0 to 255, not rounded; out of
/// gamut channels are clamped), alpha 1.
pub fn oklab_to_rgb(l: f64, a: f64, b: f64) -> Rgba {
    let l_ = l + 0.3963377774 * a + 0.2158037573 * b;
    let m_ = l - 0.1055613458 * a - 0.0638541728 * b;
    let s_ = l - 0.0894841775 * a - 1.2914855480 * b;
    let (l3, m3, s3) = (cube_ref(l_), cube_ref(m_), cube_ref(s_));
    let r = 4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3;
    let g = -1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3;
    let bb = -0.0041960863 * l3 - 0.7034186147 * m3 + 1.7076147010 * s3;
    Rgba::new(enc(r), enc(g), enc(bb), 1.0)
}

// The four C library functions the color math uses, each behind a wrapper.
// In the library the wrapper is the plain call. In unit tests a table
// installed on the thread (palette::libm_replay) answers instead, so the
// tests can prove the port is the reference's on any C library.
#[cfg(test)]
use crate::palette::libm_replay as replay;

/// The library: no table, never answered, compiles away.
#[cfg(not(test))]
mod replay {
    #[inline(always)]
    pub(super) fn pow(_: f64, _: f64) -> Option<f64> {
        None
    }
    #[inline(always)]
    pub(super) fn atan2(_: f64, _: f64) -> Option<f64> {
        None
    }
    #[inline(always)]
    pub(super) fn cos(_: f64) -> Option<f64> {
        None
    }
    #[inline(always)]
    pub(super) fn sin(_: f64) -> Option<f64> {
        None
    }
}

/// `x ** y` as Python computes it: the C library's `pow` (Rust's `powf`).
fn pow_c(x: f64, y: f64) -> f64 {
    if let Some(v) = replay::pow(x, y) {
        return v;
    }
    x.powf(y)
}

/// `atan2(y, x)`: the C library's.
fn atan2_c(y: f64, x: f64) -> f64 {
    if let Some(v) = replay::atan2(y, x) {
        return v;
    }
    y.atan2(x)
}

// The C library's cosine and sine, each called on its own as Python calls
// them. Rust's `cos` and `sin` of one angle compile to a single sincos call
// (`__sincos_stret` on macOS, `sincos` with glibc), and on macOS that sine
// differs from `sin` in the last bit for some angles.
extern "C" {
    #[link_name = "cos"]
    fn libm_cos(x: f64) -> f64;
    #[link_name = "sin"]
    fn libm_sin(x: f64) -> f64;
}

fn cos_ref(x: f64) -> f64 {
    if let Some(v) = replay::cos(x) {
        return v;
    }
    // SAFETY: `cos` from the C math library (linked through libc) takes and
    // returns a double, reads no memory and at most sets errno.
    unsafe { libm_cos(x) }
}

fn sin_ref(x: f64) -> f64 {
    if let Some(v) = replay::sin(x) {
        return v;
    }
    // SAFETY: as `cos_ref`.
    unsafe { libm_sin(x) }
}

/// An OKLCH color (h in degrees) back to sRGB channels, as `oklab_to_rgb`.
pub fn oklch_to_rgb(l: f64, c: f64, h: f64) -> Rgba {
    let r = h.to_radians();
    oklab_to_rgb(l, c * cos_ref(r), c * sin_ref(r))
}

/// The color `t` of the way from `a` to `b` in OKLab, in 8 bits.
pub fn mix(a: Rgb, b: Rgb, t: f64) -> Rgb {
    let (x, y) = (oklab(a), oklab(b));
    quantize(oklab_to_rgb(x[0] + (y[0] - x[0]) * t, x[1] + (y[1] - x[1]) * t, x[2] + (y[2] - x[2]) * t))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::palette::libm_replay;
    use crate::palette::testjson::{self, J};
    use std::hint::black_box;

    fn rgb(s: &str) -> Rgb {
        parse_rgb(s).unwrap_or_else(|| panic!("not #rrggbb: {s}"))
    }

    fn fixture(name: &str) -> J {
        let p = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures/palette").join(name);
        let s = std::fs::read_to_string(&p).unwrap_or_else(|e| panic!("reading {}: {e}", p.display()));
        testjson::parse(&s).unwrap_or_else(|e| panic!("{}: {e}", p.display()))
    }

    fn s<'a>(e: &'a J, k: &str) -> &'a str {
        e.get(k).and_then(J::as_str).unwrap_or_else(|| panic!("no string {k}"))
    }

    #[test]
    fn parse_reads_every_css_form() {
        assert_eq!(parse("#abc"), Some(Rgba::new(170.0, 187.0, 204.0, 1.0)));
        assert_eq!(parse("#abcd"), Some(Rgba::new(170.0, 187.0, 204.0, 221.0 / 255.0)));
        assert_eq!(parse("#C0caF5"), Some(Rgba::new(192.0, 202.0, 245.0, 1.0)));
        assert_eq!(parse("#ffffff2e"), Some(Rgba::new(255.0, 255.0, 255.0, 46.0 / 255.0)));
        assert_eq!(parse("  #000000\n"), Some(Rgba::new(0.0, 0.0, 0.0, 1.0)));
        assert_eq!(parse("rgb(1, 2, 3)"), Some(Rgba::new(1.0, 2.0, 3.0, 1.0)));
        assert_eq!(parse("rgba(1,2,3,0.5)"), Some(Rgba::new(1.0, 2.0, 3.0, 0.5)));
        assert_eq!(parse("rgba(253, 255, 0, 0.2)"), Some(Rgba::new(253.0, 255.0, 0.0, 0.2)));
        assert_eq!(parse("rgb(1 2 3 / 0.25)"), Some(Rgba::new(1.0, 2.0, 3.0, 0.25)));
        assert_eq!(parse("rgb(1.5, 2, 3)"), Some(Rgba::new(1.5, 2.0, 3.0, 1.0)));
        for bad in [
            "", "#", "#12", "#12345", "#1234567", "#123456789", "#gggggg", "#+12345", "# 12345", "red", "c0caf5",
            "rgb(1,2)", "rgb(a,b,c)", "rgb(1,2,3", "rgb(1,2,3%)", "hsl(1, 2, 3)", "RGB(1,2,3)",
        ] {
            assert_eq!(parse(bad), None, "{bad:?}");
        }
    }

    #[test]
    fn parse_rgb_takes_exactly_rrggbb() {
        assert_eq!(parse_rgb("#C0caf5"), Some(Rgb(0xc0, 0xca, 0xf5)));
        assert_eq!(parse_rgb("#000000"), Some(Rgb(0, 0, 0)));
        let bad = ["#abc", "#abcd", "#c0caf5ff", "c0caf5", " #c0caf5", "#c0caf5 ", "#c0caf", "#c0cag5", "#+0caf5"];
        for bad in bad.into_iter().chain(["rgb(1,2,3)"]) {
            assert_eq!(parse_rgb(bad), None, "{bad:?}");
        }
    }

    #[test]
    fn rgb_conversions() {
        assert_eq!(Rgb(0x1c, 0x1f, 0x31).hex(), "#1c1f31");
        assert_eq!(Rgb::from_u32(0xc0caf5), Rgb(0xc0, 0xca, 0xf5));
        assert_eq!(Rgb(0xc0, 0xca, 0xf5).to_u32(), 0xc0caf5);
        assert_eq!(Rgb(1, 2, 3).to_rgba(), Rgba::new(1.0, 2.0, 3.0, 1.0));
        assert_eq!(vs_transparent(Rgba::new(1.0, 2.0, 3.0, 0.5), 0.5), Rgba::new(1.0, 2.0, 3.0, 0.25));
    }

    #[test]
    fn quantize_rounds_ties_to_even_and_clamps() {
        assert_eq!(quantize(Rgba::new(127.5, 126.5, -3.0, 1.0)), Rgb(128, 126, 0));
        assert_eq!(quantize(Rgba::new(300.0, 0.5, 1.5, 0.2)), Rgb(255, 0, 2));
        assert_eq!(quantize(Rgba::new(254.49, 2.5, 3.5000001, 1.0)), Rgb(254, 2, 4));
        assert_eq!(quantize(Rgba::new(f64::NAN, f64::NEG_INFINITY, f64::INFINITY, 1.0)), Rgb(255, 0, 255));
    }

    #[test]
    fn over_and_flat_composite_onto_the_color_underneath() {
        assert_eq!(over(Rgba::new(255.0, 255.0, 255.0, 0.5), Rgb(0, 0, 0)), Rgba::new(127.5, 127.5, 127.5, 1.0));
        assert_eq!(over(Rgba::new(10.0, 20.0, 30.0, 1.0), Rgb(255, 255, 255)), Rgba::new(10.0, 20.0, 30.0, 1.0));
        let v = fixture("vectors.json");
        let flat_v = v.get("flat").and_then(J::as_arr).expect("vectors.json has flat");
        assert_eq!(flat_v.len(), 4);
        for e in flat_v {
            let c = parse(s(e, "c")).expect("c parses");
            let (under, out) = (rgb(s(e, "under")), rgb(s(e, "out")));
            assert!(c.a < 0.999, "every flat vector is translucent");
            assert_eq!(flat(c, under), out, "flat({}, {})", s(e, "c"), s(e, "under"));
            assert_eq!(quantize(over(c, under)), out, "over({}, {})", s(e, "c"), s(e, "under"));
        }
        // an opaque color is only quantized; with integer channels these two
        // alphas give the same 8-bit color composited or not, so they pin only
        // that the result is right (the threshold itself:
        // flat_composites_only_below_0_999_alpha)
        assert_eq!(flat(Rgba::new(10.4, 20.6, 30.5, 1.0), Rgb(0, 0, 0)), Rgb(10, 21, 30));
        assert_eq!(flat(Rgba::new(10.0, 20.0, 30.0, 0.9995), Rgb(255, 255, 255)), Rgb(10, 20, 30));
        assert_eq!(flat(Rgba::new(10.0, 20.0, 30.0, 0.998), Rgb(255, 255, 255)), Rgb(10, 20, 30));
        assert_eq!(flat(Rgba::new(0.0, 0.0, 0.0, 0.99), Rgb(255, 255, 255)), Rgb(3, 3, 3));
    }

    /// With a fractional channel the two paths differ: composited, 10.4 at
    /// alpha 0.9995 over white would be 10.4 * 0.9995 + 255 * 0.0005 =
    /// 10.52 and give 11; below 0.999 the color is composited, from 0.999 up
    /// it is only rounded.
    #[test]
    fn flat_composites_only_below_0_999_alpha() {
        let white = Rgb(255, 255, 255);
        assert_eq!(flat(Rgba::new(10.4, 20.0, 30.0, 0.9995), white), Rgb(10, 20, 30));
        assert_eq!(flat(Rgba::new(10.4, 20.0, 30.0, 0.999), white), Rgb(10, 20, 30));
        assert_eq!(flat(Rgba::new(10.4, 20.0, 30.0, 0.998), white), Rgb(11, 20, 30));
        assert_eq!(quantize(over(Rgba::new(10.4, 20.0, 30.0, 0.9995), white)), Rgb(11, 20, 30));
    }

    #[test]
    fn contrast_is_wcag_with_vs_codes_constants() {
        let c = contrast(rgb("#c0caf5"), rgb("#222436"));
        assert!((c - 9.47).abs() < 0.005, "{c}");
        let c = contrast(rgb("#1e66f5"), rgb("#eff1f5"));
        assert!((c - 4.34).abs() < 0.005, "{c}");
        // Python's values, to the last bit
        assert_eq!(contrast(rgb("#c0caf5"), rgb("#222436")), 9.46977814745923);
        assert_eq!(contrast(rgb("#1e66f5"), rgb("#eff1f5")), 4.3447867560662665);
        let pairs = [("#c0caf5", "#222436"), ("#1e66f5", "#eff1f5"), ("#000000", "#ffffff"), ("#40a02b", "#ccd0da")];
        for (a, b) in pairs {
            assert_eq!(contrast(rgb(a), rgb(b)), contrast(rgb(b), rgb(a)), "{a} {b}");
        }
        for x in ["#000000", "#ffffff", "#222436", "#7f7f7f"] {
            assert_eq!(contrast(rgb(x), rgb(x)), 1.0, "{x}");
        }
        assert_eq!(contrast(rgb("#000000"), rgb("#ffffff")), 21.0);
        assert_eq!(rel_lum(rgb("#000000")), 0.0);
        assert_eq!(rel_lum(rgb("#ffffff")), 1.0);
    }

    /// VS Code's WCAG linearization switches to the power curve above
    /// 0.03928 (OKLab's sRGB curve uses 0.04045). No 8-bit channel falls
    /// between the two (10/255 is below both, 11/255 above both), so only a
    /// channel value in between tells them apart.
    #[test]
    fn the_wcag_linearization_uses_vs_codes_threshold() {
        for x in [0.0393f64, 0.04, 0.0404] {
            let v = x * 255.0;
            assert_eq!(lin_wcag(v), ((v / 255.0 + 0.055) / 1.055).powf(2.4), "{x}");
        }
        assert_eq!(lin_wcag(10.0), 10.0 / 255.0 / 12.92);
        assert_eq!(lin_wcag(0.0392 * 255.0), 0.0392 * 255.0 / 255.0 / 12.92);
    }

    #[test]
    fn oklch_of_the_terminal_background() {
        let [l, c, h] = oklch(rgb("#222436"));
        let want = [0.2669469632252375, 0.03365532860991694, 278.95817918406766];
        for (got, want) in [l, c, h].into_iter().zip(want) {
            assert!((got - want).abs() < 1e-12, "{got} vs {want}");
        }
        assert_eq!(l_of(rgb("#222436")), l);
        assert_eq!(oklab(rgb("#222436"))[0], l);
        // achromatic colors have no chroma to speak of and a hue in [0, 360)
        for x in ["#000000", "#ffffff", "#808080"] {
            let [_, c, h] = oklch(rgb(x));
            assert!(c < 1e-6 && (0.0..360.0).contains(&h), "{x}: {c} {h}");
        }
        assert_eq!(oklab(rgb("#000000")), [0.0, 0.0, 0.0]);
    }

    /// The chroma comes from Python's hypot, not the C library's, which
    /// gives another last bit for some of these (on macOS the first two).
    /// Inputs and results are bit patterns: OKLab a and b of the color, and
    /// Python's `math.hypot` of them.
    #[test]
    fn hypot_is_pythons_to_the_last_bit() {
        let pins: [(Rgb, u64, u64, u64); 6] = [
            (Rgb(0, 0, 15), 0xbf7663cf3b218aa0, 0xbfaadcdf06679f8a, 0x3fab02180ed1cec4),
            (Rgb(0, 17, 5), 0xbfa2275826fbc47b, 0x3f91f5a084bf8318, 0x3fa440d1c95a2b1e),
            (Rgb(34, 36, 54), 0x3f757727e4254760, 0xbfa10576b4b9381c, 0x3fa13b456f6e73b1),
            (Rgb(192, 202, 245), 0x3f74c50fcf11ae00, 0xbfaf28e9acf48d60, 0x3faf448da89a50a9),
            (Rgb(12, 200, 99), 0xbfc5c00f968ab4d8, 0x3fb8200d81c12558, 0x3fc8df0a743f8130),
            (Rgb(255, 0, 0), 0x3fccc85012adabec, 0x3fc01bbb44418e76, 0x3fd07de220dcebe1),
        ];
        for (c, a, b, ch) in pins {
            // black_box: computed at run time, never folded from constants
            let [_, la, lb] = oklab(black_box(c));
            assert_eq!((la.to_bits(), lb.to_bits()), (a, b), "oklab of {}", c.hex());
            let got = hypot_ref(black_box(f64::from_bits(a)), black_box(f64::from_bits(b)));
            assert_eq!(got.to_bits(), ch, "hypot for {}", c.hex());
            assert_eq!(oklch(black_box(c))[1].to_bits(), ch, "chroma of {}", c.hex());
        }
        assert_eq!(hypot_ref(3.0, -4.0), 5.0);
        assert_eq!(hypot_ref(0.0, -0.0).to_bits(), 0);
        assert_eq!(hypot_ref(f64::INFINITY, f64::NAN), f64::INFINITY);
        assert!(hypot_ref(1.0, f64::NAN).is_nan());
        assert_eq!(hypot_ref(5e-324, 5e-324).to_bits(), 1);
        assert_eq!(hypot_ref(1e300, 1e300).to_bits(), 0x7e40e4d50f99b211);
        assert_eq!(hypot_ref(2.5e-310, 1e-311).to_bits(), 0x00002e0ec87607aa);
    }

    /// The way back from OKLCH takes the cosine and the sine one by one, as
    /// Python does; a fused sincos gives another last bit for these two
    /// colors on macOS. Bit patterns of L, C, h and the three channels, as
    /// Python computes them from the same answers of the C library
    /// (`bits_libm.json`, `pinned`): the colors are computed here from those
    /// recorded answers, so the check holds on any platform. The
    /// integration test `palette_bits` checks them on this platform's own C
    /// library.
    #[test]
    fn oklch_to_rgb_is_pythons_to_the_last_bit() {
        let pins: [(Rgb, [u64; 6]); 2] = [
            (
                Rgb(169, 43, 8),
                [
                    0x3fdf1a1e005acaf0, 0x3fc56ac30b464559, 0x40413b5a5af5a018,
                    0x4065200000fc0fa6, 0x40457fffe889ed20, 0x401ffff32758eae0,
                ],
            ),
            (
                Rgb(235, 160, 130),
                [
                    0x3fe8b5aa53fa3431, 0x3fb96023ca103236, 0x40454dfbf5f1a5fd,
                    0x406d6000071bf25d, 0x4063fffffae5204b, 0x40603fffcc27a12b,
                ],
            ),
        ];
        let rec = libm_replay::recorded();
        assert_eq!(rec.pinned.len(), 2, "bits_libm.json pins the same two colors");
        for ((c, [l, ch, h, r, g, b]), pin) in pins.iter().zip(&rec.pinned) {
            assert_eq!(pin.c, *c, "same colors in the same order");
            assert_eq!(pin.lch, [*l, *ch, *h], "recorded L, C, h of {}", c.hex());
            assert_eq!(pin.rgb, [*r, *g, *b], "recorded channels of {}", c.hex());
        }
        for (c, [l, ch, h, r, g, b]) in pins {
            let pin = rec.pinned.iter().find(|p| p.c == c).expect("recorded");
            // black_box: computed at run time, as the palette computes it,
            // never folded by the compiler from constants
            let ((lch, back), t) = libm_replay::run(libm_replay::table(&rec, &pin.p), || {
                let lch = oklch(black_box(c));
                let [l, ch, h] = [l, ch, h].map(|v| black_box(f64::from_bits(v)));
                (lch, oklch_to_rgb(l, ch, h))
            });
            assert_eq!(lch.map(f64::to_bits), [l, ch, h], "oklch of {}", c.hex());
            assert_eq!([back.r, back.g, back.b].map(f64::to_bits), [r, g, b], "back from oklch of {}", c.hex());
            assert!(t.misses.is_empty(), "{}: calls the recording does not hold: {:?}", c.hex(), t.misses);
            assert_eq!(t.used.len(), pin.p.len(), "{}: every recorded call is made", c.hex());
        }
    }

    #[test]
    fn oklch_round_trips_through_8_bits() {
        for i in 0u32..200 {
            let x = Rgb::from_u32(i.wrapping_mul(1237) % (1 << 24));
            let [l, c, h] = oklch(x);
            let y = quantize(oklch_to_rgb(l, c, h));
            let d = [x.0.abs_diff(y.0), x.1.abs_diff(y.1), x.2.abs_diff(y.2)];
            assert!(d.iter().all(|&d| d <= 1), "{} came back as {}", x.hex(), y.hex());
            let [l2, a2, b2] = oklab(x);
            let z = quantize(oklab_to_rgb(l2, a2, b2));
            assert!(x.0.abs_diff(z.0) <= 1 && x.1.abs_diff(z.1) <= 1 && x.2.abs_diff(z.2) <= 1, "{}", x.hex());
        }
    }

    /// CIELAB L* from the same relative luminance as the contrast ratio.
    #[test]
    fn lstar_is_cielab_lightness_of_the_wcag_luminance() {
        assert_eq!(lstar(Rgb(0, 0, 0)), 0.0);
        assert!((lstar(Rgb(255, 255, 255)) - 100.0).abs() < 1e-9, "{}", lstar(Rgb(255, 255, 255)));
        // the linear branch (Y at or below 216/24389): #090909 has Y of about 0.0027
        let y = rel_lum(Rgb(9, 9, 9));
        assert!(y <= 216.0 / 24389.0);
        assert_eq!(lstar(Rgb(9, 9, 9)), (24389.0 / 27.0) * y);
        // the cube-root branch
        let y = rel_lum(Rgb(128, 128, 128));
        assert!(y > 216.0 / 24389.0);
        assert_eq!(lstar(Rgb(128, 128, 128)), 116.0 * y.powf(1.0 / 3.0) - 16.0);
        // monotone in the gray level
        let mut last = -1.0;
        for g in 0..=255u8 {
            let l = lstar(Rgb(g, g, g));
            assert!(l > last, "{g}");
            last = l;
        }
    }

    #[test]
    fn mix_is_linear_in_oklab() {
        assert_eq!(mix(rgb("#222436"), rgb("#c0caf5"), 0.2), rgb("#3e4158"));
        assert_eq!(mix(rgb("#222436"), rgb("#c0caf5"), 0.0), rgb("#222436"));
        assert_eq!(mix(rgb("#222436"), rgb("#c0caf5"), 1.0), rgb("#c0caf5"));
    }
}
