//! `prepare_tex`: AMS equation numbering, `\label`, `\eqref` and `\ref`
//! resolution over the maths of a document, in document order.
//!
//! Two passes, as in the reference. Pass 1 walks the display maths in order:
//! a display that is exactly one unstarred numbered environment gets an
//! explicit `\tag{n}` per numbered row inside a starred environment, and
//! every `\label` it holds is taken out and registered under the row's tag (a
//! `multline` is one equation with one tag, deviation D7); any other display
//! only has its labels taken out, registered under its first explicit
//! `\tag`. Pass 2 walks every math, after all labels are known (so a
//! reference may come before the equation it names): `\eqref{k}` becomes
//! `\text{(v)}`, `\ref{k}` becomes `\text{v}`, any `\label{k}` left is
//! removed. Both passes read labels, tags and skip words only where the
//! engines see them (deviation D9).
//!
//! Every search here is a scan for a fixed prefix, then the first `}`: the
//! reference's `\\prefix\{[^}]*\}` regular expressions. A prefix with no `}`
//! after it matches nothing, and neither does any later one.
//!
//! Where this differs from the reference on purpose (deviations D2, D3 and D6
//! to D11):
//!
//! - D2: the reference looks environment names and label keys up in plain
//!   objects, so `constructor` or `valueOf` count as numbered environments
//!   and `__proto__` is not a label. Here the seven AMS names are a fixed
//!   table and the label keys are an ordinary map.
//! - D3: the tag text that `\ref` and `\eqref` copy is limited per call, not
//!   per tag. In the reference every reference copies the whole tag, so
//!   `$$x \tag{<T bytes>}\label{a}$$` with `R` inline `$\ref{a}$` after it
//!   grows to `R * T` bytes, quadratic in the source (a 1 MB cell would need
//!   28 GB). Here a reference prints its tag while the bytes copied so far
//!   plus this tag stay within [`REF_BUDGET_FACTOR`] times the TeX of all the
//!   maths plus [`REF_BUDGET_BASE`], and prints `??` (as for an unknown
//!   label) past it. A tag of any length is printed by the first references to
//!   it, exactly as in the reference; only a document whose references
//!   together copy more than the budget (more than 64 KiB of tag text and
//!   more than four times the TeX of its maths) sees `??` from the first
//!   reference that does not fit. The tag itself always stays in its display,
//!   and the output is at most a constant times the source plus the base.
//! - D6: the reference writes a numbered `eqnarray` as `align*` and a
//!   numbered `multline` as `gather*` for every engine. Those are KaTeX's
//!   stand-ins (KaTeX has neither environment), and [`prepare_tex`] keeps
//!   them: its output is the reference's and the KaTeX text. MathJax has
//!   `eqnarray*` and `multline*` and draws them with explicit tags as LaTeX
//!   draws the numbered environments (a `multline` staggered from the left
//!   margin to the right, an `eqnarray` aligned at its relation), where
//!   `gather*` centers every row and `align*` leaves a gap after each `=`.
//!   So the MathJax text ([`prepare_tex_for`] with [`Engine::MathJax`]) puts
//!   every numbered environment in its own starred form, but a `flalign` in
//!   the unstarred `flalign`: MathJax 3.2.2 refuses a `\tag` in `flalign*`
//!   ("\tag not allowed in flalign* environment"), so the reference's text of
//!   every numbered `flalign` was an error there, and it draws the unstarred
//!   environment with the same explicit tags as LaTeX draws it. An unstarred
//!   environment numbers the rows that have no tag itself when MathJax's own
//!   numbering is on, so in that text every row the numbering leaves without
//!   a tag ends with `\notag`, and it draws the same either way. KaTeX has
//!   neither form; its text keeps `flalign*`. Both texts come from one pass:
//!   the rows, tags and labels are the same, only the name of the
//!   environment and the `\notag`s differ, and the references of the MathJax
//!   text are resolved against a D3 budget of their own, so each text is
//!   exactly what the reference's code gives with that engine's table.
//! - D7: a numbered `multline` is one equation, as in amsmath. The reference
//!   numbers it row by row as if every row but the last had `\nonumber`: a
//!   `\label` before the last row is registered under no tag (every reference
//!   to it prints `??`), a `\tag` there stays in its row while the last row
//!   is numbered too (KaTeX draws two tags and numbers every later equation
//!   one too high; MathJax refuses `multline*` with "Multiple \tag"), and a
//!   `\nonumber` or `\notag` there leaves the equation numbered. Here
//!   (`number_multline`) the first `\tag{..}` or `\tag*{..}` of any row is
//!   the equation's tag; a `\nonumber` or `\notag` in any row means no
//!   number; otherwise the last row gets `\tag{n}`; every `\label` of every
//!   row is registered under that tag; and every tag of a row before the last
//!   is taken out of its row with its whole brace group and written at the
//!   end of the last row, where amsmath sets it (two tags meet there and are
//!   an error in both engines, as in LaTeX). Only what the engines see counts:
//!   a `\label`, `\tag`, `\nonumber` or `\notag` in a `%` comment or after an
//!   escaping backslash (`{a\\tag{T}}` is a line break and the text `tag`)
//!   does not. A tag whose group does not close in its row (a row with a
//!   stray `}`, an error in every engine) stays where it is, and so does
//!   every tag after it in that row, so the text never loses a brace. A
//!   `multline` whose labels, tags and skip words all stand in its last row,
//!   outside comments and not after a backslash, comes out as it would
//!   without D7. This holds for `prepared`, the KaTeX text and the MathJax
//!   text alike: the rows are written once.
//! - D8: what a reference prints for a tag is the tag's whole brace group
//!   (`shown_tag`). The reference copies its `\\tag\*?\{([^}]*)\}` reading,
//!   the text up to the first `}`, so a label on a tag with a group in it
//!   (`\tag{$x_{1}$}`, `\tag{I{a}}`) or an escaped brace made every `\eqref`
//!   of it `\text{($x_{1)}`, an error in both engines; with D7 that reaches
//!   the labels of every row of a `multline` too. Here the group is read as
//!   `group_end` reads it (a backslash takes the next byte with it), and a
//!   reference to a tag whose group does not close (only an unbalanced text
//!   has one, an error in every engine) prints `??`. Whether a row has a tag
//!   and whether it is empty, which decide its number, are read as the
//!   reference reads them.
//! - D9: the numbering reads the TeX as the engines see it (`Seen`: a
//!   backslash takes the next byte with it, a `%` hides the rest of its
//!   line), in every numbered environment, in a display that is none and in
//!   the labels left over. The reference read the raw text: it split rows at
//!   a `\\` inside a comment (and counted the braces there), so a step of a
//!   derivation commented out with `%` took a number of its own, its
//!   `\tag{n}` written into the comment where no engine draws it, and every
//!   later equation and reference was one too high; it read a `\label`,
//!   `\tag`, `\nonumber` or `\notag` in a comment (a commented `\nonumber`
//!   took the number away, a commented `\tag` replaced it, a commented label
//!   still resolved) or after an escaping backslash (`{u\\label{q}}`, a line
//!   break and text, lost `label{q}` and became the unbalanced `{u\}`). Here
//!   an environment is numbered only when the engines see its `\end`
//!   (`end_seen`: a comment on the body's last line hides it, an error in
//!   both engines, so the source goes on as it is); rows are split only at a
//!   `\\` the engines see, nothing in a comment counting (`split_rows`);
//!   a last row the engines see as empty is dropped, as the reference drops
//!   a blank one (`seen_empty`: white space and comments, after the
//!   argument `[..]` of the row break before it, which both engines drop);
//!   a `\label`, `\tag`, `\tag*`, `\nonumber` or `\notag` counts, and is
//!   taken out, only where the engines see it, and one they do not see stays
//!   as it is, in pass 2 too. Every row then ends before a `\\` the engines
//!   see or at the seen end of the body, so the `\tag{n}` written after it is
//!   always seen. A body with no `%` and no backslash before one of those
//!   commands, `\end` or the `[` of a row break comes out as it would
//!   without D9.
//! - D10: each row follows its row break directly (`JOIN`). The reference
//!   joined the rows with a blank after every `\\`, and neither engine looks
//!   past a blank for the argument of a row break, so a row-spacing argument
//!   `\\[4pt]` became `\\ [4pt]`, which both engines draw as the text `[4pt]`
//!   in the formula, and `\\*` became `\\ *`, a `*` MathJax draws. The row's
//!   own text is kept whole, so a bracket on the line after a `\\` stays the
//!   row's text, as in the source. Only blanks change for every other row,
//!   and the engines draw no blank in math.
//! - D11: a take-out never joins what it stood between (`Glue`). The
//!   reference took a `\label`, `\nonumber` or `\notag` out (and D7 a tag of
//!   a `multline` row) leaving nothing in its place, so a control word before
//!   it and a letter after it became one word (`\alpha\label{x}b` became the
//!   undefined `\alphab`, an error in both engines, where LaTeX draws alpha b;
//!   `\nonumber\label{x}b` lost its skip word to `\nonumberb`), and a row
//!   break before it took a `[` or `*` after it for its argument
//!   (`\\\label{x}[c, d]` became `\\[c, d]`, a spacing that is no length, an
//!   error in both engines, where the source draws `[c, d]`). Here a blank
//!   stands in the command's place exactly there: both engines end a control
//!   word at a blank and skip it, and neither reads a row break's argument
//!   after one. Every other take-out leaves nothing, as in the reference.
//!
//! The tags are kept once, shared by the labels of their row, so the memory
//! follows the source as well.

use std::borrow::Cow;
use std::collections::HashMap;
use std::ops::Range;
use std::rc::Rc;

use super::jsstr::js_trim;
use super::macros::Engine;
use super::Math;

/// What the numbered rows of an environment are.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Mode {
    /// The body is one numbered row (`equation`).
    Single,
    /// Every row split at a top-level `\\` is numbered.
    Rows,
    /// One equation over all its rows, numbered on the last (`multline`,
    /// deviation D7).
    Last,
}

/// The environments that are numbered, with the environment their numbered
/// form is written in: first the reference's, which is the KaTeX text, then
/// MathJax's (deviation D6). The reference writes `eqnarray` as `align*` and
/// `multline` as `gather*`, KaTeX's stand-ins for the two environments it
/// lacks; MathJax gets the starred form of every environment, `eqnarray*`
/// and `multline*` included, but `flalign` unstarred (it refuses a `\tag` in
/// `flalign*`), with `\notag` on every row left without a tag ([`NOTAG`]).
const NUMBERED: [(&str, Mode, &str, &str); 7] = [
    ("equation", Mode::Single, "equation*", "equation*"),
    ("align", Mode::Rows, "align*", "align*"),
    ("gather", Mode::Rows, "gather*", "gather*"),
    ("flalign", Mode::Rows, "flalign*", "flalign"),
    ("alignat", Mode::Rows, "alignat*", "alignat*"),
    ("eqnarray", Mode::Rows, "align*", "eqnarray*"),
    ("multline", Mode::Last, "gather*", "multline*"),
];

/// The starred environment `engine` is handed for one entry of [`NUMBERED`].
fn starred_for(engine: Engine, reference: &'static str, mathjax: &'static str) -> &'static str {
    match engine {
        Engine::Katex => reference,
        Engine::MathJax => mathjax,
    }
}

/// Deviation D3: the bytes of tag text that the references of one
/// [`prepare_tex`] call may copy are limited to this many times the TeX bytes
/// of all its maths, plus [`REF_BUDGET_BASE`].
pub const REF_BUDGET_FACTOR: usize = 4;

/// The part of the budget that does not depend on the size of the maths, so
/// that a small document with a long tag and a few references behaves as the
/// reference does.
pub const REF_BUDGET_BASE: usize = 64 * 1024;

/// Deviation D10: what is written between two numbered rows; the next row's
/// own text follows it directly, as in the source (the reference wrote a
/// blank after the `\\`).
const JOIN: &str = " \\\\";

/// Deviation D6: what ends a row the numbering leaves without a tag in an
/// environment MathJax is handed unstarred, which numbers such a row itself
/// when its own numbering is on.
const NOTAG: &str = " \\notag";

/// The tag a label refers to.
#[derive(Clone, Debug, PartialEq, Eq)]
enum Tag {
    /// The label's row has no tag: a reference to it prints `??`.
    Absent,
    /// The number the row was given.
    Num(usize),
    /// An explicit tag (empty for `\tag{}`), shared by the labels of the row.
    Text(Rc<str>),
}

/// The labels of a document by key; the keys are slices of the maths.
type Labels<'a> = HashMap<&'a str, Tag>;

/// Registers `key` for a row.
fn register<'a>(labels: &mut Labels<'a>, key: &'a str, tag: Tag) {
    labels.insert(key, tag);
}

/// The tag text that references may still copy (deviation D3).
struct Budget {
    left: usize,
}

impl Budget {
    fn new(total_tex_bytes: usize) -> Self {
        Budget {
            left: total_tex_bytes
                .saturating_mul(REF_BUDGET_FACTOR)
                .saturating_add(REF_BUDGET_BASE),
        }
    }

    /// Whether a copy of `n` bytes still fits; takes it from the budget when it does.
    fn take(&mut self, n: usize) -> bool {
        match self.left.checked_sub(n) {
            Some(rest) => {
                self.left = rest;
                true
            }
            None => false,
        }
    }
}

/// The TeX of every math after numbering and reference resolution: the
/// reference's text, which is also the text the KaTeX rule reads. The input is
/// every math of the document in order, display and inline; the output has
/// one string per input.
pub fn prepare_tex<'a, I: IntoIterator<Item = &'a Math>>(maths: I) -> Vec<String> {
    prepare(maths, Engine::Katex).text
}

/// [`prepare_tex`] for `engine`: the text [`super::MacroScope::next`] takes
/// for that engine. Under [`Engine::Katex`] it is [`prepare_tex`]; under
/// [`Engine::MathJax`] a numbered `eqnarray` and `multline` are written in
/// their own starred forms and a numbered `flalign` as `flalign` with
/// `\notag` on its rows without a tag (deviation D6).
pub fn prepare_tex_for<'a, I: IntoIterator<Item = &'a Math>>(
    maths: I,
    engine: Engine,
) -> Vec<String> {
    let Prepared { mut text, own } = prepare(maths, engine);
    for (i, t) in own {
        if let Some(slot) = text.get_mut(i) {
            *slot = t;
        }
    }
    text
}

/// The output of [`prepare`].
pub(crate) struct Prepared {
    /// [`prepare_tex`]: the reference's text of every math.
    pub(crate) text: Vec<String>,
    /// The engine's text of the maths where it differs from `text`, as
    /// (index, text) in increasing order of the index.
    pub(crate) own: Vec<(usize, String)>,
}

/// [`prepare_tex`] and, in the same pass, `engine`'s text where it differs
/// from it (deviation D6). The engine's text keeps a reference budget of its
/// own (deviation D3), so each of the two is exactly what the reference's code
/// gives with that table; while the two budgets agree, a math that is the
/// same in both is resolved once. A document with no numbered `eqnarray`,
/// `multline` or `flalign`, and every document under KaTeX, allocates nothing
/// for the engine's text.
pub(crate) fn prepare<'a, I: IntoIterator<Item = &'a Math>>(maths: I, engine: Engine) -> Prepared {
    let mut labels = Labels::new();
    let mut eq = 0usize;
    let mut total = 0usize;
    let mut pass1: Vec<Cow<'a, str>> = Vec::new();
    let mut variants: Vec<(usize, String)> = Vec::new();
    for m in maths {
        total = total.saturating_add(m.tex.len());
        let (t, own) = number_display(m, engine, &mut eq, &mut labels);
        if let Some(own) = own {
            variants.push((pass1.len(), own));
        }
        pass1.push(t);
    }
    let mut budget = Budget::new(total);
    let mut own_budget = Budget::new(total);
    let mut text = Vec::with_capacity(pass1.len());
    let mut own = Vec::new();
    let mut variants = variants.into_iter().peekable();
    for (i, t) in pass1.iter().enumerate() {
        let in_step = own_budget.left == budget.left;
        let r = resolve(t, &labels, &mut budget).into_owned();
        match variants.next_if(|(j, _)| *j == i) {
            Some((_, v)) => own.push((i, resolve(&v, &labels, &mut own_budget).into_owned())),
            None if in_step => own_budget.left = budget.left,
            None => {
                let o = resolve(t, &labels, &mut own_budget);
                if o != r.as_str() {
                    own.push((i, o.into_owned()));
                }
            }
        }
        text.push(r);
    }
    Prepared { text, own }
}

/// Pass 1 for one math: numbers a numbered environment, otherwise takes the
/// labels out of a display. An inline math is returned as it is. The second
/// value is `engine`'s text where its environment differs from the
/// reference's: the same rows in the engine's environment, each row left
/// without a tag ending with `\notag` when that environment is unstarred.
fn number_display<'a>(
    m: &'a Math,
    engine: Engine,
    eq: &mut usize,
    labels: &mut Labels<'a>,
) -> (Cow<'a, str>, Option<String>) {
    let t = m.tex.as_str();
    if !m.display {
        return (Cow::Borrowed(t), None);
    }
    if let Some((name, body)) = unstarred_env(t) {
        if let Some(&(_, mode, starred, mathjax)) = NUMBERED.iter().find(|e| e.0 == name) {
            // deviation D9: only an environment whose `\end` the engines see
            if end_seen(body.as_bytes()) {
                let engine_env = starred_for(engine, starred, mathjax);
                // deviation D6: an unstarred environment numbers a row without a
                // tag itself, so the engine's text gives each such row `\notag`
                let mut notags = Vec::new();
                let numbers_itself = !engine_env.ends_with('*');
                let (text, inner) = number_env(
                    body,
                    mode,
                    starred,
                    eq,
                    labels,
                    numbers_itself.then_some(&mut notags),
                );
                let own = (engine_env != starred).then(|| wrap(engine_env, &text, inner, &notags));
                return (Cow::Owned(text), own);
            }
        }
    }
    // Not a numbered environment: a `\label` only refers to an explicit `\tag`,
    // the first one the engines see (deviation D9), whose text is read once, at
    // the first label; each label the engines see is taken out without joining
    // what it stood between (deviation D11).
    let found = first_seen_tag(t);
    let mut tag: Option<Tag> = None;
    let mut seen = Seen::new(t);
    let mut glue = Glue::new(false);
    let text = replace_all_at(t, LABEL, |at, key, out| {
        if !seen.at(at) {
            push_label(out, key);
            return;
        }
        if glue.blank(t.as_bytes(), at, label_end(at, key)) {
            out.push(' ');
        }
        if let Some(m) = found {
            let tag = tag.get_or_insert_with(|| shown_tag(t, m));
            register(labels, key, tag.clone());
        }
    });
    (text.map_or(Cow::Borrowed(t), Cow::Owned), None)
}

/// The rows `text[inner]` inside the environment `env`, with [`NOTAG`] written
/// at each position of `notags` (positions in `text`, increasing, inside
/// `inner`).
fn wrap(env: &str, text: &str, inner: Range<usize>, notags: &[usize]) -> String {
    let mut out =
        String::with_capacity(inner.len() + 14 + 2 * env.len() + NOTAG.len() * notags.len());
    out.push_str("\\begin{");
    out.push_str(env);
    out.push('}');
    let mut copied = inner.start;
    for &at in notags {
        out.push_str(text.get(copied..at).unwrap_or_default());
        out.push_str(NOTAG);
        copied = at;
    }
    out.push_str(text.get(copied..inner.end).unwrap_or_default());
    out.push_str("\\end{");
    out.push_str(env);
    out.push('}');
    out
}

/// `^\\begin\{([A-Za-z]+)\}([\s\S]*)\\end\{\1\}$`: the name and the body of a
/// TeX that is one unstarred environment from its first byte to its last. A
/// starred name never matches (`\begin{align*}` is already numbered by hand).
fn unstarred_env(t: &str) -> Option<(&str, &str)> {
    let b = t.as_bytes();
    let letters = b.strip_prefix(b"\\begin{")?;
    let n = letters
        .iter()
        .take_while(|c| c.is_ascii_alphabetic())
        .count();
    if n == 0 || letters.get(n) != Some(&b'}') {
        return None;
    }
    let name = t.get(7..7 + n)?;
    let head = 7 + n + 1;
    // `\end{` name `}` at the very end, not overlapping the head.
    let tail = 5 + n + 1;
    let tail_start = b.len().checked_sub(tail)?;
    if tail_start < head {
        return None;
    }
    let end = b.get(tail_start..)?;
    if !end.starts_with(b"\\end{")
        || end.get(5..5 + n)? != name.as_bytes()
        || end.get(5 + n) != Some(&b'}')
    {
        return None;
    }
    Some((name, t.get(head..tail_start)?))
}

/// The numbered form of one environment body: its rows tagged and joined,
/// inside the starred environment, with the byte range of the rows (the text
/// between `\begin{starred}` and `\end{starred}`). With `notags`, the end of
/// every row the numbering leaves without a tag is pushed to it (deviation
/// D6; a `multline` has one equation and always a starred form).
fn number_env<'a>(
    body: &'a str,
    mode: Mode,
    starred: &str,
    eq: &mut usize,
    labels: &mut Labels<'a>,
    notags: Option<&mut Vec<usize>>,
) -> (String, Range<usize>) {
    let mut rows = if mode == Mode::Single {
        vec![body]
    } else {
        split_rows(body)
    };
    if rows.len() > 1 && rows.last().is_some_and(|r| seen_empty(r.as_bytes())) {
        rows.pop();
    }
    let mut out = String::with_capacity(body.len() + 32 + 2 * starred.len());
    out.push_str("\\begin{");
    out.push_str(starred);
    out.push('}');
    let inner_start = out.len();
    if mode == Mode::Last {
        number_multline(&rows, eq, labels, &mut out);
    } else {
        number_rows(&rows, eq, labels, &mut out, notags);
    }
    let inner = inner_start..out.len();
    out.push_str("\\end{");
    out.push_str(starred);
    out.push('}');
    (out, inner)
}

/// The rows of an environment numbered row by row (`equation` is one row),
/// joined, appended to `out`. Only what the engines see is read (deviation
/// D9), each row follows its row break directly (deviation D10), and nothing
/// taken out of a row joins what it stood between (deviation D11). With
/// `notags`, the end of every row left without a tag (a skip word and no
/// explicit tag) is pushed to it (deviation D6).
fn number_rows<'a>(
    rows: &[&'a str],
    eq: &mut usize,
    labels: &mut Labels<'a>,
    out: &mut String,
    mut notags: Option<&mut Vec<usize>>,
) {
    for (i, &row) in rows.iter().enumerate() {
        let after_break = i > 0;
        if after_break {
            out.push_str(JOIN);
        }
        // In this order: labels out, the first tag, whether the row is
        // skipped, the skip words out, the number when there is no tag.
        let mut keys: Vec<&'a str> = Vec::new();
        let row = take_seen_labels(row, &mut keys, after_break);
        let found = first_seen_tag(&row);
        let explicit = found.and_then(|m| captured(&row, m));
        let skip = first_seen_skip_word(row.as_bytes()).is_some();
        let numbered = !skip && explicit.is_none_or(str::is_empty);
        let tag = if numbered {
            Tag::Num(*eq + 1)
        } else if keys.is_empty() {
            Tag::Absent
        } else {
            found.map_or(Tag::Absent, |m| shown_tag(&row, m))
        };
        out.push_str(&remove_seen_skip_words(&row, after_break));
        push_number(out, eq, &tag);
        if !numbered && found.is_none() {
            if let Some(n) = notags.as_mut() {
                n.push(out.len());
            }
        }
        for key in keys {
            register(labels, key, tag.clone());
        }
    }
}

/// Deviation D7: the rows of a numbered `multline`, one equation, joined and
/// appended to `out` (the module doc has the rule). Each row is read in the
/// reference's order (labels out, the tag, the skip test, the skip words
/// out), every read through a [`Seen`], so only what the engines see counts
/// and is taken out (deviation D9); then the tags of a row before the last
/// move to the end of the last row, and the last row gets the number when the
/// equation has neither a tag nor a skip word. Nothing taken out of a row
/// joins what it stood between (deviation D11). Every `\label` is registered
/// under the equation's tag at the end, before any later math is read.
fn number_multline<'a>(
    rows: &[&'a str],
    eq: &mut usize,
    labels: &mut Labels<'a>,
    out: &mut String,
) {
    let last = rows.len().saturating_sub(1);
    let mut keys: Vec<&'a str> = Vec::new();
    // the equation's tag, from the first row that has one: its text as the
    // reference reads it (which decides the numbering) and what a reference
    // to it prints (deviation D8)
    let mut explicit: Option<(String, Tag)> = None;
    let mut skip = false;
    // the tags taken out of the rows before the last, each after a blank
    let mut moved = String::new();
    for (i, &row) in rows.iter().enumerate() {
        let after_break = i > 0;
        if after_break {
            out.push_str(JOIN);
        }
        let row = take_seen_labels(row, &mut keys, after_break);
        if explicit.is_none() {
            if let Some(t) = first_seen_tag(&row) {
                let text = captured(&row, t).unwrap_or_default().to_owned();
                explicit = Some((text, shown_tag(&row, t)));
            }
        }
        if !skip {
            skip = first_seen_skip_word(row.as_bytes()).is_some();
        }
        let row = remove_seen_skip_words(&row, after_break);
        if i == last {
            out.push_str(&row);
        } else {
            out.push_str(&take_tags(&row, &mut moved, after_break));
        }
    }
    out.push_str(&moved);
    let numbered = !skip && explicit.as_ref().is_none_or(|(text, _)| text.is_empty());
    let tag = if numbered {
        Tag::Num(*eq + 1)
    } else if keys.is_empty() {
        Tag::Absent
    } else {
        explicit.map_or(Tag::Absent, |(_, shown)| shown)
    };
    push_number(out, eq, &tag);
    for key in keys {
        register(labels, key, tag.clone());
    }
}

/// When `tag` is a number: takes it as the last number given and appends
/// ` \tag{n}` to `out`.
fn push_number(out: &mut String, eq: &mut usize, tag: &Tag) {
    if let Tag::Num(n) = *tag {
        *eq = n;
        out.push_str(" \\tag{");
        push_num(out, n);
        out.push('}');
    }
}

/// Deviations D7 and D9: whether the engines see a command that starts at a
/// byte of a text: the text is read from its start, a backslash takes the
/// next byte with it (`\\` is one token, so is `\%`) and a `%` hides the rest
/// of its line. Asked with increasing positions, it reads every byte at most once.
/// A position inside a multi-byte character is never asked: every command
/// starts with a backslash.
struct Seen<'t> {
    b: &'t [u8],
    i: usize,
}

impl<'t> Seen<'t> {
    fn new(t: &'t str) -> Self {
        Seen {
            b: t.as_bytes(),
            i: 0,
        }
    }

    /// Whether the reading lands on `at`: false when `at` is the byte after
    /// an escaping backslash or inside a comment.
    fn at(&mut self, at: usize) -> bool {
        while self.i < at {
            match self.b.get(self.i) {
                Some(b'\\') => self.i += 2,
                Some(b'%') => {
                    let rest = self.b.get(self.i..).unwrap_or_default();
                    self.i += rest.iter().position(|&c| c == b'\n').unwrap_or(rest.len());
                }
                Some(_) => self.i += 1,
                None => break,
            }
        }
        self.i == at
    }
}

/// Deviation D11: what the text before a take-out ends with, as far as taking
/// the command out could join it to the text after it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Tail {
    /// Nothing a take-out could join to what follows.
    Other,
    /// A control word: a letter after it would lengthen it.
    Word,
    /// A row break `\\`: a `[` or `*` after it would become its argument.
    Break,
}

/// Deviation D11: one pass of take-outs over a text, left to right, and for
/// each command taken out whether a blank must stand in its place, so that
/// the text before it and the text after it are read as they were. Linear:
/// only the text between two take-outs is read, once.
struct Glue {
    /// The end of the last command taken out.
    from: usize,
    tail: Tail,
}

impl Glue {
    /// A pass over a text that comes right after a row break (`after_break`:
    /// a row after the first) or after nothing a take-out could join.
    fn new(after_break: bool) -> Self {
        Glue {
            from: 0,
            tail: if after_break {
                Tail::Break
            } else {
                Tail::Other
            },
        }
    }

    /// The command `t[at..end]` is taken out: whether a blank stands in its
    /// place. Asked for every command taken out, in increasing order.
    fn blank(&mut self, t: &[u8], at: usize, end: usize) -> bool {
        if let Some(copied) = t.get(self.from..at).filter(|s| !s.is_empty()) {
            self.tail = tail_of(copied);
        }
        self.from = end;
        let blank = match (self.tail, t.get(end)) {
            (Tail::Word, Some(&c)) => is_control_word_byte(c),
            (Tail::Break, Some(&c)) => c == b'[' || c == b'*',
            _ => false,
        };
        if blank {
            self.tail = Tail::Other;
        }
        blank
    }
}

/// A byte that goes on a control word: an ASCII letter, or `@`, which KaTeX
/// reads as one.
fn is_control_word_byte(c: u8) -> bool {
    c.is_ascii_alphabetic() || c == b'@'
}

/// What `copied`, text copied whole between two take-outs, ends with: a
/// control word when its last bytes are letters after a backslash that starts
/// a command (an odd run of backslashes: in `\\alpha` the letters follow a
/// row break), a row break when it ends with an even run of backslashes. A
/// take-out starts where the engines see a command, so the text before it
/// ends between two tokens, and the runs are read within `copied` alone.
fn tail_of(copied: &[u8]) -> Tail {
    let letters = copied
        .iter()
        .rev()
        .take_while(|&&c| is_control_word_byte(c))
        .count();
    let before = copied
        .get(..copied.len().saturating_sub(letters))
        .unwrap_or_default();
    let slashes = before.iter().rev().take_while(|&&c| c == b'\\').count();
    if letters > 0 && slashes % 2 == 1 {
        Tail::Word
    } else if letters == 0 && slashes > 0 && slashes % 2 == 0 {
        Tail::Break
    } else {
        Tail::Other
    }
}

/// `\label{`, the prefix of every label.
const LABEL: &str = "\\label{";

/// The end of the label `\label{key}` that starts at `at`.
fn label_end(at: usize, key: &str) -> usize {
    at + LABEL.len() + key.len() + 1
}

/// Deviation D7: `row` with every tag the engines see taken out, each with
/// its whole brace group, and appended to `moved` after a blank. A tag whose
/// group does not close in the row stays, and so does every tag after it.
/// A tag taken out joins nothing (deviation D11; `after_break`: the row comes
/// after a row break). Borrows `row` when nothing moves. Linear: the groups
/// taken are disjoint, each search starts after the last match and the
/// reading only goes on.
fn take_tags<'r>(row: &'r str, moved: &mut String, after_break: bool) -> Cow<'r, str> {
    let mut seen = Seen::new(row);
    let mut glue = Glue::new(after_break);
    let mut kept: Option<String> = None;
    let (mut copied, mut from) = (0, 0);
    while let Some(t) = next_tag(row, from) {
        if !seen.at(t.at) {
            from = t.end;
            continue;
        }
        let Some(end) = group_end(row.as_bytes(), t.open) else {
            break;
        };
        moved.push(' ');
        moved.push_str(row.get(t.at..end).unwrap_or_default());
        let k = kept.get_or_insert_with(|| String::with_capacity(row.len()));
        k.push_str(row.get(copied..t.at).unwrap_or_default());
        if glue.blank(row.as_bytes(), t.at, end) {
            k.push(' ');
        }
        copied = end;
        from = end;
    }
    match kept {
        Some(mut k) => {
            k.push_str(row.get(copied..).unwrap_or_default());
            Cow::Owned(k)
        }
        None => Cow::Borrowed(row),
    }
}

/// The end (the byte after its `}`) of the brace group that opens at `open`,
/// a backslash taking the next byte with it as in [`split_rows`]; `None` when
/// it does not close.
fn group_end(b: &[u8], open: usize) -> Option<usize> {
    let mut depth = 0usize;
    let mut j = open;
    while let Some(&c) = b.get(j) {
        match c {
            b'\\' => {
                j += 2;
                continue;
            }
            b'{' => depth += 1,
            b'}' => {
                depth = depth.checked_sub(1)?;
                if depth == 0 {
                    return Some(j + 1);
                }
            }
            _ => {}
        }
        j += 1;
    }
    None
}

/// Appends the decimal digits of `n`.
fn push_num(out: &mut String, mut n: usize) {
    let mut digits = [b'0'; 20];
    let mut i = digits.len();
    loop {
        i = i.saturating_sub(1);
        if let Some(d) = digits.get_mut(i) {
            *d = b'0' + (n % 10) as u8;
        }
        n /= 10;
        if n == 0 || i == 0 {
            break;
        }
    }
    out.push_str(std::str::from_utf8(digits.get(i..).unwrap_or_default()).unwrap_or_default());
}

/// Splits an environment body at its top-level `\\`: not inside braces and
/// not inside a nested `\begin{..}...\end{..}`. A backslash takes the next
/// byte with it, so `\{`, `\}` and `\\` are never counted as braces or twice.
/// Deviation D9: a `%` hides the rest of its line, so nothing in a comment
/// counts (the reference split at a `\\` in a comment and counted its braces).
fn split_rows(body: &str) -> Vec<&str> {
    let b = body.as_bytes();
    let mut rows = Vec::new();
    let (mut depth, mut env, mut last) = (0i64, 0i64, 0usize);
    let mut i = 0;
    while i < b.len() {
        match b[i] {
            b'%' => {
                i = line_end(b, i);
                continue;
            }
            b'\\' => {
                let rest = &b[i..];
                if rest.starts_with(b"\\begin{") {
                    env += 1;
                } else if rest.starts_with(b"\\end{") {
                    env -= 1;
                } else if rest.get(1) == Some(&b'\\') && depth == 0 && env == 0 {
                    rows.push(body.get(last..i).unwrap_or_default());
                    last = i + 2;
                }
                i += 2;
                continue;
            }
            b'{' => depth += 1,
            b'}' => depth -= 1,
            _ => {}
        }
        i += 1;
    }
    rows.push(body.get(last..).unwrap_or_default());
    rows
}

/// Pass 2 for one math: `\eqref`, then `\ref`, then any `\label` left. Each
/// step works on the result of the one before. Borrows `t` when none of the
/// three occurs in it (a step can only match what an earlier step wrote if
/// that one matched), and allocates once per step that matched.
fn resolve<'a>(t: &'a str, labels: &Labels<'_>, budget: &mut Budget) -> Cow<'a, str> {
    if !mentions_reference(t.as_bytes()) {
        return Cow::Borrowed(t);
    }
    let mut cur: Cow<'a, str> = Cow::Borrowed(t);
    if let Some(s) = replace_all(&cur, "\\eqref{", |key, out| {
        out.push_str("\\text{(");
        push_tag(out, labels, budget, key);
        out.push_str(")}");
    }) {
        cur = Cow::Owned(s);
    }
    if let Some(s) = replace_all(&cur, "\\ref{", |key, out| {
        out.push_str("\\text{");
        push_tag(out, labels, budget, key);
        out.push('}');
    }) {
        cur = Cow::Owned(s);
    }
    // deviation D9: a label the engines do not see stays as it is; deviation
    // D11: one taken out joins nothing
    let text: &str = &cur;
    let mut seen = Seen::new(text);
    let mut glue = Glue::new(false);
    if let Some(s) = replace_all_at(text, LABEL, |at, key, out| {
        if !seen.at(at) {
            push_label(out, key);
        } else if glue.blank(text.as_bytes(), at, label_end(at, key)) {
            out.push(' ');
        }
    }) {
        cur = Cow::Owned(s);
    }
    cur
}

/// Whether `\eqref{`, `\ref{` or `\label{` occurs in `b`: one scan over the
/// backslashes.
fn mentions_reference(b: &[u8]) -> bool {
    let mut i = 0;
    while let Some(off) = b.get(i..).and_then(|r| r.iter().position(|&c| c == b'\\')) {
        let rest = b.get(i + off..).unwrap_or_default();
        if rest.starts_with(b"\\ref{")
            || rest.starts_with(b"\\eqref{")
            || rest.starts_with(b"\\label{")
        {
            return true;
        }
        i += off + 1;
    }
    false
}

/// Appends what a reference to `key` prints: its tag, `??` when the label is
/// unknown, its row had no tag or the budget for copied tag text is spent
/// (deviation D3), nothing for an empty tag.
fn push_tag(out: &mut String, labels: &Labels, budget: &mut Budget, key: &str) {
    match labels.get(key) {
        Some(Tag::Num(n)) => push_num(out, *n),
        Some(Tag::Text(t)) if budget.take(t.len()) => out.push_str(t),
        _ => out.push_str("??"),
    }
}

/// The first match of `prefix` `[^}]*` `}` at or after `from`, as the byte
/// offsets of the match start, of the text between prefix and brace, and of the
/// end of the match. `prefix` ends with `{`.
fn next_braced(t: &str, prefix: &str, from: usize) -> Option<(usize, usize, usize)> {
    let at = from + t.get(from..)?.find(prefix)?;
    let key = at + prefix.len();
    let close = key + t.get(key..)?.find('}')?;
    Some((at, key, close + 1))
}

/// Replaces every match of `prefix` `[^}]*` `}` (left to right, not
/// overlapping) with what `f` appends for the text between prefix and brace.
/// `None` when there is no match.
fn replace_all<'a>(
    t: &'a str,
    prefix: &str,
    mut f: impl FnMut(&'a str, &mut String),
) -> Option<String> {
    replace_all_at(t, prefix, |_, key, out| f(key, out))
}

/// [`replace_all`] with the start of each match given to `f` first.
fn replace_all_at<'a>(
    t: &'a str,
    prefix: &str,
    mut f: impl FnMut(usize, &'a str, &mut String),
) -> Option<String> {
    let mut m = next_braced(t, prefix, 0)?;
    let mut out = String::with_capacity(t.len());
    let mut copied = 0;
    loop {
        let (at, key, end) = m;
        out.push_str(t.get(copied..at).unwrap_or_default());
        f(at, t.get(key..end - 1).unwrap_or_default(), &mut out);
        copied = end;
        match next_braced(t, prefix, end) {
            Some(next) => m = next,
            None => break,
        }
    }
    out.push_str(t.get(copied..).unwrap_or_default());
    Some(out)
}

/// [`replace_all`], borrowing `t` when there is no match.
#[cfg(test)]
fn replace_braced<'a>(
    t: &'a str,
    prefix: &str,
    f: impl FnMut(&'a str, &mut String),
) -> Cow<'a, str> {
    match replace_all(t, prefix, f) {
        Some(s) => Cow::Owned(s),
        None => Cow::Borrowed(t),
    }
}

/// `\\tag\*?\{([^}]*)\}`: the text of the first `\tag{..}` or `\tag*{..}`.
/// It may be empty.
#[cfg(test)]
fn first_tag(t: &str) -> Option<&str> {
    captured(t, next_tag(t, 0)?)
}

/// The text of the tag `m` as the reference reads it, up to the first `}`
/// (`([^}]*)`): whether a row has a tag and whether it is empty, which decide
/// its number, are read from it.
fn captured(t: &str, m: TagMatch) -> Option<&str> {
    t.get(m.open + 1..m.end - 1)
}

/// Deviation D8: what a reference to a label prints for the tag `m` of `t`:
/// the text of the tag's whole brace group (a backslash takes the next byte
/// with it, as in [`group_end`]), or `??` ([`Tag::Absent`]) when the group
/// does not close. The reference copies its `[^}]*` reading, so a tag with a
/// group in it (`\tag{$x_{1}$}`) made every `\eqref` of it `\text{($x_{1)}`,
/// an error in both engines.
fn shown_tag(t: &str, m: TagMatch) -> Tag {
    match group_end(t.as_bytes(), m.open) {
        Some(end) => Tag::Text(Rc::from(t.get(m.open + 1..end - 1).unwrap_or_default())),
        None => Tag::Absent,
    }
}

/// One match of `\\tag\*?\{[^}]*\}`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct TagMatch {
    /// The backslash.
    at: usize,
    /// The `{`.
    open: usize,
    /// The byte after the first `}` after `open`.
    end: usize,
}

/// The leftmost match of `\\tag\*?\{[^}]*\}` that starts at or after
/// `from`. A `\tag{` with no `}` after it ends the search: no later one has
/// one either.
fn next_tag(t: &str, mut from: usize) -> Option<TagMatch> {
    let b = t.as_bytes();
    loop {
        let at = from + t.get(from..)?.find("\\tag")?;
        let mut j = at + 4;
        if b.get(j) == Some(&b'*') {
            j += 1;
        }
        if b.get(j) == Some(&b'{') {
            let close = j + 1 + t.get(j + 1..)?.find('}')?;
            return Some(TagMatch {
                at,
                open: j,
                end: close + 1,
            });
        }
        from = at + 1;
    }
}

/// A JavaScript word character (`\w` without the `u` flag).
fn is_word(c: u8) -> bool {
    c.is_ascii_alphanumeric() || c == b'_'
}

/// `\\(nonumber|notag)\b`: the leftmost `\nonumber` or `\notag` at or after
/// `from` that is not followed by a word character, as its start and end.
fn next_skip_word(b: &[u8], from: usize) -> Option<(usize, usize)> {
    let mut i = from;
    loop {
        let at = i + b.get(i..)?.iter().position(|&c| c == b'\\')?;
        let rest = b.get(at..)?;
        for word in [&b"\\nonumber"[..], &b"\\notag"[..]] {
            if rest.starts_with(word) {
                let end = at + word.len();
                if !b.get(end).is_some_and(|&c| is_word(c)) {
                    return Some((at, end));
                }
            }
        }
        i = at + 1;
    }
}

/// Deviation D9: the first `\nonumber` or `\notag` word the engines see, as
/// its start and end.
fn first_seen_skip_word(b: &[u8]) -> Option<(usize, usize)> {
    let mut seen = Seen { b, i: 0 };
    let mut from = 0;
    while let Some((at, end)) = next_skip_word(b, from) {
        if seen.at(at) {
            return Some((at, end));
        }
        from = end;
    }
    None
}

/// Every `\nonumber` and `\notag` word the engines see out of `row`; one in a
/// comment or after an escaping backslash stays (deviation D9). A word taken
/// out joins nothing (deviation D11; `after_break`: the row comes after a row
/// break). Borrows `row` when it takes nothing out.
fn remove_seen_skip_words(row: &str, after_break: bool) -> Cow<'_, str> {
    let b = row.as_bytes();
    let mut seen = Seen { b, i: 0 };
    let mut glue = Glue::new(after_break);
    let mut out: Option<String> = None;
    let (mut copied, mut from) = (0, 0);
    while let Some((at, end)) = next_skip_word(b, from) {
        from = end;
        if !seen.at(at) {
            continue;
        }
        let o = out.get_or_insert_with(|| String::with_capacity(row.len()));
        o.push_str(row.get(copied..at).unwrap_or_default());
        if glue.blank(b, at, end) {
            o.push(' ');
        }
        copied = end;
    }
    match out {
        Some(mut o) => {
            o.push_str(row.get(copied..).unwrap_or_default());
            Cow::Owned(o)
        }
        None => Cow::Borrowed(row),
    }
}

/// Deviation D9: `row` with every `\label{..}` the engines see taken out and
/// its key pushed to `keys`; a label in a comment or after an escaping
/// backslash stays as it is. A label taken out joins nothing (deviation D11;
/// `after_break`: the row comes after a row break). Borrows `row` when it
/// holds no label.
fn take_seen_labels<'a>(row: &'a str, keys: &mut Vec<&'a str>, after_break: bool) -> Cow<'a, str> {
    let mut seen = Seen::new(row);
    let mut glue = Glue::new(after_break);
    match replace_all_at(row, LABEL, |at, key, out| {
        if seen.at(at) {
            keys.push(key);
            if glue.blank(row.as_bytes(), at, label_end(at, key)) {
                out.push(' ');
            }
        } else {
            push_label(out, key);
        }
    }) {
        Some(s) => Cow::Owned(s),
        None => Cow::Borrowed(row),
    }
}

/// Appends `\label{key}`: a label the numbering leaves where it is.
fn push_label(out: &mut String, key: &str) {
    out.push_str(LABEL);
    out.push_str(key);
    out.push('}');
}

/// Deviation D9: the leftmost `\tag{..}` or `\tag*{..}` the engines see, read
/// as the reference reads a tag from there. A match the engines do not see is
/// passed whole, as a regular expression's next match starts after it.
fn first_seen_tag(t: &str) -> Option<TagMatch> {
    let mut seen = Seen::new(t);
    let mut from = 0;
    while let Some(m) = next_tag(t, from) {
        if seen.at(m.at) {
            return Some(m);
        }
        from = m.end;
    }
    None
}

/// The position of the line feed that ends the `%` comment at `pct`, or the
/// end of `b` when no line feed follows.
fn line_end(b: &[u8], pct: usize) -> usize {
    let rest = b.get(pct..).unwrap_or_default();
    pct + rest.iter().position(|&c| c == b'\n').unwrap_or(rest.len())
}

/// Deviation D9: whether the engines see the `\end{..}` right after `body`:
/// not when a `%` comment on the body's last line hides it or a backslash at
/// the body's end escapes its backslash. Both engines report such a source as
/// an error, so it is not numbered and goes on as it is.
fn end_seen(b: &[u8]) -> bool {
    let mut i = 0;
    while let Some(&c) = b.get(i) {
        match c {
            b'\\' => i += 2,
            b'%' => {
                i = line_end(b, i);
                if i == b.len() {
                    return false;
                }
            }
            _ => i += 1,
        }
    }
    i == b.len()
}

/// Deviation D9: whether the engines see a row as empty: after the argument
/// `[..]` of the row break before it (a `[` right after the `\\`, up to the
/// first `]` outside braces), only white space and comments. Both engines
/// drop such a last row; the reference dropped only a blank one, so a last
/// row that was a comment or a break's argument took a number.
fn seen_empty(b: &[u8]) -> bool {
    let mut i = 0;
    if b.first() == Some(&b'[') {
        match bracket_end(b) {
            Some(end) => i = end,
            None => return false,
        }
    }
    while i < b.len() {
        let rest = b.get(i..).unwrap_or_default();
        let pct = rest.iter().position(|&c| c == b'%').map(|p| i + p);
        if !js_trim(b.get(i..pct.unwrap_or(b.len())).unwrap_or_default()).is_empty() {
            return false;
        }
        match pct {
            Some(p) => i = line_end(b, p),
            None => return true,
        }
    }
    true
}

/// The end (the byte after its `]`) of the argument `[..]` at the start of
/// `b`, read as both engines read a row break's argument: up to the first `]`
/// outside braces, a backslash taking the next byte with it. `None` when it
/// does not close or a `}` closes a brace it did not open.
fn bracket_end(b: &[u8]) -> Option<usize> {
    let mut depth = 0usize;
    let mut j = 1;
    while let Some(&c) = b.get(j) {
        match c {
            b'\\' => j += 1,
            b'{' => depth += 1,
            b'}' => depth = depth.checked_sub(1)?,
            b']' if depth == 0 => return Some(j + 1),
            _ => {}
        }
        j += 1;
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Deviation D11: what the text before a take-out ends with, and whether a blank stands in a take-out's place.
    /// Every value was printed by the oracle's own `tailOf` and `takeOut` on the same input
    /// (`tests/mathgrammar/gen_cases.mjs`).
    #[test]
    fn a_take_out_never_joins_what_it_stood_between() {
        let tails: &[(&str, Tail)] = &[
            (r#"\alpha"#, Tail::Word),
            (r#"\\alpha"#, Tail::Other),
            (r#"\\\alpha"#, Tail::Word),
            (r#"x\alpha"#, Tail::Word),
            (r#"alpha"#, Tail::Other),
            (r#"\\"#, Tail::Break),
            (r#"a \\"#, Tail::Break),
            (r#"\\\\"#, Tail::Break),
            (r#"\"#, Tail::Other),
            (r#"\a@"#, Tail::Word),
            (r#"\,"#, Tail::Other),
            (r#"\alpha "#, Tail::Other),
            (r#"\alpha1"#, Tail::Other),
            (r#"}"#, Tail::Other),
            (r#"\\*"#, Tail::Other),
        ];
        for &(t, want) in tails {
            assert_eq!(tail_of(t.as_bytes()), want, "tail of {t:?}");
        }
        type Cuts<'a> = &'a [(usize, usize)];
        let passes: &[(&str, bool, Cuts, &[bool])] = &[
            (r#"\alpha\label{x}b"#, false, &[(6, 15)], &[true]),
            (
                r#"\alpha\label{x}\label{y}b"#,
                false,
                &[(6, 15), (15, 24)],
                &[false, true],
            ),
            (r#"\alpha\label{x}1"#, false, &[(6, 15)], &[false]),
            (r#"\label{x}[c]"#, true, &[(0, 9)], &[true]),
            (r#"\label{x}[c]"#, false, &[(0, 9)], &[false]),
            (
                r#"\label{x}\label{y}*c"#,
                true,
                &[(0, 9), (9, 18)],
                &[false, true],
            ),
            (r#"a\\\label{x}[c]"#, false, &[(3, 12)], &[true]),
            (
                r#"\beta\label{x}b\gamma\label{y}c"#,
                false,
                &[(5, 14), (21, 30)],
                &[true, true],
            ),
            (
                r#"\beta\label{x}b\label{y}c"#,
                false,
                &[(5, 14), (15, 24)],
                &[true, false],
            ),
            (r#"\alpha\label{x}"#, false, &[(6, 15)], &[false]),
        ];
        for &(t, after_break, cuts, want) in passes {
            let mut glue = Glue::new(after_break);
            let got: Vec<bool> = cuts
                .iter()
                .map(|&(at, end)| glue.blank(t.as_bytes(), at, end))
                .collect();
            assert_eq!(got, want, "take-outs {cuts:?} of {t:?}");
        }
    }

    #[test]
    fn env_is_one_unstarred_environment() {
        assert_eq!(
            unstarred_env(r"\begin{align}a\\b\end{align}"),
            Some(("align", r"a\\b"))
        );
        assert_eq!(unstarred_env(r"\begin{a}\end{a}"), Some(("a", "")));
        // nested names of the same letters: the end must be the very last bytes
        assert_eq!(
            unstarred_env(r"\begin{a}x\end{a}y\end{a}"),
            Some(("a", r"x\end{a}y"))
        );
        // starred, mismatched, trailing text, overlapping and non-ASCII names do not match
        assert_eq!(unstarred_env(r"\begin{align*}a\end{align*}"), None);
        assert_eq!(unstarred_env(r"\begin{align}a\end{gather}"), None);
        assert_eq!(unstarred_env(r"\begin{align}a\end{align}b"), None);
        assert_eq!(unstarred_env(r"\begin{align}a\end{align*}"), None);
        assert_eq!(unstarred_env(r"\begin{align}"), None);
        assert_eq!(unstarred_env(r"\begin{align}\end{alig}"), None);
        assert_eq!(unstarred_env(r"\begin{}\end{}"), None);
        assert_eq!(unstarred_env(r"\begin{a1}x\end{a1}"), None);
        assert_eq!(unstarred_env("\\begin{\u{e9}}x\\end{\u{e9}}"), None);
        assert_eq!(unstarred_env(r"\begin{align"), None);
        assert_eq!(unstarred_env(""), None);
    }

    #[test]
    fn rows_split_at_top_level_only() {
        assert_eq!(split_rows(r"a\\b"), ["a", "b"]);
        assert_eq!(split_rows("a"), ["a"]);
        assert_eq!(split_rows(r"a\\b\\"), ["a", "b", ""]);
        assert_eq!(split_rows(r"a\\\\b"), ["a", "", "b"]);
        assert_eq!(split_rows(r"{a\\b}\\c"), [r"{a\\b}", "c"]);
        // an escaped brace is not a brace
        assert_eq!(split_rows(r"a\{\\b"), [r"a\{", "b"]);
        assert_eq!(split_rows(r"a\}\\b"), [r"a\}", "b"]);
        // nested environments, including an unbalanced end, which keeps the count negative
        assert_eq!(
            split_rows(r"\begin{x}a\\b\end{x}\\c"),
            [r"\begin{x}a\\b\end{x}", "c"]
        );
        assert_eq!(split_rows(r"a\end{y}\\b"), [r"a\end{y}\\b"]);
        assert_eq!(split_rows(r"}\\a"), [r"}\\a"]);
        // a backslash before a multi-byte character takes only its lead byte
        assert_eq!(split_rows("\\\u{e9}\\\\b"), ["\\\u{e9}", "b"]);
        assert_eq!(split_rows("a\\"), ["a\\"]);
        assert_eq!(split_rows(""), [""]);
    }

    /// Deviation D9: the numbering reads a body as the engines see it. Every value was printed by the oracle's own
    /// helper on the same input (`splitRowsAsSeen`, `endSeen`, `emptyAsSeen`, `firstSeen`, `removeSeenLabels` and the
    /// label and skip-word steps of `rowsAsSeen` in `tests/mathgrammar/gen_cases.mjs`).
    #[test]
    fn rows_split_where_the_engines_see_a_break() {
        // nothing in a comment counts: a row break, a brace, an environment; an escaped % is no comment
        assert_eq!(split_rows("a % \\\\ b\n\\\\c"), ["a % \\\\ b\n", r#"c"#]);
        assert_eq!(split_rows("a % {\n\\\\b"), ["a % {\n", r#"b"#]);
        assert_eq!(split_rows("a %}\n\\\\b"), ["a %}\n", r#"b"#]);
        assert_eq!(split_rows(r#"a \% \\b"#), [r#"a \% "#, r#"b"#]);
        assert_eq!(
            split_rows("% \\begin{x}\n\\\\b"),
            ["% \\begin{x}\n", r#"b"#]
        );
        assert_eq!(
            split_rows(r#"a % no line feed \\b"#),
            [r#"a % no line feed \\b"#]
        );
        assert_eq!(split_rows("a\\\\% c \\\\\nd"), [r#"a"#, "% c \\\\\nd"]);
        assert_eq!(split_rows(r#"%"#), [r#"%"#]);
        assert_eq!(split_rows("{%}\n\\\\a}\\\\b"), ["{%}\n\\\\a}", r#"b"#]);
    }

    #[test]
    fn an_end_is_seen_unless_a_comment_or_a_backslash_hides_it() {
        assert!(end_seen(r#"a"#.as_bytes()));
        assert!(end_seen(r#""#.as_bytes()));
        assert!(end_seen("a % c\n".as_bytes()));
        assert!(!end_seen(r#"a % c"#.as_bytes()));
        assert!(end_seen(r#"a \% c"#.as_bytes()));
        assert!(end_seen(r#"a \\"#.as_bytes()));
        assert!(!end_seen(r#"a \"#.as_bytes()));
        assert!(!end_seen(r#"a \\\"#.as_bytes()));
        assert!(!end_seen(r#"%"#.as_bytes()));
        assert!(end_seen("a\n%\n".as_bytes()));
    }

    #[test]
    fn a_row_is_empty_when_the_engines_see_nothing_in_it() {
        // white space and comments, after the argument of the row break before it
        assert!(seen_empty(r#""#.as_bytes()));
        assert!(seen_empty(" \n".as_bytes()));
        assert!(seen_empty(" % c\n".as_bytes()));
        assert!(seen_empty(r#"% c"#.as_bytes()));
        assert!(seen_empty("% c\n % d\n ".as_bytes()));
        assert!(seen_empty("[2pt]\n".as_bytes()));
        assert!(seen_empty("[2pt] % x\n".as_bytes()));
        assert!(seen_empty("[{]}]\n".as_bytes()));
        assert!(!seen_empty("[a\n".as_bytes()));
        assert!(!seen_empty(r#"[a}]"#.as_bytes()));
        assert!(seen_empty(r#"[\]]"#.as_bytes()));
        assert!(!seen_empty(r#"\,"#.as_bytes()));
        assert!(!seen_empty(r#"x"#.as_bytes()));
        assert!(!seen_empty(r#" [2pt]"#.as_bytes()));
        assert!(!seen_empty(r#"[2pt]x"#.as_bytes()));
        assert!(!seen_empty(r#"\%"#.as_bytes()));
        assert!(!seen_empty("% c\nx".as_bytes()));
        assert!(seen_empty("\u{a0}% c\n\u{3000}".as_bytes()));
        assert!(seen_empty(r#"[]"#.as_bytes()));
        assert!(!seen_empty(r#"["#.as_bytes()));
    }

    #[test]
    fn labels_tags_and_skip_words_count_where_the_engines_see_them() {
        fn labels(s: &str) -> (String, Vec<&str>) {
            let mut keys = Vec::new();
            let row = take_seen_labels(s, &mut keys, false).into_owned();
            (row, keys)
        }
        fn tag(s: &str) -> Option<(usize, &str)> {
            first_seen_tag(s).map(|m| (m.at, captured(s, m).unwrap_or_default()))
        }
        assert_eq!(
            labels(r#"a\label{x} b"#),
            (r#"a b"#.to_string(), vec![r#"x"#])
        );
        assert_eq!(
            labels("a % \\label{x}\n\\label{y}"),
            ("a % \\label{x}\n".to_string(), vec![r#"y"#])
        );
        assert_eq!(
            labels(r#"{u\\label{q}} \label{r}"#),
            (r#"{u\\label{q}} "#.to_string(), vec![r#"r"#])
        );
        assert_eq!(
            labels(r#"\\\label{s}"#),
            (r#"\\"#.to_string(), vec![r#"s"#])
        );
        assert_eq!(
            labels(r#"\%\label{t}"#),
            (r#"\%"#.to_string(), vec![r#"t"#])
        );
        assert_eq!(
            labels("% \\label{a\n\\label{b}"),
            ("% \\label{a\n\\label{b}".to_string(), vec![])
        );
        assert_eq!(
            remove_seen_skip_words(r#"a\nonumber b\notag"#, false),
            r#"a b"#
        );
        assert_eq!(
            remove_seen_skip_words("a % \\nonumber\n\\notag", false),
            "a % \\nonumber\n"
        );
        assert_eq!(
            remove_seen_skip_words(r#"{v\\nonumber} \notag"#, false),
            r#"{v\\nonumber} "#
        );
        assert_eq!(
            remove_seen_skip_words(r#"\nonumberx \notag_ % \notag"#, false),
            r#"\nonumberx \notag_ % \notag"#
        );
        assert_eq!(remove_seen_skip_words(r#"\%\nonumber"#, false), r#"\%"#);
        assert!(matches!(
            remove_seen_skip_words(r"a % \nonumber", false),
            Cow::Borrowed(_)
        ));
        assert_eq!(tag(r#"a\tag{A}"#), Some((1, r#"A"#)));
        assert_eq!(tag("% \\tag{C}\n\\tag{D}"), Some((10, r#"D"#)));
        assert_eq!(tag(r#"{u\\tag{E}} \tag*{F}"#), Some((12, r#"F"#)));
        assert_eq!(tag("% \\tag{G\n\\tag{H}"), None);
        assert_eq!(tag(r#"\%\tag{P}"#), Some((2, r#"P"#)));
        assert_eq!(tag(r#"% \tag{I}"#), None);
        assert_eq!(
            first_seen_skip_word("% \\nonumber\n\\notag".as_bytes()).map(|w| w.0),
            Some(12)
        );
        assert_eq!(
            first_seen_skip_word(r#"\\notag \nonumber"#.as_bytes()).map(|w| w.0),
            Some(8)
        );
        assert_eq!(first_seen_skip_word(r#"% \notag"#.as_bytes()), None);
        assert_eq!(
            first_seen_skip_word(r#"\notagx \notag"#.as_bytes()).map(|w| w.0),
            Some(8)
        );
        // the labels left over: one the engines do not see stays
        let labels = Labels::new();
        let mut b = Budget::new(0);
        assert_eq!(resolve(r#"a\label{x}b"#, &labels, &mut b), r#"ab"#);
        assert_eq!(
            resolve(r#"a\\label{x}b"#, &labels, &mut b),
            r#"a\\label{x}b"#
        );
        assert_eq!(
            resolve("a % \\label{x}\nb\\label{y}", &labels, &mut b),
            "a % \\label{x}\nb"
        );
    }

    #[test]
    fn first_tag_is_the_leftmost_complete_tag() {
        assert_eq!(first_tag(r"a\tag{A}"), Some("A"));
        assert_eq!(first_tag(r"a\tag*{B}"), Some("B"));
        assert_eq!(first_tag(r"a\tag{}"), Some(""));
        assert_eq!(first_tag(r"\tag{X}\tag{Y}"), Some("X"));
        assert_eq!(first_tag(r"\tagx{A}\tag{B}"), Some("B"));
        assert_eq!(first_tag(r"\tag*x \tag{C}"), Some("C"));
        assert_eq!(first_tag(r"\\tag{D}"), Some("D"));
        assert_eq!(first_tag(r"\tag{a{b}c}"), Some("a{b"));
        assert_eq!(first_tag("\\tag{a\nb}"), Some("a\nb"));
        // no closing brace: nothing, and no later tag can match either
        assert_eq!(first_tag(r"\tag{A"), None);
        assert_eq!(first_tag(r"\tag**{A}"), None);
        assert_eq!(first_tag(r"\tag"), None);
        assert_eq!(first_tag(r"\tag*"), None);
        assert_eq!(first_tag(""), None);
    }

    #[test]
    fn tags_are_found_left_to_right_from_a_position() {
        let m = |t: &str, from: usize| next_tag(t, from).map(|m| (m.at, m.open, m.end));
        assert_eq!(m(r"a\tag{A}", 0), Some((1, 5, 8)));
        assert_eq!(m(r"\tag*{B}", 0), Some((0, 5, 8)));
        assert_eq!(m(r"\tag{A}\tag{B}", 1), Some((7, 11, 14)));
        // the reference's reading: the first `}` ends the match
        assert_eq!(m(r"\tag{a{b}c}", 0), Some((0, 4, 9)));
        assert_eq!(m(r"\tag{A", 0), None);
        assert_eq!(m(r"\tag{A}", 7), None);
        assert_eq!(m(r"\tag{A}", 8), None);
    }

    /// Deviation D7: what the engines see, read once from the start.
    #[test]
    fn seen_reads_escapes_and_comments_as_the_engines_do() {
        let at = |t: &str, ps: &[usize]| -> Vec<bool> {
            let mut s = Seen::new(t);
            ps.iter().map(|&p| s.at(p)).collect()
        };
        assert_eq!(at(r"a\tag{x}", &[1]), [true]);
        // after an escaping backslash the byte belongs to `\\`; after two, a command starts
        assert_eq!(at(r"\\tag{x}", &[1]), [false]);
        assert_eq!(at(r"\\\tag{x}", &[2]), [true]);
        // a comment hides the rest of its line, the next line is seen; with no line end, the rest of the text
        assert_eq!(at("a % \\tag{x}\n\\tag{y}", &[4, 12]), [false, true]);
        assert_eq!(at("%\\tag{x}", &[1]), [false]);
        // an escaped % starts no comment
        assert_eq!(at(r"\%\tag{x}", &[2]), [true]);
        // asked in order, the reading goes on from where it stopped
        assert_eq!(
            at(r"\tag{a}\\tag{b}\tag{c}", &[0, 8, 15]),
            [true, false, true]
        );
        // a backslash before a multi-byte character takes its lead byte; the next command is still seen
        assert_eq!(at("\\\u{e9}\\tag{x}", &[3]), [true]);
    }

    #[test]
    fn a_group_ends_at_its_matching_brace() {
        assert_eq!(group_end(b"{a}", 0), Some(3));
        assert_eq!(group_end(b"{a{b}c}d", 0), Some(7));
        // escaped braces are not braces
        assert_eq!(group_end(br"{a\}b}", 0), Some(6));
        assert_eq!(group_end(br"{a\{b}", 0), Some(6));
        assert_eq!(group_end(br"{a\", 0), None);
        assert_eq!(group_end(b"{a{b}", 0), None);
        assert_eq!(group_end(b"", 0), None);
    }

    /// Deviation D7: the tags of a row before the last of a `multline`.
    #[test]
    fn tags_seen_move_with_their_whole_group() {
        let take = |row: &str| {
            let mut moved = String::new();
            let kept = take_tags(row, &mut moved, false).into_owned();
            (kept, moved)
        };
        let pair = |a: &str, b: &str| (a.to_owned(), b.to_owned());
        assert_eq!(take(r"a \tag{A} b"), pair("a  b", r" \tag{A}"));
        assert_eq!(
            take(r"\tag*{$x_{1}$}a\tag{B}"),
            pair("a", r" \tag*{$x_{1}$} \tag{B}")
        );
        // not seen: in a comment, after an escaping backslash
        assert_eq!(
            take("a % \\tag{C}\nb {u\\\\tag{E}}"),
            pair("a % \\tag{C}\nb {u\\\\tag{E}}", "")
        );
        // a group that does not close stays, with every tag after it
        assert_eq!(
            take(r"\tag{A} } \tag{a{b} \tag{Z}"),
            pair(r" } \tag{a{b} \tag{Z}", r" \tag{A}")
        );
        // nothing moves: the row is borrowed
        let mut moved = String::new();
        assert!(matches!(
            take_tags("a b", &mut moved, false),
            Cow::Borrowed("a b")
        ));
    }

    /// Deviation D8: what a reference prints for a tag; the reference's own reading, which decides the number, stays.
    #[test]
    fn a_tag_is_shown_as_its_whole_group() {
        let shown = |t: &str| match next_tag(t, 0).map(|m| shown_tag(t, m)) {
            Some(Tag::Text(s)) => Some(s.to_string()),
            Some(Tag::Absent) => Some("??".to_string()),
            _ => None,
        };
        assert_eq!(shown(r"\tag{A}"), Some("A".into()));
        assert_eq!(shown(r"\tag*{$x_{1}$}"), Some("$x_{1}$".into()));
        assert_eq!(shown(r"\tag{a\}b}"), Some(r"a\}b".into()));
        assert_eq!(shown(r"\tag{}"), Some(String::new()));
        // a group that does not close: a reference prints ??
        assert_eq!(shown(r"\tag{a{b} c"), Some("??".into()));
        assert_eq!(shown(r"\tag{A"), None);
        assert_eq!(first_tag(r"\tag{a{b}c}"), Some("a{b"));
        assert_eq!(first_tag(r"\tag{a\}b}"), Some(r"a\"));
    }

    #[test]
    fn skip_words_end_at_a_word_boundary() {
        let find = |s: &str| next_skip_word(s.as_bytes(), 0);
        assert_eq!(find(r"a\nonumber"), Some((1, 10)));
        assert_eq!(find(r"a\notag b"), Some((1, 7)));
        assert_eq!(find(r"\nonumber\notag"), Some((0, 9)));
        // a word character after the word continues it
        assert_eq!(find(r"\nonumberx"), None);
        assert_eq!(find(r"\nonumber_"), None);
        assert_eq!(find(r"\nonumber1"), None);
        assert_eq!(find(r"\notagA"), None);
        // anything else ends it, a non-ASCII letter included
        assert_eq!(find(r"\nonumber\label"), Some((0, 9)));
        assert_eq!(find("\\notag\u{e9}"), Some((0, 6)));
        assert_eq!(find(r"\nonumberx \notag"), Some((11, 17)));
        assert_eq!(find(r"\nonumbe"), None);
        assert_eq!(find(r"\no"), None);
        assert_eq!(find(""), None);
        let removed = |s: &str| remove_seen_skip_words(s, false).into_owned();
        assert_eq!(removed(r"a\nonumber b\notag\nonumber"), "a b");
        assert_eq!(removed(r"a\nonumberx"), r"a\nonumberx");
        assert_eq!(removed("\\nonumber\u{e9}"), "\u{e9}");
        assert!(matches!(
            remove_seen_skip_words(r"a\nonumberx", false),
            Cow::Borrowed(_)
        ));
    }

    #[test]
    fn braced_replacement_needs_a_closing_brace() {
        fn rep(s: &str) -> Cow<'_, str> {
            replace_braced(s, "\\label{", |k, out| out.push_str(&k.to_uppercase()))
        }
        assert_eq!(rep(r"a\label{x}b\label{y}c"), "aXbYc");
        assert_eq!(rep(r"\label{}"), "");
        // the key may hold a brace or a line break
        assert_eq!(rep("\\label{a{b}c}"), "A{Bc}");
        assert_eq!(rep("\\label{a\nb}"), "A\nB");
        // no closing brace: borrowed, unchanged; an earlier match still counts
        assert!(matches!(rep(r"a\label{x"), Cow::Borrowed(_)));
        assert!(matches!(rep(r"a\label"), Cow::Borrowed(_)));
        assert_eq!(rep(r"\label{x}\label{y"), r"X\label{y");
        assert_eq!(rep("\\label{\u{e9}}\u{e9}"), "\u{c9}\u{e9}");
    }

    #[test]
    fn references_print_the_tag_of_their_label() {
        let mut labels = Labels::new();
        labels.insert("a", Tag::Num(1));
        labels.insert("e", Tag::Text(Rc::from("")));
        labels.insert("n", Tag::Absent);
        let mut b = Budget::new(0);
        assert_eq!(
            resolve(r"\eqref{a} \ref{a} \label{a}", &labels, &mut b),
            r"\text{(1)} \text{1} "
        );
        assert_eq!(
            resolve(r"\ref{e}\eqref{e}", &labels, &mut b),
            r"\text{}\text{()}"
        );
        assert_eq!(
            resolve(r"\ref{n} \eqref{n} \ref{zz}", &labels, &mut b),
            r"\text{??} \text{(??)} \text{??}"
        );
        // each replacement works on the result of the one before: `\eqref{t}` leaves `\ref{a)}`
        labels.insert("t", Tag::Text(Rc::from(r"\ref{a")));
        labels.insert("a)", Tag::Num(1));
        assert_eq!(resolve(r"\eqref{t}", &labels, &mut b), r"\text{(\text{1}");
        // nothing to resolve: borrowed, and a step that finds nothing does not copy
        assert!(matches!(
            resolve(r"x^2 \tag{1}", &labels, &mut b),
            Cow::Borrowed(_)
        ));
        assert!(matches!(
            resolve(r"\reference{a}", &labels, &mut b),
            Cow::Borrowed(_)
        ));
        assert!(matches!(
            resolve(r"\ref{a", &labels, &mut b),
            Cow::Borrowed(_)
        ));
    }

    #[test]
    fn numbers_are_written_in_decimal() {
        for n in [0usize, 1, 9, 10, 99, 100, 12345, usize::MAX] {
            let mut s = String::new();
            push_num(&mut s, n);
            assert_eq!(s, n.to_string());
        }
    }

    /// The Math values of a display with an explicit tag and its label, then
    /// one inline math per reference text.
    fn tag_doc(tag: &str, refs: &[&str]) -> Vec<Math> {
        let mut maths = vec![Math {
            tex: format!("x \\tag{{{tag}}}\\label{{k}}"),
            raw: String::new(),
            display: true,
            block: true,
            kind: crate::mathgrammar::Kind::Dollars,
        }];
        for r in refs {
            maths.push(Math {
                tex: (*r).to_string(),
                raw: String::new(),
                display: false,
                block: false,
                kind: crate::mathgrammar::Kind::Paren,
            });
        }
        maths
    }

    /// Deviation D3: a tag of any length is copied into the references that
    /// fit the budget, exactly as the reference does, and the tag stays in
    /// its display.
    #[test]
    fn long_tags_are_copied_while_the_budget_lasts() {
        for len in [1usize, 64, 65, 1000, 20_000] {
            let tag = "x".repeat(len);
            let maths = tag_doc(&tag, &[r"\ref{k}", r"\eqref{k}", r"\ref{k}"]);
            let out = prepare_tex(maths.iter());
            assert_eq!(out[0], format!("x \\tag{{{tag}}}"), "display, tag of {len}");
            assert_eq!(out[1], format!("\\text{{{tag}}}"), "\\ref, tag of {len}");
            assert_eq!(
                out[2],
                format!("\\text{{({tag})}}"),
                "\\eqref, tag of {len}"
            );
            assert_eq!(
                out[3],
                format!("\\text{{{tag}}}"),
                "second \\ref, tag of {len}"
            );
        }
    }

    /// Past the budget a reference prints `??`, the budget is shared by all
    /// references of the call, a tag that does not fit does not stop a
    /// shorter one, and numbers and empty tags never use it.
    #[test]
    fn references_past_the_budget_print_question_marks() {
        let tag = "x".repeat(REF_BUDGET_BASE);
        // a tag as long as the base: only a few copies fit, the rest do not
        let refs = vec![r"\ref{k}"; 12];
        let maths = tag_doc(&tag, &refs);
        let total: usize = maths.iter().map(|m| m.tex.len()).sum();
        let fit = (REF_BUDGET_FACTOR * total + REF_BUDGET_BASE) / tag.len();
        assert!(fit >= 1 && fit < refs.len(), "{fit} copies fit");
        let out = prepare_tex(maths.iter());
        for (i, o) in out.iter().enumerate().skip(1) {
            if i <= fit {
                assert_eq!(*o, format!("\\text{{{tag}}}"), "reference {i} fits");
            } else {
                assert_eq!(o, "\\text{??}", "reference {i} is past the budget");
            }
        }
        // the copied bytes never pass the budget, however many references follow
        let copied: usize = out
            .iter()
            .skip(1)
            .filter(|o| o.len() > 20)
            .map(String::len)
            .sum();
        assert!(copied <= REF_BUDGET_FACTOR * total + REF_BUDGET_BASE + 8 * fit);
        // a short tag after the budget is spent still prints; the long one prints ??
        let mut maths = tag_doc(&tag, &refs);
        maths.push(Math {
            tex: "y \\tag{T}\\label{s}".to_string(),
            raw: String::new(),
            display: true,
            block: true,
            kind: crate::mathgrammar::Kind::Dollars,
        });
        maths.push(Math {
            tex: r"\ref{s} \ref{k}".to_string(),
            raw: String::new(),
            display: false,
            block: false,
            kind: crate::mathgrammar::Kind::Paren,
        });
        let out = prepare_tex(maths.iter());
        assert_eq!(out.last().map(String::as_str), Some(r"\text{T} \text{??}"));
    }

    /// A display with an explicit tag and its label.
    fn tagged(tag: &str, label: &str) -> Math {
        Math {
            tex: format!("x \\tag{{{tag}}}\\label{{{label}}}"),
            raw: String::new(),
            display: true,
            block: true,
            kind: crate::mathgrammar::Kind::Dollars,
        }
    }

    /// An inline math.
    fn inline(tex: &str) -> Math {
        Math {
            tex: tex.to_string(),
            raw: String::new(),
            display: false,
            block: false,
            kind: crate::mathgrammar::Kind::Paren,
        }
    }

    /// The budget is used up to the last byte: a tag that is exactly what is
    /// left is copied whole (`Budget::take` accepts an exact fit), and with
    /// nothing left a reference to a numbered equation and one to an empty
    /// tag still print (a number and an empty tag never use the budget),
    /// where a reference to a tag of any length prints `??`.
    #[test]
    fn a_tag_that_fits_the_budget_exactly_is_copied() {
        const COPIES: usize = 8;
        let doc = |t1: &str, t2: &str| {
            let mut maths = vec![
                tagged(t1, "a"),
                tagged(t2, "b"),
                Math {
                    tex: "\\begin{equation}n\\label{n}\\end{equation}".to_string(),
                    ..tagged("", "")
                },
                tagged("", "e"),
            ];
            maths.extend((0..COPIES).map(|_| inline(r"\ref{a}")));
            for r in [
                r"\ref{b}",
                r"\ref{n}",
                r"\eqref{n}",
                r"\ref{e}",
                r"\eqref{e}",
                r"\ref{b}",
                r"\ref{a}",
                r"\eqref{a}",
                r"\ref{e}",
            ] {
                maths.push(inline(r));
            }
            maths
        };
        let total = |maths: &[Math]| maths.iter().map(|m| m.tex.len()).sum::<usize>();
        // COPIES copies of the first tag leave exactly the second tag's length of the budget:
        // L2 = F (base + L1 + L2) + BASE - COPIES * L1, with the TeX counted in the budget
        // growing with both tags
        let base = total(&doc("", ""));
        let (f, c) = (REF_BUDGET_FACTOR, COPIES);
        let (l1, l2) = (30_000..30_003)
            .find_map(|l1| {
                let num = (c - f) * l1;
                let num = num.checked_sub(f * base + REF_BUDGET_BASE)?;
                (num % (f - 1) == 0).then_some((l1, num / (f - 1)))
            })
            .expect("a tag length that makes the fit exact");
        let (t1, t2) = ("a".repeat(l1), "b".repeat(l2));
        let maths = doc(&t1, &t2);
        let budget = REF_BUDGET_FACTOR * total(&maths) + REF_BUDGET_BASE;
        assert_eq!(budget - COPIES * l1, l2, "the second tag is what is left");
        let out = prepare_tex(maths.iter());
        for (i, o) in out[4..4 + COPIES].iter().enumerate() {
            assert_eq!(*o, format!("\\text{{{t1}}}"), "copy {i} of the first tag");
        }
        let after = &out[4 + COPIES..];
        assert_eq!(
            after[0],
            format!("\\text{{{t2}}}"),
            "the exact fit is copied"
        );
        assert_eq!(after[1], r"\text{1}", "a number needs no budget");
        assert_eq!(after[2], r"\text{(1)}");
        assert_eq!(after[3], r"\text{}", "an empty tag needs no budget");
        assert_eq!(after[4], r"\text{()}");
        assert_eq!(
            after[5], r"\text{??}",
            "nothing is left for the same tag again"
        );
        assert_eq!(after[6], r"\text{??}");
        assert_eq!(after[7], r"\text{(??)}");
        assert_eq!(after[8], r"\text{}", "and an empty tag still prints");
    }

    /// The tag text of a row is stored once however many labels the row has.
    #[test]
    fn labels_of_one_row_share_their_tag() {
        let mut labels = Labels::new();
        let row = r"x \tag{abc}";
        let tag = next_tag(row, 0).map_or(Tag::Absent, |m| shown_tag(row, m));
        register(&mut labels, "a", tag.clone());
        register(&mut labels, "b", tag.clone());
        match (labels.get("a"), labels.get("b")) {
            (Some(Tag::Text(x)), Some(Tag::Text(y))) => assert!(Rc::ptr_eq(x, y)),
            other => panic!("not shared: {other:?}"),
        }
    }
    /// One math of a document, display or inline.
    fn math(tex: &str, display: bool) -> Math {
        Math {
            tex: tex.to_string(),
            raw: String::new(),
            display,
            block: display,
            kind: if display {
                crate::mathgrammar::Kind::Dollars
            } else {
                crate::mathgrammar::Kind::Dollar
            },
        }
    }

    /// Deviation D6: every numbered environment in its own starred form for MathJax (but `flalign` unstarred, which
    /// MathJax draws with a `\tag`), the reference's forms (`align*` for `eqnarray`, `gather*` for `multline`,
    /// `flalign*`) for KaTeX and in `prepare_tex`. The texts are
    /// `node tests/mathgrammar/gen_cases.mjs json --doc`'s `prepared`, `katex` and `mathjax` for the same
    /// source (`$$..$$` displays and `$..$` inlines); each row follows its `\\` directly (deviation D10).
    #[test]
    fn each_engine_gets_its_starred_forms() {
        let maths = [
            math(r"\begin{equation}a\label{e}\end{equation}", true),
            math(r"\begin{align}b\\c\end{align}", true),
            math(r"\begin{gather}d\end{gather}", true),
            math(r"\begin{flalign}e\end{flalign}", true),
            math(r"\begin{alignat}{2}f\end{alignat}", true),
            math(r"\begin{eqnarray}g\\h\label{q}\end{eqnarray}", true),
            math(r"\begin{multline}i\\j\end{multline}", true),
            math(r"\eqref{q}", false),
            math(r"\ref{e}", false),
        ];
        let reference = [
            r"\begin{equation*}a \tag{1}\end{equation*}",
            r"\begin{align*}b \tag{2} \\c \tag{3}\end{align*}",
            r"\begin{gather*}d \tag{4}\end{gather*}",
            r"\begin{flalign*}e \tag{5}\end{flalign*}",
            r"\begin{alignat*}{2}f \tag{6}\end{alignat*}",
            r"\begin{align*}g \tag{7} \\h \tag{8}\end{align*}",
            r"\begin{gather*}i \\j \tag{9}\end{gather*}",
            r"\text{(8)}",
            r"\text{1}",
        ];
        let mathjax = [
            r"\begin{equation*}a \tag{1}\end{equation*}",
            r"\begin{align*}b \tag{2} \\c \tag{3}\end{align*}",
            r"\begin{gather*}d \tag{4}\end{gather*}",
            r"\begin{flalign}e \tag{5}\end{flalign}",
            r"\begin{alignat*}{2}f \tag{6}\end{alignat*}",
            r"\begin{eqnarray*}g \tag{7} \\h \tag{8}\end{eqnarray*}",
            r"\begin{multline*}i \\j \tag{9}\end{multline*}",
            r"\text{(8)}",
            r"\text{1}",
        ];
        assert_eq!(prepare_tex(maths.iter()), reference);
        assert_eq!(prepare_tex_for(maths.iter(), Engine::Katex), reference);
        assert_eq!(prepare_tex_for(maths.iter(), Engine::MathJax), mathjax);
        // one pass gives both, and the engine's text only where it differs
        let p = prepare(maths.iter(), Engine::MathJax);
        assert_eq!(p.text, reference);
        let differs: Vec<usize> = p.own.iter().map(|(i, _)| *i).collect();
        assert_eq!(differs, [3, 5, 6]);
        let p = prepare(maths.iter(), Engine::Katex);
        assert_eq!(p.text, reference);
        assert!(p.own.is_empty());
        // numbering that restarts per source: the same forms on each source's maths alone
        assert_eq!(
            prepare_tex_for(maths[5..7].iter(), Engine::MathJax),
            [
                r"\begin{eqnarray*}g \tag{1} \\h \tag{2}\end{eqnarray*}",
                r"\begin{multline*}i \\j \tag{3}\end{multline*}",
            ]
        );
    }

    /// Deviation D3 for the MathJax text: its references copy tag text within a budget of their own, so the
    /// reference's text never changes when the MathJax text is made, and the MathJax text is what the
    /// reference's code gives with MathJax's forms. A reference whose key runs into the end of the environment
    /// (an unclosed `\ref{` in a last row without a tag) names `k\end{gather*` in the reference's text and
    /// `k\end{multline*` in MathJax's; only the first is a label here, so the reference copies the long tag
    /// there and MathJax prints `??`, which leaves MathJax one more copy for the inline references after it.
    #[test]
    fn the_mathjax_text_has_a_reference_budget_of_its_own() {
        let tag = "x".repeat(REF_BUDGET_BASE);
        let mut maths = vec![
            math(&format!(r"x \tag{{{tag}}}\label{{k\end{{gather*}}"), true),
            math(r"\begin{multline}a\\b \nonumber \ref{k\end{multline}", true),
        ];
        let base = maths.len();
        let total_without = |n: usize| {
            maths.iter().map(|m| m.tex.len()).sum::<usize>() + n * r"\ref{k\end{gather*}".len()
        };
        // enough inline references that the budget runs out in both texts
        let mut refs = 1;
        while refs * tag.len() <= REF_BUDGET_FACTOR * total_without(refs) + REF_BUDGET_BASE {
            refs += 1;
        }
        let total = total_without(refs);
        let fit = (REF_BUDGET_FACTOR * total + REF_BUDGET_BASE) / tag.len();
        assert!(
            fit >= 2 && fit < refs,
            "{fit} copies fit, {refs} inline references"
        );
        for _ in 0..refs {
            maths.push(math(r"\ref{k\end{gather*}", false));
        }
        let copied = format!("\\text{{{tag}}}");
        let reference = prepare_tex(maths.iter());
        let mathjax = prepare_tex_for(maths.iter(), Engine::MathJax);
        assert_eq!(reference[1], format!(r"\begin{{gather*}}a \\b  {copied}"));
        assert_eq!(mathjax[1], r"\begin{multline*}a \\b  \text{??}");
        // the reference copies the tag `fit` times in all, the multline's copy first; MathJax `fit` times inline
        for i in 0..refs {
            let want_reference = if i + 1 < fit {
                copied.as_str()
            } else {
                r"\text{??}"
            };
            let want_mathjax = if i < fit {
                copied.as_str()
            } else {
                r"\text{??}"
            };
            assert_eq!(
                reference[base + i],
                want_reference,
                "reference text of inline {i}"
            );
            assert_eq!(
                mathjax[base + i],
                want_mathjax,
                "MathJax text of inline {i}"
            );
        }
        // making the MathJax text leaves the reference's text as it is
        let p = prepare(maths.iter(), Engine::MathJax);
        assert_eq!(p.text, reference);
        let differs: Vec<usize> = p.own.iter().map(|(i, _)| *i).collect();
        assert_eq!(differs, [1, base + fit - 1]);
    }

    /// Deviation D3 for a math whose MathJax text is its own: a reference inside a numbered `multline` copies a long
    /// tag, and the budget runs out in the inline references after it. Both texts copy the tag at the same places
    /// (the references and the budgets are the same), and the reference's text is the same under both engines. Were
    /// the MathJax text of the `multline` to spend the reference's budget, the reference's text would copy the tag
    /// one time fewer.
    #[test]
    fn a_reference_in_a_numbered_multline_copies_within_the_mathjax_budget() {
        let tag = "y".repeat(REF_BUDGET_BASE / 2);
        let mut maths = vec![
            math(&format!(r"z \tag{{{tag}}}\label{{t}}"), true),
            math(r"\begin{multline}a\\b \eqref{t}\end{multline}", true),
        ];
        for _ in 0..20 {
            maths.push(math(r"\ref{t}", false));
        }
        let reference = prepare_tex(maths.iter());
        let copied = format!("\\text{{{tag}}}");
        let copies = reference.iter().skip(2).filter(|t| **t == copied).count();
        assert!((2..20).contains(&copies), "{copies} inline copies");
        let p = prepare(maths.iter(), Engine::MathJax);
        assert_eq!(p.text, reference, "reference text under MathJax");
        let mathjax = prepare_tex_for(maths.iter(), Engine::MathJax);
        assert!(
            mathjax[1].starts_with(r"\begin{multline*}"),
            "{}",
            &mathjax[1][..40]
        );
        for i in 2..maths.len() {
            assert_eq!(mathjax[i], reference[i], "MathJax text of inline {i}");
        }
    }
}
