//! The palette: the color tokens everything jupynvim draws with, derived
//! from the colorscheme in use. `color` holds the color math (CSS parsing,
//! compositing, WCAG contrast, OKLab, OKLCH and CIELAB lightness),
//! `registry` VS Code's color registry defaults with its resolution rule,
//! `ports` the colors of the known VS Code ports of Neovim colorschemes,
//! `rules` the derivation of the tokens with its floors, and `wire` the
//! text formats of the three job kinds that reach this module through the
//! C ABI (ABI 1.1):
//!
//! - `JNV_KIND_PALETTE` (2048), [`run_derive`]: a colorscheme's highlight
//!   colors in, the 35 tokens with their sources out. An input that carries
//!   the `set` line also becomes the library's current palette.
//! - `JNV_KIND_PALETTE_SCHEMA` (2049), [`run_schema`]: the highlight groups
//!   the rules read, the token names and the known ports (key, source,
//!   label), so the library is the only source of these lists.
//! - `JNV_KIND_PALETTE_READABLE` (2050), [`run_readable`]: a color made
//!   readable on a background (see [`readable`]).
//!
//! Rust code that paints reads the current palette with [`current`] and
//! keys its caches on the palette's `theme_id`.

use std::sync::{Arc, RwLock};

use color::{contrast, Rgb, Rgba};

pub mod color;
pub mod ports;
pub mod registry;
pub mod rules;
pub mod wire;

pub use rules::{derive, CanvasSource, Input, Kind, Palette, Source, Token};

/// The library's current palette: the last one a derive request with the
/// `set` line (or [`set_current`]) made. `None` until one is set.
static CURRENT: RwLock<Option<Arc<Palette>>> = RwLock::new(None);

/// The current palette, if any. The `Arc` is the reader's own: a palette
/// set later does not change what it holds.
pub fn current() -> Option<Arc<Palette>> {
    CURRENT.read().unwrap_or_else(|e| e.into_inner()).clone()
}

/// Make `p` the current palette and return it.
pub fn set_current(p: Palette) -> Arc<Palette> {
    let a = Arc::new(p);
    *CURRENT.write().unwrap_or_else(|e| e.into_inner()) = Some(a.clone());
    a
}

/// `fg` if it reads on `bg` at `target` contrast (WCAG), else whichever of
/// the palette's text and canvas colors contrasts more with `bg` (the text
/// when they contrast equally), or white and black without a palette. For
/// text on a fill the user colored.
pub fn readable(fg: Rgb, bg: Rgb, target: f64, pal: Option<&Palette>) -> Rgb {
    if contrast(fg, bg) >= target {
        return fg;
    }
    let (a, b) = match pal {
        Some(p) => (p.get(Token::Text), p.get(Token::Canvas)),
        None => (Rgb(255, 255, 255), Rgb(0, 0, 0)),
    };
    if contrast(a, bg) >= contrast(b, bg) {
        a
    } else {
        b
    }
}

/// What `c` looks like drawn on `under` in 8 bits: composited when it is
/// translucent, else only rounded. The painter's way to a color that
/// sits on something.
pub fn flatten(c: Rgba, under: Rgb) -> Rgb {
    color::flat(c, under)
}

/// Kind 2048: parse the input (`wire::parse_input`), derive, make the result
/// current when the input asked for it, and encode it (`wire::encode`). A
/// malformed input is an `Err` naming its line; nothing changes then.
pub fn run_derive(input: &[u8]) -> Result<Vec<u8>, String> {
    let input = wire::parse_input(input)?;
    let palette = derive(&input);
    if input.set {
        let current = set_current(palette);
        Ok(wire::encode(&current))
    } else {
        Ok(wire::encode(&palette))
    }
}

/// Kind 2049: the schema (`wire::schema`).
pub fn run_schema() -> Vec<u8> {
    wire::schema().into_bytes()
}

/// Kind 2050: `readable` with the current palette, as `#rrggbb\n`.
pub fn run_readable(input: &[u8]) -> Result<Vec<u8>, String> {
    let (fg, bg, target) = wire::parse_readable(input)?;
    let current = current();
    let c = readable(fg, bg, target, current.as_deref());
    Ok(format!("{}\n", c.hex()).into_bytes())
}

/// The tests' JSON reader (the integration tests' own), for the unit tests
/// that read the palette fixtures.
#[cfg(test)]
#[path = "../../tests/support/minijson.rs"]
pub(crate) mod testjson;

/// The C library's recorded answers, for the tests that prove the color
/// math is the reference's to the last bit on any platform.
#[cfg(test)]
pub(crate) mod libm_replay;

#[cfg(test)]
mod tests {
    use super::color::{contrast, parse_rgb, Rgb, Rgba};
    use super::rules::{GroupColors, Input};
    use super::*;
    use std::sync::{Arc, Mutex, MutexGuard};

    /// The current palette is process wide: the tests that read or write it
    /// run one at a time.
    static CURRENT_LOCK: Mutex<()> = Mutex::new(());

    fn lock() -> MutexGuard<'static, ()> {
        CURRENT_LOCK.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn clear() {
        *CURRENT.write().unwrap_or_else(|e| e.into_inner()) = None;
    }

    fn rgb(s: &str) -> Rgb {
        parse_rgb(s).unwrap_or_else(|| panic!("not #rrggbb: {s}"))
    }

    /// tokyonight storm as the approved case sees it, reduced to what the
    /// readable tests need: `Normal`'s text `#c0caf5` on the terminal's
    /// `#222436`.
    fn user() -> Palette {
        let mut i = Input::new(Kind::Dark);
        i.colors_name = Some("tokyonight-storm".to_string());
        i.terminal = Some(rgb("#222436"));
        i.groups.insert("Normal".into(), GroupColors { fg: Some(rgb("#c0caf5")), bg: None });
        let p = derive(&i);
        assert_eq!(p.get(Token::Text), rgb("#c0caf5"));
        assert_eq!(p.get(Token::Canvas), rgb("#222436"));
        p
    }

    const SET_TEXT: &str = "JNP 1\nkind dark\nname tokyonight-storm\nterm #222436\nset\n";
    const PLAIN_TEXT: &str = "JNP 1\nkind light\nname catppuccin-latte\nterm #eff1f5\n";

    #[test]
    fn set_current_then_current_gives_the_same_theme_id() {
        let _g = lock();
        clear();
        assert!(current().is_none());
        let p = user();
        let id = p.theme_id;
        let a = set_current(p.clone());
        assert_eq!(a.theme_id, id);
        let c = current().expect("a current palette");
        assert_eq!(c.theme_id, id);
        assert!(Arc::ptr_eq(&a, &c), "the Arc set is the Arc read");
        assert_eq!(*c, p);
        let other = derive(&Input::new(Kind::Light));
        assert_ne!(other.theme_id, id);
        set_current(other.clone());
        assert_eq!(current().expect("replaced").theme_id, other.theme_id);
        clear();
    }

    #[test]
    fn a_reader_keeps_the_palette_it_got_when_a_new_one_is_set() {
        let _g = lock();
        let first = set_current(user());
        let held = current().expect("current");
        set_current(derive(&Input::new(Kind::Light)));
        assert_eq!(held.theme_id, first.theme_id);
        assert_ne!(current().expect("current").theme_id, first.theme_id);
        clear();
    }

    #[test]
    fn a_derive_input_with_set_replaces_the_current_palette_and_without_it_leaves_it() {
        let _g = lock();
        clear();
        let out = run_derive(PLAIN_TEXT.as_bytes()).expect("derives");
        assert!(out.starts_with(b"JNP 1\ntheme "));
        assert!(current().is_none(), "no set line: nothing becomes current");
        let out = String::from_utf8(run_derive(SET_TEXT.as_bytes()).expect("derives")).expect("UTF-8");
        let cur = current().expect("set makes it current");
        assert_eq!(out.lines().nth(1), Some(format!("theme {:016x}", cur.theme_id).as_str()));
        assert_eq!(cur.kind, Kind::Dark);
        let before = cur.theme_id;
        let out = String::from_utf8(run_derive(PLAIN_TEXT.as_bytes()).expect("derives")).expect("UTF-8");
        assert_ne!(out.lines().nth(1), Some(format!("theme {before:016x}").as_str()), "a different palette");
        assert_eq!(current().expect("still there").theme_id, before, "without set the current one stays");
        run_derive(format!("{PLAIN_TEXT}set\n").as_bytes()).expect("derives");
        assert_eq!(current().expect("replaced").kind, Kind::Light);
        clear();
    }

    #[test]
    fn a_failed_derive_leaves_the_current_palette_alone() {
        let _g = lock();
        let id = set_current(user()).theme_id;
        let m = run_derive(b"JNP 1\nkind dark\nset\nx y\n").unwrap_err();
        assert!(m.contains("palette input line 4"), "{m}");
        assert_eq!(current().expect("current").theme_id, id);
        clear();
    }

    #[test]
    fn run_derive_gives_what_encode_of_derive_gives() {
        let _g = lock();
        let input = wire::parse_input(PLAIN_TEXT.as_bytes()).expect("parses");
        assert_eq!(run_derive(PLAIN_TEXT.as_bytes()), Ok(wire::encode(&derive(&input))));
    }

    #[test]
    fn run_schema_is_the_wire_schema() {
        assert_eq!(run_schema(), wire::schema().into_bytes());
    }

    #[test]
    fn readable_keeps_a_color_that_is_readable_enough() {
        let p = user();
        assert_eq!(readable(rgb("#c0caf5"), rgb("#222436"), 4.5, Some(&p)), rgb("#c0caf5"));
        assert_eq!(readable(rgb("#c0caf5"), rgb("#222436"), 4.5, None), rgb("#c0caf5"));
        // Exactly at the target counts as readable.
        let (fg, bg) = (rgb("#767676"), rgb("#ffffff"));
        let c = contrast(fg, bg);
        assert!(c >= 4.5 && c < 4.6, "{c}");
        assert_eq!(readable(fg, bg, c, None), fg);
    }

    #[test]
    fn readable_flips_to_the_palette_text_or_canvas() {
        let p = user();
        // Blue text on yellow: the dark canvas reads better than the light text.
        assert_eq!(readable(rgb("#7aa2f7"), rgb("#ffff00"), 4.5, Some(&p)), rgb("#222436"));
        // Dark text on its own dark fill: the light text.
        assert_eq!(readable(rgb("#1c1f31"), rgb("#222436"), 4.5, Some(&p)), rgb("#c0caf5"));
    }

    #[test]
    fn readable_without_a_palette_is_white_or_black() {
        let (fg, bg) = (rgb("#777777"), rgb("#808080"));
        let w = contrast(rgb("#ffffff"), bg);
        let b = contrast(rgb("#000000"), bg);
        let want = if w >= b { rgb("#ffffff") } else { rgb("#000000") };
        assert_eq!(want, rgb("#000000"), "{w} {b}");
        assert_eq!(readable(fg, bg, 4.5, None), want);
        assert_eq!(readable(rgb("#777777"), rgb("#101010"), 4.5, None), rgb("#ffffff"));
    }

    #[test]
    fn readable_respects_the_target() {
        let (fg, bg) = (rgb("#808080"), rgb("#ffffff"));
        assert!(contrast(fg, bg) > 3.0 && contrast(fg, bg) < 4.5);
        assert_eq!(readable(fg, bg, 3.0, None), fg);
        assert_eq!(readable(fg, bg, 4.5, None), rgb("#000000"));
        assert_eq!(readable(fg, bg, 7.0, Some(&user())), rgb("#222436"));
    }

    #[test]
    fn run_readable_reads_the_current_palette() {
        let _g = lock();
        clear();
        assert_eq!(run_readable(b"#1c1f31 #222436"), Ok(b"#ffffff\n".to_vec()));
        assert_eq!(run_readable(b"#c0caf5 #222436"), Ok(b"#c0caf5\n".to_vec()));
        set_current(user());
        assert_eq!(run_readable(b"#1c1f31 #222436"), Ok(b"#c0caf5\n".to_vec()));
        assert_eq!(run_readable(b"#7aa2f7 #ffff00 4.5"), Ok(b"#222436\n".to_vec()));
        assert_eq!(run_readable(b"#7aa2f7 #ffff00 1.5"), Ok(b"#7aa2f7\n".to_vec()));
        assert!(run_readable(b"#7aa2f7").unwrap_err().starts_with("palette readable: "));
        clear();
    }

    #[test]
    fn flatten_composites_over_what_is_underneath() {
        let under = rgb("#222436");
        let veil = Rgba::new(255.0, 255.0, 255.0, 0.18);
        assert_eq!(flatten(veil, under), color::flat(veil, under));
        assert_ne!(flatten(veil, under), under);
        assert_eq!(flatten(Rgba::new(1.0, 2.0, 3.0, 1.0), under), Rgb(1, 2, 3));
    }
}
