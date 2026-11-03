// One math grammar for both layouts. Math is pulled out of the markdown source before any markdown parsing, so the
// TeX is never touched by markdown (escapes, emphasis, HTML and links inside math stay TeX).
//
//   $$...$$                  display (own lines or mid-paragraph); no blank line inside
//   $...$                    inline, pandoc's rule: the opener is not followed by whitespace, the closer is not
//                            preceded by whitespace and not followed by a digit; the first $ after the opener ends
//                            the attempt; a single line break is allowed, a blank line is not
//   $`...`$                  inline (backtick form)
//   \(...\)  \[...\]         inline / display
//   \begin{env}...\end{env}  display (bare environment, matching nesting)
//   ```math / ~~~math        display (any case of "math")
//   \$                       a literal dollar outside math; inside math it is TeX's \$
// Code spans, fenced code blocks, indented code blocks, HTML comments and HTML tags are never scanned.
// Every $ that does not form math is escaped as \$ so no later markdown processor can pair it.
//
// extractMath(src) -> { text, maths: [{ tex, display, block, kind }] } where text carries placeholders
//   ZZMTH0001ZZ (inline) or ZZDMTH0001ZZ (display); `block` = the display math stands alone on its lines.
// prepareTex(maths) -> AMS numbering for both renderers: numbered environments become starred ones with explicit
//   \tag{n} per row (\nonumber/\notag respected, \tag kept), \label removed, \eqref/\ref resolved (also forward).

const PUNCT = /[!-/:-@[-`{-~]/;
const isWS = c => c === ' ' || c === '\t' || c === '\n';
const pad = n => String(n).padStart(4, '0');

export function placeholder(i, display) { return (display ? 'ZZDMTH' : 'ZZMTH') + pad(i) + 'ZZ'; }

// strip blockquote / list container prefixes from continuation lines of multi-line math
function cleanTex(t) { return t.replace(/\n[ \t]*(?:>[ \t]?)*/g, '\n').trim(); }

export function extractMath(src) {
  src = src.replace(/\r\n?/g, '\n');
  const lines = src.split('\n');
  const maths = [];
  const out = [];
  // ---- block pass: fenced code, math fences, indented code ----
  const segs = []; // {type: 'text'|'code'|'mathfence', lines: [...], prefix}
  let i = 0, inListRecently = false, prevBlank = true;
  const pushText = l => { const s = segs[segs.length - 1]; if (s && s.type === 'text') s.lines.push(l); else segs.push({ type: 'text', lines: [l] }); };
  while (i < lines.length) {
    const line = lines[i];
    const m = line.match(/^((?:[ \t]{0,3}>[ \t]?)*)([ \t]*)(`{3,}|~{3,})(.*)$/);
    if (m && m[2].length <= 3 && !(m[3][0] === '`' && m[4].includes('`'))) {
      const prefix = m[1], fence = m[3], info = m[4].trim();
      const body = []; let j = i + 1, closed = false;
      while (j < lines.length) {
        const l = lines[j].replace(/^(?:[ \t]{0,3}>[ \t]?)*/, '');
        const c = l.match(/^[ \t]{0,3}(`{3,}|~{3,})[ \t]*$/);
        if (c && c[1][0] === fence[0] && c[1].length >= fence.length) { closed = true; break; }
        body.push(lines[j]); j++;
      }
      const all = lines.slice(i, closed ? j + 1 : j);
      if (/^math$/i.test(info)) segs.push({ type: 'mathfence', prefix, raw: all.join('\n'), tex: body.map(l => l.replace(/^(?:[ \t]{0,3}>[ \t]?)*/, '')).join('\n') });
      else segs.push({ type: 'code', lines: all });
      i = closed ? j + 1 : j; prevBlank = false; continue;
    }
    // indented code block: 4+ spaces after a blank line, not continuing a list
    if (/^( {4}|\t)/.test(line) && line.trim() && prevBlank && !inListRecently) {
      const all = []; let j = i;
      while (j < lines.length && (/^( {4}|\t)/.test(lines[j]) || !lines[j].trim())) { all.push(lines[j]); j++; }
      while (all.length && !all[all.length - 1].trim()) { all.pop(); j--; }
      segs.push({ type: 'code', lines: all }); i = j; prevBlank = false; continue;
    }
    if (!line.trim()) { prevBlank = true; pushText(line); i++; continue; }
    if (/^[ \t]{0,3}([-*+]|\d{1,9}[.)])([ \t]|$)/.test(line)) inListRecently = true;
    else if (!/^[ \t]/.test(line) && prevBlank) inListRecently = false;
    prevBlank = false; pushText(line); i++;
  }
  // ---- inline pass over text segments ----
  for (const seg of segs) {
    if (seg.type === 'code') { out.push(seg.lines.join('\n')); continue; }
    if (seg.type === 'mathfence') { maths.push({ tex: seg.tex.trim(), display: true, block: true, kind: 'fence', raw: seg.raw }); out.push(seg.prefix + placeholder(maths.length, true)); continue; }
    out.push(scanText(seg.lines.join('\n'), maths));
  }
  return { text: out.join('\n'), maths };
}

function lineIsOnlyAround(s, start, end) {
  // the math span [start, end) stands alone on its line(s): only container prefix before, only spaces after
  const ls = s.lastIndexOf('\n', start - 1) + 1;
  const before = s.slice(ls, start);
  let le = s.indexOf('\n', end); if (le < 0) le = s.length;
  const after = s.slice(end, le);
  return /^(?:[ \t]{0,3}>[ \t]?)*[ \t]*$/.test(before) && /^[ \t]*$/.test(after);
}

function scanText(s, maths) {
  let o = '', k = 0;
  const n = s.length;
  const add = (tex, display, kind, start, end) => {
    maths.push({ tex: cleanTex(tex), display, block: display && lineIsOnlyAround(s, start, end), kind, raw: s.slice(start, end) });
    return placeholder(maths.length, display);
  };
  while (k < n) {
    const c = s[k];
    // HTML comment / tag: copy verbatim
    if (c === '<') {
      if (s.startsWith('<!--', k)) { const e = s.indexOf('-->', k + 4); const stop = e < 0 ? n : e + 3; o += s.slice(k, stop); k = stop; continue; }
      const t = s.slice(k).match(/^<\/?[A-Za-z][A-Za-z0-9-]*(?:\s+[^<>]*)?\/?>|^<[A-Za-z][A-Za-z0-9+.-]*:[^\s<>]*>/);
      if (t) { o += t[0]; k += t[0].length; continue; }
    }
    // backslash: escapes, \( \[ \begin
    if (c === '\\') {
      const d = s[k + 1];
      // doubled delimiters \\( \\) and \\[ \\] (the classic Jupyter notebook form, as JupyterLab reads it)
      if (d === '\\' && (s[k + 2] === '(' || s[k + 2] === '[')) {
        const close = s[k + 2] === '(' ? '\\\\)' : '\\\\]';
        const e = s.indexOf(close, k + 3);
        if (e > 0 && !/\n[ \t]*(?:>[ \t]?)*\n/.test(s.slice(k, e))) { o += add(s.slice(k + 3, e), s[k + 2] === '[', 'doubled', k, e + 3); k = e + 3; continue; }
      }
      if (d === '(' || d === '[') {
        const close = d === '(' ? ')' : ']';
        let j = k + 2, found = -1;
        while (j < n) {
          if (s[j] === '\n' && s[j + 1] === '\n') break;
          if (s[j] === '\\' && s[j + 1] === close) { found = j; break; }
          if (s[j] === '\\') { j += 2; continue; }
          j++;
        }
        if (found >= 0) { o += add(s.slice(k + 2, found), d === '[', d === '(' ? 'paren' : 'bracket', k, found + 2); k = found + 2; continue; }
      }
      if (s.startsWith('\\begin{', k)) {
        const nm = s.slice(k).match(/^\\begin\{([A-Za-z*]+)\}/);
        if (nm) {
          const name = nm[1]; let depth = 0, j = k, found = -1;
          const re = new RegExp('\\\\(begin|end)\\{' + name.replace('*', '\\*') + '\\}', 'g'); re.lastIndex = k;
          let mm;
          while ((mm = re.exec(s))) { if (mm[1] === 'begin') depth++; else { depth--; if (depth === 0) { found = mm.index + mm[0].length; break; } } }
          if (found > 0 && !/\n[ \t]*(?:>[ \t]?)*\n/.test(s.slice(k, found))) { o += add(s.slice(k, found), true, 'env', k, found); k = found; continue; }
        }
      }
      if (d !== undefined && PUNCT.test(d)) { o += c + d; k += 2; continue; }
      o += c; k++; continue;
    }
    // code span (and the $`...`$ backtick form)
    if (c === '`') {
      let r = k; while (s[r] === '`') r++;
      const run = r - k;
      let j = r, close = -1;
      while (j < n) {
        if (s[j] === '`') { let e = j; while (s[e] === '`') e++; if (e - j === run) { close = j; break; } j = e; continue; }
        if (s[j] === '\n' && s[j + 1] === '\n') break;
        j++;
      }
      if (close < 0) { o += s.slice(k, r); k = r; continue; }
      const end = close + run;
      o += s.slice(k, end); k = end; continue;
    }
    if (c === '$') {
      // backtick form $`...`$
      if (s[k + 1] === '`') {
        let r = k + 1; while (s[r] === '`') r++;
        const run = r - k - 1;
        let j = r, close = -1;
        while (j < n) {
          if (s[j] === '`') { let e = j; while (s[e] === '`') e++; if (e - j === run) { close = j; break; } j = e; continue; }
          if (s[j] === '\n' && s[j + 1] === '\n') break;
          j++;
        }
        if (close >= 0 && s[close + run] === '$') {
          let inner = s.slice(r, close).replace(/\n/g, ' ');
          if (inner.length > 1 && inner[0] === ' ' && inner[inner.length - 1] === ' ' && inner.trim()) inner = inner.slice(1, -1);
          maths.push({ tex: inner, display: false, block: false, kind: 'backtick', raw: s.slice(k, close + run + 1) });
          o += placeholder(maths.length, false); k = close + run + 1; continue;
        }
      }
      // display $$...$$
      if (s[k + 1] === '$') {
        let j = k + 2, found = -1;
        while (j < n) {
          if (s[j] === '\n' && /^\n[ \t]*(?:>[ \t]?)*[ \t]*\n/.test(s.slice(j))) break;
          if (s[j] === '\\') { j += 2; continue; }
          if (s[j] === '$' && s[j + 1] === '$') { found = j; break; }
          j++;
        }
        if (found >= 0 && s.slice(k + 2, found).trim()) { o += add(s.slice(k + 2, found), true, 'dollars', k, found + 2); k = found + 2; continue; }
      }
      // inline $...$ (pandoc)
      const r = inlineDollar(s, k);
      if (r) { o += add(s.slice(k + 1, r), false, 'dollar', k, r + 1); k = r + 1; continue; }
      o += '\\$'; k++; continue;
    }
    o += c; k++;
  }
  return o;
}

// returns the index of the closing $ or -1 / null
function inlineDollar(s, k) {
  const n = s.length;
  let j = k + 1;
  if (j >= n || isWS(s[j])) return null;
  // first content character is always consumed (pandoc many1Till), a backslash takes the next char with it
  if (s[j] === '\\') j += 2; else j += 1;
  while (j < n) {
    const c = s[j];
    if (c === '$') return /[0-9]/.test(s[j + 1] || '') ? null : j;
    if (c === '\\') { j += 2; continue; }
    if (isWS(c)) {
      let e = j, nl = 0;
      while (e < n && isWS(s[e])) { if (s[e] === '\n') nl++; e++; }
      if (nl >= 2) return null;
      if (nl === 1 && /^\n[ \t]*(?:>[ \t]?)*[ \t]*\n/.test(s.slice(j))) return null;
      if (s[e] === '$') return null;
      j = e; continue;
    }
    j++;
  }
  return null;
}

// ---------- AMS numbering, labels and references (shared by KaTeX and MathJax) ----------
const NUMBERED = { equation: 'single', align: 'rows', gather: 'rows', flalign: 'rows', alignat: 'rows', eqnarray: 'rows', multline: 'last' };
const STARRED = { equation: 'equation*', align: 'align*', gather: 'gather*', flalign: 'flalign*', alignat: 'alignat*', eqnarray: 'align*', multline: 'gather*' };

function splitRows(body) {
  // split on top-level \\ (not inside braces or nested environments)
  const rows = []; let depth = 0, env = 0, last = 0;
  for (let i = 0; i < body.length; i++) {
    const c = body[i];
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

export function prepareTex(maths) {
  const labels = {};
  let eq = 0;
  const pass1 = maths.map(m => {
    let t = m.tex;
    if (!m.display) return t;
    const env = t.match(/^\\begin\{([A-Za-z]+)(\*?)\}([\s\S]*)\\end\{\1\2\}$/);
    if (env && NUMBERED[env[1]] && !env[2]) {
      const name = env[1], mode = NUMBERED[name];
      let body = env[3];
      let rows = mode === 'single' ? [body] : splitRows(body);
      if (rows.length > 1 && !rows[rows.length - 1].trim()) rows.pop();
      rows = rows.map((row, ri) => {
        let tag = null; const lab = [];
        row = row.replace(/\\label\{([^}]*)\}/g, (_, k2) => { lab.push(k2); return ''; });
        const tg = row.match(/\\tag\*?\{([^}]*)\}/); if (tg) tag = tg[1];
        const skip = /\\(nonumber|notag)\b/.test(row) || (mode === 'last' && ri !== rows.length - 1);
        row = row.replace(/\\(nonumber|notag)\b/g, '');
        if (!tag && !skip) { tag = String(++eq); row += ` \\tag{${tag}}`; }
        for (const k2 of lab) labels[k2] = tag;
        return row;
      });
      return `\\begin{${STARRED[name]}}${rows.join(' \\\\ ')}\\end{${STARRED[name]}}`;
    }
    // unnumbered display: a \label only refers to an explicit \tag
    const tg = t.match(/\\tag\*?\{([^}]*)\}/);
    t = t.replace(/\\label\{([^}]*)\}/g, (_, k2) => { if (tg) labels[k2] = tg[1]; return ''; });
    return t;
  });
  return pass1.map(t => t
    .replace(/\\eqref\{([^}]*)\}/g, (_, k2) => `\\text{(${labels[k2] ?? '??'})}`)
    .replace(/\\ref\{([^}]*)\}/g, (_, k2) => `\\text{${labels[k2] ?? '??'}}`)
    .replace(/\\label\{([^}]*)\}/g, ''));
}

export function escapeHtml(s) { return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;'); }
