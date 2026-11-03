#!/usr/bin/env bash
# The isolation audit's rules for the files that are not shell, Lua or Python
# tests: the .mjs, .cjs and .js helpers under tests/, and the Rust files of the
# native library (core/native). The audit is run on small made-up trees, each
# holding a minimal suite (a run_all.sh that runs one top-level test) and the
# files of one case, and what it reports is compared with what it should.
#
#   R1  a fixed temp path in a helper under tests/, in core/native/src, in
#       core/native/tests, core/native/examples, core/native/build.rs and the C
#       checks under tests/; also written as a prefixed string literal
#       (b"..", rb"..", f"..") or as string pieces joined with + in JavaScript
#   R5  the local notes dir named in a file under core/native
#   R7  a helper in a subdirectory of tests/ that no top-level test (shell,
#       Python or Lua) names on a code line (a name in a comment, or inside a
#       longer name, is not one); a top-level .mjs, .cjs or .js test that
#       tests/run_all.sh does not run
#
# Without these rules a helper or a Rust file could hold a path the suite
# must never use, or be left out of the suite, and the audit would pass.
#
#   bash tests/audit_rules_spec.sh
set -u
source "$(dirname "$0")/lib/test_env.sh"
ROOT="$JNV_REPO"
AUDIT="$ROOT/tests/isolation_audit.py"

# The fixed temp path and the notes dir's name are what the audit forbids, so
# this file builds them from pieces and never spells them out.
t="/"; t="${t}tmp"
n=".cl"; n="${n}aude"

fails=0
# chk NAME RC [DETAIL]: one result line; a failure carries its detail.
chk() {
  if [ "$2" = 0 ]; then
    echo "  ok $1"
  else
    echo "FAIL $1${3:+  -- $3}"
    fails=$((fails + 1))
  fi
}

if ! command -v python3 >/dev/null 2>&1; then
  echo "FAIL python3 is not installed (the audit is a python3 script)"
  exit 1
fi
if [ ! -f "$AUDIT" ]; then
  echo "FAIL tests/isolation_audit.py is missing"
  exit 1
fi

# mk_tree: a minimal tree the audit finds clean, its path on stdout. Inside
# the run dir, which test_env.sh removes. tests/run_all.sh runs one top-level
# test, tests/x_spec.sh; both source the per-run env, as R4 asks.
mk_tree() {
  local d
  d="$(mktemp -d "$TMPDIR/jnv_auditrules.XXXXXX")" || return 1
  mkdir -p "$d/tests/lib" "$d/tests/sub" "$d/core/native/src" "$d/core/native/tests"
  printf '%s\n' '# the per-run env' > "$d/tests/lib/test_env.sh"
  printf '%s\n' 'source "$(dirname "$0")/lib/test_env.sh"' \
    'bash "$ROOT/tests/x_spec.sh"' > "$d/tests/run_all.sh"
  printf '%s\n' 'source "$(dirname "$0")/lib/test_env.sh"' \
    'echo run' > "$d/tests/x_spec.sh"
  printf '%s' "$d"
}

# a tree that could not be made ends the run: the next lines would write to
# paths under an empty directory name
tree_failed() {
  echo "FAIL could not make a tree for the audit to read (mktemp under $TMPDIR)"
  exit 1
}

# add_line FILE LINE: append one line
add_line() { printf '%s\n' "$2" >> "$1"; }

# run_audit TREE: OUT is the audit's output, RC its exit status
run_audit() {
  OUT="$(python3 -I "$AUDIT" "$1" 2>&1)"
  RC=$?
}

# violations: "RULE path" of every violation the audit printed, sorted
violations() {
  printf '%s\n' "$OUT" | sed -n 's/^\(R[0-9]*-[a-z0-9-]*\) \([^:]*\):[0-9]*: .*$/\1 \2/p' | sort
}

# check NAME WANT...: the audit named exactly the WANT violations ("RULE path"
# each; none for a clean tree), stopped the way it should and ran its own
# probes without complaint
check() {
  local name="$1" got last why="" want="" cnt=0 w
  shift
  for w in "$@"; do
    want="${want}${w}"$'\n'
    cnt=$((cnt + 1))
  done
  want="$(printf '%s' "$want" | sort)"
  got="$(violations)"
  last="$(printf '%s\n' "$OUT" | tail -n 1)"
  if [ "$got" != "$want" ]; then
    why="violations: got [$(printf '%s' "$got" | tr '\n' ',')] want [$(printf '%s' "$want" | tr '\n' ',')];"
  fi
  if [ "$cnt" = 0 ]; then
    [ "$RC" = 0 ] && [ "$last" = "ALL ISOLATION AUDIT CHECKS PASSED" ] \
      || why="$why exit $RC, last line [$last];"
  else
    [ "$RC" = 1 ] && [ "$last" = "$cnt ISOLATION AUDIT VIOLATIONS" ] \
      || why="$why exit $RC, last line [$last];"
  fi
  if printf '%s\n' "$OUT" | grep -q '^SELF-TEST'; then
    why="$why the audit's own probes failed;"
  fi
  [ -z "$why" ]
  chk "$name" $? "${why# }"
}

# 1. R1 reads a helper under tests/
d="$(mk_tree)" || tree_failed
printf 'const p = "%s/x";\n' "$t" > "$d/tests/sub/helper.mjs"
add_line "$d/tests/x_spec.sh" 'node "$ROOT/tests/sub/helper.mjs"'
run_audit "$d"
check "R1 reads a .mjs helper under tests/" "R1-fixed-tmp tests/sub/helper.mjs"

# 2. R1 reads core/native/src
d="$(mk_tree)" || tree_failed
printf 'fn p() -> &'"'"'static str { "%s/x" }\n' "$t" > "$d/core/native/src/a.rs"
run_audit "$d"
check "R1 reads a .rs file under core/native/src" "R1-fixed-tmp core/native/src/a.rs"

# 3. R1 reads core/native/tests
d="$(mk_tree)" || tree_failed
printf 'fn p() -> &'"'"'static str { "%s/x" }\n' "$t" > "$d/core/native/tests/b.rs"
run_audit "$d"
check "R1 reads a .rs file under core/native/tests" "R1-fixed-tmp core/native/tests/b.rs"

# 4. R7 wants a helper named by a top-level test. The only mentions here do
# not count: a comment, and names that merely contain the helper's.
d="$(mk_tree)" || tree_failed
printf '%s\n' 'export const x = 1;' > "$d/tests/sub/lonely.mjs"
add_line "$d/tests/x_spec.sh" '# lonely.mjs is run elsewhere'
add_line "$d/tests/x_spec.sh" 'echo xlonely.mjs lonely.mjs.bak a-lonely.mjs lonely.mjsx'
run_audit "$d"
check "R7 wants a helper under tests/ to be named by a top-level test" "R7-wired tests/sub/lonely.mjs"

# 5. R7 is met once a wired top-level test names the helper on a code line
d="$(mk_tree)" || tree_failed
printf '%s\n' 'export const x = 1;' > "$d/tests/sub/lonely.mjs"
add_line "$d/tests/x_spec.sh" 'node "$ROOT/tests/sub/lonely.mjs"'
run_audit "$d"
check "R7 is met when a top-level test names the helper"

# 6. R5 reads core/native
d="$(mk_tree)" || tree_failed
printf '// see %s/notes.md\n' "$n" > "$d/core/native/src/c.rs"
run_audit "$d"
check "R5 reads a file under core/native" "R5-no-local-notes core/native/src/c.rs"

# 7. a clean tree passes: clean files of every new kind, and the fixed temp
# path and the notes dir in dirs the audit never reads
d="$(mk_tree)" || tree_failed
mkdir -p "$d/tests/node_modules/pkg" "$d/core/native/target/debug"
printf '%s\n' 'export const ok = 1;' > "$d/tests/sub/ok.mjs"
printf '%s\n' 'module.exports = 1;' > "$d/tests/sub/ok.js"
printf '%s\n' 'pub fn ok() {}' > "$d/core/native/src/ok.rs"
printf '%s\n' 'fn ok() {}' > "$d/core/native/tests/ok.rs"
printf 'const p = "%s/x"; // %s\n' "$t" "$n" > "$d/tests/node_modules/pkg/index.js"
printf 'fn p() { let _ = "%s/x"; } // %s\n' "$t" "$n" > "$d/core/native/target/debug/gen.rs"
add_line "$d/tests/x_spec.sh" 'node "$ROOT/tests/sub/ok.mjs" "$ROOT/tests/sub/ok.js"'
run_audit "$d"
check "a clean tree passes"

# 8. R1 reads a prefixed literal, where the prefix hides the quote from the plain rule
d="$(mk_tree)" || tree_failed
printf 'fn p() -> &'"'"'static [u8] { b"%s/x" }\n' "$t" > "$d/core/native/src/d.rs"
run_audit "$d"
check "R1 reads a Rust byte string" "R1-fixed-tmp core/native/src/d.rs"
d="$(mk_tree)" || tree_failed
printf 'p = rb"%s/x"\nq = f"%s/{n}"\n' "$t" "$t" > "$d/tests/sub/e.py"
run_audit "$d"
check "R1 reads Python prefixed strings" "R1-fixed-tmp tests/sub/e.py" "R1-fixed-tmp tests/sub/e.py"
d="$(mk_tree)" || tree_failed
printf 'let p = b"%s" + dir;\nlet q = nb"%s";\nlet r = f"{d}%s/x";\n' "ok" "$t/x" "$t" > "$d/core/native/tests/prefix_ok.rs"
run_audit "$d"
check "R1 lets a longer word or a path that continues a name through" 

# 9. R1 reads string pieces joined with + in a JavaScript helper
d="$(mk_tree)" || tree_failed
printf 'const p = "/" + "%s" + "/x";\n' "${t#/}" > "$d/tests/sub/j.mjs"
add_line "$d/tests/x_spec.sh" 'node "$ROOT/tests/sub/j.mjs"'
run_audit "$d"
check "R1 reads JavaScript string pieces joined with +" "R1-fixed-tmp tests/sub/j.mjs"

# 10. R1 reads the other files of the native library and the C checks
d="$(mk_tree)" || tree_failed
mkdir -p "$d/core/native/examples"
printf 'fn p() -> &'"'"'static str { "%s/x" }\n' "$t" > "$d/core/native/examples/ex.rs"
printf 'fn main() { let _ = "%s/x"; }\n' "$t" > "$d/core/native/build.rs"
printf 'const char *p = "%s/x";\n' "$t" > "$d/tests/sub/abi.c"
run_audit "$d"
check "R1 reads core/native/examples, core/native/build.rs and a C check under tests/" \
  "R1-fixed-tmp core/native/examples/ex.rs" "R1-fixed-tmp core/native/build.rs" "R1-fixed-tmp tests/sub/abi.c"

# 11. R7 is met by a Python or a Lua top-level test that names the helper, and
# is not met by a name in their comments
for lang in py lua; do
  case "$lang" in
    py) run_line='python3 "$ROOT/tests/y_spec.py"'; use='run("tests/sub/lonely.mjs")'; note='# lonely.mjs is run elsewhere' ;;
    lua) run_line='nvim -l "$ROOT/tests/y_spec.lua"'; use='run("tests/sub/lonely.mjs")'; note='-- lonely.mjs is run elsewhere' ;;
  esac
  d="$(mk_tree)" || tree_failed
  printf '%s\n' 'export const x = 1;' > "$d/tests/sub/lonely.mjs"
  add_line "$d/tests/run_all.sh" "$run_line"
  printf '%s\n' "$use" > "$d/tests/y_spec.$lang"
  printf '%s\n' 'source "$(dirname "$0")/lib/test_env.sh"' >> "$d/tests/y_spec.$lang"
  run_audit "$d"
  got11="$(violations)"
  d="$(mk_tree)" || tree_failed
  printf '%s\n' 'export const x = 1;' > "$d/tests/sub/lonely.mjs"
  add_line "$d/tests/run_all.sh" "$run_line"
  printf '%s\n' "$note" > "$d/tests/y_spec.$lang"
  run_audit "$d"
  check "R7 reads a .$lang top-level test: a name in its comment does not count" "R7-wired tests/sub/lonely.mjs"
  # the first tree (the name on a code line) must not have had the R7 violation
  case "$got11" in *R7-wired*) chk "R7 is met when a .$lang top-level test names the helper" 1 "got [$got11]" ;; *) chk "R7 is met when a .$lang top-level test names the helper" 0 ;; esac
done

# 12. R7 wants a top-level .mjs test to be run by run_all.sh
d="$(mk_tree)" || tree_failed
printf '%s\n' 'export const x = 1;' > "$d/tests/lonely_top.mjs"
run_audit "$d"
check "R7 wants a top-level .mjs test to be run by tests/run_all.sh" "R7-wired tests/lonely_top.mjs"
d="$(mk_tree)" || tree_failed
printf '%s\n' 'export const x = 1;' > "$d/tests/wired_top.mjs"
add_line "$d/tests/run_all.sh" 'node "$ROOT/tests/wired_top.mjs"'
run_audit "$d"
check "R7 is met when tests/run_all.sh runs a top-level .mjs test"

# 13. a .cjs node helper is read like a .mjs or .js one: R1 (the plain path and the joined
# pieces) and R7 (a helper under tests/, and a top-level test)
d="$(mk_tree)" || tree_failed
printf 'const p = "%s/x";\n' "$t" > "$d/tests/sub/helper.cjs"
add_line "$d/tests/x_spec.sh" 'node "$ROOT/tests/sub/helper.cjs"'
run_audit "$d"
check "R1 reads a .cjs helper under tests/" "R1-fixed-tmp tests/sub/helper.cjs"
d="$(mk_tree)" || tree_failed
printf 'const p = "/" + "%s" + "/x";\n' "${t#/}" > "$d/tests/sub/joined.cjs"
add_line "$d/tests/x_spec.sh" 'node "$ROOT/tests/sub/joined.cjs"'
run_audit "$d"
check "R1 reads JavaScript string pieces joined with + in a .cjs helper" "R1-fixed-tmp tests/sub/joined.cjs"
d="$(mk_tree)" || tree_failed
printf '%s\n' 'module.exports = 1;' > "$d/tests/sub/lonely.cjs"
add_line "$d/tests/x_spec.sh" '# lonely.cjs is run elsewhere'
run_audit "$d"
check "R7 wants a .cjs helper under tests/ to be named by a top-level test" "R7-wired tests/sub/lonely.cjs"
d="$(mk_tree)" || tree_failed
printf '%s\n' 'module.exports = 1;' > "$d/tests/sub/lonely.cjs"
add_line "$d/tests/x_spec.sh" 'node "$ROOT/tests/sub/lonely.cjs"'
run_audit "$d"
check "R7 is met when a top-level test names the .cjs helper"
d="$(mk_tree)" || tree_failed
printf '%s\n' 'module.exports = 1;' > "$d/tests/lonely_top.cjs"
run_audit "$d"
check "R7 wants a top-level .cjs test to be run by tests/run_all.sh" "R7-wired tests/lonely_top.cjs"
d="$(mk_tree)" || tree_failed
printf '%s\n' 'module.exports = 1;' > "$d/tests/wired_top.cjs"
add_line "$d/tests/run_all.sh" 'node "$ROOT/tests/wired_top.cjs"'
run_audit "$d"
check "R7 is met when tests/run_all.sh runs a top-level .cjs test"

if [ "$fails" = 0 ]; then
  echo "ALL AUDIT RULES CHECKS PASSED"
  exit 0
fi
echo "$fails AUDIT RULES CHECKS FAILED"
exit 1
