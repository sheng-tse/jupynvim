// Generates the case files the Rust math grammar is compared against, from the reference grammar in this folder.
//
//   node gen_cases.mjs battery <cases.json>      one document per [name, source] pair, in file order
//   node gen_cases.mjs fixtures <dir>            the markdown fixtures: whole .md files, each notebook cell, each notebook
//   node gen_cases.mjs fuzz <seed> <count>       <count> random documents, deterministic for a seed
//   node gen_cases.mjs ams <seed> <count>        <count> random documents dense in numbered environments, tags, skip words,
//                                                labels and references (several sources, forward references, repeated keys),
//                                                and in what the engines do not see (deviation D9: comments, rows commented
//                                                out, escaped commands, hidden ends) or read with a row break (deviation
//                                                D10: a spacing argument, a star, a bracket on the next line, the row
//                                                right after the break), and in take-outs that could join what they
//                                                stand between (deviation D11: a control word and a letter, a row
//                                                break and a bracket or star)
//   node gen_cases.mjs envs <seed> <count>       <count> random documents of bare \begin{..} and \end{..} that repeat names:
//                                                nested, unclosed before closed, stray ends, starred names, quote prefixes
//   node gen_cases.mjs d5 <seed> <count>         <count> random documents of displays dense in what the KaTeX \newcommand
//                                                rule reads (deviation D5): definitions, names, comments, line ends,
//                                                \verb in every form, the addresses of \url, \href and \includegraphics
//                                                (a `}` where the address starts too, in a definition body
//                                                and outside any group)
//   node gen_cases.mjs multline <seed> <count>   <count> random documents dense in numbered multline environments
//                                                (deviation D7) and in tags with groups (deviation D8): labels, tags
//                                                and skip words in every row, in a % comment and after an escaping
//                                                backslash, tags with groups in them and unclosed ones, unnumbered
//                                                displays with tags, references forward and from other sources, tags
//                                                taken out from between a control word and a letter or from the start
//                                                of a row before a bracket or star (deviation D11)
//   node gen_cases.mjs tags                      explicit tags of 1 to 5,000 bytes and references to them
//   node gen_cases.mjs whitespace                the code points JavaScript's /\s/ matches, one hex number per line
//   node gen_cases.mjs json [--doc]              stdin is one source (or, with --doc, a JSON array of sources);
//                                                prints the oracle's output for it as JSON (with the `katex` and
//                                                `mathjax` texts of every math)
//
// The oracle is the reference with deviations D5 to D11 (README.md). The case file format is described there too.
// Output goes to stdout, a count of redrawn documents (the random kinds) and all errors go to stderr; any error exits
// with status 1.

import fs from 'node:fs';
import path from 'node:path';
import { extractMath, prepareTex as referencePrepareTex } from './mathgrammar.mjs';
import { latexNewcommand, KATEX_ONLY as REFERENCE_NAMES } from './katex_macros.mjs';
import { katexNewcommand, katexOnly } from './katex_rule.mjs';

// ---- running the reference over one document (a list of sources, typeset in order) ----

// A check of the oracle itself failed: never a reason to draw a random document again, always fatal.
class OracleError extends Error {}

function run(sources) {
  const ex = sources.map(s => extractMath(s));
  const all = [];
  ex.forEach((x, source) => x.maths.forEach(m => all.push({ ...m, source })));
  const prepared = prepareTex(all);
  // each deviation changes only the documents that hold what it reads differently
  const d10 = prepareTexD10(all);
  if (!all.some(m => D11_FEATURE.test(m.tex))) {
    prepared.forEach((t, i) => {
      if (t !== d10[i]) throw new OracleError('deviation D11 changed a document where no take-out can join anything');
    });
  }
  const d9 = prepareTexD9(all);
  if (!sources.some(s => s.includes(MARK))) {
    const marked = prepareTexMarked(all);
    marked.forEach((t, i) => {
      if (t.replaceAll(MARK, '') !== d9[i] || t.replaceAll(MARK + ' ', '') !== d10[i]) {
        throw new OracleError('deviation D10 changed a document elsewhere than after a row break');
      }
    });
  }
  const d7 = prepareTexD7(all);
  if (!all.some(m => D9_FEATURE.test(m.tex))) {
    d9.forEach((t, i) => {
      if (t !== d7[i]) throw new OracleError('deviation D9 changed a document that holds nothing it reads differently');
    });
  }
  const d8 = prepareTexD8(all);
  if (!all.some(m => m.display && D7_FEATURE.test(m.tex))) {
    d7.forEach((t, i) => {
      if (t !== d8[i]) throw new OracleError('deviation D7 changed a document that holds no multline it reads differently');
    });
  }
  if (!all.some(m => D8_FEATURE.test(m.tex))) {
    const reference = referencePrepareTex(all);
    d8.forEach((t, i) => {
      if (t !== reference[i]) throw new OracleError('deviation D8 changed a document that holds no tag it reads differently');
    });
  }
  const katex = katexRule(prepared);
  const mathjax = prepareTexMathJax(all);
  return { ex, all, prepared, katex, mathjax };
}

// The oracles of prepareTex are the reference module itself, loaded from its own source with a change made to it, so
// they share the reference's code for everything else. Each change is made to text that must occur exactly once.
const REFERENCE_SOURCE = fs.readFileSync(new URL('./mathgrammar.mjs', import.meta.url), 'utf8');
function patch(source, from, to, what) {
  if (source.split(from).length !== 2) throw new Error(`mathgrammar.mjs: ${what} is not where the oracle expects it`);
  return source.replace(from, () => to);
}
const load = source => import('data:text/javascript;base64,' + Buffer.from(source, 'utf8').toString('base64'));
// The take-out hook of the row loops below (deviation D11): in the modules of D7 to D10 a command taken out leaves
// nothing, as in the reference; D11's module replaces this one line.
const NO_GLUE = "function takeOut(st, s, at, end) { return ''; }";

// Deviation D8: the text a reference prints for a tag is the tag's whole brace group. The reference copies the text
// its /\\tag\*?\{([^}]*)\}/ captures, up to the first }, so a tag with a group in it (\tag{$x_{1}$}, \tag{\text{a}})
// made every \eqref of its label \text{($x_{1)}, an error in both engines. Here the label of a row with a tag, and of
// an unnumbered display with one, gets tagText: the text of the whole group (a backslash takes the next character
// with it), or null, printed ??, when the group does not close. Whether a row has a tag and whether it is empty (which
// decide its number) are read as before. Patched in the two places the reference registers a label under a tag.
const D8_SOURCE = patch(patch(patch(REFERENCE_SOURCE,
  'if (tg) tag = tg[1];', 'if (tg) tag = tg[1]; const shown = tg ? tagText(row, tg) : null;', 'the tag of a row'),
  'for (const k2 of lab) labels[k2] = tag;', 'for (const k2 of lab) labels[k2] = tg && tag === tg[1] ? shown : tag;', 'the labels of a row'),
  'if (tg) labels[k2] = tg[1];', 'if (tg) labels[k2] = tagText(t, tg);', 'the labels of an unnumbered display')
  + '\n' + tagText.toString() + '\n';
// A tag D8 reads differently: a { or a backslash in what /\\tag\*?\{([^}]*)\}/ captures (or a \ta a label removal
// could join with a g{ after it). Every other document must come out the same with and without D8, which is checked
// for every document generated.
const D8_FEATURE = /\\tag\*?\{[^}]*[{\\]|\\ta[\s\S]*\\label\{/;

// What a reference prints for the tag `m` (a match of /\\tag\*?\{([^}]*)\}/ in `s`), deviation D8; written to stand
// alone, since it runs inside the reference's module.
function tagText(s, m) {
  const open = m.index + (s[m.index + 4] === '*' ? 5 : 4);
  let depth = 0;
  for (let j = open; j < s.length; j++) {
    if (s[j] === '\\') { j++; continue; }
    if (s[j] === '{') depth++;
    else if (s[j] === '}' && --depth === 0) return s.slice(open + 1, j);
  }
  return null;
}
const { prepareTex: prepareTexD8 } = await load(D8_SOURCE);

// Deviation D7, the `prepared` field and the input of the `katex` field: a numbered multline is one equation, as in
// amsmath. The reference numbers it row by row, as if only its last row were numbered and the others had \nonumber: a
// \label before the last row is registered under no tag (every reference to it prints ??), a \tag there stays in its
// row while the last row gets a number too (two tags: KaTeX draws both, MathJax refuses multline* with "Multiple
// \tag"), and a \nonumber or \notag there leaves the equation numbered. Here the whole multline is read for its one
// tag: the first \tag{..} or \tag*{..} of any row is the equation's tag, a \nonumber or \notag in any row means no
// number, otherwise the last row gets \tag{n}; every \label of every row is registered under that tag, and every tag
// of a row before the last is taken out of its row, with its whole brace group, and written at the end of the last
// row, where amsmath sets it (so two tags meet there and are an error in both engines, as in LaTeX). Only a \label,
// \tag, \nonumber or \notag the engines see counts: one in a % comment or after an escaping backslash (`{a\\tag{T}}`
// is a line break and the text tag) does not. A tag whose group does not close in its row (a row with a stray `}`)
// stays where it is, and so does every tag after it in that row. A multline whose labels, tags and skip words all
// stand in its last row, outside comments and not after a backslash, comes out as it would without D7.
const D7_CALL_SITE = '      rows = rows.map((row, ri) => {';
const D7_SOURCE = patch(D8_SOURCE, D7_CALL_SITE,
  "      if (mode === 'last') ({ rows, eq } = multlineAsOneEquation(rows, eq, labels)); else rows = rows.map((row, ri) => {",
  'the row numbering of prepareTex') + '\n' + multlineAsOneEquation.toString() + '\n' + NO_GLUE + '\n';
// A multline that may come out differently under D7: a % in it, a backslash right before a \label, \tag, \nonumber
// or \notag, or one of those with a \\ after it (in a row before the last). Every other document must come out the
// same with and without D7, which is checked for every document generated.
const D7_FEATURE = /^\\begin\{multline\}[\s\S]*(?:%|\\\\(?:label\{|tag|nonumber|notag)|\\(?:label\{|tag|nonumber|notag)[\s\S]*\\\\)/;

// The rows of one numbered multline (deviation D7); written to stand alone, since it runs inside the reference's module.
// With `seenOnly` (deviation D9) a \label, \nonumber or \notag the engines do not see is also left where it is.
function multlineAsOneEquation(rows, eq, labels, seenOnly) {
  // seen(state, s, at): whether the engines see a command at `at` of `s`: `s` is read from its start, a backslash takes
  // the next character with it and a % hides the rest of its line. Asked with increasing `at` for one state.
  const seen = (state, s, at) => {
    let i = state.i;
    while (i < at) {
      if (s[i] === '\\') i += 2;
      else if (s[i] === '%') { const nl = s.indexOf('\n', i); i = nl < 0 ? s.length : nl; }
      else i++;
    }
    state.i = i;
    return i === at;
  };
  const keys = [];
  let tag = null, shown = null, found = false, skip = false, moved = '';
  const last = rows.length - 1;
  rows = rows.map((row, ri) => {
    // in the reference's order: labels out, the tag, the skip test, the skip words out; whatever is taken out goes
    // through takeOut (deviation D11), each pass knowing whether the row comes after a row break
    const glue = () => ({ from: 0, tail: ri > 0 ? 'break' : 'other' });
    const lab = { i: 0 }, lg = glue(), original = row;
    row = row.replace(/\\label\{([^}]*)\}/g, (all, k2, at) => {
      if (seen(lab, original, at)) { keys.push(k2); return takeOut(lg, original, at, at + all.length); }
      return seenOnly ? all : '';
    });
    const tg = { i: 0 };
    for (const m of row.matchAll(/\\tag\*?\{([^}]*)\}/g)) {
      if (seen(tg, row, m.index)) { if (!found) { found = true; tag = m[1]; shown = tagText(row, m); } break; }
    }
    const sk = { i: 0 };
    for (const m of row.matchAll(/\\(nonumber|notag)\b/g)) if (seen(sk, row, m.index)) { skip = true; break; }
    const sw = { i: 0 }, wg = glue(), words = row;
    row = row.replace(/\\(nonumber|notag)\b/g, (all, w, at) => {
      if (!seenOnly) return '';
      return seen(sw, words, at) ? takeOut(wg, words, at, at + all.length) : all;
    });
    if (ri === last) return row;
    // the tags of a row before the last move to the end of the last row, each with its whole brace group
    const TAG = /\\tag\*?\{[^}]*\}/g, mv = { i: 0 }, mg = glue();
    let out = '', copied = 0, m;
    while ((m = TAG.exec(row)) !== null) {
      if (!seen(mv, row, m.index)) continue;
      let depth = 0, end = -1;
      for (let j = m.index + (row[m.index + 4] === '*' ? 5 : 4); j < row.length; j++) {
        if (row[j] === '\\') { j++; continue; }
        if (row[j] === '{') depth++;
        else if (row[j] === '}' && --depth === 0) { end = j + 1; break; }
      }
      if (end < 0) break;
      moved += ' ' + row.slice(m.index, end);
      out += row.slice(copied, m.index) + takeOut(mg, row, m.index, end);
      copied = end;
      TAG.lastIndex = end;
    }
    return out + row.slice(copied);
  });
  rows[last] += moved;
  if (!tag && !skip) { tag = String(++eq); rows[last] += ` \\tag{${tag}}`; shown = tag; }
  for (const k2 of keys) labels[k2] = shown;
  return { rows, eq };
}

const { prepareTex: prepareTexD7 } = await load(D7_SOURCE);

// Deviation D9: the numbering reads the TeX as the engines see it, in every numbered environment, in an unnumbered
// display and where it removes the labels left over. The reference reads the raw text: it split rows at a \\ inside a
// % comment (and counted the braces there), numbered a commented-out row and wrote its \tag{n} into the comment, and
// read a \label, \tag, \nonumber or \notag in a comment or after an escaping backslash, so a derivation with one step
// commented out drew (1) (3) and every later number and reference was one too high, a commented \nonumber took the
// number away, and {u\\label{q}} lost its label's text into {u\}. Here (seenAt: a backslash takes the next character
// with it, a % hides the rest of its line):
// - an environment is numbered only when the engines see its \end (a % comment on the body's last line hides it, and
//   so does a backslash before it: the engines report the source as an error, and it is handed on as it is);
// - rows are split only at a \\ the engines see (splitRowsAsSeen): nothing in a comment counts, braces included;
// - a last row the engines see as empty is dropped, as the reference drops a blank one (emptyAsSeen): after the
//   argument [..] of the row break before it, only white space and comments;
// - a \label, \tag, \tag*, \nonumber or \notag counts only where it is seen (rowsAsSeen, the multline of D7 with
//   seenOnly, displayAsSeen), and one that is not seen stays where it is, in the leftover labels too
//   (removeSeenLabels).
// Every row then ends before a seen \\ or at the seen end of the body, so the \tag{n} written after it is seen.
// Patched in the reference (with D8): splitRows, the numbered environment, the last row, the whole row loop (D7's
// call site included), the labels of an unnumbered display and the leftover labels. The module is built on D8's, with
// D7 inside it (multlineAsOneEquation with seenOnly).
function seenAt(state, s, at) {
  let i = state.i;
  while (i < at) {
    if (s[i] === '\\') i += 2;
    else if (s[i] === '%') { const nl = s.indexOf('\n', i); i = nl < 0 ? s.length : nl; }
    else i++;
  }
  state.i = i;
  return i === at;
}
function firstSeen(s, re) {
  const state = { i: 0 };
  for (const m of s.matchAll(re)) if (seenAt(state, s, m.index)) return m;
  return null;
}
function endSeen(body) {
  let i = 0;
  while (i < body.length) {
    if (body[i] === '\\') i += 2;
    else if (body[i] === '%') { const nl = body.indexOf('\n', i); if (nl < 0) return false; i = nl; }
    else i++;
  }
  return i === body.length;
}
function splitRowsAsSeen(body) {
  const rows = []; let depth = 0, env = 0, last = 0;
  for (let i = 0; i < body.length; i++) {
    const c = body[i];
    if (c === '%') { const nl = body.indexOf('\n', i); if (nl < 0) break; i = nl; continue; }
    if (c === '\\') {
      if (body.startsWith('\\begin{', i)) env++;
      else if (body.startsWith('\\end{', i)) env--;
      else if (body[i + 1] === '\\' && depth === 0 && env === 0) { rows.push(body.slice(last, i)); last = i + 2; i++; continue; }
      i++; continue;
    }
    if (c === '{') depth++; else if (c === '}') depth--;
  }
  rows.push(body.slice(last));
  return rows;
}
function emptyAsSeen(row) {
  let i = 0;
  if (row[0] === '[') {
    // the argument of the row break: up to the first ] outside braces, a backslash taking the next character
    let depth = 0;
    for (i = 1; i < row.length; i++) {
      if (row[i] === '\\') { i++; continue; }
      if (row[i] === '{') depth++;
      else if (row[i] === '}' && --depth < 0) return false;
      else if (row[i] === ']' && depth === 0) break;
    }
    if (i >= row.length) return false;
    i++;
  }
  while (i < row.length) {
    const pct = row.indexOf('%', i);
    if (row.slice(i, pct < 0 ? row.length : pct).trim()) return false;
    if (pct < 0) return true;
    const nl = row.indexOf('\n', pct);
    if (nl < 0) return true;
    i = nl;
  }
  return true;
}
function rowsAsSeen(rows, eq, labels, notag) {
  rows = rows.map((row, ri) => {
    // in the reference's order: labels out, the first tag, whether the row is skipped, the skip words out; whatever is
    // taken out goes through takeOut (deviation D11), each pass knowing whether the row comes after a row break
    let tag = null; const lab = [];
    const glue = () => ({ from: 0, tail: ri > 0 ? 'break' : 'other' });
    const ls = { i: 0 }, lg = glue(), original = row;
    row = row.replace(/\\label\{([^}]*)\}/g, (all, k2, at) => {
      if (!seenAt(ls, original, at)) return all;
      lab.push(k2);
      return takeOut(lg, original, at, at + all.length);
    });
    const tg = firstSeen(row, /\\tag\*?\{([^}]*)\}/g); if (tg) tag = tg[1]; const shown = tg ? tagText(row, tg) : null;
    const skip = firstSeen(row, /\\(nonumber|notag)\b/g) !== null;
    const sw = { i: 0 }, wg = glue(), words = row;
    row = row.replace(/\\(nonumber|notag)\b/g, (all, w, at) => seenAt(sw, words, at) ? takeOut(wg, words, at, at + all.length) : all);
    if (!tag && !skip) { tag = String(++eq); row += ` \\tag{${tag}}`; }
    // deviation D6: an environment MathJax numbers by itself gets \notag on a row left without a tag
    else if (notag && !tg) row += ' \\notag';
    for (const k2 of lab) labels[k2] = tg && tag === tg[1] ? shown : tag;
    return row;
  });
  return { rows, eq };
}
function displayAsSeen(t, labels) {
  const tg = firstSeen(t, /\\tag\*?\{([^}]*)\}/g);
  const state = { i: 0 }, glue = { from: 0, tail: 'other' };
  return t.replace(/\\label\{([^}]*)\}/g, (all, k2, at) => {
    if (!seenAt(state, t, at)) return all;
    if (tg) labels[k2] = tagText(t, tg);
    return takeOut(glue, t, at, at + all.length);
  });
}
function removeSeenLabels(t) {
  const state = { i: 0 }, glue = { from: 0, tail: 'other' };
  return t.replace(/\\label\{([^}]*)\}/g, (all, k2, at) => seenAt(state, t, at) ? takeOut(glue, t, at, at + all.length) : all);
}
// The row loop of the reference with D8, from its first line to its last, each found exactly once.
function rowLoop(source) {
  const first = D7_CALL_SITE, last = '        return row;\n      });';
  if (source.split(first).length !== 2 || source.split(last).length !== 2) throw new Error('mathgrammar.mjs: the row loop is not where the oracle expects it');
  const start = source.indexOf(first), end = source.indexOf(last) + last.length;
  if (end < start) throw new Error('mathgrammar.mjs: the row loop is not where the oracle expects it');
  return source.slice(start, end);
}
const D9_SOURCE = [
  ['function splitRows(body) {', 'function splitRows(body) { return splitRowsAsSeen(body); }\nfunction splitRowsOfTheReference(body) {', 'splitRows'],
  ['if (env && NUMBERED[env[1]] && !env[2]) {', 'if (env && NUMBERED[env[1]] && !env[2] && endSeen(env[3])) {', 'the numbered environment'],
  ['if (rows.length > 1 && !rows[rows.length - 1].trim()) rows.pop();', 'if (rows.length > 1 && emptyAsSeen(rows[rows.length - 1])) rows.pop();', 'the last row'],
  [rowLoop(D8_SOURCE), "      ({ rows, eq } = mode === 'last' ? multlineAsOneEquation(rows, eq, labels, true) : rowsAsSeen(rows, eq, labels));", 'the row loop'],
  ["    const tg = t.match(/\\\\tag\\*?\\{([^}]*)\\}/);\n    t = t.replace(/\\\\label\\{([^}]*)\\}/g, (_, k2) => { if (tg) labels[k2] = tagText(t, tg); return ''; });",
    '    t = displayAsSeen(t, labels);', 'the labels of an unnumbered display'],
  ["    .replace(/\\\\label\\{([^}]*)\\}/g, ''));", '  ).map(removeSeenLabels);', 'the leftover labels'],
].reduce((src, [from, to, what]) => patch(src, from, to, what), D8_SOURCE)
  + '\n' + [seenAt, firstSeen, endSeen, splitRowsAsSeen, emptyAsSeen, rowsAsSeen, displayAsSeen, removeSeenLabels, multlineAsOneEquation].map(f => f.toString()).join('\n') + '\n' + NO_GLUE + '\n';
const { prepareTex: prepareTexD9 } = await load(D9_SOURCE);
// What D9 may read differently: a % in a math, or a backslash right before \label{, \tag, \nonumber, \notag, \end{ or
// the [ of a row break's argument. Every other document must come out the same with and without D9, which is checked
// for every document generated.
const D9_FEATURE = /%|\\\\(?:label\{|tag|nonumber|notag|end\{|\[)/;

// Deviation D10: the rows are joined with ' \\' and the row's own text right after it, so the text after a row break
// is the source's. The reference writes ' \\ ' and then the row: a row-spacing argument \\[4pt] became \\ [4pt],
// and both engines then draw "[4pt]" as text in the formula (neither looks past a blank for the argument), and \\*
// became \\ *, a * MathJax draws. Patched in the reference's join, found exactly once. Checked for every document:
// the D9 module with a mark after the blank of each join (MARK_JOIN) gives D9's text without the marks and D10's
// without the marks and the blank after each, so the join is all D10 changes.
const D10_JOIN = ["rows.join(' \\\\\\\\ ')", "rows.join(' \\\\\\\\')"];
const MARK = '';
const D10_SOURCE = patch(D9_SOURCE, D10_JOIN[0], D10_JOIN[1], 'the join of the rows');
const { prepareTex: prepareTexMarked } = await load(patch(D9_SOURCE, D10_JOIN[0], "rows.join(' \\\\\\\\\\uE000 ')", 'the join of the rows'));
const { prepareTex: prepareTexD10 } = await load(D10_SOURCE);

// Deviation D11: a command taken out never joins what it stood between. The reference takes a \label, \nonumber or
// \notag out (and D7 a tag of a multline row before the last) leaving nothing, so a control word before it and a
// letter after it became one word (\alpha\label{x}b gave the undefined \alphab, an error in both engines, where
// LaTeX draws alpha b; \nonumber\label{x}b lost its skip word to \nonumberb), and a row break before it took a [ or
// * after it for its argument (\\\label{x}[c, d] gave \\[c, d], a spacing that is no length, an error in both
// engines, where the source draws [c, d]). Here takeOut writes a blank in the command's place exactly there: the text
// copied since the last take-out (or from the start of the pass, which is a row after a row break or not) ends with a
// control word (letters, or @, which KaTeX reads as one, after an odd run of backslashes) and a letter or @ follows,
// or it ends with a row break (an even run of backslashes) and a [ or * follows. Patched in the hook's one line, found
// exactly once. Checked for every document: one where no take-out can meet such a byte (no } and no \nonumber or
// \notag right before a letter, @, [ or *) comes out the same with and without D11.
function takeOut(st, s, at, end) {
  if (at > st.from) st.tail = tailOf(s.slice(st.from, at));
  st.from = end;
  const c = s[end];
  const blank = c !== undefined && (st.tail === 'word' ? /^[A-Za-z@]$/.test(c) : st.tail === 'break' && (c === '[' || c === '*'));
  if (blank) st.tail = 'other';
  return blank ? ' ' : '';
}
function tailOf(t) {
  let j = t.length;
  while (j > 0 && /^[A-Za-z@]$/.test(t[j - 1])) j--;
  let k = j;
  while (k > 0 && t[k - 1] === '\\') k--;
  const letters = t.length - j, slashes = j - k;
  if (letters > 0 && slashes % 2 === 1) return 'word';
  if (letters === 0 && slashes > 0 && slashes % 2 === 0) return 'break';
  return 'other';
}
const D11_SOURCE = patch(D10_SOURCE, NO_GLUE, takeOut.toString() + '\n' + tailOf.toString(), 'the take-out hook');
const D11_FEATURE = /\}[A-Za-z@[*]|\\no(?:number|tag)[@[*]/;
const { prepareTex } = await load(D11_SOURCE);

// The `mathjax` field: the text MathJax is handed, prepareTex (with D7 to D11) with the environment MathJax draws for
// a numbered eqnarray, multline and flalign (deviation D6). The reference writes KaTeX's stand-ins, align* and gather*,
// for both engines (KaTeX has neither environment); MathJax has eqnarray* and multline* and draws them with an explicit
// \tag as LaTeX draws the numbered ones (a multline staggered, an eqnarray aligned at its relation), so the Rust grammar
// hands MathJax the starred form of the same environment, like every other numbered environment. A numbered flalign
// is the one exception: MathJax 3.2.2 refuses \tag in flalign* ("\tag not allowed in flalign* environment"), so the
// reference's flalign* with \tag{n} was an error, and it draws the unstarred flalign with the same explicit tags as
// LaTeX draws it. An unstarred environment numbers a row without a tag itself when MathJax's own numbering is on, so
// every row the numbering leaves without a tag (a skip word and no explicit tag) gets \notag, and the text draws the
// same with that numbering on or off. KaTeX has neither form of flalign; its text keeps flalign*. The oracle is the
// D11 module with the two table entries changed and rowsAsSeen told when its environment is unstarred, each found
// exactly once; MathJax applies no \newcommand rule, so this is its whole text.
const KATEX_STARRED = "eqnarray: 'align*', multline: 'gather*' };";
const MATHJAX_STARRED = "eqnarray: 'eqnarray*', multline: 'multline*' };";
const KATEX_FLALIGN = "flalign: 'flalign*',";
const MATHJAX_FLALIGN = "flalign: 'flalign',";
const ROWS_CALL = ': rowsAsSeen(rows, eq, labels));';
const ROWS_CALL_NOTAG = ": rowsAsSeen(rows, eq, labels, !STARRED[name].endsWith('*')));";
const { prepareTex: prepareTexMathJax } = await load([
  [KATEX_STARRED, MATHJAX_STARRED, 'the STARRED table'],
  [KATEX_FLALIGN, MATHJAX_FLALIGN, 'the STARRED form of flalign'],
  [ROWS_CALL, ROWS_CALL_NOTAG, 'the row loop of a numbered environment'],
].reduce((src, [from, to, what]) => patch(src, from, to, what), D11_SOURCE));

// The `katex` field is the Rust grammar's rule (deviation D5, katex_rule.mjs). The reference's rule (katex_macros.mjs)
// differs from it only where the document holds a % (a comment), a \providecommand, a \verb, a \url, \href or
// \includegraphics (their address is read with % an ordinary character), a \\newcommand (a line break and letters), a
// name with an @ after its letters, white space other than a blank (a no-break space), a \newcommand whose braced name
// is not exactly one token (a blank after the brace, or something other than the closing brace after the name), or a
// \newcommand of a name that only one of the two lists holds (\C and \Q, or one of the names added by D5). Any other
// document must come out the same under both, which is checked for every document generated.
const ONLY_ONE = [...katexOnly()].filter(n => !REFERENCE_NAMES.has(n)).concat([...REFERENCE_NAMES].filter(n => !katexOnly().has(n)));
const D5_FEATURE = new RegExp(`%|providecommand|[\\u000b\\u000c\\u00a0\\u1680\\u2000-\\u200a\\u2028\\u2029\\u202f\\u205f\\u3000\\ufeff]|\\\\verb|\\\\url|\\\\href|\\\\includegraphics|\\\\\\\\newcommand|\\\\newcommand\\s*\\{\\s|\\\\newcommand\\s*\\{\\\\[A-Za-z@]+(?![A-Za-z@])[ \\t\\r\\n]*(?:[^} \\t\\r\\n]|$)|\\\\newcommand\\s*(?:\\{\\s*)?\\\\(?:[A-Za-z]*@|(?:${ONLY_ONE.join('|')})(?![A-Za-z]))`);

function katexRule(prepared) {
  const defined = new Set();
  const katex = prepared.map(t => katexNewcommand(t, defined));
  const reference = new Set();
  const same = prepared.map(t => latexNewcommand(t, reference));
  if (!prepared.some(t => D5_FEATURE.test(t))) {
    prepared.forEach((_, i) => {
      if (katex[i] !== same[i]) throw new OracleError('the D5 rule and the reference rule differ on a document that holds no D5 feature');
    });
  }
  return katex;
}

// ---- the case file writer ----

// A field is written as UTF-8 bytes; a string that would not survive that (a lone surrogate) is refused.
function bytes(str) {
  const b = Buffer.from(str, 'utf8');
  if (b.toString('utf8') !== str) throw new Error('a field does not round-trip through UTF-8 (lone surrogate)');
  return b;
}

function field(parts, label, str) {
  const b = bytes(str);
  parts.push(Buffer.from(`${label} ${b.length}\n`), b, Buffer.from('\n'));
}

function writeDoc(parts, name, sources, res) {
  if (/[\n\r]/.test(name)) throw new Error('a document name holds a line break');
  parts.push(Buffer.from(`doc ${name}\n`));
  sources.forEach(s => field(parts, 'src', s));
  res.ex.forEach(x => field(parts, 'text', x.text));
  res.all.forEach((m, i) => {
    parts.push(Buffer.from(`math ${m.source} ${m.display ? 1 : 0} ${m.block ? 1 : 0} ${m.kind}\n`));
    field(parts, 'tex', m.tex);
    field(parts, 'raw', m.raw);
    field(parts, 'prepared', res.prepared[i]);
    field(parts, 'katex', res.katex[i]);
    if (res.mathjax[i] !== res.prepared[i]) field(parts, 'mathjax', res.mathjax[i]);
  });
  parts.push(Buffer.from('end\n'));
}

// Encodes one document to its case file text, or throws (the reference throwing counts, so does an unwritable field).
function encodeDoc(name, sources) {
  const parts = [];
  writeDoc(parts, name, sources, run(sources));
  return Buffer.concat(parts);
}

function writeCaseFile(docs) {
  const parts = [Buffer.from('JNVMATH 2\n')];
  for (const d of docs) parts.push(d);
  parts.push(Buffer.from(`count ${docs.length}\n`));
  emit(Buffer.concat(parts));
}

function emit(buf) { process.stdout.write(buf); }

// ---- battery and fixtures ----

function batteryDocs(file) {
  const cases = JSON.parse(fs.readFileSync(path.resolve(file), 'utf8'));
  if (!Array.isArray(cases)) throw new Error('the battery file is not an array');
  return cases.map(c => {
    if (!Array.isArray(c) || c.length !== 2 || typeof c[0] !== 'string' || typeof c[1] !== 'string') {
      throw new Error('a battery case is not a [name, source] pair');
    }
    return encodeDoc(c[0], [c[1]]);
  });
}

function cellSource(cell) { return Array.isArray(cell.source) ? cell.source.join('') : String(cell.source); }

function fixtureDocs(dir) {
  const read = f => fs.readFileSync(path.join(path.resolve(dir), f), 'utf8');
  const docs = [];
  for (const f of ['md-fixture.md', 'hero.md', 'gauss.md']) docs.push(encodeDoc(f, [read(f)]));
  for (const f of ['md-fixture.ipynb', 'hero.ipynb', 'gauss.ipynb']) {
    const nb = JSON.parse(read(f));
    const sources = [];
    nb.cells.forEach((cell, i) => {
      if (cell.cell_type !== 'markdown') return;
      const s = cellSource(cell);
      sources.push(s);
      docs.push(encodeDoc(`${f}#${i}`, [s]));
    });
    docs.push(encodeDoc(f, sources));
  }
  return docs;
}

// ---- random documents ----

function mulberry32(a) { return function () { a |= 0; a = (a + 0x6D2B79F5) | 0; let t = Math.imul(a ^ (a >>> 15), 1 | a); t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t; return ((t ^ (t >>> 14)) >>> 0) / 4294967296; }; }

// [weight, text]
const FRAGMENTS = [
  [12, '$'], [5, '$$'], [3, '\\$'], [3, '\\('], [3, '\\)'], [2, '\\['], [2, '\\]'], [2, '\\\\('], [2, '\\\\)'], [1, '\\\\['], [1, '\\\\]'],
  [5, '`'], [2, '``'], [2, '```'], [1, '~~~'], [2, '```math'], [1, '```MATH'], [1, '~~~Math'], [1, '```latex'], [3, '$`'], [3, '`$'],
  [3, '\\begin{'], [3, '\\end{'], [1, 'equation}'], [1, 'equation*}'], [1, 'align}'], [1, 'align*}'], [1, 'gather}'], [1, 'multline}'],
  [1, 'flalign}'], [1, 'alignat}{2}'], [1, 'eqnarray}'], [1, 'aligned}'], [1, 'cases}'], [1, 'x}'], [1, 'a*b*}'], [1, 'a**}'], [1, '**}'], [2, '}'], [2, '{'],
  [2, '\\label{a}'], [1, '\\label{b}'], [1, '\\label{eq:1}'], [2, '\\eqref{a}'], [1, '\\ref{b}'], [1, '\\eqref{eq:1}'], [1, '\\ref{zz}'],
  [1, '\\tag{T}'], [1, '\\tag*{S}'], [1, '\\tag{}'], [1, '\\nonumber'], [1, '\\notag'], [4, '\\\\'], [2, '&'],
  [1, '\\newcommand{\\R}{x}'], [1, '\\newcommand\\N{y}'], [1, '\\newcommand {\\Reals}'], [1, '\\renewcommand{\\R}{z}'], [1, '\\def\\foo{1}'],
  [1, '\\newcommand{\\Rx}{w}'], [1, '\\newcommand\u00a0{\\C}'], [1, '\\newcommand\u00a0{\\Z}'], [1, '\\newcommand\u2003\\N'],
  [1, '\\providecommand{\\R}{p}'], [1, '\\providecommand\\bm{b}'], [1, '\\newcommand{\\Q}{q}'], [1, '\\newcommand{\\argmax}{a}'],
  [1, '\\newcommand\\ket{k}'], [1, '\\verb|'], [2, '%'], [1, '\\newcommand%\n{\\Z}'], [1, '\\newcommand{\\R@x}{w}'], [1, '\\%'],
  [2, '<'], [2, '>'], [1, '<b>'], [1, '</b>'], [1, '<a href="x">'], [1, '<a\u00a0b>'], [1, '<!--'], [1, '-->'], [1, '<https://e.com>'], [1, '<x:y z>'],
  [1, '- '], [1, '1. '], [1, '* '], [1, '# '], [1, '| '], [1, '*'], [1, '**'], [1, '_'], [1, '~~'], [1, '['], [1, '](u)'], [1, ':smile:'],
  [8, ' '], [8, 'x'], [3, 'ab'], [3, '1'], [1, '20.50'], [1, '5 and '], [1, '-'], [1, '.'], [1, ','],
  [5, '\n'], [2, '\n\n'], [2, '\n> '], [1, '> '], [2, '\n    '], [1, '    '], [1, '\t'], [1, '\n  '], [1, '\r\n'], [1, '\r'],
  [1, '\u00a0'], [1, '\u2028'], [1, '\u2029'], [1, '\ufeff'], [1, '\u0085'], [1, '\u3000'], [1, '\u00e9'], [1, '\u{1F600}'],
];
const CUMULATIVE = [];
let TOTAL = 0;
for (const [w, t] of FRAGMENTS) { TOTAL += w; CUMULATIVE.push([TOTAL, t]); }

function pick(r) {
  const x = r() * TOTAL;
  for (const [c, t] of CUMULATIVE) if (c > x) return t;
  return CUMULATIVE[CUMULATIVE.length - 1][1];
}

function frags(r, lo, hi) {
  const n = lo + Math.floor(r() * (hi - lo + 1));
  let s = '';
  for (let i = 0; i < n; i++) s += pick(r);
  return s;
}

const ENVS = ['equation', 'align', 'gather', 'multline', 'flalign', 'alignat', 'eqnarray', 'align*', 'aligned'];
const quote = s => s.split('\n').map(l => '> ' + l).join('\n');

function envDoc(r) {
  const e = ENVS[Math.floor(r() * ENVS.length)], n = 1 + Math.floor(r() * 3), rows = [];
  for (let i = 0; i < n; i++) {
    let row = frags(r, 0, 3);
    if (r() < 0.3) row += ' \\label{' + ['a', 'b', 'eq:1'][Math.floor(r() * 3)] + '}';
    if (r() < 0.2) row += ' \\tag{T' + i + '}';
    if (r() < 0.2) row += r() < 0.5 ? ' \\nonumber' : ' \\notag';
    rows.push(row);
  }
  let body = '\\begin{' + e + '}' + rows.join(r() < 0.5 ? ' \\\\ ' : '\\\\\n') + '\\end{' + e + '}';
  if (r() < 0.5) body = '$$\n' + body + '\n$$';
  if (r() < 0.5) body += ' see $\\eqref{a}$ and $\\ref{b}$';
  return body;
}

const TEMPLATES = [
  r => '$' + frags(r, 1, 6) + '$' + frags(r, 0, 3),
  r => '$$' + frags(r, 1, 6) + '$$',
  r => (r() < 0.5 ? '' : 'text\n') + '$$\n' + frags(r, 1, 6) + '\n$$' + (r() < 0.5 ? '' : '\nafter'),
  r => quote('$$\n' + frags(r, 1, 4) + '\n$$'),
  r => envDoc(r),
  r => (r() < 0.5 ? '```math\n' : '~~~MATH\n') + frags(r, 1, 4) + (r() < 0.5 ? '\n```' : '\n~~~'),
  r => '`' + frags(r, 1, 4) + '` $x$ ' + frags(r, 0, 3),
  r => '- ' + frags(r, 1, 6) + '\n\n  ' + frags(r, 1, 6),
];

function randomSource(r) { return r() < 0.70 ? frags(r, 1, 24) : TEMPLATES[Math.floor(r() * 8)](r); }

function fuzzDocs(seed, count) {
  const r = mulberry32(seed);
  const docs = [];
  let redrawn = 0;
  while (docs.length < count) {
    const k = r() < 0.10 ? 2 + Math.floor(r() * 2) : 1;
    const sources = [];
    for (let j = 0; j < k; j++) sources.push(randomSource(r));
    try {
      docs.push(encodeDoc(`fuzz-${seed}-${docs.length}`, sources));
    } catch (e) {
      if (e instanceof OracleError) throw e;
      redrawn++;
    }
  }
  process.stderr.write(`redrawn ${redrawn}\n`);
  return docs;
}

// ---- AMS-dense documents (numbering, labels, references) ----

const pickOf = (r, list) => list[Math.floor(r() * list.length)];

// small sets, so that keys and names collide: a label defined twice, a reference to a label defined later or never
const AMS_KEYS = ['a', 'b', 'c', 'eq:1', '', 'a b', '\\tag{X', '\\nonumber', 'zz'];
const AMS_ENVS = ['equation', 'align', 'gather', 'multline', 'flalign', 'alignat', 'eqnarray',
  'equation', 'align', 'gather', 'multline', 'equation*', 'align*', 'multline*', 'aligned', 'split', 'cases', 'x'];
const AMS_ROW_PIECES = [
  () => 'x', () => 'a & b', () => 'y^2', () => '{a\\\\b}', () => '\\{ x \\}', () => '\\begin{aligned}p\\\\q\\end{aligned}',
  () => '', () => ' ', () => '\\frac{1}{2}', r => pickOf(r, AMS_GLUED)(r), r => pickOf(r, AMS_GLUED)(r),
];

// What a take-out could join (deviation D11): a control word right before a label or skip word with a letter or @
// right after it, a row break (the one before the row, or one in a group) right before one with a [ or * right after
// it, and the near misses (letters after an escaped backslash, a digit or a blank after the command).
const AMS_GLUED = [
  r => '\\alpha' + pickOf(r, ['\\label{a}', '\\nonumber', '\\notag', '\\label{b}\\notag', '\\label{c}\\label{a}']) + pickOf(r, ['b', '@', ' b', '1']),
  r => pickOf(r, ['\\label{c}', '\\nonumber', '\\label{a}\\nonumber', '\\notag']) + pickOf(r, ['[p, q]', '*q', '[1pt] q']),
  r => '{x\\\\' + pickOf(r, ['\\label{a}', '\\notag']) + pickOf(r, ['[y]', '*y', 'y']) + '}',
  r => '\\\\alpha\\label{' + pickOf(r, AMS_KEYS) + '}c',
];

// What the engines do not see (deviation D9): a label, tag or skip word in a % comment (to the end of its line or of
// the row) or after an escaping backslash, braces, row breaks and environments in a comment, an escaped %.
const AMS_UNSEEN = [
  r => ' % \\label{' + pickOf(r, AMS_KEYS) + '}\n', r => ' %\\tag{' + pickOf(r, ['C', '1', '']) + '}',
  r => ' % ' + pickOf(r, ['\\nonumber', '\\notag', '\\tag*{S}']) + '\n', r => ' %' + pickOf(r, ['\\nonumber', '\\label{a}']),
  r => ' {u\\\\' + pickOf(r, ['label{a}', 'tag{E}', 'nonumber', 'notag']) + '}', r => ' \\\\' + pickOf(r, ['label{b}', 'notag']),
  r => ' % ' + pickOf(r, ['{', '}', '\\\\', '\\begin{x}', '\\end{x}', '} \\\\ {']) + '\n', () => ' \\%\\label{c}', () => ' \\%',
];

function amsRow(r) {
  let row = pickOf(r, AMS_ROW_PIECES)(r);
  const extras = Math.floor(r() * 3);
  for (let i = 0; i < extras; i++) {
    const x = r();
    if (x < 0.15) { row += pickOf(r, AMS_UNSEEN)(r); continue; }
    if (x < 0.30) row += ' \\label{' + pickOf(r, AMS_KEYS) + '}';
    else if (x < 0.42) row += ' \\tag{' + pickOf(r, ['T', 'A', '2', '(i)', 'Thm 1']) + '}';
    else if (x < 0.48) row += ' \\tag*{S}';
    else if (x < 0.53) row += ' \\tag{}';
    else if (x < 0.65) row += ' \\nonumber';
    else if (x < 0.73) row += ' \\notag';
    else if (x < 0.78) row += pickOf(r, [' \\nonumberx', ' \\notag_', ' \\nonumber1', ' \\notagé']);
    else if (x < 0.84) row += ' \\label{\\nonumber}';
    else if (x < 0.90) row += ' \\label{\\tag{X}}';
    else if (x < 0.95) row += ' \\label{unclosed';
    else row += ' \\ref{' + pickOf(r, AMS_KEYS) + '}';
  }
  return row;
}

// Row breaks: plain, at a line end, with a row-spacing argument or a star (deviation D10), a break whose next line
// starts with a bracket, which is the row's text, and a break with the row's text right after it (a take-out at the
// row's start meets the break there, deviation D11).
const AMS_BREAKS = [' \\\\ ', '\\\\\n', ' \\\\ ', '\\\\\n', '\\\\[4pt]\n', '\\\\[-2pt] ', '\\\\[1em]', '\\\\*\n', '\\\\\n[x, y] ', '\\\\'];

function amsEnv(r) {
  const e = pickOf(r, AMS_ENVS), n = 1 + Math.floor(r() * 4);
  const plain = r() < 0.5;
  let body = '';
  for (let i = 0; i < n; i++) {
    if (i > 0) body += plain ? pickOf(r, [' \\\\ ', '\\\\\n']) : pickOf(r, AMS_BREAKS);
    // a row commented out on a line of its own, its break with it or not (deviation D9)
    if (!plain && r() < 0.25) body += '\n% ' + amsRow(r).replace(/\n/g, ' ') + (r() < 0.7 ? ' \\\\' : '') + '\n';
    body += amsRow(r);
  }
  if (r() < 0.2) body += '\\\\';
  if (r() < 0.1) body += ' \\\\ ';
  // a last row the engines see as empty or not, and an end hidden by a comment or a backslash (deviation D9)
  if (!plain) {
    const t = r();
    if (t < 0.15) body += '\\\\\n% ' + amsRow(r).replace(/\n/g, ' ') + '\n';
    else if (t < 0.25) body += pickOf(r, ['\\\\[2pt]\n', '\\\\[2pt] % x\n', '\\\\*\n', '\\\\\n[2pt]\n', '\\\\[{]}]\n', '\\\\[a\n']);
    else if (t < 0.30) body += pickOf(r, [' % note', '\\']);
  }
  const arg = e === 'alignat' ? '{2}' : '';
  const end = r() < 0.08 ? pickOf(r, ['gamma', 'align', e + '*', '']) : e;
  return '\\begin{' + e + '}' + arg + body + '\\end{' + end + '}';
}

function amsDisplay(r) {
  const x = r();
  if (x < 0.55) {
    const env = amsEnv(r);
    const w = r();
    if (w < 0.4) return '$$\n' + env + '\n$$';
    if (w < 0.55) return '$$' + env + '$$';
    if (w < 0.65) return '\\[' + env + '\\]';
    if (w < 0.70) return '> ' + env;
    return env;
  }
  // a display that is no numbered environment: its labels refer to its explicit tag, if it has one
  let t = 'x';
  const extras = 1 + Math.floor(r() * 3);
  for (let i = 0; i < extras; i++) {
    const y = r();
    if (y < 0.15) { t += pickOf(r, AMS_UNSEEN)(r); continue; }
    if (y < 0.4) t += ' \\label{' + pickOf(r, AMS_KEYS) + '}';
    else if (y < 0.7) t += ' \\tag{' + pickOf(r, ['T', 'A', '2', '']) + '}';
    else if (y < 0.8) t += ' \\tag*{S}';
    else if (y < 0.9) t += ' \\nonumber';
    else if (y < 0.95) t += ' \\label{\\tag{X}}';
    else t += ' ' + AMS_GLUED[0](r);
  }
  return r() < 0.7 ? '$$' + t + '$$' : '\\[' + t + '\\]';
}

function amsInline(r) {
  const cmd = pickOf(r, ['\\ref', '\\eqref', '\\ref', '\\eqref', '\\label']);
  const key = r() < 0.08 ? pickOf(r, ['\\tag{X', 'a)', '']) : pickOf(r, AMS_KEYS);
  // a leftover label the engines do not see stays (deviation D9)
  const unseen = r() < 0.1 ? pickOf(r, [' \\\\label{a}', ' x % \\label{b}\n y', ' \\beta\\label{c}d']) : '';
  const m = cmd + '{' + key + '}' + (r() < 0.15 ? ' ' + cmd + '{' + pickOf(r, AMS_KEYS) + '}' : '') + unseen;
  return r() < 0.6 ? '$' + m + '$' : '\\(' + m + '\\)';
}

function amsSource(r) {
  const n = 1 + Math.floor(r() * 6), parts = [];
  for (let i = 0; i < n; i++) {
    const x = r();
    if (x < 0.55) parts.push(amsDisplay(r));
    else if (x < 0.85) parts.push('see ' + amsInline(r) + ' and ' + amsInline(r));
    else parts.push(pickOf(r, ['text', 'a $x$ b', '`code`', '$$\nx\n$$']));
  }
  return parts.join(r() < 0.6 ? '\n\n' : '\n');
}

// ---- documents dense in numbered multline environments and in tags with groups (deviations D7 and D8) ----

// What a row of a multline holds: labels, tags (starred, empty, with groups in them, unclosed), skip words and their
// near misses in any row, the same in a % comment (to the end of the line or of the row) and after an escaping
// backslash, an escaped %, a backslash before a character of two to four UTF-8 bytes, a stray } before a tag,
// references.
const ML_KEYS = ['a', 'b', 'eq:1', 'm', ''];
const ML_ROW_PIECES = [
  () => 'f(x) = a_0 + a_1 x', () => '+ a_2 x^2', () => 'x', () => '{a\\\\b}', () => '\\{ x \\}', () => '',
  () => ' ', () => '\\begin{aligned}p\\\\q\\end{aligned}', () => '\\shoveleft{y}', () => '\\frac{1}{2}',
  // a tag, label or skip word at the start of a row with a [ or * right after it, which D7 and D11 take out
  () => '\\tag{B}[x, y]', () => '\\label{a}*y', () => '\\notag[1pt]',
];
const ML_EXTRAS = [
  r => ' \\label{' + pickOf(r, ML_KEYS) + '}',
  r => ' \\label{' + pickOf(r, ML_KEYS) + '}',
  r => ' \\tag{' + pickOf(r, ['A', '$\\ast$', '2', '(i)', '', '$x_{1}$', '\\text{a}', '\\textbf{B}{}']) + '}',
  r => ' \\tag{' + pickOf(r, ['A', '$\\ast$', '2']) + '}',
  () => ' \\tag*{S}',
  () => ' \\nonumber', () => ' \\notag', r => pickOf(r, [' \\nonumberx', ' \\notag_', ' \\notage']),
  r => ' % ' + pickOf(r, ['\\tag{C}', '\\label{a}', '\\nonumber', 'note']) + '\n',
  r => ' %' + pickOf(r, ['\\tag{D}', '\\label{b}', '\\notag']),
  r => ' {u\\\\' + pickOf(r, ['tag{E}', 'label{a}', 'nonumber']) + '}',
  () => ' \\%\\tag{P}', () => ' {v\\\\%\\tag{Q}}', () => ' \\\\%',
  r => ' \\' + pickOf(r, ['\u00e9', '\u{1F600}', '\u00e9%', '\u0301']) + '\\tag{F}',
  () => ' } \\tag{a{b}', () => ' \\tag{a\\tag{b}}', () => ' \\tag{\\label{m}x}',
  r => ' \\alpha' + pickOf(r, ['\\tag{G}', '\\label{a}', '\\notag', '\\tag{H}\\label{m}']) + pickOf(r, ['b', '@', ' b']),
  r => ' \\eqref{' + pickOf(r, ML_KEYS) + '}', r => ' \\ref{' + pickOf(r, ML_KEYS) + '}',
];

function multlineEnv(r) {
  const e = pickOf(r, ['multline', 'multline', 'multline', 'multline', 'multline*', 'equation', 'align', 'gather']);
  const n = 1 + Math.floor(r() * 5), rows = [];
  for (let i = 0; i < n; i++) {
    let row = pickOf(r, ML_ROW_PIECES)();
    for (let k = 0, extras = Math.floor(r() * 3); k < extras; k++) row += pickOf(r, ML_EXTRAS)(r);
    rows.push(row);
  }
  // a join with the row's text right after the break too, so a take-out at a row's start meets it (deviation D11)
  let body = rows.join(pickOf(r, [' \\\\ ', '\\\\\n', '\\\\']));
  if (r() < 0.15) body += '\\\\';
  return '\\begin{' + e + '}' + (r() < 0.5 ? '\n' : '') + body + (r() < 0.5 ? '\n' : '') + '\\end{' + e + '}';
}

function multlineSource(r) {
  const n = 1 + Math.floor(r() * 4), parts = [];
  for (let i = 0; i < n; i++) {
    const x = r();
    if (x < 0.6) {
      const env = multlineEnv(r), w = r();
      parts.push(w < 0.5 ? '$$\n' + env + '\n$$' : w < 0.75 ? '$$' + env + '$$' : w < 0.9 ? '\\[' + env + '\\]' : env);
    } else if (x < 0.7) {
      // an unnumbered display: its labels refer to its first tag, read as its whole group (deviation D8)
      let t = 'x';
      for (let k = 0, extras = 1 + Math.floor(r() * 3); k < extras; k++) t += pickOf(r, ML_EXTRAS)(r);
      parts.push('$$' + t + '$$');
    } else if (x < 0.9) {
      parts.push('By $\\eqref{' + pickOf(r, ML_KEYS) + '}$ and \\(\\ref{' + pickOf(r, ML_KEYS) + '}\\)');
    } else parts.push('text');
  }
  return parts.join('\n\n');
}

// ---- documents of bare environments that repeat names ----

const ENV_NAMES = ['x', 'y', 'x', 'align', 'x*', 'a*b*', 'a*', '*', 'ab**', 'x', 'y', 'a**', '*a*'];
const ENV_FILL = [' a ', ' b ', 'x', '\n', '\n\n', ' ', '> ', '$', '$$', '\\(', '\\)', '`', '\\\\', '{', '}', '\\label{a}', '\\tag{T}'];

function envSource(r) {
  const n = 2 + Math.floor(r() * 12);
  let s = '', quoted = r() < 0.15;
  for (let i = 0; i < n; i++) {
    const x = r();
    if (x < 0.30) s += '\\begin{' + pickOf(r, ENV_NAMES) + '}';
    else if (x < 0.60) s += '\\end{' + pickOf(r, ENV_NAMES) + '}';
    else s += pickOf(r, ENV_FILL);
  }
  if (quoted) s = s.split('\n').map(l => '> ' + l).join('\n');
  return s;
}

// ---- documents dense in what the KaTeX rule reads (deviation D5) ----

// The pieces the rule reads otherwise than plain text, so that each math holds several of them in every order: the
// definitions and their names (braced or not, one token or not, listed or not), comments and line ends, \verb in every
// form (each line terminator as the delimiter, the star, a delimiter that comes back and one that does not), the
// addresses of \url, \href and \includegraphics with its brackets (and a `}` where the address starts, which ends the
// formula in KaTeX outside any group and closes the group inside one: definition bodies, names and \let that hold
// these commands, the brackets left open in a body), braces after a backslash, white space other than a blank,
// multibyte and combining characters. No `$`, backtick or `<`, so each display stays one math.
const D5_PIECES = [
  '\\newcommand', '\\providecommand', '\\renewcommand', '\\newcommand{', '\\newcommand{\\R}{1}', '\\newcommand\\N{2}',
  '\\providecommand{\\argmax}{a}', '\\newcommand {\\bm}', '\\R', '\\N', '\\Z', '\\argmax', '\\bm', '\\Q', '\\R@', '\\Rx',
  '{', '}', '{ ', '{\\R', '\\R}', '\\R }', '\\R x}', '[1]', '#1', '\\def',
  '%', '%c\n', '\n', '\r\n', ' ', '\t', '\u00a0', '\u2028', '\u2029',
  '\\verb', '\\verb*', '\\verb\n', '\\verb*\n', '\\verb\r', '\\verb\u2028', '\\verb\u2029', '\\verb|', '\\verb*!', '!', '|',
  '\\url', '\\href', '\\url{', '\\href{', '\\url{a%b}', '\\url ', 'a%b', '}{t}',
  '\\includegraphics', '\\includegraphics[', '[x]', ']', '[height=1em]',
  '\\url}', '\\href }', '\\includegraphics}', '\\includegraphics[x]\n}',
  '\\newcommand{\\lk}{\\url}', '\\def\\lk{\\href}', '\\newcommand{\\fig}[1]{\\includegraphics[width=#1]}',
  '\\newcommand{\\fig}{\\includegraphics[width=}', '\\renewcommand{\\url}[1]{x}', '{\\let\\lk\\url}', '\\newcommand{\\a}{\\newcommand{\\b}{x}\\url}',
  '\\\\', '\\}', '\\{', '\\%', '\\text{', 'a', '2', '@', '\u00e9', '\u0301', '\u{1F600}',
];

function d5Source(r) {
  const n = 1 + Math.floor(r() * 3), maths = [];
  for (let i = 0; i < n; i++) {
    let m = '';
    for (let j = 0, k = 1 + Math.floor(r() * 16); j < k; j++) m += pickOf(r, D5_PIECES);
    maths.push('$$' + m + '$$');
  }
  return maths.join('\n\n');
}

function makeDocs(prefix, source, seed, count, maxSources) {
  const r = mulberry32(seed);
  const docs = [];
  let redrawn = 0;
  while (docs.length < count) {
    const k = r() < 0.30 ? 2 + Math.floor(r() * (maxSources - 1)) : 1;
    const sources = [];
    for (let j = 0; j < k; j++) sources.push(source(r));
    try {
      docs.push(encodeDoc(`${prefix}-${seed}-${docs.length}`, sources));
    } catch (e) {
      if (e instanceof OracleError) throw e;
      redrawn++;
    }
  }
  process.stderr.write(`redrawn ${redrawn}\n`);
  return docs;
}

// ---- long tags ----

// Documents with an explicit tag of 1 to 5,000 bytes referenced one to three
// times (and from other sources): the Rust grammar copies a tag into a
// reference while the references of the document together copy a bounded
// amount (deviation D3), and every document here is far below that bound, so
// the reference's output is the expected one.
function tagDocs() {
  const words = 'mass and energy are the same thing ';
  const tagOf = len => words.repeat(Math.ceil(len / words.length)).slice(0, len);
  const refs = n => Array.from({ length: n }, (_, i) => (i % 2 === 0 ? '$\\ref{k}$' : '$\\eqref{k}$')).join(' ');
  const docs = [];
  for (const len of [1, 63, 64, 65, 100, 1000, 5000]) {
    const tag = tagOf(len);
    for (const n of [1, 2, 3]) {
      docs.push(encodeDoc(`tags-display-${len}-${n}`, [`$$x \\tag{${tag}}\\label{k}$$ ${refs(n)}`]));
    }
    docs.push(encodeDoc(`tags-star-${len}`, [`$$x \\tag*{${tag}}\\label{k}$$ ${refs(2)}`]));
  }
  for (const len of [65, 1000]) {
    const tag = tagOf(len);
    docs.push(encodeDoc(`tags-row-${len}`, [
      `$$\\begin{align}a\\tag{${tag}}\\label{k}\\\\ b\\label{m}\\end{align}$$ $\\ref{k}$ $\\eqref{k}$ $\\ref{m}$ $\\eqref{k}$`,
    ]));
    docs.push(encodeDoc(`tags-cells-${len}`, [
      `$$x \\tag{${tag}}\\label{k}$$`,
      `see ${refs(2)}`,
      `and again ${refs(3)}`,
    ]));
    docs.push(encodeDoc(`tags-forward-${len}`, [
      `first ${refs(3)}`,
      `$$x \\tag{${tag}}\\label{k}$$ ${refs(1)}`,
    ]));
  }
  return docs;
}

// ---- JavaScript whitespace ----

function whitespaceTable() {
  const lines = [];
  const ws = /\s/;
  for (let cp = 0; cp <= 0x10FFFF; cp++) {
    if (cp >= 0xD800 && cp <= 0xDFFF) continue;
    const ch = String.fromCodePoint(cp);
    const byRegex = ws.test(ch);
    if (byRegex !== (ch.trim() === '')) throw new Error(`trim and \\s disagree at U+${cp.toString(16)}`);
    if (byRegex) lines.push(cp.toString(16).padStart(4, '0'));
  }
  return lines.join('\n') + '\n';
}

// ---- the json mode ----

function jsonOutput(sources) {
  const res = run(sources);
  return JSON.stringify({
    texts: res.ex.map(x => x.text),
    maths: res.all.map(m => ({ source: m.source, tex: m.tex, raw: m.raw, display: m.display, block: m.block, kind: m.kind })),
    prepared: res.prepared,
    katex: res.katex,
    mathjax: res.mathjax,
  }) + '\n';
}

// ---- main ----

function main(argv) {
  const [mode, ...rest] = argv;
  switch (mode) {
    case 'battery':
      if (rest.length !== 1) throw new Error('usage: battery <cases.json>');
      return writeCaseFile(batteryDocs(rest[0]));
    case 'fixtures':
      if (rest.length !== 1) throw new Error('usage: fixtures <dir>');
      return writeCaseFile(fixtureDocs(rest[0]));
    case 'fuzz': {
      if (rest.length !== 2) throw new Error('usage: fuzz <seed> <count>');
      const seed = Number(rest[0]), count = Number(rest[1]);
      if (!Number.isInteger(seed) || !Number.isInteger(count) || count < 0) throw new Error('seed and count must be integers');
      return writeCaseFile(fuzzDocs(seed, count));
    }
    case 'ams':
    case 'envs':
    case 'd5':
    case 'multline': {
      if (rest.length !== 2) throw new Error(`usage: ${mode} <seed> <count>`);
      const seed = Number(rest[0]), count = Number(rest[1]);
      if (!Number.isInteger(seed) || !Number.isInteger(count) || count < 0) throw new Error('seed and count must be integers');
      const kinds = { ams: [amsSource, 3], envs: [envSource, 2], d5: [d5Source, 4], multline: [multlineSource, 3] };
      const [source, maxSources] = kinds[mode];
      return writeCaseFile(makeDocs(mode, source, seed, count, maxSources));
    }
    case 'tags':
      if (rest.length !== 0) throw new Error('usage: tags');
      return writeCaseFile(tagDocs());
    case 'whitespace':
      if (rest.length !== 0) throw new Error('usage: whitespace');
      return emit(Buffer.from(whitespaceTable()));
    case 'json': {
      const doc = rest.length === 1 && rest[0] === '--doc';
      if (rest.length > 1 || (rest.length === 1 && !doc)) throw new Error('usage: json [--doc]');
      const input = fs.readFileSync(0, 'utf8');
      let sources = [input];
      if (doc) {
        sources = JSON.parse(input);
        if (!Array.isArray(sources) || sources.some(s => typeof s !== 'string')) throw new Error('--doc wants a JSON array of strings');
      }
      return emit(Buffer.from(jsonOutput(sources)));
    }
    default:
      throw new Error('usage: gen_cases.mjs battery|fixtures|fuzz|ams|envs|d5|multline|tags|whitespace|json ...');
  }
}

try {
  main(process.argv.slice(2));
} catch (e) {
  process.stderr.write(`gen_cases: ${e && e.message ? e.message : e}\n`);
  process.exitCode = 1;
}
