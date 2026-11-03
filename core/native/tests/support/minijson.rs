//! A small JSON reader for the tests' fixtures, so the library's tests need
//! no dependency beyond the library's own. Included with
//! `#[path = "support/minijson.rs"] mod minijson;` by the tests that read
//! fixtures.
#![allow(dead_code)]

/// A JSON value. Objects keep their keys in the order of the text.
#[derive(Clone, Debug, PartialEq)]
pub enum J {
    Null,
    Bool(bool),
    Num(f64),
    Str(String),
    Arr(Vec<J>),
    Obj(Vec<(String, J)>),
}

impl J {
    /// The value of `key` when this is an object that has it (the first one).
    pub fn get(&self, key: &str) -> Option<&J> {
        self.as_obj()?.iter().find(|(k, _)| k == key).map(|(_, v)| v)
    }

    pub fn as_str(&self) -> Option<&str> {
        match self {
            J::Str(s) => Some(s),
            _ => None,
        }
    }

    pub fn as_f64(&self) -> Option<f64> {
        match self {
            J::Num(n) => Some(*n),
            _ => None,
        }
    }

    pub fn as_obj(&self) -> Option<&[(String, J)]> {
        match self {
            J::Obj(o) => Some(o),
            _ => None,
        }
    }

    pub fn as_arr(&self) -> Option<&[J]> {
        match self {
            J::Arr(a) => Some(a),
            _ => None,
        }
    }
}

/// Parses one JSON text (RFC 8259). An error names the byte offset where
/// the text stops being JSON.
pub fn parse(text: &str) -> Result<J, String> {
    let mut p = Parser { s: text.as_bytes(), i: 0 };
    p.ws();
    let v = p.value()?;
    p.ws();
    if p.i != p.s.len() {
        return Err(p.err("trailing characters after the value"));
    }
    Ok(v)
}

struct Parser<'a> {
    s: &'a [u8],
    i: usize,
}

impl Parser<'_> {
    fn err(&self, what: &str) -> String {
        format!("at byte {}: {what}", self.i)
    }

    fn peek(&self) -> Option<u8> {
        self.s.get(self.i).copied()
    }

    fn ws(&mut self) {
        while matches!(self.peek(), Some(b' ' | b'\t' | b'\n' | b'\r')) {
            self.i += 1;
        }
    }

    fn expect(&mut self, c: u8) -> Result<(), String> {
        if self.peek() == Some(c) {
            self.i += 1;
            Ok(())
        } else {
            Err(self.err(&format!("expected '{}'", c as char)))
        }
    }

    fn value(&mut self) -> Result<J, String> {
        match self.peek() {
            None => Err(self.err("unexpected end of the text")),
            Some(b'{') => self.object(),
            Some(b'[') => self.array(),
            Some(b'"') => self.string().map(J::Str),
            Some(b't') => self.word("true", J::Bool(true)),
            Some(b'f') => self.word("false", J::Bool(false)),
            Some(b'n') => self.word("null", J::Null),
            Some(b'-' | b'0'..=b'9') => self.number(),
            Some(c) => Err(self.err(&format!("unexpected '{}'", c as char))),
        }
    }

    fn word(&mut self, w: &str, v: J) -> Result<J, String> {
        if self.s[self.i..].starts_with(w.as_bytes()) {
            self.i += w.len();
            Ok(v)
        } else {
            Err(self.err(&format!("expected {w}")))
        }
    }

    fn object(&mut self) -> Result<J, String> {
        self.expect(b'{')?;
        let mut o = Vec::new();
        self.ws();
        if self.peek() == Some(b'}') {
            self.i += 1;
            return Ok(J::Obj(o));
        }
        loop {
            self.ws();
            if self.peek() != Some(b'"') {
                return Err(self.err("expected a string key"));
            }
            let k = self.string()?;
            self.ws();
            self.expect(b':')?;
            self.ws();
            let v = self.value()?;
            o.push((k, v));
            self.ws();
            match self.peek() {
                Some(b',') => self.i += 1,
                Some(b'}') => {
                    self.i += 1;
                    return Ok(J::Obj(o));
                }
                _ => return Err(self.err("expected ',' or '}'")),
            }
        }
    }

    fn array(&mut self) -> Result<J, String> {
        self.expect(b'[')?;
        let mut a = Vec::new();
        self.ws();
        if self.peek() == Some(b']') {
            self.i += 1;
            return Ok(J::Arr(a));
        }
        loop {
            self.ws();
            a.push(self.value()?);
            self.ws();
            match self.peek() {
                Some(b',') => self.i += 1,
                Some(b']') => {
                    self.i += 1;
                    return Ok(J::Arr(a));
                }
                _ => return Err(self.err("expected ',' or ']'")),
            }
        }
    }

    fn digits(&mut self) -> usize {
        let start = self.i;
        while matches!(self.peek(), Some(b'0'..=b'9')) {
            self.i += 1;
        }
        self.i - start
    }

    fn number(&mut self) -> Result<J, String> {
        let start = self.i;
        if self.peek() == Some(b'-') {
            self.i += 1;
        }
        match self.peek() {
            Some(b'0') => self.i += 1,
            Some(b'1'..=b'9') => {
                self.digits();
            }
            _ => return Err(self.err("expected a digit")),
        }
        if self.peek() == Some(b'.') {
            self.i += 1;
            if self.digits() == 0 {
                return Err(self.err("expected a digit after '.'"));
            }
        }
        if matches!(self.peek(), Some(b'e' | b'E')) {
            self.i += 1;
            if matches!(self.peek(), Some(b'+' | b'-')) {
                self.i += 1;
            }
            if self.digits() == 0 {
                return Err(self.err("expected a digit in the exponent"));
            }
        }
        // The slice is ASCII digits, signs, '.' and 'e': valid UTF-8, and
        // Rust's float parsing rounds it correctly.
        let t = std::str::from_utf8(&self.s[start..self.i]).map_err(|_| self.err("bad number"))?;
        t.parse::<f64>().map(J::Num).map_err(|_| self.err("bad number"))
    }

    fn hex4(&mut self) -> Result<u32, String> {
        let h = self.s.get(self.i..self.i + 4).ok_or_else(|| self.err("short \\u escape"))?;
        if !h.iter().all(u8::is_ascii_hexdigit) {
            return Err(self.err("bad \\u escape"));
        }
        let v = u32::from_str_radix(std::str::from_utf8(h).map_err(|_| self.err("bad \\u escape"))?, 16)
            .map_err(|_| self.err("bad \\u escape"))?;
        self.i += 4;
        Ok(v)
    }

    fn string(&mut self) -> Result<String, String> {
        self.expect(b'"')?;
        let mut out: Vec<u8> = Vec::new();
        loop {
            let Some(c) = self.peek() else {
                return Err(self.err("unterminated string"));
            };
            match c {
                b'"' => {
                    self.i += 1;
                    // Only whole UTF-8 sequences of the text and chars are pushed.
                    return String::from_utf8(out).map_err(|_| self.err("bad UTF-8 in a string"));
                }
                b'\\' => {
                    self.i += 1;
                    let e = self.peek().ok_or_else(|| self.err("unterminated escape"))?;
                    self.i += 1;
                    let ch = match e {
                        b'"' => '"',
                        b'\\' => '\\',
                        b'/' => '/',
                        b'b' => '\u{8}',
                        b'f' => '\u{c}',
                        b'n' => '\n',
                        b'r' => '\r',
                        b't' => '\t',
                        b'u' => {
                            let hi = self.hex4()?;
                            let cp = if (0xd800..0xdc00).contains(&hi) {
                                if !self.s[self.i..].starts_with(b"\\u") {
                                    return Err(self.err("a high surrogate without its low surrogate"));
                                }
                                self.i += 2;
                                let lo = self.hex4()?;
                                if !(0xdc00..0xe000).contains(&lo) {
                                    return Err(self.err("a high surrogate without its low surrogate"));
                                }
                                0x10000 + ((hi - 0xd800) << 10) + (lo - 0xdc00)
                            } else if (0xdc00..0xe000).contains(&hi) {
                                return Err(self.err("a low surrogate on its own"));
                            } else {
                                hi
                            };
                            char::from_u32(cp).ok_or_else(|| self.err("bad \\u escape"))?
                        }
                        _ => return Err(self.err("unknown escape")),
                    };
                    let mut buf = [0u8; 4];
                    out.extend_from_slice(ch.encode_utf8(&mut buf).as_bytes());
                }
                0x00..=0x1f => return Err(self.err("a control character in a string")),
                _ => {
                    out.push(c);
                    self.i += 1;
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_nested_sample() {
        let j = parse(r#" { "a": [1, -2.5, 3e2, 0.25E-1, true, false, null], "b": { "c": "d", "e": {} }, "f": [] } "#)
            .unwrap();
        let a = j.get("a").and_then(J::as_arr).unwrap();
        assert_eq!(a.len(), 7);
        assert_eq!(a[0].as_f64(), Some(1.0));
        assert_eq!(a[1].as_f64(), Some(-2.5));
        assert_eq!(a[2].as_f64(), Some(300.0));
        assert_eq!(a[3].as_f64(), Some(0.025));
        assert_eq!(a[4], J::Bool(true));
        assert_eq!(a[5], J::Bool(false));
        assert_eq!(a[6], J::Null);
        let b = j.get("b").unwrap();
        assert_eq!(b.get("c").and_then(J::as_str), Some("d"));
        assert_eq!(b.get("e").and_then(J::as_obj).map(|o| o.len()), Some(0));
        assert_eq!(j.get("f").and_then(J::as_arr).map(|v| v.len()), Some(0));
        assert_eq!(j.get("nope"), None);
        // keys keep their order
        let keys: Vec<&str> = j.as_obj().unwrap().iter().map(|(k, _)| k.as_str()).collect();
        assert_eq!(keys, ["a", "b", "f"]);
        assert_eq!(a[0].as_str(), None);
        assert_eq!(j.as_arr(), None);
    }

    #[test]
    fn string_escapes() {
        let j = parse(r#""q\" b\\ s\/ \b\f\n\r\t u\u00e9 \u20AC \ud83d\ude00""#).unwrap();
        assert_eq!(j.as_str(), Some("q\" b\\ s/ \u{8}\u{c}\n\r\t u\u{e9} \u{20ac} \u{1f600}"));
        assert_eq!(parse("\"plain é\"").unwrap().as_str(), Some("plain é"));
    }

    #[test]
    fn errors_name_the_position() {
        let e = parse(r#"{"a": [1, 2,, 3]}"#).unwrap_err();
        assert!(e.contains("byte 12"), "{e}");
        for bad in [
            "", "{", "[1, 2", "{\"a\" 1}", "{\"a\": 1,}", "[1,]", "tru", "nul", "01", "1.", ".5", "-", "1e",
            "\"abc", "\"\\x\"", "\"\\u12\"", "\"\\ud83d\"", "\"\\ude00\"", "{1: 2}", "[1] x", "\"a\nb\"",
        ] {
            assert!(parse(bad).is_err(), "{bad:?} parsed");
        }
    }
}
