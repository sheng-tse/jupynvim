# Markdown fixtures

Shared inputs for the markdown work (the math grammar, the markdown file view, the notebook cell renderer). One copy lives here; tests read it from this folder and never duplicate it.

- `md-fixture.md`: one section per markdown construct (headings of every level and edge case, emphasis, lists, tables, quotes, code, links, math in every delimiter, and so on).
- `md-fixture.ipynb`: the same content split into 31 markdown cells of a notebook (and no other cells). Cell 27 defines the macros `\RR`, `\norm` and `\abs` and cell 28 uses them, so a renderer has to carry macros from one cell to the next. The file and the notebook hold 135 maths each.
- `hero.md`, `hero.ipynb`: a short sample without math (a heading, a callout, a task list, a table, a code block) as a file and as a notebook with one markdown cell.
- `gauss.md`, `gauss.ipynb`: a short sample with one display math and one inline math, as a file and as a notebook with one markdown cell.
- `math_battery_cases.json`: 82 one-line math cases as `[name, source]` pairs, each probing one rule of the math grammar (what opens and closes inline math, escaped dollars, the delimiters, environments, code that is never scanned).

The math grammar tests read these files in place: `tests/mathgrammar/golden/fixtures.cases` and `battery.cases` are generated from them (see `tests/mathgrammar/README.md`), and `core/native/tests/math_grammar_perf.rs` times the grammar on `md-fixture.md`. A test of the markdown work reads this folder and does not copy the files.

The files are copies of the reference inputs and must stay byte for byte identical. A change needs the golden files regenerated and the lines below updated:

```
md-fixture.md sha256 3977a14676ab9ed819faa76ae15793c98164a7f3afba5eb30e292a87212a77c7
md-fixture.ipynb sha256 d4a3a8f13fe0207f1da798a2e417227ca34ddcb9ef5dc637d666ca84ad2186e6
hero.md sha256 6ff06d9f161895d5bd7ae8478fe8f579e532af8bc23614329a2486a9e2aa8d74
hero.ipynb sha256 b3adbd3a9db1402ad31382537e1a9223202d30b46b2d5c32c476a0c87c393f43
gauss.md sha256 e8bda2cb3fc9bef97b1ad342738c46d84e49169cbd68fc22346a66056518d2c9
gauss.ipynb sha256 c7b2f120affd2404bf4d911f0682a7a17244d1b9bbbb9a15591f7a9f9b454488
math_battery_cases.json sha256 68501f4c1e4d1a075248aa6b847e7d70ea076ba9738530700712b4401a3b12c2
```
