//! The VS Code color registry port against live VS Code: for 25 themes and
//! the 26 color ids of the registry, the color the port predicts from a
//! theme's own colors must be the `--vscode-*` value VS Code 1.139.1 gave a
//! markdown preview of that theme (tests/fixtures/palette/
//! vscode_registry_check.json). Equal ignoring case, or, when both parse,
//! every channel within 1 and the alpha within 0.01 (the rounding of VS
//! Code's own CSS output).

#[path = "support/minijson.rs"]
mod minijson;

use std::path::PathBuf;

use jupynvim::palette::color::{parse, Rgba};
use jupynvim::palette::registry::{css, get_color, ids, ThemeType};
use minijson::J;

fn fixture(name: &str) -> J {
    let p = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures/palette").join(name);
    let s = std::fs::read_to_string(&p).unwrap_or_else(|e| panic!("reading {}: {e}", p.display()));
    minijson::parse(&s).unwrap_or_else(|e| panic!("{}: {e}", p.display()))
}

/// The value as the check compares it: a missing, null or empty value is none.
fn value(v: Option<&J>) -> Option<String> {
    v.and_then(J::as_str).filter(|s| !s.is_empty()).map(str::to_string)
}

fn same(pred: &Option<String>, live: &Option<String>) -> bool {
    match (pred, live) {
        (None, None) => true,
        (Some(p), Some(l)) => {
            if p.eq_ignore_ascii_case(l) {
                return true;
            }
            match (parse(p), parse(l)) {
                (Some(a), Some(b)) => {
                    (a.r - b.r).abs() <= 1.0
                        && (a.g - b.g).abs() <= 1.0
                        && (a.b - b.b).abs() <= 1.0
                        && (a.a - b.a).abs() < 0.01
                }
                _ => false,
            }
        }
        _ => false,
    }
}

#[test]
fn the_registry_predicts_every_live_vscode_value() {
    let fx = fixture("vscode_registry_check.json");
    let themes = fx.as_obj().expect("an object of themes");
    assert_eq!(themes.len(), 25, "themes in the fixture");
    let mut reg_ids: Vec<&str> = ids().collect();
    reg_ids.sort_unstable();
    assert_eq!(reg_ids.len(), 26, "ids in the registry");

    let (mut checks, mut mismatches) = (0usize, Vec::new());
    for (slug, t) in themes {
        let ty_name = t.get("type").and_then(J::as_str).unwrap_or_else(|| panic!("{slug}: no type"));
        let ty = ThemeType::from_name(ty_name).unwrap_or_else(|| panic!("{slug}: type {ty_name}"));
        let defined = t.get("defined").and_then(J::as_obj).unwrap_or_else(|| panic!("{slug}: no defined"));
        let live = t.get("live").and_then(J::as_obj).unwrap_or_else(|| panic!("{slug}: no live"));
        // The theme's own colors, as VS Code reads them: an empty value is none.
        let theme = |id: &str| -> Option<Rgba> {
            defined.iter().find(|(k, _)| k == id).and_then(|(_, v)| value(Some(v))).and_then(|s| parse(&s))
        };
        let mut live_ids: Vec<&str> = live.iter().map(|(k, _)| k.as_str()).collect();
        live_ids.sort_unstable();
        assert_eq!(live_ids, reg_ids, "{slug}: the live values cover exactly the registry's ids");
        for (id, lv) in live {
            checks += 1;
            let pred = css(get_color(id, &theme, ty));
            let lv = value(Some(lv));
            if !same(&pred, &lv) {
                mismatches.push(format!("MISMATCH {slug} {id} predicted {pred:?} live {lv:?}"));
            }
        }
    }
    println!("registry checks: {checks}, mismatches: {}", mismatches.len());
    let n = mismatches.len();
    assert!(mismatches.is_empty(), "{n} of {checks} registry checks failed:\n{}", mismatches.join("\n"));
    assert_eq!(checks, 650, "25 themes x 26 ids");
}

/// Every default of the registry port, all four theme types, as VS Code
/// 1.139.1 resolves it (tests/fixtures/palette/registry_defaults.json), compared
/// as the exact css string; the live check above allows one step per channel,
/// which would let a one-step typo in a default through.
#[test]
fn registry_defaults_are_vs_code_s_exactly() {
    let fx = fixture("registry_defaults.json");
    let values = fx.get("values").and_then(J::as_arr).expect("an array of values");
    let (mut checks, mut mismatches) = (0usize, Vec::new());
    let mut seen: Vec<(String, String)> = Vec::new();
    for e in values {
        let id = e.get("id").and_then(J::as_str).expect("an id");
        let ty_name = e.get("type").and_then(J::as_str).expect("a type");
        let ty = ThemeType::from_name(ty_name).unwrap_or_else(|| panic!("{id}: type {ty_name}"));
        let want: Option<String> = match e.get("css").expect("a css member") {
            J::Null => None,
            J::Str(s) => Some(s.clone()),
            other => panic!("{id} {ty_name}: css is neither a string nor null: {other:?}"),
        };
        checks += 1;
        seen.push((id.to_string(), ty_name.to_string()));
        let got = css(get_color(id, &|_| None, ty));
        if got != want {
            mismatches.push(format!("MISMATCH {id} {ty_name} got {got:?} want {want:?}"));
        }
    }
    // every registry id appears once per type
    let mut reg_ids: Vec<&str> = ids().collect();
    reg_ids.sort_unstable();
    for id in &reg_ids {
        for ty in ["dark", "light", "hcDark", "hcLight"] {
            let n = seen.iter().filter(|(i, t)| i == id && t == ty).count();
            assert_eq!(n, 1, "{id} {ty} appears {n} times in the fixture");
        }
    }
    println!("registry default checks: {checks}, mismatches: {}", mismatches.len());
    let n = mismatches.len();
    assert!(mismatches.is_empty(), "{n} of {checks} registry defaults differ:\n{}", mismatches.join("\n"));
    assert_eq!(checks, 104, "26 ids x 4 types");
}
