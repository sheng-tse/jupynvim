//! The math grammar of the markdown views: finds the math in markdown source
//! before any markdown parsing, so the TeX is never touched by markdown
//! (escapes, emphasis, HTML and links inside math stay TeX), and prepares it
//! for a typesetting engine.
//!
//! # Delimiters
//!
//! ````text
//! $$...$$                  display, on its own lines or mid-paragraph; no blank line inside
//! $...$                    inline; the opener is not followed by whitespace, the closer is not
//!                          preceded by whitespace and not followed by a digit, the first
//!                          unescaped $ after the opener ends the attempt; one line break is
//!                          allowed, a blank line is not
//! $`...`$                  inline, backtick form
//! \(...\)   \[...\]        inline / display
//! \\(...\\) \\[...\\]      the same with doubled backslashes (the classic notebook form, written
//!                          doubled so that markdown leaves one backslash)
//! \begin{env}...\end{env}  display, a bare environment with matching nesting
//! ```math / ~~~math        display fence, any case of "math"
//! \$                       a literal dollar outside math; inside math it is TeX's \$
//! ````
//!
//! The pandoc rule keeps prices out of math: a closing `$` may not follow
//! whitespace and may not be followed by a digit, so in `costs $5 and $10 each`
//! neither `$5 and $` nor `$10` pairs.
//!
//! # Never scanned
//!
//! Code spans, fenced code blocks, indented code blocks, HTML comments and
//! HTML tags. Every `$` that does not form math is written as `\$`, so no
//! later markdown processor can pair it.
//!
//! # Output
//!
//! [`extract_math`] returns [`Extracted`]: the text with each math replaced
//! by a placeholder (`ZZMTH0001ZZ` inline, `ZZDMTH0001ZZ` display, numbered
//! from 1 in document order, see [`placeholder`]), the maths, and a source
//! map. The text is what a markdown parser is given; the placeholders survive
//! any markdown construct and are swapped for typeset math afterwards. A
//! math that spans several lines becomes one placeholder, so the rows of the
//! text and of the source differ after it.
//!
//! A math's `block` flag says that the display math stands alone on its lines
//! (only blockquote markers and blanks around it). Its `raw` field is the
//! source it was cut from, delimiters included: what a formula that fails to
//! typeset shows in the error color.
//!
//! The grammar writes every leftover `$` as `\$` (an edit with
//! `math == None`), so that markdown cannot pair it. Markdown processes no
//! backslash escape inside raw HTML (a CommonMark HTML block such as `<div>`,
//! `<pre>` or a `<details>` up to its first blank line, or raw inline HTML),
//! so a renderer that passes raw HTML through puts back the `$` of every edit
//! with `math == None` that falls inside it (the edits give the exact ranges);
//! otherwise a `<div>` that holds `The fee is $5.` shows `The fee is \$5.`.
//! The same renderer decides whether a math inside `<pre>`, `<code>`,
//! `<script>`, `<style>` or `<textarea>` is typeset or shown as its `raw`
//! source: the grammar turns it into a placeholder like any other math.
//!
//! # Offsets
//!
//! Every offset in this module is a byte offset into UTF-8, and the offsets
//! of the source map refer to the *newline-normalized* source,
//! [`normalize_newlines`] of the input (`\r\n` and a lone `\r` become `\n`;
//! the input itself when it has no `\r`), not to the input. A caller that
//! holds a file with other line endings normalizes first and maps against the
//! normalized text.
//!
//! [`Extracted::edits`] lists every place where the text differs from the
//! normalized source: a math became its placeholder (`math` names it), or a
//! `$` became `\$` (`math` is `None`). The edits are sorted and disjoint on
//! both sides, so [`Extracted::text_to_src`] and [`Extracted::src_to_text`]
//! are binary searches. They are the only way back from the text a markdown
//! parser saw to the source: a position inside a replacement maps to the
//! start of the replaced range, and the edit's `src.end` is where it ends.
//!
//! # Numbering and references
//!
//! [`prepare_tex`] gives every math its final TeX the way AMS LaTeX would:
//! a numbered environment (`equation`, `align`, `gather`, `multline`,
//! `flalign`, `alignat`, `eqnarray`) becomes a starred environment with
//! explicit tags: `equation`, `align`, `gather`, `flalign` and `alignat` their
//! own starred form with a `\tag{n}` on every numbered row, `eqnarray`
//! `align*` the same way, and `multline` `gather*` as one equation with its
//! one tag on its last row (`\nonumber` and `\notag` respected, an explicit
//! `\tag` of any row kept and written there, deviation D7).
//! `\label` is removed, and `\eqref` and `\ref` are resolved, forward
//! references included. Rows, labels, tags and skip words are read as the
//! engines see them: a row commented out with `%` takes no number and a
//! command in a comment or after an escaping backslash counts for nothing
//! (deviation D9); each row follows its row break directly, so a row-spacing
//! argument such as `\\[4pt]` stays the break's (deviation D10); and a
//! command taken out never joins what it stood between (deviation D11). That
//! is the reference's text with deviations D7 to D11, and the KaTeX text:
//! KaTeX has neither `eqnarray` nor `multline`, and `align*` and `gather*`
//! are the reference's stand-ins. MathJax draws `eqnarray*` and `multline*`
//! with explicit tags as LaTeX draws the numbered environments (a `multline`
//! staggered, an `eqnarray` aligned at its relation), so its text,
//! [`prepare_tex_for`] with [`Engine::MathJax`], writes every numbered
//! environment in its own starred form, `eqnarray*` and `multline*` included,
//! but `flalign` unstarred: MathJax refuses a `\tag` in `flalign*`, and a row
//! of it the numbering leaves without a tag ends with `\notag`, so it draws
//! the same with and without MathJax's own numbering. The rows, tags and
//! references are the same (deviation D6).
//! [`prepare_document`] runs the numbering over all sources of one document (a
//! notebook is one document: numbers and references continue across cells),
//! and its [`EngineTex::tex`] is the engine's text.
//!
//! # Macros
//!
//! [`katex_newcommand`] is the KaTeX rule (deviation D5, below): the first
//! `\newcommand` or `\providecommand` of a name that KaTeX predefines and
//! LaTeX does not (`\R`, `\N`, `\argmax`, `\bm`, `\ket`, ...: [`KATEX_ONLY`])
//! is passed on as `\renewcommand`.
//! [`MacroScope`] applies it in document order (for [`Engine::Katex`]; MathJax
//! needs no rewrite) and gives each math the hash of every math before it that
//! defines or changes a macro, so a renderer can cache by
//! ([`EngineTex::tex`], [`EngineTex::env`]) and still resolve macros in
//! document order. Given the same prepared TeX for the later
//! maths, a math that is not affecting changes neither their env, their TeX
//! nor their decision, and an edit to a definition changes the env of every
//! math after it. That is the scope's part: the prepared TeX comes from
//! [`prepare_tex_for`], whose numbers and references are document-wide, so an
//! edit to a math that is not affecting (an `equation` in place of `$$..$$`,
//! a `\label` added) can still change the tags and references, and so the
//! prepared TeX, of later maths, and with them the env after a later affecting
//! math that holds one. Run [`prepare_document`] (or [`prepare_tex_for`] and
//! the fold) on every change, and reuse a later math's typeset result only
//! where its prepared TeX and its env are both unchanged. Under
//! [`Engine::Katex`] a math is also affecting when the rule rewrote it (a
//! net: the scan sees every control word the rule acts on, so a rewritten
//! math is one it has already counted). A definition the scope cannot follow
//! (a body that defines something when it runs, an environment or extension
//! command, a definition that does not parse to its end, a definition next to
//! a `\verb` or to a `%` that a command may be reading, whose reading differs
//! between the engines) makes every later math count as affecting. A `%`
//! where no command is reading is not such a `%`: a note after a definition
//! at the top level of the math
//! (`\newcommand{\R}{\mathbb{R}} % reals`), or on a line of its own after one
//! or at the start of the math. A definition inside a braced argument, a group
//! or an environment leaves no such point after it (`\url{\def\a{1} % }`): a
//! `%` there is one that a command may be reading. Nor does a definition that
//! an engine ends before the walk does, so that the rest of it is formula text
//! there: a `*` after `\newcommand` (both engines take it as the name) or a
//! default argument (KaTeX has none). A definition that an engine reads
//! further than the walk does makes every later math count as affecting: a
//! `\{` in the parameter text of a `\def` (MathJax starts the body at its
//! `{`), a braced `[` where the count would stand (a count to KaTeX) or an
//! `\edef` whose body holds a command (KaTeX expands it, and a macro there
//! reads on past the body). So does input outside the model: the walk models
//! the definition forms and the lexing that both engines share and that it
//! reproduces exactly, and a definition that holds anything else is opaque
//! whatever either engine would make of it. That is a combining mark of the
//! five combining blocks (U+0300 to U+036F, U+1AB0 to U+1AFF, U+1DC0 to U+1DFF,
//! U+20D0 to U+20FF, U+FE20 to U+FE2F), white space beyond space, tab, newline
//! and carriage return (a form feed, U+00A0, U+3000, ...) or another control
//! character, an `@` control sequence (`\newcommand\a@b{x}`, `\let\a\@ab`), a
//! control symbol over a non-ASCII character as a name or a non-ASCII character
//! in the parameter text of a `\def`, and under [`Engine::MathJax`] a
//! `\providecommand`, `\gdef`, `\edef`, `\xdef`, `\global` or `\long`, which
//! MathJax 3 does not have. Ordinary non-ASCII text in a body or a target
//! (`\newcommand{\N}{<U+2115>}`) and anything in a comment at a safe point are
//! inside the model and stay followed. A `\renewcommand*`, which defines the
//! character `*` as a macro in KaTeX, makes every later math count as
//! affecting too, and so does a definition after a command (`\alpha \def\a{1}`,
//! `\text{\def\a{1}}`) or after a definition an engine ends earlier: the
//! command can be a macro that takes arguments and hands the engine a part of
//! the definition in another order (`\first\let\y\b\def`, with `\first`
//! giving back the first of two arguments, lets `\b` be `\def`). The module
//! documentation of [`macros`] lists the readers of both engines and has the
//! rules.
//!
//! # Using the grammar
//!
//! A markdown file is one source. A notebook is one document of several
//! sources, its markdown cells in order, because the numbers, the references
//! and the macros of a cell continue in the next. The steps:
//!
//! 1. [`extract_document`] (or [`extract_math`] for one source) on every
//!    change of the text, keeping the [`Extracted`] of each source: only the
//!    sources that changed need to be read again.
//! 2. The markdown parser gets [`Extracted::text`]. Rows, conceal and the
//!    live preview map positions of that text back with the edits. Find the
//!    placeholders through the ranges in [`Extracted::edits`] (`Edit::text`),
//!    never by searching the text for `ZZMTH`: a source can hold that very
//!    text itself, and it cannot be told from a placeholder.
//! 3. [`prepare_document`] over the [`Extracted`] of every source gives a
//!    [`PreparedDoc`]: `prepared` and `engine` hold one entry per math of the
//!    document in order, and `offsets[s]` is the index of source `s`'s first
//!    math. Numbering that restarts in every cell, with the macros still in
//!    document order, is [`prepare_tex_for`] (with the engine) over the maths
//!    of each source on its own followed by one [`MacroScope`] fold
//!    ([`MacroScope::next`] over all the results, in document order).
//! 4. The renderer typesets each [`EngineTex::tex`] and swaps the result for
//!    the placeholder of its math.
//!
//! Row mapping: the text and the source differ by the edits, and a
//! multi-line math is one placeholder, so a row of the text is found by
//! mapping its first byte.
//!
//! ```
//! use jupynvim::mathgrammar::extract_math;
//!
//! let src = "intro\n$$\n\\int_0^1 x^2 \\, dx = \\frac{1}{3}\n$$\nafter";
//! let ex = extract_math(src);
//! assert_eq!(ex.text, "intro\nZZDMTH0001ZZ\nafter");
//!
//! // the third row of the text is the fifth row of the source
//! let at = ex.text_to_src(ex.text.find("after").unwrap_or(0));
//! assert_eq!(&src[at..], "after");
//! assert_eq!(src[..at].matches('\n').count(), 4);
//! // the edit says which source bytes the placeholder stands for
//! let math = ex.edits[0].src.clone();
//! assert_eq!(&src[math], "$$\n\\int_0^1 x^2 \\, dx = \\frac{1}{3}\n$$");
//! ```
//!
//! The environment, [`EngineTex::env`], is a cache key and a replay rule.
//! A formula is typeset after every macro the document defined before it, so
//! cache a typeset formula by ([`EngineTex::tex`], [`EngineTex::env`]): the
//! same text in the same environment gives the same output. Never key it by
//! [`PreparedDoc::prepared`]: that is the reference's text, which under
//! [`Engine::MathJax`] is not the engine's (an `eqnarray` and an `align`
//! with the same body, or a one-row `multline` and a `gather`, have the same
//! `prepared` and env and different MathJax text, deviation D6), so a cache
//! keyed on it would keep the old drawing when an `eqnarray` is renamed
//! `align`. Prepare the document again on every
//! change (numbers and references are document-wide, so an edit to any math
//! can change the prepared TeX of a later one) and reuse a typeset formula
//! wherever its (`tex`, `env`) is unchanged; for the same prepared TeX of the
//! later maths, an edit that leaves a math with `affecting == false` changes
//! no key after it. A renderer that does not
//! typeset the whole document (only the visible formulas, say) still gets the
//! macros of document order by replaying: typeset the maths with
//! `affecting == true` in document order, take a snapshot of the engine's
//! macros after each, and typeset any other math against the snapshot taken
//! for its `env`. A MathJax run has to turn its own automatic equation
//! numbering off (or reset it for every formula), otherwise the engine keeps
//! a counter the key does not know about; the grammar writes the numbers
//! itself as explicit tags. A KaTeX run keeps the macros from one formula to
//! the next only with one shared `macros` object and `globalGroup: true`, as
//! the reference renderer runs it (without the option a definition lasts for
//! its own formula only), and the snapshot is a copy of that object.
//!
//! ```
//! use jupynvim::mathgrammar::{extract_document, prepare_document, Engine};
//!
//! let cells = [r"$\newcommand{\RR}{\mathbb R}$ then $\RR$", r"and $\RR^2$"];
//! let doc = extract_document(&cells);
//! let p = prepare_document(&doc, Engine::Katex);
//! assert_eq!(p.offsets, vec![0, 2]);
//! // the definition changes the environment; the two uses share one
//! assert!(p.engine[0].affecting && !p.engine[1].affecting && !p.engine[2].affecting);
//! assert_eq!(p.engine[0].env, 0);
//! assert_ne!(p.engine[1].env, 0);
//! assert_eq!(p.engine[1].env, p.engine[2].env);
//! ```
//!
//! White space follows JavaScript, not Rust: `trim` and `\s` there strip
//! U+00A0 and U+FEFF but not U+0085, and `.` does not match U+2028 or
//! U+2029. Code in the markdown views that has to agree with the grammar on
//! what is blank uses [`jsstr`], never `str::trim`.
//!
//! # Where this differs from the reference on purpose
//!
//! The grammar is a port of a JavaScript reference and is identical to it on
//! every input except eleven. Three are crashes, garbage or an engine error
//! there, one a wrong layout or an error in MathJax, one a wrong numbering of
//! `multline`, one broken reference text, one a wrong numbering wherever a
//! `%` comment or an escaped command stands in a numbered environment, one a
//! row break's argument drawn as text and one a command taken out that joins
//! what it stood between; two bound the memory and the time, and change the
//! output only on inputs that name which they are (below), none of which a
//! document holds unless it is made to:
//!
//! 1. D1: a `\begin{name}` whose name makes the reference build an invalid
//!    regular expression (a `**` anywhere after the name's first `*`) is plain
//!    text here; the reference throws and the whole render fails.
//! 2. D2: environment names and label keys are looked up in plain maps. The
//!    reference reads inherited object properties (`constructor`,
//!    `toString`, ...), so such a name is numbered as an equation and printed
//!    as the text of a function, and it drops a label named `__proto__`.
//! 3. D3: the tag text that `\ref` and `\eqref` copy is limited per call of
//!    [`prepare_tex`] (so per document), not per tag. A reference prints its
//!    tag while the bytes copied so far plus this tag stay within
//!    [`ams::REF_BUDGET_FACTOR`] (4) times the TeX of all the maths plus
//!    [`ams::REF_BUDGET_BASE`] (64 KiB), and prints `??`, as for an unknown
//!    label, past it. The reference copies the whole tag into every reference,
//!    so a tag of `T` bytes with `R` references makes `R * T` bytes of output,
//!    quadratic in the source (a 1 MB cell would need 28 GB). A tag of any
//!    length referenced a few times, 65 or 1,000 bytes included, is copied
//!    exactly as the reference does; only a document whose references together
//!    copy more than 64 KiB of tag text and more than four times the TeX of
//!    its maths (a tag of kilobytes referenced dozens of times) sees `??`,
//!    from the first reference that does not fit.
//! 4. D4: the names of `\begin{name}` that hold a starred atom (two or more
//!    stars, not a LaTeX environment) are matched within a work budget per text
//!    segment, [`index::STAR_WORK_FACTOR`] (16) units per byte plus
//!    [`index::STAR_WORK_BASE`] (1 Mi). A name of that kind that comes after
//!    the budget is spent and was not answered before is plain text, as in D1;
//!    the names answered before keep their answers, whatever else is asked
//!    (an answer is never dropped; the budget is also spent when the groups
//!    kept for the names that match several others pass twice the
//!    occurrences of the segment plus a floor, which is what bounds that
//!    memory). The reference builds a regular expression per name, which
//!    backtracks without bound on a near miss, and the exact match of many
//!    such names against many others is quadratic. Only a name with two or
//!    more stars reaches either bound, and no LaTeX environment is named so.
//!    The work budget is far above any text of such names that is not made to
//!    spend it: 4 MiB of distinct names of this kind spends about half of it.
//!    The bound on the groups is nearer, and a few names are enough: a text
//!    with one plain environment name used a thousand times and eleven names
//!    with two stars that each match it (37.5 KB) reaches it at the fifth,
//!    and every new such name after that is plain text, where the reference
//!    makes all of them environments.
//! 5. D5: the KaTeX `\newcommand` rule ([`katex_newcommand`]). The reference's
//!    rule is a regular expression over the raw TeX with a list of ten names.
//!    KaTeX predefines neither `\C` nor `\Q`, so
//!    `$\newcommand{\Q}{\mathbb{Q}}$` became `\renewcommand{\Q}`, which KaTeX
//!    refuses ("when command `\Q` does not yet exist"), and every `\Q` after
//!    it was undefined. It lacked
//!    the names KaTeX predefines that LaTeX does not (`\argmax`, `\bm`, `\set`,
//!    `\ket`, `\coloneqq`, ...), so a preamble that defines one fails as a
//!    whole in KaTeX. It took the text of a comment (`% \newcommand{\R}{1}`) or
//!    of `\\newcommand` (a line break and letters) for a definition, so the
//!    real one after it was refused, and it passed `\providecommand` on, which
//!    KaTeX skips for a name it predefines (`\providecommand{\R}{\mathbf{R}}`
//!    drew KaTeX's own `\R`). Here [`KATEX_ONLY`] is the 246 control words that
//!    KaTeX 0.16.21 predefines and LaTeX with amsmath and amssymb does not
//!    define (8 of them are among the reference's ten), generated from KaTeX
//!    and LaTeX by `tests/mathgrammar/gen_katex_only.mjs`; the text is lexed
//!    as KaTeX lexes it, so only a control word outside a comment and outside
//!    `\verb` text counts, and the blanks between the parts of a definition
//!    are KaTeX's (the reference's `\s` also skipped a no-break space, which
//!    KaTeX takes for the name); the address of `\url`, `\href` and
//!    `\includegraphics` is read with `%` an ordinary character (and ends the
//!    formula, as an unclosed group does, when it starts with a `}` and no
//!    group is open around the command: inside one, a definition body among
//!    them, that `}` closes the group), a name in braces is exactly one token
//!    and a `\verb` token where the name should be claims nothing (the module
//!    `macros` has the detail, and the known gap of an address inside text
//!    KaTeX has lexed before, where its `%` is a comment); and the first
//!    `\providecommand` of a listed name is passed on like the first
//!    `\newcommand`. Another KaTeX version needs the list generated again
//!    (0.16.47 adds `\overbracket` and `\underbracket`).
//! 6. D6: the MathJax text of a numbered `eqnarray`, `multline` and `flalign`.
//!    The reference writes the first two as `align*` and `gather*` for both
//!    engines, KaTeX's stand-ins for two environments it lacks, so MathJax
//!    centered every row of a `multline` and left a gap of about 1.7 em after
//!    each `=` of an `eqnarray` (`align*` pairs its columns right, left, with
//!    space between the pairs). Under [`Engine::MathJax`] they are `multline*`
//!    and `eqnarray*` with the same rows and tags, which MathJax 3.2.2 draws
//!    with the layout of the numbered environments: the rows of a `multline`
//!    staggered from the left margin to the right with the tag on the last, the
//!    columns of an `eqnarray` where the numbered one has them. A numbered
//!    `flalign` is the unstarred `flalign` under [`Engine::MathJax`]: the
//!    reference's `flalign*` with `\tag{n}` was an error there ("\tag not
//!    allowed in flalign* environment"), and MathJax draws `flalign` with the
//!    same tags as LaTeX draws it; every row the numbering leaves without a tag
//!    ends with `\notag` in that text, so MathJax's own numbering, on or off,
//!    adds none. `prepared` and the KaTeX text keep the reference's forms.
//! 7. D7: a numbered `multline` is one equation, as in amsmath. The reference
//!    numbered it row by row: a `\label` before the last row referred to
//!    nothing (`\eqref` printed `(??)`), a `\tag` there stayed in its row
//!    while the last row was numbered too (two tags: KaTeX drew both and
//!    numbered every later equation one too high, MathJax refused the
//!    `multline*` of D6 with "Multiple \tag"), and a `\nonumber` there left
//!    the equation numbered. Here the first explicit tag of any row is the
//!    equation's, a skip word in any row means no number, every label is
//!    registered under the equation's tag, and the tags of the rows before
//!    the last move, each with its whole brace group, to the end of the last
//!    row, where amsmath sets the tag; only what the engines see counts (not
//!    a command in a `%` comment or after an escaping backslash). The module
//!    `ams` has the detail.
//! 8. D8: a reference prints its tag's whole brace group. The reference
//!    copied the tag's text up to its first `}`, so `\eqref` of a label on
//!    `\tag{$x_{1}$}` was `\text{($x_{1)}`, an error in both engines. A
//!    reference to a tag whose group does not close prints `??`.
//! 9. D9: the numbering reads the TeX as the engines see it, a backslash
//!    taking the next character with it and a `%` hiding the rest of its
//!    line. The reference read the raw text: a row of an `align` commented
//!    out with `%` (its row break with it) was numbered, its `\tag{n}` written
//!    into the comment, so the engines drew (1) (3) and every later number
//!    and reference was one too high; a commented `\nonumber`, `\tag` or
//!    `\label` still counted; and `{u\\label{q}}` lost `label{q}` into the
//!    unbalanced `{u\}`. Here rows are split only at a `\\` the engines see,
//!    a last row they see as empty (comments, or only the argument of the
//!    break before it) is dropped, a `\label`, `\tag`, `\nonumber` or
//!    `\notag` counts and is taken out only where they see it, and an
//!    environment whose `\end` a comment hides (an error in both engines) is
//!    not numbered.
//! 10. D10: each row follows its row break directly. The reference wrote a
//!     blank after every `\\` it joined, and neither engine reads a row
//!     break's argument after a blank, so `\\[4pt]` between two rows drew
//!     the text `[4pt]` in the formula and `\\*` a `*`. Only blanks change
//!     for any other row.
//! 11. D11: a command taken out never joins what it stood between. The
//!     reference took a `\label`, `\nonumber` or `\notag` out (and D7 a tag
//!     of a `multline` row) leaving nothing, so `\alpha\label{x}b` became the
//!     undefined `\alphab` and `\\\label{x}[c, d]` the row break `\\[c, d]`
//!     with a spacing that is no length, errors in both engines. Here a blank
//!     stands in its place where a control word would meet a letter or a row
//!     break a `[` or `*`.
//!
//! The conformance checks compare the two on the named cases, the fixtures
//! and fresh random corpora on every run of the suite (the golden files in
//! `tests/mathgrammar/golden/`, which `core/native/tests/math_grammar.rs`
//! reads, and the reference itself in `tests/mathgrammar_spec.sh`;
//! `tests/mathgrammar/README.md` describes both). D5 to D11 are part of what
//! they compare: the KaTeX text against `tests/mathgrammar/katex_rule.mjs`,
//! the prepared TeX against the reference's own code with its reading of a
//! label's tag changed for D8, the numbering of a `multline` for D7, its
//! reading of rows, labels, tags and skip words for D9, its join of the
//! rows for D10 and its take-outs for D11, the MathJax text against that
//! code with MathJax's forms of `eqnarray`, `multline` and `flalign` in its
//! table and `\notag` on a row of `flalign` left without a tag. The corpora
//! never reach the limits of D1 to D4 (their documents are small, their tags
//! short), and the golden `tags.cases` pins D3 below its budget with tags of
//! up to 5,000 bytes; the unit tests pin the behavior past each limit.
//!
//! # Linear time
//!
//! The time of [`extract_math`] is linear in the length of the source. The
//! reference is not: on a text with many delimiters and no closing one, each
//! opener reads to the end of the text (an unclosed `\(`, `\\(` or
//! `\begin{x}`, code spans of growing length). Here each such question is
//! answered from a structure built once per text segment, the first time a
//! scan of that kind runs in it, or from the memo of an earlier failed
//! search; see [`index`]. Nothing is allocated for a kind of scan that does
//! not run, and the answers are the reference's, which the same conformance
//! suite shows. The time budgets in `core/native/tests/math_grammar_perf.rs`
//! fail on a quadratic scan. They time every run with the CPU time of the
//! calling thread, not the wall clock, and run the two sizes of a ratio
//! alternately, which keeps a machine that is busy with other jobs from
//! failing them, except in the slow mode of cases A15 to A17 (below), where
//! a case over its limit is measured again in more rounds.
//!
//! [`prepare_tex`], [`prepare_tex_for`] and [`MacroScope::next`] are linear in
//! the total length of the maths and in their number, and the prepared TeX is
//! at most a constant times the source plus a base (D3 is what bounds it:
//! without it a reference copies a whole tag each time; the MathJax text has
//! a budget of its own).
//!
//! A `\begin{name}` whose name holds two or more stars (`a*b*`; not a LaTeX
//! environment) is matched by the reference as a regular expression that can
//! match several different names. Here the names of the segment are kept in a
//! path-compressed trie (a node where a name ends or two names part, an edge
//! being a range of a name that the segment already holds, so the trie has at
//! most twice as many nodes as there are distinct names, about 50 bytes each,
//! whatever their length), the pattern is walked over the part of it that it
//! can reach, and names that match the same environments share one group, so
//! a text of very many distinct names of this kind (`abc**`, `**abc`) is
//! linear (about 8 ms for 256 KiB of them and 150 ms for 4 MiB). Two shapes
//! are not, if nothing stops them. A name of `N` starred atoms read along a
//! key of `M` bytes takes `M * N / 64` word steps (134 million for 256 KiB of
//! text, and four times as many for twice the text), and `K` distinct names
//! that each match `K` keys cost `K * K` (seconds for 1 MiB). So this path has
//! a work budget per text segment (D4, [`index::STAR_WORK_FACTOR`]): every
//! byte of an edge the walk steps over costs the words of its state set, and
//! a key or an occurrence put into a match set or a merged group costs a few
//! units. The walk stops when it cannot pay for the next byte or when its
//! state sets would pass one word per byte of the segment, and a name that is
//! asked for after the budget is spent is plain text. The walk keeps one state
//! set for each node of the path it is on and two for the edge it is stepping
//! along, so they are at most 16 bytes per byte of the segment (the vector
//! may double), usually a handful of sets, together with one 16-byte frame
//! for each node of the path (at most the square root of twice the bytes of
//! the names); the groups kept for the patterns are bounded by a constant
//! times the number of occurrences (past that the budget is spent, and
//! nothing is dropped); and the time measured is 24 to 70 ns per byte of the
//! segment. The worst shapes known are cases A15 to A17 of
//! `core/native/tests/math_grammar_perf.rs`, which take 7 to 18 ms for 256 KiB
//! and 100 to 220 ms for 4 MiB (24 to 70 ns per byte; under load they can run
//! at about twice that for a while, the slow mode the perf test describes),
//! with a peak memory of 17 to 62 MB at 4 MiB (the index of the segment's
//! names and occurrences, not the trie, which is at most a fifth of it).
//! Every other text, and a name with at most one star, never takes this path.

use std::borrow::Cow;
use std::ops::Range;

pub mod ams;
pub mod blocks;
pub mod index;
pub mod jsstr;
pub mod katex_names;
pub mod macros;
pub mod scan;

pub use ams::{prepare_tex, prepare_tex_for};
pub use katex_names::KATEX_ONLY;
pub use macros::{katex_newcommand, Engine, EngineTex, MacroScope};

/// How a math was delimited.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Kind {
    /// A ```` ```math ```` or `~~~math` fence.
    Fence,
    /// `\\(...\\)` or `\\[...\\]`.
    Doubled,
    /// `\(...\)`.
    Paren,
    /// `\[...\]`.
    Bracket,
    /// A bare `\begin{env}...\end{env}`.
    Env,
    /// ``$`...`$``.
    Backtick,
    /// `$$...$$`.
    Dollars,
    /// `$...$`.
    Dollar,
}

impl Kind {
    /// The name used in the case files: `fence`, `doubled`, `paren`,
    /// `bracket`, `env`, `backtick`, `dollars` or `dollar`.
    pub fn as_str(self) -> &'static str {
        match self {
            Kind::Fence => "fence",
            Kind::Doubled => "doubled",
            Kind::Paren => "paren",
            Kind::Bracket => "bracket",
            Kind::Env => "env",
            Kind::Backtick => "backtick",
            Kind::Dollars => "dollars",
            Kind::Dollar => "dollar",
        }
    }

    /// The kind named `s` (see [`Kind::as_str`]).
    pub fn from_name(s: &str) -> Option<Kind> {
        Some(match s {
            "fence" => Kind::Fence,
            "doubled" => Kind::Doubled,
            "paren" => Kind::Paren,
            "bracket" => Kind::Bracket,
            "env" => Kind::Env,
            "backtick" => Kind::Backtick,
            "dollars" => Kind::Dollars,
            "dollar" => Kind::Dollar,
            _ => return None,
        })
    }
}

/// One math found in a source.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Math {
    /// The TeX between the delimiters, container prefixes (blockquote
    /// markers) stripped from continuation lines and the ends trimmed. For
    /// a bare environment the delimiters belong to the TeX.
    pub tex: String,
    /// Display (centered) or inline.
    pub display: bool,
    /// A display math that stands alone on its lines.
    pub block: bool,
    /// How it was delimited.
    pub kind: Kind,
    /// The source text the math was cut from, delimiters included.
    pub raw: String,
}

/// One replacement: normalized-source bytes `src` became text bytes `text`.
/// `math` is the index into `maths` for a placeholder, `None` for a `$`
/// escaped as `\$`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Edit {
    /// The replaced range of the normalized source.
    pub src: Range<usize>,
    /// The replacement's range in the text.
    pub text: Range<usize>,
    /// The math this placeholder stands for, if it is one.
    pub math: Option<usize>,
}

/// The result of [`extract_math`].
#[derive(Clone, Debug, PartialEq, Eq, Default)]
pub struct Extracted {
    /// The source with every math replaced by its placeholder and every
    /// other `$` escaped.
    pub text: String,
    /// The maths, in document order; placeholder `i` (1-based) is `maths[i - 1]`.
    pub maths: Vec<Math>,
    /// Every place the text differs from the normalized source, sorted and
    /// disjoint on both sides.
    pub edits: Vec<Edit>,
}

impl Extracted {
    /// A text offset to its normalized-source offset. Inside a replacement
    /// the answer is the replacement's `src.start`.
    pub fn text_to_src(&self, off: usize) -> usize {
        let i = self.edits.partition_point(|e| e.text.start <= off);
        match i.checked_sub(1).and_then(|j| self.edits.get(j)) {
            None => off,
            Some(e) if off < e.text.end => e.src.start,
            Some(e) => e.src.end + (off - e.text.end),
        }
    }

    /// A normalized-source offset to its text offset. Inside a replaced range
    /// the answer is the replacement's `text.start`.
    pub fn src_to_text(&self, off: usize) -> usize {
        let i = self.edits.partition_point(|e| e.src.start <= off);
        match i.checked_sub(1).and_then(|j| self.edits.get(j)) {
            None => off,
            Some(e) if off < e.src.end => e.text.start,
            Some(e) => e.text.end + (off - e.src.end),
        }
    }
}

/// `\r\n` and lone `\r` to `\n`; borrowed when there is no `\r`. Edit offsets
/// refer to this text.
pub fn normalize_newlines(src: &str) -> Cow<'_, str> {
    if !src.contains('\r') {
        return Cow::Borrowed(src);
    }
    let mut out = String::with_capacity(src.len());
    let mut chars = src.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '\r' {
            if chars.peek() == Some(&'\n') {
                chars.next();
            }
            out.push('\n');
        } else {
            out.push(c);
        }
    }
    Cow::Owned(out)
}

/// `ZZMTH0001ZZ` for an inline math, `ZZDMTH0001ZZ` for a display one; `i`
/// is 1-based and padded to at least four digits (10000 gives `ZZMTH10000ZZ`).
pub fn placeholder(i: usize, display: bool) -> String {
    format!("{}{i:04}ZZ", if display { "ZZDMTH" } else { "ZZMTH" })
}

/// Finds the math in one markdown source. See the module documentation.
pub fn extract_math(src: &str) -> Extracted {
    let norm = normalize_newlines(src);
    let bytes = norm.as_bytes();
    let segs = blocks::segments(&norm);
    let mut out = scan::Out {
        buf: Vec::with_capacity(bytes.len() + 64),
        maths: Vec::new(),
        edits: Vec::new(),
    };
    let piece = |a: usize, b: usize| bytes.get(a..b).unwrap_or_default();
    for (i, seg) in segs.iter().enumerate() {
        if i > 0 {
            out.buf.push(b'\n');
        }
        match &seg.kind {
            blocks::SegKind::Code => out.buf.extend_from_slice(piece(seg.start, seg.end)),
            blocks::SegKind::Text => {
                scan::scan_text(piece(seg.start, seg.end), seg.start, &mut out);
            }
            blocks::SegKind::MathFence {
                prefix_end,
                tex,
                raw,
            } => {
                // the quote prefix stays; the fence itself becomes a display placeholder
                out.buf.extend_from_slice(piece(seg.start, *prefix_end));
                let index = out.maths.len();
                out.maths.push(Math {
                    tex: tex.clone(),
                    display: true,
                    block: true,
                    kind: Kind::Fence,
                    raw: raw.clone(),
                });
                let t0 = out.buf.len();
                scan::push_placeholder(&mut out.buf, index + 1, true);
                out.edits.push(Edit {
                    src: *prefix_end..seg.end,
                    text: t0..out.buf.len(),
                    math: Some(index),
                });
            }
        }
    }
    // The output is input slices cut at ASCII positions plus ASCII, so it is
    // valid UTF-8; the lossy branch cannot run.
    let text = String::from_utf8(out.buf)
        .unwrap_or_else(|e| String::from_utf8_lossy(e.as_bytes()).into_owned());
    Extracted {
        text,
        maths: out.maths,
        edits: out.edits,
    }
}

/// [`extract_math`] over the sources of one document, in order.
pub fn extract_document(sources: &[&str]) -> Vec<Extracted> {
    sources.iter().map(|s| extract_math(s)).collect()
}

/// The prepared TeX of a whole document.
pub struct PreparedDoc {
    /// `offsets[s]` is the index of source `s`'s first math in the flat lists.
    pub offsets: Vec<usize>,
    /// [`prepare_tex`] over all maths of all sources, in document order: the
    /// reference's text, the same for both engines. Not a cache key: under
    /// MathJax it is not the engine's text, so key a typeset formula by the
    /// `engine` entry's ([`EngineTex::tex`], [`EngineTex::env`]).
    pub prepared: Vec<String>,
    /// [`MacroScope::next`] over the engine's text ([`prepare_tex_for`]), in
    /// document order. Under [`Engine::MathJax`] that differs from
    /// `prepared` only for a numbered `eqnarray` or `multline`.
    pub engine: Vec<EngineTex>,
}

/// Numbers equations, resolves labels and carries macros across all sources
/// in order: one notebook is one document.
pub fn prepare_document(sources: &[Extracted], engine: Engine) -> PreparedDoc {
    let mut offsets = Vec::with_capacity(sources.len());
    let mut n = 0;
    for s in sources {
        offsets.push(n);
        n += s.maths.len();
    }
    let ams::Prepared {
        text: prepared,
        own,
    } = ams::prepare(sources.iter().flat_map(|s| s.maths.iter()), engine);
    let mut scope = MacroScope::new(engine);
    let mut own = own.into_iter().peekable();
    let engine = prepared
        .iter()
        .enumerate()
        .map(|(i, p)| match own.next_if(|(j, _)| *j == i) {
            Some((_, t)) => scope.next(&t),
            None => scope.next(p),
        })
        .collect();
    PreparedDoc {
        offsets,
        prepared,
        engine,
    }
}
