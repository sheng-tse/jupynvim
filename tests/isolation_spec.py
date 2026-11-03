#!/usr/bin/env python3
"""Runtime isolation checks for the backend and its kernel.

Run by tests/isolation_spec.sh (S6) inside a run environment made by
tests/lib/test_env.sh. The backend's log, its kernel connection files and
everything the kernel writes (IPython profile, matplotlib cache, Jupyter
runtime files, temp files) must stay in the run dir. Needs msgpack, like
backend_integration.py.

  P1 the run's locations, its shell history file and Python's temp dir are
     in the run dir
  P2 core.log goes to JUPYNVIM_LOG_DIR
  P3 the python3 kernelspec is the run's own
  P4 the kernel's connection file (in the run's runtime dir,
     $XDG_RUNTIME_DIR/jupynvim, mode 0600 in 0700 dirs), command line and
     environment are in it, and the caller's Python startup file, path and
     matplotlib backend are not
  P5 the kernel exits with the backend, the backend's runtime dir goes with
     it, and nothing is in the old location ($TMPDIR/jupynvim)
"""
import glob
import json
import os
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

RUN_VARS = ("TMPDIR", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME",
            "XDG_RUNTIME_DIR", "JUPYTER_CONFIG_DIR", "JUPYTER_DATA_DIR", "JUPYTER_RUNTIME_DIR",
            "JUPYTER_PATH", "IPYTHONDIR", "MPLCONFIGDIR", "JUPYNVIM_LOG_DIR")
KERNEL_VARS = ("IPYTHONDIR", "MPLCONFIGDIR", "JUPYTER_RUNTIME_DIR", "TMPDIR", "XDG_CACHE_HOME")
# The caller's Python startup file, path and matplotlib backend must not
# reach the kernel (tests/lib/test_env.sh unsets them).
KERNEL_UNSET = ("PYTHONSTARTUP", "PYTHONPATH", "PYTHONHOME", "MPLBACKEND", "MATPLOTLIBRC")
PRINT_KERNEL_VARS = ('import os, json; print(json.dumps({k: os.environ.get(k) for k in '
                     + repr(KERNEL_VARS + KERNEL_UNSET) + '}))')

PASS, FAIL = 0, 0


def report(name, ok, detail=""):
    global PASS, FAIL
    ok = bool(ok)
    PASS += int(ok)
    FAIL += int(not ok)
    sym = "[PASS]" if ok else "[FAIL]"
    print(f"  {sym} {name}{(' -- ' + str(detail)) if detail and not ok else ''}", flush=True)


def finish():
    print(f"\nisolation: {PASS}/{PASS + FAIL} passed")
    sys.exit(0 if FAIL == 0 else 1)


def cmdline(pid):
    """The whole command line of pid (-ww: never cut to a terminal width)."""
    return subprocess.run(["ps", "-ww", "-p", str(pid), "-o", "command="],
                          capture_output=True, text=True).stdout.strip()


def poll(fn, timeout, step=0.05):
    """fn() until it returns something truthy, up to timeout seconds."""
    deadline = time.time() + timeout
    while True:
        v = fn()
        if v or time.time() >= deadline:
            return v
        time.sleep(step)


def main():
    print("isolation spec: backend and kernel")
    root = os.environ.get("JNV_RUN_ROOT", "")
    if not root or not os.path.isdir(root):
        # Without a run dir the backend would write into the user's own dirs.
        report("a run environment is active (JNV_RUN_ROOT)", False,
               "run this from tests/isolation_spec.sh")
        finish()
    real_root = os.path.realpath(root)

    def under(p):
        if not p:
            return False
        rp = os.path.realpath(p)
        return rp == real_root or rp.startswith(real_root.rstrip(os.sep) + os.sep)

    # P1
    for v in RUN_VARS:
        report(f"P1 {v} is under the run dir", under(os.environ.get(v, "")),
               os.environ.get(v, "unset"))
    hist = os.environ.get("HISTFILE", "")
    report("P1 HISTFILE is /dev/null or under the run dir", hist == os.devnull or under(hist),
           hist or "unset")
    tmpdir = os.environ.get("TMPDIR", "")
    report("P1 tempfile.gettempdir() is TMPDIR",
           tmpdir and os.path.realpath(tempfile.gettempdir()) == os.path.realpath(tmpdir),
           f"{tempfile.gettempdir()} vs {tmpdir or 'unset'}")
    log_dir = os.environ.get("JUPYNVIM_LOG_DIR", "")
    if not (under(tmpdir) and under(log_dir)):
        # The backend would write its log and connection files outside the run.
        report("the backend can start inside the run dir", False,
               "TMPDIR or JUPYNVIM_LOG_DIR is outside it")
        finish()

    try:
        from backend_integration import Client, make_test_nb
        from backend_integration import _kernel_pids_of, _wait_all_dead
    except Exception as e:  # msgpack missing, most often
        report("import backend_integration", False, repr(e))
        finish()

    cl = Client()
    sid, nb_path, kpids = None, None, []
    # The backend's runtime dir: $XDG_RUNTIME_DIR/jupynvim/core-<host>-<pid>-<rand>/
    runtime = os.path.join(os.environ.get("XDG_RUNTIME_DIR", ""), "jupynvim")
    backend_dir = os.path.join(runtime, f"core-*-{cl.p.pid}-*")
    backend_dirs = []
    try:
        # P2
        err, res = cl.call("ping", {})
        report("P2 the backend answers ping", err is None and res == "pong", str(err))
        log = os.path.join(log_dir, "core.log")

        def log_has_start():
            try:
                with open(log, encoding="utf-8", errors="replace") as f:
                    return "jupynvim-core starting" in f.read()
            except OSError:
                return False
        report("P2 core.log is in JUPYNVIM_LOG_DIR and has the start line",
               poll(log_has_start, 5), log)

        # P3
        err, specs = cl.call("list_kernels", {})
        spec = next((k for k in (specs or []) if isinstance(k, dict)
                     and k.get("name") == "python3"), None)
        report("P3 list_kernels has python3", spec is not None, str(err))
        spec = spec or {}
        report("P3 the python3 kernelspec is the run's own", under(spec.get("path")),
               spec.get("path"))
        argv0 = (spec.get("argv") or [""])[0]
        want = os.environ.get("JNV_KERNEL_PYTHON", "")
        report("P3 python3 runs JNV_KERNEL_PYTHON", argv0 and argv0 == want,
               f"{argv0} vs {want or 'unset'}")

        # P4
        fd, nb_path = tempfile.mkstemp(suffix=".ipynb")
        with os.fdopen(fd, "w") as f:
            json.dump(make_test_nb(), f)
        err, res = cl.call("open", {"path": nb_path})
        report("P4 open the notebook", err is None and res and "session_id" in res, str(err))
        if not (err is None and res and "session_id" in res):
            return
        sid = res["session_id"]
        conn = os.path.join(runtime, "core-*", "kernel-*", "connection.json")
        before = set(glob.glob(conn))
        err, _ = cl.call("start_kernel", {"session_id": sid}, timeout=30)
        report("P4 start_kernel returns", err is None, str(err))
        new = sorted(set(glob.glob(conn)) - before)
        report("P4 one new connection file, in the run's runtime dir",
               len(new) == 1 and all(under(p) for p in new), f"new files in {runtime}: {new}")
        backend_dirs = glob.glob(backend_dir)

        def modes():
            f = new[0]
            kdir = os.path.dirname(f)
            places = ((f, 0o600), (kdir, 0o700), (os.path.dirname(kdir), 0o700), (runtime, 0o700))
            return {p: f"{os.stat(p).st_mode & 0o777:o}" for p, _ in places}, \
                all(os.stat(p).st_mode & 0o777 == want for p, want in places)
        if len(new) == 1:
            try:
                got, ok = modes()
            except OSError as e:
                got, ok = repr(e), False
        else:
            got, ok = "no connection file in the run's runtime dir", False
        report("P4 the connection file is 0600 in 0700 dirs", ok, got)

        kpids = poll(lambda: _kernel_pids_of(cl.p.pid), 5) or []
        cmds = {p: cmdline(p) for p in kpids}
        report("P4 the kernel process is a child of the backend", bool(kpids))
        report("P4 the kernel's command line names the run dir",
               kpids and all(root in c or real_root in c for c in cmds.values()), cmds)

        cl.call("update_cell_source", {"session_id": sid, "cell_id": "c1",
                                       "source": PRINT_KERNEL_VARS})
        cl.events.clear()
        err, _ = cl.call("execute", {"session_id": sid, "cell_id": "c1"})
        report("P4 execute returns", err is None, str(err))

        def stream_line():
            text = "".join(
                e[2][0]["event"].get("text", "") for e in list(cl.events)
                if isinstance(e, list) and len(e) > 2 and e[0] == 2 and e[1] == "cell_event"
                and e[2][0].get("cell_id") == "c1" and e[2][0]["event"].get("kind") == "stream")
            return text.split("\n", 1)[0] if "\n" in text else ""
        line = poll(stream_line, 10)
        try:
            env = json.loads(line) if line else None
        except ValueError:
            env = None
        env = env if isinstance(env, dict) else {}
        report("P4 the kernel prints its environment", bool(env),
               repr(line) if line else "no stream within 10s")
        report("P4 the kernel has its five locations", all(env.get(k) for k in KERNEL_VARS),
               repr(line))
        for k in KERNEL_VARS:
            report(f"P4 the kernel's {k} is under the run dir", under(env.get(k)),
                   env.get(k) or "empty")
        for k in KERNEL_UNSET:
            v = env.get(k)
            if k == "MPLBACKEND":
                # ipykernel sets it to its inline backend itself, but only when
                # it is empty; a caller's value would win and plots would stop
                # making image outputs.
                report("P4 the kernel's MPLBACKEND is unset or ipykernel's inline backend",
                       bool(env) and (v is None or "backend_inline" in v), v)
            else:
                report(f"P4 the kernel has no {k}", bool(env) and v is None, v)
        prof = os.path.join(os.environ.get("IPYTHONDIR", ""), "profile_default")
        report("P4 IPYTHONDIR/profile_default exists", os.path.isdir(prof), prof)
    finally:
        # P5
        if sid is not None:
            for method, timeout in (("stop_kernel", 15), ("close", 10)):
                try:
                    cl.call(method, {"session_id": sid}, timeout=timeout)
                except Exception:  # the backend may be gone already
                    pass
        cl.stop()
        # The dir the backend had while its kernel ran must be gone with it.
        left = glob.glob(backend_dir)
        report("P5 the backend's runtime dir is gone", backend_dirs and not left,
               f"left: {left}" if left else f"no backend dir {backend_dir} while the kernel ran")
        legacy = os.path.join(tmpdir, "jupynvim")
        try:
            in_legacy = sorted(os.listdir(legacy))
        except OSError:
            in_legacy = []
        report("P5 nothing in TMPDIR/jupynvim", not in_legacy,
               f"{legacy}: {in_legacy[:5]}{' ...' if len(in_legacy) > 5 else ''}")
        if kpids:
            survivors = _wait_all_dead(kpids, timeout=6)
            report("P5 the kernel is gone within 6s of the backend", not survivors,
                   f"survivors: {survivors}")
            for p in survivors:  # never leak the kernel, even when failing
                try:
                    os.kill(p, 9)
                except OSError:
                    pass
        if nb_path:
            try:
                os.unlink(nb_path)
            except OSError:
                pass


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        report("isolation spec ran to the end", False, f"crash: {e!r}")
    finish()
