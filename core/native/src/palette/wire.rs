//! The text formats of the palette's job kinds: short UTF-8 text, `\n` line
//! ends, one space between fields. One derivation per colorscheme change
//! moves about 2 KB each way and parses in microseconds, so text costs
//! nothing and Lua can build and read it with string functions.
//!
//! Derive input (kind 2048):
//!
//! ```text
//! JNP 1
//! kind dark|light
//! name <vim.g.colors_name, to the end of the line> | name -
//! term #rrggbb | term -          the terminal's OSC 11 answer, when known
//! set                            also make the result the current palette
//! g <group> <#rrggbb|-> <#rrggbb|->     fg and bg of a highlight group
//! o <token> #rrggbb              an override (`canvas` is the first token)
//! ```
//!
//! `JNP 1` comes first; the other lines may come in any order, each line
//! type at most once (a group or an override at most once each). A group
//! the rules do not read is accepted and dropped, as is one with neither
//! color. Anything else is an error: a missing version or `kind`, a second
//! `kind`, an unknown line, an empty line, a color that is not exactly
//! `#rrggbb`, an unknown override name. The message is `palette input line
//! <n>: <what>` (a missing `kind` names the line after the last one).
//!
//! Derive output:
//!
//! ```text
//! JNP 1
//! theme <16 lowercase hex digits>
//! kind dark|light
//! canvas_source Normal.bg|terminal|fallback|override
//! port <port key>|-
//! t <token> #rrggbb <source>[ <detail, to the end of the line>]    35 lines, token order
//! ```
//!
//! The detail is left out (with its space) when it is empty, as an override's
//! is. Schema output (kind 2049): `JNP 1`, `groups 37`, the group names one
//! per line, `tokens 35`, the token names one per line, `ports 19`, then one
//! line per known port, `<key> <source> <label, to the end of the line>` (the
//! key and the source never hold a space). Readable (kind
//! 2050): input `#rrggbb #rrggbb [target]` (target 1 to 21, default 4.5),
//! output `#rrggbb\n`; an error is `palette readable: <what>`.

use std::fmt::Write as _;

use super::color::{parse_rgb, Rgb};
use super::ports::PORTS;
use super::rules::{GroupColors, Input, Kind, Palette, Token, GROUPS};

/// The longest piece of an offending line an error message repeats.
const ECHO: usize = 40;

fn line_err(n: usize, what: &str) -> String {
    format!("palette input line {n}: {what}")
}

/// The start of `line` for a message.
fn echo(line: &str) -> String {
    let mut s: String = line.chars().take(ECHO).collect();
    if line.chars().nth(ECHO).is_some() {
        s.push_str("...");
    }
    s
}

/// A `#rrggbb` color, or `-` for none when `dash` allows it.
fn color_arg(n: usize, what: &str, s: &str, dash: bool) -> Result<Option<Rgb>, String> {
    if dash && s == "-" {
        return Ok(None);
    }
    match parse_rgb(s) {
        Some(c) => Ok(Some(c)),
        None => Err(line_err(n, &format!("{what}: not a #rrggbb color: {:?}", echo(s)))),
    }
}

/// Parse a derive input (module doc). Nothing is partly applied: an error
/// is the whole result.
pub fn parse_input(bytes: &[u8]) -> Result<Input, String> {
    let text = std::str::from_utf8(bytes).map_err(|e| {
        let n = bytes[..e.valid_up_to()].iter().filter(|&&b| b == b'\n').count() + 1;
        line_err(n, "not valid UTF-8")
    })?;
    let no_version = || line_err(1, "expected `JNP 1` (the format version) first");
    if text.is_empty() {
        return Err(no_version());
    }
    // `a\nb\n` has two lines; the piece after the last newline is not one.
    let body = text.strip_suffix('\n').unwrap_or(text);
    let total = body.split('\n').count();
    let mut lines = body.split('\n').enumerate().map(|(i, l)| (i + 1, l));
    if lines.next().map(|(_, l)| l) != Some("JNP 1") {
        return Err(no_version());
    }

    let mut input = Input::new(Kind::Dark);
    let (mut kind, mut name, mut term) = (false, false, false);
    let mut group_seen = [false; GROUPS.len()];
    for (n, line) in lines {
        let (word, rest) = match line.split_once(' ') {
            Some((w, r)) => (w, Some(r)),
            None => (line, None),
        };
        match word {
            "kind" => {
                if kind {
                    return Err(line_err(n, "kind given twice"));
                }
                input.kind = match rest {
                    Some("dark") => Kind::Dark,
                    Some("light") => Kind::Light,
                    other => {
                        let got = other.map(|r| format!(", not {:?}", echo(r))).unwrap_or_default();
                        return Err(line_err(n, &format!("kind must be dark or light{got}")));
                    }
                };
                kind = true;
            }
            "name" => {
                if name {
                    return Err(line_err(n, "name given twice"));
                }
                match rest {
                    Some("-") => {}
                    Some(r) if !r.is_empty() => input.colors_name = Some(r.to_string()),
                    _ => return Err(line_err(n, "name wants a colorscheme name or -")),
                }
                name = true;
            }
            "term" => {
                if term {
                    return Err(line_err(n, "term given twice"));
                }
                let Some(r) = rest else {
                    return Err(line_err(n, "term wants a #rrggbb color or -"));
                };
                input.terminal = color_arg(n, "term", r, true)?;
                term = true;
            }
            "set" => {
                if rest.is_some() {
                    return Err(line_err(n, "set takes no argument"));
                }
                if input.set {
                    return Err(line_err(n, "set given twice"));
                }
                input.set = true;
            }
            "g" => {
                let parts: Vec<&str> = rest.map(|r| r.split(' ').collect()).unwrap_or_default();
                let [group, fg, bg] = parts[..] else {
                    return Err(line_err(n, "g wants a group name and two colors (#rrggbb or -)"));
                };
                let fg = color_arg(n, "g", fg, true)?;
                let bg = color_arg(n, "g", bg, true)?;
                // Only the groups of the schema are read; others are dropped.
                if let Some(i) = GROUPS.iter().position(|&g| g == group) {
                    if group_seen[i] {
                        return Err(line_err(n, &format!("group {group} given twice")));
                    }
                    group_seen[i] = true;
                    if fg.is_some() || bg.is_some() {
                        input.groups.insert(group.to_string(), GroupColors { fg, bg });
                    }
                }
            }
            "o" => {
                let parts: Vec<&str> = rest.map(|r| r.split(' ').collect()).unwrap_or_default();
                let [tok, color] = parts[..] else {
                    return Err(line_err(n, "override wants a token name and a #rrggbb color"));
                };
                let Some(t) = Token::from_name(tok) else {
                    return Err(line_err(n, &format!("unknown override {:?}", echo(tok))));
                };
                let c = color_arg(n, "override", color, false)?;
                if input.overrides[t as usize].is_some() {
                    return Err(line_err(n, &format!("override {tok} given twice")));
                }
                input.overrides[t as usize] = c;
            }
            _ if line.is_empty() => return Err(line_err(n, "unknown line (empty)")),
            _ => return Err(line_err(n, &format!("unknown line {:?}", echo(line)))),
        }
    }
    if !kind {
        return Err(line_err(total + 1, "no kind line"));
    }
    Ok(input)
}

/// A derived palette as text (module doc). A line break inside a detail
/// becomes a space, so a detail never splits a line.
pub fn encode(p: &Palette) -> Vec<u8> {
    let mut s = String::with_capacity(2400);
    s.push_str("JNP 1\n");
    let _ = writeln!(s, "theme {:016x}", p.theme_id);
    s.push_str(match p.kind {
        Kind::Dark => "kind dark\n",
        Kind::Light => "kind light\n",
    });
    let _ = writeln!(s, "canvas_source {}", p.canvas_source.name());
    let _ = writeln!(s, "port {}", p.port.unwrap_or("-"));
    for t in Token::ALL {
        let i = t as usize;
        let _ = write!(s, "t {} {} {}", t.name(), p.tokens[i].hex(), p.sources[i].name());
        let detail = p.details[i].replace(['\n', '\r'], " ");
        let detail = detail.trim_end();
        if !detail.is_empty() {
            s.push(' ');
            s.push_str(detail);
        }
        s.push('\n');
    }
    s.into_bytes()
}

/// The schema (module doc): the groups the rules read, the tokens and the
/// known ports.
pub fn schema() -> String {
    let mut s = String::with_capacity(2304);
    s.push_str("JNP 1\n");
    let _ = writeln!(s, "groups {}", GROUPS.len());
    for g in GROUPS {
        s.push_str(g);
        s.push('\n');
    }
    let _ = writeln!(s, "tokens {}", Token::ALL.len());
    for t in Token::ALL {
        s.push_str(t.name());
        s.push('\n');
    }
    let _ = writeln!(s, "ports {}", PORTS.len());
    for p in PORTS {
        let _ = writeln!(s, "{} {} {}", p.key, p.source, p.label);
    }
    s
}

/// A readable request: `#rrggbb #rrggbb [target]`, separated by any
/// whitespace, the target (1 to 21) defaulting to 4.5.
pub fn parse_readable(bytes: &[u8]) -> Result<(Rgb, Rgb, f64), String> {
    let err = |what: &str| format!("palette readable: {what}");
    let text = std::str::from_utf8(bytes).map_err(|_| err("input is not valid UTF-8"))?;
    let mut it = text.split_whitespace();
    let (Some(fg), Some(bg)) = (it.next(), it.next()) else {
        return Err(err("wants `#rrggbb #rrggbb [target]`"));
    };
    let color = |s: &str| parse_rgb(s).ok_or_else(|| err(&format!("not a #rrggbb color: {:?}", echo(s))));
    let (fg, bg) = (color(fg)?, color(bg)?);
    let target = match it.next() {
        None => 4.5,
        Some(t) => match t.parse::<f64>() {
            Ok(v) if (1.0..=21.0).contains(&v) => v,
            _ => return Err(err(&format!("target must be a number from 1 to 21, not {:?}", echo(t)))),
        },
    };
    if it.next().is_some() {
        return Err(err("wants `#rrggbb #rrggbb [target]`, nothing more"));
    }
    Ok((fg, bg, target))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::palette::color::{parse_rgb, Rgb};
    use crate::palette::ports::PORTS;
    use crate::palette::rules::{derive, GroupColors, Input, Kind, Palette, Source, Token, GROUPS};
    use crate::palette::testjson::{self, J};
    use std::collections::{HashMap, HashSet};

    fn rgb(s: &str) -> Rgb {
        parse_rgb(s).unwrap_or_else(|| panic!("not #rrggbb: {s}"))
    }

    fn fixture(name: &str) -> J {
        let p = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures/palette").join(name);
        let s = std::fs::read_to_string(&p).unwrap_or_else(|e| panic!("reading {}: {e}", p.display()));
        testjson::parse(&s).unwrap_or_else(|e| panic!("{}: {e}", p.display()))
    }

    /// The approved user case as an `Input`: the groups of `user_hl.json`
    /// that the schema names and that have a color, tokyonight storm, dark,
    /// the terminal answering `#222436`.
    fn user_input() -> Input {
        let dump = fixture("user_hl.json");
        let mut groups = HashMap::new();
        for g in GROUPS {
            let Some(v) = dump.get(g) else { continue };
            let c = |attr: &str| v.get(attr).and_then(J::as_str).map(rgb);
            let gc = GroupColors { fg: c("fg"), bg: c("bg") };
            if gc.fg.is_some() || gc.bg.is_some() {
                groups.insert(g.to_string(), gc);
            }
        }
        let mut i = Input::new(Kind::Dark);
        i.colors_name = Some("tokyonight-storm".to_string());
        i.terminal = Some(rgb("#222436"));
        i.groups = groups;
        i
    }

    fn color_or_dash(c: Option<Rgb>) -> String {
        c.map(Rgb::hex).unwrap_or_else(|| "-".to_string())
    }

    /// The wire text of an input, written the way the Lua side writes it:
    /// groups in schema order, overrides in token order.
    fn text_of(i: &Input) -> String {
        let mut s = String::from("JNP 1\n");
        s.push_str(if i.kind == Kind::Dark { "kind dark\n" } else { "kind light\n" });
        match &i.colors_name {
            Some(n) => s.push_str(&format!("name {n}\n")),
            None => s.push_str("name -\n"),
        }
        s.push_str(&format!("term {}\n", color_or_dash(i.terminal)));
        if i.set {
            s.push_str("set\n");
        }
        for g in GROUPS {
            if let Some(c) = i.groups.get(g) {
                s.push_str(&format!("g {g} {} {}\n", color_or_dash(c.fg), color_or_dash(c.bg)));
            }
        }
        for t in Token::ALL {
            if let Some(c) = i.overrides[t as usize] {
                s.push_str(&format!("o {} {}\n", t.name(), c.hex()));
            }
        }
        s
    }

    /// One line of a derive result: `t <token> #rrggbb <source>[ <detail>]`.
    struct TLine {
        token: String,
        color: String,
        source: String,
        detail: String,
    }

    fn t_lines(out: &str) -> Vec<TLine> {
        out.lines()
            .filter_map(|l| l.strip_prefix("t "))
            .map(|rest| {
                let mut it = rest.splitn(4, ' ');
                TLine {
                    token: it.next().unwrap_or("").to_string(),
                    color: it.next().unwrap_or("").to_string(),
                    source: it.next().unwrap_or("").to_string(),
                    detail: it.next().unwrap_or("").to_string(),
                }
            })
            .collect()
    }

    fn err_of(text: &str) -> String {
        match parse_input(text.as_bytes()) {
            Ok(i) => panic!("expected an error for {text:?}, got {i:?}"),
            Err(m) => m,
        }
    }

    // ---- parse_input ----

    #[test]
    fn a_full_input_parses_to_the_expected_input() {
        let text = "JNP 1\n\
                    kind light\n\
                    name my scheme\n\
                    term #101820\n\
                    set\n\
                    g Normal #112233 #445566\n\
                    g Comment #778899 -\n\
                    g CursorLine - #AABBCC\n\
                    o canvas #000000\n\
                    o text #ffffff\n\
                    o quote_bar #123456\n";
        let got = parse_input(text.as_bytes()).expect("parses");
        let mut want = Input::new(Kind::Light);
        want.colors_name = Some("my scheme".to_string());
        want.terminal = Some(Rgb(0x10, 0x18, 0x20));
        want.set = true;
        want.groups.insert("Normal".into(), GroupColors { fg: Some(Rgb(0x11, 0x22, 0x33)), bg: Some(Rgb(0x44, 0x55, 0x66)) });
        want.groups.insert("Comment".into(), GroupColors { fg: Some(Rgb(0x77, 0x88, 0x99)), bg: None });
        want.groups.insert("CursorLine".into(), GroupColors { fg: None, bg: Some(Rgb(0xaa, 0xbb, 0xcc)) });
        want.overrides[Token::Canvas as usize] = Some(Rgb(0, 0, 0));
        want.overrides[Token::Text as usize] = Some(Rgb(255, 255, 255));
        want.overrides[Token::QuoteBar as usize] = Some(Rgb(0x12, 0x34, 0x56));
        assert_eq!(got, want);
    }

    #[test]
    fn the_smallest_input_is_the_version_and_the_kind() {
        assert_eq!(parse_input(b"JNP 1\nkind dark\n"), Ok(Input::new(Kind::Dark)));
        assert_eq!(parse_input(b"JNP 1\nkind light"), Ok(Input::new(Kind::Light)), "the last newline is optional");
        let dash = parse_input(b"JNP 1\nkind dark\nname -\nterm -\n").expect("parses");
        assert_eq!(dash.colors_name, None);
        assert_eq!(dash.terminal, None);
        assert!(!dash.set);
    }

    #[test]
    fn a_name_runs_to_the_end_of_the_line() {
        let i = parse_input(b"JNP 1\nkind dark\nname rose pine - moon\n").expect("parses");
        assert_eq!(i.colors_name.as_deref(), Some("rose pine - moon"));
    }

    #[test]
    fn lines_may_come_in_any_order_after_the_version() {
        let a = parse_input(b"JNP 1\ng Normal #112233 -\nset\no text #ffffff\nterm #000000\nname x\nkind light\n");
        let mut want = Input::new(Kind::Light);
        want.colors_name = Some("x".into());
        want.terminal = Some(Rgb(0, 0, 0));
        want.set = true;
        want.groups.insert("Normal".into(), GroupColors { fg: Some(Rgb(0x11, 0x22, 0x33)), bg: None });
        want.overrides[Token::Text as usize] = Some(Rgb(255, 255, 255));
        assert_eq!(a, Ok(want));
    }

    #[test]
    fn a_group_the_rules_do_not_read_is_dropped_and_one_with_no_color_is_left_out() {
        let i = parse_input(b"JNP 1\nkind dark\ng NotAGroup #112233 -\ng Normal - -\ng Comment #010203 -\n").expect("parses");
        assert_eq!(i.groups.len(), 1, "{:?}", i.groups);
        assert!(i.groups.contains_key("Comment"));
    }

    #[test]
    fn colors_are_read_in_either_case() {
        let i = parse_input(b"JNP 1\nkind dark\nterm #C0CAF5\no fill #aAbBcC\n").expect("parses");
        assert_eq!(i.terminal, Some(Rgb(0xc0, 0xca, 0xf5)));
        assert_eq!(i.overrides[Token::Fill as usize], Some(Rgb(0xaa, 0xbb, 0xcc)));
    }

    #[test]
    fn every_error_names_its_line_and_what_is_wrong() {
        // (text, the line the error names, a word the message has)
        let cases: &[(&str, usize, &str)] = &[
            ("", 1, "JNP 1"),
            ("kind dark\n", 1, "JNP 1"),
            ("JNP 2\nkind dark\n", 1, "JNP 1"),
            ("JNP 1 \nkind dark\n", 1, "JNP 1"),
            ("JNP 1\nkind dusk\n", 2, "dusk"),
            ("JNP 1\nkind\n", 2, "kind"),
            ("JNP 1\nkind dark\nx y\n", 3, "unknown line"),
            ("JNP 1\nkind dark\n\nname x\n", 3, "unknown line"),
            ("JNP 1\nkind dark\nsetting\n", 3, "unknown line"),
            ("JNP 1\nkind dark\nset now\n", 3, "set"),
            ("JNP 1\nkind dark\ng Normal red -\n", 3, "red"),
            ("JNP 1\nkind dark\ng Normal #fff -\n", 3, "#fff"),
            ("JNP 1\nkind dark\ng Normal #112233\n", 3, "group"),
            ("JNP 1\nkind dark\ng Normal #112233 - -\n", 3, "group"),
            ("JNP 1\nkind dark\ng NotAGroup red -\n", 3, "red"),
            ("JNP 1\nkind dark\no nope #ffffff\n", 3, "nope"),
            ("JNP 1\nkind dark\no text\n", 3, "override"),
            ("JNP 1\nkind dark\no text -\n", 3, "-"),
            ("JNP 1\nkind dark\no text #ffffffaa\n", 3, "#ffffffaa"),
            ("JNP 1\nkind dark\nterm #fff\n", 3, "#fff"),
            ("JNP 1\nkind dark\nterm #ggg000\n", 3, "#ggg000"),
            ("JNP 1\nkind dark\nterm\n", 3, "term"),
            ("JNP 1\nkind dark\nname\n", 3, "name"),
            ("JNP 1\nkind dark\nkind light\n", 3, "twice"),
            ("JNP 1\nkind dark\nname a\nname b\n", 4, "twice"),
            ("JNP 1\nkind dark\nterm -\nterm #000000\n", 4, "twice"),
            ("JNP 1\nkind dark\nset\nset\n", 4, "twice"),
            ("JNP 1\nkind dark\ng Normal #112233 -\ng Normal - #112233\n", 4, "twice"),
            ("JNP 1\nkind dark\no text #ffffff\no text #000000\n", 4, "twice"),
            ("JNP 1\nname x\n", 3, "kind"),
            ("JNP 1\n", 2, "kind"),
        ];
        for &(text, line, word) in cases {
            let m = err_of(text);
            let prefix = format!("palette input line {line}: ");
            assert!(m.starts_with(&prefix), "{text:?}: {m:?} should start with {prefix:?}");
            assert!(m.contains(word), "{text:?}: {m:?} should contain {word:?}");
        }
    }

    #[test]
    fn input_that_is_not_utf8_is_an_error_naming_its_line() {
        let m = parse_input(b"JNP 1\nkind dark\nname \xff\xfe\n").unwrap_err();
        assert!(m.starts_with("palette input line 3: "), "{m}");
        assert!(m.contains("UTF-8"), "{m}");
    }

    #[test]
    fn an_unknown_line_is_never_accepted_silently() {
        // Any line of a shape the format does not have fails the whole input.
        for extra in ["x", "x y", "G Normal - -", "t text #ffffff", "theme abc", "port -", "canvas_source terminal"] {
            let text = format!("JNP 1\nkind dark\n{extra}\n");
            let m = err_of(&text);
            assert!(m.starts_with("palette input line 3: "), "{extra}: {m}");
        }
    }

    // ---- the round trip ----

    #[test]
    fn the_user_input_round_trips_through_its_text() {
        let i = user_input();
        assert!(i.groups.len() > 10, "{} groups", i.groups.len());
        let text = text_of(&i);
        assert!(text.starts_with("JNP 1\nkind dark\nname tokyonight-storm\nterm #222436\n"), "{text}");
        assert_eq!(parse_input(text.as_bytes()), Ok(i));
    }

    #[test]
    fn a_text_with_overrides_and_set_round_trips() {
        let mut i = user_input();
        i.set = true;
        i.overrides[Token::Canvas as usize] = Some(rgb("#101010"));
        i.overrides[Token::Fill as usize] = Some(rgb("#202020"));
        i.overrides[Token::KbdBorder as usize] = Some(rgb("#abcdef"));
        assert_eq!(parse_input(text_of(&i).as_bytes()), Ok(i));
    }

    // ---- encode ----

    #[test]
    fn encode_of_the_user_palette_has_the_header_and_35_token_lines_in_order() {
        let p = derive(&user_input());
        let out = String::from_utf8(encode(&p)).expect("UTF-8");
        assert!(out.starts_with("JNP 1\ntheme "), "{out}");
        assert!(out.ends_with('\n'));
        let lines: Vec<&str> = out.lines().collect();
        assert_eq!(lines[0], "JNP 1");
        assert_eq!(lines[1], format!("theme {:016x}", p.theme_id));
        assert_eq!(lines[2], "kind dark");
        assert_eq!(lines[3], "canvas_source terminal");
        assert_eq!(lines[4], format!("port {}", p.port.unwrap_or("-")));
        assert_eq!(p.port, Some("tokyonight-storm"));
        assert_eq!(lines.len(), 5 + 35);
        let ts = t_lines(&out);
        assert_eq!(ts.len(), 35);
        for (k, t) in ts.iter().zip(Token::ALL) {
            assert_eq!(k.token, t.name());
            assert_eq!(k.color, p.get(t).hex(), "{}", t.name());
            assert_eq!(k.source, p.sources[t as usize].name(), "{}", t.name());
            assert_eq!(k.detail, p.details[t as usize], "{}", t.name());
        }
        assert_eq!(lines[5], "t canvas #222436 derived the terminal's background (OSC 11)");
        assert!(lines.iter().any(|l| l.starts_with("t text #c0caf5 ")), "{out}");
        assert!(lines.iter().all(|l| !l.ends_with(' ')), "no trailing space: {out}");
    }

    #[test]
    fn an_override_line_ends_after_its_source() {
        let mut i = user_input();
        i.overrides[Token::Fill as usize] = Some(rgb("#101010"));
        let p = derive(&i);
        assert_eq!(p.sources[Token::Fill as usize], Source::Override);
        assert_eq!(p.details[Token::Fill as usize], "");
        let out = String::from_utf8(encode(&p)).expect("UTF-8");
        assert!(out.lines().any(|l| l == "t fill #101010 override"), "{out}");
    }

    #[test]
    fn the_header_names_the_kind_the_canvas_source_and_the_port() {
        let mut i = Input::new(Kind::Light);
        i.groups.insert("Normal".into(), GroupColors { fg: Some(rgb("#101010")), bg: Some(rgb("#f0f0f0")) });
        let out = String::from_utf8(encode(&derive(&i))).expect("UTF-8");
        let lines: Vec<&str> = out.lines().collect();
        assert_eq!(&lines[2..5], ["kind light", "canvas_source Normal.bg", "port -"]);
        let fallback = String::from_utf8(encode(&derive(&Input::new(Kind::Dark)))).expect("UTF-8");
        assert!(fallback.lines().any(|l| l == "canvas_source fallback"), "{fallback}");
        let mut o = Input::new(Kind::Dark);
        o.overrides[Token::Canvas as usize] = Some(rgb("#000000"));
        let over = String::from_utf8(encode(&derive(&o))).expect("UTF-8");
        assert!(over.lines().any(|l| l == "canvas_source override"), "{over}");
        assert!(over.lines().any(|l| l == "t canvas #000000 override"), "{over}");
    }

    #[test]
    fn a_line_break_in_a_detail_never_splits_a_line() {
        let mut p: Palette = derive(&user_input());
        p.details[Token::Math as usize] = "two\nlines\r\nhere".to_string();
        let out = String::from_utf8(encode(&p)).expect("UTF-8");
        assert_eq!(out.lines().count(), 5 + 35, "{out}");
        assert!(out.lines().any(|l| l.starts_with("t math ") && l.ends_with(" two lines  here")), "{out}");
    }

    // ---- schema ----

    #[test]
    fn the_schema_lists_37_groups_then_35_tokens() {
        let s = schema();
        assert!(s.starts_with("JNP 1\ngroups 37\nNormal\nComment\n@comment\n"), "{s}");
        assert!(s.contains("\ntokens 35\ncanvas\ntext\ntext_muted\n"), "{s}");
        assert!(s.contains("\nkbd_border\nquote_bar\nports 19\n"), "{s}");
        let lines: Vec<&str> = s.lines().collect();
        assert_eq!(lines.len(), 1 + 1 + 37 + 1 + 35 + 1 + PORTS.len());
        assert_eq!(&lines[2..39], GROUPS);
        assert_eq!(lines[39], "tokens 35");
        let names: Vec<&str> = Token::ALL.iter().map(|t| t.name()).collect();
        assert_eq!(&lines[40..75], names.as_slice());
        assert_eq!(lines[38], "PmenuSel");
        assert_eq!(lines[40], "canvas");
        assert_eq!(lines[74], "quote_bar");
    }

    #[test]
    fn the_schema_ends_with_every_port_key_source_and_label() {
        let s = schema();
        let lines: Vec<&str> = s.lines().collect();
        assert_eq!(PORTS.len(), 19);
        assert_eq!(lines[75], "ports 19");
        for (i, p) in PORTS.iter().enumerate() {
            assert_eq!(lines[76 + i], format!("{} {} {}", p.key, p.source, p.label), "port {i}");
            assert!(!p.key.is_empty() && !p.key.chars().any(char::is_whitespace), "key of port {i}: {:?}", p.key);
            assert!(!p.source.is_empty() && !p.source.chars().any(char::is_whitespace), "source of port {i}: {:?}", p.source);
            assert!(!p.label.is_empty(), "label of port {i}");
            assert!(!p.label.contains('\n'), "label of port {i}: {:?}", p.label);
            assert_eq!(p.label, p.label.trim(), "label of port {i}");
        }
        let keys: HashSet<&str> = PORTS.iter().map(|p| p.key).collect();
        assert_eq!(keys.len(), PORTS.len(), "the keys are distinct");
        assert_eq!(lines[76], "tokyonight-storm enkia.tokyo-night-1.1.2 Tokyo Night Storm");
        assert!(lines.contains(&"rosepine mvllow.rose-pine-2.15.2 Ros\u{e9} Pine"), "{s}");
        assert_eq!(lines.len(), 76 + PORTS.len());
        assert_eq!(lines.len(), 95);
        assert!(s.ends_with('\n'));
    }

    // ---- the readable request ----

    #[test]
    fn a_readable_request_is_two_colors_and_an_optional_target() {
        assert_eq!(parse_readable(b"#c0caf5 #222436"), Ok((Rgb(0xc0, 0xca, 0xf5), Rgb(0x22, 0x24, 0x36), 4.5)));
        assert_eq!(parse_readable(b"#C0CAF5 #222436 3.0\n"), Ok((Rgb(0xc0, 0xca, 0xf5), Rgb(0x22, 0x24, 0x36), 3.0)));
        assert_eq!(parse_readable(b"#000000 #ffffff 7"), Ok((Rgb(0, 0, 0), Rgb(255, 255, 255), 7.0)));
        assert_eq!(parse_readable(b"#000000 #ffffff 21"), Ok((Rgb(0, 0, 0), Rgb(255, 255, 255), 21.0)));
        assert_eq!(parse_readable(b"#000000 #ffffff 1"), Ok((Rgb(0, 0, 0), Rgb(255, 255, 255), 1.0)));
    }

    #[test]
    fn a_bad_readable_request_is_an_error_that_says_so() {
        for bad in [
            "", "#c0caf5", "#c0caf5 #222436 4.5 extra", "c0caf5 #222436", "#c0caf5 #222", "#c0caf5 #222436 abc",
            "#c0caf5 #222436 0.5", "#c0caf5 #222436 22", "#c0caf5 #222436 NaN", "#c0caf5 #222436 inf", "#c0caf5 #222436 -3",
        ] {
            let m = parse_readable(bad.as_bytes()).unwrap_err();
            assert!(m.starts_with("palette readable: "), "{bad:?}: {m}");
        }
        let m = parse_readable(b"#c0caf5 \xff\xfe").unwrap_err();
        assert!(m.contains("UTF-8"), "{m}");
    }
}
