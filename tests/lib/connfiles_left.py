#!/usr/bin/env python3
"""List the kernel connection files and backend runtime dirs a test run left.

    python3 -I tests/lib/connfiles_left.py

Run inside a run environment (tests/lib/test_env.sh). A backend removes its
own runtime dir when it exits, and the next start removes what one that did
not exit left, so after a test nothing is left in:

  - $XDG_RUNTIME_DIR/jupynvim, $JUPYTER_RUNTIME_DIR/jupynvim,
    $JUPYTER_DATA_DIR/runtime/jupynvim and $JUPYNVIM_RUNTIME_DIR/jupynvim
    (when set), $TMPDIR/jupynvim-<uid>, and jupynvim-<uid> in the other
    three dirs (the name in a sticky dir others can write to):
    any entry of one of these that exists is left over, and so is one of
    these places itself when it is a symlink (a backend never makes one)
  - $TMPDIR/jupynvim, the old location of connection files: the dir is left
    over when it exists at all, with every entry in it

Each place is read only when it is inside $JNV_RUN_ROOT (real paths; for a
symlink, where the link itself is), so nothing outside the run is ever
listed.

Prints `connection files a test left:` and one line per path (dirs end in /,
symlinks are listed, never followed), exit 1. Nothing left: no output, exit
0. JNV_RUN_ROOT unset or not a dir: exit 2. Standard library only.
"""
import os
import sys


def main():
    run = os.environ.get("JNV_RUN_ROOT", "")
    if not run or not os.path.isdir(run):
        print("connfiles_left: JNV_RUN_ROOT is not a run dir (run inside tests/lib/test_env.sh)",
              file=sys.stderr)
        return 2
    real = os.path.realpath(run)

    def inside_real(rp):
        return rp == real or rp.startswith(real.rstrip(os.sep) + os.sep)

    def inside(p):
        return inside_real(os.path.realpath(p))

    def link_loc(p):
        """Where the entry p itself is (its dir resolved, p never followed)."""
        return os.path.join(os.path.realpath(os.path.dirname(p)), os.path.basename(p))

    def env_dir(name, *parts):
        v = os.environ.get(name, "")
        return os.path.join(v, *parts) if v and os.path.isabs(v) else None

    mine = f"jupynvim-{os.geteuid()}"
    roots = [env_dir("XDG_RUNTIME_DIR", "jupynvim"), env_dir("JUPYTER_RUNTIME_DIR", "jupynvim"),
             env_dir("JUPYTER_DATA_DIR", "runtime", "jupynvim"), env_dir("JUPYNVIM_RUNTIME_DIR", "jupynvim"),
             env_dir("TMPDIR", mine), env_dir("JUPYTER_RUNTIME_DIR", mine),
             env_dir("JUPYTER_DATA_DIR", "runtime", mine), env_dir("JUPYNVIM_RUNTIME_DIR", mine)]
    legacy = env_dir("TMPDIR", "jupynvim")

    left = []

    def walk(top):
        """Every entry under top, depth first, sorted; symlinks not followed."""
        try:
            names = sorted(os.listdir(top))
        except OSError:
            return
        for n in names:
            p = os.path.join(top, n)
            if os.path.isdir(p) and not os.path.islink(p):
                left.append(p + os.sep)
                walk(p)
            else:
                left.append(p)

    seen = set()
    for r in roots:
        if not r:
            continue
        if os.path.islink(r):
            loc = link_loc(r)
            if inside_real(loc) and loc not in seen:
                seen.add(loc)
                left.append(r)
            continue
        if not inside(r) or os.path.realpath(r) in seen:
            continue
        seen.add(os.path.realpath(r))
        if os.path.isdir(r) and not os.path.islink(r):
            walk(r)
        elif os.path.lexists(r) and not os.path.isdir(r):
            left.append(r)
    if legacy and inside(legacy) and os.path.lexists(legacy):
        left.append(legacy + (os.sep if os.path.isdir(legacy) else ""))
        if os.path.isdir(legacy) and not os.path.islink(legacy):
            walk(legacy)

    if not left:
        return 0
    print("connection files a test left:")
    for p in left:
        print(f"  {p}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
