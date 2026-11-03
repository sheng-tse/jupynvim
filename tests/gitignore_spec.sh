#!/usr/bin/env bash
# What the repo's .gitignore keeps out of git, checked in a scratch git repo
# that has only that file. The sources of the fake libraries the native tests
# load (core/native/examples/) must be tracked: without them a fresh clone or
# CI cannot run cargo test. The top-level examples/ playground, where people
# drop their own notebooks, and the build output must stay ignored.
#
#   bash tests/gitignore_spec.sh
set -u
source "$(dirname "$0")/lib/test_env.sh"
ROOT="$JNV_REPO"

# inside the run dir, which test_env.sh removes too
D="$(mktemp -d "$TMPDIR/jnv_gitignore.XXXXXX")" || { echo "FAIL mktemp"; exit 1; }
cleanup() { rm -rf "$D"; }
jnv_on_exit cleanup

# Only the repo's .gitignore may decide: no global or system git config, so
# no excludes file of the person running the suite takes part.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

git init -q "$D" || { echo "FAIL git init"; exit 1; }
cp "$ROOT/.gitignore" "$D/.gitignore" || { echo "FAIL copy .gitignore"; exit 1; }
mkdir -p "$D/core/native/examples" "$D/examples" "$D/core/target"
: > "$D/core/native/examples/jnv_fake.rs"
: > "$D/examples/demo.ipynb"
: > "$D/core/target/x"

fails=0
# check-ignore -q exits 0 when the path is ignored, 1 when it is not
chk_ignored() {
  local name="$1" path="$2" want="$3" rc
  git -C "$D" check-ignore -q "$path"
  rc=$?
  if [ "$rc" = "$want" ]; then
    echo "ok $name"
  else
    echo "FAIL $name (git check-ignore $path exited $rc, wanted $want)"
    fails=$((fails + 1))
  fi
}

chk_ignored "core/native/examples/jnv_fake.rs is tracked" core/native/examples/jnv_fake.rs 1
chk_ignored "the top-level examples playground stays ignored" examples/demo.ipynb 0
chk_ignored "build output stays ignored" core/target/x 0

if [ "$fails" = 0 ]; then
  echo "ALL GITIGNORE CHECKS PASSED"
  exit 0
fi
echo "$fails GITIGNORE CHECKS FAILED"
exit 1
