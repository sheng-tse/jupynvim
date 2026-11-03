//! The palette rules: the 35 color tokens everything jupynvim draws with,
//! derived from the colorscheme in use. Each token takes, in order, the
//! user's override, the colorscheme's Neovim highlight groups, the colors
//! of the scheme's VS Code port when it is a known one (`ports`), and VS
//! Code's own defaults (`registry`), or GitHub's colors where VS Code has
//! none. Then the floors, each judged on the 8-bit color that is drawn:
//!
//! - visibility (fills and the quote bar): a color is visible on the canvas
//!   when it is at least 0.02 away in OKLab lightness and 2.32 in CIELAB
//!   lightness (the same step on CIELAB's scale, which near black does not
//!   call a step visible that is not). One that is not moves in OKLab L,
//!   keeping its chroma and hue (a port background keeps the port color's,
//!   which clamping at black or white would have lost), by the smallest
//!   shift that is visible: on its own side first (darker when level), on
//!   the other side when the first has no room, as on a black canvas;
//! - contrast (text: 4.5:1, the task boxes 3:1): a color moves in OKLab L
//!   only, by the smallest shift that reaches the target, first toward
//!   the text's lightness, then on to the end of the scale on the text's
//!   side of the canvas, then from the canvas's lightness to the far end.
//!   When none reaches it, the text itself if it does, else pure black or
//!   white, so a scheme on a canvas it was not made for still reads;
//! - restore: a color the scheme gives, a Neovim group or a port color
//!   (never a formula's or one that is another token), keeps the contrast
//!   it had on the background it was made for. A port color is made for the
//!   port's background, so it is restored whenever the canvas is another
//!   color, `Normal`'s included; a group color is made for `Normal`'s
//!   background, so it is restored only when the canvas is not that. The
//!   restore lifts as near as the color's hue gets and never falls back
//!   to the text or to black or white. A port's background colors are
//!   re-anchored instead: they keep their OKLab L offset from the port's
//!   background, with their own chroma and hue.
//!
//! VS Code's translucent defaults (code block, preformatted text,
//! separator) are overlays: they take their dark or light variant from what
//! is drawn, dark when the text is lighter than the canvas, whatever
//! `background` says.
//!
//! Two departures from the plain order above are deliberate. The accent, the
//! comment and the alerts note, tip, important and warning take no port
//! color: their groups (`Title`, `Function`, `Comment`, `Statement`,
//! `DiagnosticInfo`, `DiagnosticHint`, `DiagnosticWarn`) are defined by
//! Neovim in every colorscheme, so a port stage after them would never be
//! reached. And there is no token for the underline of a table's header
//! (69% in VS Code's markdown theme): the approved table style draws the
//! grid on every cell in `edge`, so a consumer that wants a header rule
//! takes `edge` or asks for a token here, and never a color of its own.
//!
//! An override is final: no floor touches it, and the tokens derived from
//! it follow it. Every color is 8-bit between steps, so a token is the
//! color that is really drawn.

use std::cell::Cell;
use std::collections::HashMap;

use super::color::{
    contrast, flat, l_of, lstar, mix, oklab, oklab_to_rgb, oklch, oklch_to_rgb, quantize, rel_lum, Rgb, Rgba,
};
use super::ports::{lookup, Port};
use super::registry::default_for;
pub use super::registry::Kind;

/// The palette's tokens, in the order of the wire format and of Lua's
/// `TOKENS`. Never glob-imported: `Token::Ok` and `Token::Error` would
/// shadow `Result`'s variants.
#[repr(u8)]
#[derive(Copy, Clone, PartialEq, Eq, Debug, Hash)]
pub enum Token {
    Canvas = 0,
    Text,
    TextMuted,
    Comment,
    Fill,
    Lifted,
    Edge,
    Track,
    Thumb,
    Accent,
    HeadingH1H3,
    HeadingH4H5,
    HeadingH6,
    Math,
    Link,
    InlineCodeFg,
    InlineCodeBg,
    TaskChecked,
    TaskUnchecked,
    AlertNote,
    AlertTip,
    AlertImportant,
    AlertWarning,
    AlertCaution,
    Ok,
    Info,
    Warn,
    Error,
    SelectionBorderCommand,
    SelectionBorderEdit,
    SelectedBg,
    MarkBg,
    KbdBg,
    KbdBorder,
    QuoteBar,
}

/// How many tokens a palette has.
pub const TOKENS: usize = 35;

const NAMES: [&str; TOKENS] = [
    "canvas",
    "text",
    "text_muted",
    "comment",
    "fill",
    "lifted",
    "edge",
    "track",
    "thumb",
    "accent",
    "heading_h1_h3",
    "heading_h4_h5",
    "heading_h6",
    "math",
    "link",
    "inline_code_fg",
    "inline_code_bg",
    "task_checked",
    "task_unchecked",
    "alert_note",
    "alert_tip",
    "alert_important",
    "alert_warning",
    "alert_caution",
    "ok",
    "info",
    "warn",
    "error",
    "selection_border_command",
    "selection_border_edit",
    "selected_bg",
    "mark_bg",
    "kbd_bg",
    "kbd_border",
    "quote_bar",
];

impl Token {
    /// Every token, in order (`ALL[i] as usize == i`).
    pub const ALL: [Token; TOKENS] = [
        Token::Canvas,
        Token::Text,
        Token::TextMuted,
        Token::Comment,
        Token::Fill,
        Token::Lifted,
        Token::Edge,
        Token::Track,
        Token::Thumb,
        Token::Accent,
        Token::HeadingH1H3,
        Token::HeadingH4H5,
        Token::HeadingH6,
        Token::Math,
        Token::Link,
        Token::InlineCodeFg,
        Token::InlineCodeBg,
        Token::TaskChecked,
        Token::TaskUnchecked,
        Token::AlertNote,
        Token::AlertTip,
        Token::AlertImportant,
        Token::AlertWarning,
        Token::AlertCaution,
        Token::Ok,
        Token::Info,
        Token::Warn,
        Token::Error,
        Token::SelectionBorderCommand,
        Token::SelectionBorderEdit,
        Token::SelectedBg,
        Token::MarkBg,
        Token::KbdBg,
        Token::KbdBorder,
        Token::QuoteBar,
    ];

    /// The token's name, as in `palette/tokens.json` (`text_muted`).
    pub fn name(self) -> &'static str {
        NAMES[self as usize]
    }

    /// The token named `s`, exactly as `name` gives it.
    pub fn from_name(s: &str) -> Option<Token> {
        NAMES.iter().position(|&n| n == s).map(|i| Token::ALL[i])
    }
}

/// Where a token's color came from.
#[derive(Copy, Clone, PartialEq, Eq, Debug)]
pub enum Source {
    /// The user's `palette` setting.
    Override,
    /// A Neovim highlight group.
    Group,
    /// The known VS Code port of the colorscheme.
    Port,
    /// VS Code's (or GitHub's) defaults and formulas.
    Formula,
    /// Another token (or, for the canvas, the terminal's background).
    Derived,
}

impl Source {
    pub fn name(self) -> &'static str {
        match self {
            Source::Override => "override",
            Source::Group => "group",
            Source::Port => "port",
            Source::Formula => "formula",
            Source::Derived => "derived",
        }
    }
}

/// Where the canvas, the background everything is drawn on, came from.
#[derive(Copy, Clone, PartialEq, Eq, Debug)]
pub enum CanvasSource {
    /// `Normal`'s background.
    Normal,
    /// The terminal's own background (its answer to OSC 11), when `Normal`
    /// has none.
    Terminal,
    /// VS Code's `editor.background` default for the kind: nothing else
    /// was known.
    Fallback,
    /// The user's `palette = { canvas = ... }`.
    Override,
}

impl CanvasSource {
    pub fn name(self) -> &'static str {
        match self {
            CanvasSource::Normal => "Normal.bg",
            CanvasSource::Terminal => "terminal",
            CanvasSource::Fallback => "fallback",
            CanvasSource::Override => "override",
        }
    }
}

/// A highlight group's colors (with links resolved).
#[derive(Copy, Clone, Default, PartialEq, Eq, Debug)]
pub struct GroupColors {
    pub fg: Option<Rgb>,
    pub bg: Option<Rgb>,
}

/// What a derivation reads.
#[derive(Clone, Debug, PartialEq)]
pub struct Input {
    /// Neovim's `background`.
    pub kind: Kind,
    /// `g:colors_name`, when a colorscheme set it.
    pub colors_name: Option<String>,
    /// The terminal's background (its OSC 11 answer), when known.
    pub terminal: Option<Rgb>,
    /// The highlight groups; only those of `GROUPS` are read.
    pub groups: HashMap<String, GroupColors>,
    /// The user's overrides, by token index. An override of the canvas may
    /// come here or in `canvas_override`, which wins.
    pub overrides: [Option<Rgb>; TOKENS],
    pub canvas_override: Option<Rgb>,
    /// Also make the result the library's current palette.
    pub set: bool,
}

impl Input {
    /// No colorscheme, no terminal answer, no groups, no overrides.
    pub fn new(kind: Kind) -> Input {
        Input {
            kind,
            colors_name: None,
            terminal: None,
            groups: HashMap::new(),
            overrides: [None; TOKENS],
            canvas_override: None,
            set: false,
        }
    }
}

/// A derived palette.
#[derive(Clone, Debug, PartialEq)]
pub struct Palette {
    pub tokens: [Rgb; TOKENS],
    pub sources: [Source; TOKENS],
    /// Per token, where inside its source it came from, never repeating the
    /// source's name: the group (`RenderMarkdownCode.bg`), `<port key>
    /// <color id>` or `<port key> completion` for a port, `VS Code <id>`,
    /// `GitHub <what>` or the formula's words for a formula, `= <token>` for
    /// a derived token, empty for an override; then what moved it (`;
    /// visibility floor from #rrggbb`, `; lifted to N.N:1 from #rrggbb`,
    /// `; restored from #rrggbb`).
    pub details: [String; TOKENS],
    pub kind: Kind,
    pub canvas_source: CanvasSource,
    /// The key of the known port used, if any.
    pub port: Option<&'static str>,
    /// FNV-1a 64 over the 35 colors' bytes in token order, then the kind
    /// (0 dark, 1 light): what caches key on.
    pub theme_id: u64,
}

impl Palette {
    pub fn get(&self, t: Token) -> Rgb {
        self.tokens[t as usize]
    }
}

/// The highlight groups the rules read, in the order of first use.
pub const GROUPS: [&str; 37] = [
    "Normal",
    "Comment",
    "@comment",
    "RenderMarkdownCode",
    "@markup.raw.block",
    "MarkviewCode",
    "markdownCodeBlock",
    "NormalFloat",
    "CursorLine",
    "@markup.raw.markdown_inline",
    "RenderMarkdownCodeInline",
    "@markup.quote",
    "RenderMarkdownQuote",
    "markdownBlockquote",
    "@markup.heading.1",
    "@markup.heading",
    "Title",
    "Function",
    "@markup.math",
    "@markup.link.url",
    "@markup.link",
    "markdownUrl",
    "Underlined",
    "Directory",
    "@markup.raw",
    "markdownCode",
    "@markup.list.checked",
    "RenderMarkdownChecked",
    "@markup.list.unchecked",
    "RenderMarkdownUnchecked",
    "DiagnosticInfo",
    "DiagnosticHint",
    "Statement",
    "DiagnosticWarn",
    "DiagnosticError",
    "DiagnosticOk",
    "PmenuSel",
];

/// GitHub's colors (github-markdown-css 5.9.0) where VS Code has none.
struct GitHub {
    note: Rgb,
    tip: Rgb,
    important: Rgb,
    warning: Rgb,
    caution: Rgb,
    success: Rgb,
}

const GITHUB_DARK: GitHub = GitHub {
    note: Rgb::from_u32(0x4493f8),
    tip: Rgb::from_u32(0x3fb950),
    important: Rgb::from_u32(0xab7df8),
    warning: Rgb::from_u32(0xd29922),
    caution: Rgb::from_u32(0xf85149),
    success: Rgb::from_u32(0x3fb950),
};

const GITHUB_LIGHT: GitHub = GitHub {
    note: Rgb::from_u32(0x0969da),
    tip: Rgb::from_u32(0x1a7f37),
    important: Rgb::from_u32(0x8250df),
    warning: Rgb::from_u32(0x9a6700),
    caution: Rgb::from_u32(0xd1242f),
    success: Rgb::from_u32(0x1a7f37),
};

/// Neovim's own `DiagnosticOk` foreground (`NvimLightGreen` on dark,
/// `NvimDarkGreen` on light), which a colorscheme that does not set the
/// group leaves in place.
fn nvim_default_ok(kind: Kind) -> Rgb {
    match kind {
        Kind::Dark => Rgb::from_u32(0xb3f6c0),
        Kind::Light => Rgb::from_u32(0x005523),
    }
}

/// The smallest OKLab L distance between a fill and the canvas.
pub const VIS_DL: f64 = 0.02;

/// The smallest CIELAB L* distance: 116 times `VIS_DL`, the same step on
/// CIELAB's scale (a linear segment near black, where OKLab's cube root
/// calls steps of 0.03 or more invisible).
pub const VIS_DLSTAR: f64 = 2.32;

/// The steps of every bisection.
const STEPS: usize = 40;

/// `contrast(x, bg)` for many `x` against one `bg`, as a bisection asks
/// it: `color::contrast`'s arithmetic exactly, with `bg`'s luminance
/// computed once and the last color's remembered (a bisection's late steps
/// land on the same 8-bit color again and again).
struct Against {
    lb: f64,
    last: Cell<Option<(Rgb, f64)>>,
}

impl Against {
    fn new(bg: Rgb) -> Against {
        Against { lb: rel_lum(bg), last: Cell::new(None) }
    }

    fn cr(&self, x: Rgb) -> f64 {
        let la = match self.last.get() {
            Some((c, l)) if c == x => l,
            _ => {
                let l = rel_lum(x);
                self.last.set(Some((x, l)));
                l
            }
        };
        let (hi, lo) = if la >= self.lb { (la, self.lb) } else { (self.lb, la) };
        (hi + 0.05) / (lo + 0.05)
    }
}

/// `color::mix(a, b, t)` for many `t`: the same arithmetic, with both
/// colors' OKLab computed once.
struct Mixer {
    x: [f64; 3],
    y: [f64; 3],
}

impl Mixer {
    fn new(a: Rgb, b: Rgb) -> Mixer {
        Mixer { x: oklab(a), y: oklab(b) }
    }

    fn at(&self, t: f64) -> Rgb {
        let (x, y) = (self.x, self.y);
        quantize(oklab_to_rgb(x[0] + (y[0] - x[0]) * t, x[1] + (y[1] - x[1]) * t, x[2] + (y[2] - x[2]) * t))
    }
}

/// The canvas's lightness in OKLab and in CIELAB, for judging many colors
/// against one canvas.
struct Under {
    l: f64,
    ls: f64,
}

impl Under {
    fn new(under: Rgb) -> Under {
        Under { l: l_of(under), ls: lstar(under) }
    }

    /// `visible(x, under)`.
    fn sees(&self, x: Rgb) -> bool {
        (l_of(x) - self.l).abs() >= VIS_DL && (lstar(x) - self.ls).abs() >= VIS_DLSTAR
    }
}

/// Whether `x` is visible on `under`: at least `VIS_DL` apart in OKLab L and
/// `VIS_DLSTAR` in CIELAB L*, judged on the 8-bit colors. Symmetric.
pub fn visible(x: Rgb, under: Rgb) -> bool {
    Under::new(under).sees(x)
}

/// The visibility floor: `c` when it is visible on `under`; else the hue
/// and chroma of `hue_of` (default `c`) at the OKLab L nearest `under`'s
/// whose 8-bit color is visible, searched up to 0.2 away: on the side `c`
/// is on (darker when it is level), else on the other side.
pub fn vis_floor(c: Rgb, under: Rgb, hue_of: Option<Rgb>) -> Rgb {
    let u = Under::new(under);
    if u.sees(c) {
        return c;
    }
    let d = l_of(c) - u.l;
    let sign = if d.abs() > 1e-4 && d > 0.0 { 1.0 } else { -1.0 };
    let [_, ch, h] = oklch(hue_of.unwrap_or(c));
    // The smallest visible color on one side, and whether there is one.
    let side = |sg: f64| -> (Rgb, bool) {
        let q = |s: f64| quantize(oklch_to_rgb(u.l + sg * s, ch, h));
        let last: Cell<Option<(Rgb, bool)>> = Cell::new(None);
        let ok = |s: f64| {
            let x = q(s);
            match last.get() {
                Some((y, ok)) if y == x => ok,
                _ => {
                    let ok = u.sees(x);
                    last.set(Some((x, ok)));
                    ok
                }
            }
        };
        if ok(VIS_DL) {
            return (q(VIS_DL), true);
        }
        let (mut lo, mut hi) = (VIS_DL, 0.2);
        for _ in 0..STEPS {
            let mid = (lo + hi) / 2.0;
            if ok(mid) {
                hi = mid;
            } else {
                lo = mid;
            }
        }
        (q(hi), ok(hi))
    };
    let (x, good) = side(sign);
    if good {
        return x;
    }
    let (y, good) = side(-sign);
    if good {
        y
    } else {
        x
    }
}

/// The contrast floor: `c` when it is at least `target`:1 against `bg`;
/// else `c` with only its OKLab L moved, by the smallest shift whose 8-bit
/// color meets `target`: toward `toward`'s L; when even that is not enough,
/// on to the end of the scale on `toward`'s side of `bg`; then from `bg`'s
/// L to the far end. When none reaches it, `toward` if it does, else pure
/// white or black, whichever contrasts more with `bg`.
pub fn lift(c: Rgb, bg: Rgb, target: f64, toward: Rgb) -> Rgb {
    lift_by(c, bg, target, toward, false)
}

/// `lift` for the restore floor, which asks for the contrast a color had
/// elsewhere and may ask for more than any color can give: the same three
/// stages, but when none reaches the target the better of the last two
/// ends if it contrasts more than `c` does, else `c`. It never falls back
/// to `toward` or to pure black or white.
pub fn lift_soft(c: Rgb, bg: Rgb, target: f64, toward: Rgb) -> Rgb {
    lift_by(c, bg, target, toward, true)
}

fn lift_by(c: Rgb, bg: Rgb, target: f64, toward: Rgb, soft: bool) -> Rgb {
    let on = Against::new(bg);
    if on.cr(c) >= target {
        return c;
    }
    let [l0, ch, h] = oklch(c);
    let (lt, lb) = (l_of(toward), l_of(bg));
    let q = |t: f64| quantize(oklch_to_rgb(l0 + (lt - l0) * t, ch, h));
    if on.cr(q(1.0)) >= target {
        return q(bisect(|t| on.cr(q(t)) >= target));
    }
    let end = if lt < lb { 0.0 } else { 1.0 };
    let q2 = |t: f64| quantize(oklch_to_rgb(lt + (end - lt) * t, ch, h));
    if on.cr(q2(1.0)) >= target {
        return q2(bisect(|t| on.cr(q2(t)) >= target));
    }
    let far = 1.0 - end;
    let q3 = |t: f64| quantize(oklch_to_rgb(lb + (far - lb) * t, ch, h));
    if on.cr(q3(1.0)) >= target {
        return q3(bisect(|t| on.cr(q3(t)) >= target));
    }
    if soft {
        let (a, b) = (q2(1.0), q3(1.0));
        let best = if on.cr(a) >= on.cr(b) { a } else { b };
        return if on.cr(best) > on.cr(c) { best } else { c };
    }
    if on.cr(toward) >= target {
        return toward;
    }
    let (white, black) = (Rgb(255, 255, 255), Rgb(0, 0, 0));
    if on.cr(white) >= on.cr(black) {
        white
    } else {
        black
    }
}

/// The smallest `t` in [0, 1] for which `meets(t)` holds, to 40 halvings
/// (`meets` grows with `t`; `meets(1)` holds).
fn bisect(meets: impl Fn(f64) -> bool) -> f64 {
    let (mut lo, mut hi) = (0.0, 1.0);
    for _ in 0..STEPS {
        let mid = (lo + hi) / 2.0;
        if meets(mid) {
            hi = mid;
        } else {
            lo = mid;
        }
    }
    hi
}

/// Muted text: `text` when it is at most 7:1 against `canvas`, else the
/// OKLab mix from `text` toward `canvas` that stays at 7:1.
pub fn muted_7(text: Rgb, canvas: Rgb) -> Rgb {
    let on = Against::new(canvas);
    if on.cr(text) <= 7.0 {
        return text;
    }
    let m = Mixer::new(text, canvas);
    let (mut lo, mut hi) = (0.0, 1.0);
    for _ in 0..STEPS {
        let mid = (lo + hi) / 2.0;
        if on.cr(m.at(mid)) >= 7.0 {
            lo = mid;
        } else {
            hi = mid;
        }
    }
    m.at(lo)
}

/// The OKLab mix from `canvas` toward `toward` that first reaches `target`:1
/// against the canvas.
pub fn mix_to_contrast(canvas: Rgb, toward: Rgb, target: f64) -> Rgb {
    let (on, m) = (Against::new(canvas), Mixer::new(canvas, toward));
    m.at(bisect(|t| on.cr(m.at(t)) >= target))
}

/// The restore floor for a color `v` the scheme gives, drawn on `canvas`
/// instead of `target`, the background it was made for (none: nothing to
/// restore): when `v` contrasts less with the canvas than with the target,
/// it is lifted toward `toward` until it contrasts as much as it did there,
/// or as near as its hue gets (`lift_soft`).
pub fn restore(v: Rgb, canvas: Rgb, target: Option<Rgb>, toward: Rgb) -> Rgb {
    let Some(target) = target else {
        return v;
    };
    let want = contrast(v, target);
    if contrast(v, canvas) >= want {
        return v;
    }
    lift_soft(v, canvas, want, toward)
}

/// A port's background color `v` re-anchored on `canvas`: translucent, it
/// is flattened over the canvas; opaque, it keeps its own hue and chroma
/// and its OKLab L offset from the port's background `pbg`.
pub fn bgport(v: Rgba, canvas: Rgb, pbg: Rgb) -> Rgb {
    if v.a < 0.999 {
        return flat(v, canvas);
    }
    let [l, ch, h] = oklch(quantize(v));
    quantize(oklch_to_rgb(l_of(canvas) + (l - l_of(pbg)), ch, h))
}

#[derive(Copy, Clone, PartialEq, Eq)]
enum Attr {
    Fg,
    Bg,
}

impl Attr {
    fn name(self) -> &'static str {
        match self {
            Attr::Fg => "fg",
            Attr::Bg => "bg",
        }
    }
}

/// A color with its source and detail, before the floors.
type Cand = (Rgb, Source, String);

/// One derivation's state: the tokens so far.
struct Cx<'a> {
    input: &'a Input,
    port: Option<&'static Port>,
    /// The port's `editor.background`.
    pbg: Option<Rgb>,
    canvas: Rgb,
    /// The port's background when the canvas is another color: what the
    /// restore floor measures a port color against.
    target_port: Option<Rgb>,
    /// The same for a group color, which is made for `Normal`'s background:
    /// none when the canvas is `Normal`'s.
    target_group: Option<Rgb>,
    text: Rgb,
    /// Which variant of VS Code's translucent defaults is drawn: dark when
    /// the text is lighter than the canvas, else light.
    overlay: Kind,
    /// `DiagnosticOk` at Neovim's default does not count: a colorscheme
    /// other than `default` is in use.
    skip_nvim_ok: bool,
    tokens: [Rgb; TOKENS],
    sources: [Source; TOKENS],
    details: [String; TOKENS],
    /// The text colors lifted so far toward the text: (color, on, floor's
    /// bits, result). Tokens often share a color (a scheme's blue for
    /// headings, math and links), and a lift is a 40 step bisection.
    lifts: Vec<(Rgb, Rgb, u64, Rgb)>,
}

impl Cx<'_> {
    fn get(&self, t: Token) -> Rgb {
        self.tokens[t as usize]
    }

    fn put(&mut self, t: Token, c: Rgb, s: Source, detail: String) {
        self.tokens[t as usize] = c;
        self.sources[t as usize] = s;
        self.details[t as usize] = detail;
    }

    fn overridden(&self, t: Token) -> Option<Rgb> {
        if t == Token::Canvas {
            self.input.canvas_override.or(self.input.overrides[0])
        } else {
            self.input.overrides[t as usize]
        }
    }

    /// Puts `t`'s override, when it has one; true when it did.
    fn take_override(&mut self, t: Token) -> bool {
        match self.overridden(t) {
            Some(c) => {
                self.put(t, c, Source::Override, String::new());
                true
            }
            None => false,
        }
    }

    /// A group's color, if the input has it.
    fn g(&self, name: &str, attr: Attr) -> Option<Rgb> {
        let gc = self.input.groups.get(name)?;
        let c = match attr {
            Attr::Fg => gc.fg,
            Attr::Bg => gc.bg,
        }?;
        if self.skip_nvim_ok && attr == Attr::Fg && name == "DiagnosticOk" && c == nvim_default_ok(self.input.kind) {
            return None;
        }
        Some(c)
    }

    /// The first of the groups' colors present (and not `exclude`).
    fn first(&self, names: &[&str], attr: Attr, exclude: Option<Rgb>) -> Option<Cand> {
        names.iter().find_map(|n| {
            let c = self.g(n, attr).filter(|&c| Some(c) != exclude)?;
            Some((c, Source::Group, format!("{n}.{}", attr.name())))
        })
    }

    /// The port's color for `id`, with its alpha.
    fn p(&self, id: &str) -> Option<Rgba> {
        self.port?.color(id)
    }

    /// The port's color for `id` as drawn on the canvas, as a candidate.
    fn pc(&self, id: &str) -> Option<Cand> {
        let c = flat(self.p(id)?, self.canvas);
        Some((c, Source::Port, self.pdetail(id)))
    }

    fn pdetail(&self, what: &str) -> String {
        format!("{} {what}", self.port.map_or("-", |p| p.key))
    }

    /// The port's completion for `t`, as a candidate.
    fn completion(&self, t: Token) -> Option<Cand> {
        let c = self.port?.completion(t)?;
        Some((c, Source::Port, self.pdetail("completion")))
    }

    /// VS Code's default for `id`, opaque, as a candidate.
    fn reg(&self, id: &str) -> Cand {
        (quantize(default_for(id, self.input.kind)), Source::Formula, format!("VS Code {id}"))
    }

    /// What the restore floor measures a color of source `s` against: only
    /// a color the scheme gives is restored, a port's against the port's
    /// background, a group's against the same unless the canvas is
    /// `Normal`'s.
    fn target_of(&self, s: Source) -> Option<Rgb> {
        match s {
            Source::Port => self.target_port,
            Source::Group => self.target_group,
            _ => None,
        }
    }

    /// `v` restored (toward the text), with the detail saying so; a formula
    /// or derived color is returned as it is.
    fn restored(&self, (v, s, mut d): Cand) -> Cand {
        let r = restore(v, self.canvas, self.target_of(s), self.text);
        if r != v {
            d.push_str(&format!("; restored from {}", v.hex()));
        }
        (r, s, d)
    }

    /// A color drawn as text: restored, then lifted to `floor`:1 against
    /// `on`.
    fn fg(&mut self, t: Token, cand: Cand, floor: f64, on: Rgb) {
        if self.take_override(t) {
            return;
        }
        let (r, s, mut d) = self.restored(cand);
        let key = (r, on, floor.to_bits());
        let x = match self.lifts.iter().find(|l| (l.0, l.1, l.2) == key) {
            Some(l) => l.3,
            None => {
                let x = lift(r, on, floor, self.text);
                self.lifts.push((r, on, key.2, x));
                x
            }
        };
        if x != r {
            d.push_str(&format!("; lifted to {floor:.1}:1 from {}", r.hex()));
        }
        self.put(t, x, s, d);
    }

    /// A fill: the first group background that is not the canvas, else the
    /// port's color re-anchored, else VS Code's default flattened over the
    /// canvas; then the visibility floor.
    fn fill(&mut self, t: Token, names: &[&str], port_id: &str, reg_id: &str) {
        if self.take_override(t) {
            return;
        }
        let canvas = self.canvas;
        // An opaque port background keeps the port color's own chroma and
        // hue when the floor moves it: re-anchoring may have clamped them away.
        let mut hue_of = None;
        let (c, s, mut d) = self
            .first(names, Attr::Bg, Some(canvas))
            .or_else(|| {
                let (v, pbg) = (self.p(port_id)?, self.pbg?);
                if v.a >= 0.999 {
                    hue_of = Some(quantize(v));
                }
                Some((bgport(v, canvas, pbg), Source::Port, self.pdetail(port_id)))
            })
            .unwrap_or_else(|| {
                let kind = self.input.kind;
                let mut def = default_for(reg_id, kind);
                if def.a < 0.999 {
                    def = default_for(reg_id, self.overlay);
                }
                (flat(def, canvas), Source::Formula, format!("VS Code {reg_id}"))
            });
        let x = vis_floor(c, canvas, hue_of);
        if x != c {
            d.push_str(&format!("; visibility floor from {}", c.hex()));
        }
        self.put(t, x, s, d);
    }

    /// A token equal to another one (unless overridden).
    fn same_as(&mut self, t: Token, from: Token) {
        if !self.take_override(t) {
            self.put(t, self.get(from), Source::Derived, format!("= {}", from.name()));
        }
    }
}

/// The palette for `input`, by the rules above, token by token in the
/// order each one's sources need.
pub fn derive(input: &Input) -> Palette {
    let kind = input.kind;
    let port = input.colors_name.as_deref().and_then(|n| lookup(n, kind));
    let gh = match kind {
        Kind::Dark => &GITHUB_DARK,
        Kind::Light => &GITHUB_LIGHT,
    };
    let mut cx = Cx {
        input,
        port,
        pbg: port.map(Port::bg),
        canvas: Rgb(0, 0, 0),
        target_port: None,
        target_group: None,
        text: Rgb(0, 0, 0),
        overlay: kind,
        skip_nvim_ok: input.colors_name.as_deref().is_some_and(|n| n != "default"),
        tokens: [Rgb(0, 0, 0); TOKENS],
        sources: [Source::Formula; TOKENS],
        details: std::array::from_fn(|_| String::new()),
        lifts: Vec::with_capacity(TOKENS),
    };

    // The canvas: the override, Normal's background, the terminal's, VS
    // Code's default.
    let canvas_source = if cx.take_override(Token::Canvas) {
        CanvasSource::Override
    } else if let Some(c) = cx.g("Normal", Attr::Bg) {
        cx.put(Token::Canvas, c, Source::Group, "Normal.bg".to_string());
        CanvasSource::Normal
    } else if let Some(c) = input.terminal {
        cx.put(Token::Canvas, c, Source::Derived, "the terminal's background (OSC 11)".to_string());
        CanvasSource::Terminal
    } else {
        let (c, s, d) = cx.reg("editor.background");
        cx.put(Token::Canvas, c, s, d);
        CanvasSource::Fallback
    };
    let canvas = cx.get(Token::Canvas);
    cx.canvas = canvas;
    cx.target_port = cx.pbg.filter(|&pbg| pbg != canvas);
    cx.target_group = cx.target_port.filter(|_| canvas_source != CanvasSource::Normal);

    // Text: restored (toward itself) and lifted toward its own L, then on
    // to the end of the scale, and else to black or white.
    if !cx.take_override(Token::Text) {
        let (c, s, mut d) = cx
            .first(&["Normal"], Attr::Fg, None)
            .or_else(|| cx.pc("editor.foreground"))
            .unwrap_or_else(|| cx.reg("editor.foreground"));
        let r = restore(c, canvas, cx.target_of(s), c);
        if r != c {
            d.push_str(&format!("; restored from {}", c.hex()));
        }
        let x = lift(r, canvas, 4.5, c);
        if x != r {
            d.push_str(&format!("; lifted to 4.5:1 from {}", r.hex()));
        }
        cx.put(Token::Text, x, s, d);
    }
    let text = cx.get(Token::Text);
    cx.text = text;
    cx.overlay = if l_of(text) > l_of(canvas) { Kind::Dark } else { Kind::Light };

    // Muted text: the port's foreground when it is quieter than the text,
    // else the text mixed toward the canvas down to 7:1.
    let muted = match cx.pc("editor.foreground") {
        Some(p) if p.0 != text && contrast(p.0, canvas) < contrast(text, canvas) => p,
        _ => (muted_7(text, canvas), Source::Formula, "text toward the canvas, at most 7:1".to_string()),
    };
    cx.fg(Token::TextMuted, muted, 4.5, canvas);

    let comment = cx.first(&["Comment", "@comment"], Attr::Fg, None).unwrap_or_else(|| {
        let c = flat(Rgba::new(text.0 as f64, text.1 as f64, text.2 as f64, 179.0 / 255.0), canvas);
        (c, Source::Formula, "text at 70% over the canvas".to_string())
    });
    cx.fg(Token::Comment, comment, 4.5, canvas);

    cx.fill(
        Token::Fill,
        &["RenderMarkdownCode", "@markup.raw.block", "MarkviewCode", "markdownCodeBlock", "NormalFloat"],
        "textCodeBlock.background",
        "textCodeBlock.background",
    );
    cx.fill(Token::Lifted, &["CursorLine"], "list.inactiveSelectionBackground", "textPreformat.background");
    cx.fill(
        Token::InlineCodeBg,
        &["@markup.raw.markdown_inline", "RenderMarkdownCodeInline", "CursorLine"],
        "textPreformat.background",
        "textPreformat.background",
    );

    // Lines: a port separator only when it is quiet (under 3:1), a port
    // line number only when quieter than the edge.
    if !cx.take_override(Token::Edge) {
        let edge = match cx.pc("textSeparator.foreground") {
            Some(p) if contrast(p.0, canvas) < 3.0 => cx.restored(p),
            _ => {
                let c = flat(default_for("textSeparator.foreground", cx.overlay), canvas);
                (c, Source::Formula, "VS Code textSeparator.foreground".to_string())
            }
        };
        cx.put(Token::Edge, edge.0, edge.1, edge.2);
    }
    if !cx.take_override(Token::Track) {
        // As drawn (restored), not louder than the edge.
        let edge = cx.get(Token::Edge);
        match cx.pc("editorLineNumber.foreground").map(|p| cx.restored(p)) {
            Some((c, s, d)) if contrast(c, canvas) < contrast(edge, canvas) => cx.put(Token::Track, c, s, d),
            _ => cx.put(Token::Track, edge, Source::Derived, "= edge".to_string()),
        }
    }
    if !cx.take_override(Token::Thumb) {
        let (c, s, d) = match cx.completion(Token::Thumb) {
            Some(p) => cx.restored(p),
            None => {
                let c = mix_to_contrast(canvas, text, 3.0);
                (c, Source::Formula, "canvas toward text, 3:1".to_string())
            }
        };
        cx.put(Token::Thumb, c, s, d);
    }
    if !cx.take_override(Token::QuoteBar) {
        let cand = cx
            .first(&["@markup.quote", "RenderMarkdownQuote", "markdownBlockquote"], Attr::Fg, None)
            .or_else(|| cx.completion(Token::QuoteBar))
            .or_else(|| cx.pc("textBlockQuote.border"))
            .unwrap_or_else(|| {
                let (t, what) = match kind {
                    Kind::Dark => (0.20, "canvas toward text, 20%"),
                    Kind::Light => (0.11, "canvas toward text, 11%"),
                };
                (mix(canvas, text, t), Source::Formula, what.to_string())
            });
        let (r, s, mut d) = cx.restored(cand);
        let x = vis_floor(r, canvas, None);
        if x != r {
            d.push_str(&format!("; visibility floor from {}", r.hex()));
        }
        cx.put(Token::QuoteBar, x, s, d);
    }

    // Text colors.
    let accent = cx
        .first(&["@markup.heading.1", "@markup.heading", "Title", "Function"], Attr::Fg, None)
        .unwrap_or_else(|| cx.reg("focusBorder"));
    cx.fg(Token::Accent, accent, 4.5, canvas);
    let math = cx
        .first(&["@markup.math"], Attr::Fg, None)
        .unwrap_or_else(|| (text, Source::Derived, "= text".to_string()));
    cx.fg(Token::Math, math, 4.5, canvas);
    let link = cx
        .first(&["@markup.link.url", "@markup.link", "markdownUrl", "Underlined", "Directory"], Attr::Fg, None)
        .or_else(|| cx.pc("textLink.foreground"))
        .unwrap_or_else(|| cx.reg("textLink.foreground"));
    cx.fg(Token::Link, link, 4.5, canvas);
    let code = cx
        .first(
            &["@markup.raw.markdown_inline", "RenderMarkdownCodeInline", "@markup.raw", "markdownCode"],
            Attr::Fg,
            None,
        )
        .or_else(|| cx.pc("textPreformat.foreground"))
        .unwrap_or_else(|| cx.reg("textPreformat.foreground"));
    let code_bg = cx.get(Token::InlineCodeBg);
    cx.fg(Token::InlineCodeFg, code, 4.5, code_bg);
    let accent = cx.get(Token::Accent);
    for (t, names) in [
        (Token::TaskChecked, ["@markup.list.checked", "RenderMarkdownChecked"]),
        (Token::TaskUnchecked, ["@markup.list.unchecked", "RenderMarkdownUnchecked"]),
    ] {
        let c = cx
            .first(&names, Attr::Fg, None)
            .unwrap_or_else(|| (accent, Source::Derived, "= accent".to_string()));
        cx.fg(t, c, 3.0, canvas);
    }
    for (t, group, c, what) in [
        (Token::AlertNote, "DiagnosticInfo", gh.note, "note"),
        (Token::AlertTip, "DiagnosticHint", gh.tip, "tip"),
        (Token::AlertImportant, "Statement", gh.important, "important"),
        (Token::AlertWarning, "DiagnosticWarn", gh.warning, "warning"),
    ] {
        let c = cx
            .first(&[group], Attr::Fg, None)
            .unwrap_or_else(|| (c, Source::Formula, format!("GitHub {what}")));
        cx.fg(t, c, 4.5, canvas);
    }

    // Caution: the first candidate that already reads at 4.5:1, else the
    // first one lifted.
    if !cx.take_override(Token::AlertCaution) {
        let mut cands: Vec<Cand> = Vec::with_capacity(3);
        if let Some(c) = cx.first(&["DiagnosticError"], Attr::Fg, None) {
            cands.push(cx.restored(c));
        }
        for id in ["editorError.foreground", "terminal.ansiRed"] {
            if let Some(c) = cx.pc(id) {
                cands.push(cx.restored(c));
            }
        }
        let pick = match cands.iter().position(|c| contrast(c.0, canvas) >= 4.5) {
            Some(i) => cands.swap_remove(i),
            None => {
                let (c, s, mut d) = if cands.is_empty() {
                    (gh.caution, Source::Formula, "GitHub caution".to_string())
                } else {
                    cands.swap_remove(0)
                };
                let x = lift(c, canvas, 4.5, text);
                if x != c {
                    d.push_str(&format!("; lifted to 4.5:1 from {}", c.hex()));
                }
                (x, s, d)
            }
        };
        cx.put(Token::AlertCaution, pick.0, pick.1, pick.2);
    }

    let ok = cx
        .first(&["DiagnosticOk"], Attr::Fg, None)
        .or_else(|| cx.completion(Token::Ok))
        .or_else(|| cx.pc("testing.iconPassed"))
        .or_else(|| cx.pc("terminal.ansiGreen"))
        .unwrap_or_else(|| (gh.success, Source::Formula, "GitHub success".to_string()));
    cx.fg(Token::Ok, ok, 4.5, canvas);

    cx.fill(
        Token::SelectedBg,
        &["PmenuSel"],
        "editorSuggestWidget.selectedBackground",
        "list.inactiveSelectionBackground",
    );

    // Derived tokens.
    for (t, from) in [
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
    ] {
        cx.same_as(t, from);
    }
    if !cx.take_override(Token::MarkBg) {
        let w = cx.get(Token::AlertWarning);
        let c = flat(Rgba::new(w.0 as f64, w.1 as f64, w.2 as f64, 38.0 / 255.0), canvas);
        cx.put(Token::MarkBg, c, Source::Derived, "= alert_warning at 15% over the canvas".to_string());
    }

    Palette {
        theme_id: theme_id(&cx.tokens, kind),
        tokens: cx.tokens,
        sources: cx.sources,
        details: cx.details,
        kind,
        canvas_source,
        port: port.map(|p| p.key),
    }
}

/// FNV-1a 64 over the tokens' bytes in order, then 0 for dark or 1 for
/// light.
fn theme_id(tokens: &[Rgb; TOKENS], kind: Kind) -> u64 {
    const OFFSET: u64 = 0xcbf2_9ce4_8422_2325;
    const PRIME: u64 = 0x0000_0100_0000_01b3;
    let kind_byte = match kind {
        Kind::Dark => 0u8,
        Kind::Light => 1u8,
    };
    tokens
        .iter()
        .flat_map(|c| [c.0, c.1, c.2])
        .chain([kind_byte])
        .fold(OFFSET, |h, b| (h ^ b as u64).wrapping_mul(PRIME))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// `n` colors spread over the 8-bit cube.
    fn sample(n: u32, seed: u32) -> Vec<Rgb> {
        (0..n).map(|i| Rgb::from_u32(i.wrapping_add(seed).wrapping_mul(2_654_435_761) >> 8)).collect()
    }

    #[test]
    fn against_is_contrast_to_the_last_bit() {
        for (a, b) in sample(2000, 1).into_iter().zip(sample(2000, 99)) {
            let on = Against::new(b);
            let want = contrast(a, b).to_bits();
            assert_eq!(on.cr(a).to_bits(), want, "{} on {}", a.hex(), b.hex());
            assert_eq!(on.cr(a).to_bits(), want, "{} on {} remembered", a.hex(), b.hex());
            assert_eq!(on.cr(b).to_bits(), contrast(b, b).to_bits());
        }
    }

    #[test]
    fn mixer_is_mix_to_the_last_bit() {
        for (a, b) in sample(500, 3).into_iter().zip(sample(500, 51)) {
            let m = Mixer::new(a, b);
            for t in [0.0, 0.1, 0.2, 0.11, 0.37, 0.5, 0.731, 0.999, 1.0] {
                assert_eq!(m.at(t), mix(a, b, t), "{} to {} at {t}", a.hex(), b.hex());
            }
        }
    }

    #[test]
    fn the_floors_leave_what_already_meets_them() {
        let (canvas, text) = (Rgb::from_u32(0x222436), Rgb::from_u32(0xc0caf5));
        assert_eq!(vis_floor(Rgb::from_u32(0x292e42), canvas, None), Rgb::from_u32(0x292e42));
        assert_eq!(lift(text, canvas, 4.5, text), text);
        assert_eq!(restore(text, canvas, None, text), text);
        // On a darker canvas than the port's, a light color contrasts more:
        // nothing to restore.
        assert_eq!(restore(text, canvas, Some(Rgb::from_u32(0x24283b)), text), text);
        assert_eq!(muted_7(Rgb::from_u32(0x4c4f69), Rgb::from_u32(0xeff1f5)), Rgb::from_u32(0x4c4f69));
    }

    #[test]
    fn a_port_background_keeps_its_offset_from_the_ports_own() {
        let pbg = Rgb::from_u32(0x24283b);
        let fill = Rgba::new(31.0, 35.0, 53.0, 1.0);
        // On the port's own background it stays itself.
        assert_eq!(bgport(fill, pbg, pbg), Rgb::from_u32(0x1f2335));
        // On another canvas its L offset follows the canvas.
        let on = bgport(fill, Rgb::from_u32(0x222436), pbg);
        let want = l_of(Rgb::from_u32(0x1f2335)) - l_of(pbg);
        let got = l_of(on) - l_of(Rgb::from_u32(0x222436));
        assert!((got - want).abs() < 0.005, "offset {got} for {want}");
        // Translucent: flattened over the canvas.
        let half = Rgba::new(255.0, 255.0, 255.0, 0.5);
        assert_eq!(bgport(half, Rgb(0, 0, 0), pbg), Rgb(128, 128, 128));
    }

    #[test]
    fn theme_id_is_fnv1a_64() {
        // FNV-1a 64 of the 106 bytes (35 zero colors, then the kind byte 0)
        // as an independent loop computes it.
        let mut h: u64 = 0xcbf2_9ce4_8422_2325;
        for _ in 0..106 {
            h = (h ^ 0).wrapping_mul(0x100_0000_01b3);
        }
        assert_eq!(theme_id(&[Rgb(0, 0, 0); TOKENS], Kind::Dark), h);
        assert_ne!(theme_id(&[Rgb(0, 0, 0); TOKENS], Kind::Light), h);
    }
}
