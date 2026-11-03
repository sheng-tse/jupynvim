//! The block pass of [`extract_math`](super::extract_math): splits a
//! normalized source into fenced code, math fences, indented code and the
//! text segments the inline pass scans.
//!
//! A segment is a run of whole lines. The segments partition the lines in
//! order, so joining their outputs with one `\n` keeps every byte position of
//! the source recoverable.
//!
//! The rules follow the reference line by line, in the same order:
//!
//! - A fence opens on `(quote prefix)(up to 3 blanks)(3 or more of one of
//!   backtick and tilde)(rest)`. A backtick fence whose rest holds a backtick
//!   is not a fence, and neither is a line whose rest holds U+2028 or U+2029
//!   (JavaScript's `.` does not match them).
//! - It closes on a line (after its quote prefix) of up to 3 blanks, a run of
//!   the same character at least as long, and blanks. An unclosed fence runs
//!   to the end of the source. A fence whose trimmed info is `math` (ASCII,
//!   any case) is a display math; any other is code.
//! - Indented code starts on a line with 4 spaces or a tab, that is not blank,
//!   after a blank line and not while a list item is recent; it takes the
//!   following indented or blank lines, less the trailing blank ones.

use super::jsstr::{at, js_line_terminator_in, js_trim, quote_prefix_len};

/// What a segment is.
pub(crate) enum SegKind {
    /// Prose, scanned for math.
    Text,
    /// Fenced or indented code, copied as it is.
    Code,
    /// A ```` ```math ```` fence.
    MathFence {
        /// Offset in the normalized source where the quote prefix ends and the
        /// replaced part of the fence begins.
        prefix_end: usize,
        /// The TeX: the body lines without their quote prefix, trimmed.
        tex: String,
        /// The fence lines, joined.
        raw: String,
    },
}

/// A range of whole lines of the normalized source, `end` before the `\n`
/// that separates it from the next segment.
pub(crate) struct Segment {
    pub start: usize,
    pub end: usize,
    pub kind: SegKind,
}

/// The bytes `a..b`, empty when out of range.
fn sub(b: &[u8], a: usize, e: usize) -> &[u8] {
    b.get(a..e).unwrap_or_default()
}

fn lossy(b: &[u8]) -> String {
    String::from_utf8_lossy(b).into_owned()
}

/// Line `i`, empty when there is no such line.
fn line_at<'a>(b: &'a [u8], lines: &[(usize, usize)], i: usize) -> &'a [u8] {
    match lines.get(i) {
        Some(&(s, e)) => sub(b, s, e),
        None => &[],
    }
}

fn blank(line: &[u8]) -> bool {
    js_trim(line).is_empty()
}

fn indented(line: &[u8]) -> bool {
    line.starts_with(b"    ") || line.starts_with(b"\t")
}

/// `[start, end)` of every line; a trailing `\n` gives a trailing empty line
/// and an empty source is one empty line, as `String.split("\n")` does.
fn line_table(b: &[u8]) -> Vec<(usize, usize)> {
    let mut lines = Vec::new();
    let mut start = 0;
    for (i, &c) in b.iter().enumerate() {
        if c == b'\n' {
            lines.push((start, i));
            start = i + 1;
        }
    }
    lines.push((start, b.len()));
    lines
}

/// An opening fence: the quote prefix length, the fence character, the length
/// of the run and the rest of the line.
struct FenceOpen<'a> {
    prefix: usize,
    ch: u8,
    run: usize,
    rest: &'a [u8],
}

/// `^((?:[ \t]{0,3}>[ \t]?)*)([ \t]*)(`{3,}|~{3,})(.*)$` with the reference's
/// checks on top: at most 3 blanks of indent, and no backtick in the rest of
/// a backtick fence.
fn fence_open(line: &[u8]) -> Option<FenceOpen<'_>> {
    let prefix = quote_prefix_len(line);
    let mut p = prefix;
    while matches!(at(line, p), b' ' | b'\t') {
        p += 1;
    }
    let indent = p - prefix;
    let ch = at(line, p);
    if ch != b'`' && ch != b'~' {
        return None;
    }
    let mut r = p;
    while at(line, r) == ch {
        r += 1;
    }
    let run = r - p;
    if run < 3 {
        return None;
    }
    let rest = sub(line, r, line.len());
    if js_line_terminator_in(rest) || indent > 3 || (ch == b'`' && rest.contains(&b'`')) {
        return None;
    }
    Some(FenceOpen {
        prefix,
        ch,
        run,
        rest,
    })
}

/// Whether `line` closes a fence of `run` characters `ch`: after its quote
/// prefix, up to 3 blanks, a run of `ch` of at least `run`, and only blanks.
fn fence_close(line: &[u8], ch: u8, run: usize) -> bool {
    let l = sub(line, quote_prefix_len(line), line.len());
    let mut p = 0;
    while p < 3 && matches!(at(l, p), b' ' | b'\t') {
        p += 1;
    }
    if at(l, p) != ch {
        return false;
    }
    let mut r = p;
    while at(l, r) == ch {
        r += 1;
    }
    r - p >= run && sub(l, r, l.len()).iter().all(|&c| c == b' ' || c == b'\t')
}

/// `^[ \t]{0,3}([-*+]|\d{1,9}[.)])([ \t]|$)`.
fn list_item(line: &[u8]) -> bool {
    let mut p = 0;
    while p < 3 && matches!(at(line, p), b' ' | b'\t') {
        p += 1;
    }
    let after = if matches!(at(line, p), b'-' | b'*' | b'+') {
        p + 1
    } else {
        let mut q = p;
        while at(line, q).is_ascii_digit() {
            q += 1;
        }
        let digits = q - p;
        if digits == 0 || digits > 9 || !matches!(at(line, q), b'.' | b')') {
            return false;
        }
        q + 1
    };
    after >= line.len() || matches!(at(line, after), b' ' | b'\t')
}

/// The segments of `norm`, in order, covering every line.
pub(crate) fn segments(norm: &str) -> Vec<Segment> {
    let b = norm.as_bytes();
    let lines = line_table(b);
    let line = |i: usize| line_at(b, &lines, i);
    let mut segs: Vec<Segment> = Vec::new();
    let mut i = 0;
    let mut in_list_recently = false;
    let mut prev_blank = true;
    while i < lines.len() {
        let text = line(i);
        let (ls, _) = lines.get(i).copied().unwrap_or((0, 0));
        if let Some(open) = fence_open(text) {
            // body and closing line
            let mut j = i + 1;
            let mut closed = false;
            while j < lines.len() {
                if fence_close(line(j), open.ch, open.run) {
                    closed = true;
                    break;
                }
                j += 1;
            }
            let last = if closed { j } else { j.saturating_sub(1) };
            let le = lines.get(last).map_or(b.len(), |&(_, e)| e);
            if js_trim(open.rest).eq_ignore_ascii_case(b"math") {
                let mut tex: Vec<u8> = Vec::new();
                for (n, k) in (i + 1..j).enumerate() {
                    if n > 0 {
                        tex.push(b'\n');
                    }
                    let l = line(k);
                    tex.extend_from_slice(sub(l, quote_prefix_len(l), l.len()));
                }
                segs.push(Segment {
                    start: ls,
                    end: le,
                    kind: SegKind::MathFence {
                        prefix_end: ls + open.prefix,
                        tex: lossy(js_trim(&tex)),
                        raw: lossy(sub(b, ls, le)),
                    },
                });
            } else {
                segs.push(Segment {
                    start: ls,
                    end: le,
                    kind: SegKind::Code,
                });
            }
            i = if closed { j + 1 } else { j };
            prev_blank = false;
            continue;
        }
        // indented code: 4+ spaces after a blank line, not continuing a list
        if indented(text) && !blank(text) && prev_blank && !in_list_recently {
            let mut j = i;
            while j < lines.len() && (indented(line(j)) || blank(line(j))) {
                j += 1;
            }
            while j > i + 1 && blank(line(j - 1)) {
                j -= 1;
            }
            let le = lines.get(j - 1).map_or(b.len(), |&(_, e)| e);
            segs.push(Segment {
                start: ls,
                end: le,
                kind: SegKind::Code,
            });
            i = j;
            prev_blank = false;
            continue;
        }
        let le = lines.get(i).map_or(b.len(), |&(_, e)| e);
        if blank(text) {
            prev_blank = true;
        } else {
            if list_item(text) {
                in_list_recently = true;
            } else if !matches!(at(text, 0), b' ' | b'\t') && prev_blank {
                in_list_recently = false;
            }
            prev_blank = false;
        }
        match segs.last_mut() {
            Some(Segment {
                end,
                kind: SegKind::Text,
                ..
            }) => *end = le,
            _ => segs.push(Segment {
                start: ls,
                end: le,
                kind: SegKind::Text,
            }),
        }
        i += 1;
    }
    segs
}
