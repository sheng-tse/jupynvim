//! The KaTeX `\newcommand` rule and the macro environment of a document.
//!
//! # The rule
//!
//! KaTeX predefines names that LaTeX does not (`\R`, `\N`, `\argmax`, `\bm`,
//! `\ket`, ...: [`KATEX_ONLY`]), so a document's first `\newcommand` of one of
//! them is legal LaTeX that KaTeX refuses; [`katex_newcommand`] passes it on
//! as `\renewcommand`, and so it does the first `\providecommand` of one,
//! which KaTeX would skip. It is applied to every math in document order with
//! one `defined` set per document. The list is the control words KaTeX
//! 0.16.21 predefines that LaTeX with amsmath and amssymb does not (generated
//! from KaTeX and LaTeX, see `katex_names.rs`), and the text is read as KaTeX
//! lexes it: a comment (`%` to the end of the line, not `\%`), the text of a
//! `\verb` (to the next copy of its delimiter with no line terminator in
//! between, so `\verb<LF>abc<LF>` is the text `abc` and `\verb<LF>a<CR>` is
//! none) and the letters after a `\\` are no definition, and blanks (space,
//! tab, line feed, carriage return) and comments may stand between the parts
//! of one, no other white space (KaTeX takes a no-break space there for the
//! name). Three more things are read as KaTeX reads them:
//!
//! - the address of `\url`, `\href` and `\includegraphics`: KaTeX reads that
//!   argument with `%` an ordinary character, so a `%` there starts no comment
//!   (`\url{a%20b} \newcommand{\R}{1}` defines `\R`), a group runs to its
//!   matching brace (a backslash takes the next character, a `\verb` token is
//!   one token) and a definition inside it is not looked at; a group that is
//!   never closed ends the formula in KaTeX, so nothing after it is read.
//!   `\includegraphics` first takes an optional argument in brackets, which
//!   KaTeX lexes as anywhere else (a `%` there starts a comment), up to the
//!   `]` outside any group. KaTeX reads the `%` as a character only where it
//!   lexes the address as it parses it; inside text it has lexed before (the
//!   argument of another command, such as `\text{..}`, or a macro body) that
//!   `%` was read as a comment already. The rule reads every address the
//!   first way: telling the two apart takes the argument count of every
//!   command, and it is a known gap (`tests/mathgrammar/README.md`, which has
//!   a second one: an address read after a word KaTeX takes as one token, in
//!   `\let\lk\url` or a body without braces). The rule follows a KaTeX
//!   error only inside this scan, where KaTeX's reading of the argument fails
//!   and it reads nothing after it: an unclosed group and, with no group open
//!   around the command, a `}` where the argument starts (`\url}`, blanks
//!   before it allowed: KaTeX reports "Extra }") or in the brackets outside
//!   their groups. With a group open that `}` closes the group and the math
//!   is read on: KaTeX parses no command in a definition body
//!   (`\newcommand{\img}{\includegraphics}`), a braced name
//!   (`\renewcommand{\url}[1]{..}`), after `\let` (`{\let\lk\url}`) or in a
//!   macro's argument, and in a group it does parse, which the rule cannot
//!   tell from those, the math is an error in every engine. Everywhere else a
//!   math is read to its end, as LaTeX reads on after reporting an error
//!   (`\url{}}`, a `}` after a whole address, is read on); the math shows as
//!   an error in every engine either way;
//! - a name in braces is exactly one token: only comments stand between the
//!   brace and the control word (a blank there is a token of its own) and,
//!   after the word, only blanks and comments before the closing brace; any
//!   other group (`\newcommand{ \R}{1}`, `{\R x}`) is an error to KaTeX, so
//!   the rule takes no name from it;
//! - a `\verb` token where the name should be is the name KaTeX is handed, and
//!   claims nothing (`\newcommand\verb*!\newcommand\argmax!{x}` defines no
//!   `\argmax`).
//!
//! This is deviation D5 from
//! the reference, whose expression over the raw TeX rewrote `\C` and `\Q`
//! (KaTeX has neither, so the definition became an error), missed the other
//! names, took a comment for a definition and passed `\providecommand` on.
//!
//! # The environment
//!
//! A formula is typeset after every macro defined before it in the document,
//! so a renderer that caches by formula text needs to know which maths
//! change the macros. [`MacroScope::next`] answers for each math in order:
//!
//! - `affecting`: the math holds a command that defines or changes
//!   something, or an earlier math was one the scope cannot follow, or (under
//!   [`Engine::Katex`]) the `\newcommand` rule rewrote it;
//! - `env`: a hash of every affecting math before this one (0 before the
//!   first), so a formula is cached by (text, `env`).
//!
//! The contract, for the maths the scope is handed: given the same prepared
//! TeX for the later maths, their `env`, their TeX and their `affecting` do
//! not depend on what a math that is not affecting says. It covers the scope
//! only. The prepared TeX comes from [`super::prepare_tex`], whose numbers and
//! references are document-wide: turning `$$x$$` into
//! `\begin{equation}x\end{equation}`, or adding a `\label`, leaves that math
//! not affecting and still shifts every later `\tag` or resolves a later
//! `\ref`, and with them the TeX of later maths and the `env` after a later
//! affecting math that holds one. So a consumer runs
//! [`super::prepare_document`] (or `prepare_tex` and the fold) on every
//! change, and reuses a later math's result only where its prepared TeX and
//! its `env` are both unchanged.
//!
//! The rule has a state of its own, the names `\newcommand` and
//! `\providecommand` have defined so far, and it changes the TeX a later math
//! is handed. The rule hides every comment and all `\verb` text from itself
//! (and the address of a `\url`, `\href` or `\includegraphics` is the one
//! place it reads a `%` as a character), where the scan below hides only a
//! comment at a safe point, so the scan sees every control word the rule acts
//! on and the maths that change the state are the ones the scan counts as
//! defining. A math the rule rewrote is affecting under [`Engine::Katex`]
//! whatever the scan found, a net that is never needed: were the two ever to
//! disagree about what a command word is, it would cost a cache hit, never a
//! stale render.
//!
//! A math is scanned as TeX tokens. A command word counts wherever it stands,
//! in the argument of `\text` or `\verb` too (the scan can only be wrong in
//! the direction of finding more), with one exception: the words of a comment
//! at a safe point (below) are hidden from both engines and count for
//! nothing. The commands that define are walked to their end: the
//! `\newcommand` family (`\renewcommand`, `\providecommand`), the `\def`
//! family (`\gdef`, `\edef`, `\xdef`), `\let` and `\DeclareMathOperator`,
//! with `\global` and `\long` in front (not every engine has all of them:
//! see where each engine ends a definition, below). A definition the scope
//! can follow (its name, its argument list and a balanced body, none of them
//! holding a defining command) only makes the math affecting. Anything else
//! makes the scope *opaque* for the rest of the document: every later math
//! is affecting and the environment moves on every time. That is the safe
//! direction, it only costs cache hits. Opaque are:
//!
//! - input outside the model. The walk models the definition forms and the
//!   lexing that KaTeX 0.16 and MathJax 3 share and that it reproduces
//!   exactly. A definition that holds anything else is opaque, whatever either
//!   engine would make of it: the walk does not try to match one engine or the
//!   other case by case, and later maths are keyed from their exact source (a
//!   cache miss, never a stale render). The kinds, found in the bytes of the
//!   definition after its command word, or by the walk itself:
//!   (i) a combining mark (U+0300 to U+036F, U+1AB0 to U+1AFF, U+1DC0 to
//!   U+1DFF, U+20D0 to U+20FF, U+FE20 to U+FE2F: KaTeX makes a character and
//!   its marks one token, so `\newcommand\cafe{\text{cafe<U+0301>}}` has no
//!   `}` where the walk has it), white space other than space, tab, newline
//!   and carriage return (a form feed, a vertical tab, U+00A0, U+1680, U+2000
//!   to U+200A, U+2028, U+2029, U+202F, U+205F, U+3000, U+FEFF: MathJax skips
//!   it before an argument, KaTeX does not, as in
//!   `\newcommand\a<U+00A0>{\def\b{X}}`) or any other control character
//!   below U+0020, anywhere in the definition, a mark right after its last
//!   token included (`\let\a=x<U+0301>`), and after `\global` or `\long`
//!   the first character after the blanks that follow it;
//!   (ii) an `@` control sequence anywhere in a definition, as a name, a
//!   target, a body or parameter text: a control word with an `@` after its
//!   letters (`\newcommand\a@b{x}`, `\newcommand\a{\b@c}`) or the control
//!   symbol `\@` (`\let\a\@ab`), and a defining command written with an `@`
//!   right after it (`\def@x`), since KaTeX reads `@` as a letter and MathJax
//!   does not;
//!   (iii) a control symbol over a non-ASCII character as a name (as a target
//!   it is followed) or in the parameter text of a `\def`, and any other
//!   non-ASCII character in that parameter text (`\newcommand\<e acute>{x}`,
//!   `\def\a#1<e acute>{#1}`);
//!   (iv) under [`Engine::MathJax`] only, a use of the six commands MathJax 3
//!   lacks: `\providecommand`, `\gdef`, `\edef`, `\xdef`, `\global` and
//!   `\long` (it typesets the name, and the definition is formula text there;
//!   KaTeX has them and stays modelled).
//!   A control symbol over a character outside the basic plane (four bytes of
//!   UTF-8, such as U+1F600) is outside the model too: MathJax reads it as a
//!   command and KaTeX does not read it at all.
//!   Ordinary non-ASCII text in a body or a target
//!   (`\newcommand{\N}{<U+2115>}`, `\def\eps{<epsilon>}`,
//!   `\let\a=<e acute>`) and anything in a comment at a safe point is inside
//!   the model: it stays followed and on the cached path;
//! - a body, name or argument list that holds a defining command, since the
//!   macro defines something when it runs (`\newcommand{\mk}[1]{\def#1{x}}`);
//! - a `\let` of a defining command (`\let\d\def`);
//! - the commands that change the engine's state in other ways
//!   (environments, extensions, tag forms, column types, colors, groups that
//!   span formulas, the `xparse` definition commands, `\csname`,
//!   `\futurelet`, `\chardef`, ...), whatever follows them;
//! - a definition that does not parse to its end;
//! - a definition after a command that is not part of a definition the scope
//!   follows (`\alpha \def\a{1}`, `\text{\def\a{1}}`), or after a
//!   definition that an engine ends before the walk does: any command can be
//!   a macro of the document that takes arguments, and such a macro can take
//!   a part of the definition and hand the engine the tokens in another order
//!   than the text has (with `\first` taking two arguments and giving back the
//!   first, `\first\let\y\b\def` lets `\b` be `\def` in both engines; KaTeX
//!   has such macros built in, `\@firstoftwo`). Characters, blanks, comments
//!   at a safe point and followed definitions take no arguments, so
//!   `x = 1 \def\a{1}` and `{\def\a{1}}` are followed;
//! - a definition that an engine reads further than the walk does (below):
//!   what lies between the two ends is part of that engine's definition, so
//!   a defining command there is stored in a macro body and a `%` there is a
//!   character. These are a `\{` in the parameter text of a `\def`, a braced
//!   `[` where the count of the `\newcommand` family would stand, and an
//!   `\edef` or `\xdef` whose body holds a command;
//! - `\renewcommand*`: KaTeX takes the `*` for the name and defines the
//!   character `*` as a macro, which every later math reads as such wherever
//!   it holds a `*`, so a later definition after a `*` could be spliced (see
//!   the definitions after a command, above);
//! - an affecting math that holds an unescaped `%` other than a comment at a
//!   safe point, or a `\verb`: the engines disagree about what they hide.
//!   KaTeX drops a comment when it reads the characters, MathJax reads the
//!   argument of `\text{%}\def\b{X}` without looking for comments, takes
//!   the `%` of `\newcommand{\R} %c` as the body and of `x^%` as the
//!   superscript, and counts the braces inside a comment, and `\verb|%|` is
//!   raw text in both, so where a definition ends, or whether a `\def` after
//!   the `%` runs at all, depends on the engine.
//!
//! The commands the scope tracks are the ones above. The grammar numbers
//! equations itself (explicit tags), so the engines' own counters do not
//! matter; the state a MathJax package keeps from one formula to the next
//! (the colors of `\definecolor`, the environments of `\newgathered`, the
//! options of `\mathtoolsset`, a `\begingroup` that is closed in a later
//! formula) is why those commands are in the opaque list, and a command of
//! another package that keeps state belongs there too. One MathJax command
//! keeps state only when it is written one way: the `unicode` package keeps
//! the font, height and depth of a code point in a table of the module, which
//! outlives the formula and every document (`\unicode[Garamond]{x263A}` makes
//! each later `\unicode{x263A}` Garamond). MathJax reads the bracket from
//! whatever follows the command once macros are expanded, so the text of a
//! math does not show whether a `\unicode` reads one (`\newcommand{\U}{\unicode}`
//! with `\U[Garamond]{x263A}` after it, or `\app{\unicode}[Garamond]{x263A}`).
//! Under [`Engine::MathJax`] a `\unicode` whose next character, after
//! JavaScript white space, is not `{` may read a font (a `{` is the code
//! point, never a bracket): a math that holds one is affecting, a definition
//! that holds one is opaque (the macro takes its font from the text after the
//! call), and so is a `\let` of the command whatever follows the target.
//! `\newcommand{\smile}{\unicode{x263A}}` stays followed. Everything else is
//! taken to change nothing that a later formula can see.
//!
//! # Comments
//!
//! The engines differ about a `%` only where a command is reading something:
//! a braced argument, the optional argument of `\newcommand`, the parameter
//! text of a `\def`, or the single token that stands for an argument. Where
//! no command is reading anything, `%` is a comment up to the end of its line
//! in both: KaTeX's lexer drops it (a `%` that is a token of its own: with a
//! combining mark after it, the two are one token there and no comment), and
//! MathJax's parser maps it to a comment once the handler of the definition
//! has returned, provided that handler read the definition the walk read
//! (below). So
//! `$$\newcommand{\R}{\mathbb{R}} % reals$$`, a macro cell at the top of a
//! notebook with a note after each line, is followed like the same cell
//! without the notes. Were it opaque, every later formula would re-key on
//! every edit anywhere in the notebook after it.
//!
//! The scan tracks such a *safe point*. It holds at the start of the math,
//! right after a definition that began at a safe point and that both engines
//! end where the walk does, and right after the newline that ends a comment
//! met at a safe point, with nothing but white space in between: the blanks
//! of both engines (space, tab, carriage return, newline) and the other white
//! space of JavaScript that KaTeX lexes (U+00A0, U+1680, U+2000 to U+200A,
//! U+202F, U+205F, U+3000, U+FEFF), which both engines read as a character
//! that takes no argument or as a space, so that
//! `\newcommand{\R}{\mathbb{R}}<U+00A0>% reals` (a no-break space is one
//! Option+Space on a layout that types the braces with Option) is followed
//! like the same line with a space. A form feed, a vertical tab, U+2028 and
//! U+2029 are errors to KaTeX and clear the point, and so does a combining
//! mark after any white space (one token with it to KaTeX).
//! Any other byte or token clears the point, and so does `\global` or
//! `\long` (whose definition is still to come and starts where the prefix
//! did; there only ASCII blanks may follow it, as KaTeX's `\global` is an
//! error before any other token). A `%` at a safe point skips to the end of
//! its line without noting anything, and the words in it do not count, unless
//! a combining mark follows it (one token with it to KaTeX, so no comment
//! there). Every other `%` is noted and, in a math that defines something,
//! makes the scope opaque.
//!
//! Two forms of a definition are read further by the walk than by one of
//! the engines, so the engine's handler returns while the walk is still
//! inside the definition, and what the walk takes after that point is formula
//! text to the engine:
//!
//! - a `*` after a command of the `\newcommand` family: both engines take
//!   the `*` as the name of the macro (KaTeX 0.16 defines `*` in
//!   `\renewcommand*{\a}{x}` and refuses `\newcommand*` because `*` exists,
//!   MathJax 3 defines `\*`), so `\a` is the body and `{x}` is typeset;
//! - a default argument: KaTeX reads the count of `\newcommand\g[1][x]{y}`
//!   but no default, so the body of `\g` is the `[` and `x]{y}` is typeset.
//!
//! (A name that is a control word with an `@` after its letters, and the
//! commands MathJax lacks, are ended earlier by one engine too; they are
//! outside the model and opaque, above.)
//!
//! A command in that formula text can read the next `%` as its argument (a
//! `\url` in KaTeX, which reads its address with `%` as a character, a `\hat`
//! in MathJax, whose argument reader does not look for comments), and then
//! the text after the `%` runs: in
//! `\newcommand\g[1][x]\url % \def\b{\gdef\c{X}}` KaTeX defines `\b`. So
//! such a definition keeps no safe point after it: a note after it is noted
//! and makes the scope opaque (the definition is affecting), and without a
//! note it is followed like any other.
//!
//! A definition keeps the safe point it started at and never creates one: it
//! is the note after a definition *at the top level of the math* that is
//! followed. In `\url{\def\a{1} % }\def\b{\gdef\c{X}}` the definition ends
//! while `\url` is still reading its argument. KaTeX reads the `%` of a `\url`
//! or `\href` address as an ordinary character, so the `}` after it closes the
//! argument and `\def\b` runs; MathJax's `GetArgument` counts the braces inside
//! a comment, so in `\text{\def\a{1} % }` it closes the argument at that `}`
//! where KaTeX, which drops the comment, does not. The same holds in
//! `\mathrm`, `\frac` and every other braced argument, in a group, in an
//! environment and after a word of plain text. Were that `%` taken as a
//! comment, the text after it would run in one engine and be hidden by the
//! scope, and a render cached by (text, `env`) would go stale instead of
//! missing. (A definition in the argument of a command is not followed at
//! all, since the command may be a macro: see the opaque list. This rule is
//! what keeps a note in a group or after characters, `{\def\a{1} % }` or
//! `x\def\a{1} % c`, from being taken for a comment.)
//!
//! A `%` that the walk of a definition reads (as its body, its parameter text
//! or inside its braces) is noted by the walk, so `\newcommand{\R} %c` with
//! `{x}` on the next line stays opaque, and so does `x^%` with a `\def` on
//! the next line, because the `x` has cleared the safe point.
//!
//! # Where each engine ends a definition
//!
//! The scope follows a definition, and keeps the safe point after it, only
//! where both engines read it as the walk does. Here are the readers each
//! engine runs for the commands the scope tracks, as KaTeX 0.16.21 (the same
//! in 0.16.47) and MathJax 3.2.2 with all its packages have them, and where
//! each one ends against the walk.
//!
//! The tokens. The walk reads `\` and ASCII letters as a control word, noting
//! an `@` and letters after them (outside the model), `\` and one whole
//! character as a control symbol, and any other byte alone. KaTeX's lexer
//! reads `\` and letters or `@` as a control word (so `\a@b` and `\@ab` are
//! one name there), `\` and one UTF-16 unit as a control symbol, a character
//! together with the combining marks (U+0300 to U+036F) after it as one
//! token, a run of `[ \r\n\t]` as one space, `\verb` and its text as one
//! token, and a `%` token as the start of a comment that ends after the next
//! newline. MathJax reads `\` and letters as a control word (an `@` ends it),
//! `\` and one character as a control symbol, and every other character
//! alone. A combining mark, a control character and white space beyond ASCII
//! inside a definition are outside the model whichever way an engine reads
//! them (opaque, above).
//!
//! The readers:
//!
//! - Before each part (the name, a `*`, a count, a default, a body, the `=`
//!   of `\let` and its target) KaTeX skips its space tokens and MathJax every
//!   character of JavaScript `\s` (`GetNext`). The walk skips ASCII blanks
//!   and form feeds; a form feed, a vertical tab or a wider space (U+00A0,
//!   U+2000 to U+200A, U+3000, U+FEFF and the others of `\s`) inside a
//!   definition is outside the model: opaque.
//! - The name: one argument of the `\newcommand` family (KaTeX `consumeArg`,
//!   a token or a group of one token; MathJax `GetCsNameArgument`) and of
//!   `\DeclareMathOperator` (MathJax `GetArgument`), the next token after
//!   `\def` and `\let` (KaTeX `popToken`; MathJax `GetCSname`). It is the
//!   walk's control word or symbol. A name with an `@` (`\a@b`, `\@ab`: one
//!   name to KaTeX, shorter to MathJax) or a control symbol over a non-ASCII
//!   character is outside the model: opaque.
//! - A `*` after the `\newcommand` family is the name in both engines, and
//!   what the walk reads after it is formula text (an earlier end, no safe
//!   point). KaTeX's `\renewcommand*` defines the character `*` itself as a
//!   macro (`\newcommand*` is an error there, since `*` exists, and
//!   `\providecommand*` defines nothing), so a later `*` can be a macro with
//!   arguments: opaque. After `\DeclareMathOperator` MathJax reads the `*`
//!   as the walk does (`GetStar`).
//! - The count: KaTeX reads the argument after the name and, when that is
//!   the single token `[`, braced or not, reads the tokens up to `]`,
//!   expanding macros; MathJax reads `[...]` (`GetBrackets`). The walk reads
//!   `[`, blanks, digits and `]`, and anything else there does not parse. So
//!   a braced `{[}` there is a count to KaTeX and the body to MathJax and the
//!   walk: a later end, opaque.
//! - A default argument: MathJax reads it (`GetBrackets`), KaTeX has none and
//!   takes its `[` as the body: an earlier end, no safe point.
//! - The body of the `\newcommand` family and of `\DeclareMathOperator` is
//!   one token or a balanced group (KaTeX `consumeArg` counts the tokens `{`
//!   and `}`, MathJax `GetArgument` the characters `{` and `}` that no `\`
//!   escapes, comments included). The walk counts the bytes `{` and `}` that
//!   are not a control symbol, so all three end a group at the same `}`,
//!   except where a combining mark follows a brace, which is then no brace to
//!   KaTeX (a mark is outside the model: opaque). A body of one character is
//!   its first byte to the walk and the whole character to KaTeX: what lies
//!   between those ends is the rest of the character, which the scan reads as
//!   text either way (a mark after it is outside the model too).
//! - The parameter text of a `\def`: KaTeX reads tokens up to the token `{`,
//!   MathJax characters up to the character `{` without reading `\` as an
//!   escape (`GetTemplate`). So the `{` of a `\{` starts MathJax's body: a
//!   later end, opaque. A `{` with a combining mark starts no body in KaTeX,
//!   and a non-ASCII character in the parameter text is not modelled: outside
//!   the model, opaque. The body is a balanced group, as above. KaTeX expands
//!   the body of an `\edef` or `\xdef` when it defines the macro
//!   (`expandTokens`), on the token stack it reads the text from, so a macro
//!   with arguments in the body reads on past its `}`: a later end, opaque
//!   unless the body holds no command.
//! - The target of a `\let`: an optional `=`, then one optional space token
//!   (KaTeX `getRHS`, where a run of blanks is one token) or any white space
//!   (MathJax `GetNext`), then one token (KaTeX), one control sequence or one
//!   character (MathJax), as the walk reads it; a target with an `@` is
//!   outside the model (opaque).
//! - A prefix: KaTeX's `\global` and `\long` expand what follows them and
//!   take the definition there (anything but a `\def`, `\let`, `\futurelet`
//!   or prefix then stops KaTeX with an error, after the expansion: a
//!   `\newcommand`, a macro, has defined its name by then); MathJax has
//!   neither and typesets the name, which reads nothing: outside the model
//!   under MathJax (opaque).
//! - A command an engine does not have. MathJax 3 has no `\providecommand`,
//!   `\gdef`, `\edef`, `\xdef`, `\global` or `\long` (its `newcommand`
//!   package defines `\newcommand`, `\renewcommand`, `\def` and `\let`): it
//!   typesets the name, and the rest is formula text. That is outside the
//!   model: a math that uses one is opaque under MathJax. KaTeX has no
//!   `\DeclareMathOperator` and stops there with an error.
//! - A `%` that the walk reads inside a definition is dropped with its line
//!   by KaTeX's lexer and read as a character by MathJax's readers, so a math
//!   that defines something and holds one is opaque (above).
//!
//! All of these read the text as it stands only where no macro is taking
//! arguments: a macro of the document (or KaTeX's `\@firstoftwo`) before a
//! definition can take a part of it, and the engine then reads the
//! definition from the tokens the macro gives back. Hence the rule above that
//! a definition after a command is not followed.
//!
//! An engine that stops with an error reads nothing after it, so an error is
//! never a later end. A later end is opaque: what lies between the two ends
//! is part of that engine's definition, so a defining command there is stored
//! in a macro body (which the scope's rule makes opaque), with or without a
//! note after it. An earlier end (a `*` or a default argument) keeps the
//! definition followed, since the walk reads every token of the rest and a
//! defining command among them still counts, but leaves no safe point after
//! it.
//!
//! # Engine gaps the grammar does not paper over
//!
//! The TeX is handed to the engine as the reference hands it (with MathJax's
//! own starred forms of a numbered `eqnarray` and `multline`, deviation D6),
//! so the engines' own gaps show. KaTeX 0.16.21 has no `flalign`, `flalign*`,
//! `multline*`, `eqnarray` or `eqnarray*` environment (in the KaTeX text a
//! numbered `flalign` is passed on as `flalign*`, a numbered `eqnarray`
//! becomes `align*` and a numbered `multline` `gather*`, the reference's
//! stand-ins; MathJax gets `eqnarray*` and `multline*`, which it draws), and
//! it has neither the `*` forms
//! of the `\newcommand` family nor a default argument (above:
//! `\newcommand*` is an error, `\renewcommand*{\a}{x}` defines `*`,
//! `\providecommand*` defines nothing, and `\newcommand\g[1][x]{y}` gives `\g`
//! the body `[`). MathJax 3.2.2 has
//! no `\providecommand`, `\gdef`, `\edef`, `\xdef`, `\global` or `\long`
//! (the `noundefined` package typesets each as its name, and the rest of a
//! definition is formula text); under [`Engine::MathJax`] a math that uses
//! one makes the scope opaque. They are errors or wrong output in the
//! typeset math, as in the reference; a mapping belongs to the layer that
//! runs the engine, where it can be checked against the engine itself.

use std::collections::{HashMap, HashSet};

use super::jsstr::{at, js_ws_len};
use super::katex_names::KATEX_ONLY;

/// The byte length of the run of JavaScript white space at `i`.
fn ws_run(s: &[u8], mut i: usize) -> usize {
    let start = i;
    loop {
        let n = js_ws_len(s, i);
        if n == 0 {
            return i - start;
        }
        i += n;
    }
}

/// The end of a comment that starts at `i` (a `%`): after the line feed that
/// ends it, or the end of the text. KaTeX and MathJax both end it there.
fn comment_end(s: &[u8], i: usize) -> usize {
    match s.get(i..).and_then(|t| t.iter().position(|&c| c == b'\n')) {
        Some(n) => i + n + 1,
        None => s.len(),
    }
}

/// The end of the white space and the comments from `i`: both are nothing
/// between the parts of a definition. The white space is the blanks of
/// KaTeX's lexer (space, tab, line feed and carriage return): any other
/// character, a no-break space included, is the token that follows, which
/// KaTeX takes for the name or the body.
fn skip_blank(s: &[u8], mut i: usize) -> usize {
    loop {
        if is_blank(at(s, i)) {
            i += 1;
        } else if at(s, i) == b'%' {
            i = comment_end(s, i);
        } else {
            return i;
        }
    }
}

/// The end of a control word's letters from `i`, `@` counting as a letter as
/// it does for KaTeX (`\a@b` is one word there).
fn word_end(s: &[u8], mut i: usize) -> usize {
    while at(s, i).is_ascii_alphabetic() || at(s, i) == b'@' {
        i += 1;
    }
    i
}

/// A character the dot of a JavaScript regular expression does not match.
fn is_line_end(c: char) -> bool {
    matches!(c, '\n' | '\r' | '\u{2028}' | '\u{2029}')
}

/// The characters of one line of a math, from the first place a `\verb` asked
/// about it, and where each last stands: the answer to "does this delimiter
/// come back on the line" in one lookup, for every `\verb` on the line. A
/// search that read to the end of the line for each `\verb` that has no
/// closing delimiter would be quadratic in their number.
struct VerbLine {
    from: usize,
    end: usize,
    last: HashMap<char, usize>,
}

/// The end of the verbatim text that `\verb` (whose letters end at `i`)
/// starts, or `None` when there is none. KaTeX reads it as `\verb`, an
/// optional `*`, a delimiter and everything up to the next copy of the
/// delimiter, with no line terminator in between (`\verb\*([^]).*?\4` and
/// `\verb([^*a-zA-Z]).*?\5` of its lexer, whose `.` matches no line
/// terminator); a `%` inside is part of the text. `line` holds what the
/// earlier `\verb` of the math learnt about their line.
fn verb_end(tex: &str, i: usize, line: &mut Option<VerbLine>) -> Option<usize> {
    let mut at_delim = i;
    if at(tex.as_bytes(), at_delim) == b'*' {
        at_delim += 1;
    }
    let delim = tex.get(at_delim..)?.chars().next()?;
    let from = at_delim + delim.len_utf8();
    // a line terminator as the delimiter: the text runs to the next line terminator, which closes
    // it when it is the delimiter again (`\verb<LF>abc<LF>` is the text `abc`); another one first,
    // or none, and there is no text. This reads the line after the delimiter once, and that line
    // terminator is the delimiter of this `\verb` alone, so each line is read once for all of them.
    if is_line_end(delim) {
        let (pos, c) = tex
            .get(from..)?
            .char_indices()
            .find(|&(_, c)| is_line_end(c))?;
        return (c == delim).then(|| from + pos + c.len_utf8());
    }
    if !line
        .as_ref()
        .is_some_and(|l| l.from <= from && from <= l.end)
    {
        let mut last = HashMap::new();
        let mut pos = from;
        for c in tex.get(from..)?.chars() {
            if is_line_end(c) {
                break;
            }
            last.insert(c, pos);
            pos += c.len_utf8();
        }
        *line = Some(VerbLine {
            from,
            end: pos,
            last,
        });
    }
    // the first delimiter at or after `from` is on the line when the last one is
    let last = *line.as_ref()?.last.get(&delim)?;
    if last < from {
        return None;
    }
    let first = from + tex.get(from..)?.find(delim)?;
    Some(first + delim.len_utf8())
}

/// What the `\newcommand` or `\providecommand` whose word ends at some byte
/// is about (see [`definition_name`]).
enum Name {
    /// The letters of the name it claims, as a byte range (`@` counts as one,
    /// so the name of `\newcommand{\R@x}` is `R@x`), and whether a brace
    /// opened it: the scan goes on before the closing brace, so that is one
    /// more open group for it to count.
    Letters(usize, usize, bool),
    /// A `\verb` token stands where the name should: it is the name KaTeX
    /// hands over, nothing is claimed, and the scan goes on at this byte,
    /// with one more open group if a brace opened it.
    Skip(usize, bool),
    /// No name: nothing is claimed or rewritten.
    Missing,
}

/// The end of the comments from `i`: none, one or several in a row, with
/// nothing between them (a blank after one is a token of KaTeX's).
fn skip_comments(s: &[u8], mut i: usize) -> usize {
    while at(s, i) == b'%' {
        i = comment_end(s, i);
    }
    i
}

/// The end of the `\verb` token whose backslash is at `i`, if it starts one
/// (see [`verb_end`]); `\verbx` is a control word and gives `None`.
fn verb_token_end(tex: &str, i: usize, line: &mut Option<VerbLine>) -> Option<usize> {
    let word = i + 1;
    let verb = word + 4;
    if tex.as_bytes().get(word..)?.starts_with(b"verb")
        && !at(tex.as_bytes(), verb).is_ascii_alphabetic()
    {
        return verb_end(tex, verb, line);
    }
    None
}

/// The end of the token KaTeX lexes at `i`, a backslash: a `\verb` token, a
/// control word (letters and `@`) or a control symbol (the backslash and the
/// character after it, a lone backslash at the end of the text included).
fn control_token_end(tex: &str, i: usize, line: &mut Option<VerbLine>) -> usize {
    if let Some(stop) = verb_token_end(tex, i, line) {
        return stop;
    }
    let word = i + 1;
    let end = word_end(tex.as_bytes(), word);
    if end > word {
        return end;
    }
    word + tex
        .get(word..)
        .and_then(|t| t.chars().next())
        .map_or(0, char::len_utf8)
}

/// What the `\newcommand` or `\providecommand` whose word ends at `i` is
/// about, the way KaTeX reads its first argument: blanks and comments, then
/// either one token or a group that holds exactly one token.
///
/// Without a brace the name is the control word that follows (`@` counts as a
/// letter, as in KaTeX). With one, only comments may stand between the brace
/// and the control word (a blank is a token of its own, and so is anything
/// else but the name), and after the word only blanks (the control word takes
/// those) and comments before the closing brace; any other group is an error
/// to KaTeX and names nothing. A `\verb` token where the name should be is
/// the name, tried before the control word as KaTeX's lexer does.
fn definition_name(tex: &str, i: usize, line: &mut Option<VerbLine>) -> Name {
    let s = tex.as_bytes();
    let mut i = skip_blank(s, i);
    let braced = at(s, i) == b'{';
    if braced {
        i = skip_comments(s, i + 1);
    }
    if at(s, i) != b'\\' {
        return Name::Missing;
    }
    if let Some(stop) = verb_token_end(tex, i, line) {
        return Name::Skip(stop, braced);
    }
    let start = i + 1;
    let end = word_end(s, start);
    if end == start {
        return Name::Missing;
    }
    if braced {
        let mut close = end;
        while is_blank(at(s, close)) {
            close += 1;
        }
        if at(s, skip_comments(s, close)) != b'}' {
            return Name::Missing;
        }
    }
    Name::Letters(start, end, braced)
}

/// What a `}` the address scan meets at `i` means, with `open` groups open
/// around the command (see [`rewrite_newcommand`]): at 0 it closes no group,
/// KaTeX reports "Extra }" and the formula ends there, so the end of the text
/// comes back. Otherwise it closes one of them: `i`, for the main scan to
/// read it and go on.
fn closing_brace(s: &[u8], i: usize, open: usize) -> usize {
    if open == 0 {
        s.len()
    } else {
        i
    }
}

/// The end of the argument of `\url` or `\href` whose control word ends at
/// `i`, or of the address of `\includegraphics` that starts at `i` (see
/// [`includegraphics_end`]), with `open` groups open around the command.
/// KaTeX reads that argument with `%` an ordinary character (its parser gives
/// `%` the category code of an ordinary character while it reads the
/// address), so no comment starts there. After the blanks
/// the lexer takes with the control word the argument is either one token (a
/// control word, a control symbol, a `\verb` token or one character, `%`
/// included) or a group up to its matching brace, in which a backslash takes
/// the next character (`\}` closes nothing) and a `\verb` token is one token.
/// A group that is never closed is an error to KaTeX, which reads nothing
/// after it: it ends at the end of the text, so the scan reads each byte
/// once. A `}` where the argument starts (`\url}`, blanks before it allowed)
/// goes to [`closing_brace`]. Only these follow a KaTeX error; a `}` after a
/// whole address (`\url{}}`) is read on, as LaTeX reads on after an error, and
/// a control symbol `\}` is the one token.
fn url_argument_end(tex: &str, i: usize, open: usize, line: &mut Option<VerbLine>) -> usize {
    let s = tex.as_bytes();
    let mut i = i;
    while is_blank(at(s, i)) {
        i += 1;
    }
    if i >= s.len() {
        return s.len();
    }
    if at(s, i) == b'}' {
        return closing_brace(s, i, open);
    }
    if at(s, i) == b'\\' {
        return control_token_end(tex, i, line);
    }
    if at(s, i) != b'{' {
        return i + tex
            .get(i..)
            .and_then(|t| t.chars().next())
            .map_or(1, char::len_utf8);
    }
    let mut depth = 1usize;
    i += 1;
    while i < s.len() {
        match at(s, i) {
            b'{' => depth += 1,
            b'}' => {
                depth -= 1;
                if depth == 0 {
                    return i + 1;
                }
            }
            b'\\' => {
                i = control_token_end(tex, i, line);
                continue;
            }
            _ => {}
        }
        i += 1;
    }
    s.len()
}

/// The end of the arguments of `\includegraphics` whose control word ends at
/// `i`. KaTeX looks for its optional argument with the usual lexer, so the
/// blanks and comments before it are nothing; a `[` starts it and it runs to
/// the first `]` outside any group, a `%` in it starting a comment and a
/// `\verb` token being one token. The end of the text there is an error to
/// KaTeX: the formula ends there, so the scan does too. A `}` outside the
/// groups of the brackets goes to [`closing_brace`]. Then comes the address,
/// read as for `\url` (see [`url_argument_end`], with or without the
/// brackets); a definition inside the brackets or the address is not looked
/// at. Each byte is read once.
fn includegraphics_end(tex: &str, i: usize, open: usize, line: &mut Option<VerbLine>) -> usize {
    let s = tex.as_bytes();
    let mut i = skip_blank(s, i);
    if at(s, i) != b'[' {
        return url_argument_end(tex, i, open, line);
    }
    i += 1;
    let mut depth = 0usize;
    while i < s.len() {
        match at(s, i) {
            b'%' => {
                i = comment_end(s, i);
                continue;
            }
            b'\\' => {
                i = control_token_end(tex, i, line);
                continue;
            }
            b'{' => depth += 1,
            b'}' => {
                if depth == 0 {
                    return closing_brace(s, i, open);
                }
                depth -= 1;
            }
            b']' if depth == 0 => return url_argument_end(tex, i + 1, open, line),
            _ => {}
        }
        i += 1;
    }
    s.len()
}

/// Rewrites the first `\newcommand` or `\providecommand` of each KaTeX-only
/// name to `\renewcommand`; `defined` holds the names defined so far in the
/// document and gets every name a definition here claims.
pub fn katex_newcommand(tex: &str, defined: &mut HashSet<String>) -> String {
    rewrite_newcommand(tex, defined).0
}

/// [`katex_newcommand`], and whether it rewrote anything. It rewrites
/// exactly when a KaTeX-only name enters `defined` (the other names it adds
/// never decide a later rewrite), so a `true` is the one way this rule changes
/// the TeX of a later math.
///
/// The text is read as KaTeX lexes it, so only a control word counts: the
/// `\newcommand` of a comment, of `\\newcommand` (a line break and letters),
/// of `\verb|\newcommand\R|` or inside the address of a `\url`, `\href` or
/// `\includegraphics` (or the brackets before the last) is not one, and a `%`
/// in that address is no comment (see the module
/// documentation). The name is read as KaTeX's `\newcommand` receives it (see
/// [`definition_name`]). `open` counts the groups open at the scan: a
/// definition body, a braced name and the argument of a macro count like any
/// other group, because KaTeX parses no command there and a `}` right after
/// one closes the group (see [`closing_brace`]); a `}` that closes none leaves
/// it at 0. The count takes no allocation and no second reading.
fn rewrite_newcommand(tex: &str, defined: &mut HashSet<String>) -> (String, bool) {
    let b = tex.as_bytes();
    // `out` holds `tex[..copied]` with the rewrites; nothing is allocated when there is none
    let mut out = String::new();
    let mut copied = 0;
    let mut i = 0;
    let mut open = 0usize;
    let mut verb_line = None;
    while i < b.len() {
        match b[i] {
            b'%' => i = comment_end(b, i),
            b'{' => {
                open += 1;
                i += 1;
            }
            b'}' => {
                open = open.saturating_sub(1);
                i += 1;
            }
            b'\\' => {
                let word = i + 1;
                let end = word_end(b, word);
                if end == word {
                    // a control symbol: the backslash and the character after it
                    i = word
                        + tex
                            .get(word..)
                            .and_then(|t| t.chars().next())
                            .map_or(0, char::len_utf8);
                    continue;
                }
                // KaTeX tries `\verb` before the control word: `\verb@x@` is verbatim text
                // and `\verbx` is a word
                if let Some(stop) = verb_token_end(tex, i, &mut verb_line) {
                    i = stop;
                    continue;
                }
                i = end;
                match tex.get(word..end) {
                    // the address is read with `%` an ordinary character, after the brackets of
                    // `\includegraphics`
                    Some("url" | "href") => {
                        i = url_argument_end(tex, end, open, &mut verb_line);
                        continue;
                    }
                    Some("includegraphics") => {
                        i = includegraphics_end(tex, end, open, &mut verb_line);
                        continue;
                    }
                    Some("newcommand" | "providecommand") => {}
                    _ => continue,
                }
                let (from, to) = match definition_name(tex, end, &mut verb_line) {
                    Name::Letters(from, to, braced) => {
                        open += usize::from(braced);
                        (from, to)
                    }
                    Name::Skip(stop, braced) => {
                        open += usize::from(braced);
                        i = stop;
                        continue;
                    }
                    Name::Missing => continue,
                };
                let name = tex.get(from..to).unwrap_or_default();
                if !defined.contains(name) {
                    if KATEX_ONLY.binary_search(&name).is_ok() {
                        out.push_str(tex.get(copied..word).unwrap_or_default());
                        out.push_str("renewcommand");
                        copied = end;
                    }
                    defined.insert(name.to_string());
                }
                i = to;
            }
            _ => i += 1,
        }
    }
    if copied == 0 {
        return (tex.to_string(), false);
    }
    out.push_str(tex.get(copied..).unwrap_or_default());
    (out, true)
}

/// The typesetting engine the macro rule is for.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Engine {
    /// KaTeX: the `\newcommand` rule applies.
    Katex,
    /// MathJax: its `\newcommand` never refuses a redefinition, so the TeX is passed on as it is.
    /// MathJax 3 has no `\providecommand`, `\gdef`, `\edef`, `\xdef`, `\global` or `\long`, so
    /// a math that uses one is opaque here (see the module documentation).
    MathJax,
}

/// One math's TeX for the engine, with the macro environment it is typeset in.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EngineTex {
    /// The TeX to hand to the engine.
    pub tex: String,
    /// A hash of every macro-affecting math before this one in the document.
    pub env: u64,
    /// Whether this math defines or changes a macro, or (under KaTeX) the
    /// `\newcommand` rule rewrote it, or an earlier math was one the scope
    /// cannot follow. When it is `false`, the environment, the TeX and the
    /// decision of every later math are the same whatever this math says,
    /// for the same engine text of those maths (what
    /// [`super::prepare_tex_for`] gives for the engine, the input of
    /// [`MacroScope::next`]). Numbers and references are document-wide there,
    /// so an edit of this math can still change that text: rerun the
    /// preparation on every change and key a typeset formula by
    /// ([`EngineTex::tex`], [`EngineTex::env`]), never by
    /// [`super::PreparedDoc::prepared`]. That is the reference's text, which
    /// under MathJax is not the engine's: an `eqnarray` and an `align` with
    /// the same body have the same `prepared` and env and different MathJax
    /// text (deviation D6). See the module documentation.
    pub affecting: bool,
}

// ---- reading TeX tokens ----

/// A token of a math. Comments are not skipped: `%` is a byte like any other.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Tok<'a> {
    /// `\` and ASCII letters: the letters alone (how MathJax reads the name)
    /// and the letters followed by `@` and letters (how KaTeX reads it, `@`
    /// being a letter there). The two are equal unless an `@` follows.
    Word(&'a [u8], &'a [u8]),
    /// `\` and one other character, such as `\\`, `\%`, `\{` or `\` and a
    /// letter with an accent. `\@` is one too, as MathJax reads it, though
    /// KaTeX reads `\@` and the letters or `@` after it as one control word
    /// (outside the model, see [`Walk::take`]).
    Sym,
    /// `\` and a character outside the basic plane (four bytes of UTF-8):
    /// MathJax reads a control symbol, KaTeX does not read it.
    Astral,
    /// Any other byte.
    Byte(u8),
}

#[derive(Clone, Copy)]
struct Cursor<'a> {
    s: &'a [u8],
    i: usize,
}

impl<'a> Cursor<'a> {
    /// The next token, or `None` at the end.
    fn next(&mut self) -> Option<Tok<'a>> {
        let b = *self.s.get(self.i)?;
        if b != b'\\' {
            self.i += 1;
            return Some(Tok::Byte(b));
        }
        let start = self.i + 1;
        let mut j = start;
        while at(self.s, j).is_ascii_alphabetic() {
            j += 1;
        }
        if j == start {
            // a `\` at the very end is a byte of its own
            let Some(&lead) = self.s.get(start) else {
                self.i = start;
                return Some(Tok::Byte(b'\\'));
            };
            // one control symbol over the whole character, not its first byte
            let len = match lead {
                0xF0..=0xF7 => 4,
                0xE0..=0xEF => 3,
                0xC0..=0xDF => 2,
                _ => 1,
            };
            self.i = (start + len).min(self.s.len());
            return Some(if len == 4 { Tok::Astral } else { Tok::Sym });
        }
        let mut k = j;
        while at(self.s, k).is_ascii_alphabetic() || at(self.s, k) == b'@' {
            k += 1;
        }
        self.i = k;
        Some(Tok::Word(
            self.s.get(start..j).unwrap_or_default(),
            self.s.get(start..k).unwrap_or_default(),
        ))
    }

    /// After a `%` was read: moves past the end of its line, the newline
    /// included, or to the end of the text when the line has none. Both
    /// engines end a comment at the first `\n` and nowhere else.
    fn skip_comment(&mut self) {
        let rest = self.s.get(self.i..).unwrap_or_default();
        self.i += rest
            .iter()
            .position(|&c| c == b'\n')
            .map_or(rest.len(), |p| p + 1);
    }

    /// Moves to the next `\` or `%`: the bytes in between are neither
    /// commands nor the start of a comment.
    fn skip_to_special(&mut self) {
        let rest = self.s.get(self.i..).unwrap_or_default();
        self.i += rest
            .iter()
            .position(|&c| c == b'\\' || c == b'%')
            .unwrap_or(rest.len());
    }
}

fn is_space(b: u8) -> bool {
    matches!(b, b' ' | b'\t' | b'\n' | b'\r' | 0x0c)
}

/// Whether a combining mark starts at `i`: U+0300 to U+036F, U+1AB0 to U+1AFF,
/// U+1DC0 to U+1DFF, U+20D0 to U+20FF or U+FE20 to U+FE2F. KaTeX's lexer reads
/// a character and the marks of the first block after it as one token, so `}`
/// with a mark closes nothing there and `%` with a mark starts no comment; the
/// other blocks are marks of the same kind that no engine is known to treat
/// alike, and the walk does not model them either. The 2 or 3 bytes of the
/// character are decoded through [`at`]; a continuation byte or any other
/// byte gives `false`.
fn combining_at(s: &[u8], i: usize) -> bool {
    let (b0, b1, b2) = (at(s, i), at(s, i + 1), at(s, i + 2));
    let cont = |b: u8| (0x80..=0xbf).contains(&b);
    let cp = match b0 {
        0xc2..=0xdf if cont(b1) => (u32::from(b0 & 0x1f) << 6) | u32::from(b1 & 0x3f),
        0xe0..=0xef if cont(b1) && cont(b2) => {
            (u32::from(b0 & 0x0f) << 12) | (u32::from(b1 & 0x3f) << 6) | u32::from(b2 & 0x3f)
        }
        _ => return false,
    };
    matches!(
        cp,
        0x300..=0x36f | 0x1ab0..=0x1aff | 0x1dc0..=0x1dff | 0x20d0..=0x20ff | 0xfe20..=0xfe2f
    )
}

/// Whether the character at `i` is one the walk does not model: a combining
/// mark, a control character below U+0020 other than tab, newline and carriage
/// return (a form feed and a vertical tab among them), or white space beyond
/// ASCII (U+00A0, U+1680, U+2000 to U+200A, U+2028, U+2029, U+202F, U+205F,
/// U+3000, U+FEFF). The engines read these in different places (KaTeX makes a
/// character and its marks one token and cannot lex a control character,
/// MathJax skips every character of JavaScript `\s` before an argument), so a
/// definition that holds one is opaque.
fn outside_model_at(s: &[u8], i: usize) -> bool {
    // (the end of the text is not a character: `at` would answer a NUL there)
    let Some(&b) = s.get(i) else { return false };
    combining_at(s, i)
        || (b < 0x20 && !matches!(b, b'\t' | b'\n' | b'\r'))
        || (b >= 0x80 && js_ws_len(s, i) > 0)
}

/// Whether the bytes of a definition, from the end of its command word to
/// where the walk stopped, hold a character outside the model, or a combining
/// mark follows the last of them (right after the last token, past the rest of
/// a multi-byte character the walk took one byte of). One pass over the
/// bytes, and the ranges of successive definitions do not overlap, so the scan
/// of a math stays linear.
fn exotic_in(s: &[u8], from: usize, to: usize) -> bool {
    let end = to.min(s.len());
    for i in from..end {
        // (only a control character or a byte of a multi-byte character can be outside the model)
        let b = s.get(i).copied().unwrap_or(0);
        if !(0x20..0x80).contains(&b) && outside_model_at(s, i) {
            return true;
        }
    }
    let mut j = to;
    while (0x80..=0xbf).contains(&at(s, j)) {
        j += 1;
    }
    combining_at(s, j)
}

/// The names of the definition commands that MathJax 3 does not have (its
/// `newcommand` package defines `\newcommand`, `\renewcommand`, `\def` and
/// `\let`, and the `ams` package `\DeclareMathOperator`). It has no
/// `\global` and `\long` either, the prefixes, which `analyze` tests by their
/// class. Under [`Engine::MathJax`] a math that uses one of the six is opaque.
fn mathjax_lacks(name: &[u8]) -> bool {
    matches!(name, b"providecommand" | b"gdef" | b"edef" | b"xdef")
}

/// The white space both engines read as a space between two tokens of the
/// text: KaTeX's lexer takes `[ \r\n\t]`, MathJax's parser maps the same four.
/// (A form feed is white space to `is_space`, the wider test the walk uses
/// between a definition's parts. Inside a definition it is outside the model
/// (opaque), and between definitions it clears the safe point, since KaTeX
/// cannot lex it.)
fn is_blank(b: u8) -> bool {
    matches!(b, b' ' | b'\t' | b'\n' | b'\r')
}

/// Whether the `\unicode` whose letters end at `i` may read a font: the next
/// character, after JavaScript white space, is not `{`. MathJax 3.2.2 reads an
/// optional `[font]` right after the command (`GetBrackets`, from whatever
/// follows it once macros are expanded) and keeps the font (and the height and
/// depth) for the code point, in a table of its `unicode` package that every
/// later `\unicode` of that code point without a font uses. When the next
/// character is `{` it reads no bracket, whatever the text around says.
fn unicode_may_read_font(s: &[u8], i: usize) -> bool {
    at(s, i + ws_run(s, i)) != b'{'
}

/// Whether `s` holds nothing but white space that both engines read as
/// something that takes no argument: the ASCII blanks and the non-ASCII white
/// space of JavaScript that KaTeX's lexer reads (U+00A0, U+1680, U+2000 to
/// U+200A, U+202F, U+205F, U+3000, U+FEFF; not U+2028 and U+2029, which it
/// refuses, like the form feed and the vertical tab). It is walked character
/// by character, so a combining mark after one ends the run.
fn only_white_space(s: &[u8]) -> bool {
    let mut i = 0;
    while i < s.len() {
        let n = match js_ws_len(s, i) {
            0 => return false,
            1 if is_blank(s[i]) => 1,
            // the ASCII white space that is not a blank: a form feed, a vertical tab
            1 => return false,
            // U+2028 and U+2029
            3 if at(s, i) == 0xe2
                && at(s, i + 1) == 0x80
                && matches!(at(s, i + 2), 0xa8 | 0xa9) =>
            {
                return false;
            }
            n => n,
        };
        i += n;
    }
    true
}

/// What a control word does to the macro state.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Class {
    /// Nothing the scope tracks.
    Plain,
    /// `\global`, `\long`: a prefix of the definition that follows.
    Prefix,
    /// `\newcommand`, `\renewcommand`, `\providecommand`.
    NewCommand,
    /// `\def`, `\gdef`, `\edef`, `\xdef`.
    Def,
    /// `\let`.
    Let,
    /// `\DeclareMathOperator`.
    Operator,
    /// Changes the engine's state in a way the scope does not follow.
    Opaque,
    /// `\verb`: raw text follows, which each engine reads on its own terms.
    Verb,
}

/// The class of a control word name (letters only, no `@`).
fn lookup(name: &[u8]) -> Class {
    match name {
        b"newcommand" | b"renewcommand" | b"providecommand" => Class::NewCommand,
        b"def" | b"gdef" | b"edef" | b"xdef" => Class::Def,
        b"let" => Class::Let,
        b"DeclareMathOperator" => Class::Operator,
        b"global" | b"long" => Class::Prefix,
        b"verb" => Class::Verb,
        b"futurelet"
        | b"definecolor"
        | b"newgathered"
        | b"renewgathered"
        | b"mathtoolsset"
        | b"begingroup"
        | b"endgroup"
        | b"begingroupReset"
        | b"begingroupSandbox"
        | b"NewDocumentCommand"
        | b"RenewDocumentCommand"
        | b"ProvideDocumentCommand"
        | b"DeclareDocumentCommand"
        | b"NewDocumentEnvironment"
        | b"RenewDocumentEnvironment"
        | b"ProvideDocumentEnvironment"
        | b"DeclareDocumentEnvironment"
        | b"newenvironment"
        | b"renewenvironment"
        | b"Newextarrow"
        | b"DeclarePairedDelimiter"
        | b"DeclarePairedDelimiterX"
        | b"DeclarePairedDelimiterXPP"
        | b"newtagform"
        | b"renewtagform"
        | b"usetagform"
        | b"newcolumntype"
        | b"require"
        | b"setOptions"
        | b"csname"
        | b"chardef"
        | b"mathchardef" => Class::Opaque,
        _ => Class::Plain,
    }
}

/// Both readings of a control word are looked up (they differ only when an `@` follows the letters).
fn class(n1: &[u8], n2: &[u8]) -> Class {
    match lookup(n1) {
        Class::Plain => lookup(n2),
        c => c,
    }
}

/// A walk over the tokens of a definition. Any control word of a defining or
/// state-changing class met inside a definition makes the scope opaque, and so
/// does a control symbol over an astral character, a control word with an `@`
/// after its letters and the control symbol `\@`; an unescaped `%` or a
/// `\verb` is only noted (see `analyze`).
struct Walk<'a> {
    cur: Cursor<'a>,
    engine: Engine,
    opaque: bool,
    /// An unescaped `%` or a `\verb` was read: the engines disagree about
    /// what they hide.
    raw: bool,
    /// Where the last token of a `\def` parameter text started: after the
    /// walk of a `\def`, the `{` of its body.
    body_at: usize,
}

impl<'a> Walk<'a> {
    /// The next token, noted. A control word with an `@` after its letters
    /// (`\a@b`) or the control symbol `\@` is outside the model: KaTeX reads
    /// `@` as a letter and MathJax does not, so the engines read them as
    /// different commands (`\@ab` is one control word to KaTeX and `\@` and
    /// two letters to MathJax).
    fn take(&mut self) -> Option<Tok<'a>> {
        let from = self.cur.i;
        let t = self.cur.next()?;
        self.note(t);
        match t {
            Tok::Word(n1, n2) if n1 != n2 => self.opaque = true,
            // (a `\unicode` in a definition takes the font from the text after the call)
            Tok::Word(n1, n2) if self.unicode_may_read_font(n1, n2) => self.opaque = true,
            Tok::Sym if at(self.cur.s, from + 1) == b'@' => self.opaque = true,
            _ => {}
        }
        Some(t)
    }

    /// Whether the word just read, with the readings `n1` and `n2`, is a
    /// MathJax `\unicode` that may read a font (see [`unicode_may_read_font`]).
    fn unicode_may_read_font(&self, n1: &[u8], n2: &[u8]) -> bool {
        self.engine == Engine::MathJax
            && n1 == b"unicode"
            && unicode_may_read_font(self.cur.s, self.cur.i - n2.len() + n1.len())
    }

    /// What a token read does to the walk's flags.
    fn note(&mut self, t: Tok<'a>) {
        match t {
            Tok::Word(n1, n2) => match class(n1, n2) {
                Class::Plain => {}
                Class::Verb => self.raw = true,
                _ => self.opaque = true,
            },
            Tok::Astral => self.opaque = true,
            Tok::Byte(b'%') => self.raw = true,
            Tok::Sym | Tok::Byte(_) => {}
        }
    }

    fn peek(&self) -> Option<Tok<'a>> {
        let mut c = self.cur;
        c.next()
    }

    /// The white space between two parts of a definition: it skips ASCII
    /// blanks and form feeds. Any other white space, and a form feed too, is
    /// outside the model and decided by the check in `analyze` over the bytes
    /// of the definition ([`exotic_in`]).
    fn spaces(&mut self) {
        loop {
            let mut c = self.cur;
            match c.next() {
                Some(Tok::Byte(b)) if is_space(b) => self.cur = c,
                _ => break,
            }
        }
    }

    /// Takes the byte `b` if it is next.
    fn eat(&mut self, b: u8) -> bool {
        let mut c = self.cur;
        if c.next() == Some(Tok::Byte(b)) {
            self.cur = c;
            return true;
        }
        false
    }

    /// A control word or symbol, spaces before it skipped. `None` for a byte,
    /// and for a control symbol over a non-ASCII character (outside the model;
    /// an astral one is noted opaque by [`Walk::note`]). An `@` after the
    /// letters of a word, and the control symbol `\@`, are noted opaque by
    /// [`Walk::take`].
    fn cs(&mut self) -> Option<()> {
        self.spaces();
        let from = self.cur.i;
        match self.take()? {
            Tok::Word(..) | Tok::Astral => Some(()),
            Tok::Sym => (at(self.cur.s, from + 1) < 0x80).then_some(()),
            Tok::Byte(_) => None,
        }
    }

    /// A name: `{\name}` (spaces allowed inside) or a bare `\name`, as
    /// [`Walk::cs`] has it.
    fn name(&mut self) -> Option<()> {
        self.spaces();
        if !self.eat(b'{') {
            return self.cs();
        }
        self.cs()?;
        self.spaces();
        self.eat(b'}').then_some(())
    }

    /// The rest of a `{...}` group whose `{` was taken.
    fn group(&mut self) -> Option<()> {
        let mut depth = 1usize;
        loop {
            match self.take()? {
                Tok::Byte(b'{') => depth += 1,
                Tok::Byte(b'}') => {
                    depth -= 1;
                    if depth == 0 {
                        return Some(());
                    }
                }
                _ => {}
            }
        }
    }

    /// A body: a balanced group, or one token.
    fn body(&mut self) -> Option<()> {
        self.spaces();
        match self.take()? {
            Tok::Byte(b'{') => self.group(),
            Tok::Byte(b'}') => None,
            _ => Some(()),
        }
    }

    /// The rest of a default argument whose `[` was taken, up to the `]` at brace depth 0.
    fn default_argument(&mut self) -> Option<()> {
        let mut depth = 0usize;
        loop {
            match self.take()? {
                Tok::Byte(b'{') => depth += 1,
                Tok::Byte(b'}') => depth = depth.checked_sub(1)?,
                Tok::Byte(b']') if depth == 0 => return Some(()),
                _ => {}
            }
        }
    }

    /// After `\newcommand`, `\renewcommand` or `\providecommand`:
    /// `*`? name `[n]`? `[default]`? body.
    ///
    /// `Some(false)` when an engine ends the definition before the walk does,
    /// so that the rest of what the walk took is formula text there: a `*`,
    /// which both engines take as the name of the macro (in
    /// `\renewcommand*{\a}{x}` KaTeX 0.16 defines `*` as `\a` and MathJax 3
    /// defines `\*`, and `{x}` is typeset) and a default argument, which KaTeX
    /// does not have (in `\newcommand\g[1][x]{y}` the body of `\g` is the `[`,
    /// and `x]{y}` is typeset).
    ///
    /// `None` for `{[}` where the count would stand: KaTeX reads the argument
    /// after the name and starts a count when it is the single token `[`,
    /// braced or not, so it reads `\newcommand\a{[}1]{x}` as a count of 1 and
    /// the body `x`, where MathJax and the walk read the body `[`.
    fn new_command(&mut self) -> Option<bool> {
        self.spaces();
        let star = self.eat(b'*');
        self.name()?;
        let mut even = !star;
        self.spaces();
        if self.cur.s.get(self.cur.i..self.cur.i + 3) == Some(b"{[}") {
            return None;
        }
        if self.eat(b'[') {
            self.spaces();
            let mut digits = 0usize;
            while let Some(Tok::Byte(b'0'..=b'9')) = self.peek() {
                self.cur.next();
                digits += 1;
            }
            if digits == 0 {
                return None;
            }
            self.spaces();
            if !self.eat(b']') {
                return None;
            }
            self.spaces();
            if self.eat(b'[') {
                self.default_argument()?;
                even = false;
            }
        }
        self.body()?;
        Some(even)
    }

    /// After `\def`, `\gdef`, `\edef` or `\xdef`: `\name`, the parameter text
    /// up to the first `{`, a balanced body.
    ///
    /// `None` for `\{` in the parameter text: MathJax steps through it one
    /// character at a time, without reading `\` as an escape, and starts the
    /// body at the `{` of `\{`, KaTeX and the walk at the next `{`, so
    /// MathJax's body ends one `}` later. `None` too for a non-ASCII character
    /// in the parameter text, a control symbol over one included: outside the
    /// model.
    fn def(&mut self) -> Option<bool> {
        self.cs()?;
        loop {
            let from = self.cur.i;
            self.body_at = from;
            match self.take()? {
                Tok::Byte(b'{') => return self.group().map(|()| true),
                Tok::Byte(b'}') => return None,
                Tok::Byte(b) if b >= 0x80 => return None,
                Tok::Sym if at(self.cur.s, from + 1) == b'{' => return None,
                Tok::Sym if at(self.cur.s, from + 1) >= 0x80 => return None,
                _ => {}
            }
        }
    }

    /// After `\edef` or `\xdef`: as [`Walk::def`], and `None` when the body
    /// holds a control word or symbol. KaTeX expands the body when it defines
    /// the macro, on the token stack it reads the text from, so a macro with
    /// arguments in the body reads on past its `}` (with `\first` taking two
    /// arguments and giving back the first, `\edef\a{\first}\let\b` makes
    /// `\a` the command `\let`).
    fn edef(&mut self) -> Option<bool> {
        let even = self.def()?;
        let body = self.cur.s.get(self.body_at..self.cur.i).unwrap_or_default();
        (!body.contains(&b'\\')).then_some(even)
    }

    /// After `\let`: `\name`, an optional `=` and the white space after it
    /// (a run of ASCII blanks is one space token to KaTeX, which takes at most
    /// one as the optional space, and MathJax skips white space there), one
    /// token (the target).
    ///
    /// Under MathJax a `\unicode` target is opaque whatever follows it: the
    /// name becomes the command itself (`\let\U=\unicode{x263A}`, where the
    /// `{x263A}` is formula text), and a call `\U[Garamond]{x263A}` takes its
    /// font from the call site.
    fn let_target(&mut self) -> Option<bool> {
        self.cs()?;
        self.spaces();
        if self.eat(b'=') {
            self.spaces();
        }
        let target = self.take()?;
        if self.engine == Engine::MathJax && matches!(target, Tok::Word(n1, _) if n1 == b"unicode")
        {
            self.opaque = true;
        }
        Some(true)
    }

    /// After `\DeclareMathOperator`: `*`? name body (MathJax reads the `*` as
    /// the walk does, KaTeX has no `\DeclareMathOperator`).
    fn operator(&mut self) -> Option<bool> {
        self.spaces();
        self.eat(b'*');
        self.name()?;
        self.body()?;
        Some(true)
    }
}

/// What one math does to the macro state.
struct Defines {
    affecting: bool,
    opaque: bool,
}

/// Walks the commands of one math for `engine` (see the module documentation).
fn analyze(tex: &str, engine: Engine) -> Defines {
    let mut w = Walk {
        cur: Cursor {
            s: tex.as_bytes(),
            i: 0,
        },
        engine,
        opaque: false,
        raw: false,
        body_at: 0,
    };
    let mut affecting = false;
    // A safe point: no command is reading an argument here, so an unescaped
    // `%` starts a comment that ends at the end of its line in both engines.
    // It holds at the start of the math, right after a definition that began
    // at a safe point and that both engines end where the walk does, and
    // right after the newline of a comment met at a safe point, with only the
    // white space `only_white_space` admits in between. Every other byte or token clears it. A
    // definition never makes one: inside the argument of another command
    // (`\url{\def\a{1} % }`) the command is still reading when the definition
    // ends, and the engines disagree about what the `%` there hides.
    let mut safe = true;
    // `\global` or `\long` that stood at a safe point, with only blanks since:
    // the definition they prefix starts at a safe point too.
    let mut prefix_safe = false;
    // No command before this point can be taking arguments: the math holds
    // only characters other than `\`, blanks, comments at a safe point and
    // definitions that both engines end where the walk does. A macro with
    // arguments (`\@firstoftwo` in KaTeX, a `\newcommand\first[2]{#1}` of the
    // document, a `\def\mk#1.{#1}` that reads up to a `.`) can take a part of
    // a definition after it and hand the engine another order of tokens than
    // the text has: in `\first\let\y\b\def` both engines let `\b` be `\def`.
    // A definition met after any other command is not followed.
    let mut inert = true;
    loop {
        let from = w.cur.i;
        w.cur.skip_to_special();
        if safe || prefix_safe {
            let between = w.cur.s.get(from..w.cur.i).unwrap_or_default();
            if !between.iter().all(|&c| is_blank(c)) {
                // (after `\global` or `\long` KaTeX takes only blanks, anything else is an error)
                prefix_safe = false;
                safe &= only_white_space(between);
            }
        }
        let Some(tok) = w.cur.next() else { break };
        // a `%` with a combining mark after it is one token to KaTeX, and no comment: noted below
        if tok == Tok::Byte(b'%') && combining_at(w.cur.s, w.cur.i) {
            safe = false;
        }
        let (n1, n2) = match tok {
            Tok::Word(n1, n2) => (n1, n2),
            Tok::Astral => {
                // read as a command by one engine and not at all by the other
                affecting = true;
                w.opaque = true;
                break;
            }
            Tok::Byte(b'%') if safe => {
                // a comment: what it holds is hidden from both engines and counts for nothing
                w.cur.skip_comment();
                continue;
            }
            other => {
                // an unescaped `%` met anywhere else, or a control symbol or a stray byte
                safe = false;
                prefix_safe = false;
                w.note(other);
                // (a control symbol can be a macro of the document: `\renewcommand\,[2]{#1}`)
                inert &= !matches!(other, Tok::Sym);
                continue;
            }
        };
        // whether this word stands where nothing is being read
        let started = safe || prefix_safe;
        safe = false;
        prefix_safe = false;
        let cl = class(n1, n2);
        // (a command of the document, or `\verb`, before a later definition)
        inert &= !matches!(cl, Class::Plain | Class::Verb);
        if cl == Class::Verb {
            w.raw = true;
            continue;
        }
        if cl == Class::Plain {
            // MathJax's `\unicode[font]{..}` writes a table that later formulas read
            affecting |= w.unicode_may_read_font(n1, n2);
            continue;
        }
        affecting = true;
        // the two engines read a defining word followed by `@` as different commands: not followed
        if n1 != n2 || cl == Class::Opaque {
            w.opaque = true;
            break;
        }
        // MathJax 3 has no `\providecommand`, `\gdef`, `\edef`, `\xdef`, `\global` or `\long`: it
        // typesets the name and the whole definition is formula text there, outside the model
        if engine == Engine::MathJax && (cl == Class::Prefix || mathjax_lacks(n1)) {
            w.opaque = true;
            break;
        }
        // a definition after a command that may be taking arguments: the engines may read it
        // from other tokens than the text holds
        if !inert && cl != Class::Prefix {
            w.opaque = true;
            break;
        }
        // `\renewcommand*`: KaTeX takes the `*` for the name and defines the character `*` as a
        // macro, which every later math then reads wherever it holds a `*` (and it can take
        // arguments). `\newcommand*` is an error there and `\providecommand*` defines nothing.
        let rest = w.cur.s.get(w.cur.i..).unwrap_or_default();
        if n1 == b"renewcommand" && rest.iter().find(|&&c| !is_space(c)) == Some(&b'*') {
            w.opaque = true;
            break;
        }
        // `Some(false)`: followed to its end, but an engine ends it earlier than the walk
        let args_from = w.cur.i;
        let parsed = match cl {
            Class::NewCommand => w.new_command(),
            Class::Def if matches!(n1, b"edef" | b"xdef") => w.edef(),
            Class::Def => w.def(),
            Class::Let => w.let_target(),
            Class::Operator => w.operator(),
            _ => Some(true),
        };
        // Input outside the model: a combining mark, a control character or white space beyond
        // ASCII, in the bytes the walk took or right after the last of them (for a prefix, the
        // first character after the blanks that follow it, since its definition is still to come)
        if parsed.is_some() {
            let s = w.cur.s;
            if cl == Class::Prefix {
                let mut j = args_from;
                while is_blank(at(s, j)) {
                    j += 1;
                }
                w.opaque |= outside_model_at(s, j);
            } else {
                w.opaque |= exotic_in(s, args_from, w.cur.i);
            }
        }
        if parsed.is_none() {
            w.opaque = true;
        }
        if w.opaque {
            break;
        }
        // A definition followed to its end leaves the point it started at as
        // it was: safe only if it began at a safe point. A prefix (`\global`,
        // `\long`) still has its definition to come, which starts where the
        // prefix did.
        if cl == Class::Prefix {
            prefix_safe = started;
        } else {
            safe = started;
        }
        // Unless an engine ended the definition before the walk did (a `*`, a
        // default argument): what the walk took after that end is formula text
        // in those engines, and a command there can read the `%` that follows
        // as its argument (a body `\url` in KaTeX, `\hat` in MathJax), so the
        // text after the `%` runs.
        if parsed == Some(false) {
            safe = false;
        }
        // (and that command can be a macro taking arguments, a later definition among them)
        inert &= parsed == Some(true);
    }
    // what a `%` hides, and where a `\verb` ends, depends on the engine: a
    // math that defines something and holds either is not followed. A `%` at
    // a safe point is a comment in both and never gets here.
    if affecting && w.raw {
        w.opaque = true;
    }
    Defines {
        affecting,
        opaque: w.opaque,
    }
}

const FNV_OFFSET: u64 = 0xcbf2_9ce4_8422_2325;
const FNV_PRIME: u64 = 0x0000_0100_0000_01b3;

/// FNV-1a 64 over the 8 little-endian bytes of `env` followed by `tex`.
fn chain(env: u64, tex: &str) -> u64 {
    let mut h = FNV_OFFSET;
    for &b in env.to_le_bytes().iter().chain(tex.as_bytes()) {
        h = (h ^ u64::from(b)).wrapping_mul(FNV_PRIME);
    }
    h
}

/// Walks a document's maths in order and tracks the macro environment.
pub struct MacroScope {
    engine: Engine,
    defined: HashSet<String>,
    opaque: bool,
    env: u64,
}

impl MacroScope {
    /// A fresh scope: environment 0, not opaque.
    pub fn new(engine: Engine) -> Self {
        MacroScope {
            engine,
            defined: HashSet::new(),
            opaque: false,
            env: 0,
        }
    }

    /// The next math's prepared TeX for the engine ([`super::prepare_tex_for`]
    /// with this scope's engine; under KaTeX that is [`super::prepare_tex`]):
    /// the TeX to hand over, the environment it is typeset in (every affecting
    /// math before it) and whether it is affecting itself, in which case the
    /// environment moves on.
    /// Under KaTeX a math is also affecting when the `\newcommand` rule
    /// rewrote it: the rule's own state (`defined`) is part of what a later
    /// math is handed. The scan sees every control word the rule acts on, so
    /// this only matters were the two to disagree (see the module
    /// documentation).
    pub fn next(&mut self, prepared: &str) -> EngineTex {
        let (tex, rewrote) = match self.engine {
            Engine::Katex => rewrite_newcommand(prepared, &mut self.defined),
            Engine::MathJax => (prepared.to_string(), false),
        };
        let env = self.env;
        let mut affecting = self.opaque;
        if !self.opaque {
            let d = analyze(&tex, self.engine);
            affecting = d.affecting;
            self.opaque = d.opaque;
        }
        affecting |= rewrote;
        if affecting {
            self.env = chain(env, &tex);
        }
        EngineTex {
            tex,
            env,
            affecting,
        }
    }

    /// The current macro environment hash: the one the next math is typeset in.
    pub fn env(&self) -> u64 {
        self.env
    }

    /// Whether a macro definition the scope cannot follow has been seen.
    pub fn is_opaque(&self) -> bool {
        self.opaque
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// `(affecting, opaque)` of one math under `engine`.
    fn defines_in(engine: Engine, tex: &str) -> (bool, bool) {
        let d = analyze(tex, engine);
        (d.affecting, d.opaque)
    }

    /// `(affecting, opaque)` of one math, the same under both engines.
    fn defines(tex: &str) -> (bool, bool) {
        let katex = defines_in(Engine::Katex, tex);
        assert_eq!(
            katex,
            defines_in(Engine::MathJax, tex),
            "{tex:?}: KaTeX and MathJax differ"
        );
        katex
    }

    /// A math KaTeX follows and MathJax, which lacks a command in it, makes opaque.
    fn katex_follows(tex: &str) {
        assert_eq!(defines_in(Engine::Katex, tex), (true, false), "{tex:?}");
        assert_eq!(defines_in(Engine::MathJax, tex), (true, true), "{tex:?}");
    }

    #[test]
    fn every_command_of_the_lists_is_classified() {
        for w in [
            "newcommand",
            "renewcommand",
            "providecommand",
            "def",
            "gdef",
            "edef",
            "xdef",
            "let",
            "global",
            "long",
            "DeclareMathOperator",
        ] {
            assert_ne!(lookup(w.as_bytes()), Class::Plain, "{w}");
            assert_ne!(lookup(w.as_bytes()), Class::Opaque, "{w}");
        }
        for w in [
            "futurelet",
            "definecolor",
            "newgathered",
            "renewgathered",
            "mathtoolsset",
            "begingroup",
            "endgroup",
            "begingroupReset",
            "begingroupSandbox",
            "NewDocumentCommand",
            "RenewDocumentCommand",
            "ProvideDocumentCommand",
            "DeclareDocumentCommand",
            "NewDocumentEnvironment",
            "RenewDocumentEnvironment",
            "ProvideDocumentEnvironment",
            "DeclareDocumentEnvironment",
            "newenvironment",
            "renewenvironment",
            "Newextarrow",
            "DeclarePairedDelimiter",
            "DeclarePairedDelimiterX",
            "DeclarePairedDelimiterXPP",
            "newtagform",
            "renewtagform",
            "usetagform",
            "newcolumntype",
            "require",
            "setOptions",
            "csname",
            "chardef",
            "mathchardef",
        ] {
            assert_eq!(lookup(w.as_bytes()), Class::Opaque, "{w}");
        }
        assert_eq!(lookup(b"verb"), Class::Verb);
        for w in [
            "",
            "d",
            "de",
            "defs",
            "Def",
            "letter",
            "globall",
            "operatorname",
        ] {
            assert_eq!(lookup(w.as_bytes()), Class::Plain, "{w}");
        }
    }

    #[test]
    fn tokens_read_words_symbols_and_percent() {
        let mut c = Cursor {
            s: b"\\def@x\\%a% c\n\\\\\\",
            i: 0,
        };
        assert!(matches!(c.next(), Some(Tok::Word(b"def", b"def@x"))));
        assert!(matches!(c.next(), Some(Tok::Sym)));
        assert!(matches!(c.next(), Some(Tok::Byte(b'a'))));
        // a comment is not skipped: its bytes are tokens like any other
        for b in *b"% c\n" {
            assert!(matches!(c.next(), Some(Tok::Byte(x)) if x == b), "{b}");
        }
        assert!(matches!(c.next(), Some(Tok::Sym)));
        // a lone backslash at the end is a byte
        assert!(matches!(c.next(), Some(Tok::Byte(b'\\'))));
        assert!(c.next().is_none());
    }

    /// A backslash takes the whole character after it: two and three bytes of
    /// UTF-8 are one control symbol, four are the astral kind the engines read
    /// differently; the bytes after the character are the next tokens.
    #[test]
    fn a_backslash_takes_a_whole_character() {
        for (tex, kind) in [
            ("\\\u{e9}x", 'S'),
            ("\\\u{20ac}x", 'S'),
            ("\\\u{3000}x", 'S'),
            ("\\\u{1F600}x", 'A'),
        ] {
            let mut c = Cursor {
                s: tex.as_bytes(),
                i: 0,
            };
            match (c.next(), kind) {
                (Some(Tok::Sym), 'S') | (Some(Tok::Astral), 'A') => {}
                _ => panic!("{tex:?}: wrong kind of token"),
            }
            assert!(matches!(c.next(), Some(Tok::Byte(b'x'))), "{tex:?}");
            assert!(c.next().is_none(), "{tex:?}");
        }
        // a character cut short at the end of the bytes does not run past them
        let mut c = Cursor {
            s: b"\\\xf0\x9f",
            i: 0,
        };
        assert!(matches!(c.next(), Some(Tok::Astral)));
        assert!(c.next().is_none());
    }

    #[test]
    fn definitions_parse_to_their_end() {
        assert_eq!(defines(r"\newcommand{\a}[2][{]}]{#1#2}"), (true, false));
        assert_eq!(defines(r"\def\a#1#2{#1}"), (true, false));
        assert_eq!(defines(r"\let\a= \b"), (true, false));
        assert_eq!(defines(r"\let\a=\b"), (true, false));
        assert_eq!(defines(r"\let\a \b"), (true, false));
        // a run of ASCII blanks after `=` is one space token to KaTeX and skipped by MathJax: the
        // target is what follows it
        assert_eq!(defines(r"\let\a=  \def\R{x}"), (true, true));
        assert_eq!(defines("\\let\\a=\n \\def\\R{x}"), (true, true));
        assert_eq!(defines("\\let\\a=\t\r\n \\def"), (true, true));
        assert_eq!(defines(r"\newcommand{\a}"), (true, true));
        assert_eq!(defines(r"\def\a{\def\b{}}"), (true, true));
    }

    /// Comments hide nothing from the scan, and what a `%` or a `\verb` hides
    /// depends on the engine, so a math that defines and holds either is not
    /// followed. The named cases are the ones where the engines differ.
    #[test]
    fn comments_and_verbatim_text_are_not_trusted() {
        // a word in a comment counts, and with the `%` the math is not followed
        assert_eq!(defines("x^2 % \\def"), (true, true));
        assert_eq!(defines("a % \\def\\x{1}\n+ b"), (true, true));
        // MathJax reads `\text{%}` as an argument with a `%` in it: the `\def` runs
        assert_eq!(defines(r"\text{%}\def\b{X}"), (true, true));
        // `\verb|%|` is raw text in both engines: the `\gdef` after it runs
        assert_eq!(defines(r"\verb|%|\gdef\b{X}"), (true, true));
        // a `\verb` alone, and a `%` alone, change nothing
        assert_eq!(defines(r"\verb|x|"), (false, false));
        assert_eq!(defines("x % y"), (false, false));
        // a `\verb` next to a definition
        assert_eq!(defines(r"\verb|x|\def\a{1}"), (true, true));
        assert_eq!(defines(r"\def\a{\verb|x|}"), (true, true));
        // MathJax counts the braces inside a comment, KaTeX does not
        assert_eq!(
            defines("\\newcommand\\a{x %{\n}\\gdef\\b{X}}"),
            (true, true)
        );
        // an escaped percent is a character
        assert_eq!(defines(r"\newcommand{\pct}{50\%}"), (true, false));
        assert_eq!(defines(r"\def\a{1} x \% y"), (true, false));
        // (before a definition it is a control symbol, which a document can make a macro)
        assert_eq!(defines(r"x \% \def\a{1}"), (true, true));
    }

    /// A `%` where no command is reading an argument is a comment in both
    /// engines: the words in it count for nothing and it does not make the
    /// scope opaque. The safe point holds at the start, after a definition
    /// at the top level of the math followed to its end, and after the newline
    /// of a comment met at a safe point, with only the white space
    /// `only_white_space` admits in between.
    #[test]
    fn a_comment_at_a_safe_point_hides_its_words() {
        // a note after a definition, on one line and on several
        assert_eq!(
            defines(r"\newcommand{\R}{\mathbb{R}} % reals"),
            (true, false)
        );
        assert_eq!(
            defines("\\newcommand{\\R}{\\mathbb{R}} % reals\n"),
            (true, false)
        );
        assert_eq!(
            defines("\\newcommand{\\R}{1} % reals\n\\def\\a{1} % one\n\\let\\b\\a % alias\n"),
            (true, false)
        );
        assert_eq!(
            defines(
                "% macros\n\\newcommand{\\R}{1}\n% more\n\\DeclareMathOperator{\\op}{op} % x\n"
            ),
            (true, false)
        );
        assert_eq!(defines(r"\def\a{1} % \def"), (true, false));
        assert_eq!(defines(r"\def\a{1}%c"), (true, false));
        // (MathJax has no `\global`, `\long` or `\gdef`: opaque there, see
        // `commands_mathjax_does_not_have_are_opaque_there`)
        katex_follows(r"\global\def\a{1} % c");
        // a prefix keeps the point it stood at, blanks between the parts included
        katex_follows("\\global \\long\n\\def\\a{1} % c");
        katex_follows("% c\n\\long\\def\\a{1} % c\n\\global\\def\\b{2} % d");
        katex_follows("% c\n\\long\\gdef\\a{1} % c\n\\global\\def\\b{2} % d");
        assert_eq!(
            defines("\\def\\a{1} % c\n\\def\\b{2} % d\n\\let\\c\\b % e"),
            (true, false)
        );
        // a comment at the start, or alone, defines nothing and its words count for nothing
        assert_eq!(defines(r"% \newcommand{\a}{1}"), (false, false));
        assert_eq!(defines("% \\def\\a{1}\n% \\gdef\\b{2}\n"), (false, false));
        assert_eq!(defines(" \t\r\n% \\def\\a{1}"), (false, false));
        assert_eq!(
            defines("% c\n\n \t % d\n\\newcommand{\\a}{1}"),
            (true, false)
        );
        // what a comment at a safe point holds is hidden: opaque words, `\verb` and wide characters too
        assert_eq!(
            defines("% \\begingroup \\csname \\verb|x \\\\\u{1F600} \\newenvironment\n"),
            (false, false)
        );
        assert_eq!(
            defines("\\def\\a{1} % \\verb| \\begingroup \\\\\u{1F600} \\def\\b{\\gdef\\c{}}\n"),
            (true, false)
        );
        // a definition both engines end where the walk does keeps its point: a count without a
        // default argument, a `*` after `\DeclareMathOperator` (MathJax reads it as the walk
        // does), a name that is a control symbol over an ASCII character (one token in both)
        for tex in [
            r"\newcommand\g[1]{x} % note",
            r"\renewcommand{\f}[2]{#1#2} % note",
            r"\newcommand\g[1]\url % \def\b{\gdef\cc{X}}",
            r"\newcommand\:\hat % \def\b{X}",
            r"\renewcommand{\,}\hat % \def\b{X}",
            r"\def\;{x} % \def\b{X}",
            r"\let\!\hat % \def\b{X}",
            r"\DeclareMathOperator\:\hat % \def\b{X}",
            r"\newcommand\g\url % \def\b{\gdef\cc{X}}",
            r"\renewcommand{\a}\hat % \def\b{X}",
            r"\newcommand\a\hat % \def\b{X}",
            r"\let\a\hat % \def\b{X}",
            r"\DeclareMathOperator\a\hat % \def\b{X}",
            r"\DeclareMathOperator*{\a}\hat % \def\b{X}",
        ] {
            assert_eq!(defines(tex), (true, false), "{tex:?}");
        }
        // a control symbol over a non-ASCII character as a name, `\@` and a control word with an
        // `@` after its letters anywhere in a definition: outside the model, opaque
        for tex in [
            "\\newcommand\\\u{e9}\\hat % \\def\\b{X}",
            "\\let\\\u{20ac}\\hat % \\def\\b{X}",
            r"\newcommand\@{x} % \def\b{X}",
            r"\newcommand\@ \hat % \def\b{X}",
            r"\newcommand\a\hat@ % \def\b{X}",
            r"\let\a\hat@ % \def\b{X}",
        ] {
            assert_eq!(defines(tex), (true, true), "{tex:?}");
        }
        // the comment ends at the newline: what follows it is read again
        assert_eq!(defines("% c\n\\def\\a{1}"), (true, false));
        assert_eq!(defines("% c\n\\begingroup"), (true, true));
        assert_eq!(
            defines("\\def\\a{1} % c\n\\def\\b{\\gdef\\c{}}"),
            (true, true)
        );
        assert_eq!(defines("\\def\\a{1} % c\r\n\\begingroup"), (true, true));
        // only a newline ends it: a carriage return does not
        assert_eq!(defines("\\def\\a{1} % c\r\\begingroup"), (true, false));
    }

    /// Every other `%` is still noted: a command may be reading it, and the
    /// engines then differ. A safe point is cleared by any byte or token that
    /// is not an ASCII blank, and a definition that did not parse is opaque
    /// whatever follows.
    #[test]
    fn a_comment_where_a_command_may_be_reading_is_not_trusted() {
        // MathJax takes the `%` as the superscript and runs the `\def`, KaTeX hides it
        assert_eq!(defines("x^%\n\\def\\a{1}"), (true, true));
        assert_eq!(defines("^%\n\\def\\a{1}"), (true, true));
        // MathJax takes the `%` as the body of the definition, KaTeX the group on the next line
        assert_eq!(defines("\\newcommand{\\R} %c\n{x}"), (true, true));
        assert_eq!(defines("\\newcommand\\R%\n{x}"), (true, true));
        assert_eq!(defines("\\def\\a%\n{1}"), (true, true));
        assert_eq!(defines("\\let\\a = % c\n\\def\\R{x}"), (true, true));
        assert_eq!(defines("\\def\\a{x % }\n}"), (true, true));
        // a `%` that the walk reads as a part of a definition is noted by the walk
        assert_eq!(defines("\\newcommand{\\a}[1] % c\n{#1}"), (true, true));
        assert_eq!(
            defines("\\DeclareMathOperator{\\a} % c\n{op}"),
            (true, true)
        );
        assert_eq!(defines("\\newcommand%\n{\\a}{x}"), (true, true));
        // a byte or a token that is not white space clears the safe point: a form feed, a vertical
        // tab, U+2028, U+2029 (which KaTeX refuses), U+0085 (not white space to JavaScript) and
        // a combining mark after a no-break space (one token with it to KaTeX) among them
        for between in [
            "x",
            "1",
            ",",
            ".",
            "{",
            "}",
            "^",
            "_",
            "&",
            "\u{e9}",
            "\x0c",
            "\x0b",
            "\u{2028}",
            "\u{2029}",
            "\u{85}",
            "\u{a0}\u{301}",
            "\u{3000}\u{20d7}",
            "\\\\",
            "\\,",
            "\\ ",
            "\\alpha",
            "\\text",
            "\\relax ",
        ] {
            let tex = format!("\\def\\a{{1}}{between} % \\def\\b{{2}}");
            assert_eq!(defines(&tex), (true, true), "{tex:?}");
            let tex = format!("{between} % \\def\\b{{2}}\n\\def\\a{{1}}");
            assert_eq!(defines(&tex), (true, true), "{tex:?}");
            let tex = format!("% c\n{between} % \\def\\b{{2}}");
            assert_eq!(defines(&tex), (true, true), "{tex:?}");
        }
        // the non-ASCII white space that KaTeX lexes keeps it: both engines read it as a space or as
        // a character that takes no argument, so the `%` after it is a comment as after a blank
        for between in [
            "\u{a0}",
            "\u{3000}",
            "\u{feff}",
            "\u{1680}",
            "\u{2003}\u{a0} \t",
        ] {
            let tex = format!("\\def\\a{{1}}{between} % \\def\\b{{2}}");
            assert_eq!(defines(&tex), (true, false), "{tex:?}");
            let tex = format!("{between} % \\def\\b{{2}}\n\\def\\a{{1}}");
            assert_eq!(defines(&tex), (true, false), "{tex:?}");
            let tex = format!("% c\n{between} % \\def\\b{{2}}");
            assert_eq!(defines(&tex), (false, false), "{tex:?}");
        }
        // but not after a prefix, whose definition is still to come
        assert_eq!(defines("\\global\u{a0}\\def\\a{1} % c"), (true, true));
        // after a prefix the definition is still to come: the `%` is not at a safe point
        assert_eq!(defines("\\global % c\n\\def\\a{1}"), (true, true));
        assert_eq!(defines("\\long\\global % c\n"), (true, true));
        // a `\verb` next to the comment
        assert_eq!(defines("\\def\\a{1}\\verb|x| % c"), (true, true));
        assert_eq!(defines("\\def\\a{1} % c\n\\verb|x|"), (true, true));
        // a definition that did not parse is opaque whatever follows it
        assert_eq!(defines("\\newcommand{\\a}[x] % c\n"), (true, true));
        assert_eq!(defines("\\def\\z % c\n"), (true, true));
        // the `%` after `\newcommand{\a}` is its body
        assert_eq!(defines("\\newcommand{\\a} % c\n"), (true, true));
        // a definition inside a body still makes the scope opaque
        assert_eq!(defines("\\def\\a{\\def\\b{1}} % c"), (true, true));
        // A definition keeps the safe point it started at and never creates one. Inside the
        // argument of another command that command is still reading when the definition ends:
        // KaTeX reads the `%` of `\\url` and `\\href` as a character, and MathJax counts the
        // braces inside a comment, so the `\\def\\b` after the `}` runs in one and is hidden
        // in the other
        for tex in [
            r"\url{\def\a{1} % }\def\b{\gdef\c{X}}",
            r"\href{\def\a{1} % }{y}\def\b{\gdef\c{X}}",
            "\\text{\\def\\a{1} % }\\def\\b{\\gdef\\c{X}}\n}",
            "\\mathrm{\\newcommand\\a{x} % }\\let\\d\\def\n}",
            r"x\def\a{1} % c",
        ] {
            assert_eq!(defines(tex), (true, true), "{tex:?}");
        }
        // the same wherever the definition starts at a point where something may be reading
        for open in [
            "\\frac{",
            "\\boxed{",
            "\\text{",
            "{",
            "\\begin{x}",
            "\\left(",
            "x^{",
            "x_",
            "\\relax ",
            "\\, ",
            "a ",
            "1",
            "\\alpha",
            "\\\\ ",
            "\u{a0}x",
        ] {
            for def in [
                r"\def\a{1}",
                r"\newcommand{\a}{1}",
                r"\let\a\b",
                r"\DeclareMathOperator{\a}{b}",
                r"\global\def\a{1}",
                r"\long\global\gdef\a{1}",
            ] {
                let tex = format!("{open}{def} % }}\\def\\z{{1}}\n");
                assert_eq!(defines(&tex), (true, true), "{tex:?}");
                // and with the note alone on the next line
                let tex = format!("{open}{def}\n% c\n");
                assert_eq!(defines(&tex), (true, true), "{tex:?}");
            }
        }
        // Nor does a definition that an engine ends before the walk does: the rest of what the
        // walk took is formula text there, and a `\url` (KaTeX) or a `\hat` (MathJax) in it reads
        // the `%` as its argument, so the `\def\b` after it runs. Both engines take the `*` after
        // the `\newcommand` family as the macro's name, KaTeX takes the `[` of a default argument
        // as the body, MathJax ends a name before an `@`
        for tex in [
            // the shapes probed against KaTeX 0.16.22: `\cc` is defined there
            r"\newcommand\g[1][x]\url % \def\b{\gdef\cc{X}}",
            r"\newcommand{\g}[1][x]\url % \def\b{\gdef\cc{X}}",
            r"\renewcommand*{\a}\url % \def\b{\gdef\cc{X}}",
            r"\providecommand*{\a}\url % \def\b{\gdef\cc{X}}",
            r"\renewcommand*{\a}[1]\url % \def\b{\gdef\cc{X}}",
            // and against MathJax 3.2.2: `\b` is defined there
            r"\renewcommand*{\a}\hat % \def\b{X}",
            r"\newcommand*{\a}\hat % \def\b{X}",
            r"\providecommand*{\a}\hat % \def\b{X}",
            r"\newcommand\a@\hat % \def\b{X}",
            r"\let\a@\hat % \def\b{X}",
            r"\DeclareMathOperator\a@\hat % \def\b{X}",
            r"\global\let\a@\hat % \def\b{X}",
            // the realistic forms: a note after them is noted
            r"\newcommand{\norm}[2][2]{x} % note",
            r"\renewcommand*{\a}{x} % note",
            r"\newcommand*{\x}[2][d]{#1#2} % note",
            r"\providecommand*\k[1]{#1} % note",
            r"\renewcommand\g[1][d]{[#1]} % note",
            "\\renewcommand*{\\a}{x}\n% note\n",
            "\\newcommand{\\a}[1][d]{x}\t%",
            // a prefix in front changes nothing
            r"\global\renewcommand*{\a}{x} % note",
            // a name with an `@` is outside the model, braced or not and after `\def` too
            r"\newcommand{\a@}{x} % note",
            r"\def\a@b{x} % note",
            r"\def\a@\hat{x} % \def\b{X}",
            r"\let\a@b\relax % note",
            // the point is not made again by a definition after it
            "\\renewcommand*{\\a}{x}\n\\def\\b{1} % note",
            "\\newcommand\\g[1][x]{y} \\newcommand\\h{z} % note",
        ] {
            assert_eq!(defines(tex), (true, true), "{tex:?}");
        }
        // the same definitions without a note are followed (but `\renewcommand*`, which defines
        // the character `*` in KaTeX: `a_definition_after_a_command_is_not_followed`)
        for tex in [
            r"\newcommand{\norm}[2][2]{x}",
            r"\newcommand*{\a}{x}",
            r"\newcommand*{\x}[2][d]{#1#2}",
        ] {
            assert_eq!(defines(tex), (true, false), "{tex:?}");
        }
        // (`\providecommand` is a command MathJax lacks: opaque there)
        katex_follows("\\providecommand*{\\a}{x}\n");
        // a control word with an `@` after its letters is outside the model
        for tex in [r"\newcommand\a@b{x}", r"\let\a@b\relax", r"\def\a@b{x}"] {
            assert_eq!(defines(tex), (true, true), "{tex:?}");
        }
        // but not a definition after them: the formula text there can hold a macro that takes
        // arguments (`\newcommand\g[1][x]\first\let\y\b\def`), see
        // `a_definition_after_a_command_is_not_followed`
        for tex in [
            "\\newcommand*{\\a}{x}\n\\def\\b{1}\n",
            "\\newcommand{\\norm}[2][2]{x}\n\\newcommand\\R{\\mathbb{R}}",
            r"\let\a@b\relax\let\c\d",
        ] {
            assert_eq!(defines(tex), (true, true), "{tex:?}");
        }
        // a prefix in the middle of text does not make a point either
        assert_eq!(defines(r"x\global\def\a{1} % c"), (true, true));
        assert_eq!(defines(r"\global x\def\a{1} % c"), (true, true));
        assert_eq!(defines(r"\global\relax\def\a{1} % c"), (true, true));
        assert_eq!(defines(r"\global{}\def\a{1} % c"), (true, true));
        // a control symbol is a token: it clears the point a prefix carries
        for sym in [r"\,", r"\ ", r"\\", r"\%", r"\{", "\\\u{e9}"] {
            for prefix in [r"\global", r"\long", r"\long\global"] {
                let tex = format!("{prefix}{sym}\\def\\a{{1}} % c");
                assert_eq!(defines(&tex), (true, true), "{tex:?}");
                let tex = format!("{prefix} {sym}\n\\def\\a{{1}} % c");
                assert_eq!(defines(&tex), (true, true), "{tex:?}");
            }
        }
        // but a definition that follows blanks and comment lines only is at the top level
        katex_follows(" \n% c\n\t\\global\\def\\a{1} % d");
        // an escaped percent is a character, not a comment, and it clears the safe point (and, a
        // control symbol that a document can make a macro, it leaves no definition followed)
        assert_eq!(defines("\\def\\a{1} \\% \\def\\b{2}"), (true, true));
        assert_eq!(defines("\\def\\a{1} 50\\%"), (true, false));
        assert_eq!(defines("\\def\\a{1} \\% % c"), (true, true));
    }

    /// Notes at the places where no command is reading change nothing: a
    /// preamble of definitions the scope follows, with a comment (whatever it
    /// says) after any of them, in any layout, has the state of the same
    /// preamble without the comments. A definition the scope cannot follow in
    /// the middle makes both opaque.
    ///
    /// The wrapper dimension: a definition inside the argument of another
    /// command, a group or an environment is not at the top level of the math.
    /// A note after it is a `%` that a command may be reading, so the noted
    /// form is opaque where the plain form is not, and so is everything noted
    /// after the first such wrapper (no safe point is made after it).
    ///
    /// The same holds from the first definition that an engine ends before
    /// the walk does (`EARLY`: a `*` after the `\newcommand` family, a default
    /// argument): the rest of it is formula text to that engine, so it leaves
    /// no safe point after it either. Input outside the model (`AT`: an `@`
    /// control sequence, and under MathJax `LACKED`: the commands it does not
    /// have) makes the scope opaque. Each engine is checked on its own.
    ///
    /// And a definition after a command that may take arguments (the command
    /// of a wrapper, or the formula text an early definition leaves) is not
    /// followed at all, noted or not: the plain form is opaque from there.
    #[test]
    fn comments_between_definitions_change_nothing() {
        const DEFS: [&str; 8] = [
            r"\newcommand{\a}{1}",
            r"\def\b#1{#1}",
            r"\let\c\d",
            r"\DeclareMathOperator{\op}{op}",
            r"\DeclareMathOperator*{\argmax}{arg\,max}",
            r"\newcommand{\pct}{50\%}",
            r"\let\!\hat",
            r"\def\a\}{x}",
        ];
        const EARLY: [&str; 3] = [
            r"\renewcommand\g[1][d]{[#1]}",
            r"\newcommand*{\h}{x}",
            r"\newcommand{\norm}[2][2]{x}",
        ];
        // followed by KaTeX like `DEFS`, and outside the model for MathJax, which has none of them
        const LACKED: [&str; 5] = [
            r"\global\def\e{x}",
            r"\providecommand{\f}[2]{#1#2}",
            r"\gdef\g{x}",
            r"\long\edef\h{y}",
            r"\xdef\i#1{#1}",
        ];
        // an early end for KaTeX like `EARLY` (the `*`), outside the model for MathJax
        const LACKED_EARLY: [&str; 1] = [r"\providecommand*\k[1]{#1}"];
        // outside the model under both engines: an `@` control sequence
        const AT: [&str; 3] = [
            r"\newcommand\@{x}",
            r"\newcommand\m@n{x}",
            r"\global\let\p@q\relax",
        ];
        // (`\relax` ends the word: with no gap a wrapper's `x^{` would make it `\begingroupx`)
        const BAD: [&str; 9] = [
            r"\newcommand{\mk}[1]{\def#1{x}}",
            r"\begingroup\relax",
            r"\def\z{",
            r"\def\a\{{x}",
            r"\newcommand\@ab{x}",
            "\\newcommand\\a\u{a0}{x}",
            "\\def\\a{x}\u{301}}",
            r"\newcommand\a{[}1]{x}",
            r"\renewcommand*{\h}{x}",
        ];
        // what a definition may stand in: the text before it and the text that closes it (with
        // a command or with characters alone)
        const WRAPS: [(&str, &str); 13] = [
            (r"\text{", "}"),
            (r"\url{", "}"),
            (r"\href{", "}{y}"),
            (r"\mathrm{", "}"),
            (r"\frac{", "}{2}"),
            ("{", "}"),
            (r"\begin{x}", r"\end{x}"),
            (r"x^{", "}"),
            (r"\boxed{", "}"),
            ("a_{", "}"),
            ("{{", "}}"),
            ("1+{", "}"),
            ("x^{y_{", "}}"),
        ];
        const GAPS: [&str; 5] = ["", " ", "\n", "\t", "\r\n"];
        const NOTES: [&str; 7] = [
            "",
            "% c\n",
            " % \\def\\z{1}\n",
            "%\n",
            "% \\begingroup \\verb|x \\\\\u{1F600} \\csname\n",
            "\t% \\newcommand{\\a}{\\def\\q{1}}\n",
            "% {\n",
        ];
        for engine in [Engine::Katex, Engine::MathJax] {
            let (defs, early_defs, bad_defs): (Vec<&str>, Vec<&str>, Vec<&str>) = match engine {
                Engine::Katex => (
                    DEFS.iter().chain(&LACKED).copied().collect(),
                    EARLY.iter().chain(&LACKED_EARLY).copied().collect(),
                    BAD.iter().chain(&AT).copied().collect(),
                ),
                Engine::MathJax => (
                    DEFS.to_vec(),
                    EARLY.to_vec(),
                    BAD.iter()
                        .chain(&AT)
                        .chain(&LACKED)
                        .chain(&LACKED_EARLY)
                        .copied()
                        .collect(),
                ),
            };
            let mut state = 0x2545_f491_4f6c_dd1du64;
            let mut rand = move |n: usize| {
                state ^= state << 13;
                state ^= state >> 7;
                state ^= state << 17;
                (state % n as u64) as usize
            };
            let (mut opaque_seen, mut wrapped_seen, mut wrapped_noted_seen) = (0, 0, 0);
            let (mut early_seen, mut early_noted_seen, mut spliced_seen) = (0, 0, 0);
            for _ in 0..5000 {
                let count = 1 + rand(5);
                let bad_at = if rand(4) == 0 {
                    Some(rand(count))
                } else {
                    None
                };
                let (mut plain, mut noted) = (String::new(), String::new());
                // a note, or the end of the text, at or after the first wrapper, and at or after
                // the first early definition
                let (mut wrapped, mut early) = (false, false);
                let (mut noted_after_wrapper, mut noted_after_early) = (false, false);
                // a definition met after a command that may take arguments
                let (mut inert, mut spliced) = (true, false);
                for i in 0..count {
                    let ends_early = bad_at != Some(i) && rand(6) == 0;
                    let def = if bad_at == Some(i) {
                        bad_defs[rand(bad_defs.len())]
                    } else if ends_early {
                        early_defs[rand(early_defs.len())]
                    } else {
                        defs[rand(defs.len())]
                    };
                    // (the unbalanced definition would be closed by the wrapper's brace)
                    let wrap = if bad_at != Some(i) && rand(5) == 0 {
                        Some(WRAPS[rand(WRAPS.len())])
                    } else {
                        None
                    };
                    let gap = GAPS[rand(GAPS.len())];
                    let note = NOTES[rand(NOTES.len())];
                    let open_command = wrap.is_some_and(|(open, _)| open.contains('\\'));
                    let close_command = wrap.is_some_and(|(_, close)| close.contains('\\'));
                    spliced |= bad_at != Some(i) && (open_command || !inert);
                    inert &= !open_command && !close_command && !ends_early;
                    wrapped |= wrap.is_some();
                    early |= ends_early;
                    noted_after_wrapper |= wrapped && !note.is_empty();
                    noted_after_early |= early && !note.is_empty();
                    if let Some((open, close)) = wrap {
                        plain.push_str(open);
                        plain.push_str(def);
                        plain.push_str(close);
                        plain.push_str(gap);
                        noted.push_str(open);
                        noted.push_str(def);
                        noted.push_str(gap);
                        noted.push_str(note);
                        if !note.is_empty() && !note.ends_with('\n') {
                            noted.push('\n');
                        }
                        noted.push_str(close);
                        noted.push_str(gap);
                        continue;
                    }
                    plain.push_str(def);
                    plain.push_str(gap);
                    noted.push_str(def);
                    // a note needs a safe point before it: nothing but blanks after the definition
                    noted.push_str(gap);
                    noted.push_str(note);
                    if !note.is_empty() && !note.ends_with('\n') {
                        noted.push('\n');
                    }
                }
                // a note before the first definition and a last one without a newline
                let first = NOTES[rand(NOTES.len())];
                let last = ["", "% end"][rand(2)];
                noted_after_wrapper |= wrapped && !last.is_empty();
                noted_after_early |= early && !last.is_empty();
                let noted = format!("{first}{noted}{last}");
                let (a, b) = (analyze(&plain, engine), analyze(&noted, engine));
                assert!(a.affecting, "{engine:?}: {plain:?}");
                assert_eq!(
                    a.opaque,
                    bad_at.is_some() || spliced,
                    "{engine:?}: {plain:?}"
                );
                // every note is followed, except from the first wrapper or early definition on
                assert_eq!(
                    (
                        a.affecting,
                        a.opaque || noted_after_wrapper || noted_after_early
                    ),
                    (b.affecting, b.opaque),
                    "{engine:?}: {plain:?} against {noted:?}"
                );
                opaque_seen += usize::from(a.opaque);
                spliced_seen += usize::from(spliced && bad_at.is_none());
                wrapped_seen += usize::from(wrapped);
                wrapped_noted_seen += usize::from(noted_after_wrapper && !a.opaque);
                early_seen += usize::from(early);
                // made opaque by a note that only the early definition leaves unsafe
                early_noted_seen +=
                    usize::from(noted_after_early && !noted_after_wrapper && !a.opaque);
            }
            assert!(
                opaque_seen > 500,
                "{engine:?}: {opaque_seen} opaque preambles"
            );
            assert!(
                wrapped_seen > 1000,
                "{engine:?}: {wrapped_seen} wrapped preambles"
            );
            assert!(
                spliced_seen > 1000,
                "{engine:?}: {spliced_seen} preambles with a definition after a command"
            );
            assert!(
                wrapped_noted_seen > 300,
                "{engine:?}: {wrapped_noted_seen} wrapped preambles made opaque by a note"
            );
            assert!(
                early_seen > 1000,
                "{engine:?}: {early_seen} preambles with an early end"
            );
            assert!(
                early_noted_seen > 150,
                "{engine:?}: {early_noted_seen} preambles made opaque by a note after an early end alone"
            );
        }
    }

    /// The rule reads TeX as KaTeX does (deviation D5): a `\newcommand` in a
    /// comment or after a `\\` is no definition, so such a math defines
    /// nothing under either engine, takes no name from the rule and leaves
    /// the environment of every later math alone; the real definition after
    /// it is the first one and is passed on as `\renewcommand`. A math the
    /// rule does rewrite is one that defines something, so it is affecting.
    #[test]
    fn a_look_alike_takes_no_name_from_the_rule() {
        let state = |engine: Engine, tex: &str| {
            let mut scope = MacroScope::new(engine);
            let r = scope.next(tex);
            (r.affecting, scope.is_opaque(), r.tex)
        };
        for tex in [
            r"% \newcommand{\R}{1}",
            r"a \\newcommand{\Q}{x}",
            " \t% \\newcommand{ \\Complex }{1}",
            "% c\n% \\newcommand\\cnums{1}\n",
            r"% \newcommand{\a}{1}",
            r"a \\newcommand{\Qx}{x}",
            r"% \renewcommand{\R}{1}",
            r"% \newcommand*{\R}{1}",
        ] {
            for engine in [Engine::Katex, Engine::MathJax] {
                assert_eq!(
                    state(engine, tex),
                    (false, false, tex.to_string()),
                    "{engine:?}: {tex:?}"
                );
            }
        }
        let mut scope = MacroScope::new(Engine::Katex);
        for tex in [r"% \newcommand{\R}{1}", r"a \\newcommand{\R}{2}"] {
            let r = scope.next(tex);
            assert!(!r.affecting, "{tex:?}");
            assert_eq!(r.tex, tex);
        }
        let real = scope.next(r"\newcommand{\R}{\mathbb{R}}");
        assert!(real.affecting);
        assert_eq!(real.tex, r"\renewcommand{\R}{\mathbb{R}}");
        // the same definition after a plain comment is keyed the same
        let mut other = MacroScope::new(Engine::Katex);
        assert!(!other.next("% note").affecting);
        let real_without = other.next(r"\newcommand{\R}{\mathbb{R}}");
        assert_eq!(real_without.tex, real.tex);
        assert_eq!(real_without.env, real.env);
        // a rewritten math is a definition, in every form
        for tex in [
            r"\newcommand{\R}{1}",
            r"\providecommand{\bm}[1]{\boldsymbol{#1}}",
            "\\newcommand% c\n{\\argmax}{x}",
        ] {
            let mut scope = MacroScope::new(Engine::Katex);
            let r = scope.next(tex);
            assert_ne!(r.tex, tex, "{tex:?} is rewritten");
            assert!(r.affecting, "{tex:?}");
        }
    }

    /// The parts of a definition and the address of `\url`, `\href` and
    /// `\includegraphics` are read as KaTeX's lexer reads them, on the TeX
    /// itself (the rows are the output of `tests/mathgrammar/katex_rule.mjs`):
    /// a braced name is exactly one token, a `\verb` token where the name
    /// should be claims nothing, and a `%` in an address starts no comment.
    /// Each row is one document, its maths typeset in order with one set of
    /// defined names.
    #[test]
    fn the_rule_reads_the_parts_and_the_address_as_katex_does() {
        let rows: &[(&[&str], &[&str])] = &[
            // a blank after a comment inside the braces is a token of its own
            (
                &["\\newcommand{%a\n \\R}{1}", r"\newcommand{\R}{2}"],
                &["\\newcommand{%a\n \\R}{1}", r"\renewcommand{\R}{2}"],
            ),
            // ... and so is a blank between two comments after the name
            (
                &["\\newcommand{\\R%a\n %b\n}{1}", r"\newcommand{\R}{2}"],
                &["\\newcommand{\\R%a\n %b\n}{1}", r"\renewcommand{\R}{2}"],
            ),
            // a comment that ends the text leaves the brace unclosed
            (
                &[r"\newcommand{\R%a", r"\newcommand{\R}{2}"],
                &[r"\newcommand{\R%a", r"\renewcommand{\R}{2}"],
            ),
            // a carriage return and a tab are blanks after the name
            (
                &["\\newcommand{\\R\r\n\t}{1}"],
                &["\\renewcommand{\\R\r\n\t}{1}"],
            ),
            // a tab, a carriage return and a line feed after the brace are tokens of their own
            (
                &[
                    "\\newcommand{\t\\R}{1}",
                    "\\newcommand{\r\\R}{2}",
                    "\\newcommand{\n\\R}{3}",
                    r"\newcommand{\R}{4}",
                ],
                &[
                    "\\newcommand{\t\\R}{1}",
                    "\\newcommand{\r\\R}{2}",
                    "\\newcommand{\n\\R}{3}",
                    r"\renewcommand{\R}{4}",
                ],
            ),
            // a no-break space after the name is a token of its own
            (
                &["\\newcommand{\\R\u{a0}}{1}", r"\newcommand{\R}{2}"],
                &["\\newcommand{\\R\u{a0}}{1}", r"\renewcommand{\R}{2}"],
            ),
            // a lone backslash or a control symbol is no name
            (
                &[r"\newcommand{\}{1}\newcommand{\,}{2}\newcommand{\R}{3}"],
                &[r"\newcommand{\}{1}\newcommand{\,}{2}\renewcommand{\R}{3}"],
            ),
            // the address: the blanks the lexer takes with the control word, a tab, a carriage return
            (
                &["\\url\t\r\n{%}\\newcommand{\\R}{1}"],
                &["\\url\t\r\n{%}\\renewcommand{\\R}{1}"],
            ),
            // the address: a group closed by a brace after a backslash and a character
            (
                &[
                    r"\url{\\}\newcommand{\R}{1}",
                    "\\url{\\%}%\n\\newcommand{\\N}{2}",
                ],
                &[
                    r"\url{\\}\renewcommand{\R}{1}",
                    "\\url{\\%}%\n\\renewcommand{\\N}{2}",
                ],
            ),
            // the address: the end of the text right after the word, and after the blanks
            (
                &[r"\url", "\\href \n", r"\url{", r"\newcommand{\R}{1}"],
                &[r"\url", "\\href \n", r"\url{", r"\renewcommand{\R}{1}"],
            ),
            // the address of an href holds a verb whose delimiter is a brace character
            (
                &[
                    r"\href{\verb|}|}{t}\newcommand{\R}{1}",
                    r"\href{\verb}}}{t}\newcommand{\N}{1}",
                ],
                &[
                    r"\href{\verb|}|}{t}\renewcommand{\R}{1}",
                    r"\href{\verb}}}{t}\renewcommand{\N}{1}",
                ],
            ),
            // unclosed groups one inside the other: nothing after them is read
            (
                &[
                    r"\url{\href{\url{\href{\newcommand{\R}{1}",
                    r"\newcommand{\R}{2}",
                ],
                &[
                    r"\url{\href{\url{\href{\newcommand{\R}{1}",
                    r"\renewcommand{\R}{2}",
                ],
            ),
            // the verb token as the name: a verb that finds no closing delimiter is the control word
            (
                &[
                    r"\newcommand\verb|\R}{1}",
                    r"\newcommand{\verb}{2}",
                    r"\newcommand{\R}{3}",
                ],
                &[
                    r"\newcommand\verb|\R}{1}",
                    r"\newcommand{\verb}{2}",
                    r"\renewcommand{\R}{3}",
                ],
            ),
            // the verb token as the name: the delimiter is a line terminator, and the text runs to
            // the same one, so the definition inside it is text
            (
                &[
                    "\\newcommand\\verb\n\\newcommand\\argmax\n{x}",
                    r"\newcommand{\argmax}{y}",
                ],
                &[
                    "\\newcommand\\verb\n\\newcommand\\argmax\n{x}",
                    r"\renewcommand{\argmax}{y}",
                ],
            ),
            (
                &[
                    "\\newcommand\\verb\r\\newcommand\\argmax\r{x}",
                    r"\newcommand{\argmax}{y}",
                ],
                &[
                    "\\newcommand\\verb\r\\newcommand\\argmax\r{x}",
                    r"\renewcommand{\argmax}{y}",
                ],
            ),
            (
                &[
                    "\\newcommand{\\verb\u{2028}\\newcommand\\R\u{2028}}{x}",
                    r"\newcommand{\R}{y}",
                ],
                &[
                    "\\newcommand{\\verb\u{2028}\\newcommand\\R\u{2028}}{x}",
                    r"\renewcommand{\R}{y}",
                ],
            ),
            // ... another line terminator first: no verb token, the name is the word `verb`
            (
                &["\\newcommand\\verb\n\r\\newcommand\\R\n{1}"],
                &["\\newcommand\\verb\n\r\\renewcommand\\R\n{1}"],
            ),
            // the address holds a verb token whose delimiter is a line terminator, braced or not
            (
                &[
                    "\\url{\\verb\n}\n\\newcommand{\\R}{1}}",
                    r"\newcommand{\R}{2}",
                ],
                &[
                    "\\url{\\verb\n}\n\\newcommand{\\R}{1}}",
                    r"\renewcommand{\R}{2}",
                ],
            ),
            (
                &["\\url\\verb\r\\newcommand{\\R}{1}\r", r"\newcommand{\R}{2}"],
                &[
                    "\\url\\verb\r\\newcommand{\\R}{1}\r",
                    r"\renewcommand{\R}{2}",
                ],
            ),
            // ... and none when another line terminator comes first: the brace after it closes
            (
                &[
                    "\\href{\\verb\n}\r}\\newcommand{\\R}{1}",
                    r"\newcommand{\R}{2}",
                ],
                &[
                    "\\href{\\verb\n}\r}\\renewcommand{\\R}{1}",
                    r"\newcommand{\R}{2}",
                ],
            ),
            // the address of `\includegraphics`, after its optional argument in brackets, which is
            // lexed as anywhere else (the comment before it, and one inside it, are comments)
            (
                &[r"\includegraphics[height=1em]{a%20b.png} \newcommand{\R}{\mathbb{R}} \R"],
                &[r"\includegraphics[height=1em]{a%20b.png} \renewcommand{\R}{\mathbb{R}} \R"],
            ),
            (
                &["\\includegraphics\t\r\n[a%]\n]\n {%}\\newcommand{\\R}{1}"],
                &["\\includegraphics\t\r\n[a%]\n]\n {%}\\renewcommand{\\R}{1}"],
            ),
            (
                &["\\includegraphics%c\n{a%b}\\newcommand{\\R}{1}"],
                &["\\includegraphics%c\n{a%b}\\renewcommand{\\R}{1}"],
            ),
            // ... after the brackets a `%` is the one token the address takes
            (
                &["\\includegraphics[x]\t%\\newcommand{\\R}{1}"],
                &["\\includegraphics[x]\t%\\renewcommand{\\R}{1}"],
            ),
            // ... the brackets end at the `]` outside any group, a verb token is one token
            (
                &[r"\includegraphics[{]}]{a%}\newcommand{\R}{1}"],
                &[r"\includegraphics[{]}]{a%}\renewcommand{\R}{1}"],
            ),
            (
                &["\\includegraphics[\\verb\n]\n]{a%}\\newcommand{\\R}{1}"],
                &["\\includegraphics[\\verb\n]\n]{a%}\\renewcommand{\\R}{1}"],
            ),
            // ... a definition inside them is not looked at
            (
                &[
                    r"\includegraphics[\newcommand{\R}{1}]{x}",
                    r"\newcommand{\R}{2}",
                ],
                &[
                    r"\includegraphics[\newcommand{\R}{1}]{x}",
                    r"\renewcommand{\R}{2}",
                ],
            ),
            // ... a `}` that closes no group in them, with none open around them, or brackets never closed, end the formula
            (
                &[
                    r"\includegraphics[a}]{x}\newcommand{\R}{1}",
                    r"\newcommand{\R}{2}",
                ],
                &[
                    r"\includegraphics[a}]{x}\newcommand{\R}{1}",
                    r"\renewcommand{\R}{2}",
                ],
            ),
            (
                &[
                    r"\includegraphics[a\newcommand{\R}{1}",
                    r"\newcommand{\R}{2}",
                ],
                &[
                    r"\includegraphics[a\newcommand{\R}{1}",
                    r"\renewcommand{\R}{2}",
                ],
            ),
            // ... the end of the text after the word, the bracket or the brackets
            (
                &[
                    r"\includegraphics",
                    r"\includegraphics[",
                    r"\includegraphics[x]",
                    r"\newcommand{\R}{1}",
                ],
                &[
                    r"\includegraphics",
                    r"\includegraphics[",
                    r"\includegraphics[x]",
                    r"\renewcommand{\R}{1}",
                ],
            ),
            // ... and another control word is no `\includegraphics`
            (
                &[
                    r"\includegraphicsx{%}\newcommand{\R}{1}",
                    r"\includegraphics@{%}\newcommand{\R}{1}",
                ],
                &[
                    r"\includegraphicsx{%}\newcommand{\R}{1}",
                    r"\includegraphics@{%}\newcommand{\R}{1}",
                ],
            ),
            // the verb token as the name, in braces, the star form
            (
                &[
                    r"\newcommand{\verb*!\newcommand\Z!}{1}",
                    r"\newcommand{\Z}{2}",
                ],
                &[
                    r"\newcommand{\verb*!\newcommand\Z!}{1}",
                    r"\renewcommand{\Z}{2}",
                ],
            ),
        ];
        for (maths, want) in rows {
            let mut defined = HashSet::new();
            let got: Vec<String> = maths
                .iter()
                .map(|t| katex_newcommand(t, &mut defined))
                .collect();
            assert_eq!(got, *want, "{maths:?}");
        }
        // a `}` where the address starts, with no group open, closes none: KaTeX reports "Extra }" and the formula ends there, so
        // the definition after it is not rewritten and claims no name
        for tex in [
            r"\url}\newcommand{\R}{1}",
            r"\includegraphics}\newcommand{\R}{1}",
            r"\includegraphics[x]}\newcommand{\R}{1}",
        ] {
            let mut defined = HashSet::new();
            assert_eq!(katex_newcommand(tex, &mut defined), tex, "{tex:?}");
            assert!(defined.is_empty(), "{tex:?} defined {defined:?}");
        }
        // ... a `}` after a whole address is read on, and `\}` is the one token
        for (tex, want) in [
            (r"\url{}}\newcommand{\R}{1}", r"\url{}}\renewcommand{\R}{1}"),
            (r"\url\}\newcommand{\R}{1}", r"\url\}\renewcommand{\R}{1}"),
        ] {
            let mut defined = HashSet::new();
            assert_eq!(katex_newcommand(tex, &mut defined), want, "{tex:?}");
            assert!(defined.contains("R"), "{tex:?}");
        }
        // ... and with a group open that `}` closes it (a definition body, a braced name, after `\let`, the
        // brackets of `\includegraphics` left open in a body, a body with a braced name in it): the definition
        // after it is rewritten and claimed, by the rule and by the scope
        for prefix in [
            r"\newcommand{\img}{\includegraphics}",
            r"\newcommand{\lk}{\url}",
            r"\def\lk{\href}",
            r"\newcommand{\fig}[1]{\includegraphics[width=#1]}",
            r"\newcommand{\fig}{\includegraphics[width=}",
            r"\renewcommand{\url}[1]{\texttt{#1}}",
            r"{\let\lk\url}",
            r"\newcommand{\a}{\newcommand{\b}{x}\url}",
            r"\newcommand{\a}{\newcommand{\verb|x|}{1}\url}",
        ] {
            let tex = format!(r"{prefix}\newcommand{{\R}}{{1}}");
            let want = format!(r"{prefix}\renewcommand{{\R}}{{1}}");
            let mut defined = HashSet::new();
            assert_eq!(katex_newcommand(&tex, &mut defined), want, "{tex:?}");
            assert!(defined.contains("R"), "{tex:?}");
            let got = MacroScope::new(Engine::Katex).next(&tex);
            assert_eq!(got.tex, want, "{tex:?}");
            assert!(got.affecting, "{tex:?}");
        }
        // ... the count is back at 0 after them, so a `}` there ends the formula again
        for tex in [
            r"\newcommand{\lk}{\url}\url}\newcommand{\R}{1}",
            r"\newcommand{\b}{x}\url}\newcommand{\R}{1}",
            r"\newcommand\b{x}\url}\newcommand{\R}{1}",
            r"\newcommand{\verb|x|}{1}\url}\newcommand{\R}{1}",
            r"\newcommand\verb|x|{1}\url}\newcommand{\R}{1}",
            r"x}\url}\newcommand{\R}{1}",
        ] {
            let mut defined = HashSet::new();
            assert_eq!(katex_newcommand(tex, &mut defined), tex, "{tex:?}");
            assert!(!defined.contains("R"), "{tex:?} defined {defined:?}");
        }
    }

    /// The text of a `\verb` ends at the next delimiter on its line, as KaTeX
    /// lexes it, whichever `\verb` before it had none to find: the answers
    /// come from one index of the line, and a line of its own for each. A
    /// line terminator as the delimiter ends the text at the next line
    /// terminator when that is the same one, and starts none otherwise.
    #[test]
    fn verb_text_ends_at_the_next_delimiter_of_its_line() {
        let rule = |tex: &str| katex_newcommand(tex, &mut HashSet::new());
        for (tex, want) in [
            // a definition after the text is read, one inside it is not
            (
                "\\verb|a|\\newcommand{\\R}{x}",
                "\\verb|a|\\renewcommand{\\R}{x}",
            ),
            (
                "\\verb|\\newcommand{\\R}{x}|\\newcommand{\\R}{y}",
                "\\verb|\\newcommand{\\R}{x}|\\renewcommand{\\R}{y}",
            ),
            // the star form, any character as the delimiter, an ASCII letter included
            (
                "\\verb*!\\newcommand{\\R}{x}!\\newcommand{\\R}{y}",
                "\\verb*!\\newcommand{\\R}{x}!\\renewcommand{\\R}{y}",
            ),
            (
                "\\verb*a\\newcommand{\\R}{x}a\\newcommand{\\R}{y}",
                "\\verb*a\\newcommand{\\R}{x}a\\renewcommand{\\R}{y}",
            ),
            // a letter right after the word makes another word, `@` and others a delimiter
            (
                "\\verba\\newcommand{\\R}{x}a",
                "\\verba\\renewcommand{\\R}{x}a",
            ),
            (
                "\\verb@\\newcommand{\\R}{x}@\\newcommand{\\R}{y}",
                "\\verb@\\newcommand{\\R}{x}@\\renewcommand{\\R}{y}",
            ),
            // the delimiter must come back on the same line
            (
                "\\verb|\\newcommand{\\R}{x}\n|\\newcommand{\\R}{y}",
                "\\verb|\\renewcommand{\\R}{x}\n|\\newcommand{\\R}{y}",
            ),
            (
                "\\verb|a|\n\\verb|\\newcommand{\\R}{x}|\n\\newcommand{\\R}{y}",
                "\\verb|a|\n\\verb|\\newcommand{\\R}{x}|\n\\renewcommand{\\R}{y}",
            ),
            // one with no closing delimiter, then others of the same line: each is answered from
            // the one index of the line
            (
                "\\verb1\\verb2\\verb|\\newcommand{\\R}{x}|\\newcommand{\\R}{y}",
                "\\verb1\\verb2\\verb|\\newcommand{\\R}{x}|\\renewcommand{\\R}{y}",
            ),
            (
                "\\verb\u{e9}\\newcommand{\\R}{x}\u{e9}\\verb\u{20ac}\u{20ac}\\newcommand{\\R}{y}",
                "\\verb\u{e9}\\newcommand{\\R}{x}\u{e9}\\verb\u{20ac}\u{20ac}\\renewcommand{\\R}{y}",
            ),
            // a line terminator as the delimiter: the dot matches none, so the text runs to the next
            // line terminator and ends there when that is the same one, so a definition in it is text
            (
                "\\verb\n\\newcommand{\\R}{x}\n\\newcommand{\\R}{y}",
                "\\verb\n\\newcommand{\\R}{x}\n\\renewcommand{\\R}{y}",
            ),
            (
                "\\verb\r\\newcommand{\\R}{x}\r\\newcommand{\\R}{y}",
                "\\verb\r\\newcommand{\\R}{x}\r\\renewcommand{\\R}{y}",
            ),
            (
                "\\verb\u{2028}\\newcommand{\\R}{x}\u{2028}\\newcommand{\\R}{y}",
                "\\verb\u{2028}\\newcommand{\\R}{x}\u{2028}\\renewcommand{\\R}{y}",
            ),
            (
                "\\verb*\u{2029}\\newcommand{\\R}{x}\u{2029}\\newcommand{\\R}{y}",
                "\\verb*\u{2029}\\newcommand{\\R}{x}\u{2029}\\renewcommand{\\R}{y}",
            ),
            // ... and when another line terminator comes first, or none, there is no text and
            // `\verb` is a control word
            (
                "\\verb\n\r\\newcommand{\\R}{x}\n",
                "\\verb\n\r\\renewcommand{\\R}{x}\n",
            ),
            (
                "\\verb\r\n\\newcommand{\\R}{x}\r",
                "\\verb\r\n\\renewcommand{\\R}{x}\r",
            ),
            (
                "\\verb\u{2028}\n\\newcommand{\\R}{x}\u{2028}",
                "\\verb\u{2028}\n\\renewcommand{\\R}{x}\u{2028}",
            ),
            (
                "\\verb\n\\newcommand{\\R}{x}",
                "\\verb\n\\renewcommand{\\R}{x}",
            ),
            // an empty text
            (
                "\\verb\n\n\\newcommand{\\R}{x}",
                "\\verb\n\n\\renewcommand{\\R}{x}",
            ),
            // the end of the text, with and without the delimiter
            ("\\verb", "\\verb"),
            ("\\verb*", "\\verb*"),
            ("\\verb|", "\\verb|"),
            ("\\verb*|a", "\\verb*|a"),
        ] {
            assert_eq!(rule(tex), want, "{tex:?}");
        }
        // a thousand of them, each with a delimiter of its own, then a definition
        let mut tex = String::new();
        for c in 0x100u32..0x100 + 1000 {
            tex.push_str("\\verb");
            tex.push(char::from_u32(c).unwrap());
        }
        tex.push_str("\\newcommand{\\R}{x}");
        assert!(rule(&tex).ends_with("\\renewcommand{\\R}{x}"));
    }

    /// MathJax's `unicode` package keeps the font of a code point in a table
    /// of the module, so `\unicode[Garamond]{x263A}` changes every later
    /// `\unicode{x263A}`. MathJax reads the bracket from whatever follows the
    /// command once the macros are expanded, so a `\unicode` whose next
    /// character (after JavaScript white space) is not `{` may read a font:
    /// the math that holds one is affecting, and a definition that holds one,
    /// or a `\let` of the command, is opaque (an alias takes its font from the
    /// call site). A `\unicode` followed by `{` reads none. KaTeX has no
    /// `\unicode`.
    #[test]
    fn mathjax_unicode_font_is_state() {
        for tex in [
            r"\unicode[Garamond]{x263A}",
            r"\unicode [Garamond]{x263A}",
            "\\unicode\n\t[Garamond]{x263A}",
            "\\unicode\u{a0}[Garamond]{x263A}",
            "\\unicode\u{3000}[Garamond]{x263A}",
            r"\unicode[0.7,0.2]{x263A}",
            r"\unicode[0.7,0.2][Garamond]{x263A}",
            r"\unicode[]{x263A}",
            r"x + \unicode[Courier]{x263A} + y",
            r"\text{\unicode[Courier]{x263A}}",
        ] {
            assert_eq!(defines_in(Engine::MathJax, tex), (true, false), "{tex:?}");
            assert_eq!(defines_in(Engine::Katex, tex), (false, false), "{tex:?}");
        }
        // the command with something other than its `{` right after it may read a font from what
        // follows it once macros are expanded: affecting under MathJax, still nothing to KaTeX
        for tex in [
            r"\unicode x263A",
            r"\unicode",
            r"\unicode@[Garamond]{x263A}",
            r"\app{\unicode}",
            r"{\unicode}[Garamond]{x263A}",
        ] {
            assert_eq!(defines_in(Engine::MathJax, tex), (true, false), "{tex:?}");
            assert_eq!(defines_in(Engine::Katex, tex), (false, false), "{tex:?}");
        }
        for tex in [
            r"\unicode{x263A}",
            r"\unicodex[Garamond]{x263A}",
            r"\unicod[Garamond]{x263A}",
            r"[Garamond]\unicode{x263A}",
            // a comment at a safe point is hidden from both engines
            "% \\unicode[Garamond]{x263A}\n",
        ] {
            for engine in [Engine::Katex, Engine::MathJax] {
                assert_eq!(
                    defines_in(engine, tex),
                    (false, false),
                    "{engine:?}: {tex:?}"
                );
            }
        }
        // a body that may read a font writes the table whenever the macro runs, and an alias of the
        // command takes the font from the call site (`\U[Garamond]{x263A}`): not followed
        for tex in [
            r"\newcommand{\smile}{\unicode[Garamond]{x263A}}",
            r"\def\smile{\unicode [Garamond]{x263A}}",
            r"\let\smile=\unicode[Garamond]",
            r"\newcommand\smile[1]{\unicode[#1]{x263A}}",
            r"\newcommand{\U}{\unicode}",
            r"\newcommand{\U}{\unicode }",
            r"\def\U{\unicode}",
            r"\newcommand\U\unicode",
            r"\newcommand{\U}[1]{\unicode#1}",
            r"\def\U#1{\unicode#1}",
            r"\let\U\unicode",
            r"\let\U=\unicode",
            // (the `{` after the target is formula text: `\U` is still the command)
            r"\let\U = \unicode{x263A}",
            r"\let\U\unicode{x263A}",
        ] {
            assert_eq!(defines_in(Engine::MathJax, tex), (true, true), "{tex:?}");
            assert_eq!(defines_in(Engine::Katex, tex), (true, false), "{tex:?}");
        }
        // and one that only uses it, with its code point right after it, is followed
        for tex in [
            r"\newcommand{\smile}{\unicode{x263A}}",
            r"\def\smile{\unicode{x263A}}",
            r"\def\smile{\unicode {x263A}}",
            "\\def\\smile{\\unicode\n{x263A}}",
        ] {
            assert_eq!(defines(tex), (true, false), "{tex:?}");
        }
    }

    /// A control symbol over a character of two or three bytes is one token,
    /// so the body that follows is the body (the lead byte alone used to be
    /// taken for the name, and the rest of the character for the body, which
    /// left the definition inside the body to be read as a definition of its
    /// own, not as part of the first). As a name it is outside the model, so
    /// the scope is opaque with a body that defines nothing as well.
    #[test]
    fn a_control_symbol_over_a_wide_character_is_one_token() {
        for tex in [
            "\\newcommand\\\u{e9}{\\gdef\\b{X}}",
            "\\let\\\u{e9}\\gdef\\relax{}",
            "\\DeclareMathOperator\\\u{e9}{\\gdef\\b{X}}",
            "\\newcommand\\\u{20ac}{\\gdef\\b{X}}",
            "\\newcommand{\\\u{e9}}{\\gdef\\b{X}}",
        ] {
            assert_eq!(defines(tex), (true, true), "{tex:?}");
        }
        // and with a body that defines nothing: the name alone is outside the model
        for tex in [
            "\\newcommand\\\u{e9}{x}",
            "\\newcommand\\\u{20ac}{\\frac{a}{b}}",
            "\\let\\\u{e9}\\relax",
            "\\DeclareMathOperator\\\u{e9}{op}",
            "\\def\\\u{e9}#1{#1}",
        ] {
            assert_eq!(defines(tex), (true, true), "{tex:?}");
        }
        // the astral character is read as a command by one engine only
        for tex in [
            "\\newcommand\\\u{1F600}{x}",
            "\\let\\\u{1F600}\\relax",
            "\\def\\a{\\\u{1F600}}",
            "x \\\u{1F600}",
        ] {
            assert_eq!(defines(tex), (true, true), "{tex:?}");
        }
    }

    /// A definition that an engine reads further than the walk does: what the
    /// walk takes after its own end is a part of that engine's definition, so
    /// a defining command there is stored in a macro body (which the scope's
    /// own rule makes opaque) and a `%` there is read as a character. So the
    /// scope is opaque, with a note after the definition and without one.
    /// The forms were found by typesetting documents with the engines
    /// themselves (MathJax 3.2.2 with all packages, KaTeX 0.16.21).
    #[test]
    fn a_definition_an_engine_ends_later_is_not_followed() {
        // MathJax starts the body of a `\def` at the `{` of a `\{` in its parameter text
        for tex in [
            r"\def\a\{{x} % }\def\b{X}",
            r"\def\a#1\{{#1} % }\def\b{X}",
            r"\def\a\{{x} \def\b{X}}",
            r"\global\def\a\{{x}",
            r"\def\a#1\{#1\}{x}",
        ] {
            assert_eq!(defines(tex), (true, true), "{tex:?}");
        }
        // the controls: a `\\` or a `\}` before the body, which no engine reads as its brace
        for tex in [r"\def\a\\{x} % }\def\b{X}", r"\def\a\}{x} % note"] {
            assert_eq!(defines(tex), (true, false), "{tex:?}");
        }

        // MathJax skips every character of JavaScript `\s` before an argument, KaTeX and the
        // walk read it as a part: the body, the target, the place of a count. A form feed is
        // outside the model too (KaTeX cannot lex it at all)
        for ws in [
            "\u{a0}", "\u{3000}", "\u{feff}", "\u{b}", "\u{2003}", "\u{205f}", "\x0c",
        ] {
            for shape in [
                "\\newcommand\\a{ws}{\\def\\cc{X}}",
                "\\newcommand\\a{ws}[1]{#1}",
                "\\newcommand{\\a}{ws}{x}",
                "\\newcommand{ws}\\a{x}",
                "\\newcommand\\a[1]{ws}[x]{#1}",
                "\\let\\a{ws}\\def\\relax{}",
                "\\let\\a={ws}\\relax",
                "\\def{ws}\\a{x}",
                "\\DeclareMathOperator\\a{ws}{\\def\\cc{X}}",
                "\\DeclareMathOperator{ws}*{\\a}{x}",
            ] {
                let tex = shape.replace("{ws}", ws);
                assert_eq!(defines(&tex), (true, true), "{tex:?}");
            }
        }
        // the controls: ASCII blanks, which both engines skip there
        for ws in [" ", "\t", "\n", "\r", " \n\t "] {
            for shape in [
                "\\newcommand\\a{ws}{x}",
                "\\newcommand\\a{ws}[1]{ws}{#1}",
                "\\let\\a{ws}={ws}\\relax",
                "\\DeclareMathOperator{ws}*{ws}{\\a}{ws}{x}",
            ] {
                let tex = shape.replace("{ws}", ws);
                assert_eq!(defines(&tex), (true, false), "{tex:?}");
            }
        }
        // white space beyond ASCII inside a body is outside the model too
        assert_eq!(defines("\\newcommand\\a{\u{a0}x\u{3000}}"), (true, true));

        // KaTeX reads `\@` and the letters or `@` after it as one control word (`@` is a letter
        // to its lexer), MathJax and the walk read the control symbol `\@`: outside the model
        // wherever it stands in a definition
        for tex in [
            r"\newcommand\@ab{\def\cc{X}}",
            r"\providecommand\@ab{\def\cc{X}}",
            r"\newcommand\@a\def\relax{}",
            r"\let\@ab\def\relax{}",
            r"\global\let\@ab\def\relax{}",
            r"\newcommand\@@{x}",
            r"\newcommand\@ab{x}",
            r"\newcommand{\@ab}{x}",
            r"\let\@ab\relax",
            r"\def\@ab{x}",
            r"\DeclareMathOperator\@ab{x}",
            r"\newcommand\@{x}",
            r"\newcommand\@ \hat",
            r"\let\@\relax",
            r"\def\@#1{#1}",
            r"\newcommand\a\@ab",
            r"\let\a\@ab",
        ] {
            assert_eq!(defines(tex), (true, true), "{tex:?}");
        }

        // KaTeX makes a character and the combining marks after it one token: a `}` with a mark
        // closes nothing, a `{` with one starts no body of a `\def`, a `%` with one is no comment
        let m = '\u{301}';
        for tex in [
            format!("\\newcommand\\a{{\\@secondoftwo}}{m}{{}}\\def\\cc{{X}}}}"),
            format!("\\def\\a{{\\@secondoftwo}}{m}{{}}\\def\\cc{{X}}}}"),
            format!("\\def\\a{{{m}x}}{{\\def\\cc{{X}}}}"),
            format!("\\newcommand\\a{{x}} %{m} note"),
            format!("\\newcommand\\a[1]{m}{{x}}"),
            format!("\\newcommand\\a[1][x]{m}{{y}}"),
            format!("\\newcommand\\cafe{{\\text{{cafe{m}}}}}"),
            format!("\\let\\a={m}\\relax"),
            format!("\\newcommand*{m}{{\\a}}{{x}}"),
            format!("\\DeclareMathOperator{{\\a}}{{x}}{m}"),
            format!("\\def\\a#{m}1{{x}}"),
            // (alone, a `%` with a mark is an error in KaTeX and a comment in MathJax: the
            // scope is conservative)
            format!("%{m} \\def\\b{{X}}"),
        ] {
            assert_eq!(defines(&tex), (true, true), "{tex:?}");
        }
        // the controls: a mark in a comment after its `%`
        for tex in [
            format!("\\newcommand\\a{{x}} % e{m}"),
            format!("\\def\\a{{x}}\n% {m}\n"),
            format!("\\let\\a\\relax % {m}"),
        ] {
            assert_eq!(defines(&tex), (true, false), "{tex:?}");
        }
        assert_eq!(defines(&format!("x{m} % y")), (false, false));

        // KaTeX reads the argument after the name and starts a count when it is the single
        // token `[`, braced or not: `{[}1]{x}` is a count of 1 and the body `x` there, the body
        // `[` and formula text to MathJax and the walk
        for tex in [
            r"\newcommand\a{[}1]{\def\cc{X}}",
            r"\newcommand{\a}{[}1]{x}",
            r"\renewcommand\a {[}2]{#1#2}",
            r"\providecommand\a{[}",
        ] {
            assert_eq!(defines(tex), (true, true), "{tex:?}");
        }
        // the controls: a count read first, and groups that are not the lone `[`
        for tex in [
            r"\newcommand\a[1]{[}",
            r"\newcommand\a{[]}",
            r"\newcommand\a{ [}",
            r"\newcommand\a{[ }",
            r"\newcommand\a{[x}",
        ] {
            assert_eq!(defines(tex), (true, false), "{tex:?}");
        }
    }

    /// A macro that takes arguments can take a part of a definition after it
    /// and hand the engine the tokens in another order than the text has:
    /// with `\first` taking two arguments and giving back the first,
    /// `\first\let\y\b\def` lets `\b` be `\def` in both engines (KaTeX has such
    /// a macro built in, `\@firstoftwo`, and a delimited `\def\mk#1.{#1}` reads
    /// up to any token). Any command can be such a macro of the document, so a
    /// definition after one in the math is not followed. Before a followed
    /// definition the math holds only characters, blanks, comments at a safe
    /// point and definitions that both engines end where the walk does.
    #[test]
    fn a_definition_after_a_command_is_not_followed() {
        for tex in [
            r"\newcommand\first[2]{#1}\first\let\y\b\def\relax{}",
            r"\first\let\y\b\def\relax{}",
            r"\@firstoftwo\let\y\b\def\relax{}",
            r"\mk{\let\b}\def\relax{}",
            r"\def\mk#1.{#1}\mk\let\b.\def\relax{}",
            r"\mk\newcommand\b.{\def\cc{X}}",
            r"{\mk}\let\b.\def\relax{}",
            r"\text{\def\a{1}}",
            r"\alpha \def\a{1}",
            r"\, \def\a{1}",
            r"\\ \def\a{1}",
            r"\global\relax\def\a{1}",
            // after a definition an engine ends earlier, whose rest is formula text there
            r"\newcommand\g[1][x]\first\let\y\b\def\relax{}",
            r"\renewcommand*{\a}{x}\def\b{1}",
            r"\newcommand\a@\first\let\y\b\def\relax{}",
        ] {
            assert_eq!(defines(tex), (true, true), "{tex:?}");
        }
        // KaTeX expands the body of `\edef` and `\xdef` when it defines them, on the stack it
        // reads the text from, so a macro there reads on past the body: a body with a command
        // is not followed (`\edef\a{\first}\let\b` makes `\a` the command `\let`)
        for tex in [
            r"\newcommand\first[2]{#1}\edef\a{\first}\let\b\relax",
            r"\edef\a{\@firstoftwo}",
            r"\xdef\a{x\@firstoftwo}",
            r"\global\edef\a#1{#1\relax}",
        ] {
            assert_eq!(defines(tex), (true, true), "{tex:?}");
        }
        // (under MathJax, which has no `\edef`, a definition after one is not followed either)
        assert_eq!(
            defines_in(Engine::Katex, r"\edef\a{xy}\let\b\relax"),
            (true, false)
        );
        katex_follows(r"\edef\a{xy}");
        katex_follows(r"\edef\a\b{x}");
        assert_eq!(defines(r"\def\a{\first}\let\b\relax"), (true, false));
        // KaTeX's `\renewcommand*` defines the character `*` as a macro (here `\first`), so a
        // later `*` can take a definition after it as arguments: the scope is opaque from it
        for tex in [
            r"\renewcommand*\first{x}",
            r"\renewcommand *{\a}{x}",
            r"\global\renewcommand*{\a}{x}",
        ] {
            assert_eq!(defines(tex), (true, true), "{tex:?}");
        }
        for tex in [r"\newcommand*{\a}{x}", r"\renewcommand{\a}{*}"] {
            assert_eq!(defines(tex), (true, false), "{tex:?}");
        }
        // (`\providecommand` is a command MathJax lacks: opaque there)
        katex_follows(r"\providecommand*{\a}{x}");
        // and under MathJax after a command it does not have, which is formula text there
        let tex = r"\gdef\first{x}\let\y\b\def\relax{}";
        assert_eq!(defines_in(Engine::MathJax, tex), (true, true));
        assert_eq!(defines_in(Engine::Katex, tex), (true, false));
        // the controls: characters, groups, superscripts, comments and definitions before it,
        // and a command that is a part of a definition (a body, a target), which does not run
        for tex in [
            r"x = 1, \def\a{1}",
            r"{\def\a{1}}",
            r"x^{\def\a{1}}",
            r"\def\a{1}\def\b{2}",
            r"\newcommand\first[2]{#1}\let\b\relax",
            "% \\first\n\\let\\b\\relax",
            r"\let\a\first\let\b\relax",
            r"\newcommand\a\first\let\b\relax",
            r"\def\a#1\first{#1}\let\b\relax",
        ] {
            assert_eq!(defines(tex), (true, false), "{tex:?}");
        }
        // (MathJax has no `\global` or `\long`: opaque there)
        katex_follows(r"\global\def\a{1}\long\def\b{2}");
    }

    /// MathJax 3 has no `\providecommand`, `\gdef`, `\edef`, `\xdef`, `\global`
    /// or `\long`: it typesets the name (the `noundefined` package) and reads the
    /// rest as formula text, where a command the walk took for the name, the
    /// parameter text or a one-token body reads on (`\frac` takes `{x}` and
    /// the `%` after it), so the text after the `%` runs. That is outside the
    /// model: under MathJax a math that uses one of the six is opaque, with a
    /// note after it and without. KaTeX has them and follows the note.
    #[test]
    fn commands_mathjax_does_not_have_are_opaque_there() {
        for tex in [
            r"\gdef\frac{x} % \def\b{X}",
            r"\providecommand\frac{x} % \def\b{X}",
            r"\providecommand{\a}\hat % \def\b{X}",
            r"\gdef\a\frac{x} % \def\b{X}",
            r"\xdef\binom{n} % \def\b{X}",
            r"\edef\frac{x} % \def\b{X}",
            r"\gdef\frac{x} % \def\b{\def\cc{X}}",
            r"\providecommand{\R}{\mathbb{R}} % reals",
            r"\gdef\R{\mathbb{R}} % reals",
            r"\long\gdef\a{1} % c",
            r"\global\xdef\a{1} % c",
            // `\global` and `\long` in front of a command KaTeX has: its safe point
            // carries into the `\def` or `\let`, and the note after it is hidden
            r"\global\def\a{1} % c",
            r"\long\let\a\b % c",
            "\\providecommand{\\f}[2]{#1#2}\n% note\n",
            "\\gdef\\a{1}\n\\def\\b{2} % note",
        ] {
            assert_eq!(defines_in(Engine::MathJax, tex), (true, true), "{tex:?}");
            assert_eq!(defines_in(Engine::Katex, tex), (true, false), "{tex:?}");
        }
        // without a note too: opaque under MathJax, followed by KaTeX
        for tex in [
            r"\gdef\frac{x}",
            r"\providecommand{\R}{\mathbb{R}}",
            r"\edef\a{b}",
            "\\providecommand{\\f}[2]{#1#2}\n",
            r"\global\def\a{1}",
            r"\long\let\a\b",
            r"\global",
            r"\long",
        ] {
            assert_eq!(defines_in(Engine::MathJax, tex), (true, true), "{tex:?}");
            assert_eq!(defines_in(Engine::Katex, tex), (true, false), "{tex:?}");
        }
        // and with a definition after them
        for tex in [
            r"\edef\a{b}\xdef\c{d}",
            "\\providecommand{\\f}[2]{#1#2}\n\\def\\g{1}\n",
            "\\gdef\\R{\\mathbb{R}}\n\\gdef\\N{\\mathbb{N}}",
        ] {
            assert_eq!(defines_in(Engine::MathJax, tex), (true, true), "{tex:?}");
            assert_eq!(defines_in(Engine::Katex, tex), (true, false), "{tex:?}");
        }
        // the commands MathJax has are followed, a note after them included
        for tex in [
            r"\def\frac{x} % \def\b{X}",
            r"\renewcommand\frac{x} % \def\b{X}",
            r"\renewcommand{\a}\hat % \def\b{X}",
            r"\newcommand{\R}{\mathbb{R}} % reals",
            r"\DeclareMathOperator{\tr}{tr} % trace",
        ] {
            assert_eq!(defines(tex), (true, false), "{tex:?}");
        }
    }

    /// The walk models the definition forms and the lexing both engines share
    /// and that it reproduces exactly. A definition that holds anything else
    /// is opaque whatever either engine would make of it: a combining mark
    /// of the five combining blocks (U+0300 to U+036F, U+1AB0 to U+1AFF,
    /// U+1DC0 to U+1DFF, U+20D0 to U+20FF, U+FE20 to U+FE2F), white space
    /// beyond space, tab, newline and carriage return or any other control
    /// character, a non-ASCII control symbol as a name or in the parameter
    /// text of a `\def`, an `@` control sequence anywhere, and under MathJax
    /// the six commands it lacks. Ordinary non-ASCII text in a body or a
    /// target, and anything in a comment at a safe point, is inside the model
    /// and stays followed.
    #[test]
    fn input_outside_the_model_is_opaque() {
        const MARKS: [char; 12] = [
            '\u{300}', '\u{301}', '\u{36f}', '\u{1ab0}', '\u{1aff}', '\u{1dc0}', '\u{1dff}',
            '\u{20d0}', '\u{20d7}', '\u{20ff}', '\u{fe20}', '\u{fe2f}',
        ];
        const SPACES: [char; 14] = [
            '\u{b}', '\u{c}', '\u{1}', '\u{1f}', '\u{a0}', '\u{1680}', '\u{2000}', '\u{200a}',
            '\u{2028}', '\u{2029}', '\u{202f}', '\u{205f}', '\u{3000}', '\u{feff}',
        ];
        // (`<c>` is where the mark or the character goes)
        const WITH_MARK: [&str; 8] = [
            r"\newcommand\a{e<c>}",
            r"\newcommand{\a<c>}{x}",
            r"\def\a#1<c>{x}",
            r"\let\a=x<c>",
            r"\def\a{x}<c>",
            r"\newcommand\a[1][e<c>]{x}",
            r"\DeclareMathOperator{\op}{e<c>}",
            r"\global<c>\def\a{x}",
        ];
        const WITH_SPACE: [&str; 6] = [
            r"\newcommand\a<c>{x}",
            r"\newcommand\a{x<c>y}",
            r"\let\a=<c>\b",
            r"\def\a<c>#1{#1}",
            r"\DeclareMathOperator<c>{\op}{x}",
            r"\global<c>\def\a{x}",
        ];
        const NAMES: [&str; 11] = [
            "\\newcommand\\\u{e9}{x}",
            "\\newcommand{\\\u{3b1}}{x}",
            "\\renewcommand{\\\u{2115}}{x}",
            "\\def\\\u{e9}{x}",
            "\\let\\\u{e9}\\relax",
            "\\DeclareMathOperator{\\\u{e9}}{x}",
            "\\def\\a#1\u{e9}{#1}",
            "\\def\\a \u{3b1}{x}",
            "\\def\\a\\\u{e9}{x}",
            "\\newcommand\\\u{e9}\\hat % \\def\\b{X}",
            "\\let\\\u{20ac}\\hat % \\def\\b{X}",
        ];
        const AT: [&str; 11] = [
            r"\newcommand\a@b{x}",
            r"\def\a@b{x}",
            r"\let\a@b\relax",
            r"\newcommand\@{x}",
            r"\newcommand\@ \hat",
            r"\let\@\relax",
            r"\def\@#1{#1}",
            r"\newcommand\a{\b@c}",
            r"\newcommand\a\@ab",
            r"\let\a\@ab",
            r"\def\a#1\@{#1}",
        ];
        // MathJax 3 has none of these: opaque there, followed by KaTeX
        const LACKED: [&str; 8] = [
            r"\providecommand{\f}{x}",
            r"\providecommand{\R}{\mathbb{R}} % reals",
            r"\gdef\g{x}",
            r"\edef\h{y}",
            r"\xdef\i#1{#1}",
            r"\global\def\e{x}",
            r"\long\def\l#1{#1}",
            r"\global\let\a\b",
        ];
        // ordinary content: followed under both engines
        let controls: [String; 13] = [
            "\\newcommand{\\N}{\u{2115}}".to_string(),
            "\\newcommand{\\F}{\u{1d53d}}".to_string(),
            "\\newcommand{\\cafe}{\\text{caf\u{e9}}}".to_string(),
            "\\def\\eps{\u{3b5}}".to_string(),
            r"\let\phi\varphi".to_string(),
            "\\let\\a=\u{e9}".to_string(),
            r"\DeclareMathOperator{\argmax}{arg\,max}".to_string(),
            "\\newcommand{\\R}{\\mathbb{R}} % les r\u{e9}els\u{a0}: e\u{301}".to_string(),
            "\\def\\a{x}\n% e\u{301}\n".to_string(),
            "\\newcommand\\a{x}\u{a0}y".to_string(),
            "\\newcommand\\a{x}\r\n\\newcommand\\b{y}".to_string(),
            r"\newcommand\:\hat % \def\b{X}".to_string(),
            r"\def\;{x}".to_string(),
        ];

        // (kind, tex, KaTeX, MathJax), the last two as (affecting, opaque)
        type State = (bool, bool);
        let mut rows: Vec<(&str, String, State, State)> = Vec::new();
        let opaque = (true, true);
        for m in MARKS {
            for shape in WITH_MARK {
                let tex = shape.replace("<c>", &m.to_string());
                rows.push(("mark", tex, opaque, opaque));
            }
        }
        for c in SPACES {
            for shape in WITH_SPACE {
                let tex = shape.replace("<c>", &c.to_string());
                rows.push(("space", tex, opaque, opaque));
            }
        }
        for tex in NAMES {
            rows.push(("name", tex.to_string(), opaque, opaque));
        }
        for tex in AT {
            rows.push(("at", tex.to_string(), opaque, opaque));
        }
        for tex in LACKED {
            rows.push(("mathjax", tex.to_string(), (true, false), opaque));
        }
        for tex in &controls {
            rows.push(("control", tex.clone(), (true, false), (true, false)));
        }
        let mut red: Vec<(&str, String)> = Vec::new();
        for (kind, tex, katex, mathjax) in &rows {
            for (engine, want) in [(Engine::Katex, katex), (Engine::MathJax, mathjax)] {
                let got = defines_in(engine, tex);
                if got != *want {
                    red.push((kind, format!("{engine:?} {tex:?}: {got:?}, want {want:?}")));
                }
            }
        }
        let mut per_kind = String::new();
        for kind in ["mark", "space", "name", "at", "mathjax", "control"] {
            let n = red.iter().filter(|(k, _)| *k == kind).count();
            let total = rows.iter().filter(|(k, ..)| *k == kind).count() * 2;
            per_kind.push_str(&format!("{kind}: {n} of {total} engine rows wrong\n"));
        }
        assert!(
            red.is_empty(),
            "{} rows wrong\n{per_kind}{}",
            red.len(),
            red.iter()
                .map(|(_, r)| r.as_str())
                .collect::<Vec<_>>()
                .join("\n")
        );
    }

    /// Whether `tex` holds a `\unicode` word with something other than `{` right after it (after
    /// JavaScript white space): the command may read a font there. Found from the text alone,
    /// without the scan's tokens; a `\\` pair is not a word, and `\unicodex` is another word.
    fn unicode_may_read_a_font(tex: &str) -> bool {
        let mut from = 0;
        while let Some(p) = tex[from..].find("\\unicode") {
            let start = from + p;
            from = start + 1;
            let escaped = tex[..start]
                .bytes()
                .rev()
                .take_while(|&b| b == b'\\')
                .count()
                % 2
                == 1;
            let rest = &tex[start + "\\unicode".len()..];
            if escaped || rest.starts_with(|c: char| c.is_ascii_alphabetic()) {
                continue;
            }
            if at(rest.as_bytes(), ws_run(rest.as_bytes(), 0)) != b'{' {
                return true;
            }
        }
        false
    }

    /// Random token soup: nothing panics, and the decisions stay consistent.
    #[test]
    fn random_soup_keeps_its_invariants() {
        const PIECES: [&str; 50] = [
            "\\newcommand",
            "\\renewcommand",
            "\\providecommand",
            "\\verb",
            "|",
            "\\def",
            "\\let",
            "\\global",
            "\\DeclareMathOperator",
            "\\csname",
            "\\R",
            "\\argmax",
            "\\a",
            "\\\\",
            "\\%",
            "\\",
            "{",
            "}",
            "[",
            "]",
            "[1]",
            "#1",
            "=",
            "*",
            "@",
            "%",
            "%c\n",
            " ",
            "\n",
            "\t",
            "\u{a0}",
            "\u{3000}",
            "\u{2028}",
            "\u{85}",
            "\u{e9}",
            "\u{1F600}",
            "x",
            "1",
            "\\newcommand{\\R}",
            "\\newcommand\\N",
            "\\def\\a",
            "\\let\\a\\b",
            "\\x@",
            "\\url",
            "\\href",
            "\\unicode",
            "{ ",
            "\\includegraphics",
            "\\verb\n",
            "\\verb\r",
        ];
        let mut state = 0x9e37_79b9_7f4a_7c15u64;
        let mut rand = move |n: usize| {
            state ^= state << 13;
            state ^= state >> 7;
            state ^= state << 17;
            (state % n as u64) as usize
        };
        for _ in 0..20_000 {
            let tex: String = (0..1 + rand(12))
                .map(|_| PIECES[rand(PIECES.len())])
                .collect();
            let d = analyze(&tex, Engine::Katex);
            assert!(
                d.affecting || !d.opaque,
                "opaque but not affecting: {tex:?}"
            );
            // two passes over one `defined` set: the second finds nothing left to rewrite
            let mut defined = HashSet::new();
            let once = katex_newcommand(&tex, &mut defined);
            // `re` is inserted before `newcommand` and `providecommand` becomes `renewcommand`: two
            // bytes each way
            assert!((once.len().abs_diff(tex.len())) & 1 == 0, "{tex:?}");
            assert_eq!(katex_newcommand(&once, &mut defined), once, "{tex:?}");
            // with every KaTeX-only name taken nothing is rewritten at all
            let mut taken: HashSet<String> = KATEX_ONLY.iter().map(|n| n.to_string()).collect();
            assert_eq!(katex_newcommand(&tex, &mut taken), tex, "{tex:?}");
            // the scope's decisions agree with the analysis, and an opaque scope stays opaque
            let mut scope = MacroScope::new(Engine::Katex);
            let r = scope.next(&tex);
            // the scan sees every control word the rule acts on, so a math it rewrote is one the
            // scan has already counted: the scan alone decides what is affecting
            if r.tex != tex {
                assert!(d.affecting, "rewritten but not affecting: {tex:?}");
            }
            assert_eq!(r.affecting, d.affecting, "{tex:?}");
            assert_eq!(scope.is_opaque(), d.opaque, "{tex:?}");
            if scope.is_opaque() {
                assert!(scope.next("x").affecting && scope.is_opaque(), "{tex:?}");
            }
            // MathJax only is opaque more often (the commands it does not have are outside the
            // model), so the same maths are affecting and at least the same ones opaque; nothing
            // is rewritten
            let mj = analyze(&tex, Engine::MathJax);
            assert!(
                mj.affecting || !mj.opaque,
                "MathJax: opaque but not affecting: {tex:?}"
            );
            // (a `\unicode` that may read a font is the one thing only MathJax counts)
            if tex.contains("\\unicode") {
                assert!(mj.affecting || !d.affecting, "{tex:?}");
            } else {
                assert_eq!(mj.affecting, d.affecting, "{tex:?}");
            }
            assert!(mj.opaque || !d.opaque, "{tex:?}");
            // MathJax: a `\unicode` that may read a font is state (a `%` can hide it, so those
            // texts are left out)
            if !tex.contains('%') && unicode_may_read_a_font(&tex) {
                assert!(
                    mj.affecting,
                    "MathJax: a `\\unicode` may read a font: {tex:?}"
                );
            }
            let mut scope = MacroScope::new(Engine::MathJax);
            let r = scope.next(&tex);
            assert_eq!(
                (r.affecting, scope.is_opaque()),
                (mj.affecting, mj.opaque),
                "{tex:?}"
            );
            assert_eq!(r.tex, tex);
        }
    }

    #[test]
    fn unicode_after_a_backslash_does_not_panic() {
        for tex in [
            "\\\u{e9}",
            "\\",
            "\\def\\\u{1F600}{x}",
            "\\newcommand{\\\u{e9}}{\u{e9}}",
        ] {
            let _ = analyze(tex, Engine::Katex);
            let _ = analyze(tex, Engine::MathJax);
        }
        let mut defined = HashSet::new();
        for tex in [
            "\\newcommand\u{e9}",
            "\\newcommand\u{a0}\\\u{e9}",
            "\u{e9}\\newcommand\u{3000}{\u{3000}\\R}",
        ] {
            let _ = katex_newcommand(tex, &mut defined);
        }
        // (an ideographic space is not a blank to KaTeX: it is the token after `\newcommand`)
        assert_eq!(
            katex_newcommand(
                "\u{e9}\\newcommand\u{3000}{\u{3000}\\R}x",
                &mut HashSet::new()
            ),
            "\u{e9}\\newcommand\u{3000}{\u{3000}\\R}x"
        );
        assert_eq!(
            katex_newcommand("\u{e9}\\newcommand \\R\u{3000}x", &mut HashSet::new()),
            "\u{e9}\\renewcommand \\R\u{3000}x"
        );
    }
}
