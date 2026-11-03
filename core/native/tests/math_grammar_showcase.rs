//! The 100 showcase rows the math grammar owns: 82 `MB-*` (one per battery case), 15 `MG-*` (the places
//! where the renderers disagree and the grammar settles the reading), `MK-15` (the settled edge cases),
//! `MK-16` (code, HTML and leftover dollars never read as math, and AMS numbering, in the fixture sections
//! that mix markdown and math and in documents of its own) and `MD-18` (TeX that reaches MathJax
//! unchanged). Every row runs its own comparison against the reference grammar's output, which the
//! committed golden case files hold (`tests/mathgrammar/golden/`), and prints `showcase <ID> ok` when it
//! passes. No row needs a reference image: they are conformance and text comparisons.
//!
//! Every expected literal below was printed by the reference
//! (`node tests/mathgrammar/gen_cases.mjs json [--doc] < source`), never written from reasoning about the
//! grammar. A row whose comparison spans two tests (`MG-04`, `MG-15`) prints its line when both have passed.
//! A test prints its lines together after a line feed, so each starts a line even when libtest has just
//! written `test <name> ... ` (one test thread): `grep -c '^showcase .* ok$'` counts the rows that passed.
//!
//! `field_problems` is the comparison every row shares: the Rust grammar against the golden document,
//! for the text, and for the chosen maths their display, block, kind, tex, raw, prepared text, KaTeX text and
//! MathJax text (the golden `mathjax` field: the prepared text but for MathJax's own starred forms of a numbered
//! `eqnarray` and `multline`, deviation D6). Each problem it reports starts with the row id.

#[path = "support/casefile.rs"]
mod casefile;

use casefile::{esc, golden, CaseMath, Doc};
use jupynvim::mathgrammar::{
    extract_document, extract_math, normalize_newlines, prepare_document, Engine, Extracted, Math,
    PreparedDoc,
};
use std::collections::HashSet;
use std::ops::Range;
use std::sync::Mutex;

/// `(kind, display, block, tex)` of one math.
type Span = (&'static str, bool, bool, &'static str);
/// A battery row: its id, the battery case, and the stated `(display, tex)` of each math.
type BatteryRow = (&'static str, &'static str, &'static [(bool, &'static str)]);
/// A battery or additions case with the spans it must hold.
type CaseSpans = (&'static str, &'static [Span]);
/// A row of the disagreement table: its id and the cases it covers.
type DisagreementRow = (&'static str, &'static [CaseSpans]);
/// An addition: its name, the text the reference extracts from it and its spans.
type Addition = (&'static str, &'static str, &'static [Span]);
/// One math as the reference gives it: `(source, display, block, kind, tex, raw, prepared, katex)`.
type RefMath = (
    usize,
    bool,
    bool,
    &'static str,
    &'static str,
    &'static str,
    &'static str,
    &'static str,
);
/// A document written out here with the reference's output: name, sources, the text of each source, maths.
type RefDoc = (
    &'static str,
    &'static [&'static str],
    &'static [&'static str],
    &'static [RefMath],
);

// ---- the expected values, printed by the reference ----

/// The 82 battery rows, one per case of the battery: id, case, and the stated result as `(display, tex)` per math.
#[rustfmt::skip]
const BATTERY_ROWS: &[BatteryRow] = &[
    ("MB-open-space", "open-space", &[(false, "x")]),
    ("MB-space-after-open", "space-after-open", &[]),
    ("MB-space-before-close", "space-before-close", &[]),
    ("MB-word-before-open", "word-before-open", &[(false, "x")]),
    ("MB-word-after-close", "word-after-close", &[(false, "x")]),
    ("MB-digit-before-open", "digit-before-open", &[(false, "x")]),
    ("MB-digit-after-close", "digit-after-close", &[]),
    ("MB-paren", "paren", &[(false, "x")]),
    ("MB-bracket", "bracket", &[(false, "x")]),
    ("MB-dquote", "dquote", &[(false, "x")]),
    ("MB-squote", "squote", &[(false, "x")]),
    ("MB-brace", "brace", &[(false, "x")]),
    ("MB-hyphen", "hyphen", &[(false, "x")]),
    ("MB-slash", "slash", &[(false, "x")]),
    ("MB-colon-after", "colon-after", &[(false, "x")]),
    ("MB-period-after", "period-after", &[(false, "x")]),
    ("MB-comma-after", "comma-after", &[(false, "x")]),
    ("MB-currency-two", "currency-two", &[]),
    ("MB-currency-close-digit", "currency-close-digit", &[(false, "5 to 10")]),
    ("MB-currency-doc", "currency-doc", &[(false, "100/2")]),
    ("MB-escaped-open", "escaped-open", &[]),
    ("MB-escaped-close", "escaped-close", &[]),
    ("MB-escaped-inside", "escaped-inside", &[(false, "x \\$ y")]),
    ("MB-escaped-backslash-then-math", "escaped-backslash-then-math", &[(false, "x")]),
    ("MB-dbl-inline-mid", "dbl-inline-mid", &[(true, "x")]),
    ("MB-dbl-space-after-open", "dbl-space-after-open", &[(true, "x")]),
    ("MB-dbl-alone", "dbl-alone", &[(true, "x")]),
    ("MB-dbl-alone-spaces", "dbl-alone-spaces", &[(true, "x")]),
    ("MB-dbl-open-single-close", "dbl-open-single-close", &[(false, "$x")]),
    ("MB-adjacent", "adjacent", &[(false, "a"), (false, "b")]),
    ("MB-three", "three", &[(false, "a"), (false, "c")]),
    ("MB-emph-star-inside", "emph-star-inside", &[(false, "a*b*c")]),
    ("MB-emph-under-inside", "emph-under-inside", &[(false, "a_b_c")]),
    ("MB-two-subscripts", "two-subscripts", &[(false, "x_1"), (false, "y_1")]),
    ("MB-strong-around", "strong-around", &[(false, "x")]),
    ("MB-em-around", "em-around", &[(false, "x")]),
    ("MB-link-around", "link-around", &[(false, "x")]),
    ("MB-link-inside", "link-inside", &[(false, "[a](b)")]),
    ("MB-autolink-inside", "autolink-inside", &[(false, "<https://e.com>")]),
    ("MB-code-inside", "code-inside", &[(false, "`a`b")]),
    ("MB-backtick-form", "backtick-form", &[(false, "a \\\\ b")]),
    ("MB-backtick-unclosed", "backtick-unclosed", &[]),
    ("MB-strike-inside", "strike-inside", &[(false, "a~~b~~c")]),
    ("MB-emoji-inside", "emoji-inside", &[(false, ":smile:")]),
    ("MB-lt-tight", "lt-tight", &[(false, "a<b")]),
    ("MB-lt-space", "lt-space", &[(false, "a < b")]),
    ("MB-html-tag-inside", "html-tag-inside", &[(false, "a <b> c")]),
    ("MB-amp", "amp", &[(false, "a & b")]),
    ("MB-brace-escape", "brace-escape", &[(false, "\\{a\\}")]),
    ("MB-thinspace", "thinspace", &[(false, "a\\,b")]),
    ("MB-dbl-backslash-inline", "dbl-backslash-inline", &[(false, "a \\\\ b")]),
    ("MB-pipe-escape", "pipe-escape", &[(false, "\\|v\\|")]),
    ("MB-underscore-escape", "underscore-escape", &[(false, "\\_")]),
    ("MB-hash-percent", "hash-percent", &[(false, "\\#\\%")]),
    ("MB-paren-delims", "paren-delims", &[(false, "x")]),
    ("MB-bracket-delims", "bracket-delims", &[(true, "x")]),
    ("MB-dbl-paren-delims", "dbl-paren-delims", &[(false, "x")]),
    ("MB-bare-env-inline", "bare-env-inline", &[(true, "\\begin{equation}x\\end{equation}")]),
    ("MB-env-in-dollar", "env-in-dollar", &[(false, "\\begin{aligned}a&=b\\end{aligned}")]),
    ("MB-display-blank-line", "display-blank-line", &[]),
    ("MB-display-plus-line", "display-plus-line", &[(true, "a\n+ b")]),
    ("MB-display-hash-line", "display-hash-line", &[(true, "a\n# b")]),
    ("MB-display-indented-4", "display-indented-4", &[]),
    ("MB-display-in-list", "display-in-list", &[(true, "x")]),
    ("MB-display-in-quote", "display-in-quote", &[(true, "x")]),
    ("MB-display-after-text-no-blank", "display-after-text-no-blank", &[(true, "x")]),
    ("MB-display-then-text", "display-then-text", &[(true, "x")]),
    ("MB-display-dbl-backslash", "display-dbl-backslash", &[(true, "a \\\\ b")]),
    ("MB-display-thinspace", "display-thinspace", &[(true, "a\\,b")]),
    ("MB-display-two-adjacent", "display-two-adjacent", &[(true, "a"), (true, "b")]),
    ("MB-display-same-line-open", "display-same-line-open", &[(true, "a\nb")]),
    ("MB-fence-math", "fence-math", &[(true, "a \\\\ b")]),
    ("MB-fence-math-tilde", "fence-math-tilde", &[(true, "a")]),
    ("MB-fence-math-upper", "fence-math-upper", &[(true, "a")]),
    ("MB-fence-latex", "fence-latex", &[]),
    ("MB-empty-inline", "empty-inline", &[]),
    ("MB-single-space-math", "single-space-math", &[]),
    ("MB-unbalanced-brace", "unbalanced-brace", &[(false, "\\frac{1}{")]),
    ("MB-table-pipe", "table-pipe", &[(false, "|x|")]),
    ("MB-table-escaped-pipe", "table-escaped-pipe", &[(false, "\\|x\\|")]),
    ("MB-heading", "heading", &[(false, "x")]),
    ("MB-newline-inside-inline", "newline-inside-inline", &[(false, "x\ny")]),
];

/// The disagreement rows: id, then each case with the `(kind, display, block, tex)` of its maths.
#[rustfmt::skip]
const DISAGREEMENT_ROWS: &[DisagreementRow] = &[
    ("MG-01", &[
        ("space-after-open", &[]),
        ("space-before-close", &[]),
    ]),
    ("MG-02", &[
        ("bracket", &[("dollar", false, false, "x")]),
        ("dquote", &[("dollar", false, false, "x")]),
        ("hyphen", &[("dollar", false, false, "x")]),
        ("paren", &[("dollar", false, false, "x")]),
    ]),
    ("MG-03", &[
        ("word-before-open", &[("dollar", false, false, "x")]),
        ("word-after-close", &[("dollar", false, false, "x")]),
        ("digit-after-close", &[]),
        ("settled-digit-both-sides", &[]),
    ]),
    ("MG-04", &[
        ("currency-two", &[]),
        ("settled-price-decimal", &[]),
        ("settled-prices", &[]),
    ]),
    ("MG-05", &[
        ("emph-star-inside", &[("dollar", false, false, "a*b*c")]),
        ("emph-under-inside", &[("dollar", false, false, "a_b_c")]),
    ]),
    ("MG-06", &[
        ("html-tag-inside", &[("dollar", false, false, "a <b> c")]),
        ("lt-tight", &[("dollar", false, false, "a<b")]),
        ("lt-space", &[("dollar", false, false, "a < b")]),
    ]),
    ("MG-08", &[
        ("dbl-inline-mid", &[("dollars", true, false, "x")]),
    ]),
    ("MG-09", &[
        ("display-blank-line", &[]),
        ("settled-display-blank-line", &[]),
    ]),
    ("MG-10", &[
        ("display-after-text-no-blank", &[("dollars", true, true, "x")]),
        ("display-then-text", &[("dollars", true, true, "x")]),
    ]),
    ("MG-11", &[
        ("fence-math", &[("fence", true, true, "a \\\\ b")]),
        ("fence-math-tilde", &[("fence", true, true, "a")]),
        ("fence-math-upper", &[("fence", true, true, "a")]),
        ("fence-latex", &[]),
    ]),
    ("MG-13", &[
        ("dbl-paren-delims", &[("doubled", false, false, "x")]),
        ("settled-dbl-paren", &[("doubled", false, false, "a + b")]),
        ("settled-dbl-bracket", &[("doubled", true, true, "x")]),
        ("settled-dbl-bracket-lines", &[("doubled", true, true, "c + d")]),
    ]),
    ("MG-14", &[
        ("paren-delims", &[("paren", false, false, "x")]),
        ("bracket-delims", &[("bracket", true, true, "x")]),
    ]),
];

/// The reference's text for the cases whose every `$` is escaped (MG-04).
#[rustfmt::skip]
const ESCAPED_TEXTS: &[(&str, &str)] = &[
    ("currency-two", "costs \\$5 and \\$10 each"),
    ("settled-price-decimal", "It costs \\$20.50 each."),
    ("settled-prices", "\\$5 and \\$10 per item, \\$1,000 total or \\$20.50 each."),
];

/// The additions: source, text and maths exactly as the reference gives them (MK-15).
#[rustfmt::skip]
const ADDITIONS: &[Addition] = &[
    ("settled-digit-both-sides", "2\\$x\\$3", &[]),
    ("settled-price-decimal", "It costs \\$20.50 each.", &[]),
    ("settled-prices", "\\$5 and \\$10 per item, \\$1,000 total or \\$20.50 each.", &[]),
    ("settled-display-blank-line", "\\$\\$\na\n\nb\n\\$\\$", &[]),
    ("settled-dbl-paren", "ZZMTH0001ZZ", &[("doubled", false, false, "a + b")]),
    ("settled-dbl-bracket", "ZZDMTH0001ZZ", &[("doubled", true, true, "x")]),
    ("settled-dbl-bracket-lines", "ZZDMTH0001ZZ", &[("doubled", true, true, "c + d")]),
    ("settled-newcommand-R", "ZZMTH0001ZZ and ZZMTH0002ZZ", &[("dollar", false, false, "\\newcommand{\\R}{\\mathbb{R}}"), ("dollar", false, false, "\\R^n")]),
    ("settled-multline", "ZZDMTH0001ZZ", &[("dollars", true, true, "\\begin{multline}a\\\\b\\\\c\\end{multline}")]),
    ("settled-escaped-dollar-in-math", "ZZMTH0001ZZ", &[("dollar", false, false, "\\$4 + x")]),
    ("settled-escaped-dollar-text", "a \\$ b", &[]),
];

/// `bare-env-inline` (MG-12): a bare environment in a line of text is a display math that is not a block.
const BARE_ENV_INLINE: &[Span] = &[("env", true, false, "\\begin{equation}x\\end{equation}")];

/// `code-inside` (MK-16).
const CODE_INSIDE: &[Span] = &[("dollar", false, false, "`a`b")];

/// MK-16's own documents, the inputs its fixture sections lack, with the reference's output: a `$` inside a code
/// span, a fence, indented code, an HTML comment and an HTML tag (alone, and before a math), leftover dollars,
/// and AMS numbering with `\tag`, `\nonumber`, `\notag` and `\label`, and `\eqref` and `\ref` before the
/// equation they name (in one cell and from an earlier cell).
#[rustfmt::skip]
const MK16_DOCS: &[RefDoc] = &[
    ("code-span", &["`$x$`"], &["`$x$`"], &[]),
    ("fence", &["```\n$x$\n```"], &["```\n$x$\n```"], &[]),
    ("indented", &["para\n\n    $x$"], &["para\n\n    $x$"], &[]),
    ("comment", &["<!-- $x$ -->"], &["<!-- $x$ -->"], &[]),
    ("tag", &["<a title=\"$x$\">"], &["<a title=\"$x$\">"], &[]),
    ("code-span-then-math", &["`a $ b` and $y$"], &["`a $ b` and ZZMTH0001ZZ"], &[(0, false, false, "dollar", "y", "$y$", "y", "y")]),
    ("fence-then-math", &["```\n$\n```\n$y$"], &["```\n$\n```\nZZMTH0001ZZ"], &[(0, false, false, "dollar", "y", "$y$", "y", "y")]),
    ("indented-then-math", &["para\n\n    $ x\n\n$y$"], &["para\n\n    $ x\n\nZZMTH0001ZZ"], &[(0, false, false, "dollar", "y", "$y$", "y", "y")]),
    ("comment-then-math", &["<!-- $ -->$y$"], &["<!-- $ -->ZZMTH0001ZZ"], &[(0, false, false, "dollar", "y", "$y$", "y", "y")]),
    ("tag-then-math", &["<a title=\"$\">$y$"], &["<a title=\"$\">ZZMTH0001ZZ"], &[(0, false, false, "dollar", "y", "$y$", "y", "y")]),
    ("leftover-lone", &["a $ b"], &["a \\$ b"], &[]),
    ("leftover-after-math", &["$x$ costs $5"], &["ZZMTH0001ZZ costs \\$5"], &[(0, false, false, "dollar", "x", "$x$", "x", "x")]),
    ("leftover-unclosed", &["an open $x and $y$ then $"], &["an open \\$x and ZZMTH0001ZZ then \\$"], &[(0, false, false, "dollar", "y", "$y$", "y", "y")]),
    ("ams-tags-and-skips", &["$$\\begin{align}a\\tag{A}\\label{p}\\\\b\\nonumber\\\\c\\notag\\\\d\\end{align}$$ $\\ref{p}$"], &["ZZDMTH0001ZZ ZZMTH0002ZZ"], &[(0, true, false, "dollars", "\\begin{align}a\\tag{A}\\label{p}\\\\b\\nonumber\\\\c\\notag\\\\d\\end{align}", "$$\\begin{align}a\\tag{A}\\label{p}\\\\b\\nonumber\\\\c\\notag\\\\d\\end{align}$$", "\\begin{align*}a\\tag{A} \\\\b \\\\c \\\\d \\tag{1}\\end{align*}", "\\begin{align*}a\\tag{A} \\\\b \\\\c \\\\d \\tag{1}\\end{align*}"), (0, false, false, "dollar", "\\ref{p}", "$\\ref{p}$", "\\text{A}", "\\text{A}")]),
    ("ams-nonumber-label", &["$$\\begin{align}a\\nonumber\\label{n}\\\\b\\end{align}$$ $\\ref{n}$ $\\eqref{n}$"], &["ZZDMTH0001ZZ ZZMTH0002ZZ ZZMTH0003ZZ"], &[(0, true, false, "dollars", "\\begin{align}a\\nonumber\\label{n}\\\\b\\end{align}", "$$\\begin{align}a\\nonumber\\label{n}\\\\b\\end{align}$$", "\\begin{align*}a \\\\b \\tag{1}\\end{align*}", "\\begin{align*}a \\\\b \\tag{1}\\end{align*}"), (0, false, false, "dollar", "\\ref{n}", "$\\ref{n}$", "\\text{??}", "\\text{??}"), (0, false, false, "dollar", "\\eqref{n}", "$\\eqref{n}$", "\\text{(??)}", "\\text{(??)}")]),
    ("ams-forward-eqref", &["$\\eqref{a}$ then $$\\begin{equation}x\\label{a}\\end{equation}$$"], &["ZZMTH0001ZZ then ZZDMTH0002ZZ"], &[(0, false, false, "dollar", "\\eqref{a}", "$\\eqref{a}$", "\\text{(1)}", "\\text{(1)}"), (0, true, false, "dollars", "\\begin{equation}x\\label{a}\\end{equation}", "$$\\begin{equation}x\\label{a}\\end{equation}$$", "\\begin{equation*}x \\tag{1}\\end{equation*}", "\\begin{equation*}x \\tag{1}\\end{equation*}")]),
    ("ams-forward-ref-cells", &["See $\\ref{a}$ and $\\eqref{a}$.", "$$\\begin{equation}x\\label{a}\\end{equation}$$"], &["See ZZMTH0001ZZ and ZZMTH0002ZZ.", "ZZDMTH0001ZZ"], &[(0, false, false, "dollar", "\\ref{a}", "$\\ref{a}$", "\\text{1}", "\\text{1}"), (0, false, false, "dollar", "\\eqref{a}", "$\\eqref{a}$", "\\text{(1)}", "\\text{(1)}"), (1, true, true, "dollars", "\\begin{equation}x\\label{a}\\end{equation}", "$$\\begin{equation}x\\label{a}\\end{equation}$$", "\\begin{equation*}x \\tag{1}\\end{equation*}", "\\begin{equation*}x \\tag{1}\\end{equation*}")]),
];

/// The line of the fixture's code section whose fence holds a `$`: never read as math (MK-16).
const CODE_FENCE_DOLLAR: &str = "for f in *.ipynb; do echo \"$f\"; done";

/// The battery cases whose escapes stay inside the math (MG-07) and the TeX between their `$`: one inline math
/// each, whose TeX, raw text and MathJax text keep every backslash.
const KEPT_ESCAPES: &[(&str, &str)] = &[
    ("brace-escape", "\\{a\\}"),
    ("thinspace", "a\\,b"),
    ("pipe-escape", "\\|v\\|"),
    ("underscore-escape", "\\_"),
    ("dbl-backslash-inline", "a \\\\ b"),
];

/// The battery cases whose TeX reaches MathJax unchanged (MD-18) and the TeX between their delimiters.
const UNTOUCHED_CASES: &[(&str, &str)] = &[("brace-escape", "\\{a\\}"), ("thinspace", "a\\,b")];

/// The TeX of the maths of the `Escapes inside math:` line of the math-conflicts section (MD-18).
const ESCAPES_LINE: &[&str] = &[
    "\\{a, b\\}",
    "a \\, b",
    "a\\;b",
    "\\|v\\|",
    "a \\\\ b",
    "\\#\\%\\&\\_",
    "\\$",
];

/// The two maths of `gauss.md` as `(raw, tex)`, copied from the golden bytes (MD-18): the display holds `\,`
/// (GitHub's MathJax shows the thin space, not a comma), and the inline `$x^2 + y_1$` is plain.
const GAUSS_MATHS: &[(&str, &str)] = &[
    (
        "$$\n\\int_{-\\infty}^{\\infty} e^{-x^2}\\,dx = \\sqrt{\\pi}\n$$",
        "\\int_{-\\infty}^{\\infty} e^{-x^2}\\,dx = \\sqrt{\\pi}",
    ),
    ("$x^2 + y_1$", "x^2 + y_1"),
];

/// The `Currency:` line of the math-inline section as the reference extracts it, without its line feed (MG-04).
const CURRENCY_TEXT: &str =
    "Currency: it costs \\$5 and \\$10 per item, \\$1,000 total or \\$20.50 each.";

/// `settled-multline` after preparation and in the KaTeX text: KaTeX draws `multline` as `gather*` (MK-15); each
/// row follows its `\\` directly, as in the source (deviation D10).
const MULTLINE_GATHER: &str = "\\begin{gather*}a \\\\b \\\\c \\tag{1}\\end{gather*}";
/// `settled-multline` in the MathJax text: MathJax draws its own `multline*` (deviation D6).
const MULTLINE_MATHJAX: &str = "\\begin{multline*}a \\\\b \\\\c \\tag{1}\\end{multline*}";
/// `settled-newcommand-R`: the first math for KaTeX and for MathJax (MG-15).
const NEWCOMMAND_KATEX: &str = "\\renewcommand{\\R}{\\mathbb{R}}";
const NEWCOMMAND_MATHJAX: &str = "\\newcommand{\\R}{\\mathbb{R}}";

// ---- what a row reports ----

/// The rows that finished in this process and how many of their parts did.
static FINISHED: Mutex<Vec<(String, usize)>> = Mutex::new(Vec::new());

/// The tests that must pass before a row prints its line.
fn parts(id: &str) -> usize {
    match id {
        "MG-04" | "MG-15" => 2,
        _ => 1,
    }
}

/// Records that one part of row `id` passed; true when that was its last part, so its line is due.
fn row_ok(id: &str) -> bool {
    let mut done = FINISHED.lock().unwrap_or_else(|e| e.into_inner());
    let n = match done.iter_mut().find(|(i, _)| i == id) {
        Some(entry) => {
            entry.1 += 1;
            entry.1
        }
        None => {
            done.push((id.to_string(), 1));
            1
        }
    };
    n == parts(id)
}

/// The rows a test checked: the ones without a problem and every problem found.
#[derive(Default)]
struct Report {
    ok: Vec<String>,
    problems: Vec<String>,
}

impl Report {
    /// Records one row. Every problem must start with the row id, so a failure names the row it belongs to.
    fn row(&mut self, id: &str, problems: Vec<String>) {
        let prefix = format!("{id}: ");
        assert!(
            problems.iter().all(|p| p.starts_with(&prefix)),
            "a problem of {id} does not start with the row id: {problems:?}"
        );
        if problems.is_empty() {
            self.ok.push(id.to_string());
        } else {
            self.problems.extend(problems);
        }
    }

    /// Whether some problem belongs to row `id`.
    fn names(&self, id: &str) -> bool {
        let prefix = format!("{id}: ");
        self.problems.iter().any(|p| p.starts_with(&prefix))
    }

    /// Prints one line per row that passed and fails with every problem found. The lines go out in one write
    /// after a line feed: with one test thread libtest has just written `test <name> ... ` without one.
    fn finish(self) {
        let lines: String = self
            .ok
            .iter()
            .filter(|id| row_ok(id))
            .map(|id| format!("showcase {id} ok\n"))
            .collect();
        if !lines.is_empty() {
            print!("\n{lines}");
        }
        assert!(
            self.problems.is_empty(),
            "{} problems:\n{}",
            self.problems.len(),
            self.problems.join("\n")
        );
    }
}

// ---- messages ----

/// `s` cut to a window of about 160 bytes around byte `first`, escaped.
fn window(s: &str, first: usize) -> String {
    let mut a = first.saturating_sub(40).min(s.len());
    while !s.is_char_boundary(a) {
        a -= 1;
    }
    let mut b = (first + 120).min(s.len());
    while !s.is_char_boundary(b) {
        b += 1;
    }
    let lead = if a > 0 { "..." } else { "" };
    let tail = if b < s.len() { "..." } else { "" };
    format!("{lead}{}{tail}", esc(&s[a..b]))
}

/// A problem of row `row`: the field of document `doc` that differs, with both values around the first difference.
fn problem(row: &str, doc: &str, field: &str, want: &str, got: &str) -> String {
    let first = want
        .bytes()
        .zip(got.bytes())
        .position(|(a, b)| a != b)
        .unwrap_or(want.len().min(got.len()));
    format!(
        "{row}: {doc} {field}: want {} got {}",
        window(want, first),
        window(got, first)
    )
}

fn find<'a>(docs: &'a [Doc], name: &str) -> Option<&'a Doc> {
    docs.iter().find(|d| d.name == name)
}

// ---- running the Rust grammar over a golden document ----

/// The Rust grammar over a document's sources, prepared for both engines.
struct Run {
    ex: Vec<Extracted>,
    katex: PreparedDoc,
    mathjax: PreparedDoc,
}

fn run(doc: &Doc) -> Run {
    let srcs: Vec<&str> = doc.sources.iter().map(String::as_str).collect();
    let ex = extract_document(&srcs);
    let katex = prepare_document(&ex, Engine::Katex);
    let mathjax = prepare_document(&ex, Engine::MathJax);
    Run { ex, katex, mathjax }
}

impl Run {
    /// Every math of the document in order, with the index of its source.
    fn flat(&self) -> Vec<(usize, &Math)> {
        self.ex
            .iter()
            .enumerate()
            .flat_map(|(s, x)| x.maths.iter().map(move |m| (s, m)))
            .collect()
    }
}

/// How much of the extracted text a row compares.
#[derive(Clone, Copy)]
enum Text {
    /// The text of every source.
    Whole,
    /// The text of one section of a markdown file, from its `<!-- section: .. -->` line to the next one. The
    /// marker lines are not touched by the grammar, so the section starts at the same place in both texts.
    Section(usize),
}

/// The byte offsets of the lines that start a section.
fn section_starts(s: &str) -> Vec<usize> {
    let mut starts = Vec::new();
    let mut at = 0;
    for line in s.split_inclusive('\n') {
        if line.starts_with("<!-- section: ") {
            starts.push(at);
        }
        at += line.len();
    }
    starts
}

/// Section `i` of a text, marker line included.
fn section(s: &str, i: usize) -> Option<&str> {
    let starts = section_starts(s);
    let a = *starts.get(i)?;
    let b = starts.get(i + 1).copied().unwrap_or(s.len());
    s.get(a..b)
}

/// The indexes (among the maths of one source) of the maths whose placeholder replaces source bytes in `bytes`.
fn maths_within(ex: &Extracted, bytes: Range<usize>) -> Range<usize> {
    let hit: Vec<usize> = ex
        .edits
        .iter()
        .filter(|e| bytes.contains(&e.src.start))
        .filter_map(|e| e.math)
        .collect();
    match (hit.iter().min(), hit.iter().max()) {
        (Some(&a), Some(&b)) => a..b + 1,
        _ => 0..0,
    }
}

/// The comparison every row shares: the Rust grammar against the golden document `doc`. The text of the
/// document (`text`), and for the maths `maths` (indexes into the document's flat list) their source, display,
/// block, kind, tex and raw, the prepared text, the KaTeX text, and the MathJax text, which is the prepared text
/// but for MathJax's own starred forms of a numbered `eqnarray` and `multline` (the golden `mathjax` field). The
/// numbers and references of `prepared` and the macro rule of the KaTeX text depend on every math before, so the
/// whole document is always prepared and only the chosen maths are compared.
fn field_problems(row: &str, doc: &Doc, maths: Range<usize>, text: Text) -> Vec<String> {
    let r = run(doc);
    let n = doc.name.as_str();
    let mut out = Vec::new();
    if r.ex.len() != doc.sources.len() {
        out.push(problem(
            row,
            n,
            "sources",
            &doc.sources.len().to_string(),
            &r.ex.len().to_string(),
        ));
        return out;
    }
    for (s, x) in r.ex.iter().enumerate() {
        match text {
            Text::Whole => {
                if x.text != doc.texts[s] {
                    out.push(problem(
                        row,
                        n,
                        &format!("text[{s}]"),
                        &doc.texts[s],
                        &x.text,
                    ));
                }
            }
            Text::Section(i) => match (section(&doc.texts[s], i), section(&x.text, i)) {
                (Some(want), Some(got)) => {
                    if want != got {
                        out.push(problem(row, n, &format!("text of section {i}"), want, got));
                    }
                }
                _ => out.push(format!(
                    "{row}: {n}: the text of source {s} has no marker for section {i}"
                )),
            },
        }
    }
    let flat = r.flat();
    if flat.len() != doc.maths.len() {
        out.push(problem(
            row,
            n,
            "maths.len",
            &doc.maths.len().to_string(),
            &flat.len().to_string(),
        ));
        return out;
    }
    if maths.end > flat.len() {
        out.push(format!(
            "{row}: {n}: maths {maths:?} lie outside the {} maths of the document",
            flat.len()
        ));
        return out;
    }
    for g in maths {
        let (s, m) = flat[g];
        let want = &doc.maths[g];
        let fields: [(&str, String, String); 6] = [
            ("source", want.source.to_string(), s.to_string()),
            ("display", want.display.to_string(), m.display.to_string()),
            ("block", want.block.to_string(), m.block.to_string()),
            ("kind", want.kind.clone(), m.kind.as_str().to_string()),
            ("tex", want.tex.clone(), m.tex.clone()),
            ("raw", want.raw.clone(), m.raw.clone()),
        ];
        for (f, w, got) in fields {
            if w != got {
                out.push(problem(row, n, &format!("maths[{g}].{f}"), &w, &got));
            }
        }
        let prepared = r.katex.prepared.get(g).map_or("", String::as_str);
        if prepared != want.prepared {
            out.push(problem(
                row,
                n,
                &format!("prepared[{g}]"),
                &want.prepared,
                prepared,
            ));
        }
        let katex = r.katex.engine.get(g).map_or("", |e| e.tex.as_str());
        if katex != want.katex {
            out.push(problem(row, n, &format!("katex[{g}]"), &want.katex, katex));
        }
        let mathjax = r.mathjax.engine.get(g).map_or("", |e| e.tex.as_str());
        if mathjax != want.mathjax {
            out.push(problem(
                row,
                n,
                &format!("mathjax[{g}]"),
                &want.mathjax,
                mathjax,
            ));
        }
    }
    out
}

/// The maths of `src` as `(kind, display, block, tex)` against the stated ones.
fn span_problems(row: &str, name: &str, src: &str, want: &[Span]) -> Vec<String> {
    let got: Vec<(String, bool, bool, String)> = extract_math(src)
        .maths
        .iter()
        .map(|m| {
            (
                m.kind.as_str().to_string(),
                m.display,
                m.block,
                m.tex.clone(),
            )
        })
        .collect();
    let want: Vec<(String, bool, bool, String)> = want
        .iter()
        .map(|&(k, d, b, t)| (k.to_string(), d, b, t.to_string()))
        .collect();
    if got == want {
        Vec::new()
    } else {
        vec![format!("{row}: {name}: spans: want {want:?} got {got:?}")]
    }
}

/// A source with no math whose every `$` is escaped: the text is the stated one, the source holds no math and
/// each `$` is one edit with no math that turns the one byte `$` into `\$`.
fn escape_problems(row: &str, name: &str, src: &str, want_text: &str) -> Vec<String> {
    let norm = normalize_newlines(src);
    let ex = extract_math(&norm);
    let mut out = Vec::new();
    if ex.text != want_text {
        out.push(problem(row, name, "text", want_text, &ex.text));
    }
    if !ex.maths.is_empty() {
        out.push(format!("{row}: {name}: found {} maths", ex.maths.len()));
    }
    let dollars = norm.matches('$').count();
    if ex.edits.len() != dollars {
        out.push(format!(
            "{row}: {name}: {dollars} dollars but {} edits",
            ex.edits.len()
        ));
    }
    for e in &ex.edits {
        let from = norm.get(e.src.clone());
        let to = ex.text.get(e.text.clone());
        if e.math.is_some() || from != Some("$") || to != Some("\\$") {
            out.push(format!(
                "{row}: {name}: edit {e:?} turns {from:?} into {to:?}, not a `$` into `\\$`"
            ));
        }
    }
    out
}

// ---- the battery (MB rows) ----

fn battery_rows(rows: &[BatteryRow], battery: &[Doc], rep: &mut Report) {
    for &(id, case, want) in rows {
        let Some(doc) = find(battery, case) else {
            rep.row(id, vec![format!("{id}: battery.cases has no case {case}")]);
            continue;
        };
        let mut p = field_problems(id, doc, 0..doc.maths.len(), Text::Whole);
        let got: Vec<(bool, String)> = extract_math(&doc.sources[0])
            .maths
            .iter()
            .map(|m| (m.display, m.tex.clone()))
            .collect();
        let want: Vec<(bool, String)> = want.iter().map(|&(d, t)| (d, t.to_string())).collect();
        if got != want {
            p.push(format!(
                "{id}: {case}: the stated result is {want:?} but the grammar finds {got:?}"
            ));
        }
        rep.row(id, p);
    }
}

/// The battery cases no row of `rows` checks.
fn uncovered<'a>(rows: &[BatteryRow], battery: &'a [Doc]) -> Vec<&'a str> {
    battery
        .iter()
        .map(|d| d.name.as_str())
        .filter(|name| !rows.iter().any(|r| r.1 == *name))
        .collect()
}

#[test]
fn showcase_battery_rows() {
    let battery = casefile::load(&golden("battery.cases"));
    assert_eq!(BATTERY_ROWS.len(), 82, "the rows of the battery");
    let ids: HashSet<&str> = BATTERY_ROWS.iter().map(|r| r.0).collect();
    assert_eq!(ids.len(), 82, "every row id once");
    let none: [&str; 0] = [];
    assert_eq!(
        uncovered(BATTERY_ROWS, &battery),
        none,
        "battery cases without a row"
    );
    let mut rep = Report::default();
    battery_rows(BATTERY_ROWS, &battery, &mut rep);
    rep.finish();
}

// ---- the disagreement table (MG rows) ----

fn disagreement_rows(
    rows: &[DisagreementRow],
    escaped: &[(&str, &str)],
    battery: &[Doc],
    additions: &[Doc],
    rep: &mut Report,
) {
    for &(id, cases) in rows {
        let mut p = Vec::new();
        for &(case, spans) in cases {
            let Some(doc) = find(battery, case).or_else(|| find(additions, case)) else {
                p.push(format!(
                    "{id}: no case {case} in battery.cases or additions.cases"
                ));
                continue;
            };
            p.extend(field_problems(id, doc, 0..doc.maths.len(), Text::Whole));
            p.extend(span_problems(id, case, &doc.sources[0], spans));
            if id == "MG-04" {
                match escaped.iter().find(|(c, _)| *c == case) {
                    Some(&(_, text)) => p.extend(escape_problems(id, case, &doc.sources[0], text)),
                    None => p.push(format!("{id}: {case}: no stated text")),
                }
            }
        }
        rep.row(id, p);
    }
}

/// MG-07: `\{ \, \| \_` and a mid-line `\\` stay inside the math byte for byte (GitHub's renderer strips the
/// backslashes): each case is one inline math whose TeX, the TeX between its `$` and its MathJax text are the
/// stated TeX, and every field equals the reference.
fn kept_escape_rows(cases: &[(&str, &'static str)], battery: &[Doc], rep: &mut Report) {
    let id = "MG-07";
    let mut p = untouched_cases(id, battery, cases);
    for &(case, tex) in cases {
        if let Some(doc) = find(battery, case) {
            p.extend(span_problems(
                id,
                case,
                &doc.sources[0],
                &[("dollar", false, false, tex)],
            ));
        }
    }
    rep.row(id, p);
}

#[test]
fn showcase_disagreement_table() {
    let battery = casefile::load(&golden("battery.cases"));
    let additions = casefile::load(&golden("additions.cases"));
    assert_eq!(DISAGREEMENT_ROWS.len(), 12, "the rows of this table");
    assert_eq!(KEPT_ESCAPES.len(), 5, "the cases of MG-07");
    let mut rep = Report::default();
    disagreement_rows(
        DISAGREEMENT_ROWS,
        ESCAPED_TEXTS,
        &battery,
        &additions,
        &mut rep,
    );
    kept_escape_rows(KEPT_ESCAPES, &battery, &mut rep);
    rep.finish();
}

// ---- the settled edge cases (MK-15, and the \renewcommand half of MG-15) ----

/// `settled-multline` per engine: `prepared` (under both engines) and the KaTeX text against `katex`, the stated
/// form KaTeX draws, and the MathJax text against `mathjax`, MathJax's own form.
fn multline_problems(id: &str, additions: &[Doc], katex: &str, mathjax: &str) -> Vec<String> {
    let mut p = Vec::new();
    let Some(doc) = find(additions, "settled-multline") else {
        p.push(format!("{id}: additions.cases has no settled-multline"));
        return p;
    };
    let r = run(doc);
    let got = [
        ("prepared", r.katex.prepared.first(), katex),
        ("prepared under MathJax", r.mathjax.prepared.first(), katex),
        ("katex", r.katex.engine.first().map(|e| &e.tex), katex),
        ("mathjax", r.mathjax.engine.first().map(|e| &e.tex), mathjax),
    ];
    for (what, got, want) in got {
        if got.map(String::as_str) != Some(want) {
            p.push(format!(
                "{id}: settled-multline {what}: want {want:?} got {got:?}"
            ));
        }
    }
    p
}

fn settled_rows(additions: &[Doc], expected: &[Addition], rep: &mut Report) {
    let id = "MK-15";
    let mut p = Vec::new();
    if additions.len() != expected.len() {
        p.push(format!(
            "{id}: additions.cases holds {} documents, the table {}",
            additions.len(),
            expected.len()
        ));
    }
    for doc in additions {
        if !expected.iter().any(|(n, _, _)| *n == doc.name) {
            p.push(format!("{id}: no stated values for {}", doc.name));
        }
    }
    for &(name, text, spans) in expected {
        let Some(doc) = find(additions, name) else {
            p.push(format!("{id}: additions.cases has no {name}"));
            continue;
        };
        p.extend(field_problems(id, doc, 0..doc.maths.len(), Text::Whole));
        let ex = extract_math(&doc.sources[0]);
        if ex.text != text {
            p.push(problem(id, name, "text", text, &ex.text));
        }
        p.extend(span_problems(id, name, &doc.sources[0], spans));
    }
    p.extend(multline_problems(
        id,
        additions,
        MULTLINE_GATHER,
        MULTLINE_MATHJAX,
    ));
    rep.row(id, p);

    // MG-15, the part that needs no fixture: \newcommand of a name KaTeX has becomes \renewcommand for KaTeX only.
    let id = "MG-15";
    let mut p = Vec::new();
    match find(additions, "settled-newcommand-R") {
        Some(doc) => {
            p.extend(field_problems(id, doc, 0..doc.maths.len(), Text::Whole));
            let r = run(doc);
            let got = [
                (
                    "KaTeX",
                    r.katex.engine.first().map(|e| e.tex.as_str()),
                    NEWCOMMAND_KATEX,
                ),
                (
                    "MathJax",
                    r.mathjax.engine.first().map(|e| e.tex.as_str()),
                    NEWCOMMAND_MATHJAX,
                ),
                (
                    "KaTeX later math",
                    r.katex.engine.get(1).map(|e| e.tex.as_str()),
                    "\\R^n",
                ),
            ];
            for (what, got, want) in got {
                if got != Some(want) {
                    p.push(format!(
                        "{id}: settled-newcommand-R {what}: want {want:?} got {got:?}"
                    ));
                }
            }
        }
        None => p.push(format!("{id}: additions.cases has no settled-newcommand-R")),
    }
    rep.row(id, p);
}

#[test]
fn showcase_settled_edge_cases() {
    let additions = casefile::load(&golden("additions.cases"));
    assert_eq!(ADDITIONS.len(), 11, "the additions");
    let mut rep = Report::default();
    settled_rows(&additions, ADDITIONS, &mut rep);
    rep.finish();
}

// ---- the sections of the fixture (MG-12, MG-15, MK-16, MG-04) ----

/// One section of `md-fixture.md` as each layout holds it: inside the whole markdown file, as its own cell
/// document and as a cell of the whole notebook.
struct Layout<'a> {
    doc: &'a Doc,
    /// The source of the section in `doc`.
    source: usize,
    /// The section's bytes in that source (line feeds normalized).
    bytes: Range<usize>,
    /// The index in the flat list of the first math of that source.
    base: usize,
    /// The indexes in the flat list of the section's maths.
    maths: Range<usize>,
    text: Text,
}

impl Layout<'_> {
    fn source_text(&self) -> String {
        normalize_newlines(&self.doc.sources[self.source]).into_owned()
    }
}

/// Section `i` (named `name`) in the three layouts. Section `i` of the markdown file must be cell `i` of the
/// notebook, so a mixed-up index cannot pass.
fn layouts<'a>(fx: &'a [Doc], name: &str, i: usize) -> Result<Vec<Layout<'a>>, String> {
    let md = find(fx, "md-fixture.md").ok_or("fixtures.cases has no md-fixture.md")?;
    let nb = find(fx, "md-fixture.ipynb").ok_or("fixtures.cases has no md-fixture.ipynb")?;
    let cell_name = format!("md-fixture.ipynb#{i}");
    let cell = find(fx, &cell_name).ok_or(format!("fixtures.cases has no {cell_name}"))?;
    let norm = normalize_newlines(&md.sources[0]);
    let starts = section_starts(&norm);
    let a = *starts
        .get(i)
        .ok_or(format!("md-fixture.md has no section {i}"))?;
    let b = starts.get(i + 1).copied().unwrap_or(norm.len());
    let marker = format!("<!-- section: {name} -->");
    let body = norm[a..b]
        .strip_prefix(marker.as_str())
        .ok_or(format!("section {i} of md-fixture.md is not {name}"))?;
    let nb_src = nb
        .sources
        .get(i)
        .ok_or(format!("md-fixture.ipynb has no cell {i}"))?;
    if body.trim() != cell.sources[0].trim() || body.trim() != nb_src.trim() {
        return Err(format!(
            "section {i} ({name}) of md-fixture.md is not cell {i} of the notebook"
        ));
    }
    let md_maths = maths_within(&extract_math(&norm), a..b);
    let nb_base = nb.maths.iter().filter(|m| m.source < i).count();
    let nb_len = nb.maths.iter().filter(|m| m.source == i).count();
    Ok(vec![
        Layout {
            doc: md,
            source: 0,
            bytes: a..b,
            base: 0,
            maths: md_maths,
            text: Text::Section(i),
        },
        Layout {
            doc: cell,
            source: 0,
            bytes: 0..normalize_newlines(&cell.sources[0]).len(),
            base: 0,
            maths: 0..cell.maths.len(),
            text: Text::Whole,
        },
        Layout {
            doc: nb,
            source: i,
            bytes: 0..normalize_newlines(nb_src).len(),
            base: nb_base,
            maths: nb_base..nb_base + nb_len,
            text: Text::Whole,
        },
    ])
}

/// The first line of `src[within]` that starts with `prefix`, without its line feed.
fn line_starting(src: &str, within: Range<usize>, prefix: &str) -> Option<Range<usize>> {
    let mut at = within.start;
    for line in src.get(within)?.split_inclusive('\n') {
        if line.starts_with(prefix) {
            return Some(at..at + line.trim_end_matches('\n').len());
        }
        at += line.len();
    }
    None
}

/// The names of the environments `prepare_tex` numbers.
const NUMBERED: [&str; 7] = [
    "equation", "align", "gather", "flalign", "alignat", "eqnarray", "multline",
];

fn is_numbered_env(tex: &str) -> bool {
    let Some(rest) = tex.trim_start().strip_prefix("\\begin{") else {
        return false;
    };
    rest.find('}')
        .is_some_and(|end| NUMBERED.contains(&&rest[..end]))
}

/// MG-12: every numbered environment of the section is prepared with an explicit `\tag{` and no math keeps a
/// `\label{`. The section has two numbered environments, an `align` and an `equation`.
fn numbering_problems(row: &str, l: &Layout) -> Vec<String> {
    let r = run(l.doc);
    let n = l.doc.name.as_str();
    let flat = r.flat();
    let mut out = Vec::new();
    let mut numbered = 0;
    for g in l.maths.clone() {
        let (Some((_, m)), Some(prepared)) = (flat.get(g), r.katex.prepared.get(g)) else {
            out.push(format!("{row}: {n}: math {g} is missing"));
            continue;
        };
        if is_numbered_env(&m.tex) {
            numbered += 1;
            if !prepared.contains("\\tag{") {
                out.push(format!(
                    "{row}: {n}: math {g} has no \\tag{{: {}",
                    esc(prepared)
                ));
            }
        }
        if prepared.contains("\\label{") {
            out.push(format!(
                "{row}: {n}: math {g} keeps a \\label{{: {}",
                esc(prepared)
            ));
        }
    }
    if numbered != 2 {
        out.push(format!(
            "{row}: {n}: {numbered} numbered environments, want 2"
        ));
    }
    out
}

/// The TeX handed to the engine for math `k`.
fn engine_tex(p: &PreparedDoc, k: usize) -> Option<&str> {
    p.engine.get(k).map(|e| e.tex.as_str())
}

/// MG-15: in the section a `\newcommand` of `\R` (which KaTeX predefines) is `\renewcommand` for KaTeX and
/// unchanged for MathJax, and the `\renewcommand` after it is unchanged for both.
fn macro_problems(row: &str, l: &Layout) -> Vec<String> {
    let r = run(l.doc);
    let n = l.doc.name.as_str();
    let flat = r.flat();
    let new_r = "\\newcommand{\\R}{\\mathbf{R}} \\R";
    let renew_r = "\\renewcommand{\\R}{\\mathbf{R}} \\R";
    let Some(g) = l
        .maths
        .clone()
        .find(|&g| flat.get(g).is_some_and(|(_, m)| m.tex == new_r))
    else {
        return vec![format!("{row}: {n}: no math `{new_r}` in the section")];
    };
    let mut out = Vec::new();
    if flat.get(g + 1).map(|(_, m)| m.tex.as_str()) != Some(renew_r) {
        out.push(format!(
            "{row}: {n}: the math after `{new_r}` is not `{renew_r}`"
        ));
    }
    let checks = [
        ("KaTeX definition", engine_tex(&r.katex, g), renew_r),
        ("KaTeX renewcommand", engine_tex(&r.katex, g + 1), renew_r),
        ("MathJax definition", engine_tex(&r.mathjax, g), new_r),
        (
            "MathJax renewcommand",
            engine_tex(&r.mathjax, g + 1),
            renew_r,
        ),
    ];
    for (what, got, want) in checks {
        if got != Some(want) {
            out.push(format!("{row}: {n}: {what}: want {want:?} got {got:?}"));
        }
    }
    if !r.katex.engine.get(g).is_some_and(|e| e.affecting) {
        out.push(format!(
            "{row}: {n}: the rewritten math is not affecting for KaTeX"
        ));
    }
    out
}

/// MG-15: in the whole notebook the definitions of cell `def` are affecting under both engines, and every math
/// of cell `next` is typeset in the macro environment of the first math after the last affecting one of cell
/// `def`, which is not the empty environment 0.
fn env_problems(row: &str, nb: &Doc, def: usize, next: usize) -> Vec<String> {
    let r = run(nb);
    let n = nb.name.as_str();
    if def >= r.ex.len() || next >= r.ex.len() {
        return vec![format!("{row}: {n}: has no cells {def} and {next}")];
    }
    let mut out = Vec::new();
    for (label, p) in [("KaTeX", &r.katex), ("MathJax", &r.mathjax)] {
        let off = p.offsets[def];
        let len = r.ex[def].maths.len();
        let engine = &p.engine;
        if len == 0 || !engine[off].affecting {
            out.push(format!(
                "{row}: {n}: {label}: the definitions math of cell {def} is not affecting"
            ));
            continue;
        }
        let Some(last) = (off..off + len).rev().find(|&k| engine[k].affecting) else {
            continue;
        };
        let Some(after) = (last + 1..engine.len()).find(|&k| !engine[k].affecting) else {
            out.push(format!(
                "{row}: {n}: {label}: no math without a definition follows"
            ));
            continue;
        };
        let env = engine[after].env;
        if env == 0 {
            out.push(format!(
                "{row}: {n}: {label}: the environment after the definitions is 0"
            ));
        }
        let (a, b) = (p.offsets[next], p.offsets[next] + r.ex[next].maths.len());
        if a == b {
            out.push(format!("{row}: {n}: {label}: cell {next} has no maths"));
        }
        for (k, e) in engine.iter().enumerate().skip(a).take(b - a) {
            if e.env != env {
                out.push(format!(
                    "{row}: {n}: {label}: math {k} of cell {next} has environment {:#x}, want {env:#x}",
                    e.env
                ));
            }
        }
    }
    out
}

/// MG-04: the `Currency:` line of the section holds no math, each of its `$` is an edit with no math that
/// writes `\$`, and its text is the reference's.
fn currency_problems(row: &str, l: &Layout, want_text: &str) -> Vec<String> {
    let n = l.doc.name.as_str();
    let src = l.source_text();
    let Some(line) = line_starting(&src, l.bytes.clone(), "Currency: it costs ") else {
        return vec![format!("{row}: {n}: no Currency line in the section")];
    };
    let r = run(l.doc);
    let ex = &r.ex[l.source];
    let mut out = Vec::new();
    let dollars = src[line.clone()].matches('$').count();
    let edits: Vec<_> = ex
        .edits
        .iter()
        .filter(|e| line.contains(&e.src.start))
        .collect();
    if edits.len() != dollars {
        out.push(format!(
            "{row}: {n}: {dollars} dollars on the line but {} edits",
            edits.len()
        ));
    }
    for e in edits {
        let from = src.get(e.src.clone());
        let to = ex.text.get(e.text.clone());
        if e.math.is_some() || from != Some("$") || to != Some("\\$") {
            out.push(format!(
                "{row}: {n}: edit {e:?} turns {from:?} into {to:?}, not a `$` into `\\$`"
            ));
        }
    }
    match line_starting(&ex.text, 0..ex.text.len(), "Currency: it costs ") {
        Some(t) if ex.text[t.clone()] == *want_text => {}
        Some(t) => out.push(problem(row, n, "Currency text", want_text, &ex.text[t])),
        None => out.push(format!("{row}: {n}: no Currency line in the text")),
    }
    out
}

/// MK-16: a line of the section the grammar must not touch (a fenced line holding a `$`) is in the source and in
/// the text byte for byte, and no edit starts inside it.
fn verbatim_problems(row: &str, l: &Layout, want: &str) -> Vec<String> {
    let n = l.doc.name.as_str();
    let src = l.source_text();
    let line = match line_starting(&src, l.bytes.clone(), want) {
        Some(line) if src[line.clone()] == *want => line,
        _ => return vec![format!("{row}: {n}: no line {want:?} in the section")],
    };
    let r = run(l.doc);
    let Some(ex) = r.ex.get(l.source) else {
        return vec![format!("{row}: {n}: has no source {}", l.source)];
    };
    let mut out = Vec::new();
    if let Some(e) = ex.edits.iter().find(|e| line.contains(&e.src.start)) {
        out.push(format!("{row}: {n}: edit {e:?} lies inside {want:?}"));
    }
    if !ex.text.split('\n').any(|t| t == want) {
        out.push(format!("{row}: {n}: the text has no line {want:?}"));
    }
    out
}

/// A document of the reference's output written out in this file, in the form of the golden case files. None of
/// these documents holds a numbered `eqnarray` or `multline`, so the MathJax text is the prepared text (deviation
/// D6 changes only those two).
fn ref_doc(&(name, sources, texts, maths): &RefDoc) -> Doc {
    Doc {
        name: name.to_string(),
        sources: sources.iter().map(|s| s.to_string()).collect(),
        texts: texts.iter().map(|s| s.to_string()).collect(),
        maths: maths
            .iter()
            .map(
                |&(source, display, block, kind, tex, raw, prepared, katex)| CaseMath {
                    source,
                    display,
                    block,
                    kind: kind.to_string(),
                    tex: tex.to_string(),
                    raw: raw.to_string(),
                    prepared: prepared.to_string(),
                    katex: katex.to_string(),
                    mathjax: prepared.to_string(),
                },
            )
            .collect(),
    }
}

/// MK-16: the sections math-conflicts (29), math-env (25), inlinecode (3) and code (12, whose fence holds a
/// `$`) in the three layouts, battery `code-inside`, and its own documents `docs`: every field equals the
/// reference.
fn mk16_row(fx: &[Doc], battery: &[Doc], docs: &[RefDoc], rep: &mut Report) {
    let id = "MK-16";
    let mut p = Vec::new();
    for (name, i) in [
        ("math-conflicts", 29),
        ("math-env", 25),
        ("inlinecode", 3),
        ("code", 12),
    ] {
        match layouts(fx, name, i) {
            Ok(ls) => {
                for l in &ls {
                    p.extend(field_problems(id, l.doc, l.maths.clone(), l.text));
                    if name == "code" {
                        p.extend(verbatim_problems(id, l, CODE_FENCE_DOLLAR));
                    }
                }
            }
            Err(e) => p.push(format!("{id}: {e}")),
        }
    }
    match find(battery, "code-inside") {
        Some(doc) => {
            p.extend(field_problems(id, doc, 0..doc.maths.len(), Text::Whole));
            p.extend(span_problems(
                id,
                "code-inside",
                &doc.sources[0],
                CODE_INSIDE,
            ));
        }
        None => p.push(format!("{id}: battery.cases has no code-inside")),
    }
    for d in docs {
        let doc = ref_doc(d);
        p.extend(field_problems(id, &doc, 0..doc.maths.len(), Text::Whole));
    }
    rep.row(id, p);
}

fn fixture_rows(fx: &[Doc], battery: &[Doc], rep: &mut Report) {
    // MG-12
    let id = "MG-12";
    let mut p = Vec::new();
    match layouts(fx, "math-bare", 26) {
        Ok(ls) => {
            for l in &ls {
                p.extend(field_problems(id, l.doc, l.maths.clone(), l.text));
                p.extend(numbering_problems(id, l));
            }
        }
        Err(e) => p.push(format!("{id}: {e}")),
    }
    match find(battery, "bare-env-inline") {
        Some(doc) => {
            p.extend(field_problems(id, doc, 0..doc.maths.len(), Text::Whole));
            p.extend(span_problems(
                id,
                "bare-env-inline",
                &doc.sources[0],
                BARE_ENV_INLINE,
            ));
        }
        None => p.push(format!("{id}: battery.cases has no bare-env-inline")),
    }
    rep.row(id, p);

    // MG-15, the part with the macros section and the notebook
    let id = "MG-15";
    let mut p = Vec::new();
    match layouts(fx, "math-macros", 27) {
        Ok(ls) => {
            for l in &ls {
                p.extend(field_problems(id, l.doc, l.maths.clone(), l.text));
                p.extend(macro_problems(id, l));
            }
            p.extend(env_problems(id, ls[2].doc, 27, 28));
        }
        Err(e) => p.push(format!("{id}: {e}")),
    }
    rep.row(id, p);

    mk16_row(fx, battery, MK16_DOCS, rep);

    // MG-04, the part with the fixture
    let id = "MG-04";
    let mut p = Vec::new();
    match layouts(fx, "math-inline", 22) {
        Ok(ls) => {
            for l in &ls {
                p.extend(field_problems(id, l.doc, l.maths.clone(), l.text));
                p.extend(currency_problems(id, l, CURRENCY_TEXT));
            }
        }
        Err(e) => p.push(format!("{id}: {e}")),
    }
    rep.row(id, p);
}

#[test]
fn showcase_fixture_sections() {
    let fixtures = casefile::load(&golden("fixtures.cases"));
    let battery = casefile::load(&golden("battery.cases"));
    let mut rep = Report::default();
    fixture_rows(&fixtures, &battery, &mut rep);
    rep.finish();
}

// ---- TeX that reaches MathJax unchanged (MD-18) ----

/// The maths `local` of source `source` of `r`: the grammar's TeX, the TeX between their `$` and the TeX
/// MathJax receives are each the stated TeX, byte for byte.
fn untouched_problems(
    row: &str,
    name: &str,
    r: &Run,
    source: usize,
    local: Range<usize>,
    want: &[&str],
) -> Vec<String> {
    let mut out = Vec::new();
    if local.len() != want.len() {
        out.push(format!(
            "{row}: {name}: {} maths, want {}",
            local.len(),
            want.len()
        ));
        return out;
    }
    let Some(&base) = r.mathjax.offsets.get(source) else {
        return vec![format!("{row}: {name}: has no source {source}")];
    };
    for (j, want) in local.zip(want) {
        let Some(m) = r.ex.get(source).and_then(|x| x.maths.get(j)) else {
            out.push(format!(
                "{row}: {name}: math {j} of source {source} is missing"
            ));
            continue;
        };
        let between = m.raw.strip_prefix('$').and_then(|s| s.strip_suffix('$'));
        let mathjax = r.mathjax.engine.get(base + j).map(|e| e.tex.as_str());
        let got = [
            ("tex", Some(m.tex.as_str())),
            ("raw between the delimiters", between),
            ("MathJax text", mathjax),
        ];
        for (what, got) in got {
            if got != Some(*want) {
                out.push(format!("{row}: {name}: {what}: want {want:?} got {got:?}"));
            }
        }
    }
    out
}

/// Battery cases of one math whose TeX passes through untouched: every field equals the reference, and the
/// grammar's TeX, the TeX between the `$` and the MathJax text each equal the stated TeX.
fn untouched_cases(id: &str, battery: &[Doc], cases: &[(&str, &str)]) -> Vec<String> {
    let mut p = Vec::new();
    for &(case, tex) in cases {
        let Some(doc) = find(battery, case) else {
            p.push(format!("{id}: battery.cases has no {case}"));
            continue;
        };
        p.extend(field_problems(id, doc, 0..doc.maths.len(), Text::Whole));
        p.extend(untouched_problems(id, case, &run(doc), 0, 0..1, &[tex]));
    }
    p
}

/// The TeX the engine receives for math `i` of source `s`.
fn source_engine_tex(d: &PreparedDoc, s: usize, i: usize) -> Option<&str> {
    let base = d.offsets.get(s)?;
    d.engine.get(base + i).map(|e| e.tex.as_str())
}

/// The comparison of MD-18 names "MD-H-md-gauss shows the thin space, not a comma", so its text half also runs
/// on that fixture: in `gauss.md`, `gauss.ipynb#0` and `gauss.ipynb` the maths are the stated ones, the display
/// one with its `\,`. For each math the golden raw, TeX, prepared and KaTeX text, the grammar's raw and TeX, and
/// the TeX each engine receives are the stated `(raw, tex)`, byte for byte.
fn gauss_problems(id: &str, fx: &[Doc], gauss: &[(&str, &str)]) -> Vec<String> {
    let mut p = Vec::new();
    if !gauss.first().is_some_and(|g| g.1.contains("\\,")) {
        p.push(format!("{id}: the stated gauss display has no thin space"));
    }
    for name in ["gauss.md", "gauss.ipynb#0", "gauss.ipynb"] {
        let Some(doc) = find(fx, name) else {
            p.push(format!("{id}: fixtures.cases has no {name}"));
            continue;
        };
        p.extend(field_problems(id, doc, 0..doc.maths.len(), Text::Whole));
        let r = run(doc);
        let flat = r.flat();
        if doc.maths.len() != flat.len() || flat.len() != gauss.len() {
            p.push(format!(
                "{id}: {name}: {} golden maths, {} found, {} stated",
                doc.maths.len(),
                flat.len(),
                gauss.len()
            ));
            continue;
        }
        let mut local = vec![0; r.ex.len()];
        for (j, ((s, m), (raw, tex))) in flat.iter().zip(gauss).enumerate() {
            let i = local.get(*s).copied().unwrap_or(0);
            if let Some(n) = local.get_mut(*s) {
                *n += 1;
            }
            let golden = doc.maths.get(j);
            let fields = [
                ("golden raw", golden.map(|g| g.raw.as_str()), *raw),
                ("golden tex", golden.map(|g| g.tex.as_str()), *tex),
                ("golden prepared", golden.map(|g| g.prepared.as_str()), *tex),
                ("golden katex", golden.map(|g| g.katex.as_str()), *tex),
                ("raw", Some(m.raw.as_str()), *raw),
                ("tex", Some(m.tex.as_str()), *tex),
                ("MathJax text", source_engine_tex(&r.mathjax, *s, i), *tex),
                ("KaTeX text", source_engine_tex(&r.katex, *s, i), *tex),
            ];
            for (what, got, want) in fields {
                if got != Some(want) {
                    p.push(format!(
                        "{id}: {name}: maths[{j}] {what}: want {want:?} got {got:?}"
                    ));
                }
            }
        }
    }
    p
}

fn untouched_rows(
    fx: &[Doc],
    battery: &[Doc],
    cases: &[(&str, &str)],
    escapes: &[&str],
    gauss: &[(&str, &str)],
    rep: &mut Report,
) {
    let id = "MD-18";
    let mut p = untouched_cases(id, battery, cases);
    p.extend(gauss_problems(id, fx, gauss));
    match layouts(fx, "math-conflicts", 29) {
        Ok(ls) => {
            for l in &ls {
                let src = l.source_text();
                let Some(line) = line_starting(&src, l.bytes.clone(), "Escapes inside math: ")
                else {
                    p.push(format!("{id}: {}: no Escapes line", l.doc.name));
                    continue;
                };
                let r = run(l.doc);
                let local = maths_within(&r.ex[l.source], line);
                let flat = l.base + local.start..l.base + local.end;
                p.extend(field_problems(id, l.doc, flat, l.text));
                p.extend(untouched_problems(
                    id,
                    &l.doc.name,
                    &r,
                    l.source,
                    local,
                    escapes,
                ));
            }
        }
        Err(e) => p.push(format!("{id}: {e}")),
    }
    rep.row(id, p);
}

#[test]
fn showcase_text_untouched() {
    let fixtures = casefile::load(&golden("fixtures.cases"));
    let battery = casefile::load(&golden("battery.cases"));
    let mut rep = Report::default();
    untouched_rows(
        &fixtures,
        &battery,
        UNTOUCHED_CASES,
        ESCAPES_LINE,
        GAUSS_MATHS,
        &mut rep,
    );
    rep.finish();
}

// ---- the checks reject a change ----

fn doc_mut<'a>(docs: &'a mut [Doc], name: &str) -> &'a mut Doc {
    docs.iter_mut()
        .find(|d| d.name == name)
        .unwrap_or_else(|| panic!("no document {name}"))
}

/// Runs every checker on the data and returns what it found.
fn check_all(battery: &[Doc], additions: &[Doc], fixtures: &[Doc]) -> Report {
    let mut rep = Report::default();
    battery_rows(BATTERY_ROWS, battery, &mut rep);
    disagreement_rows(
        DISAGREEMENT_ROWS,
        ESCAPED_TEXTS,
        battery,
        additions,
        &mut rep,
    );
    kept_escape_rows(KEPT_ESCAPES, battery, &mut rep);
    settled_rows(additions, ADDITIONS, &mut rep);
    fixture_rows(fixtures, battery, &mut rep);
    untouched_rows(
        fixtures,
        battery,
        UNTOUCHED_CASES,
        ESCAPES_LINE,
        GAUSS_MATHS,
        &mut rep,
    );
    rep
}

/// The checkers accept the reference's own data, cover all 100 rows, and name the row when one expected
/// value or one golden value changes.
#[test]
fn showcase_checks_reject_a_change() {
    let battery = casefile::load(&golden("battery.cases"));
    let additions = casefile::load(&golden("additions.cases"));
    let fixtures = casefile::load(&golden("fixtures.cases"));

    // Control: unchanged data passes, and the checkers together cover exactly the 100 rows.
    let rep = check_all(&battery, &additions, &fixtures);
    assert!(
        rep.problems.is_empty(),
        "control:\n{}",
        rep.problems.join("\n")
    );
    let ids: HashSet<&str> = rep.ok.iter().map(String::as_str).collect();
    assert_eq!(ids.len(), 100, "rows covered: {ids:?}");
    assert_eq!(ids.iter().filter(|i| i.starts_with("MB-")).count(), 82);
    assert_eq!(ids.iter().filter(|i| i.starts_with("MG-")).count(), 15);
    for id in ["MK-15", "MK-16", "MD-18"] {
        assert!(ids.contains(id), "{id} is not covered");
    }

    // One altered expected value per checker: the stated TeX of a battery row, its display flag, a kind
    // of the disagreement table, the text of an escaped case, a settled literal, a fixture literal.
    let caught = |id: &str, f: &dyn Fn(&mut Report)| {
        let mut rep = Report::default();
        f(&mut rep);
        assert!(
            rep.names(id),
            "a changed value of {id} is not reported: {:?}",
            rep.problems
        );
        assert!(
            !rep.ok.iter().any(|o| o == id),
            "{id} passed with a changed value"
        );
    };
    caught("MB-open-space", &|rep| {
        battery_rows(
            &[("MB-open-space", "open-space", &[(false, "y")])],
            &battery,
            rep,
        )
    });
    caught("MB-open-space", &|rep| {
        battery_rows(
            &[("MB-open-space", "open-space", &[(true, "x")])],
            &battery,
            rep,
        )
    });
    caught("MB-open-space", &|rep| {
        battery_rows(&[("MB-open-space", "open-space", &[])], &battery, rep)
    });
    // GitHub's reading of a table cell's escaped pipe, `|x|`, is not the grammar's.
    caught("MB-table-escaped-pipe", &|rep| {
        battery_rows(
            &[(
                "MB-table-escaped-pipe",
                "table-escaped-pipe",
                &[(false, "|x|")],
            )],
            &battery,
            rep,
        )
    });
    // A table without the rows whose cells hold an escaped pipe leaves exactly those cases uncovered.
    let without_pipes: Vec<BatteryRow> = BATTERY_ROWS
        .iter()
        .copied()
        .filter(|r| !r.1.contains("pipe"))
        .collect();
    assert_eq!(
        uncovered(&without_pipes, &battery),
        ["pipe-escape", "table-pipe", "table-escaped-pipe"]
    );
    // MG-07: a stated TeX with the backslashes stripped, as GitHub shows it.
    caught("MG-07", &|rep| {
        kept_escape_rows(&[("pipe-escape", "|v|")], &battery, rep)
    });
    caught("MG-07", &|rep| {
        let mut cases = KEPT_ESCAPES.to_vec();
        cases[4].1 = "a \\ b";
        kept_escape_rows(&cases, &battery, rep)
    });
    caught("MG-02", &|rep| {
        let rows: &[DisagreementRow] =
            &[("MG-02", &[("bracket", &[("dollars", false, false, "x")])])];
        disagreement_rows(rows, ESCAPED_TEXTS, &battery, &additions, rep)
    });
    caught("MG-04", &|rep| {
        let rows: &[DisagreementRow] = &[("MG-04", &[("currency-two", &[])])];
        let escaped = [("currency-two", "costs $5 and $10 each")];
        disagreement_rows(rows, &escaped, &battery, &additions, rep)
    });
    caught("MK-15", &|rep| {
        let mut table = ADDITIONS.to_vec();
        table[8].1 = "ZZMTH0001ZZ";
        settled_rows(&additions, &table, rep)
    });

    // One altered golden value per field, in each kind of document.
    let mut b = battery.clone();
    doc_mut(&mut b, "open-space").maths[0].tex.push('y');
    caught("MB-open-space", &|rep| battery_rows(BATTERY_ROWS, &b, rep));
    let mut b = battery.clone();
    doc_mut(&mut b, "open-space").maths[0].prepared.push('y');
    caught("MB-open-space", &|rep| battery_rows(BATTERY_ROWS, &b, rep));
    let mut b = battery.clone();
    doc_mut(&mut b, "open-space").maths[0].katex.push('y');
    caught("MB-open-space", &|rep| battery_rows(BATTERY_ROWS, &b, rep));
    let mut b = battery.clone();
    doc_mut(&mut b, "open-space").texts[0].push('y');
    caught("MB-open-space", &|rep| battery_rows(BATTERY_ROWS, &b, rep));
    let mut b = battery.clone();
    doc_mut(&mut b, "open-space").maths[0].kind = "dollars".into();
    caught("MB-open-space", &|rep| battery_rows(BATTERY_ROWS, &b, rep));
    let mut b = battery.clone();
    doc_mut(&mut b, "currency-two").texts[0].push('y');
    caught("MB-currency-two", &|rep| {
        battery_rows(BATTERY_ROWS, &b, rep)
    });
    caught("MG-04", &|rep| {
        disagreement_rows(DISAGREEMENT_ROWS, ESCAPED_TEXTS, &b, &additions, rep)
    });
    let mut b = battery.clone();
    doc_mut(&mut b, "pipe-escape").maths[0].prepared = "|v|".into();
    caught("MG-07", &|rep| kept_escape_rows(KEPT_ESCAPES, &b, rep));
    caught("MB-pipe-escape", &|rep| battery_rows(BATTERY_ROWS, &b, rep));

    // An additions document.
    let mut a = additions.clone();
    doc_mut(&mut a, "settled-dbl-bracket").maths[0].display = false;
    caught("MK-15", &|rep| settled_rows(&a, ADDITIONS, rep));
    caught("MG-13", &|rep| {
        disagreement_rows(DISAGREEMENT_ROWS, ESCAPED_TEXTS, &battery, &a, rep)
    });
    let mut a = additions.clone();
    doc_mut(&mut a, "settled-newcommand-R").maths[0].katex =
        "\\newcommand{\\R}{\\mathbb{R}}".into();
    caught("MK-15", &|rep| settled_rows(&a, ADDITIONS, rep));
    caught("MG-15", &|rep| settled_rows(&a, ADDITIONS, rep));
    // The MathJax text of the settled multline: a golden that holds KaTeX's stand-in, and a stated form that is
    // the stand-in for MathJax or MathJax's form for KaTeX, are each reported.
    let mut a = additions.clone();
    doc_mut(&mut a, "settled-multline").maths[0].mathjax = MULTLINE_GATHER.into();
    caught("MK-15", &|rep| settled_rows(&a, ADDITIONS, rep));
    assert!(multline_problems("MK-15", &additions, MULTLINE_GATHER, MULTLINE_MATHJAX).is_empty());
    let stand_in = multline_problems("MK-15", &additions, MULTLINE_GATHER, MULTLINE_GATHER);
    assert!(
        stand_in.len() == 1 && stand_in[0].contains("settled-multline mathjax:"),
        "{stand_in:?}"
    );
    let own = multline_problems("MK-15", &additions, MULTLINE_MATHJAX, MULTLINE_MATHJAX);
    assert_eq!(own.len(), 3, "{own:?}");
    let mut a = additions.clone();
    doc_mut(&mut a, "settled-price-decimal").texts[0].push('y');
    caught("MG-04", &|rep| {
        disagreement_rows(DISAGREEMENT_ROWS, ESCAPED_TEXTS, &battery, &a, rep)
    });

    // A section's prepared text, in each layout.
    let mut f = fixtures.clone();
    doc_mut(&mut f, "md-fixture.ipynb#26").maths[0]
        .prepared
        .push('y');
    caught("MG-12", &|rep| fixture_rows(&f, &battery, rep));
    let md_pos = |f: &[Doc]| {
        let md = find(f, "md-fixture.md").expect("md-fixture.md");
        md.maths
            .iter()
            .position(|m| m.tex.starts_with("\\begin{align}\n\\dot{x}"))
            .expect("the bare align")
    };
    let nb_pos = |f: &[Doc]| {
        let nb = find(f, "md-fixture.ipynb").expect("md-fixture.ipynb");
        nb.maths
            .iter()
            .position(|m| m.tex.starts_with("\\begin{align}\n\\dot{x}"))
            .expect("the bare align")
    };
    let mut f = fixtures.clone();
    let k = md_pos(&f);
    doc_mut(&mut f, "md-fixture.md").maths[k].prepared.push('y');
    caught("MG-12", &|rep| fixture_rows(&f, &battery, rep));
    let mut f = fixtures.clone();
    let k = nb_pos(&f);
    doc_mut(&mut f, "md-fixture.ipynb").maths[k]
        .prepared
        .push('y');
    caught("MG-12", &|rep| fixture_rows(&f, &battery, rep));
    let mut f = fixtures.clone();
    doc_mut(&mut f, "md-fixture.ipynb#27").maths[4].katex =
        "\\newcommand{\\R}{\\mathbf{R}} \\R".into();
    caught("MG-15", &|rep| fixture_rows(&f, &battery, rep));
    let mut f = fixtures.clone();
    doc_mut(&mut f, "md-fixture.ipynb#29").maths[0]
        .prepared
        .push('y');
    caught("MK-16", &|rep| fixture_rows(&f, &battery, rep));
    let mut f = fixtures.clone();
    doc_mut(&mut f, "md-fixture.ipynb#3").texts[0].push('y');
    caught("MK-16", &|rep| fixture_rows(&f, &battery, rep));
    // The code section: the reference's text with the fenced `$` escaped.
    let mut f = fixtures.clone();
    let cell = doc_mut(&mut f, "md-fixture.ipynb#12");
    cell.texts[0] = cell.texts[0].replace("\"$f\"", "\"\\$f\"");
    caught("MK-16", &|rep| fixture_rows(&f, &battery, rep));

    // MK-16's own documents: a `$` in a code span read as math, and an `\eqref` before its equation left
    // unresolved.
    caught("MK-16", &|rep| {
        let docs: &[RefDoc] = &[(
            "code-span",
            &["`$x$`"],
            &["`ZZMTH0001ZZ`"],
            &[(0, false, false, "dollar", "x", "$x$", "x", "x")],
        )];
        mk16_row(&fixtures, &battery, docs, rep)
    });
    caught("MK-16", &|rep| {
        let mut docs = MK16_DOCS.to_vec();
        let k = docs
            .iter()
            .position(|d| d.0 == "ams-forward-eqref")
            .expect("ams-forward-eqref");
        docs[k].3 = &[
            (
                0,
                false,
                false,
                "dollar",
                "\\eqref{a}",
                "$\\eqref{a}$",
                "\\text{(??)}",
                "\\text{(??)}",
            ),
            (
                0,
                true,
                false,
                "dollars",
                "\\begin{equation}x\\label{a}\\end{equation}",
                "$$\\begin{equation}x\\label{a}\\end{equation}$$",
                "\\begin{equation*}x \\tag{1}\\end{equation*}",
                "\\begin{equation*}x \\tag{1}\\end{equation*}",
            ),
        ];
        mk16_row(&fixtures, &battery, &docs, rep)
    });
    // The fenced line check: a line that is not there, and a line the grammar does read as math (the fence
    // taken away and a `$` pair put in, in the source of all three layouts alike).
    let ls = layouts(&fixtures, "code", 12).expect("the code section");
    for l in &ls {
        assert_eq!(
            verbatim_problems("MK-16", l, CODE_FENCE_DOLLAR),
            Vec::<String>::new()
        );
        let p = verbatim_problems("MK-16", l, "for f in *.ipynb; do echo \"\\$f\"; done");
        assert!(p.iter().any(|x| x.contains("no line")), "{p:?}");
    }
    let mut f = fixtures.clone();
    let fenced = format!("```bash\n{CODE_FENCE_DOLLAR}\n```");
    let math_line = "for f in *.ipynb; do echo \"$f$\"; done";
    for name in ["md-fixture.md", "md-fixture.ipynb#12"] {
        let d = doc_mut(&mut f, name);
        assert!(d.sources[0].contains(&fenced), "{name} has the bash fence");
        d.sources[0] = d.sources[0].replace(&fenced, math_line);
    }
    let nb = doc_mut(&mut f, "md-fixture.ipynb");
    nb.sources[12] = nb.sources[12].replace(&fenced, math_line);
    let ls = layouts(&f, "code", 12).expect("the changed code section");
    for l in &ls {
        let p = verbatim_problems("MK-16", l, math_line);
        assert!(p.iter().any(|x| x.contains("lies inside")), "{p:?}");
        assert!(
            p.iter().any(|x| x.contains("the text has no line")),
            "{p:?}"
        );
    }
    let mut f = fixtures.clone();
    doc_mut(&mut f, "md-fixture.ipynb#22").texts[0].push('y');
    caught("MG-04", &|rep| fixture_rows(&f, &battery, rep));

    // A text change inside one section of the markdown file is named by that section's row only.
    let mut f = fixtures.clone();
    let md = doc_mut(&mut f, "md-fixture.md");
    let at = md.texts[0]
        .find("Bare environment after a blank line:")
        .expect("a line of math-bare");
    md.texts[0].insert(at, 'y');
    let mut rep = Report::default();
    fixture_rows(&f, &battery, &mut rep);
    assert!(rep.names("MG-12"), "{:?}", rep.problems);
    for other in ["MG-15", "MK-16", "MG-04"] {
        assert!(
            !rep.names(other),
            "{other} reports a change in another section: {:?}",
            rep.problems
        );
    }
    // And one inside the code section is named by MK-16 only.
    let mut f = fixtures.clone();
    let md = doc_mut(&mut f, "md-fixture.md");
    let at = md.texts[0]
        .find(CODE_FENCE_DOLLAR)
        .expect("the fenced line of the code section");
    md.texts[0].insert(at, 'y');
    let mut rep = Report::default();
    fixture_rows(&f, &battery, &mut rep);
    assert!(rep.names("MK-16"), "{:?}", rep.problems);
    for other in ["MG-12", "MG-15", "MG-04"] {
        assert!(
            !rep.names(other),
            "{other} reports a change in another section: {:?}",
            rep.problems
        );
    }

    // The MD-18 literals and golden values.
    caught("MD-18", &|rep| {
        let mut escapes = ESCAPES_LINE.to_vec();
        escapes[1] = "a \\,b";
        untouched_rows(
            &fixtures,
            &battery,
            UNTOUCHED_CASES,
            &escapes,
            GAUSS_MATHS,
            rep,
        )
    });
    caught("MD-18", &|rep| {
        let cases = [("thinspace", "a\\, b")];
        untouched_rows(&fixtures, &battery, &cases, ESCAPES_LINE, GAUSS_MATHS, rep)
    });
    let mut f = fixtures.clone();
    doc_mut(&mut f, "md-fixture.ipynb#29").maths[7]
        .tex
        .push('y');
    caught("MD-18", &|rep| {
        untouched_rows(
            &f,
            &battery,
            UNTOUCHED_CASES,
            ESCAPES_LINE,
            GAUSS_MATHS,
            rep,
        )
    });
    // The gauss fixture: the stated display TeX with GitHub's stripped form (`\,` replaced by `,`), and the golden
    // TeX of `gauss.md` changed the same way.
    caught("MD-18", &|rep| {
        let stripped = GAUSS_MATHS[0].1.replace("\\,", ",");
        let gauss = [(GAUSS_MATHS[0].0, stripped.as_str()), GAUSS_MATHS[1]];
        untouched_rows(
            &fixtures,
            &battery,
            UNTOUCHED_CASES,
            ESCAPES_LINE,
            &gauss,
            rep,
        )
    });
    let mut g = fixtures.clone();
    let tex = &mut doc_mut(&mut g, "gauss.md").maths[0].tex;
    *tex = tex.replace("\\,", ",");
    caught("MD-18", &|rep| {
        untouched_rows(
            &g,
            &battery,
            UNTOUCHED_CASES,
            ESCAPES_LINE,
            GAUSS_MATHS,
            rep,
        )
    });
}
