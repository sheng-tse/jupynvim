//! VS Code's color registry (1.139.1): the defaults of the color ids that
//! rendered markdown and notebooks use, per theme type, and the resolution
//! rule of ColorThemeData.getColor: a color the theme defines wins, else the
//! registry default for the theme's type, whose references resolve against
//! the same theme. Checked against the live values VS Code gives a markdown
//! preview in 25 themes (tests/palette_registry.rs).

use super::color::{parse, quantize, vs_transparent, Rgba};

/// VS Code's theme types.
#[derive(Copy, Clone, PartialEq, Eq, Debug)]
pub enum ThemeType {
    Dark,
    Light,
    HcDark,
    HcLight,
}

impl ThemeType {
    /// From the names `dark`, `light`, `hcDark` and `hcLight`.
    pub fn from_name(s: &str) -> Option<ThemeType> {
        match s {
            "dark" => Some(ThemeType::Dark),
            "light" => Some(ThemeType::Light),
            "hcDark" => Some(ThemeType::HcDark),
            "hcLight" => Some(ThemeType::HcLight),
            _ => None,
        }
    }
}

/// Whether the colors are drawn on a dark or a light background (Neovim's
/// `background`).
#[derive(Copy, Clone, PartialEq, Eq, Debug, Hash)]
pub enum Kind {
    Dark,
    Light,
}

impl Kind {
    pub fn theme_type(self) -> ThemeType {
        match self {
            Kind::Dark => ThemeType::Dark,
            Kind::Light => ThemeType::Light,
        }
    }
}

/// A registry default.
enum Def {
    /// A color, `#rrggbb` or `#rrggbbaa`.
    Hex(&'static str),
    /// Another color id, resolved against the same theme.
    Ref(&'static str),
    /// A default with its alpha scaled (VS Code's `transparent`).
    Transparent(&'static Def, f64),
    /// No default for this type.
    Absent,
}

use Def::{Absent, Hex, Ref, Transparent};

/// An id's defaults per theme type; one default for every type is written
/// four times.
struct Entry {
    id: &'static str,
    dark: Def,
    light: Def,
    hc_dark: Def,
    hc_light: Def,
}

static REG: [Entry; 26] = [
    // baseColors.ts
    Entry {
        id: "foreground",
        dark: Hex("#CCCCCC"),
        light: Hex("#616161"),
        hc_dark: Hex("#FFFFFF"),
        hc_light: Hex("#292929"),
    },
    Entry {
        id: "descriptionForeground",
        dark: Transparent(&Ref("foreground"), 0.7),
        light: Hex("#717171"),
        hc_dark: Transparent(&Ref("foreground"), 0.7),
        hc_light: Transparent(&Ref("foreground"), 0.7),
    },
    Entry {
        id: "focusBorder",
        dark: Hex("#007FD4"),
        light: Hex("#0090F1"),
        hc_dark: Hex("#F38518"),
        hc_light: Hex("#006BBD"),
    },
    Entry { id: "contrastBorder", dark: Absent, light: Absent, hc_dark: Hex("#6FC3DF"), hc_light: Hex("#0F4A85") },
    Entry {
        id: "textLink.foreground",
        dark: Hex("#3794FF"),
        light: Hex("#006AB1"),
        hc_dark: Hex("#21A6FF"),
        hc_light: Hex("#0F4A85"),
    },
    Entry {
        id: "textLink.activeForeground",
        dark: Hex("#3794FF"),
        light: Hex("#006AB1"),
        hc_dark: Hex("#21A6FF"),
        hc_light: Hex("#0F4A85"),
    },
    Entry {
        id: "textSeparator.foreground",
        dark: Hex("#ffffff2e"),
        light: Hex("#0000002e"),
        hc_dark: Hex("#000000"),
        hc_light: Hex("#292929"),
    },
    Entry {
        id: "textPreformat.foreground",
        dark: Hex("#D7BA7D"),
        light: Hex("#A31515"),
        hc_dark: Hex("#FFFFFF"),
        hc_light: Hex("#FFFFFF"),
    },
    Entry {
        id: "textPreformat.background",
        dark: Hex("#FFFFFF1A"),
        light: Hex("#0000001A"),
        hc_dark: Absent,
        hc_light: Hex("#09345f"),
    },
    Entry {
        id: "textPreformat.border",
        dark: Absent,
        light: Absent,
        hc_dark: Ref("contrastBorder"),
        hc_light: Absent,
    },
    Entry {
        id: "textBlockQuote.background",
        dark: Hex("#222222"),
        light: Hex("#f2f2f2"),
        hc_dark: Absent,
        hc_light: Hex("#F2F2F2"),
    },
    Entry {
        id: "textBlockQuote.border",
        dark: Hex("#007acc80"),
        light: Hex("#007acc80"),
        hc_dark: Hex("#FFFFFF"),
        hc_light: Hex("#292929"),
    },
    Entry {
        id: "textCodeBlock.background",
        dark: Hex("#0a0a0a66"),
        light: Hex("#dcdcdc66"),
        hc_dark: Hex("#000000"),
        hc_light: Hex("#F2F2F2"),
    },
    // editorColors.ts
    Entry {
        id: "editor.background",
        dark: Hex("#1E1E1E"),
        light: Hex("#ffffff"),
        hc_dark: Hex("#000000"),
        hc_light: Hex("#FFFFFF"),
    },
    Entry {
        id: "editor.foreground",
        dark: Hex("#BBBBBB"),
        light: Hex("#333333"),
        hc_dark: Hex("#FFFFFF"),
        hc_light: Ref("foreground"),
    },
    Entry {
        id: "widget.border",
        dark: Absent,
        light: Absent,
        hc_dark: Ref("contrastBorder"),
        hc_light: Ref("contrastBorder"),
    },
    // workbench/common/theme.ts
    Entry {
        id: "editorPane.background",
        dark: Ref("editor.background"),
        light: Ref("editor.background"),
        hc_dark: Ref("editor.background"),
        hc_light: Ref("editor.background"),
    },
    Entry {
        id: "sideBar.background",
        dark: Hex("#252526"),
        light: Hex("#F3F3F3"),
        hc_dark: Hex("#000000"),
        hc_light: Hex("#FFFFFF"),
    },
    Entry {
        id: "panel.border",
        dark: Transparent(&Hex("#808080"), 0.35),
        light: Transparent(&Hex("#808080"), 0.35),
        hc_dark: Ref("contrastBorder"),
        hc_light: Ref("contrastBorder"),
    },
    // listColors.ts
    Entry {
        id: "list.inactiveSelectionBackground",
        dark: Hex("#37373D"),
        light: Hex("#E4E6F1"),
        hc_dark: Absent,
        hc_light: Transparent(&Hex("#0F4A85"), 0.1),
    },
    // notebookEditorWidget.ts
    Entry {
        id: "notebook.editorBackground",
        dark: Ref("editorPane.background"),
        light: Ref("editorPane.background"),
        hc_dark: Absent,
        hc_light: Absent,
    },
    Entry {
        id: "notebook.cellEditorBackground",
        dark: Ref("sideBar.background"),
        light: Ref("sideBar.background"),
        hc_dark: Absent,
        hc_light: Absent,
    },
    Entry {
        id: "notebook.selectedCellBackground",
        dark: Ref("list.inactiveSelectionBackground"),
        light: Ref("list.inactiveSelectionBackground"),
        hc_dark: Absent,
        hc_light: Absent,
    },
    Entry {
        id: "notebook.focusedCellBorder",
        dark: Ref("focusBorder"),
        light: Ref("focusBorder"),
        hc_dark: Ref("focusBorder"),
        hc_light: Ref("focusBorder"),
    },
    Entry {
        id: "notebook.cellBorderColor",
        dark: Transparent(&Ref("list.inactiveSelectionBackground"), 1.0),
        light: Transparent(&Ref("list.inactiveSelectionBackground"), 1.0),
        hc_dark: Ref("panel.border"),
        hc_light: Ref("panel.border"),
    },
    Entry {
        id: "notebook.symbolHighlightBackground",
        dark: Hex("#ffffff0b"),
        light: Hex("#fdff0033"),
        hc_dark: Absent,
        hc_light: Absent,
    },
];

impl Entry {
    fn def(&self, ty: ThemeType) -> &Def {
        match ty {
            ThemeType::Dark => &self.dark,
            ThemeType::Light => &self.light,
            ThemeType::HcDark => &self.hc_dark,
            ThemeType::HcLight => &self.hc_light,
        }
    }
}

/// The ids the registry knows, in its order.
pub fn ids() -> impl Iterator<Item = &'static str> {
    REG.iter().map(|e| e.id)
}

fn resolve(d: &Def, theme: &dyn Fn(&str) -> Option<Rgba>, ty: ThemeType) -> Option<Rgba> {
    match d {
        Absent => None,
        Hex(s) => parse(s),
        Ref(id) => get_color(id, theme, ty),
        Transparent(inner, f) => resolve(inner, theme, ty).map(|c| vs_transparent(c, *f)),
    }
}

/// The color VS Code uses for `id` in a theme of type `ty` whose own colors
/// `theme` gives: the theme's color, else the registry default (references
/// resolved against the same theme), else none.
pub fn get_color(id: &str, theme: &dyn Fn(&str) -> Option<Rgba>, ty: ThemeType) -> Option<Rgba> {
    if let Some(c) = theme(id) {
        return Some(c);
    }
    let e = REG.iter().find(|e| e.id == id)?;
    resolve(e.def(ty), theme, ty)
}

/// The registry default of `id` for a dark or light theme that defines no
/// colors. An id with no default for the kind is fully transparent, so it
/// flattens to whatever is underneath.
pub fn default_for(id: &str, kind: Kind) -> Rgba {
    get_color(id, &|_| None, kind.theme_type()).unwrap_or(Rgba::new(0.0, 0.0, 0.0, 0.0))
}

/// The text VS Code's Color.toString() gives: `#rrggbb` when opaque, else
/// `rgba(r, g, b, a)` with the channels rounded (ties to even) and the
/// alpha rounded to two decimals, trailing zeros dropped.
pub fn css(c: Option<Rgba>) -> Option<String> {
    let c = c?;
    if c.a >= 1.0 {
        return Some(quantize(c).hex());
    }
    // Two decimals rounded from the exact value (ties to even), then as
    // `%g` prints them: no trailing zeros, no trailing point.
    let a = format!("{:.2}", c.a);
    let a = a.trim_end_matches('0').trim_end_matches('.');
    Some(format!(
        "rgba({}, {}, {}, {})",
        c.r.round_ties_even() as i64,
        c.g.round_ties_even() as i64,
        c.b.round_ties_even() as i64,
        a
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::palette::color::parse;

    fn hex(s: &str) -> Rgba {
        parse(s).unwrap_or_else(|| panic!("not a color: {s}"))
    }

    /// The registry defaults the palette formulas use, for both kinds.
    #[test]
    fn default_for_the_ids_the_formulas_use() {
        let want = [
            ("editor.background", "#1E1E1E", "#ffffff"),
            ("editor.foreground", "#BBBBBB", "#333333"),
            ("textCodeBlock.background", "#0a0a0a66", "#dcdcdc66"),
            ("textPreformat.background", "#FFFFFF1A", "#0000001A"),
            ("textSeparator.foreground", "#ffffff2e", "#0000002e"),
            ("focusBorder", "#007FD4", "#0090F1"),
            ("textLink.foreground", "#3794FF", "#006AB1"),
            ("textPreformat.foreground", "#D7BA7D", "#A31515"),
            ("list.inactiveSelectionBackground", "#37373D", "#E4E6F1"),
        ];
        for (id, dark, light) in want {
            assert_eq!(default_for(id, Kind::Dark), hex(dark), "{id} dark");
            assert_eq!(default_for(id, Kind::Light), hex(light), "{id} light");
        }
        // no default for the kind: fully transparent, so it flattens to what is underneath
        assert_eq!(default_for("contrastBorder", Kind::Dark).a, 0.0);
        assert_eq!(default_for("no.such.color", Kind::Light).a, 0.0);
    }

    #[test]
    fn get_color_resolves_references_and_transparency() {
        let none = |_: &str| -> Option<Rgba> { None };
        // descriptionForeground dark is foreground at 70%
        let want = Some(Rgba::new(204.0, 204.0, 204.0, 0.7));
        assert_eq!(get_color("descriptionForeground", &none, ThemeType::Dark), want);
        assert_eq!(get_color("descriptionForeground", &none, ThemeType::Light), Some(hex("#717171")));
        // a theme's own color wins, and references resolve against the theme
        let theme = |id: &str| -> Option<Rgba> { (id == "foreground").then(|| hex("#102030")) };
        assert_eq!(get_color("foreground", &theme, ThemeType::Dark), Some(hex("#102030")));
        let want = Some(Rgba::new(16.0, 32.0, 48.0, 0.7));
        assert_eq!(get_color("descriptionForeground", &theme, ThemeType::Dark), want);
        // a chain: notebook.editorBackground -> editorPane.background -> editor.background
        assert_eq!(get_color("notebook.editorBackground", &none, ThemeType::Light), Some(hex("#ffffff")));
        let theme = |id: &str| -> Option<Rgba> { (id == "editor.background").then(|| hex("#222436")) };
        assert_eq!(get_color("notebook.editorBackground", &theme, ThemeType::Dark), Some(hex("#222436")));
        // no default for the type, and an unknown id
        assert_eq!(get_color("contrastBorder", &none, ThemeType::Dark), None);
        assert_eq!(get_color("contrastBorder", &none, ThemeType::HcDark), Some(hex("#6FC3DF")));
        assert_eq!(get_color("no.such.color", &none, ThemeType::Dark), None);
        assert_eq!(get_color("panel.border", &none, ThemeType::HcLight), Some(hex("#0F4A85")));
        assert_eq!(get_color("panel.border", &none, ThemeType::Light), Some(Rgba::new(128.0, 128.0, 128.0, 0.35)));
    }

    #[test]
    fn the_registry_has_its_26_ids_once_each() {
        let mut v: Vec<&str> = ids().collect();
        assert_eq!(v.len(), 26);
        v.sort_unstable();
        v.dedup();
        assert_eq!(v.len(), 26);
        assert_eq!(ThemeType::from_name("dark"), Some(ThemeType::Dark));
        assert_eq!(ThemeType::from_name("light"), Some(ThemeType::Light));
        assert_eq!(ThemeType::from_name("hcDark"), Some(ThemeType::HcDark));
        assert_eq!(ThemeType::from_name("hcLight"), Some(ThemeType::HcLight));
        assert_eq!(ThemeType::from_name("vs-dark"), None);
        assert_eq!(Kind::Dark.theme_type(), ThemeType::Dark);
        assert_eq!(Kind::Light.theme_type(), ThemeType::Light);
    }

    /// The format of VS Code's Color.toString(): `#rrggbb` when opaque,
    /// else `rgba(r, g, b, a)` with the alpha to two decimals at most.
    #[test]
    fn css_formats_as_vs_code_does() {
        assert_eq!(css(None), None);
        assert_eq!(css(Some(hex("#C0CAF5"))), Some("#c0caf5".to_string()));
        assert_eq!(css(Some(hex("#ffffff2e"))), Some("rgba(255, 255, 255, 0.18)".to_string()));
        assert_eq!(css(Some(Rgba::new(1.0, 2.0, 3.0, 0.7))), Some("rgba(1, 2, 3, 0.7)".to_string()));
        assert_eq!(css(Some(Rgba::new(10.5, 11.5, 254.5, 0.125))), Some("rgba(10, 12, 254, 0.12)".to_string()));
        assert_eq!(css(Some(Rgba::new(1.0, 2.0, 3.0, 0.375))), Some("rgba(1, 2, 3, 0.38)".to_string()));
        assert_eq!(css(Some(Rgba::new(1.0, 2.0, 3.0, 0.996))), Some("rgba(1, 2, 3, 1)".to_string()));
        assert_eq!(css(Some(Rgba::new(1.0, 2.0, 3.0, 0.0))), Some("rgba(1, 2, 3, 0)".to_string()));
        assert_eq!(css(Some(Rgba::new(1.0, 2.0, 3.0, 0.05))), Some("rgba(1, 2, 3, 0.05)".to_string()));
        assert_eq!(css(Some(Rgba::new(253.0, 255.0, 0.0, 0.2))), Some("rgba(253, 255, 0, 0.2)".to_string()));
        assert_eq!(css(Some(Rgba::new(127.5, 0.0, 255.0, 1.0))), Some("#8000ff".to_string()));
    }
}
