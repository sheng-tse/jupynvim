// KaTeX predefines a few names that LaTeX does not (\R, \N, ...); a document's first \newcommand of one of them is
// legal LaTeX, so it is passed to KaTeX as \renewcommand
export const KATEX_ONLY = new Set(['R', 'N', 'Z', 'C', 'Q', 'Reals', 'reals', 'natnums', 'Complex', 'cnums']);
export function latexNewcommand(t, defined) {
  return t.replace(/\\newcommand\s*(\{\s*)?\\([A-Za-z]+)/g, (all, brace, name) => {
    if (KATEX_ONLY.has(name) && !defined.has(name)) { defined.add(name); return all.replace('newcommand', 'renewcommand'); }
    defined.add(name); return all;
  });
}
