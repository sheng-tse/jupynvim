//! The palette rules against their fixtures (tests/fixtures/palette/): the
//! four highlight dumps of `cases.json` must give their 35 expected tokens,
//! the contrast floor must lift Catppuccin Latte's low contrast text colors
//! keeping their hue, each token must say where it came from, the rule
//! vectors must give their outputs exactly, every known port must meet the
//! floors, the port table must be well formed, and a derivation must stay
//! within its time budget (B1: under 100 us per call in a release build).

#[path = "support/minijson.rs"]
mod minijson;

use std::collections::HashMap;
use std::hint::black_box;
use std::path::PathBuf;
use std::time::Instant;

use jupynvim::palette::color::{contrast, l_of, oklch, parse_rgb, quantize, Rgb, Rgba};
use jupynvim::palette::ports::{lookup, PORTS};
use jupynvim::palette::registry::default_for;
use jupynvim::palette::rules::{
    derive, lift, lift_soft, mix_to_contrast, muted_7, vis_floor, visible, CanvasSource, GroupColors, Input, Kind,
    Palette, Source, Token, GROUPS,
};
use minijson::J;

const CASES: [&str; 4] = ["user", "user_live", "mocha", "latte"];

fn fixture(name: &str) -> J {
    let p = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures/palette").join(name);
    let s = std::fs::read_to_string(&p).unwrap_or_else(|e| panic!("reading {}: {e}", p.display()));
    minijson::parse(&s).unwrap_or_else(|e| panic!("{}: {e}", p.display()))
}

fn rgb(s: &str) -> Rgb {
    parse_rgb(s).unwrap_or_else(|| panic!("not a #rrggbb color: {s:?}"))
}

fn str_of<'a>(j: &'a J, key: &str) -> &'a str {
    j.get(key).and_then(J::as_str).unwrap_or_else(|| panic!("no string {key:?}"))
}

/// A string, or none for a missing or null value.
fn opt_str<'a>(j: &'a J, key: &str) -> Option<&'a str> {
    j.get(key).and_then(J::as_str)
}

fn kind_of(background: &str) -> Kind {
    match background {
        "dark" => Kind::Dark,
        "light" => Kind::Light,
        other => panic!("background {other:?}"),
    }
}

/// The groups of a highlight dump: its `groups` object when it has one,
/// else the top-level object without the keys starting with `_`. A group
/// given as an empty array or object has neither color.
fn groups_of(dump: &J) -> HashMap<String, GroupColors> {
    let obj = match dump.get("groups") {
        Some(g) => g.as_obj().expect("groups is an object"),
        None => dump.as_obj().expect("a highlight dump is an object"),
    };
    obj.iter()
        .filter(|(k, _)| !k.starts_with('_'))
        .map(|(k, v)| {
            let c = |attr: &str| v.get(attr).and_then(J::as_str).map(rgb);
            (k.clone(), GroupColors { fg: c("fg"), bg: c("bg") })
        })
        .collect()
}

fn input(
    groups: HashMap<String, GroupColors>,
    colors_name: Option<&str>,
    background: &str,
    term: Option<&str>,
) -> Input {
    Input {
        kind: kind_of(background),
        colors_name: colors_name.map(str::to_string),
        terminal: term.map(rgb),
        groups,
        overrides: [None; 35],
        canvas_override: None,
        set: false,
    }
}

fn case(name: &str) -> J {
    let cases = fixture("cases.json");
    cases.get(name).unwrap_or_else(|| panic!("cases.json has no case {name}")).clone()
}

fn case_input(name: &str) -> Input {
    let c = case(name);
    let dump = fixture(str_of(&c, "hl"));
    input(groups_of(&dump), opt_str(&c, "colors_name"), str_of(&c, "background"), opt_str(&c, "terminal_canvas"))
}

/// The 35 expected tokens of an expectation file: its `tokens` object when
/// it has one, else its top level (whose other keys are not tokens).
fn expected_tokens(file: &J) -> Vec<(Token, Rgb)> {
    let t = file.get("tokens").unwrap_or(file);
    Token::ALL.iter().map(|&tok| (tok, rgb(str_of(t, tok.name())))).collect()
}

fn src(p: &Palette, t: Token) -> (Source, &str) {
    (p.sources[t as usize], p.details[t as usize].as_str())
}

/// Derives a case and compares every token with its expectation (and the
/// case's `expected_differences`, which replace the expected value of their
/// tokens). Every mismatch is printed by token name before the test fails.
fn check_case(name: &str) -> Palette {
    let c = case(name);
    let p = derive(&case_input(name));
    let diffs: Vec<(String, Rgb)> = c
        .get("expected_differences")
        .and_then(J::as_obj)
        .map(|o| o.iter().map(|(k, v)| (k.clone(), rgb(v.as_str().expect("a color")))).collect())
        .unwrap_or_default();
    let exp = expected_tokens(&fixture(str_of(&c, "expected")));
    let mut bad = Vec::new();
    for (tok, want) in &exp {
        let want = diffs.iter().find(|(k, _)| k == tok.name()).map(|(_, v)| *v).unwrap_or(*want);
        let got = p.get(*tok);
        if got != want {
            let (s, d) = src(&p, *tok);
            bad.push(format!(
                "{name} {}: derived {} ({} {d}), expected {}",
                tok.name(),
                got.hex(),
                s.name(),
                want.hex()
            ));
        }
    }
    println!("case {name}: {} of 35 tokens equal", 35 - bad.len());
    for b in &bad {
        println!("MISMATCH {b}");
    }
    assert!(bad.is_empty(), "{} of 35 tokens differ:\n{}", bad.len(), bad.join("\n"));
    p
}

#[test]
fn the_cases_are_the_four_fixture_cases() {
    let cases = fixture("cases.json");
    let names: Vec<&str> = cases.as_obj().expect("an object").iter().map(|(k, _)| k.as_str()).collect();
    assert_eq!(names, CASES);
}

#[test]
fn case_user() {
    let p = check_case("user");
    assert_eq!(p.kind, Kind::Dark);
}

#[test]
fn case_user_live() {
    // The live dump differs from the approved one only in the inline code
    // chip, which its colorscheme defines (@markup.raw.markdown_inline).
    let c = case("user_live");
    let diffs = c.get("expected_differences").and_then(J::as_obj).expect("expected_differences");
    let diffs: Vec<(&str, &str)> = diffs.iter().map(|(k, v)| (k.as_str(), v.as_str().expect("a color"))).collect();
    assert_eq!(diffs, [("inline_code_fg", "#90baff"), ("inline_code_bg", "#414868")]);
    let base = expected_tokens(&fixture("user_tokens.json"));
    for (k, v) in &diffs {
        let tok = Token::from_name(k).expect("a token");
        let b = base.iter().find(|(t, _)| *t == tok).expect("in the expectation").1;
        assert_ne!(b, rgb(v), "{k} is a real difference from user_tokens.json");
    }
    check_case("user_live");
}

#[test]
fn case_mocha() {
    check_case("mocha");
}

#[test]
fn case_latte() {
    let p = check_case("latte");
    assert_eq!(p.kind, Kind::Light);
}

fn hue_gap(a: f64, b: f64) -> f64 {
    let d = (a - b).rem_euclid(360.0);
    d.min(360.0 - d)
}

#[test]
fn latte_spec_lifts_reach_the_contrast_floor_and_keep_the_hue() {
    let exp = fixture("latte_tokens.json");
    let lifts = exp.get("spec_lifts").and_then(J::as_obj).expect("spec_lifts");
    let names: Vec<&str> = lifts.iter().map(|(k, _)| k.as_str()).collect();
    assert_eq!(names, ["heading_h1_h3", "math", "link", "inline_code_fg"]);
    let p = derive(&case_input("latte"));
    let text_l = l_of(p.get(Token::Text));
    let mut bad = Vec::new();
    for (name, e) in lifts {
        let tok = Token::from_name(name).expect("a token");
        let reference = rgb(str_of(e, "ref"));
        let got = p.get(tok);
        let on = if tok == Token::InlineCodeFg { p.get(Token::InlineCodeBg) } else { p.get(Token::Canvas) };
        let (cr_ref, cr_got) = (contrast(reference, on), contrast(got, on));
        let gap = hue_gap(oklch(reference)[2], oklch(got)[2]);
        let (l_ref, l_got) = (l_of(reference), l_of(got));
        let toward = (l_got - l_ref) * (text_l - l_ref) > 0.0;
        println!(
            "spec lift {name}: {} {cr_ref:.2}:1 -> {} {cr_got:.2}:1, hue moved {gap:.2} degrees, \
             L {l_ref:.4} -> {l_got:.4} (text {text_l:.4})",
            reference.hex(),
            got.hex()
        );
        if cr_ref >= 4.5 {
            bad.push(format!("{name}: the reference {} is already {cr_ref:.2}:1", reference.hex()));
        }
        if cr_got < 4.5 {
            bad.push(format!("{name}: derived {} is only {cr_got:.2}:1", got.hex()));
        }
        if gap > 3.0 {
            bad.push(format!("{name}: hue moved {gap:.2} degrees"));
        }
        if !toward {
            bad.push(format!("{name}: L {l_ref:.4} -> {l_got:.4} does not move toward the text's {text_l:.4}"));
        }
    }
    assert!(bad.is_empty(), "{}", bad.join("\n"));
}

#[test]
fn user_sources_say_where_each_token_came_from() {
    let p = derive(&case_input("user"));
    assert_eq!(p.canvas_source, CanvasSource::Terminal);
    assert_eq!(p.canvas_source.name(), "terminal");
    assert_eq!(p.port, Some("tokyonight-storm"));

    let (s, d) = src(&p, Token::Fill);
    assert_eq!(s, Source::Group, "fill: {d}");
    assert!(d.contains("RenderMarkdownCode.bg"), "fill detail {d:?}");
    assert!(d.contains("visibility floor from #1f2335"), "fill detail {d:?}");

    for t in [Token::Thumb, Token::QuoteBar, Token::Ok] {
        let (s, d) = src(&p, t);
        assert_eq!(s, Source::Port, "{}: {d}", t.name());
        assert!(d.contains("completion"), "{} detail {d:?}", t.name());
    }
    let (s, d) = src(&p, Token::Ok);
    assert_ne!(s, Source::Group, "ok must not take Neovim's default DiagnosticOk: {d}");

    let (s, d) = src(&p, Token::Edge);
    assert_eq!(s, Source::Port, "edge: {d}");
    assert!(d.contains("textSeparator.foreground"), "edge detail {d:?}");

    let (s, d) = src(&p, Token::AlertCaution);
    assert_eq!(s, Source::Port, "alert_caution: {d}");
    assert!(d.contains("terminal.ansiRed"), "alert_caution detail {d:?}");

    let (s, d) = src(&p, Token::Canvas);
    assert_ne!(s, Source::Override, "canvas: {d}");
    assert!(d.contains("terminal"), "canvas detail {d:?}");
    let (s, d) = src(&p, Token::HeadingH1H3);
    assert_eq!((s, d), (Source::Derived, "= accent"));
}

#[test]
fn mocha_sources_say_where_each_token_came_from() {
    let p = derive(&case_input("mocha"));
    assert_eq!(p.canvas_source, CanvasSource::Normal);
    assert_eq!(p.canvas_source.name(), "Normal.bg");
    assert_eq!(p.port, Some("catppuccin-mocha"));
    let (s, d) = src(&p, Token::Edge);
    assert_eq!(s, Source::Formula, "edge (the port's mauve separator is far above 3:1): {d}");
    let (s, d) = src(&p, Token::Track);
    assert_eq!(s, Source::Derived, "track (the port's line number is louder than the edge): {d}");
    assert_eq!(d, "= edge");
    let (s, d) = src(&p, Token::Canvas);
    assert_eq!((s, d), (Source::Group, "Normal.bg"));
}

#[test]
fn source_and_canvas_source_names() {
    let names: Vec<&str> =
        [Source::Override, Source::Group, Source::Port, Source::Formula, Source::Derived].map(Source::name).to_vec();
    assert_eq!(names, ["override", "group", "port", "formula", "derived"]);
    let names: Vec<&str> =
        [CanvasSource::Normal, CanvasSource::Terminal, CanvasSource::Fallback, CanvasSource::Override]
            .map(CanvasSource::name)
            .to_vec();
    assert_eq!(names, ["Normal.bg", "terminal", "fallback", "override"]);
}

fn vectors(kind: &str) -> Vec<J> {
    let v = fixture("vectors.json");
    v.get(kind).and_then(J::as_arr).unwrap_or_else(|| panic!("vectors.json has no {kind}")).to_vec()
}

fn report(kind: &str, bad: Vec<String>, n: usize) {
    println!("vectors {kind}: {} of {n} equal", n - bad.len());
    assert!(bad.is_empty(), "{kind}:\n{}", bad.join("\n"));
}

#[test]
fn vectors_vis_floor() {
    let v = vectors("vis_floor");
    let mut bad = Vec::new();
    for e in &v {
        let (c, under, out) = (rgb(str_of(e, "c")), rgb(str_of(e, "under")), rgb(str_of(e, "out")));
        let hue_of = opt_str(e, "hue_of").map(rgb);
        let got = vis_floor(c, under, hue_of);
        if got != out {
            bad.push(format!(
                "vis_floor({}, {}, {:?}) = {}, expected {}",
                c.hex(),
                under.hex(),
                hue_of.map(Rgb::hex),
                got.hex(),
                out.hex()
            ));
        }
    }
    assert_eq!(v.len(), 14, "vis_floor vectors");
    report("vis_floor", bad, v.len());
}

/// The visibility judgment: OKLab lightness 0.02 AND CIELAB lightness 2.32
/// apart, on the 8-bit colors, symmetric.
#[test]
fn visible_judges_oklab_and_cielab_lightness() {
    let yes = [("#1c1f31", "#222436"), ("#090909", "#000000"), ("#e8eaf0", "#eff1f5")];
    let no = [
        ("#1c2031", "#222436"),
        ("#000001", "#000000"),
        ("#010101", "#000000"),
        ("#080808", "#000000"),
        ("#e9ebf1", "#eff1f5"),
    ];
    for (a, b) in yes {
        assert!(visible(rgb(a), rgb(b)), "{a} on {b} is visible");
        assert!(visible(rgb(b), rgb(a)), "{b} on {a} is visible");
    }
    for (a, b) in no {
        assert!(!visible(rgb(a), rgb(b)), "{a} on {b} is not visible");
        assert!(!visible(rgb(b), rgb(a)), "{b} on {a} is not visible");
    }
    // a color is never visible against itself
    assert!(!visible(rgb("#222436"), rgb("#222436")));
}

#[test]
fn vectors_lift() {
    let v = vectors("lift");
    let mut bad = Vec::new();
    for e in &v {
        let (c, bg, toward, out) =
            (rgb(str_of(e, "c")), rgb(str_of(e, "bg")), rgb(str_of(e, "toward")), rgb(str_of(e, "out")));
        let target = e.get("target").and_then(J::as_f64).expect("target");
        let soft = matches!(e.get("soft"), Some(J::Bool(true)));
        let got = if soft { lift_soft(c, bg, target, toward) } else { lift(c, bg, target, toward) };
        if got != out {
            bad.push(format!(
                "{}({}, {}, {target}, {}) = {}, expected {}",
                if soft { "lift_soft" } else { "lift" },
                c.hex(),
                bg.hex(),
                toward.hex(),
                got.hex(),
                out.hex()
            ));
        }
    }
    assert_eq!(v.len(), 18, "lift vectors");
    report("lift", bad, v.len());
}

#[test]
fn vectors_muted_7() {
    let v = vectors("muted_7");
    let mut bad = Vec::new();
    for e in &v {
        let (text, canvas, out) = (rgb(str_of(e, "text")), rgb(str_of(e, "canvas")), rgb(str_of(e, "out")));
        let got = muted_7(text, canvas);
        if got != out {
            bad.push(format!("muted_7({}, {}) = {}, expected {}", text.hex(), canvas.hex(), got.hex(), out.hex()));
        }
    }
    report("muted_7", bad, v.len());
}

#[test]
fn vectors_mix_to_contrast() {
    let v = vectors("mix_to_contrast_3");
    let mut bad = Vec::new();
    for e in &v {
        let (canvas, toward, out) = (rgb(str_of(e, "canvas")), rgb(str_of(e, "toward")), rgb(str_of(e, "out")));
        let got = mix_to_contrast(canvas, toward, 3.0);
        if got != out {
            bad.push(format!(
                "mix_to_contrast({}, {}, 3.0) = {}, expected {}",
                canvas.hex(),
                toward.hex(),
                got.hex(),
                out.hex()
            ));
        }
    }
    report("mix_to_contrast_3", bad, v.len());
}

/// The input of a whole-derivation vector, overrides included (`canvas`
/// among them).
fn vector_input(e: &J) -> Input {
    let groups = groups_of(&J::Obj(vec![("groups".into(), e.get("groups").expect("groups").clone())]));
    let mut i = input(groups, opt_str(e, "colors_name"), str_of(e, "background"), opt_str(e, "terminal_canvas"));
    for (k, v) in e.get("overrides").and_then(J::as_obj).expect("overrides") {
        let c = rgb(v.as_str().expect("a color"));
        if k == "canvas" {
            i.canvas_override = Some(c);
        } else {
            let t = Token::from_name(k).unwrap_or_else(|| panic!("override of {k}"));
            i.overrides[t as usize] = Some(c);
        }
    }
    i
}

#[test]
fn vectors_derive() {
    let v = vectors("derive");
    assert_eq!(v.len(), 21, "derive vectors");
    let mut bad = Vec::new();
    for e in &v {
        let name = str_of(e, "name");
        let p = derive(&vector_input(e));
        let exp = expected_tokens(e);
        let mut n = 0;
        for (tok, want) in exp {
            let got = p.get(tok);
            if got != want {
                let (s, d) = src(&p, tok);
                bad.push(format!(
                    "{name:?} {}: derived {} ({} {d}), expected {}",
                    tok.name(),
                    got.hex(),
                    s.name(),
                    want.hex()
                ));
            } else {
                n += 1;
            }
        }
        println!("vector {name:?}: {n} of 35 tokens equal");
    }
    assert!(bad.is_empty(), "{} tokens differ:\n{}", bad.len(), bad.join("\n"));
}

#[test]
fn overrides_are_final_and_flow_into_derived_tokens() {
    let mut i = case_input("user");
    i.overrides[Token::Accent as usize] = Some(rgb("#200000"));
    i.overrides[Token::Fill as usize] = Some(rgb("#000000"));
    i.canvas_override = Some(rgb("#000000"));
    let p = derive(&i);
    assert_eq!(p.canvas_source, CanvasSource::Override);
    assert_eq!(p.get(Token::Canvas), rgb("#000000"));
    assert_eq!(src(&p, Token::Canvas), (Source::Override, ""));
    // A fill equal to the canvas and an accent at about 1.1:1: either floor
    // would move them, but no floor touches an override.
    assert!(contrast(rgb("#200000"), rgb("#000000")) < 1.2);
    assert_eq!(p.get(Token::Fill), rgb("#000000"));
    assert_eq!(src(&p, Token::Fill), (Source::Override, ""));
    assert_eq!(p.get(Token::KbdBg), rgb("#000000"));
    for t in [Token::Accent, Token::HeadingH1H3, Token::SelectionBorderCommand, Token::SelectionBorderEdit] {
        assert_eq!(p.get(t), rgb("#200000"), "{}", t.name());
    }
    assert_eq!(src(&p, Token::Accent), (Source::Override, ""));
    // The override token in the canvas's place works the same.
    let mut j = case_input("user");
    j.overrides[Token::Canvas as usize] = Some(rgb("#000000"));
    let q = derive(&j);
    assert_eq!((q.get(Token::Canvas), q.canvas_source), (rgb("#000000"), CanvasSource::Override));
}

/// Every token drawn as text (plan decision 9) and checked at 4.5:1
/// against the canvas.
const TEXT_TOKENS: [Token; 20] = [
    Token::Text,
    Token::TextMuted,
    Token::Comment,
    Token::Accent,
    Token::HeadingH1H3,
    Token::HeadingH4H5,
    Token::HeadingH6,
    Token::SelectionBorderCommand,
    Token::SelectionBorderEdit,
    Token::Math,
    Token::Link,
    Token::Ok,
    Token::AlertNote,
    Token::AlertTip,
    Token::AlertImportant,
    Token::AlertWarning,
    Token::AlertCaution,
    Token::Info,
    Token::Warn,
    Token::Error,
];

/// The tokens that are another token by rule (plan 3.4, token 25 and the
/// tokens "equal to" another): (token, what it must equal). The inputs of the
/// invariants have no math or task groups, so those are derived too.
const SAME: [(Token, Token); 13] = [
    (Token::HeadingH1H3, Token::Accent),
    (Token::HeadingH4H5, Token::Text),
    (Token::HeadingH6, Token::TextMuted),
    (Token::SelectionBorderCommand, Token::Accent),
    (Token::SelectionBorderEdit, Token::Accent),
    (Token::Info, Token::AlertNote),
    (Token::Warn, Token::AlertWarning),
    (Token::Error, Token::AlertCaution),
    (Token::KbdBg, Token::Fill),
    (Token::KbdBorder, Token::Track),
    (Token::Math, Token::Text),
    (Token::TaskChecked, Token::Accent),
    (Token::TaskUnchecked, Token::Accent),
];

/// For every known port, 8 inputs: `Normal` with the port's own foreground
/// and background and no terminal answer, then `Normal` with the foreground
/// only on seven terminal canvases (black, white, mid grays, the port's own
/// background, a canvas of the other kind, a dark blue). On each, the floors
/// hold: text 4.5:1, inline code 4.5:1 on its chip, task boxes 3:1, fills,
/// quote bar and edge visible, track no louder than edge, the derived
/// tokens equal what they derive from.
#[test]
fn invariants_over_every_port() {
    let mut bad = Vec::new();
    let mut inputs = 0usize;
    for port in PORTS {
        let kind = if port.light { Kind::Light } else { Kind::Dark };
        let (alias, _) = port.aliases[0];
        let key = port.key;
        if lookup(alias, kind).map(|p| p.key) != Some(key) {
            bad.push(format!("{key}: its first alias {alias} does not find it"));
        }
        let fg = port
            .color("editor.foreground")
            .map(quantize)
            .unwrap_or_else(|| quantize(default_for("editor.foreground", kind)));
        let pbg = port.bg();
        let other = if port.light { "#1e1e2e" } else { "#eff1f5" };
        let terminals: [Option<Rgb>; 8] = [
            None,
            Some(rgb("#000000")),
            Some(rgb("#ffffff")),
            Some(rgb("#808080")),
            Some(rgb("#767676")),
            Some(pbg),
            Some(rgb(other)),
            Some(rgb("#222436")),
        ];
        for term in terminals {
            inputs += 1;
            let mut groups = HashMap::new();
            groups.insert("Normal".to_string(), GroupColors { fg: Some(fg), bg: term.is_none().then_some(pbg) });
            let mut i = input(groups, Some(alias), if port.light { "light" } else { "dark" }, None);
            i.terminal = term;
            let on = term.map_or("Normal.bg".to_string(), Rgb::hex);
            let key = format!("{key} on {on}");
            let p = derive(&i);
            let again = derive(&i);
            if p != again {
                bad.push(format!("{key}: two derivations of one input differ"));
            }
            if p.theme_id != again.theme_id {
                bad.push(format!("{key}: theme_id {:016x} then {:016x}", p.theme_id, again.theme_id));
            }
            if p.port != Some(port.key) {
                bad.push(format!("{key}: palette port {:?}", p.port));
            }
            let canvas = p.get(Token::Canvas);
            let want_canvas = term.unwrap_or(pbg);
            if canvas != want_canvas {
                bad.push(format!("{key}: canvas {} is not {}", canvas.hex(), want_canvas.hex()));
            }
            for t in TEXT_TOKENS {
                let cr = contrast(p.get(t), canvas);
                if cr < 4.5 {
                    bad.push(format!("{key} {}: {} is {cr:.2}:1 on {}", t.name(), p.get(t).hex(), canvas.hex()));
                }
            }
            let cr = contrast(p.get(Token::InlineCodeFg), p.get(Token::InlineCodeBg));
            if cr < 4.5 {
                bad.push(format!("{key} inline_code_fg: {cr:.2}:1 on inline_code_bg"));
            }
            for t in [Token::TaskChecked, Token::TaskUnchecked] {
                let cr = contrast(p.get(t), canvas);
                if cr < 3.0 {
                    bad.push(format!("{key} {}: {cr:.2}:1", t.name()));
                }
            }
            let drawn_apart = [Token::Fill, Token::Lifted, Token::InlineCodeBg, Token::SelectedBg, Token::QuoteBar];
            for t in drawn_apart.into_iter().chain([Token::Edge]) {
                if !visible(p.get(t), canvas) {
                    bad.push(format!("{key} {}: {} is not visible on {}", t.name(), p.get(t).hex(), canvas.hex()));
                }
            }
            let (track, edge) = (contrast(p.get(Token::Track), canvas), contrast(p.get(Token::Edge), canvas));
            if track > edge {
                bad.push(format!("{key}: track {track:.2}:1 is louder than edge {edge:.2}:1"));
            }
            for (t, f) in SAME {
                if p.get(t) != p.get(f) {
                    let (a, b) = (p.get(t).hex(), p.get(f).hex());
                    bad.push(format!("{key}: {} {a} is not {} {b}", t.name(), f.name()));
                }
            }
        }
    }
    println!("invariants: {inputs} inputs, {} problems", bad.len());
    for b in &bad {
        println!("PROBLEM {b}");
    }
    assert_eq!(PORTS.len(), 19, "ports");
    assert_eq!(inputs, 152, "19 ports x 8 canvases");
    assert!(bad.is_empty(), "{} problems:\n{}", bad.len(), bad.join("\n"));
}

/// A detail says where inside the source a token came from and never repeats
/// the source word (the wire and `:JupynvimPalette` print both); an override
/// has none.
#[test]
fn details_never_repeat_the_source() {
    let mut palettes: Vec<(String, Palette)> =
        CASES.iter().map(|n| (n.to_string(), derive(&case_input(n)))).collect();
    for e in vectors("derive") {
        palettes.push((str_of(&e, "name").to_string(), derive(&vector_input(&e))));
    }
    assert_eq!(palettes.len(), 4 + 21, "four cases and 21 derive vectors");
    let (mut bad, mut details, mut overrides) = (Vec::new(), 0usize, 0usize);
    for (name, p) in &palettes {
        for t in Token::ALL {
            let (s, d) = src(p, t);
            details += 1;
            for word in ["port ", "group ", "formula ", "derived ", "override"] {
                if d.starts_with(word) {
                    bad.push(format!("{name} {}: detail {d:?} starts with {word:?}", t.name()));
                }
            }
            if s == Source::Override {
                overrides += 1;
                if !d.is_empty() {
                    bad.push(format!("{name} {}: override detail {d:?} is not empty", t.name()));
                }
            }
        }
    }
    println!("details: {details} checked, {overrides} overrides");
    assert!(bad.is_empty(), "{}", bad.join("\n"));
    // the vector with overrides: the fill, the accent and the canvas
    let ov = palettes.iter().find(|(n, _)| n == "overrides win and are final").expect("the overrides vector");
    for t in [Token::Fill, Token::Accent, Token::Canvas] {
        assert_eq!(src(&ov.1, t), (Source::Override, ""), "{}", t.name());
    }
    assert_eq!(overrides, 3, "only the overrides vector has overrides: fill, accent and the canvas");
    // the forms of the details the user's setup shows
    let user = &palettes[0].1;
    assert_eq!(src(user, Token::Thumb), (Source::Port, "tokyonight-storm completion"));
    assert_eq!(src(user, Token::Edge), (Source::Port, "tokyonight-storm textSeparator.foreground"));
}

#[test]
fn ports_lookup_and_table() {
    let key = |name: &str, kind: Kind| lookup(name, kind).map(|p| p.key);
    assert_eq!(key("tokyonight-storm", Kind::Dark), Some("tokyonight-storm"));
    assert_eq!(key("tokyonight-storm", Kind::Light), Some("tokyonight-storm"), "an alias without a kind");
    assert_eq!(key("gruvbox", Kind::Light), Some("gruvbox-light"));
    assert_eq!(key("gruvbox", Kind::Dark), Some("gruvbox-dark"));
    assert_eq!(key("tokyonight-moon", Kind::Dark), None);
    assert_eq!(key("", Kind::Dark), None);

    assert_eq!(PORTS.len(), 19, "ports");
    assert_eq!(PORTS.iter().map(|p| p.colors.len()).sum::<usize>(), 201, "colors in the table");
    let mut keys: Vec<&str> = PORTS.iter().map(|p| p.key).collect();
    keys.sort_unstable();
    keys.dedup();
    assert_eq!(keys.len(), PORTS.len(), "unique keys");
    let mut aliases: Vec<(&str, Option<Kind>)> = Vec::new();
    for p in PORTS {
        assert!(p.color("editor.background").is_some(), "{} has editor.background", p.key);
        assert!(!p.aliases.is_empty(), "{} has an alias", p.key);
        for &(name, kind) in p.aliases {
            assert!(!aliases.contains(&(name, kind)), "alias ({name}, {kind:?}) twice");
            aliases.push((name, kind));
        }
        let mut ids: Vec<&str> = p.colors.iter().map(|c| c.0).collect();
        ids.sort_unstable();
        ids.dedup();
        assert_eq!(ids.len(), p.colors.len(), "{}: each color id once", p.key);
    }
    // A name without a kind matches either kind, so it cannot also have one.
    for &(name, kind) in &aliases {
        if kind.is_none() {
            assert_eq!(aliases.iter().filter(|a| a.0 == name).count(), 1, "{name} is ambiguous");
        }
    }

    // In token order.
    let completions = [
        (Token::Thumb, Rgb(0x73, 0x7a, 0xa2)),
        (Token::Ok, Rgb(0x9e, 0xce, 0x6a)),
        (Token::QuoteBar, Rgb(0x56, 0x5f, 0x89)),
    ];
    for p in PORTS {
        let have: Vec<(Token, Rgb)> =
            Token::ALL.iter().filter_map(|&t| p.completion(t).map(|c| (t, c))).collect();
        if p.key == "tokyonight-storm" || p.key == "tokyonight-night" {
            assert_eq!(have, completions, "{}", p.key);
        } else {
            assert!(have.is_empty(), "{} has completions {have:?}", p.key);
        }
    }

    let storm = lookup("tokyonight-storm", Kind::Dark).expect("storm");
    assert_eq!(storm.color("editor.background"), Some(Rgba::new(36.0, 40.0, 59.0, 1.0)));
    assert_eq!(storm.color("textBlockQuote.border"), None);
    assert_eq!(storm.bg(), Rgb(0x24, 0x28, 0x3b));
    assert_eq!(storm.completion(Token::Text), None);
    assert_eq!(storm.label, "Tokyo Night Storm");
    let rose = lookup("rose-pine", Kind::Dark).expect("rose-pine");
    assert_eq!((rose.key, rose.label), ("rosepine", "Ros\u{e9} Pine"));
    let dawn = lookup("rose-pine", Kind::Light).expect("rose-pine light");
    assert_eq!((dawn.key, dawn.label), ("rosepine-dawn", "Ros\u{e9} Pine Dawn"));
    let gruvbox = lookup("gruvbox", Kind::Dark).expect("gruvbox");
    assert_eq!(
        gruvbox.color("list.inactiveSelectionBackground"),
        Some(Rgba::new(60.0, 56.0, 54.0, 128.0 / 255.0)),
        "0xRRGGBBAA with its alpha"
    );
}

#[test]
fn tokens_and_groups_are_the_schema() {
    // The token order is the order of the expectation files.
    let exp = fixture("latte_tokens.json");
    let names: Vec<&str> =
        exp.get("tokens").and_then(J::as_obj).expect("tokens").iter().map(|(k, _)| k.as_str()).collect();
    let ours: Vec<&str> = Token::ALL.iter().map(|t| t.name()).collect();
    assert_eq!(ours, names);
    for (i, t) in Token::ALL.iter().enumerate() {
        assert_eq!(*t as usize, i, "{} is at its index", t.name());
        assert_eq!(Token::from_name(t.name()), Some(*t));
    }
    assert_eq!(Token::from_name("nope"), None);
    assert_eq!(Token::from_name("Canvas"), None);

    let want = [
        "Normal", "Comment", "@comment", "RenderMarkdownCode", "@markup.raw.block", "MarkviewCode",
        "markdownCodeBlock", "NormalFloat", "CursorLine", "@markup.raw.markdown_inline", "RenderMarkdownCodeInline",
        "@markup.quote", "RenderMarkdownQuote", "markdownBlockquote", "@markup.heading.1", "@markup.heading", "Title",
        "Function", "@markup.math", "@markup.link.url", "@markup.link", "markdownUrl", "Underlined", "Directory",
        "@markup.raw", "markdownCode", "@markup.list.checked", "RenderMarkdownChecked", "@markup.list.unchecked",
        "RenderMarkdownUnchecked", "DiagnosticInfo", "DiagnosticHint", "Statement", "DiagnosticWarn",
        "DiagnosticError", "DiagnosticOk", "PmenuSel",
    ];
    assert_eq!(GROUPS, want);
}

#[test]
fn only_the_schema_groups_matter() {
    // Groups the rules do not read change nothing.
    let mut i = case_input("mocha");
    let p = derive(&i);
    let read: Vec<String> = i.groups.keys().filter(|k| GROUPS.contains(&k.as_str())).cloned().collect();
    i.groups.retain(|k, _| read.contains(k));
    assert_eq!(derive(&i), p);
}

/// FNV-1a 64 over the 35 tokens' bytes in order, then 0 for dark or 1 for
/// light.
fn fnv1a(p: &Palette) -> u64 {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    let mut eat = |b: u8| {
        h ^= b as u64;
        h = h.wrapping_mul(0x0000_0100_0000_01b3);
    };
    for t in Token::ALL {
        let c = p.get(t);
        eat(c.0);
        eat(c.1);
        eat(c.2);
    }
    eat(if p.kind == Kind::Light { 1 } else { 0 });
    h
}

#[test]
fn theme_id_is_fnv1a_over_the_tokens_and_the_kind() {
    let mut ids = Vec::new();
    for name in CASES {
        let p = derive(&case_input(name));
        assert_eq!(p.theme_id, fnv1a(&p), "{name}");
        ids.push(p.theme_id);
    }
    assert_ne!(ids[0], ids[1], "user and user_live differ in two tokens");
    assert_ne!(ids[2], ids[3], "mocha and latte");
    let mut p = derive(&case_input("user"));
    let dark = p.theme_id;
    p.kind = Kind::Light;
    assert_ne!(fnv1a(&p), dark, "the kind is part of the id");
}

fn load1() -> f64 {
    let mut a = [0f64; 3];
    // SAFETY: getloadavg writes at most `nelem` doubles into the array.
    let n = unsafe { libc::getloadavg(a.as_mut_ptr(), 3) };
    if n >= 1 {
        a[0]
    } else {
        -1.0
    }
}

/// B1: a derivation takes under 100 us (the best of 5 batches of 200 calls,
/// for each case). The budget is for the release build the suite runs.
#[test]
fn budget_b1_derive_under_100_us() {
    if cfg!(debug_assertions) {
        println!("B1 is a release budget; this is a debug build, timings not checked");
        return;
    }
    let mut over = Vec::new();
    for name in CASES {
        let i = case_input(name);
        black_box(derive(black_box(&i)));
        let mut best = f64::MAX;
        for batch in 1..=5 {
            let load = load1();
            let t0 = Instant::now();
            for _ in 0..200 {
                black_box(derive(black_box(&i)));
            }
            let mean = t0.elapsed().as_secs_f64() * 1e6 / 200.0;
            println!("B1 {name} batch {batch}: mean {mean:.1} us per derive (1-minute load {load:.2})");
            best = best.min(mean);
        }
        println!("B1 {name}: best batch mean {best:.1} us (budget 100 us)");
        if best >= 100.0 {
            over.push(format!("{name}: {best:.1} us"));
        }
    }
    assert!(over.is_empty(), "B1 over 100 us: {}", over.join(", "));
}
