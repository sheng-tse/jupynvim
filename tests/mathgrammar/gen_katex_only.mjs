// Generates the list of names the KaTeX \newcommand rule knows (deviation D5): the control words KaTeX predefines that
// LaTeX with amsmath and amssymb does not. A document's first \newcommand of such a name is legal LaTeX that KaTeX
// refuses ("attempting to redefine"), so the rule passes it to KaTeX as \renewcommand.
//
//   node gen_katex_only.mjs names <katex-package-dir> [latex-binary]   prints katex_only.txt (needs node, KaTeX and LaTeX)
//   node gen_katex_only.mjs check <katex-package-dir> [latex-binary]   the same names, compared with the committed katex_only.txt
//   node gen_katex_only.mjs rust                                       stdin is katex_only.txt; prints katex_names.rs
//
// <katex-package-dir> is an unpacked `katex` npm package (the one holding dist/katex.mjs). The list is the same set
// whatever the machine: it only depends on KaTeX's tables and on the kernel of LaTeX, whose version is recorded in the
// header of katex_only.txt. Errors go to stderr and exit with status 1.
//
// `check` compares what matters and nothing else: the names, and the `# katex` and `# katex-names` header lines. A
// different `# latex` banner (another TeX Live, MiKTeX) is no failure when the names agree; it prints a note. Where
// the latex binary cannot run (`latex --version` errors or exits non-zero) `check` compares the version of KaTeX and
// the number of names it predefines with the header and prints a note that the LaTeX half was not checked, so a machine
// without TeX Live can run it; `names` needs LaTeX and stops with a message.
//
// How the set is found:
//   1. The names KaTeX knows: the keys of its macro, function, math symbol, text symbol and implicit command tables
//      (read by exporting those variables from a copy of the bundle) and every control word that occurs anywhere in
//      the bundle's text, each kept only when real KaTeX refuses `\newcommand{\name}{x}` with "attempting to
//      redefine". Every name the text search finds must be in the tables or KaTeX must accept it, or the tables
//      were not read completely and generation fails.
//   2. The names LaTeX defines: `\@ifdefinable`, the test `\newcommand` itself applies, run for every name in a
//      real LaTeX run with amsmath and amssymb. A second run issues the real `\newcommand` for every name of the
//      set (no error) and for every other name KaTeX knows (an "already defined" error each) and fails otherwise.
//   3. The set is the names of 1 that 2 does not define.

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { pathToFileURL, fileURLToPath } from 'node:url';
import { parseNames } from './katex_rule.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const COMMITTED = path.join(HERE, 'katex_only.txt');
const WORD = /^[A-Za-z]+$/;

function die(msg) {
  process.stderr.write(`gen_katex_only: ${msg}\n`);
  process.exit(1);
}

// ---- 1. the names KaTeX refuses to \newcommand ----

async function loadKatex(dir, tmp) {
  const bundle = path.join(dir, 'dist', 'katex.mjs');
  let src;
  try { src = fs.readFileSync(bundle, 'utf8'); } catch (e) { die(`cannot read ${bundle}: ${e.message}`); }
  const tables = ['macros', '_functions', 'symbols', 'implicitCommands'];
  for (const v of tables) {
    if (!new RegExp(`^var ${v} = `, 'm').test(src)) die(`${bundle} has no top-level "var ${v} = ": not the bundle this generator reads`);
  }
  const patched = path.join(tmp, 'katex-tables.mjs');
  fs.writeFileSync(patched, `${src}\nexport const __tables = { ${tables.join(', ')} };\n`);
  const mod = await import(pathToFileURL(patched).href);
  const pkg = JSON.parse(fs.readFileSync(path.join(dir, 'package.json'), 'utf8'));
  if (pkg.version !== mod.version) die(`package.json says ${pkg.version}, the bundle says ${mod.version}`);
  return { katex: mod.default, version: mod.version, tables: mod.__tables, text: src };
}

function katexRefuses(katex, name) {
  // `\newcommand{\verb}{x}` does not parse as a definition (KaTeX lexes `\verb}{x}` as verbatim text), so the form
  // without braces is tried when the first one fails for another reason
  let lastError = '';
  for (const form of [`\\newcommand{\\${name}}{x}`, `\\newcommand\\${name}{x}`]) {
    try {
      katex.renderToString(form, { throwOnError: true, strict: 'ignore' });
      return false;
    } catch (e) {
      if (/attempting to redefine/.test(e.message)) return true;
      lastError = e.message;
    }
  }
  return die(`\\newcommand of \\${name} failed for another reason: ${lastError}`);
}

function katexNames(k) {
  const fromTables = new Set();
  const { macros, _functions, symbols, implicitCommands } = k.tables;
  for (const table of [macros, _functions, symbols.math, symbols.text, implicitCommands]) {
    for (const key of Object.keys(table)) {
      if (key.startsWith('\\') && WORD.test(key.slice(1))) fromTables.add(key.slice(1));
    }
  }
  const fromText = new Set();
  for (const m of k.text.matchAll(/\\{1,2}([A-Za-z]+)/g)) fromText.add(m[1]);

  const refused = new Set();
  for (const n of fromTables) if (katexRefuses(k.katex, n)) refused.add(n);
  // a table entry KaTeX would accept a \newcommand of: not a name, the tables are not what isDefined reads
  for (const n of fromTables) if (!refused.has(n)) die(`\\${n} is in a table but KaTeX accepts \\newcommand{\\${n}}`);
  for (const n of fromText) {
    if (!fromTables.has(n) && katexRefuses(k.katex, n)) die(`KaTeX refuses \\newcommand{\\${n}} but no table holds it: the tables were not read completely`);
  }
  return [...refused].sort();
}

// ---- 2. the names LaTeX defines ----

function latexRun(latex, dir, name, body) {
  const tex = path.join(dir, `${name}.tex`);
  fs.writeFileSync(tex, body);
  const r = spawnSync(latex, ['-interaction=nonstopmode', '-no-shell-escape', '-output-directory', dir, tex], {
    cwd: dir, encoding: 'utf8', timeout: 300000, stdio: ['ignore', 'pipe', 'pipe'],
  });
  if (r.error) die(`cannot run ${latex}: ${r.error.message}`);
  const log = path.join(dir, `${name}.log`);
  return { rc: r.status, out: r.stdout, log: fs.existsSync(log) ? fs.readFileSync(log, 'utf8') : '' };
}

const PREAMBLE = '\\documentclass{article}\n\\usepackage{amsmath,amssymb}\n';

function latexDefined(latex, dir, names) {
  const probes = names.map(n => `\\probe{${n}}`).join('\n');
  const body = `${PREAMBLE}\\makeatletter
\\newwrite\\jnvout
\\immediate\\openout\\jnvout=probe.out
\\def\\@notdefinable{\\immediate\\write\\jnvout{N \\reserved@a}}
\\def\\probe#1{\\expandafter\\@ifdefinable\\csname #1\\endcsname{\\immediate\\write\\jnvout{D #1}}}
\\begin{document}
${probes}
\\immediate\\closeout\\jnvout
\\end{document}
`;
  const r = latexRun(latex, dir, 'probe', body);
  const outFile = path.join(dir, 'probe.out');
  if (!fs.existsSync(outFile)) die(`the LaTeX probe wrote nothing (rc ${r.rc}); see ${path.join(dir, 'probe.log')}`);
  const defined = new Set();
  const free = new Set();
  for (const line of fs.readFileSync(outFile, 'utf8').split('\n')) {
    const m = /^([ND]) (\S+)$/.exec(line.trim());
    if (!m) continue;
    (m[1] === 'N' ? defined : free).add(m[2]);
  }
  for (const n of names) if (defined.has(n) === free.has(n)) die(`the LaTeX probe gave no single answer for \\${n}`);
  return defined;
}

// The real \newcommand for each name: the set must be accepted, every other name KaTeX knows refused. TeX stops a
// run after 100 errors, so the names go through in batches that cannot reach that.
function verifyWithNewcommand(latex, dir, all, set) {
  const BATCH = 90;
  const wrong = [];
  for (let from = 0; from < all.length; from += BATCH) {
    const batch = all.slice(from, from + BATCH);
    const body = `${PREAMBLE}\\begin{document}\n${batch.map(n => `\\newcommand{\\${n}}{x}`).join('\n')}\n\\end{document}\n`;
    const r = latexRun(latex, dir, 'verify', body);
    const refused = new Set();
    for (const m of r.log.matchAll(/LaTeX Error: Command \\([A-Za-z]+) already defined/g)) refused.add(m[1]);
    const errors = (r.log.match(/^! /gm) || []).length;
    // names beginning with "end" or equal to "relax" are refused for another reason; none is expected
    if (errors !== refused.size) die(`LaTeX reported ${errors - refused.size} other errors in the \\newcommand run; see ${path.join(dir, 'verify.log')}`);
    for (const n of batch) if (set.has(n) === refused.has(n)) wrong.push(n);
  }
  if (wrong.length) die(`the real \\newcommand disagrees with the probe for: ${wrong.join(' ')}`);
}

// ---- the files ----

// The first line `latex --version` prints, or why it cannot run.
function latexBanner(latex) {
  const v = spawnSync(latex, ['--version'], { encoding: 'utf8', timeout: 60000 });
  if (v.error) return { why: v.error.message };
  if (v.status !== 0) return { why: `exit status ${v.status}` };
  return { banner: (v.stdout || '').split('\n')[0].trim() };
}

// KaTeX's half (the names it refuses) and, when LaTeX runs, the set of those LaTeX does not define. `needLatex`:
// stop with a message when it cannot run (the names mode) instead of returning without the set.
async function gather(katexDir, latex, needLatex) {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'jnv-katex-only-'));
  try {
    const k = await loadKatex(katexDir, tmp);
    const all = katexNames(k);
    const lv = latexBanner(latex);
    if (lv.why) {
      if (needLatex) die(`cannot run ${latex} --version (${lv.why}): the names mode needs LaTeX with amsmath and amssymb`);
      return { version: k.version, all, set: null, banner: null, latex, why: lv.why };
    }
    const inLatex = latexDefined(latex, tmp, all);
    const set = new Set(all.filter(n => !inLatex.has(n)));
    verifyWithNewcommand(latex, tmp, all, set);
    return { version: k.version, all, set, banner: lv.banner, latex, why: null };
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
}

function render(g) {
  const head = [
    '# The control words KaTeX predefines that LaTeX (amsmath, amssymb) does not',
    '# define: the names the KaTeX \\newcommand rule passes as \\renewcommand',
    '# (deviation D5). Generated by gen_katex_only.mjs; do not edit.',
    `# katex ${g.version}`,
    `# latex ${g.banner}`,
    `# katex-names ${g.all.length}`,
  ];
  return `${head.join('\n')}\n${[...g.set].sort().join('\n')}\n`;
}

// The `# katex`, `# latex` and `# katex-names` header lines of a katex_only.txt.
function header(text) {
  const h = {};
  for (const line of text.split('\n')) {
    const m = /^# (katex-names|katex|latex) (.*)$/.exec(line);
    if (m) h[m[1]] = m[2];
  }
  return h;
}

async function check(katexDir, latex) {
  const text = fs.readFileSync(COMMITTED, 'utf8');
  const committed = parseNames(text);
  const h = header(text);
  const g = await gather(katexDir, latex, false);
  const stale = 'regenerate it with "names"';
  if (g.version !== h.katex) die(`katex_only.txt is for KaTeX ${h.katex}, the package is ${g.version}; ${stale}`);
  if (String(g.all.length) !== h['katex-names']) die(`katex_only.txt says KaTeX refuses ${h['katex-names']} names, it refuses ${g.all.length} now; ${stale}`);
  if (g.set === null) {
    process.stdout.write(`note: no LaTeX (${g.latex}); the LaTeX half of katex_only.txt was not checked\n`);
    process.stdout.write(`katex_only.txt matches KaTeX ${g.version} (${g.all.length} predefined names; ${committed.length} listed, not compared with LaTeX)\n`);
    return;
  }
  const now = [...g.set].sort();
  if (JSON.stringify(now) !== JSON.stringify(committed)) {
    const was = new Set(committed);
    const is = new Set(now);
    const added = now.filter(n => !was.has(n));
    const gone = committed.filter(n => !is.has(n));
    die(`katex_only.txt is not what KaTeX and LaTeX give now (${added.length} new: ${added.slice(0, 8).join(' ')}; ${gone.length} gone: ${gone.slice(0, 8).join(' ')}); ${stale}`);
  }
  if (g.banner !== h.latex) process.stdout.write(`note: LaTeX banner differs (committed: ${h.latex}, here: ${g.banner}); the names agree\n`);
  process.stdout.write(`katex_only.txt matches KaTeX and LaTeX (${committed.length} names)\n`);
}

function rust(text) {
  const list = parseNames(text);
  const head = text.split('\n').filter(l => l.startsWith('#')).map(l => `// ${l.slice(2)}`
    .replace('Generated by gen_katex_only.mjs; do not edit.', 'Generated from katex_only.txt; do not edit.'));
  const rows = [];
  let row = '   ';
  for (const n of list) {
    const item = ` "${n}",`;
    if (row.length + item.length > 78) { rows.push(row); row = '   '; }
    row += item;
  }
  if (row.trim()) rows.push(row);
  return `${head.join('\n')}

/// The names KaTeX predefines that LaTeX does not, sorted for a search.
#[rustfmt::skip]
pub const KATEX_ONLY: &[&str] = &[
${rows.join('\n')}
];
`;
}

// ---- main ----

const [mode, a, b] = process.argv.slice(2);
if (mode === 'names' || mode === 'check') {
  if (!a) die('usage: gen_katex_only.mjs names|check <katex-package-dir> [latex-binary]');
  if (mode === 'names') process.stdout.write(render(await gather(a, b || 'latex', true)));
  else await check(a, b || 'latex');
} else if (mode === 'rust') {
  process.stdout.write(rust(fs.readFileSync(0, 'utf8')));
} else {
  die('usage: gen_katex_only.mjs names|check <katex-package-dir> [latex-binary] | rust');
}
