//! Reader of the golden case files written by `tests/mathgrammar/gen_cases.mjs`.
//!
//! The format (UTF-8; every length is a decimal byte count and each payload
//! is followed by one `\n`) is described in `tests/mathgrammar/README.md`.
//! The reader needs no JSON crate and no node: the files are committed.

#![allow(dead_code)]

use std::path::{Path, PathBuf};

/// One document: a list of sources typeset in order.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Doc {
    pub name: String,
    pub sources: Vec<String>,
    /// The reference's extracted text, one per source.
    pub texts: Vec<String>,
    /// Every math of every source, in document order.
    pub maths: Vec<CaseMath>,
}

/// One math as the reference found it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CaseMath {
    /// The index of the source it came from.
    pub source: usize,
    pub display: bool,
    pub block: bool,
    pub kind: String,
    pub tex: String,
    pub raw: String,
    /// `prepareTex` over the document's maths.
    pub prepared: String,
    /// `katexNewcommand` (`tests/mathgrammar/katex_rule.mjs`, deviation D5) of `prepared`, one set of
    /// defined names per document.
    pub katex: String,
    /// The MathJax text: `prepareTex` with MathJax's starred forms of a numbered `eqnarray` and
    /// `multline` (deviation D6). The file holds it only where it differs from `prepared`; the
    /// reader fills in `prepared` where it is absent.
    pub mathjax: String,
}

impl Doc {
    /// The maths that came from source `s`, in order.
    pub fn maths_of(&self, s: usize) -> Vec<&CaseMath> {
        self.maths.iter().filter(|m| m.source == s).collect()
    }
}

struct Cur<'a> {
    b: &'a [u8],
    pos: usize,
}

impl<'a> Cur<'a> {
    fn err<T>(&self, at: usize, want: &str) -> Result<T, String> {
        let found: String = self.b[at.min(self.b.len())..]
            .iter()
            .take(24)
            .take_while(|&&c| c != b'\n')
            .map(|&c| {
                if c.is_ascii_graphic() || c == b' ' {
                    c as char
                } else {
                    '?'
                }
            })
            .collect();
        let found = if at >= self.b.len() {
            "end of file".to_string()
        } else {
            format!("`{found}`")
        };
        Err(format!("at byte {at}: expected {want}, found {found}"))
    }

    /// The next line without its `\n`, and move past it.
    fn line(&mut self, want: &str) -> Result<&'a str, String> {
        let start = self.pos;
        let Some(n) = self.b[start..].iter().position(|&c| c == b'\n') else {
            return self.err(start, want);
        };
        let s = match std::str::from_utf8(&self.b[start..start + n]) {
            Ok(s) => s,
            Err(_) => return self.err(start, &format!("{want} (valid UTF-8)")),
        };
        self.pos = start + n + 1;
        Ok(s)
    }

    /// The next line without consuming it; "" at the end of the file.
    fn peek(&self) -> &'a str {
        let rest = &self.b[self.pos..];
        let n = rest.iter().position(|&c| c == b'\n').unwrap_or(rest.len());
        std::str::from_utf8(&rest[..n]).unwrap_or("")
    }

    /// `<label> <len>\n<payload>\n`.
    fn field(&mut self, label: &str) -> Result<String, String> {
        let at = self.pos;
        let head = self.line(&format!("`{label} <len>`"))?;
        let want = format!("`{label} <len>`");
        let Some(num) = head.strip_prefix(label).and_then(|r| r.strip_prefix(' ')) else {
            return self.err(at, &want);
        };
        let Some(len) = parse_num(num) else {
            return self.err(at, &want);
        };
        let start = self.pos;
        let Some(end) = start.checked_add(len).filter(|&e| e < self.b.len()) else {
            return self.err(
                self.b.len(),
                &format!("{len} payload bytes of `{label}` and a newline"),
            );
        };
        if self.b[end] != b'\n' {
            return self.err(
                end,
                &format!("a newline after the {len} payload bytes of `{label}`"),
            );
        }
        let s = match std::str::from_utf8(&self.b[start..end]) {
            Ok(s) => s,
            Err(_) => return self.err(start, &format!("a valid UTF-8 payload for `{label}`")),
        };
        self.pos = end + 1;
        Ok(s.to_string())
    }
}

fn parse_num(s: &str) -> Option<usize> {
    if s.is_empty() || !s.bytes().all(|c| c.is_ascii_digit()) {
        return None;
    }
    s.parse().ok()
}

fn parse_flag(s: &str) -> Option<bool> {
    match s {
        "0" => Some(false),
        "1" => Some(true),
        _ => None,
    }
}

fn parse_math(c: &mut Cur, sources: usize) -> Result<CaseMath, String> {
    let at = c.pos;
    let head = c.line("a `math` line")?;
    let want = "`math <source> <display 0|1> <block 0|1> <kind>`";
    let parts: Vec<&str> = head.split(' ').collect();
    let ok = parts.len() == 5 && parts[0] == "math";
    let source = if ok {
        parse_num(parts[1]).filter(|&s| s < sources)
    } else {
        None
    };
    let display = if ok { parse_flag(parts[2]) } else { None };
    let block = if ok { parse_flag(parts[3]) } else { None };
    let kind_ok = ok && !parts[4].is_empty() && parts[4].bytes().all(|b| b.is_ascii_lowercase());
    let (Some(source), Some(display), Some(block), true) = (source, display, block, kind_ok) else {
        return c.err(at, want);
    };
    let tex = c.field("tex")?;
    let raw = c.field("raw")?;
    let prepared = c.field("prepared")?;
    let katex = c.field("katex")?;
    let mathjax = if c.peek().starts_with("mathjax ") {
        let at = c.pos;
        let m = c.field("mathjax")?;
        if m == prepared {
            return c.err(
                at,
                "a `mathjax` field only where it differs from `prepared`",
            );
        }
        m
    } else {
        prepared.clone()
    };
    Ok(CaseMath {
        source,
        display,
        block,
        kind: parts[4].to_string(),
        tex,
        raw,
        prepared,
        katex,
        mathjax,
    })
}

fn parse_doc(c: &mut Cur, name: &str) -> Result<Doc, String> {
    let mut sources = Vec::new();
    while c.peek().starts_with("src ") {
        sources.push(c.field("src")?);
    }
    if sources.is_empty() {
        return c.err(c.pos, "a `src <len>` field");
    }
    let mut texts = Vec::new();
    for _ in 0..sources.len() {
        texts.push(c.field("text")?);
    }
    let mut maths = Vec::new();
    while c.peek().starts_with("math ") {
        maths.push(parse_math(c, sources.len())?);
    }
    let at = c.pos;
    if c.line("`math ...` or `end`")? != "end" {
        return c.err(at, "`math ...` or `end`");
    }
    Ok(Doc {
        name: name.to_string(),
        sources,
        texts,
        maths,
    })
}

/// Parses a whole case file. An error names the byte offset and what was
/// expected there; the trailer count must match the documents read.
pub fn parse(b: &[u8]) -> Result<Vec<Doc>, String> {
    let mut c = Cur { b, pos: 0 };
    let at = c.pos;
    if c.line("`JNVMATH 2`")? != "JNVMATH 2" {
        return c.err(at, "`JNVMATH 2`");
    }
    let mut docs = Vec::new();
    loop {
        let at = c.pos;
        let head = c.line("`doc <name>` or `count <n>`")?;
        if let Some(name) = head.strip_prefix("doc ") {
            let doc = parse_doc(&mut c, name)?;
            docs.push(doc);
        } else if let Some(n) = head.strip_prefix("count ").and_then(parse_num) {
            if n != docs.len() {
                return Err(format!(
                    "at byte {at}: the trailer counts {n} documents but {} were read",
                    docs.len()
                ));
            }
            if c.pos != b.len() {
                return c.err(c.pos, "the end of the file after the count");
            }
            return Ok(docs);
        } else {
            return c.err(at, "`doc <name>` or `count <n>`");
        }
    }
}

/// Reads and parses a case file; panics naming the path on any failure.
pub fn load(path: &Path) -> Vec<Doc> {
    let b = std::fs::read(path).unwrap_or_else(|e| panic!("reading {}: {e}", path.display()));
    parse(&b).unwrap_or_else(|e| panic!("parsing {}: {e}", path.display()))
}

/// A string for a message: `\n`, `\t`, `\r` and `\\` escaped, other control
/// characters and everything outside printable ASCII as `\u{..}`.
pub fn esc(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 8);
    for ch in s.chars() {
        match ch {
            '\n' => out.push_str("\\n"),
            '\t' => out.push_str("\\t"),
            '\r' => out.push_str("\\r"),
            '\\' => out.push_str("\\\\"),
            ' '..='~' => out.push(ch),
            _ => out.push_str(&format!("\\u{{{:x}}}", ch as u32)),
        }
    }
    out
}

/// `tests/mathgrammar/golden/<name>` of the repository.
pub fn golden(name: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/mathgrammar/golden")
        .join(name)
}
