// The KaTeX \newcommand rule the Rust grammar applies (deviation D5), written the way KaTeX reads its input: a sticky
// regular expression that lexes comments, \verb text, control words and control symbols one token at a time. It is
// the oracle the Rust rule (core/native/src/mathgrammar/macros.rs) is compared with, and it shares nothing with it
// but the list of names in katex_only.txt.
//
// KaTeX refuses `\newcommand` of a name it predefines ("attempting to redefine") and `\renewcommand` of a name it does
// not know. LaTeX accepts the first for every name it has not defined itself, so the first definition of a name in
// katex_only.txt (a control word KaTeX predefines and LaTeX with amsmath and amssymb does not) is passed on as
// \renewcommand, and so is the first \providecommand of such a name, which KaTeX would skip.
//
// The reference renderer's rule (katex_macros.mjs, still here verbatim) differs in four ways, all of them wrong
// output for a legal document:
//   - its ten names include \C and \Q, which KaTeX does not predefine ($\newcommand{\Q}{\mathbb{Q}}$ became a KaTeX
//     error), and it lacks the other 236 (\argmax, \bm, \set, \ket, ...);
//   - it matches the text of a comment: `% \newcommand{\R}{1}` above the real definition used the name up;
//   - it matches after a line break `\\newcommand` (the letters of `newcommand` are text there);
//   - it passes \providecommand on, so `\providecommand{\R}{\mathbf{R}}` drew KaTeX's own \R.
// What is not changed: the name is the letters after the backslash (`@` is a letter, as in KaTeX), `\newcommand*` and
// a number or default argument are not looked at, and one `defined` set serves a whole document. The parts may be
// separated by KaTeX's blanks (space, tab, line feed, carriage return) and by comments; the reference's \s also took
// every other white space of JavaScript, a no-break space among them, which KaTeX reads as the token after
// \newcommand (the name of the macro), so there the definition is not about the name that follows.
//
// Three more things are read as KaTeX reads them (the reference's expression read none of them):
//   - the address of \url, \href and \includegraphics: KaTeX reads that argument with % an ordinary character, so a
//     % there starts no comment (`\url{a%20b} \newcommand{\R}{1}` defines \R) and a definition inside the address is
//     text. A group runs to its matching brace (a backslash takes the next character, a \verb token is one token) and
//     one that is never closed ends the formula in KaTeX, so nothing after it is read; without a brace the argument
//     is one token, except that a `}` where the argument starts (blanks before it allowed) ends it: with no group open
//     around the command that `}` closes no group, KaTeX reports "Extra }" and the formula ends there too; with one
//     open it closes that group and the scan reads on. KaTeX parses no command in a definition body, a braced name,
//     after \let or in a macro's argument, so there the `}` is an ordinary one (`\newcommand{\img}{\includegraphics}`);
//     in a group KaTeX does parse, which the rule cannot tell from those, the math is an error in every engine.
//     \includegraphics first takes an optional argument in brackets, which KaTeX lexes as usual (a % there starts a
//     comment) up to the `]` outside any group; a `}` outside its groups is read like the `}` where the argument
//     starts. KaTeX reads % as a character only where it lexes the address while it parses it; an address inside text
//     it has lexed before (the argument of another command, a macro body) had its % read as a comment already, which
//     the rule does not tell apart (a known gap, README.md), and it reads an address also after a word KaTeX takes as
//     one token, wherever the word stands, unless the next token is a `}` that closes an open group (a second known
//     gap there). The rule follows a KaTeX error only in this scan, where KaTeX's reading of the argument fails and it
//     reads nothing after: an unclosed group and, with no group open, a `}` in the brackets or where the argument
//     starts. Everywhere else a math is read to its end, as LaTeX reads on after reporting an error (a `}` after a
//     whole address, `\url{}}`, is read on; the math is an error in every engine either way);
//   - a braced name is exactly one token: after the brace only comments may come before the control word, and after
//     it blanks and comments before the closing brace (a blank after the brace is a token of its own, and so is
//     another word or character, so `\newcommand{ \R}{1}` and `\newcommand{\R x}{1}` are errors in KaTeX and name
//     nothing);
//   - a \verb token where the name should be is the name, and claims nothing: `\newcommand\verb*!\newcommand\argmax!{x}`
//     defines no \argmax.

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));

// katex_only.txt: comment lines, then one name per line in byte order. A name that is not alphabetic or out of order is refused.
export function parseNames(text) {
  const list = text.split('\n').filter(l => l && !l.startsWith('#'));
  for (let i = 0; i < list.length; i++) {
    if (!/^[A-Za-z]+$/.test(list[i])) throw new Error(`katex_only.txt: "${list[i]}" is not a name`);
    if (i > 0 && !(list[i - 1] < list[i])) throw new Error(`katex_only.txt: "${list[i]}" is not after "${list[i - 1]}"`);
  }
  return list;
}

let cached = null;
export function katexOnly() {
  if (!cached) cached = new Set(parseNames(fs.readFileSync(path.join(HERE, 'katex_only.txt'), 'utf8')));
  return cached;
}

// KaTeX's lexer, reduced to what the rule needs (Lexer.js: tokenRegexString): a comment runs to and includes the line
// feed, \verb text is read before a control word, a control word is letters and @, a control symbol is a backslash
// and one character. `.` does not match a line terminator, as in KaTeX, so a \verb whose delimiter is a line
// terminator ends at the next line terminator when that is the same one (`\verb<LF>abc<LF>` is the text `abc`) and
// is no \verb token when another one comes first.
const VERB_TEXT = String.raw`\\verb\*(?<d1>[^]).*?\k<d1>|\\verb(?<d2>[^*a-zA-Z]).*?\k<d2>`;
const LEX = new RegExp(String.raw`(?<comment>%[^\n]*\n?)|(?<verb>${VERB_TEXT})|(?<word>\\[a-zA-Z@]+)|(?<other>\\[^]|[^])`, 'y');
// The same tokens with % an ordinary character, which is how KaTeX lexes the argument of \url and \href
// (Parser.parseUrlGroup sets the category code of % to 13 while it reads it).
const LEX_URL = new RegExp(String.raw`(?<verb>${VERB_TEXT})|(?<word>\\[a-zA-Z@]+)|(?<other>\\[^]|[^])`, 'y');
const VERB = new RegExp(VERB_TEXT, 'y');
const BLANK = /(?:[ \r\n\t]+|%[^\n]*\n?)*/y;
const SPACE = /[ \r\n\t]*/y;
const COMMENTS = /(?:%[^\n]*\n?)*/y;
const NAME = /[A-Za-z@]+/y;

function skipWith(re, tex, pos) {
  re.lastIndex = pos;
  re.exec(tex);
  return re.lastIndex;
}

function skipBlank(tex, pos) {
  return skipWith(BLANK, tex, pos);
}

// What a `}` the address scan meets means, at pos: `open` is the number of groups open around the command. At 0 it
// closes no group, KaTeX reports "Extra }" and the formula ends there: the end of the text. Otherwise it closes one
// of them and the scan stops before it, for the main scan to read.
function closingBrace(tex, pos, open) {
  return open === 0 ? tex.length : pos;
}

// The end of the argument of \url or \href whose control word ends at pos, with `open` groups open around it: KaTeX
// lexes the word together with the blanks after it, reads the argument with % an ordinary character, and takes either
// one token or a group up to its matching brace (a backslash takes the next character, so `\}` closes nothing; a
// \verb token is one token). A group that is never closed is an error in KaTeX, the formula ends there: the end of
// the text. A `}` where the argument starts goes to closingBrace; a `}` after a whole address is read on, as LaTeX
// reads on after an error, and the control symbol `\}` is the one token.
function urlArgumentEnd(tex, pos, open) {
  pos = skipWith(SPACE, tex, pos);
  if (pos >= tex.length) return pos;
  LEX_URL.lastIndex = pos;
  const first = LEX_URL.exec(tex);
  if (first.groups.other === '}') return closingBrace(tex, pos, open);
  pos = LEX_URL.lastIndex;
  if (first.groups.other !== '{') return pos;
  let depth = 1;
  while (depth > 0 && pos < tex.length) {
    LEX_URL.lastIndex = pos;
    const t = LEX_URL.exec(tex);
    pos = LEX_URL.lastIndex;
    if (t.groups.other === '{') depth++;
    else if (t.groups.other === '}') depth--;
  }
  return pos;
}

// The end of the arguments of \includegraphics whose control word ends at pos. KaTeX looks for its optional argument
// with the usual lexer, so the blanks and comments before it are nothing; a `[` starts it, and it runs to the first
// `]` outside any group, a % in it starting a comment (the end of the text is an error: the formula ends there, and a
// `}` outside the groups of the brackets goes to closingBrace). Then comes the address, read as for \url.
function includegraphicsEnd(tex, pos, open) {
  pos = skipBlank(tex, pos);
  if (tex[pos] !== '[') return urlArgumentEnd(tex, pos, open);
  pos++;
  let depth = 0;
  while (pos < tex.length) {
    LEX.lastIndex = pos;
    const t = LEX.exec(tex);
    pos = LEX.lastIndex;
    const other = t.groups.other;
    if (other === '{') depth++;
    else if (other === '}') {
      if (depth === 0) return closingBrace(tex, t.index, open);
      depth--;
    } else if (other === ']' && depth === 0) return urlArgumentEnd(tex, pos, open);
  }
  return tex.length;
}

// What the \newcommand or \providecommand whose word ends at pos is about: { name, end } for a name it claims,
// { skip } when a \verb token stands where the name should (the token is the name; nothing is claimed, the scan goes
// on after it), or null when there is no name. With a brace the name is exactly one token: only comments between
// the brace and the control word, and after the word only blanks and comments before the closing brace. `braced`
// says a brace was passed: the scan goes on before its closing brace, so that is one more open group.
function definitionName(tex, pos) {
  let q = skipBlank(tex, pos);
  const braced = tex[q] === '{';
  if (braced) q = skipWith(COMMENTS, tex, q + 1);
  VERB.lastIndex = q;
  if (VERB.exec(tex)) return { skip: VERB.lastIndex, braced };
  if (tex[q] !== '\\') return null;
  NAME.lastIndex = q + 1;
  const name = NAME.exec(tex);
  if (!name) return null;
  const end = NAME.lastIndex;
  if (braced && tex[skipWith(COMMENTS, tex, skipWith(SPACE, tex, end))] !== '}') return null;
  return { name: name[0], end, braced };
}

// The rewritten TeX; `defined` (a Set) holds the names defined so far in the document and gets every name defined here.
export function katexNewcommand(tex, defined, only = katexOnly()) {
  let out = '';
  let copied = 0;
  let pos = 0;
  // The groups open here. A definition body, a braced name and a macro's argument count like any other group: KaTeX
  // does not parse a command there, and a `}` right after one closes the group (see closingBrace).
  let open = 0;
  while (pos < tex.length) {
    LEX.lastIndex = pos;
    const m = LEX.exec(tex);
    pos = LEX.lastIndex;
    const word = m.groups.word;
    if (m.groups.other === '{') open++;
    else if (m.groups.other === '}' && open > 0) open--;
    if (word === '\\url' || word === '\\href') {
      pos = urlArgumentEnd(tex, pos, open);
      continue;
    }
    if (word === '\\includegraphics') {
      pos = includegraphicsEnd(tex, pos, open);
      continue;
    }
    if (word !== '\\newcommand' && word !== '\\providecommand') continue;
    const found = definitionName(tex, pos);
    if (!found) continue;
    if (found.braced) open++;
    if (found.skip !== undefined) {
      pos = found.skip;
      continue;
    }
    if (!defined.has(found.name)) {
      if (only.has(found.name)) {
        out += `${tex.slice(copied, m.index + 1)}renewcommand`;
        copied = pos;
      }
      defined.add(found.name);
    }
    pos = found.end;
  }
  return copied === 0 ? tex : out + tex.slice(copied);
}

// ---- self-test: `node katex_rule.mjs --self-test` checks the rule against rows written out by hand ----

export const ROWS = [
  // [the maths of one document, what each becomes]
  [['\\newcommand{\\R}{x}', '\\newcommand{\\R}{y}'], ['\\renewcommand{\\R}{x}', '\\newcommand{\\R}{y}']],
  // names KaTeX predefines and LaTeX lacks, and names it does not predefine
  [['\\newcommand{\\argmax}{a}\\newcommand{\\bm}[1]{#1}\\newcommand{\\E}{e}'], ['\\renewcommand{\\argmax}{a}\\renewcommand{\\bm}[1]{#1}\\newcommand{\\E}{e}']],
  [['\\newcommand{\\Q}{q}\\newcommand{\\C}{c}'], ['\\newcommand{\\Q}{q}\\newcommand{\\C}{c}']],
  // names both define: LaTeX refuses them too
  [['\\newcommand{\\alpha}{a}\\newcommand{\\mathbb}{b}'], ['\\newcommand{\\alpha}{a}\\newcommand{\\mathbb}{b}']],
  // a comment is not a definition
  [['% \\newcommand{\\R}{1}\n\\newcommand{\\R}{2}'], ['% \\newcommand{\\R}{1}\n\\renewcommand{\\R}{2}']],
  [['\\newcommand{\\R}{1} % \\newcommand{\\N}{2}\n\\newcommand{\\N}{3}'], ['\\renewcommand{\\R}{1} % \\newcommand{\\N}{2}\n\\renewcommand{\\N}{3}']],
  // \providecommand of a listed name defines it the first time, then nothing
  [['\\providecommand{\\R}{1}', '\\providecommand{\\R}{2}', '\\newcommand{\\R}{3}'], ['\\renewcommand{\\R}{1}', '\\providecommand{\\R}{2}', '\\newcommand{\\R}{3}']],
  [['\\providecommand{\\foo}{1}\\providecommand{\\alpha}{2}'], ['\\providecommand{\\foo}{1}\\providecommand{\\alpha}{2}']],
  // a control word only: a line break and the letters, an escaped percent, verbatim text
  [['a \\\\newcommand{\\R}{1}'], ['a \\\\newcommand{\\R}{1}']],
  [['a \\\\\\newcommand{\\R}{1}'], ['a \\\\\\renewcommand{\\R}{1}']],
  [['\\% \\newcommand{\\R}{1}'], ['\\% \\renewcommand{\\R}{1}']],
  [['\\verb|%|\\newcommand{\\R}{1}'], ['\\verb|%|\\renewcommand{\\R}{1}']],
  [['\\verb|\\newcommand{\\R}{1}|\\newcommand{\\R}{2}'], ['\\verb|\\newcommand{\\R}{1}|\\renewcommand{\\R}{2}']],
  [['\\verb@\\newcommand{\\R}{1}@'], ['\\verb@\\newcommand{\\R}{1}@']],
  [['\\verb|\\newcommand{\\R}{x}\n|\\newcommand{\\R}{y}'], ['\\verb|\\renewcommand{\\R}{x}\n|\\newcommand{\\R}{y}']],
  [['\\verb*a\\newcommand{\\R}{x}a\\newcommand{\\R}{y}'], ['\\verb*a\\newcommand{\\R}{x}a\\renewcommand{\\R}{y}']],
  [['\\verb1\\verb2\\verb|\\newcommand{\\R}{x}|\\newcommand{\\R}{y}'], ['\\verb1\\verb2\\verb|\\newcommand{\\R}{x}|\\renewcommand{\\R}{y}']],
  // a line terminator as the delimiter: the text runs to the next line terminator when that is the same one
  [['\\verb\n\\newcommand{\\R}{1}\n', '\\newcommand{\\R}{2}'], ['\\verb\n\\newcommand{\\R}{1}\n', '\\renewcommand{\\R}{2}']],
  [['\\verb\r\\newcommand{\\R}{1}\r', '\\newcommand{\\R}{2}'], ['\\verb\r\\newcommand{\\R}{1}\r', '\\renewcommand{\\R}{2}']],
  [['\\verb*\u2028\\newcommand{\\R}{1}\u2028', '\\newcommand{\\R}{2}'], ['\\verb*\u2028\\newcommand{\\R}{1}\u2028', '\\renewcommand{\\R}{2}']],
  [['\\verb\u2029\\newcommand{\\R}{1}\u2029\\newcommand{\\N}{1}'], ['\\verb\u2029\\newcommand{\\R}{1}\u2029\\renewcommand{\\N}{1}']],
  [['\\verb\n\n\\newcommand{\\R}{x}'], ['\\verb\n\n\\renewcommand{\\R}{x}']],
  [['\\verb\nx\n\\newcommand{\\R}{x}'], ['\\verb\nx\n\\renewcommand{\\R}{x}']],
  // ... and is no \verb token (the control word \verb) when another line terminator comes first, or none
  [['\\verb\n\r\\newcommand{\\R}{1}\n'], ['\\verb\n\r\\renewcommand{\\R}{1}\n']],
  [['\\verb\r\n\\newcommand{\\R}{1}\r'], ['\\verb\r\n\\renewcommand{\\R}{1}\r']],
  [['\\verb\n\\newcommand{\\R}{1}'], ['\\verb\n\\renewcommand{\\R}{1}']],
  [['\\newcommandx{\\R}{1}\\xnewcommand{\\R}{1}\\newcommand@{\\R}{1}'], ['\\newcommandx{\\R}{1}\\xnewcommand{\\R}{1}\\newcommand@{\\R}{1}']],
  // white space and comments between the parts, an optional brace
  [['\\newcommand  \n {  \\R}{1}'], ['\\newcommand  \n {  \\R}{1}']],
  [['\\newcommand  \n {\\R}{1}'], ['\\renewcommand  \n {\\R}{1}']],
  [['\\newcommand\u00a0{\\R}{1}\\newcommand\u2003\\N{2}\\newcommand{\u00a0\\Z}{3}'], ['\\newcommand\u00a0{\\R}{1}\\newcommand\u2003\\N{2}\\newcommand{\u00a0\\Z}{3}']],
  [['\\newcommand% c\n\\R{1}'], ['\\renewcommand% c\n\\R{1}']],
  [['\\newcommand{% c\n\\R}{1}'], ['\\renewcommand{% c\n\\R}{1}']],
  [['\\newcommand\\R\\newcommand\\R'], ['\\renewcommand\\R\\newcommand\\R']],
  // no name, a star, \renewcommand, an @ in the name
  [['\\newcommand{\\}{1}\\newcommand{\\1}{2}\\newcommand*{\\R}{3}\\renewcommand{\\N}{4}'], ['\\newcommand{\\}{1}\\newcommand{\\1}{2}\\newcommand*{\\R}{3}\\renewcommand{\\N}{4}']],
  [['\\newcommand{\\R@x}{1}', '\\newcommand{\\R}{2}'], ['\\newcommand{\\R@x}{1}', '\\renewcommand{\\R}{2}']],
  // a name that merely begins like a listed one
  [['\\newcommand{\\Rx}{1}', '\\newcommand{\\R}{2}'], ['\\newcommand{\\Rx}{1}', '\\renewcommand{\\R}{2}']],
  // the address of \url and \href is read with % an ordinary character: no comment, a group to its matching brace
  [['\\url{a%20b} \\newcommand{\\R}{1}'], ['\\url{a%20b} \\renewcommand{\\R}{1}']],
  [['\\href{a%b}{t}\\newcommand{\\N}{1}'], ['\\href{a%b}{t}\\renewcommand{\\N}{1}']],
  [['\\url{\\newcommand{\\R}{1}}', '\\newcommand{\\R}{2}'], ['\\url{\\newcommand{\\R}{1}}', '\\renewcommand{\\R}{2}']],
  [['\\url %\\newcommand{\\Z}{1}'], ['\\url %\\renewcommand{\\Z}{1}']],
  [['\\href{\\newcommand{\\R}{1}}{t}', '\\newcommand{\\R}{2}'], ['\\href{\\newcommand{\\R}{1}}{t}', '\\renewcommand{\\R}{2}']],
  [['\\url{a%b \\newcommand{\\R}{1}'], ['\\url{a%b \\newcommand{\\R}{1}']],
  // an unclosed group ends the formula: nothing after it is read, in the next math either
  [['\\url{a \\newcommand{\\R}{1}', '\\newcommand{\\R}{2}'], ['\\url{a \\newcommand{\\R}{1}', '\\renewcommand{\\R}{2}']],
  // one token without a brace (a blank before it is skipped, a % is the token); a word is not \url
  [['\\url\n\t x\\newcommand{\\R}{1}'], ['\\url\n\t x\\renewcommand{\\R}{1}']],
  [['\\url\\foo \\newcommand{\\R}{1}'], ['\\url\\foo \\renewcommand{\\R}{1}']],
  [['\\url%\\newcommand{\\R}{1}'], ['\\url%\\renewcommand{\\R}{1}']],
  [['\\urlx{%\\newcommand{\\R}{1}'], ['\\urlx{%\\newcommand{\\R}{1}']],
  [['\\url@{%\\newcommand{\\R}{1}'], ['\\url@{%\\newcommand{\\R}{1}']],
  [['a \\\\url{%}\\newcommand{\\R}{1}'], ['a \\\\url{%}\\newcommand{\\R}{1}']],
  // inside the group a backslash takes the next character and a \verb token is one token
  [['\\url{\\}%}\\newcommand{\\R}{1}'], ['\\url{\\}%}\\renewcommand{\\R}{1}']],
  [['\\url{\\{%}\\newcommand{\\R}{1}'], ['\\url{\\{%}\\renewcommand{\\R}{1}']],
  [['\\url{\\{%\\newcommand{\\R}{1}'], ['\\url{\\{%\\newcommand{\\R}{1}']],
  [['\\url{\\verb|{|}\\newcommand{\\R}{1}'], ['\\url{\\verb|{|}\\renewcommand{\\R}{1}']],
  [['\\url{\\verb|{|}%\\newcommand{\\R}{1}'], ['\\url{\\verb|{|}%\\newcommand{\\R}{1}']],
  [['\\url{{a%}}\\newcommand{\\R}{1}'], ['\\url{{a%}}\\renewcommand{\\R}{1}']],
  [['\\url\\verb|x|\\newcommand{\\R}{1}'], ['\\url\\verb|x|\\renewcommand{\\R}{1}']],
  // ... a \verb token whose delimiter is a line terminator too
  [['\\url{\\verb\n}\n\\newcommand{\\R}{1}}', '\\newcommand{\\R}{2}'], ['\\url{\\verb\n}\n\\newcommand{\\R}{1}}', '\\renewcommand{\\R}{2}']],
  [['\\url\\verb\u2028\\newcommand{\\R}{1}\u2028', '\\newcommand{\\R}{2}'], ['\\url\\verb\u2028\\newcommand{\\R}{1}\u2028', '\\renewcommand{\\R}{2}']],
  // \includegraphics: the address as for \url, after an optional argument in brackets lexed as usual
  [['\\includegraphics[height=1em]{a%20b.png} \\newcommand{\\R}{\\mathbb{R}} \\R'], ['\\includegraphics[height=1em]{a%20b.png} \\renewcommand{\\R}{\\mathbb{R}} \\R']],
  [['\\includegraphics{a%}\n\\newcommand{\\R}{1}', '\\newcommand{\\R}{2}'], ['\\includegraphics{a%}\n\\renewcommand{\\R}{1}', '\\newcommand{\\R}{2}']],
  [['\\includegraphics[a%]\n]{x}\\newcommand{\\R}{1}'], ['\\includegraphics[a%]\n]{x}\\renewcommand{\\R}{1}']],
  [['\\includegraphics %c\n[x]{a%b}\\newcommand{\\R}{1}'], ['\\includegraphics %c\n[x]{a%b}\\renewcommand{\\R}{1}']],
  [['\\includegraphics%c\n{a%b}\\newcommand{\\R}{1}'], ['\\includegraphics%c\n{a%b}\\renewcommand{\\R}{1}']],
  [['\\url%c\n{a%b}\\newcommand{\\R}{1}'], ['\\url%c\n{a%b}\\newcommand{\\R}{1}']],
  [['\\includegraphics[x] %\\newcommand{\\R}{1}'], ['\\includegraphics[x] %\\renewcommand{\\R}{1}']],
  [['\\includegraphics[{]}]{a%}\\newcommand{\\R}{1}'], ['\\includegraphics[{]}]{a%}\\renewcommand{\\R}{1}']],
  [['\\includegraphics[\\verb|]|]{a%}\\newcommand{\\R}{1}'], ['\\includegraphics[\\verb|]|]{a%}\\renewcommand{\\R}{1}']],
  [['\\includegraphics[\\newcommand{\\R}{1}]{x}', '\\newcommand{\\R}{2}'], ['\\includegraphics[\\newcommand{\\R}{1}]{x}', '\\renewcommand{\\R}{2}']],
  // ... a `}` that closes no group in the brackets, with none open around them, or brackets never closed, end the formula
  [['\\includegraphics[a}]{x}\\newcommand{\\R}{1}', '\\newcommand{\\R}{2}'], ['\\includegraphics[a}]{x}\\newcommand{\\R}{1}', '\\renewcommand{\\R}{2}']],
  [['\\includegraphics[a\\newcommand{\\R}{1}', '\\newcommand{\\R}{2}'], ['\\includegraphics[a\\newcommand{\\R}{1}', '\\renewcommand{\\R}{2}']],
  [['\\includegraphicsx{%}\\newcommand{\\R}{1}'], ['\\includegraphicsx{%}\\newcommand{\\R}{1}']],
  // ... a `}` where the address starts, with no group open, closes none: KaTeX reports "Extra }" and the formula ends
  // there, blanks before it included (control: a `}` after a whole address is read on; a control symbol `\}` is the token)
  [['\\url}\\newcommand{\\R}{1}', '\\newcommand{\\R}{2}'], ['\\url}\\newcommand{\\R}{1}', '\\renewcommand{\\R}{2}']],
  [['\\href}\\newcommand{\\R}{1}', '\\newcommand{\\R}{2}'], ['\\href}\\newcommand{\\R}{1}', '\\renewcommand{\\R}{2}']],
  [['\\includegraphics}\\newcommand{\\R}{1}', '\\newcommand{\\R}{2}'], ['\\includegraphics}\\newcommand{\\R}{1}', '\\renewcommand{\\R}{2}']],
  [['\\includegraphics[x]}\\newcommand{\\R}{1}', '\\newcommand{\\R}{2}'], ['\\includegraphics[x]}\\newcommand{\\R}{1}', '\\renewcommand{\\R}{2}']],
  [['\\url \n\t}\\newcommand{\\R}{1}', '\\newcommand{\\R}{2}'], ['\\url \n\t}\\newcommand{\\R}{1}', '\\renewcommand{\\R}{2}']],
  [['\\url{}}\\newcommand{\\R}{1}', '\\newcommand{\\R}{2}'], ['\\url{}}\\renewcommand{\\R}{1}', '\\newcommand{\\R}{2}']],
  [['\\url\\}\\newcommand{\\R}{1}'], ['\\url\\}\\renewcommand{\\R}{1}']],
  // ... that holds with no group open. With one open the `}` closes it: KaTeX does not parse the command in a
  // definition body, in a braced name or after \let, and a macro's argument is a group of tokens; the scan reads on
  // and the definitions after it are rewritten and claimed
  [['\\newcommand{\\img}{\\includegraphics}\\newcommand{\\R}{\\mathbb{R}} \\R'], ['\\newcommand{\\img}{\\includegraphics}\\renewcommand{\\R}{\\mathbb{R}} \\R']],
  [['\\newcommand{\\lk}{\\url}\\newcommand{\\R}{\\mathbb{R}} \\R'], ['\\newcommand{\\lk}{\\url}\\renewcommand{\\R}{\\mathbb{R}} \\R']],
  [['\\newcommand{\\lk}{\\href}\\newcommand{\\R}{\\mathbb{R}} \\R'], ['\\newcommand{\\lk}{\\href}\\renewcommand{\\R}{\\mathbb{R}} \\R']],
  [['\\def\\lk{\\url}\\newcommand{\\R}{\\mathbb{R}} \\R'], ['\\def\\lk{\\url}\\renewcommand{\\R}{\\mathbb{R}} \\R']],
  [['\\gdef\\lk{\\href}\\newcommand{\\R}{\\mathbb{R}} \\R'], ['\\gdef\\lk{\\href}\\renewcommand{\\R}{\\mathbb{R}} \\R']],
  [['\\newcommand{\\fig}[1]{\\includegraphics[width=#1]}\\newcommand{\\R}{\\mathbb{R}} \\R'], ['\\newcommand{\\fig}[1]{\\includegraphics[width=#1]}\\renewcommand{\\R}{\\mathbb{R}} \\R']],
  [['\\renewcommand{\\url}[1]{\\texttt{#1}}\\newcommand{\\R}{\\mathbb{R}} \\R'], ['\\renewcommand{\\url}[1]{\\texttt{#1}}\\renewcommand{\\R}{\\mathbb{R}} \\R']],
  [['\\renewcommand{\\href}[2]{#2}\\newcommand{\\R}{\\mathbb{R}} \\R'], ['\\renewcommand{\\href}[2]{#2}\\renewcommand{\\R}{\\mathbb{R}} \\R']],
  [['\\renewcommand{\\includegraphics}[1]{x}\\newcommand{\\R}{\\mathbb{R}} \\R'], ['\\renewcommand{\\includegraphics}[1]{x}\\renewcommand{\\R}{\\mathbb{R}} \\R']],
  [['\\providecommand{\\url}[1]{x}\\newcommand{\\R}{\\mathbb{R}} \\R'], ['\\renewcommand{\\url}[1]{x}\\renewcommand{\\R}{\\mathbb{R}} \\R']],
  [['{\\let\\lk\\url}\\newcommand{\\R}{\\mathbb{R}} \\R'], ['{\\let\\lk\\url}\\renewcommand{\\R}{\\mathbb{R}} \\R']],
  [['\\newcommand{\\lk}{\\href}\\providecommand{\\argmax}{\\mathrm{mine}} \\argmax'], ['\\newcommand{\\lk}{\\href}\\renewcommand{\\argmax}{\\mathrm{mine}} \\argmax']],
  [['\\newcommand{\\lk}{\\url \n}\\newcommand{\\R}{\\mathbb{R}} \\R'], ['\\newcommand{\\lk}{\\url \n}\\renewcommand{\\R}{\\mathbb{R}} \\R']],
  [['\\newcommand{\\a}{{\\url}}\\newcommand{\\R}{\\mathbb{R}} \\R'], ['\\newcommand{\\a}{{\\url}}\\renewcommand{\\R}{\\mathbb{R}} \\R']],
  [['\\newcommand{\\img}{\\includegraphics}', '\\newcommand{\\R}{\\mathbb{R}}', '\\newcommand{\\R}{2}'], ['\\newcommand{\\img}{\\includegraphics}', '\\renewcommand{\\R}{\\mathbb{R}}', '\\newcommand{\\R}{2}']],
  [['\\newcommand{\\lk}[1]{#1{a}}\\lk{\\url}\\newcommand{\\R}{\\mathbb{R}} \\R'], ['\\newcommand{\\lk}[1]{#1{a}}\\lk{\\url}\\renewcommand{\\R}{\\mathbb{R}} \\R']],
  // ... the same for a `}` outside the groups of the brackets of \includegraphics, and after the brackets
  [['\\newcommand{\\fig}{\\includegraphics[width=}\\newcommand{\\R}{\\mathbb{R}} \\R'], ['\\newcommand{\\fig}{\\includegraphics[width=}\\renewcommand{\\R}{\\mathbb{R}} \\R']],
  [['\\newcommand{\\fig}{\\includegraphics[a%}\n}\\newcommand{\\R}{\\mathbb{R}} \\R'], ['\\newcommand{\\fig}{\\includegraphics[a%}\n}\\renewcommand{\\R}{\\mathbb{R}} \\R']],
  [['\\newcommand{\\fig}{\\includegraphics[{a}}\\newcommand{\\R}{\\mathbb{R}} \\R'], ['\\newcommand{\\fig}{\\includegraphics[{a}}\\renewcommand{\\R}{\\mathbb{R}} \\R']],
  [['\\newcommand{\\fig}{\\includegraphics[x]}\\newcommand{\\R}{\\mathbb{R}} \\R'], ['\\newcommand{\\fig}{\\includegraphics[x]}\\renewcommand{\\R}{\\mathbb{R}} \\R']],
  // the brace of a braced name is one more open group, whose `}` the scan reads; a bare name opens none
  [['\\newcommand{\\a}{\\newcommand{\\b}{x}\\url}\\newcommand{\\R}{\\mathbb{R}} \\R'], ['\\newcommand{\\a}{\\newcommand{\\b}{x}\\url}\\renewcommand{\\R}{\\mathbb{R}} \\R']],
  [['\\newcommand{\\a}{\\newcommand\\b{x}\\url}\\newcommand{\\R}{\\mathbb{R}} \\R'], ['\\newcommand{\\a}{\\newcommand\\b{x}\\url}\\renewcommand{\\R}{\\mathbb{R}} \\R']],
  [['\\newcommand{\\a}{\\newcommand{\\verb|x|}{1}\\url}\\newcommand{\\R}{\\mathbb{R}} \\R'], ['\\newcommand{\\a}{\\newcommand{\\verb|x|}{1}\\url}\\renewcommand{\\R}{\\mathbb{R}} \\R']],
  [['\\newcommand{\\a}{\\providecommand{\\b}{x}\\href}\\newcommand{\\R}{\\mathbb{R}} \\R'], ['\\newcommand{\\a}{\\providecommand{\\b}{x}\\href}\\renewcommand{\\R}{\\mathbb{R}} \\R']],
  [['{\\newcommand{\\b}{x}\\let\\lk\\url}\\newcommand{\\R}{\\mathbb{R}} \\R'], ['{\\newcommand{\\b}{x}\\let\\lk\\url}\\renewcommand{\\R}{\\mathbb{R}} \\R']],
  // what is no brace to KaTeX is none to the count: a comment, \verb text, a control symbol; an address or brackets
  // leave the count as it was
  [['\\newcommand{\\a}{% }\n\\url}\\newcommand{\\R}{\\mathbb{R}} \\R'], ['\\newcommand{\\a}{% }\n\\url}\\renewcommand{\\R}{\\mathbb{R}} \\R']],
  [['\\newcommand{\\a}{\\verb|}|\\url}\\newcommand{\\R}{\\mathbb{R}} \\R'], ['\\newcommand{\\a}{\\verb|}|\\url}\\renewcommand{\\R}{\\mathbb{R}} \\R']],
  [['\\newcommand{\\a}{\\}\\url}\\newcommand{\\R}{\\mathbb{R}} \\R'], ['\\newcommand{\\a}{\\}\\url}\\renewcommand{\\R}{\\mathbb{R}} \\R']],
  [['\\newcommand{\\a}{\\url{}\\url}\\newcommand{\\R}{\\mathbb{R}} \\R'], ['\\newcommand{\\a}{\\url{}\\url}\\renewcommand{\\R}{\\mathbb{R}} \\R']],
  [['\\newcommand{\\a}{\\includegraphics[{}]{x}\\url}\\newcommand{\\R}{\\mathbb{R}} \\R'], ['\\newcommand{\\a}{\\includegraphics[{}]{x}\\url}\\renewcommand{\\R}{\\mathbb{R}} \\R']],
  // no group open: the `}` closes none, the formula ends there. Definitions, whole groups, addresses and stray `}`
  // before it leave the count at 0, with a floor of 0
  [['\\url}\\newcommand{\\R}{\\mathbb{R}}', '\\newcommand{\\R}{2}'], ['\\url}\\newcommand{\\R}{\\mathbb{R}}', '\\renewcommand{\\R}{2}']],
  [['\\newcommand{\\lk}{\\url}\\url}\\newcommand{\\R}{\\mathbb{R}}', '\\newcommand{\\R}{2}'], ['\\newcommand{\\lk}{\\url}\\url}\\newcommand{\\R}{\\mathbb{R}}', '\\renewcommand{\\R}{2}']],
  [['\\newcommand{\\b}{x}\\url}\\newcommand{\\R}{\\mathbb{R}}', '\\newcommand{\\R}{2}'], ['\\newcommand{\\b}{x}\\url}\\newcommand{\\R}{\\mathbb{R}}', '\\renewcommand{\\R}{2}']],
  [['\\newcommand\\b{x}\\url}\\newcommand{\\R}{\\mathbb{R}}', '\\newcommand{\\R}{2}'], ['\\newcommand\\b{x}\\url}\\newcommand{\\R}{\\mathbb{R}}', '\\renewcommand{\\R}{2}']],
  [['\\newcommand{ \\b}{x}\\url}\\newcommand{\\R}{\\mathbb{R}}', '\\newcommand{\\R}{2}'], ['\\newcommand{ \\b}{x}\\url}\\newcommand{\\R}{\\mathbb{R}}', '\\renewcommand{\\R}{2}']],
  [['\\newcommand{\\verb|x|}{1}\\url}\\newcommand{\\R}{\\mathbb{R}}', '\\newcommand{\\R}{2}'], ['\\newcommand{\\verb|x|}{1}\\url}\\newcommand{\\R}{\\mathbb{R}}', '\\renewcommand{\\R}{2}']],
  [['\\newcommand\\verb|x|{1}\\url}\\newcommand{\\R}{\\mathbb{R}}', '\\newcommand{\\R}{2}'], ['\\newcommand\\verb|x|{1}\\url}\\newcommand{\\R}{\\mathbb{R}}', '\\renewcommand{\\R}{2}']],
  [['{\\url{a}}\\url}\\newcommand{\\R}{\\mathbb{R}}', '\\newcommand{\\R}{2}'], ['{\\url{a}}\\url}\\newcommand{\\R}{\\mathbb{R}}', '\\renewcommand{\\R}{2}']],
  [['{a}\\includegraphics[x]}\\newcommand{\\R}{\\mathbb{R}}', '\\newcommand{\\R}{2}'], ['{a}\\includegraphics[x]}\\newcommand{\\R}{\\mathbb{R}}', '\\renewcommand{\\R}{2}']],
  [['{a}\\includegraphics[a}\\newcommand{\\R}{\\mathbb{R}}', '\\newcommand{\\R}{2}'], ['{a}\\includegraphics[a}\\newcommand{\\R}{\\mathbb{R}}', '\\renewcommand{\\R}{2}']],
  [['\\{\\url}\\newcommand{\\R}{\\mathbb{R}}', '\\newcommand{\\R}{2}'], ['\\{\\url}\\newcommand{\\R}{\\mathbb{R}}', '\\renewcommand{\\R}{2}']],
  [['\\verb|{|\\url}\\newcommand{\\R}{\\mathbb{R}}', '\\newcommand{\\R}{2}'], ['\\verb|{|\\url}\\newcommand{\\R}{\\mathbb{R}}', '\\renewcommand{\\R}{2}']],
  [['%{\n\\url}\\newcommand{\\R}{\\mathbb{R}}', '\\newcommand{\\R}{2}'], ['%{\n\\url}\\newcommand{\\R}{\\mathbb{R}}', '\\renewcommand{\\R}{2}']],
  [['\\url{a}\\url}\\newcommand{\\R}{\\mathbb{R}}', '\\newcommand{\\R}{2}'], ['\\url{a}\\url}\\newcommand{\\R}{\\mathbb{R}}', '\\renewcommand{\\R}{2}']],
  [['x}\\url}\\newcommand{\\R}{\\mathbb{R}}', '\\newcommand{\\R}{2}'], ['x}\\url}\\newcommand{\\R}{\\mathbb{R}}', '\\renewcommand{\\R}{2}']],
  [['x}}{a}\\url}\\newcommand{\\R}{\\mathbb{R}}', '\\newcommand{\\R}{2}'], ['x}}{a}\\url}\\newcommand{\\R}{\\mathbb{R}}', '\\renewcommand{\\R}{2}']],
  // a group KaTeX parses and fails in is read on all the same, since the rule cannot tell it from a macro's argument:
  // the first math is an error in every engine, and the second stays \newcommand
  [['{\\url}\\newcommand{\\R}{\\mathbb{R}}', '\\newcommand{\\R}{2}'], ['{\\url}\\renewcommand{\\R}{\\mathbb{R}}', '\\newcommand{\\R}{2}']],
  [['\\text{\\url}\\newcommand{\\R}{\\mathbb{R}}', '\\newcommand{\\R}{2}'], ['\\text{\\url}\\renewcommand{\\R}{\\mathbb{R}}', '\\newcommand{\\R}{2}']],
  [['\\frac{\\url}{x}\\newcommand{\\R}{\\mathbb{R}}', '\\newcommand{\\R}{2}'], ['\\frac{\\url}{x}\\renewcommand{\\R}{\\mathbb{R}}', '\\newcommand{\\R}{2}']],
  [['{\\includegraphics[a}\\newcommand{\\R}{\\mathbb{R}}', '\\newcommand{\\R}{2}'], ['{\\includegraphics[a}\\renewcommand{\\R}{\\mathbb{R}}', '\\newcommand{\\R}{2}']],
  // a name in braces is exactly one token
  [['\\newcommand{ \\R}{1}', '\\newcommand{\\R}{2}'], ['\\newcommand{ \\R}{1}', '\\renewcommand{\\R}{2}']],
  [['\\newcommand{\\R x}{1}', '\\newcommand{\\R}{2}'], ['\\newcommand{\\R x}{1}', '\\renewcommand{\\R}{2}']],
  [['\\newcommand{\\R2}{1}', '\\newcommand{\\R}{2}'], ['\\newcommand{\\R2}{1}', '\\renewcommand{\\R}{2}']],
  [['\\newcommand{\\R }{1}'], ['\\renewcommand{\\R }{1}']],
  [['\\newcommand{\\R%c\n}{1}'], ['\\renewcommand{\\R%c\n}{1}']],
  [['\\newcommand{\\R %c\n}{1}'], ['\\renewcommand{\\R %c\n}{1}']],
  [['\\newcommand{\\R %c\n }{1}', '\\newcommand{\\R}{2}'], ['\\newcommand{\\R %c\n }{1}', '\\renewcommand{\\R}{2}']],
  [['\\newcommand{%a\n%b\n\\R%c\n%d\n}{1}'], ['\\renewcommand{%a\n%b\n\\R%c\n%d\n}{1}']],
  [['\\newcommand{%a\n \\R}{1}', '\\newcommand{\\R}{2}'], ['\\newcommand{%a\n \\R}{1}', '\\renewcommand{\\R}{2}']],
  [['\\newcommand{\\R', '\\newcommand{\\R}{2}'], ['\\newcommand{\\R', '\\renewcommand{\\R}{2}']],
  [['\\newcommand{\\R{}}{1}', '\\newcommand{\\R}{2}'], ['\\newcommand{\\R{}}{1}', '\\renewcommand{\\R}{2}']],
  // a \verb token where the name should be is the name and claims nothing, braced or not
  [['\\newcommand\\verb*!\\newcommand\\argmax!{x}', '\\newcommand{\\argmax}{y}'], ['\\newcommand\\verb*!\\newcommand\\argmax!{x}', '\\renewcommand{\\argmax}{y}']],
  [['\\newcommand{\\verb|\\newcommand\\argmax|}{x}', '\\newcommand{\\argmax}{y}'], ['\\newcommand{\\verb|\\newcommand\\argmax|}{x}', '\\renewcommand{\\argmax}{y}']],
  [['\\newcommand\\verbx{1}\\newcommand\\verb|x{2}', '\\newcommand{\\R}{y}'], ['\\newcommand\\verbx{1}\\newcommand\\verb|x{2}', '\\renewcommand{\\R}{y}']],
  // ... with a line terminator as its delimiter, and the word \verb when another line terminator comes first
  [['\\newcommand\\verb\n\\newcommand\\argmax\n{x}', '\\newcommand{\\argmax}{y}'], ['\\newcommand\\verb\n\\newcommand\\argmax\n{x}', '\\renewcommand{\\argmax}{y}']],
  [['\\newcommand{\\verb\r\\newcommand\\R\r}{x}', '\\newcommand{\\R}{y}'], ['\\newcommand{\\verb\r\\newcommand\\R\r}{x}', '\\renewcommand{\\R}{y}']],
  [['\\newcommand\\verb\n\r\\newcommand\\R\n{1}'], ['\\newcommand\\verb\n\r\\renewcommand\\R\n{1}']],
];

function selfTest() {
  const bad = [];
  const only = katexOnly();
  for (const n of ['R', 'N', 'Z', 'Reals', 'reals', 'natnums', 'Complex', 'cnums', 'argmax', 'argmin', 'bm', 'set', 'ket', 'bra', 'Tau']) {
    if (!only.has(n)) bad.push(`${n} is not in katex_only.txt`);
  }
  for (const n of ['C', 'Q', 'E', 'alpha', 'mathbb', 'frac', 'operatorname']) {
    if (only.has(n)) bad.push(`${n} is in katex_only.txt`);
  }
  for (const [docs, want] of ROWS) {
    const defined = new Set();
    const got = docs.map(t => katexNewcommand(t, defined));
    if (JSON.stringify(got) !== JSON.stringify(want)) bad.push(`${JSON.stringify(docs)}: got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`);
  }
  return bad;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  if (process.argv[2] !== '--self-test') {
    process.stderr.write('usage: node katex_rule.mjs --self-test\n');
    process.exit(2);
  }
  const bad = selfTest();
  for (const b of bad) process.stderr.write(`FAIL ${b}\n`);
  process.stdout.write(bad.length ? `${bad.length} KATEX RULE ROWS FAILED\n` : `ALL ${ROWS.length} KATEX RULE ROWS PASSED\n`);
  process.exit(bad.length ? 1 : 0);
}
