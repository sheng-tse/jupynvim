//! The inline pass of [`extract_math`](super::extract_math): scans one text
//! segment for the math delimiters and records each find with its source map
//! entry.
//!
//! Only `<`, `\`, `` ` `` and `$` act; every other byte is copied, in runs.
//! The functions are named after the steps of the reference; positions are
//! bytes of the segment, never looking outside it. Every delimiter is ASCII
//! and UTF-8 never holds an ASCII byte inside a character, so scanning bytes
//! gives the same answer as scanning UTF-16.
//!
//! The questions that look ahead for a closing delimiter (the blank-line
//! test, `\\)`, `\)`, `\end{..}` and a closing code span run) are answered by
//! `SegIndex` (see [`index`](super::index)), which gives the reference's
//! answer in logarithmic time, so a text with many unclosed delimiters is not
//! quadratic. The `$$` search and the pandoc `$` rule stay direct scans;
//! their linearity is argued at each.

use super::index::SegIndex;
use super::jsstr::{at, is_punct, is_ws, js_trim, js_ws_len, quote_prefix_len};
use super::{Edit, Kind, Math};

/// What the inline pass appends to: the output text so far (all segments), the
/// maths found so far in the source and the edits.
pub(crate) struct Out {
    pub buf: Vec<u8>,
    pub maths: Vec<Math>,
    pub edits: Vec<Edit>,
}

/// The bytes `a..b`, empty when out of range.
pub(crate) fn sub(b: &[u8], a: usize, e: usize) -> &[u8] {
    b.get(a..e).unwrap_or_default()
}

fn lossy(b: &[u8]) -> String {
    String::from_utf8_lossy(b).into_owned()
}

/// The first `needle` byte in `s[from..to]`.
fn find_byte(s: &[u8], needle: u8, from: usize, to: usize) -> Option<usize> {
    sub(s, from, to.min(s.len()))
        .iter()
        .position(|&c| c == needle)
        .map(|p| p + from)
}

/// Appends `ZZMTH0001ZZ` (inline) or `ZZDMTH0001ZZ` (display); `i` is 1-based.
pub(crate) fn push_placeholder(buf: &mut Vec<u8>, i: usize, display: bool) {
    use std::io::Write;
    buf.extend_from_slice(if display { b"ZZDMTH" } else { b"ZZMTH" });
    let _ = write!(buf, "{i:04}");
    buf.extend_from_slice(b"ZZ");
}

/// Whether `m`, a stretch without a newline, is wholly `[ \t]*(?:>[ \t]?)*`
/// (`trailing` false) or `[ \t]*(?:>[ \t]?)*[ \t]*` (`trailing` true): blanks,
/// then quote markers with at most one blank after each, and for the second
/// form any blanks at the end.
pub(crate) fn quote_blank(m: &[u8], trailing: bool) -> bool {
    let mut i = 0;
    while matches!(at(m, i), b' ' | b'\t') {
        i += 1;
    }
    while i < m.len() {
        if at(m, i) != b'>' {
            return false;
        }
        i += 1;
        let first = i;
        while matches!(at(m, i), b' ' | b'\t') {
            i += 1;
        }
        if i >= m.len() {
            return trailing || i - first <= 1;
        }
        if i - first > 1 {
            return false;
        }
    }
    true
}

/// `/^\n[ \t]*(?:>[ \t]?)*[ \t]*\n/.test(s.slice(j))`: a blank line, trailing
/// blanks allowed, starting at the newline at `j`.
fn b2_at(s: &[u8], j: usize) -> bool {
    if at(s, j) != b'\n' {
        return false;
    }
    // the next line can only be blank up to its first byte that is no blank and
    // no quote marker, so the look stops there
    let mut q = j + 1;
    while matches!(at(s, q), b' ' | b'\t' | b'>') {
        q += 1;
    }
    at(s, q) == b'\n' && quote_blank(sub(s, j + 1, q), true)
}

/// `t.replace(/\n[ \t]*(?:>[ \t]?)*/g, '\n').trim()`: the container prefixes
/// of the continuation lines of a multi-line math removed.
pub(crate) fn clean_tex(t: &[u8]) -> String {
    let mut v: Vec<u8> = Vec::with_capacity(t.len());
    let mut i = 0;
    while i < t.len() {
        match find_byte(t, b'\n', i, t.len()) {
            Some(p) => {
                v.extend_from_slice(sub(t, i, p + 1));
                i = p + 1;
                while matches!(at(t, i), b' ' | b'\t') {
                    i += 1;
                }
                while at(t, i) == b'>' {
                    i += 1;
                    if matches!(at(t, i), b' ' | b'\t') {
                        i += 1;
                    }
                }
            }
            None => {
                v.extend_from_slice(sub(t, i, t.len()));
                break;
            }
        }
    }
    lossy(js_trim(&v))
}

/// The math span `[start, end)` stands alone on its line(s): only a container
/// prefix before it and only blanks after it.
fn line_only_around(s: &[u8], start: usize, end: usize) -> bool {
    let mut e = end;
    loop {
        match s.get(e) {
            None | Some(b'\n') => break,
            Some(b' ') | Some(b'\t') => e += 1,
            Some(_) => return false,
        }
    }
    // Only blanks and `>` can precede on the line, so walking back over them
    // finds the line start or proves another character is there.
    let mut b = start;
    while b > 0 && matches!(at(s, b - 1), b' ' | b'\t' | b'>') {
        b -= 1;
    }
    if b > 0 && at(s, b - 1) != b'\n' {
        return false;
    }
    let before = sub(s, b, start);
    sub(before, quote_prefix_len(before), before.len())
        .iter()
        .all(|&c| c == b' ' || c == b'\t')
}

/// The end of the HTML comment or tag that starts at `k` (`s[k]` is `<`), or
/// `None` when it starts neither.
fn match_markup(s: &[u8], k: usize) -> Option<usize> {
    if sub(s, k, k + 4) == b"<!--" {
        let close = s
            .get(k + 4..)
            .and_then(|rest| rest.windows(3).position(|w| w == b"-->"));
        return Some(close.map_or(s.len(), |p| k + 4 + p + 3));
    }
    match_tag(s, k)
}

/// `/^<\/?[A-Za-z][A-Za-z0-9-]*(?:\s+[^<>]*)?\/?>|^<[A-Za-z][A-Za-z0-9+.-]*:[^\s<>]*>/`
/// at `k`, with JavaScript's `\s`. Returns the end of the match.
fn match_tag(s: &[u8], k: usize) -> Option<usize> {
    let p = k + 1;
    // `<` `/`? name, then blanks and anything up to `>`, or `/`? `>`
    let q = if at(s, p) == b'/' { p + 1 } else { p };
    if at(s, q).is_ascii_alphabetic() {
        let mut r = q + 1;
        while at(s, r).is_ascii_alphanumeric() || at(s, r) == b'-' {
            r += 1;
        }
        let ws = js_ws_len(s, r);
        if ws > 0 {
            // `\s+` then `[^<>]*` take everything up to the next `<` or `>`
            let mut t = r + ws;
            while t < s.len() && !matches!(at(s, t), b'<' | b'>') {
                t += 1;
            }
            if at(s, t) == b'>' {
                return Some(t + 1);
            }
        } else {
            let t = if at(s, r) == b'/' { r + 1 } else { r };
            if at(s, t) == b'>' {
                return Some(t + 1);
            }
        }
    }
    // `<` scheme `:` then anything but blanks, `<` and `>`, then `>`
    if at(s, p).is_ascii_alphabetic() {
        let mut r = p + 1;
        while at(s, r).is_ascii_alphanumeric() || matches!(at(s, r), b'+' | b'.' | b'-') {
            r += 1;
        }
        if at(s, r) == b':' {
            let mut t = r + 1;
            while t < s.len() && !matches!(at(s, t), b'<' | b'>') && js_ws_len(s, t) == 0 {
                t += 1;
            }
            if at(s, t) == b'>' {
                return Some(t + 1);
            }
        }
    }
    None
}

/// The name of a `\begin{name}` at `k` (letters and `*`, then `}`).
fn begin_name(s: &[u8], k: usize) -> Option<&[u8]> {
    if sub(s, k, k + 7) != b"\\begin{" {
        return None;
    }
    let mut p = k + 7;
    while at(s, p).is_ascii_alphabetic() || at(s, p) == b'*' {
        p += 1;
    }
    if p > k + 7 && at(s, p) == b'}' {
        Some(sub(s, k + 7, p))
    } else {
        None
    }
}

/// The `$$` that closes a `$$` whose body starts at `from`: a blank line ends
/// the search and a backslash skips the byte after it.
///
/// A direct scan, and linear over the whole segment. The walk ends at the
/// first `$$` that no backslash escapes, at a blank line, or at the end, so
/// a walk that fails has seen no `$$` in its range. A later `$$` the scan
/// could start at inside that range would have ended the walk, unless the
/// walk skipped it as the byte after a backslash; the scan skips the same
/// bytes (every byte that starts anything, `$` among them, is ASCII
/// punctuation, which the scan skips after a backslash as the walk does, and
/// both pair the backslashes of a run from its left end). So a range is
/// walked once, plus at most one overlapping walk from the second `$` of a
/// `$$$`.
fn display_close(s: &[u8], from: usize) -> Option<usize> {
    let mut j = from;
    while j < s.len() {
        let c = at(s, j);
        if c == b'\n' && b2_at(s, j) {
            return None;
        }
        if c == b'\\' {
            j += 2;
            continue;
        }
        if c == b'$' && at(s, j + 1) == b'$' {
            return Some(j);
        }
        j += 1;
    }
    None
}

/// Pandoc's rule for `$...$`: the index of the closing `$` of the `$` at `k`.
///
/// A direct scan, and linear over the whole segment, by the argument of
/// [`display_close`]: the walk consumes its first content byte, then stops
/// at the first `$` that no backslash escapes (a success, or a failure
/// before a digit), at a blank line, or at the end; a `$` it passes over
/// is one the scan does not start at either, except the one right after
/// `k`, so a range is walked at most twice.
fn inline_dollar(s: &[u8], k: usize) -> Option<usize> {
    let n = s.len();
    let mut j = k + 1;
    if j >= n || is_ws(at(s, j)) {
        return None;
    }
    // the first content byte is always consumed, a backslash takes the next with it
    j += if at(s, j) == b'\\' { 2 } else { 1 };
    while j < n {
        let c = at(s, j);
        if c == b'$' {
            return if at(s, j + 1).is_ascii_digit() {
                None
            } else {
                Some(j)
            };
        }
        if c == b'\\' {
            j += 2;
            continue;
        }
        if is_ws(c) {
            let mut e = j;
            let mut newlines = 0;
            while e < n && is_ws(at(s, e)) {
                if at(s, e) == b'\n' {
                    newlines += 1;
                }
                e += 1;
            }
            if newlines >= 2 || (newlines == 1 && b2_at(s, j)) || at(s, e) == b'$' {
                return None;
            }
            j = e;
            continue;
        }
        j += 1;
    }
    None
}

/// The state of one `scan_text` call.
struct Scan<'a, 'o> {
    s: &'a [u8],
    /// Offset of `s` in the normalized source.
    base: usize,
    out: &'o mut Out,
    /// Bytes of `s` before this index are written; the bytes from here to the
    /// scan position are copied unchanged and still pending.
    run: usize,
    /// The indexes and memos that answer the scans that look ahead.
    ix: SegIndex<'a>,
}

impl<'a> Scan<'a, '_> {
    /// Writes the pending copied bytes up to `upto`.
    fn flush(&mut self, upto: usize) {
        self.out.buf.extend_from_slice(sub(self.s, self.run, upto));
        self.run = upto;
    }

    /// The reference's `add`: a math whose TeX is `clean_tex(s[a..b])`.
    fn add(&mut self, tex: (usize, usize), display: bool, kind: Kind, span: (usize, usize)) {
        let (start, end) = span;
        let tex = clean_tex(sub(self.s, tex.0, tex.1));
        let block = display && line_only_around(self.s, start, end);
        self.push_math(tex, display, block, kind, span);
    }

    /// Records a math over `span` and writes its placeholder.
    fn push_math(
        &mut self,
        tex: String,
        display: bool,
        block: bool,
        kind: Kind,
        span: (usize, usize),
    ) {
        let (start, end) = span;
        self.flush(start);
        let index = self.out.maths.len();
        self.out.maths.push(Math {
            tex,
            display,
            block,
            kind,
            raw: lossy(sub(self.s, start, end)),
        });
        let t0 = self.out.buf.len();
        push_placeholder(&mut self.out.buf, index + 1, display);
        let t1 = self.out.buf.len();
        self.out.edits.push(Edit {
            src: self.base + start..self.base + end,
            text: t0..t1,
            math: Some(index),
        });
        self.run = end;
    }

    /// A `$` that forms no math is written as `\$`.
    fn escape_dollar(&mut self, k: usize) {
        self.flush(k);
        let t0 = self.out.buf.len();
        self.out.buf.extend_from_slice(b"\\$");
        self.out.edits.push(Edit {
            src: self.base + k..self.base + k + 1,
            text: t0..t0 + 2,
            math: None,
        });
        self.run = k + 1;
    }

    /// A backslash at `k`: doubled and single delimiters, a bare environment,
    /// an escaped punctuation byte. Returns the next position.
    fn backslash(&mut self, k: usize) -> usize {
        let s: &'a [u8] = self.s;
        let d = at(s, k + 1);
        // doubled delimiters \\( \\) and \\[ \\]
        if d == b'\\' && matches!(at(s, k + 2), b'(' | b'[') {
            let open = at(s, k + 2);
            let close = if open == b'(' { b')' } else { b']' };
            if let Some(e) = self.ix.find_doubled_close(k + 3, close) {
                if !self.ix.has_b1(k, e) {
                    self.add((k + 3, e), open == b'[', Kind::Doubled, (k, e + 3));
                    return e + 3;
                }
            }
        }
        if d == b'(' || d == b'[' {
            let close = if d == b'(' { b')' } else { b']' };
            if let Some(found) = self.ix.walk_paren(k, close) {
                let kind = if d == b'(' {
                    Kind::Paren
                } else {
                    Kind::Bracket
                };
                self.add((k + 2, found), d == b'[', kind, (k, found + 2));
                return found + 2;
            }
        }
        if let Some(name) = begin_name(s, k) {
            if let Some(found) = self.ix.env_end(k, name) {
                if !self.ix.has_b1(k, found) {
                    self.add((k, found), true, Kind::Env, (k, found));
                    return found;
                }
            }
        }
        if is_punct(d) {
            return k + 2;
        }
        k + 1
    }

    /// A `$` at `k`. Returns the next position.
    fn dollar(&mut self, k: usize) -> usize {
        let s = self.s;
        // backtick form $`...`$
        if at(s, k + 1) == b'`' {
            let mut r = k + 1;
            while at(s, r) == b'`' {
                r += 1;
            }
            let run = r - k - 1;
            if let Some(close) = self.ix.backtick_close(r, run) {
                if at(s, close + run) == b'$' {
                    let inner: Vec<u8> = sub(s, r, close)
                        .iter()
                        .map(|&c| if c == b'\n' { b' ' } else { c })
                        .collect();
                    let n = inner.len();
                    let strip = n > 1
                        && at(&inner, 0) == b' '
                        && at(&inner, n - 1) == b' '
                        && !js_trim(&inner).is_empty();
                    let tex = if strip {
                        sub(&inner, 1, n - 1)
                    } else {
                        &inner[..]
                    };
                    let end = close + run + 1;
                    self.push_math(lossy(tex), false, false, Kind::Backtick, (k, end));
                    return end;
                }
            }
        }
        // display $$...$$
        if at(s, k + 1) == b'$' {
            if let Some(found) = display_close(s, k + 2) {
                if !js_trim(sub(s, k + 2, found)).is_empty() {
                    self.add((k + 2, found), true, Kind::Dollars, (k, found + 2));
                    return found + 2;
                }
            }
        }
        // inline $...$ (pandoc)
        if let Some(r) = inline_dollar(s, k) {
            self.add((k + 1, r), false, Kind::Dollar, (k, r + 1));
            return r + 1;
        }
        self.escape_dollar(k);
        k + 1
    }
}

/// Scans one text segment `s`, which starts at byte `base` of the normalized
/// source, appending its output, maths and edits to `out`.
pub(crate) fn scan_text(s: &[u8], base: usize, out: &mut Out) {
    let mut sc = Scan {
        s,
        base,
        out,
        run: 0,
        ix: SegIndex::new(s),
    };
    let n = s.len();
    let mut k = 0;
    while k < n {
        match at(s, k) {
            b'<' => k = match_markup(s, k).unwrap_or(k + 1),
            b'\\' => k = sc.backslash(k),
            b'`' => {
                // a code span is copied whole; an unclosed run only itself
                let mut r = k;
                while at(s, r) == b'`' {
                    r += 1;
                }
                k = match sc.ix.backtick_close(r, r - k) {
                    Some(close) => close + (r - k),
                    None => r,
                };
            }
            b'$' => k = sc.dollar(k),
            _ => k += 1,
        }
    }
    sc.flush(n);
}
