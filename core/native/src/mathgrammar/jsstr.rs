//! JavaScript string semantics the grammar depends on. The reference is
//! written in JavaScript, where `\s`, `trim()` and `.` follow Unicode rules
//! that differ from Rust's (`trim()` and `\s` strip U+00A0 and U+FEFF but not
//! U+0085, and `.` does not match U+2028 or U+2029). The scanners work on
//! UTF-8 bytes, so every helper here takes bytes and never allocates.

/// Whether `c` is JavaScript `\s`: U+0009 to U+000D, U+0020, U+00A0,
/// U+1680, U+2000 to U+200A, U+2028, U+2029, U+202F, U+205F, U+3000 and
/// U+FEFF.
pub fn js_ws(c: char) -> bool {
    matches!(
        c,
        '\u{9}'..='\u{d}'
            | ' '
            | '\u{a0}'
            | '\u{1680}'
            | '\u{2000}'..='\u{200a}'
            | '\u{2028}'
            | '\u{2029}'
            | '\u{202f}'
            | '\u{205f}'
            | '\u{3000}'
            | '\u{feff}'
    )
}

/// The byte at `i`, or 0 past the end. No compared character is NUL, so the
/// sentinel never matches anything the scanners look for.
#[inline]
pub(crate) fn at(s: &[u8], i: usize) -> u8 {
    s.get(i).copied().unwrap_or(0)
}

/// The byte length of the JavaScript whitespace character that starts at
/// `i` in `s`, else 0. Works on the UTF-8 byte patterns of the 25 characters,
/// so a continuation byte or a truncated character answers 0.
pub fn js_ws_len(s: &[u8], i: usize) -> usize {
    match at(s, i) {
        0x09..=0x0d | 0x20 => 1,
        // U+00A0
        0xc2 => usize::from(at(s, i + 1) == 0xa0) * 2,
        // U+1680
        0xe1 => usize::from(at(s, i + 1) == 0x9a && at(s, i + 2) == 0x80) * 3,
        0xe2 => {
            let (b1, b2) = (at(s, i + 1), at(s, i + 2));
            // U+2000 to U+200A, U+2028, U+2029, U+202F; U+205F
            let hit = (b1 == 0x80 && matches!(b2, 0x80..=0x8a | 0xa8 | 0xa9 | 0xaf))
                || (b1 == 0x81 && b2 == 0x9f);
            usize::from(hit) * 3
        }
        // U+3000
        0xe3 => usize::from(at(s, i + 1) == 0x80 && at(s, i + 2) == 0x80) * 3,
        // U+FEFF
        0xef => usize::from(at(s, i + 1) == 0xbb && at(s, i + 2) == 0xbf) * 3,
        _ => 0,
    }
}

/// The byte length of the JavaScript whitespace character that ends at
/// `end` (exclusive), else 0.
fn js_ws_len_before(s: &[u8], end: usize) -> usize {
    for len in 1..=3usize {
        let Some(start) = end.checked_sub(len) else {
            break;
        };
        let Some(piece) = s.get(start..end) else {
            break;
        };
        if js_ws_len(piece, 0) == len {
            return len;
        }
    }
    0
}

/// `String.prototype.trim` on UTF-8 bytes.
pub fn js_trim(s: &[u8]) -> &[u8] {
    let mut a = 0;
    loop {
        let n = js_ws_len(s, a);
        if n == 0 {
            break;
        }
        a += n;
    }
    let mut b = s.len();
    while b > a {
        let n = js_ws_len_before(s, b);
        if n == 0 || b - n < a {
            break;
        }
        b -= n;
    }
    s.get(a..b).unwrap_or_default()
}

/// Whether `s` contains U+2028 or U+2029 (the bytes E2 80 A8 or E2 80 A9),
/// which JavaScript's `.` does not match.
pub fn js_line_terminator_in(s: &[u8]) -> bool {
    s.windows(3)
        .any(|w| w[0] == 0xe2 && w[1] == 0x80 && (w[2] == 0xa8 || w[2] == 0xa9))
}

/// The length of the longest greedy `(?:[ \t]{0,3}>[ \t]?)*` prefix of `s`:
/// the blockquote markers in front of a line. Each iteration needs its own
/// `>`, so taking as much as possible is exact.
pub fn quote_prefix_len(s: &[u8]) -> usize {
    let mut p = 0;
    loop {
        let mut q = p;
        while q < p + 3 && matches!(at(s, q), b' ' | b'\t') {
            q += 1;
        }
        if at(s, q) != b'>' {
            return p;
        }
        q += 1;
        if matches!(at(s, q), b' ' | b'\t') {
            q += 1;
        }
        p = q;
    }
}

/// ASCII punctuation, the reference's `PUNCT`.
pub fn is_punct(b: u8) -> bool {
    b.is_ascii_punctuation()
}

/// Space, tab or newline only: the reference's `isWS`.
pub fn is_ws(b: u8) -> bool {
    matches!(b, b' ' | b'\t' | b'\n')
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The 25 code points of JavaScript's `\s`.
    const ALL: [u32; 25] = [
        0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x20, 0xa0, 0x1680, 0x2000, 0x2001, 0x2002, 0x2003, 0x2004,
        0x2005, 0x2006, 0x2007, 0x2008, 0x2009, 0x200a, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000,
        0xfeff,
    ];

    #[test]
    fn nel_is_not_whitespace_and_bom_is() {
        assert!(!js_ws('\u{85}'));
        assert!(js_ws('\u{feff}'));
        assert!(js_ws('\u{a0}'));
        assert!(!js_ws('\u{180e}'));
        assert!(!js_ws('\u{200b}'));
        assert!(!js_ws('a'));
        assert!(!js_ws('\u{1c}'));
    }

    #[test]
    fn ws_len_of_each_whitespace_character() {
        for cp in ALL {
            let c = char::from_u32(cp).unwrap_or('?');
            assert!(js_ws(c), "{cp:x}");
            let mut b = [0u8; 4];
            let enc = c.encode_utf8(&mut b);
            assert_eq!(js_ws_len(enc.as_bytes(), 0), enc.len(), "{cp:x}");
        }
        assert_eq!(js_ws_len("a\u{3000}b".as_bytes(), 1), 3);
        assert_eq!(js_ws_len("\u{85}".as_bytes(), 0), 0);
        assert_eq!(js_ws_len("\u{a0}".as_bytes(), 1), 0, "a continuation byte");
        assert_eq!(js_ws_len(&[0x80], 0), 0, "a lone continuation byte");
        assert_eq!(js_ws_len(&[0xe2, 0x80], 0), 0, "a truncated character");
        assert_eq!(js_ws_len(&[0xc2], 0), 0, "a truncated character");
        assert_eq!(js_ws_len(b"x", 5), 0, "past the end");
        assert_eq!(js_ws_len(b"", 0), 0);
    }

    #[test]
    fn trim_follows_javascript_not_rust() {
        assert_eq!(js_trim(b"\xc2\xa0x\xef\xbb\xbf"), b"x");
        assert_eq!(js_trim(b"\xc2\x85x"), b"\xc2\x85x");
        assert_eq!(js_trim(b"x\xc2\x85"), b"x\xc2\x85");
        assert_eq!(
            js_trim(b" \t\r\n\x0b\x0cx y \xe3\x80\x80\xe2\x80\xa8"),
            b"x y"
        );
        assert_eq!(js_trim(b"   "), b"");
        assert_eq!(js_trim(b""), b"");
        assert_eq!(js_trim("\u{2000}\u{200a}".as_bytes()), b"");
        assert_eq!(js_trim("a\u{200b}".as_bytes()), "a\u{200b}".as_bytes());
        // a character whose last bytes look like whitespace is not trimmed
        assert_eq!(js_trim("\u{e0}".as_bytes()), "\u{e0}".as_bytes());
        assert_eq!(js_trim("x\u{2060}".as_bytes()), "x\u{2060}".as_bytes());
    }

    #[test]
    fn line_terminators() {
        assert!(js_line_terminator_in("a\u{2028}b".as_bytes()));
        assert!(js_line_terminator_in("\u{2029}".as_bytes()));
        assert!(!js_line_terminator_in(
            "\u{2027}\u{202a}\u{2000}".as_bytes()
        ));
        assert!(!js_line_terminator_in(b"\xe2\x80"));
        assert!(!js_line_terminator_in(b""));
        assert!(!js_line_terminator_in(b"plain \n text"));
    }

    #[test]
    fn quote_prefix_lengths() {
        assert_eq!(quote_prefix_len(b"> > x"), 4);
        assert_eq!(quote_prefix_len(b"   > x"), 5);
        assert_eq!(quote_prefix_len(b"    > x"), 0);
        assert_eq!(quote_prefix_len(b">  >"), 4);
        assert_eq!(quote_prefix_len(b"> \t>x"), 4);
        assert_eq!(quote_prefix_len(b">     x"), 2);
        assert_eq!(quote_prefix_len(b"x"), 0);
        assert_eq!(quote_prefix_len(b""), 0);
        assert_eq!(quote_prefix_len(b">"), 1);
        assert_eq!(quote_prefix_len(b"  \t>>>"), 6);
        assert_eq!(quote_prefix_len(b"   x"), 0);
        assert_eq!(quote_prefix_len(b"> x > y"), 2);
    }

    #[test]
    fn ascii_classes() {
        for b in 0..=255u8 {
            let punct = matches!(b, 0x21..=0x2f | 0x3a..=0x40 | 0x5b..=0x60 | 0x7b..=0x7e);
            assert_eq!(is_punct(b), punct, "{b:x}");
            assert_eq!(is_ws(b), matches!(b, b' ' | b'\t' | b'\n'), "{b:x}");
        }
    }
}
