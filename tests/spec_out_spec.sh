#!/usr/bin/env bash
# spec_out, the function run_all.sh hands every headless spec's output to,
# taken from the file that defines it and run on made-up spec outputs: what
# it prints and what it keeps. A failed headless spec must name its failing
# checks in the suite's output (its FAIL lines, or its last lines when it
# stopped before any), and its whole output must be kept in the run dir and,
# with JNV_SPEC_LOGS, beside it. Without this check a rewrite of run_all.sh
# could drop that and the suite would only say which spec failed.
#
#   bash tests/spec_out_spec.sh
set -u
source "$(dirname "$0")/lib/test_env.sh"
ROOT="$JNV_REPO"
# a suite run with JNV_SPEC_LOGS set must not get these made-up outputs
unset JNV_SPEC_LOGS

src=""
for f in "$ROOT/tests/run_all.sh" "$ROOT"/tests/lib/*.sh; do
  if [ -f "$f" ] && grep -q '^spec_out() {$' "$f"; then src="$f"; break; fi
done
if [ -z "$src" ]; then
  echo "FAIL no spec_out() in tests/run_all.sh or tests/lib/*.sh"
  exit 1
fi
echo "spec_out() from ${src#"$ROOT"/}"
eval "$(sed -n '/^spec_out() {$/,/^}$/p' "$src")"

# inside the run dir, which test_env.sh removes
D="$(mktemp -d "$TMPDIR/specout.XXXXXX")" || { echo "FAIL mktemp"; exit 1; }
fails=0
chk() { if [ "$2" = 0 ]; then echo "  ok $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }

pass_out=$(printf '%s\n' "-- A" "  ok A1 one" "" "ALL X CHECKS PASSED")
got=$(JNV_RUN_ROOT="$D" spec_out passing 0 "$pass_out")
[ "$got" = "ALL X CHECKS PASSED" ]; chk "a passing spec shows its last line only" $?
cmp -s <(printf '%s\n' "$pass_out") "$D/specs/passing.log"; chk "and its whole output is kept in specs/passing.log" $?

fail_out=$(printf '%s\n' "  ok A1 one" "FAIL D6 submit on the UI thread p99 under 20 us  -- run1 p99 21 us" "  ok D7" \
  "FAIL: H2 named" "" "NATIVE: 2 CHECK(S) FAILED")
got=$(JNV_RUN_ROOT="$D" spec_out failing 1 "$fail_out")
want=$(printf '%s\n' "FAIL D6 submit on the UI thread p99 under 20 us  -- run1 p99 21 us" "FAIL: H2 named" \
  "NATIVE: 2 CHECK(S) FAILED")
[ "$got" = "$want" ]; chk "a failing spec shows its FAIL lines, then its last line" $?
cmp -s <(printf '%s\n' "$fail_out") "$D/specs/failing.log"; chk "and its whole output is kept" $?

crash_out=$(for i in $(seq 1 30); do echo "line $i"; done; echo "E5113: Error while calling lua chunk: x.lua:3: boom")
got=$(JNV_RUN_ROOT="$D" spec_out crashed 3 "$crash_out")
want=$(printf '%s\n' "$crash_out" | tail -n 15)
[ "$got" = "$want" ]; chk "a spec that stopped before any FAIL line shows its last 15 lines" $?
[ ! -e "$D/keep" ]; chk "without JNV_SPEC_LOGS nothing is written outside the run dir" $?

got=$(JNV_RUN_ROOT="$D" JNV_SPEC_LOGS="$D/keep" JNV_RUN_ID=abc spec_out kept 0 "$pass_out")
[ "$got" = "ALL X CHECKS PASSED" ]; chk "with JNV_SPEC_LOGS a spec still shows its last line" $?
cmp -s <(printf '%s\n' "$pass_out") "$D/keep/abc/kept.log"; chk "and its output is also kept in JNV_SPEC_LOGS/<run id>/kept.log" $?
cmp -s <(printf '%s\n' "$pass_out") "$D/specs/kept.log"; chk "and in the run dir" $?

if [ "$fails" = 0 ]; then
  echo "ALL SPEC_OUT CHECKS PASSED"
  exit 0
fi
echo "$fails SPEC_OUT CHECKS FAILED"
exit 1
