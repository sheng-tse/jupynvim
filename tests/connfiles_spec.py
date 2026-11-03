#!/usr/bin/env python3
"""Kernel connection files: where the backend writes them, their modes, when
they are removed, and who binds a kernel's ports.

Run by tests/run_all.sh (section 2) inside a run environment made by
tests/lib/test_env.sh, with a python that has msgpack (as
backend_integration.py). Standalone, from the repo root:

  bash -c 'source tests/lib/test_env.sh && python tests/connfiles_spec.py [CASE...]'

A CASE is a case id or the start of one (C5 runs C5-eof, C5-term and
C5-hup, C16 all eight C16 cases, C23 the four C23 cases; C2 is C2 alone);
with none given every case runs.

Each kernel's connection file goes into a runtime dir only the user can
access: RT = $XDG_RUNTIME_DIR/jupynvim when XDG_RUNTIME_DIR is a dir the user
owns with mode 0700, else JRT = jupynvim in the Jupyter runtime dir, else
TRT = $TMPDIR/jupynvim-<uid>, or $JUPYNVIM_RUNTIME_DIR/jupynvim when that is
set (the dir it names is never changed). In a dir others can write to that
has the sticky bit, the root is jupynvim-<uid>. A root is used only when the
dir it is in and every dir above it can be changed only by root and the user
(no group or other write bit, unless sticky; on macOS no access control list
entry that lets anyone else add or delete entries). Never into the old
location, LEGACY = $TMPDIR/jupynvim. The layout:

  <root>/                                0700
    core-<host>-<backend pid>-<12 hex>/  0700  one per backend that started a kernel
      lock                               0600  locked while that backend runs
      kernel-<32 hex>/                   0700  one per kernel start
        connection.json                  0600

Cases (each starts its own backends and stops everything it started):
  C1      the files are private: modes, owner, contents, the kernel's command line
  C2      the same under umask 000
  C3      stop_kernel removes the kernel's dir; the backend's dir goes at its exit
  C3b     a kernel that exits by itself takes its dir with it
  C4      restart_kernel replaces the kernel's dir
  C5      the backend's exit removes everything: stdin closed, SIGTERM, SIGHUP
  C6      backend killed (SIGKILL): its kernel is stopped and the files removed
  C7      backend killed: a kernel behind a shell wrapper stops too
  C8      stop_kernel stops a wrapper's kernel too
  C9      backend and guard both killed: the kernel exits on its own and the
          next start removes the files
  C10     the guard is started again when it dies
  C11a    the start sweep removes only dead backends' dirs (XDG runtime dir)
  C11b    in the Jupyter runtime dir only this host's dead dirs go
  C11c    there, another host's dirs go once nothing in them changed for a
          week and their lock is free; recent or locked ones stay
  C12     connection files in the old location go at the next start
  C13     the kernel binds its ports before they are written
  C14     start_kernel answers right after the kernel bound its ports
  C15a    kernels that do not write their ports back get reserved ports
  C15b    a reserved start whose ports are taken is retried with new ports
  C15c    a reserved start whose ports another program's ZMQ sockets took
          counts only an answer signed with the file's key, and is retried
  C16a-e  falls back to another private dir, never one others can read
  C16f    JUPYNVIM_RUNTIME_DIR a dir its group can write to is refused: the
          next candidate is used, the reason is in core.log, and the dir is
          left as it is
  C16g    JUPYNVIM_RUNTIME_DIR a symlink to a dir: the files go into a
          private jupynvim dir in the dir it points to, left as it is
  C16h    JUPYNVIM_RUNTIME_DIR a private dir below a dir its group can
          write to is refused the same way, and nothing is made in it
  C18     one backend's start leaves another live backend's dir, lock and
          kernel alone
  C19     the guard process on its own (jupynvim-core --guard DIR)
  C20     a backend dir removed while its backend runs is made again at the
          next kernel start
  C21     a kernel start still in flight when the backend exits is stopped,
          with what it started
  C22     a process a kernel left in its process group stops when the
          kernel exits
  C23     the backend exits on SIGTERM and on SIGHUP while its stdin stays open,
          after it finished a notebook save, a file write or a recursive
          removal in progress
  C24     the exit removes the backend dir through the root it holds open:
          a root moved away, and a dir put in its place with a symlink named
          like the backend dir, leave the symlink's target alone
  C25a-b  no usable XDG_RUNTIME_DIR (unset, or missing as on a compute node)
          and Jupyter's dir below dirs the user's group can write to (umask
          002 and `ipykernel install --user`): TRT is used
  C25c    JUPYNVIM_RUNTIME_DIR a sticky dir anyone can write to: the root is
          jupynvim-<uid> in it, and a jupynvim an older version left there
          is left as it is
  C26     JUPYNVIM_RUNTIME_DIR a dir whose access control list lets others
          add and delete entries is refused (macOS; on Linux a POSIX ACL
          entry that grants writing shows in the mode), and on macOS a root
          made in a dir with inheritable entries keeps none, nor does
          anything in it
  C27     a tree thousands of dirs deep in a kernel's dir, with the backend
          limited to 256 open files: stop_kernel, the exit and the next
          start's sweep remove it, the backend keeps running, and an entry
          that cannot be removed gives one line in core.log
  C17    nothing is left in any of these places (last)

Prints one PASS or FAIL line per case, then `connfiles: P/N passed`; exits 0
only when every case passed.
"""
import base64
import fcntl
import glob
import json
import os
import re
import shutil
import signal
import socket
import stat
import struct
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
CORE = ROOT / "core/target/release/jupynvim-core"
sys.path.insert(0, str(HERE))

try:
    import msgpack
    from backend_integration import Client, make_test_nb, _child_pids, _alive
    IMPORT_ERROR = None
except Exception as e:  # msgpack missing, most often
    Client = object
    IMPORT_ERROR = e

PORT_KEYS = ("shell_port", "iopub_port", "stdin_port", "control_port", "hb_port")
BDIR_RE = re.compile(r"^core-(?P<tok>[A-Za-z0-9._-]+)-(?P<pid>\d+)-(?P<rand>[0-9a-f]{12})$")
KDIR_RE = re.compile(r"^kernel-[0-9a-f]{32}$")
RETRY_LINE = "retrying with new ports (attempt 2 of 3)"
RESERVED_LINE = "kernel ports: reserved "

# Set by init_paths() once the run environment is checked.
RUN = RT = JRT = JDRT = TRT = LEGACY = WORK = SPECS = LOG = None
PY = ""

PASS, FAIL = 0, 0


def report(name, ok, detail=""):
    global PASS, FAIL
    PASS += int(ok)
    FAIL += int(not ok)
    sym = "[PASS]" if ok else "[FAIL]"
    print(f"  {sym} {name}{(' -- ' + detail) if detail and not ok else ''}", flush=True)


def init_paths():
    """Check the run environment and set the paths; the reason when it is not
    usable, else None. Every place this spec writes to, plants in or removes
    from is inside the run dir."""
    global RUN, RT, JRT, JDRT, TRT, LEGACY, WORK, SPECS, LOG, PY
    run = os.environ.get("JNV_RUN_ROOT", "")
    if not run or not os.path.isdir(run):
        return "JNV_RUN_ROOT is not set; run this inside tests/lib/test_env.sh"
    real = os.path.realpath(run)

    def inside(v):
        rp = os.path.realpath(v)
        return rp == real or rp.startswith(real.rstrip(os.sep) + os.sep)

    for k in ("TMPDIR", "XDG_RUNTIME_DIR", "JUPYTER_RUNTIME_DIR", "JUPYTER_DATA_DIR",
              "JUPYNVIM_LOG_DIR"):
        v = os.environ.get(k, "")
        if not v or not os.path.isabs(v) or not inside(v):
            return f"{k} is not a path in the run dir ({v or 'unset'})"
    PY = os.environ.get("JNV_KERNEL_PYTHON", "")
    if not PY:
        return "JNV_KERNEL_PYTHON is not set"
    RUN = Path(run)
    RT = Path(os.environ["XDG_RUNTIME_DIR"]) / "jupynvim"
    JRT = Path(os.environ["JUPYTER_RUNTIME_DIR"]) / "jupynvim"
    JDRT = Path(os.environ["JUPYTER_DATA_DIR"]) / "runtime" / "jupynvim"
    TRT = Path(os.environ["TMPDIR"]) / f"jupynvim-{os.geteuid()}"
    LEGACY = Path(os.environ["TMPDIR"]) / "jupynvim"
    LOG = Path(os.environ["JUPYNVIM_LOG_DIR"]) / "core.log"
    WORK = Path(tempfile.mkdtemp(prefix="connfiles.", dir=os.environ["TMPDIR"]))
    SPECS = WORK / "jupyter"
    return None


# ── paths and files ─────────────────────────────────────

def rel(p):
    """p with the run dir shown as <run>, for short messages."""
    s = str(p)
    for pre in (str(RUN), os.path.realpath(str(RUN))):
        if s.startswith(pre + os.sep):
            return "<run>" + s[len(pre):]
    return s


def perm(p):
    return os.stat(p).st_mode & 0o777


def mode_text(p):
    try:
        return f"{perm(p):o}"
    except OSError:
        return "gone"


def describe(paths):
    """Each path with its mode and its dir's mode."""
    paths = list(paths)
    if not paths:
        return "none"
    return ", ".join(f"{rel(p)} (file {mode_text(p)}, dir {mode_text(Path(p).parent)})"
                     for p in paths)


def listing(d):
    try:
        names = sorted(os.listdir(d))
    except OSError:
        return f"{rel(d)} (gone)"
    shown = ", ".join(names[:4]) + (", ..." if len(names) > 4 else "")
    return f"{rel(d)} ({len(names)} entries: {shown or 'none'})"


def conn_files(extra=()):
    """Every connection file in RT, JRT, TRT, the old location and the extra
    roots."""
    pats = [str(RT / "core-*" / "kernel-*" / "connection.json"),
            str(JRT / "core-*" / "kernel-*" / "connection.json"),
            str(TRT / "core-*" / "kernel-*" / "connection.json"),
            str(LEGACY / "kernel-*.json")]
    pats += [str(Path(r) / "core-*" / "kernel-*" / "connection.json") for r in extra]
    found = set()
    for pat in pats:
        found.update(Path(p) for p in glob.glob(pat))
    return sorted(found)


def backend_dirs(root=None, pid=None):
    root = RT if root is None else Path(root)
    try:
        names = sorted(os.listdir(root))
    except OSError:
        return []
    out = []
    for n in names:
        m = BDIR_RE.match(n)
        if m and (pid is None or int(m["pid"]) == pid) and (root / n).is_dir():
            out.append(root / n)
    return out


def kernel_dirs(bdir):
    try:
        return [Path(bdir) / n for n in sorted(os.listdir(bdir)) if KDIR_RE.match(n)]
    except OSError:
        return []


def layout_of(f):
    """(backend dir, kernel dir) when f is <root>/core-*/kernel-*/connection.json,
    else (None, None)."""
    f = Path(f)
    if f.name == "connection.json" and KDIR_RE.match(f.parent.name) \
            and BDIR_RE.match(f.parent.parent.name):
        return f.parent.parent, f.parent
    return None, None


def read_json(p):
    try:
        with open(p, encoding="utf-8") as fh:
            d = json.load(fh)
        return d if isinstance(d, dict) else None
    except (OSError, ValueError):
        return None


def ports_of(d):
    """The five ports when every one is a nonzero port number, else None."""
    if not d:
        return None
    ports = [d.get(k) for k in PORT_KEYS]
    if all(isinstance(p, int) and 0 < p < 65536 for p in ports):
        return ports
    return None


def write_private(path, data=b"", mode=0o600):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode)
    try:
        os.write(fd, data)
    finally:
        os.close(fd)
    os.chmod(path, mode)


def make_dir(path, mode=0o700):
    os.mkdir(path, mode)
    os.chmod(path, mode)


def remove_tree(path):
    p = Path(path)
    if p.is_symlink() or p.is_file():
        p.unlink()
    elif p.is_dir():
        shutil.rmtree(p)


def scrub(path):
    """Remove a dir whatever a failed check left in it: a tree deeper than
    shutil.rmtree can recurse, a dir without the write bit, on macOS an
    access control list entry (the system's chmod and rm walk any depth)."""
    if not os.path.lexists(path):
        return
    if sys.platform == "darwin":
        subprocess.run(["/bin/chmod", "-R", "-N", str(path)], capture_output=True)
    subprocess.run(["/bin/chmod", "-R", "u+rwx", str(path)], capture_output=True)
    subprocess.run(["/bin/rm", "-rf", str(path)], capture_output=True)


def rmdir_if_empty(path):
    try:
        os.rmdir(path)
    except OSError:
        pass


def unlink_quiet(path):
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass


def log_mark():
    try:
        return os.path.getsize(LOG)
    except OSError:
        return 0


def log_since(mark):
    try:
        with open(LOG, "rb") as fh:
            fh.seek(mark)
            return fh.read().decode("utf-8", "replace")
    except OSError:
        return ""


SWEEP_LINE = "runtime sweep: removed"
SWEEP_DONE = "runtime sweep: done"


def wait_sweep(mark, timeout=5):
    """Whether the start sweep logged that it removed something (it does once
    it has finished) after mark, waiting up to timeout seconds. What must
    stay is checked only after that, so an entry the sweep would remove a
    moment after the ones it must remove is caught."""
    return bool(wait_until(lambda: SWEEP_LINE in log_since(mark), timeout))


def unswept(swept):
    return "" if swept else f" (no '{SWEEP_LINE}' line in core.log within 5 s)"


# ── processes ───────────────────────────────────────────

def ps_field(pid, field):
    """One ps field of pid (-ww: never cut), "" when pid is not running."""
    env = dict(os.environ, LC_ALL="C", TZ="UTC0")
    r = subprocess.run(["ps", "-ww", "-o", field + "=", "-p", str(pid)],
                       capture_output=True, text=True, env=env)
    return r.stdout.strip()


def cmdline(pid):
    return ps_field(pid, "command")


def short_cmd(cmd, width=140):
    """A command line for a message: the program's base name, the run dir as
    <run>, cut to width."""
    prog, _, rest = cmd.partition(" ")
    s = os.path.basename(prog) + (" " + rest if rest else "")
    for pre in (str(RUN), os.path.realpath(str(RUN))):
        s = s.replace(pre, "<run>")
    return s if len(s) <= width else s[:width - 3] + "..."


def started(pid):
    """The start time ps prints: with the pid, what identifies a process."""
    return ps_field(pid, "lstart")


def dead(pid):
    """True when pid is gone or a zombie (it has exited, nobody reaped it yet)."""
    if not _alive(pid):
        return True
    s = ps_field(pid, "stat")
    return not s or s.startswith("Z")


def descendants(pid, depth=6):
    out, level = [], [pid]
    for _ in range(depth):
        nxt = []
        for q in level:
            nxt.extend(_child_pids(q))
        out.extend(nxt)
        level = nxt
        if not level:
            break
    return out


def child_with(pid, text):
    for c in _child_pids(pid):
        if text in cmdline(c):
            return c
    return None


def wait_until(fn, timeout, step=0.02):
    """fn() until it returns something truthy, up to timeout seconds; its
    last value."""
    deadline = time.monotonic() + timeout
    while True:
        v = fn()
        if v or time.monotonic() >= deadline:
            return v
        time.sleep(step)


def kernel_pid(core, timeout=5):
    """The backend's child whose command line has ipykernel_launcher."""
    return wait_until(lambda: child_with(core.p.pid, "ipykernel_launcher"), timeout)


def guard_pids(core):
    return [c for c in _child_pids(core.p.pid) if " --guard " in cmdline(c) and not dead(c)]


def guard_pid(core):
    g = guard_pids(core)
    return g[0] if g else None


# ── the backend ─────────────────────────────────────────

class Core(Client):
    """A backend with an environment of its own: env_set adds or replaces
    variables, env_unset removes them, umask is the backend's umask. The
    kernelspecs in SPECS come first on JUPYTER_PATH. JUPYNVIM_RUNTIME_DIR is
    never inherited (only env_set gives it). Records when each response
    arrived."""

    def __init__(self, env_set=None, env_unset=(), umask=None, nofile=None):
        env = dict(os.environ)
        env.pop("JUPYNVIM_RUNTIME_DIR", None)
        env["JUPYTER_PATH"] = os.pathsep.join(
            p for p in (str(SPECS), os.environ.get("JUPYTER_PATH", "")) if p)
        for k, v in (env_set or {}).items():
            env[k] = str(v)
        for k in env_unset:
            env.pop(k, None)
        kw = {} if umask is None else {"umask": umask}
        self.events = []
        self.next_id = 1
        self.unpacker = msgpack.Unpacker(raw=False)
        self._stop = False
        self.arrived = {}
        self.sid = None
        self.finished = False
        self.t_resp = None
        self.t_spawn = time.monotonic()
        # nofile: the backend's open files limit, set by a shell that then
        # becomes the backend (exec keeps the pid)
        argv = [str(CORE)] if nofile is None else \
            ["/bin/sh", "-c", f'ulimit -n {int(nofile)} && exec "$0"', str(CORE)]
        self.p = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, bufsize=0, env=env, **kw)
        threading.Thread(target=self._read_loop, daemon=True).start()

    def _read_loop(self):
        fd = self.p.stdout.fileno()

        def read_exact(n):
            buf = b""
            while len(buf) < n:
                chunk = os.read(fd, n - len(buf))
                if not chunk:
                    return None
                buf += chunk
            return buf

        while not self._stop:
            try:
                hdr = read_exact(4)
                if hdr is None:
                    return
                payload = read_exact(struct.unpack(">I", hdr)[0])
                if payload is None:
                    return
                msg = msgpack.unpackb(payload, raw=False)
            except Exception:
                return
            if isinstance(msg, list) and len(msg) > 1 and msg[0] == 1:
                self.arrived[msg[1]] = time.monotonic()
            self.events.append(msg)

    def call_t(self, method, params, timeout=10):
        """call(), plus the monotonic time the response arrived (None: none)."""
        msgid = self.next_id
        err, res = self.call(method, params, timeout)
        return err, res, self.arrived.get(msgid)


def open_nb(core):
    fd, path = tempfile.mkstemp(suffix=".ipynb", dir=str(WORK))
    with os.fdopen(fd, "w") as fh:
        json.dump(make_test_nb(), fh)
    err, res = core.call("open", {"path": path})
    if err is not None or not isinstance(res, dict) or "session_id" not in res:
        raise Fail(f"open failed: {err}")
    core.sid = res["session_id"]
    return core.sid


def start(core, sid, kernel=None, timeout=20):
    """start_kernel; (err, res, seconds until the response arrived)."""
    params = {"session_id": sid}
    if kernel:
        params["kernel_name"] = kernel
    t0 = time.monotonic()
    err, res, t = core.call_t("start_kernel", params, timeout)
    core.t_resp = t
    return err, res, (t if t is not None else time.monotonic()) - t0


def run_print(core, sid, code, want, timeout=15):
    """Run code in cell c1; True when its stdout, stripped, is want."""
    err, _ = core.call("update_cell_source", {"session_id": sid, "cell_id": "c1",
                                              "source": code})
    if err is not None:
        return False
    i = len(core.events)
    err, _ = core.call("execute", {"session_id": sid, "cell_id": "c1"})
    if err is not None:
        return False

    def text():
        out = []
        for e in core.events[i:]:
            if isinstance(e, list) and len(e) > 2 and e[0] == 2 and e[1] == "cell_event":
                p = e[2][0] if isinstance(e[2], list) and e[2] else {}
                ev = p.get("event") or {}
                if p.get("cell_id") == "c1" and ev.get("kind") == "stream":
                    out.append(ev.get("text", ""))
        return "".join(out).strip() == want
    return bool(wait_until(text, timeout))


def ping_within(case, core, limit=1.0):
    err, res, t = core.call_t("ping", {}, timeout=5)
    took = (t - core.t_spawn) if t is not None else None
    case.expect(err is None and res == "pong" and took is not None and took <= limit,
                f"a new backend did not answer ping within {limit} s of its start "
                f"(err {err}, took {'-' if took is None else f'{took:.2f}'} s)")


def kill_core(core):
    core._stop = True
    core.p.kill()
    core.p.wait(5)


def finish(case, core):
    """Stop the kernel and close the notebook (when the backend still runs),
    then stop the backend. Every process seen under it is recorded first, so
    the case can stop what outlives it."""
    if core.finished:
        return
    core.finished = True
    if core.p.poll() is None:
        case.note_tree(core)
        if core.sid is not None:
            for method, timeout in (("stop_kernel", 15), ("close", 10)):
                try:
                    core.call(method, {"session_id": core.sid}, timeout=timeout)
                except Exception:  # the backend may be gone already
                    pass
    try:
        core.stop()
        core.p.wait(5)
    except Exception:
        pass
    for fh in (core.p.stdin, core.p.stderr):
        try:
            fh.close()
        except Exception:
            pass


# ── a case ──────────────────────────────────────────────

class Fail(Exception):
    pass


class Case:
    """One case: its failures, the backends and processes it started, and
    what to undo at the end."""

    def __init__(self, name):
        self.name = name
        self.fails = []
        self.cores = []
        self.own = []    # processes the case started itself (Popen)
        self.seen = {}   # pid -> (start, command) of each process seen under a backend
        self.undo = []   # cleanups, run last first

    def expect(self, ok, msg):
        if not ok:
            self.fails.append(msg)
        return bool(ok)

    def require(self, ok, msg):
        if not ok:
            raise Fail(msg)

    def core(self, **kw):
        c = Core(**kw)
        self.cores.append(c)
        return c

    def note(self, pid):
        if pid and pid not in self.seen:
            st = started(pid)
            if st:
                self.seen[pid] = (st, cmdline(pid))

    def note_tree(self, core):
        if core.p.poll() is None:
            for pid in descendants(core.p.pid):
                self.note(pid)

    def cleanup(self):
        for c in self.cores:
            finish(self, c)
        for p in self.own:
            if p.poll() is None:
                p.kill()
            try:
                p.wait(5)
            except subprocess.TimeoutExpired:
                pass
            for fh in (p.stdin, p.stdout, p.stderr):
                try:
                    if fh:
                        fh.close()
                except Exception:
                    pass
        # Whatever ran under a backend ends with it; the rest is stopped here
        # by pid, only while it is still the same process (same start).
        wait_until(lambda: all(dead(p) for p in self.seen), 3, step=0.05)
        left = []
        for pid, (st, cmd) in sorted(self.seen.items()):
            if not dead(pid) and started(pid) == st:
                left.append(f"{pid} {short_cmd(cmd)}")
                try:
                    os.kill(pid, signal.SIGKILL)
                except OSError:
                    pass
        if left:
            self.fails.append("still running after its backend was stopped (the test stopped "
                              "it by pid): " + "; ".join(left))
        for fn in reversed(self.undo):
            try:
                fn()
            except Exception as e:
                self.fails.append(f"cleanup: {e!r}")


def started_kernel(case, core, kernel=None, timeout=20, extra=()):
    """Open a notebook and start a kernel; (connection files before, the new
    ones)."""
    sid = open_nb(core)
    before = set(conn_files(extra))
    err, _, secs = start(core, sid, kernel, timeout)
    case.note_tree(core)
    case.require(err is None, f"start_kernel{' ' + kernel if kernel else ''} failed after "
                              f"{secs:.1f} s: {err}")
    return before, sorted(set(conn_files(extra)) - before)


def one_file(case, new):
    case.require(len(new) == 1, f"expected one new connection file, found {describe(new)}")
    return new[0]


def check_private(case, core, new, root, label):
    """The kernel's one new connection file is root/core-*-<backend pid>-*/
    kernel-*/connection.json: 0600 in 0700 dirs, all the user's, with
    localhost ports and a key, named on the kernel's command line."""
    pid = core.p.pid
    bds = backend_dirs(root, pid)
    case.require(len(bds) == 1,
                 f"no backend dir of this backend (pid {pid}) in {label} ({rel(root)}); "
                 f"the kernel's connection file is {describe(new)}")
    bd = bds[0]
    uid = os.getuid()
    st = os.lstat(root)
    case.expect(stat.S_ISDIR(st.st_mode) and st.st_mode & 0o777 == 0o700 and st.st_uid == uid,
                f"{label} is mode {st.st_mode & 0o777:o}, uid {st.st_uid}, "
                f"{'a dir' if stat.S_ISDIR(st.st_mode) else 'not a dir'}; want a 700 dir of uid {uid}")
    bst = os.lstat(bd)
    case.expect(stat.S_ISDIR(bst.st_mode) and bst.st_mode & 0o777 == 0o700 and bst.st_uid == uid,
                f"the backend dir is mode {bst.st_mode & 0o777:o}, uid {bst.st_uid}")
    lock = bd / "lock"
    case.expect(lock.is_file() and perm(lock) == 0o600 and os.stat(lock).st_uid == uid,
                f"the backend dir's lock is {mode_text(lock) if lock.exists() else 'missing'}")
    kds = kernel_dirs(bd)
    case.require(len(kds) == 1, f"expected one kernel dir in the backend dir, found "
                                f"{[k.name for k in kds]}")
    kd = kds[0]
    kst = os.lstat(kd)
    case.expect(stat.S_ISDIR(kst.st_mode) and kst.st_mode & 0o777 == 0o700 and kst.st_uid == uid,
                f"the kernel dir is mode {kst.st_mode & 0o777:o}, uid {kst.st_uid}")
    conn = kd / "connection.json"
    case.require(new == [conn], f"the new connection files are {describe(new)}, "
                                f"want only {rel(conn)}")
    fst = os.lstat(conn)
    case.expect(stat.S_ISREG(fst.st_mode) and fst.st_mode & 0o777 == 0o600 and fst.st_uid == uid,
                f"the connection file is mode {fst.st_mode & 0o777:o}, uid {fst.st_uid}")
    d = wait_until(lambda: read_json(conn), 2) or {}
    case.expect(d.get("ip") == "127.0.0.1" and d.get("transport") == "tcp",
                f"ip {d.get('ip')!r}, transport {d.get('transport')!r}")
    case.expect(ports_of(d) is not None, f"ports {[d.get(k) for k in PORT_KEYS]}")
    key = d.get("key")
    case.expect(isinstance(key, str) and len(key) == 36, f"a key of length "
                                                         f"{len(key) if isinstance(key, str) else '-'}")
    kp = kernel_pid(core)
    cmd = cmdline(kp) if kp else ""
    case.expect(kp and (str(conn) in cmd or os.path.realpath(conn) in cmd),
                f"the kernel's command line does not name {rel(conn)}: {short_cmd(cmd)}")
    return bd, kd, conn


# ── kernelspecs and port watchers ───────────────────────

def provision():
    slow = ["/bin/sh", "-c", "sleep 1; exec \"$0\" -m ipykernel_launcher -f \"$1\"", PY,
            "{connection_file}"]
    reserved = {"jupynvim": {"ports": "reserved"}}
    specs = {
        # sh stays the kernel's parent (no exec), as with conda run or a script
        "jnv-wrap": {"argv": ["/bin/sh", "-c", "\"$0\" -m ipykernel_launcher -f \"$1\"; exit $?",
                              PY, "{connection_file}"],
                     "display_name": "wrap", "language": "python"},
        "jnv-slow": {"argv": slow, "display_name": "slow", "language": "python"},
        "jnv-reserved": {"argv": [PY, "-m", "ipykernel_launcher", "-f", "{connection_file}"],
                         "display_name": "reserved", "language": "python",
                         "metadata": reserved},
        "jnv-reserved-slow": {"argv": slow, "display_name": "reserved slow",
                              "language": "python", "metadata": reserved},
        # a start that takes 30 s before the kernel runs at all
        "jnv-hang": {"argv": ["/bin/sh", "-c",
                              "sleep 30; exec \"$0\" -m ipykernel_launcher -f \"$1\"",
                              PY, "{connection_file}"],
                     "display_name": "hang", "language": "python"},
        # after the exec the kernel python leads the group and the sleep is in it
        "jnv-child": {"argv": ["/bin/sh", "-c",
                               "sleep 30 & exec \"$0\" -m ipykernel_launcher -f \"$1\"",
                               PY, "{connection_file}"],
                      "display_name": "child", "language": "python"},
    }
    for name, spec in specs.items():
        d = SPECS / "kernels" / name
        d.mkdir(parents=True)
        with open(d / "kernel.json", "w", encoding="utf-8") as fh:
            json.dump(spec, fh, indent=1)


class Grabber(threading.Thread):
    """Every 1 ms, for each connection file that was not there at the start:
    once it has five nonzero ports, bind each of them (SO_REUSEADDR, as
    libzmq and most servers do) and listen. Counts the ports bound (and held
    until stop) and refused. one_shot: only the first such file."""

    def __init__(self, one_shot=False):
        super().__init__(daemon=True)
        self.one_shot = one_shot
        self.skip = set(conn_files())
        self.done = set()
        self.socks = []
        self.bound = 0
        self.refused = 0
        self.halt = threading.Event()

    def run(self):
        while not self.halt.is_set():
            for f in conn_files():
                if f in self.skip or f in self.done:
                    continue
                ports = ports_of(read_json(f))
                if ports is None:  # missing, being written, or a port still 0
                    continue
                for port in ports:
                    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                    try:
                        s.bind(("127.0.0.1", port))
                        s.listen(1)
                        self.socks.append(s)
                        self.bound += 1
                    except OSError:
                        s.close()
                        self.refused += 1
                self.done.add(f)
                if self.one_shot:
                    return
            self.halt.wait(0.001)

    def stop(self):
        self.halt.set()
        self.join(2)
        for s in self.socks:
            s.close()


class PortWatch(threading.Thread):
    """Every 1 ms, the first connection file that was not there at the start:
    t_first is when it first has five nonzero ports (time.monotonic), and
    first_parse_had_ports whether the first time it parsed it had them."""

    def __init__(self):
        super().__init__(daemon=True)
        self.skip = set(conn_files())
        self.file = None
        self.t_first = None
        self.first_parse_had_ports = None
        self.halt = threading.Event()

    def run(self):
        while not self.halt.is_set():
            if self.file is None:
                new = [f for f in conn_files() if f not in self.skip]
                if new:
                    self.file = new[0]
            if self.file is not None:
                d = read_json(self.file)
                if d is not None:
                    has = ports_of(d) is not None
                    if self.first_parse_had_ports is None:
                        self.first_parse_had_ports = has
                    if has:
                        self.t_first = time.monotonic()
                        return
            self.halt.wait(0.001)

    def stop(self):
        self.halt.set()
        self.join(2)


# ── the cases ───────────────────────────────────────────

def c_private(umask):
    def fn(case):
        core = case.core(umask=umask)
        _, new = started_kernel(case, core)
        check_private(case, core, new, RT, "RT")
        case.expect(not LEGACY.exists(), f"the old location exists: {listing(LEGACY)}")
    return fn


def c3(case):
    core = case.core()
    before, new = started_kernel(case, core)
    f = one_file(case, new)
    bdir, kdir = layout_of(f)
    kpid = kernel_pid(core)
    case.require(kpid, "no kernel process under the backend")
    stop_kernel_timed(case, core)
    # right after the response
    case.expect(not f.exists(), f"the kernel's connection file is still there after "
                                f"stop_kernel: {describe([f])}")
    if kdir is not None:
        case.expect(not kdir.exists(), f"the kernel dir is still there after stop_kernel: "
                                       f"{rel(kdir)}")
        case.expect(bdir.is_dir() and (bdir / "lock").is_file(),
                    f"the backend dir or its lock went while the backend runs: {rel(bdir)}")
    case.expect(wait_until(lambda: dead(kpid), 2),
                f"the kernel (pid {kpid}) still runs 2 s after stop_kernel")
    finish(case, core)
    if bdir is not None:
        case.expect(not bdir.exists(), f"the backend dir is still there after the backend "
                                       f"exited: {listing(bdir)}")
    left = sorted(set(conn_files()) - before)
    case.expect(not left, f"connection files left after the backend exited: {describe(left)}")


def c3b(case):
    core = case.core()
    _, new = started_kernel(case, core)
    f = one_file(case, new)
    _, kdir = layout_of(f)
    kpid = kernel_pid(core)
    case.require(kpid, "no kernel process under the backend")
    core.call("update_cell_source", {"session_id": core.sid, "cell_id": "c1",
                                     "source": "import os; os._exit(0)"})
    core.call("execute", {"session_id": core.sid, "cell_id": "c1"})
    case.require(wait_until(lambda: dead(kpid), 5),
                 f"the kernel (pid {kpid}) did not exit on os._exit(0)")
    gone = wait_until(lambda: not f.exists() and (kdir is None or not kdir.exists()), 3)
    case.expect(gone, f"the connection file is still there 3 s after its kernel exited: "
                      f"{describe([f])}")


def c4(case):
    core = case.core()
    before, new = started_kernel(case, core)
    f1 = one_file(case, new)
    bdir, kdir1 = layout_of(f1)
    err, _ = core.call("restart_kernel", {"session_id": core.sid}, timeout=20)
    case.note_tree(core)
    case.require(err is None, f"restart_kernel failed: {err}")
    now = sorted(set(conn_files()) - before)
    case.expect(not f1.exists(), f"the first kernel's connection file is still there after "
                                 f"restart_kernel ({len(now)} files now: {describe(now)})")
    if kdir1 is not None:
        case.expect(not kdir1.exists(), f"the first kernel's dir is still there: {rel(kdir1)}")
    others = [p for p in now if p != f1]
    case.expect(len(others) == 1, f"expected one other connection file after restart_kernel, "
                                  f"found {describe(others)}")
    if bdir is not None and len(others) == 1:
        kds = kernel_dirs(bdir)
        case.expect(kds == [others[0].parent], f"the backend dir's kernel dirs are "
                                               f"{[k.name for k in kds]}")
    case.expect(run_print(core, core.sid, "print(1+1)", "2"),
                "the restarted kernel did not print 2")


def c5(how):
    def fn(case):
        core = case.core()
        before, _ = started_kernel(case, core)
        kpid = kernel_pid(core)
        case.require(kpid, "no kernel process under the backend")
        g = guard_pid(core)
        case.note(g)
        bdirs = backend_dirs(RT, core.p.pid)
        core._stop = True
        if how == "eof":
            core.p.stdin.close()
        elif how == "term":
            core.p.send_signal(signal.SIGTERM)
        else:
            core.p.send_signal(signal.SIGHUP)
        try:
            core.p.wait(10)
        except subprocess.TimeoutExpired:
            if how == "eof":
                raise Fail("the backend did not exit within 10 s of its stdin closing")
            # A process that waits for its stdin before it ends: closing it
            # (the frontend going away) lets the checks below still run.
            case.fails.append(f"the backend did not exit within 10 s of SIG{how.upper()} "
                              f"while its stdin stayed open")
            core.p.stdin.close()
            try:
                core.p.wait(10)
            except subprocess.TimeoutExpired:
                raise Fail("the backend did not exit within 10 s of its stdin closing either")
        # right after the backend exited
        left = sorted(set(conn_files()) - before)
        case.expect(not left, f"connection files left when the backend had exited: "
                              f"{describe(left)}")
        still = [rel(b) for b in bdirs if b.exists()]
        case.expect(not still, f"the backend dir is still there when the backend had exited: "
                               f"{still}")
        case.expect(wait_until(lambda: dead(kpid), 3),
                    f"the kernel (pid {kpid}) still runs 3 s after the backend exited")
        if case.expect(g is not None, "no guard process"):
            case.expect(wait_until(lambda: dead(g), 2),
                        f"the guard (pid {g}) still runs 2 s after the backend exited")
    return fn


STOP_LIMIT = 2.0  # stop_kernel stops the kernel's group and answers once it exited


def stop_kernel_timed(case, core):
    """stop_kernel; a failure when it fails or answers later than STOP_LIMIT
    seconds (it waits for the kernel's exit, which SIGKILL makes quick)."""
    t0 = time.monotonic()
    err, _, t = core.call_t("stop_kernel", {"session_id": core.sid}, timeout=15)
    case.require(err is None, f"stop_kernel failed: {err}")
    took = (t if t is not None else time.monotonic()) - t0
    case.expect(took <= STOP_LIMIT, f"stop_kernel answered after {took:.2f} s (limit {STOP_LIMIT} s)")


def files_left(before, bdirs):
    return sorted(set(conn_files()) - before) + [b for b in bdirs if b.exists()]


def c6(case):
    core = case.core()
    before, _ = started_kernel(case, core)
    kpid = kernel_pid(core)
    case.require(kpid, "no kernel process under the backend")
    g = guard_pid(core)
    case.note(g)
    bdirs = backend_dirs(RT, core.p.pid)
    kill_core(core)
    case.expect(wait_until(lambda: dead(kpid), 3),
                f"the kernel (pid {kpid}) still runs 3 s after its backend was killed")
    case.expect(wait_until(lambda: not files_left(before, bdirs), 3),
                f"files left 3 s after the backend was killed: {describe(files_left(before, bdirs))}")
    if case.expect(g is not None, "no guard process"):
        case.expect(wait_until(lambda: dead(g), 3),
                    f"the guard (pid {g}) still runs 3 s after the backend was killed")


def wrapper_pids(case, core):
    sh = kernel_pid(core)
    case.require(sh, "no wrapper process with ipykernel_launcher under the backend")
    py = wait_until(lambda: child_with(sh, "ipykernel_launcher"), 5)
    case.require(py, f"no kernel python under the wrapper (pid {sh})")
    case.note_tree(core)
    return sh, py


def running(named):
    return ", ".join(f"{label} (pid {pid})" for label, pid in named if not dead(pid))


def c7(case):
    core = case.core()
    before, _ = started_kernel(case, core, "jnv-wrap")
    sh, py = wrapper_pids(case, core)
    bdirs = backend_dirs(RT, core.p.pid)
    kill_core(core)
    named = (("the wrapper sh", sh), ("its kernel python", py))
    case.expect(wait_until(lambda: dead(sh) and dead(py), 3),
                f"still running 3 s after the backend was killed: {running(named)}")
    case.expect(wait_until(lambda: not files_left(before, bdirs), 3),
                f"files left 3 s after the backend was killed: {describe(files_left(before, bdirs))}")


def c8(case):
    core = case.core()
    started_kernel(case, core, "jnv-wrap")
    sh, py = wrapper_pids(case, core)
    stop_kernel_timed(case, core)
    named = (("the wrapper sh", sh), ("its kernel python", py))
    case.expect(wait_until(lambda: dead(sh) and dead(py), 2),
                f"still running 2 s after stop_kernel: {running(named)}")


def c9(case):
    core = case.core()
    before, _ = started_kernel(case, core)
    kpid = kernel_pid(core)
    case.require(kpid, "no kernel process under the backend")
    g = guard_pid(core)
    case.note(g)
    bdirs = backend_dirs(RT, core.p.pid)
    case.expect(g is not None, "no guard process")
    # Stopped first, the backend cannot start a new guard once its guard is gone.
    os.kill(core.p.pid, signal.SIGSTOP)
    if g is not None:
        os.kill(g, signal.SIGKILL)
    kill_core(core)
    case.expect(wait_until(lambda: dead(kpid), 5),
                f"the kernel (pid {kpid}) still runs 5 s after its backend and guard were killed")
    if not bdirs:
        case.fails.append("precondition: the killed backend had no dir in RT for the next start "
                          "to remove")
    else:
        gone = [rel(b) for b in bdirs if not b.exists()]
        case.expect(not gone, f"precondition: the killed backend's dir went before the next "
                              f"start: {gone}")
    left = files_left(before, bdirs)
    core2 = case.core()
    ping_within(case, core2)
    case.expect(wait_until(lambda: not files_left(before, bdirs), 5),
                f"files of the killed backend still there 5 s after the next start: "
                f"{describe(files_left(before, bdirs)) if left else 'none to remove'}")


def c10(case):
    core = case.core()
    before, _ = started_kernel(case, core)
    kpid = kernel_pid(core)
    case.require(kpid, "no kernel process under the backend")
    g1 = guard_pid(core)
    case.note(g1)
    bdirs = backend_dirs(RT, core.p.pid)
    if case.expect(g1 is not None, "no guard process"):
        os.kill(g1, signal.SIGKILL)
        g2 = wait_until(lambda: next((g for g in guard_pids(core) if g != g1), None), 2)
        if case.expect(g2 is not None, f"no new guard within 2 s of the first one's end "
                                       f"(pid {g1})"):
            case.note(g2)
    kill_core(core)
    case.expect(wait_until(lambda: dead(kpid), 3),
                f"the kernel (pid {kpid}) still runs 3 s after its backend was killed")
    case.expect(wait_until(lambda: not files_left(before, bdirs), 3),
                f"files left 3 s after the backend was killed: {describe(files_left(before, bdirs))}")


def plant_backend_dir(case, root, name, lock=True, kernel=False):
    d = Path(root) / name
    make_dir(d)
    case.undo.append(lambda: remove_tree(d) if os.path.lexists(d) else None)
    if lock:
        write_private(d / "lock")
    if kernel:
        k = d / ("kernel-" + "0" * 32)
        make_dir(k)
        write_private(k / "connection.json", b"{}")
    return d


def private_root(case, root):
    """root as a 0700 dir; removed at the end when the case made it and it is
    empty again."""
    if not root.exists():
        make_dir(root)
        case.undo.append(lambda: rmdir_if_empty(root))


def c11a(case):
    private_root(case, RT)
    d1 = plant_backend_dir(case, RT, "core-feedbeef0001-1-aaaaaaaaaaaa", kernel=True)
    d2 = plant_backend_dir(case, RT, "core-0123456789ab-2-bbbbbbbbbbbb")
    d3 = plant_backend_dir(case, RT, "core-feedbeef0003-3-cccccccccccc")
    holder = [os.open(d3 / "lock", os.O_RDWR)]
    fcntl.flock(holder[0], fcntl.LOCK_EX)

    def release():
        while holder:
            os.close(holder.pop())
    case.undo.append(release)
    d4 = plant_backend_dir(case, RT, "core-feedbeef0004-4-dddddddddddd", lock=False, kernel=True)
    old = time.time() - 120
    os.utime(d4, (old, old))
    d5 = plant_backend_dir(case, RT, "core-feedbeef0005-5-eeeeeeeeeeee", lock=False, kernel=True)
    notes = RT / "notes.txt"
    write_private(notes, b"notes\n")
    case.undo.append(lambda: unlink_quiet(notes))

    mark = log_mark()
    core = case.core()
    ping_within(case, core)
    dead_dirs = (d1, d2, d4)
    case.expect(wait_until(lambda: not any(d.exists() for d in dead_dirs), 5),
                f"dead backends' dirs still there 5 s after a start: "
                f"{[d.name for d in dead_dirs if d.exists()]}")
    swept = wait_sweep(mark)
    gone = [p.name for p in (d3, d5, notes) if not os.path.lexists(p)]
    case.expect(not gone, f"removed although they must stay (a held lock, a young dir with no "
                          f"lock, another file){unswept(swept)}: {gone}")
    finish(case, core)
    release()
    core2 = case.core()
    ping_within(case, core2)
    case.expect(wait_until(lambda: not d3.exists(), 5),
                f"the dir whose lock was released is still there 5 s after a start: {d3.name}")


def other_token(tok):
    c = tok[0]
    if c in "0123456789abcdef":
        n = "1" if c == "0" else "0"
    else:
        n = "b" if c == "a" else "a"
    return n + tok[1:]


def c11b(case):
    open_dir = WORK / "c11-open"
    make_dir(open_dir, 0o755)
    env = {"XDG_RUNTIME_DIR": str(open_dir)}
    core = case.core(env_set=env)
    _, new = started_kernel(case, core)
    bds = backend_dirs(JRT, core.p.pid)
    case.require(len(bds) == 1,
                 f"no backend dir of this backend (pid {core.p.pid}) in JRT ({rel(JRT)}), so "
                 f"its host token is unknown; the kernel's connection file is {describe(new)}")
    tok = BDIR_RE.match(bds[0].name)["tok"]
    finish(case, core)
    case.expect(not bds[0].exists(), f"the backend's own dir is still there after it exited: "
                                     f"{rel(bds[0])}")
    ours = plant_backend_dir(case, JRT, f"core-{tok}-6-ffffffffffff")
    other = plant_backend_dir(case, JRT, f"core-{other_token(tok)}-7-ffffffffffff")
    mark = log_mark()
    core2 = case.core(env_set=env)
    ping_within(case, core2)
    case.expect(wait_until(lambda: not ours.exists(), 5),
                f"this host's dead backend dir is still there 5 s after a start: {ours.name}")
    swept = wait_sweep(mark)
    case.expect(other.exists(), f"another host's backend dir was removed{unswept(swept)}: "
                                f"{other.name}")


DAY = 24 * 3600


def plant_foreign(case, name, age):
    """Another host's backend dir in JRT (a lock file, a kernel dir with its
    connection file), every mtime set to age seconds ago: files first, then
    the dirs."""
    d = plant_backend_dir(case, JRT, name, kernel=True)
    k = d / ("kernel-" + "0" * 32)
    t = time.time() - age
    for p in (k / "connection.json", d / "lock", k, d):
        os.utime(p, (t, t))
    return d


def c11c(case):
    open_dir = WORK / "c11c-open"
    make_dir(open_dir, 0o755)
    env = {"XDG_RUNTIME_DIR": str(open_dir)}
    private_root(case, JRT)
    # Tokens no host of ours can have: another host's dirs in a root that can
    # be shared by several hosts.
    old = plant_foreign(case, "core-foreign.node-a-11-aaaaaaaaaaaa", 8 * DAY)
    recent = plant_foreign(case, "core-foreign.node-b-12-bbbbbbbbbbbb", 8 * DAY)
    t = time.time() - DAY
    os.utime(recent / ("kernel-" + "0" * 32) / "connection.json", (t, t))
    locked = plant_foreign(case, "core-foreign.node-c-13-cccccccccccc", 8 * DAY)
    holder = [os.open(locked / "lock", os.O_RDWR)]
    fcntl.flock(holder[0], fcntl.LOCK_EX)

    def release():
        while holder:
            os.close(holder.pop())
    case.undo.append(release)

    mark = log_mark()
    core = case.core(env_set=env)
    ping_within(case, core)
    swept = wait_until(lambda: "runtime sweep: removed" in log_since(mark), 5)
    case.expect(not old.exists(),
                f"another host's dir with nothing changed for 8 days and a free lock is still "
                f"there after a start{'' if swept else ' (no sweep removed anything within 5 s)'}"
                f": {old.name}")
    gone = [p.name for p in (recent, locked) if not p.exists()]
    case.expect(not gone, f"removed although they must stay (a file changed a day ago, a held "
                          f"lock): {gone}")
    finish(case, core)
    release()
    core2 = case.core(env_set=env)
    ping_within(case, core2)
    case.expect(wait_until(lambda: not locked.exists(), 5),
                f"another host's 8-day-old dir whose lock was released is still there 5 s "
                f"after a start: {locked.name}")
    remove_tree(recent)


def plant_legacy(case, age):
    p = LEGACY / f"kernel-{uuid.uuid4()}.json"
    write_private(p, b'{"shell_port": 0}', 0o644)
    if age:
        t = time.time() - age
        os.utime(p, (t, t))
    case.undo.append(lambda: unlink_quiet(p))
    return p


def c12(case):
    if not LEGACY.exists():
        make_dir(LEGACY, 0o755)
        case.undo.append(lambda: rmdir_if_empty(LEGACY))
    old1 = plant_legacy(case, 120)
    fresh = plant_legacy(case, 0)
    notes = LEGACY / "notes.txt"
    write_private(notes, b"notes\n", 0o644)
    case.undo.append(lambda: unlink_quiet(notes))
    mark = log_mark()
    core = case.core()
    ping_within(case, core)
    case.expect(wait_until(lambda: not old1.exists(), 5),
                f"an old connection file is still there 5 s after a start: {rel(old1)}")
    swept = wait_sweep(mark)
    gone = [p.name for p in (fresh, notes) if not p.exists()]
    gone += [] if LEGACY.is_dir() else [rel(LEGACY)]
    case.expect(not gone, f"removed although they must stay (a young file, another file, a dir "
                          f"that is not empty){unswept(swept)}: {gone}")
    finish(case, core)
    unlink_quiet(fresh)
    unlink_quiet(notes)
    old2 = plant_legacy(case, 120)
    core2 = case.core()
    ping_within(case, core2)
    case.expect(wait_until(lambda: not old2.exists() and not LEGACY.exists(), 5),
                f"5 s after a start: {'the old file ' + old2.name if old2.exists() else 'no old file'}"
                f", {listing(LEGACY) if LEGACY.exists() else 'no dir'}")


def c13(case):
    grabber = Grabber()
    grabber.start()
    case.undo.append(grabber.stop)
    core = case.core()
    sid = open_nb(core)
    err, _, secs = start(core, sid, "jnv-slow", timeout=20)
    case.note_tree(core)
    if case.expect(err is None, f"start_kernel jnv-slow failed after {secs:.1f} s: {err}"):
        case.expect(run_print(core, sid, "print(6*7)", "42"), "the kernel did not print 42")
    grabber.stop()
    case.expect(grabber.bound == 0, f"a test socket bound {grabber.bound} of the kernel's ports "
                                    f"before the kernel did")
    case.expect(grabber.refused >= 5, f"only {grabber.refused} of the written ports were "
                                      f"already bound by the kernel")


def c14(case):
    watch = PortWatch()
    watch.start()
    case.undo.append(watch.stop)
    core = case.core()
    sid = open_nb(core)
    err, _, secs = start(core, sid)
    case.note_tree(core)
    watch.stop()
    case.require(err is None, f"start_kernel failed after {secs:.1f} s: {err}")
    case.require(watch.t_first is not None and core.t_resp is not None,
                 "no new connection file with five ports was seen")
    delta = core.t_resp - watch.t_first
    print(f"         C14 start_kernel answered {delta:.3f} s after the ports were in the file "
          f"(start_kernel took {secs:.3f} s)", flush=True)
    # The kernel got port 0 for every socket and wrote the ports it bound back.
    case.expect(watch.first_parse_had_ports is False,
                f"the connection file first read with its ports already in it "
                f"({watch.first_parse_had_ports}), not with port 0 for the kernel to bind")
    case.expect(delta <= 0.5, f"start_kernel answered {delta:.2f} s after the kernel's ports "
                              f"were in the file (limit 0.5 s)")


def c15a(case):
    mark = log_mark()
    watch = PortWatch()
    watch.start()
    case.undo.append(watch.stop)
    core = case.core()
    sid = open_nb(core)
    err, _, secs = start(core, sid, "jnv-reserved")
    case.note_tree(core)
    watch.stop()
    case.require(err is None, f"start_kernel jnv-reserved failed after {secs:.1f} s: {err}")
    case.expect(watch.first_parse_had_ports is True,
                f"the connection file first read with ports {watch.first_parse_had_ports}")
    case.expect(run_print(core, sid, "print(3+4)", "7"), "the kernel did not print 7")
    case.expect(RESERVED_LINE in log_since(mark),
                f"no '{RESERVED_LINE.strip()}' line in core.log")


def c15b(case):
    mark = log_mark()
    grabber = Grabber(one_shot=True)
    grabber.start()
    case.undo.append(grabber.stop)
    core = case.core()
    sid = open_nb(core)
    err, _, secs = start(core, sid, "jnv-reserved-slow", timeout=40)
    case.note_tree(core)
    if case.expect(err is None, f"start_kernel jnv-reserved-slow failed after {secs:.1f} s: "
                                f"{err}"):
        case.expect(run_print(core, sid, "print(5*5)", "25"), "the kernel did not print 25")
    grabber.stop()
    case.expect(grabber.bound == 5, f"the test socket bound {grabber.bound} of the first "
                                    f"attempt's 5 ports")
    n = log_since(mark).count(RETRY_LINE)
    case.expect(n == 1, f"core.log has '{RETRY_LINE}' {n} times, want once")
    bds = backend_dirs(RT, core.p.pid)
    kds = kernel_dirs(bds[0]) if len(bds) == 1 else []
    case.expect(len(bds) == 1 and len(kds) == 1,
                f"want one backend dir with one kernel dir, found {len(bds)} backend dir(s) "
                f"and kernel dirs {[k.name for k in kds]}")


# Run with the kernel's python (it has pyzmq): once a new connection file
# matching one of the patterns in the JSON list argv[1] (and not in the JSON
# list argv[2]) has its ports, bind ZMQ
# sockets on its shell, iopub and control ports, touch argv[3], and answer
# every request on shell with a kernel_info_reply signed with another key,
# then with one not signed at all.
ZMQ_TAKER = r"""
import glob, hashlib, hmac, json, sys, time, uuid
import zmq
patterns, skip, marker = json.loads(sys.argv[1]), set(json.loads(sys.argv[2])), sys.argv[3]
ctx = zmq.Context()
end = time.monotonic() + 60
shell = None
while shell is None and time.monotonic() < end:
    for f in [f for pat in patterns for f in glob.glob(pat)]:
        if f in skip:
            continue
        try:
            with open(f) as fh:
                d = json.load(fh)
        except Exception:
            continue
        ports = [d.get(k) for k in ("shell_port", "iopub_port", "control_port")]
        if not all(isinstance(p, int) and p > 0 for p in ports):
            continue
        socks = []
        for p, kind in zip(ports, (zmq.ROUTER, zmq.PUB, zmq.ROUTER)):
            s = ctx.socket(kind)
            s.bind("tcp://127.0.0.1:%d" % p)
            socks.append(s)
        shell = socks[0]
        open(marker, "w").close()
        break
    time.sleep(0.001)
other_key = uuid.uuid4().hex.encode()
while shell is not None:
    frames = shell.recv_multipart()
    i = frames.index(b"<IDS|MSG>")
    req = json.loads(frames[i + 2])
    hdr = json.dumps({"msg_id": uuid.uuid4().hex, "session": req.get("session", ""),
                      "username": "x", "date": "", "msg_type": "kernel_info_reply",
                      "version": "5.4"}).encode()
    parts = [hdr, frames[i + 2], b"{}", b'{"status": "ok"}']
    sig = hmac.new(other_key, b"".join(parts), hashlib.sha256).hexdigest().encode()
    shell.send_multipart(frames[:i] + [b"<IDS|MSG>", sig] + parts)
    shell.send_multipart(frames[:i] + [b"<IDS|MSG>", b""] + parts)
"""


def c15c(case):
    mark = log_mark()
    marker = WORK / "c15c-taken"
    patterns = [str(r / "core-*" / "kernel-*" / "connection.json") for r in (RT, JRT)]
    patterns.append(str(LEGACY / "kernel-*.json"))
    taker = subprocess.Popen([PY, "-c", ZMQ_TAKER, json.dumps(patterns), json.dumps([str(f) for f in conn_files()]),
                              str(marker)], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                             stderr=subprocess.PIPE)
    case.own.append(taker)
    core = case.core()
    sid = open_nb(core)
    err, _, secs = start(core, sid, "jnv-reserved-slow", timeout=40)
    case.note_tree(core)
    if not marker.exists():
        why = "running" if taker.poll() is None else \
            f"exited: {taker.stderr.read().decode(errors='replace').strip()[-300:]}"
        raise Fail(f"the test's ZMQ sockets did not take the first attempt's ports (taker {why})")
    if case.expect(err is None, f"start_kernel jnv-reserved-slow failed after {secs:.1f} s: {err}"):
        case.expect(run_print(core, sid, "print(6+6)", "12"), "the kernel did not print 12: the "
                                                               "start took the other sockets for it")
    log = log_since(mark)
    case.expect("failed its signature check" in log,
                "core.log does not say a reply that was not signed with the file's key was skipped")
    n = log.count(RETRY_LINE)
    case.expect(n == 1, f"core.log has '{RETRY_LINE}' {n} times, want once")
    bds = backend_dirs(RT, core.p.pid)
    kds = kernel_dirs(bds[0]) if len(bds) == 1 else []
    case.expect(len(bds) == 1 and len(kds) == 1,
                f"want one backend dir with one kernel dir, found {len(bds)} backend dir(s) "
                f"and kernel dirs {[k.name for k in kds]}")


def c16(variant):
    def fn(case):
        base = WORK / "c16"
        base.mkdir(exist_ok=True)
        env_set, env_unset, root, label = {}, (), JRT, "JRT"
        post = []
        if variant == "a":
            d = base / "open"
            make_dir(d, 0o755)
            env_set = {"XDG_RUNTIME_DIR": str(d)}
            post.append(lambda: case.expect(not os.path.lexists(d / "jupynvim"),
                                            f"made {rel(d / 'jupynvim')} in an XDG_RUNTIME_DIR "
                                            f"of mode 755"))
        elif variant == "b":
            d = base / "missing"
            env_set = {"XDG_RUNTIME_DIR": str(d)}
            post.append(lambda: case.expect(not os.path.lexists(d),
                                            f"made the missing XDG_RUNTIME_DIR {rel(d)}"))
        elif variant == "c":
            x, e = base / "xdg", base / "elsewhere"
            make_dir(x)
            make_dir(e)
            os.symlink(e, x / "jupynvim")
            env_set = {"XDG_RUNTIME_DIR": str(x)}
            post.append(lambda: case.expect(os.listdir(e) == [] and (x / "jupynvim").is_symlink(),
                                            f"wrote through the symlink: {listing(e)}"))
        elif variant == "d":
            c = base / "custom"
            deep = c / "deep"
            root, label = deep / "jupynvim", "JUPYNVIM_RUNTIME_DIR/jupynvim"
            env_set = {"JUPYNVIM_RUNTIME_DIR": str(deep)}
            post.append(lambda: case.expect(perm(c) == 0o700 and perm(deep) == 0o700,
                                            f"custom is {mode_text(c)} and custom/deep "
                                            f"{mode_text(deep)}, want 700"))
        elif variant in ("f", "h"):
            # f: a group's shared dir, which its group can write to (setgid);
            # h: a private dir in it. Refused: the next candidate, RT, is used
            shared = base / ("shared" if variant == "f" else "shared-h")
            make_dir(shared, 0o2775)
            want = os.lstat(shared).st_mode & 0o7777
            given = shared
            if variant == "h":
                given = shared / "mine"
                make_dir(given)
            root, label = RT, "RT"
            env_set = {"JUPYNVIM_RUNTIME_DIR": str(given)}
            mark = log_mark()
            why = (f"runtime: not using JUPYNVIM_RUNTIME_DIR {given / 'jupynvim'}: "
                   f"{os.path.realpath(shared)} has mode {want:o}")
            post.append(lambda: case.expect(want & 0o020 and os.lstat(shared).st_mode & 0o7777 == want,
                                            f"{rel(shared)} is mode "
                                            f"{os.lstat(shared).st_mode & 0o7777:o} after the start, "
                                            f"was {want:o}"))
            post.append(lambda: case.expect(not os.path.lexists(given / "jupynvim"),
                                            f"made {rel(given / 'jupynvim')} in a dir its group "
                                            f"can write to: {listing(given)}"))
            post.append(lambda: case.expect(why in log_since(mark),
                                            f"no '{why}' line in core.log"))
        elif variant == "g":
            real, link = base / "real", base / "rlink"
            make_dir(real, 0o755)
            os.symlink(real, link)
            root, label = link / "jupynvim", "JUPYNVIM_RUNTIME_DIR/jupynvim"
            env_set = {"JUPYNVIM_RUNTIME_DIR": str(link)}
            post.append(lambda: case.expect(perm(real) == 0o755 and link.is_symlink()
                                            and (real / "jupynvim").is_dir(),
                                            f"the symlink's target {rel(real)} is {mode_text(real)}, "
                                            f"link {'kept' if link.is_symlink() else 'replaced'}, "
                                            f"jupynvim in it: {listing(real)}"))
        else:
            env_unset = ("XDG_RUNTIME_DIR", "JUPYTER_RUNTIME_DIR")
            root, label = JDRT, "JUPYTER_DATA_DIR/runtime/jupynvim"
        core = case.core(env_set=env_set, env_unset=env_unset)
        extra = () if root in (RT, JRT) else (root,)
        _, new = started_kernel(case, core, extra=extra)
        check_private(case, core, new, root, label)
        for check in post:
            check()
        finish(case, core)
        left = backend_dirs(root)
        case.expect(not left, f"backend dirs left in {label} after the backend exited: "
                              f"{[b.name for b in left]}")
    return fn


def lock_is_held(path):
    """Whether someone holds the flock on path: an exclusive try on it, opened
    for reading and writing, fails (when it succeeds it is released at once)."""
    fd = os.open(path, os.O_RDWR | os.O_NOFOLLOW)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        return True
    finally:
        os.close(fd)
    return False


def own_backend_dir(case, core, new, who="this backend"):
    """(backend dir in RT, kernel dir, connection file) of the one new
    connection file of core."""
    f = one_file(case, new)
    bd, kd = layout_of(f)
    case.require(bd is not None and bd.parent == RT and BDIR_RE.match(bd.name)
                 and int(BDIR_RE.match(bd.name)["pid"]) == core.p.pid,
                 f"no backend dir of {who} (pid {core.p.pid}) in RT; its connection file is "
                 f"{describe(new)}")
    return bd, kd, f


def c18(case):
    start = log_mark()
    a = case.core()
    _, new = started_kernel(case, a)
    bda, kda, fa = own_backend_dir(case, a, new, "backend A")
    lock = bda / "lock"
    # A's start sweep is done before B starts, so the next done line is B's
    case.expect(wait_until(lambda: SWEEP_DONE in log_since(start), 5),
                f"no '{SWEEP_DONE}' line in core.log 5 s after backend A started")
    mark = log_mark()
    b = case.core()
    ping_within(case, b)
    case.expect(wait_until(lambda: SWEEP_DONE in log_since(mark), 5),
                f"no '{SWEEP_DONE}' line in core.log 5 s after backend B started: B's start "
                f"sweep did not run, so this case proves nothing")
    left = [rel(p) for p in (bda, lock, kda, fa) if not p.exists()]
    case.expect(not left, f"another backend's start removed backend A's files while A runs: "
                          f"{left}")
    if lock.is_file():
        case.expect(lock_is_held(lock), f"backend A's lock is not held while A runs: "
                                        f"{rel(lock)}")
    case.expect(run_print(a, a.sid, "print(3*3)", "9"), "backend A's kernel did not print 9")
    started_kernel(case, b)
    case.expect(run_print(b, b.sid, "print(4*4)", "16"), "backend B's kernel did not print 16")
    case.expect(bda.is_dir() and lock.is_file(), f"backend A's dir went when backend B started "
                                                 f"a kernel: {listing(bda)}")
    bdb = backend_dirs(RT, b.p.pid)
    case.expect(len(bdb) == 1, f"backend B has {len(bdb)} backend dirs in RT, want 1")
    finish(case, a)
    finish(case, b)
    still = [rel(d) for d in [bda] + bdb if d.exists()]
    case.expect(not still, f"backend dirs left after both backends exited: {still}")


def c19(case):
    base = WORK / "c19"
    make_dir(base)

    def backend_dir(n):
        d = base / f"core-x-{n}-00000000000{n}"
        make_dir(d)
        write_private(d / "lock")
        k = d / "kernel-y"
        make_dir(k)
        write_private(k / "connection.json", b"{}")
        return d

    def sleeper():
        p = subprocess.Popen(["sleep", "30"], start_new_session=True, stdin=subprocess.DEVNULL,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        case.own.append(p)
        return p

    def guard(d):
        g = subprocess.Popen([str(CORE), "--guard", str(d)], stdin=subprocess.PIPE,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        case.own.append(g)
        return g

    def ready(g):
        # The guard leads a process group (and session) of its own once it
        # has set itself up; then it ignores SIGHUP.
        ok = wait_until(lambda: ps_field(g.pid, "pgid") == str(g.pid), 2)
        if ok:
            time.sleep(0.1)
        return bool(ok)

    def tell(g, line):
        try:
            g.stdin.write(line.encode())
            g.stdin.flush()
        except OSError:
            pass

    d = backend_dir(1)
    s = sleeper()
    g = guard(d)
    tell(g, f"+ {s.pid}\n")
    case.expect(ready(g), "the guard does not lead a process group of its own 2 s after it "
                          "started")
    os.kill(g.pid, signal.SIGHUP)
    time.sleep(0.3)
    case.expect(g.poll() is None, f"the guard ended on SIGHUP (status {g.returncode})")
    try:
        g.stdin.close()
    except OSError:
        pass
    case.expect(wait_until(lambda: s.poll() is not None, 2),
                "the registered process still runs 2 s after the guard's input closed")
    case.expect(wait_until(lambda: not d.exists(), 2),
                f"the backend dir is still there 2 s after the guard's input closed: {listing(d)}")
    try:
        rc = g.wait(2)
    except subprocess.TimeoutExpired:
        rc = None
    case.expect(rc == 0, f"the guard's exit status is {rc}, want 0")

    # SIGTERM ends the guard and nothing else.
    d2 = backend_dir(2)
    s2 = sleeper()
    g2 = guard(d2)
    tell(g2, f"+ {s2.pid}\n")
    case.expect(ready(g2), "the second guard does not lead a process group of its own 2 s "
                           "after it started")
    os.kill(g2.pid, signal.SIGTERM)
    try:
        g2.wait(2)
        ended = True
    except subprocess.TimeoutExpired:
        ended = False
    case.expect(ended, "the guard did not end on SIGTERM")
    time.sleep(0.3)
    case.expect(s2.poll() is None, "SIGTERM to the guard stopped the process registered with it")


def c20(case):
    core = case.core()
    _, new = started_kernel(case, core)
    bd, _, _ = own_backend_dir(case, core, new)
    mark = log_mark()
    shutil.rmtree(bd)  # the kernel keeps running; only its files go
    err, _ = core.call("restart_kernel", {"session_id": core.sid}, timeout=20)
    case.note_tree(core)
    case.require(err is None, f"restart_kernel failed after the backend dir was removed: {err}")
    case.require(bd.is_dir(), f"the backend dir was not made again at {rel(bd)}: {listing(RT)}")
    uid = os.getuid()
    st = os.lstat(bd)
    case.expect(stat.S_ISDIR(st.st_mode) and st.st_mode & 0o777 == 0o700 and st.st_uid == uid,
                f"the backend dir made again is mode {st.st_mode & 0o777:o}, uid {st.st_uid}")
    case.expect(backend_dirs(RT, core.p.pid) == [bd],
                f"this backend's dirs in RT are {[d.name for d in backend_dirs(RT, core.p.pid)]}, "
                f"want only {bd.name}")
    lock = bd / "lock"
    if case.expect(lock.is_file() and perm(lock) == 0o600,
                   f"its lock is {mode_text(lock) if os.path.lexists(lock) else 'missing'}"):
        case.expect(lock_is_held(lock), f"the lock made again is not held: {rel(lock)}")
    conns = [k / "connection.json" for k in kernel_dirs(bd)]
    case.expect(len(conns) == 1 and conns[0].is_file() and perm(conns[0]) == 0o600,
                f"want one kernel dir with a 600 connection.json in it, found {describe(conns)}")
    case.expect(run_print(core, core.sid, "print(5+5)", "10"), "the restarted kernel did not "
                                                                "print 10")
    remade = "was removed while in use; made it again"
    case.expect(remade in log_since(mark), f"no '{remade}' line in core.log")
    finish(case, core)
    case.expect(not bd.exists(), f"the backend dir is still there after the backend exited: "
                                 f"{listing(bd)}")


def c21(case):
    core = case.core()
    sid = open_nb(core)
    before = set(conn_files())
    msgid = core.next_id
    core.next_id += 1
    core._send("start_kernel", {"session_id": sid, "kernel_name": "jnv-hang"}, msgid)
    sh = kernel_pid(core)
    case.require(sh, "no process with ipykernel_launcher under the backend 5 s after "
                     "start_kernel was sent")
    sl = wait_until(lambda: child_with(sh, "sleep"), 5)
    case.note_tree(core)
    case.require(sl, f"no sleep under the start's shell (pid {sh})")
    bdirs = backend_dirs(RT, core.p.pid)
    core._stop = True
    core.p.stdin.close()
    try:
        core.p.wait(10)
    except subprocess.TimeoutExpired:
        raise Fail("the backend did not exit within 10 s of its stdin closing")
    ok = [e for e in core.events if isinstance(e, list) and len(e) > 3 and e[0] == 1
          and e[1] == msgid and e[2] is None]
    case.expect(not ok, "start_kernel answered with success although the kernel never ran")
    named = (("the start's shell", sh), ("its sleep", sl))
    case.expect(wait_until(lambda: dead(sh) and dead(sl), 3),
                f"still running 3 s after the backend exited: {running(named)}")

    def left():
        return sorted(set(files_left(before, bdirs) + backend_dirs(RT, core.p.pid)))
    case.expect(wait_until(lambda: not left(), 3),
                f"files left 3 s after the backend exited: {describe(left())}")


def c22(case):
    core = case.core()
    _, new = started_kernel(case, core, "jnv-child")
    f = one_file(case, new)
    _, kdir = layout_of(f)
    kp = kernel_pid(core)
    case.require(kp, "no kernel process under the backend")
    sl = wait_until(lambda: child_with(kp, "sleep 30"), 5)
    case.note_tree(core)
    case.require(sl, f"no sleep 30 under the kernel (pid {kp})")
    core.call("update_cell_source", {"session_id": core.sid, "cell_id": "c1",
                                     "source": "import os; os._exit(0)"})
    core.call("execute", {"session_id": core.sid, "cell_id": "c1"})
    case.require(wait_until(lambda: dead(kp), 5),
                 f"the kernel (pid {kp}) did not exit on os._exit(0)")
    case.expect(wait_until(lambda: dead(sl), 2),
                f"the sleep (pid {sl}) the kernel left in its process group still runs 2 s after "
                f"the kernel exited")
    gone = wait_until(lambda: not f.exists() and (kdir is None or not kdir.exists()), 2)
    case.expect(gone, f"the kernel's dir is still there 2 s after the kernel exited: "
                      f"{describe([f])}")
    err, res = core.call("ping", {}, timeout=5)
    case.expect(err is None and res == "pong", f"the backend did not answer ping after its "
                                               f"kernel exited: {err}")


def c23(sig):
    def fn(case):
        core = case.core()
        err, res = core.call("ping", {}, timeout=5)
        case.require(err is None and res == "pong", f"the backend did not answer ping: {err}")
        core._stop = True
        t0 = time.monotonic()
        core.p.send_signal(sig)
        try:
            core.p.wait(1)
        except subprocess.TimeoutExpired:
            # Closing its stdin (the frontend going away) ends it.
            core.p.stdin.close()
            raise Fail(f"the backend still runs 1 s after {sig.name} while its stdin stays open")
        print(f"         {case.name.split(':')[0]}: exited {time.monotonic() - t0:.3f} s after "
              f"{sig.name} (status {core.p.returncode})", flush=True)
    return fn


BIG = 4 * 1024 * 1024  # far more than a pipe holds


def read_fifo(fd, deadline, first_only):
    """Reads the FIFO open at fd (O_NONBLOCK) until the writer closed it
    after writing (or, with first_only, until the first bytes arrive), or
    until the deadline: (bytes, closed by the writer)."""
    data = b""
    while time.monotonic() < deadline:
        try:
            chunk = os.read(fd, 1 << 16)
        except BlockingIOError:  # a writer has it open, nothing to read yet
            time.sleep(0.002)
            continue
        if chunk:
            data += chunk
            if first_only:
                return data, False
            continue
        if data:  # end of file after data: the writer closed it
            return data, True
        time.sleep(0.005)  # no writer yet
    return data, False


def c23_save(case):
    """A notebook save in progress when the backend gets SIGTERM, and a file
    write in progress when it gets SIGHUP, both with its stdin open: the
    whole file is written, then the backend exits. Each target is a FIFO, so
    the test sees the write begin and holds it up until it reads."""
    for method, sig in (("save", signal.SIGTERM), ("fs_write", signal.SIGHUP)):
        core = case.core()
        err, res = core.call("ping", {}, timeout=5)
        case.require(err is None and res == "pong", f"the backend did not answer ping: {err}")
        target = WORK / f"c23-{method}.ipynb"
        if method == "save":
            nb = make_test_nb()
            nb["cells"].append({"cell_type": "code", "id": "big", "metadata": {}, "source": "# " + "x" * BIG,
                                "execution_count": None, "outputs": []})
            target.write_text(json.dumps(nb))
            err, res = core.call("open", {"path": str(target)})
            case.require(err is None and isinstance(res, dict), f"open failed: {err}")
            params = {"session_id": res["session_id"]}
            target.unlink()
            want = None
        else:
            want = b"0123456789abcdef" * (BIG // 16)
            params = {"path": str(target), "content_b64": base64.b64encode(want).decode()}
        os.mkfifo(target, 0o600)
        fd = os.open(target, os.O_RDONLY | os.O_NONBLOCK)
        try:
            msgid = core.next_id
            core.next_id += 1
            core._send(method, params, msgid)
            head, _ = read_fifo(fd, time.monotonic() + 10, first_only=True)
            case.require(head, f"{method}: the backend did not begin to write within 10 s")
            # The backend is inside the write now (the pipe is full).
            core._stop = True
            core.p.send_signal(sig)
            t_sig = time.monotonic()
            time.sleep(0.6)
            alive = core.p.poll() is None
            rest, closed = read_fifo(fd, time.monotonic() + 20, first_only=False)
            t_done = time.monotonic()
        finally:
            os.close(fd)
        data = head + rest
        if want is None:
            try:
                cells = json.loads(data)["cells"]
                src = next(c["source"] for c in cells if c.get("id") == "big")
                whole = ("".join(src) if isinstance(src, list) else src) == "# " + "x" * BIG
            except (ValueError, KeyError, StopIteration, TypeError):
                whole = False
        else:
            whole = data == want
        case.expect(whole and closed,
                    f"{method}: the write in progress at {sig.name} was cut: {len(data)} bytes, "
                    f"{'closed' if closed else 'not closed'} by the backend; the backend "
                    f"{'still ran' if alive else 'had exited'} 0.6 s after {sig.name}")
        try:
            core.p.wait(2)
            print(f"         C23 save: {method}: {len(data)} bytes; the backend exited "
                  f"{time.monotonic() - t_sig:.3f} s after {sig.name} "
                  f"({time.monotonic() - t_done:.3f} s after the write ended, status {core.p.returncode})",
                  flush=True)
        except subprocess.TimeoutExpired:
            core.p.stdin.close()
            case.expect(False, f"{method}: the backend still runs 2 s after the write in progress at "
                               f"{sig.name} ended, while its stdin stays open")


def tree_entries(top):
    """How many files and dirs are under top (0 when it is gone)."""
    n = 0
    for _, dirs, files in os.walk(top):
        n += len(dirs) + len(files)
    return n


def make_tree(top, ndirs, per=200):
    """top/d0000 ... with `per` empty files each; returns how many entries."""
    for i in range(ndirs):
        d = top / f"d{i:04d}"
        d.mkdir(parents=True)
        for j in range(per):
            os.close(os.open(d / f"f{j:03d}", os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600))
    return ndirs * (per + 1)


RM_TARGET = 1.0  # seconds a removal in C23 rm should take on this machine now
RM_PROVEN = 0.4  # the removal must still run this long after SIGTERM (the grace is 0.2 s)


def c23_rm(case):
    """A recursive removal (the file browser's fs_rm) in progress when the
    backend gets SIGTERM, with its stdin open: the whole tree is removed,
    then the backend exits. The tree is sized from how fast the backend
    removes files right now, so that its removal runs on for well over the
    exit's grace for other work (0.2 s) and well under its wait for file
    changes (10 s); a run where it ended too soon after SIGTERM to tell is
    repeated with a bigger tree."""
    cal = WORK / "c23-rm-cal"
    tree = WORK / "c23-rm-tree"
    try:
        core = case.core()
        err, res = core.call("ping", {}, timeout=5)
        case.require(err is None and res == "pong", f"the backend did not answer ping: {err}")
        n_cal = make_tree(cal, 20)
        t0 = time.monotonic()
        err, _ = core.call("fs_rm", {"path": str(cal), "recursive": True}, timeout=60)
        cal_s = time.monotonic() - t0
        case.require(err is None and not os.path.lexists(cal), f"fs_rm of {n_cal} entries failed: {err}")
        rate = n_cal / max(cal_s, 0.001)
        ndirs = int(min(max(rate * RM_TARGET / 201, 20), 500))
        for attempt in range(1, 4):
            if attempt > 1:
                core = case.core()
            n = make_tree(tree, ndirs)
            msgid = core.next_id
            core.next_id += 1
            core._send("fs_rm", {"path": str(tree), "recursive": True}, msgid)
            # the removal has begun once one of the dirs is gone
            deadline = time.monotonic() + 20
            left_dirs = ndirs
            while time.monotonic() < deadline:
                try:
                    left_dirs = len(os.listdir(tree))
                except FileNotFoundError:
                    left_dirs = 0
                if left_dirs < ndirs:
                    break
                time.sleep(0.002)
            case.require(left_dirs < ndirs, "fs_rm: the backend did not begin to remove the tree within 20 s")
            core._stop = True
            core.p.send_signal(signal.SIGTERM)
            t_sig = time.monotonic()
            try:
                core.p.wait(15)
            except subprocess.TimeoutExpired:
                core.p.stdin.close()
                raise Fail("fs_rm: the backend still runs 15 s after SIGTERM while its stdin stays open")
            took = time.monotonic() - t_sig
            left = tree_entries(tree)
            note = (f"{n} entries ({rate:.0f} removed a second before), {ndirs - left_dirs} of {ndirs} "
                    f"dirs gone at SIGTERM; the backend exited {took:.3f} s after it "
                    f"(status {core.p.returncode}), {left} entries left")
            print(f"         C23 rm: attempt {attempt}: {note}", flush=True)
            case.require(not os.path.lexists(tree),
                         f"fs_rm: the removal in progress at SIGTERM was cut short: {note}")
            if took >= RM_PROVEN:
                return
            ndirs = min(ndirs * 3, 1500)
        raise Fail(f"fs_rm: in 3 tries the removal never ran {RM_PROVEN} s past SIGTERM, so this run "
                   f"cannot tell whether the exit waits for it")
    finally:
        shutil.rmtree(cal, ignore_errors=True)
        shutil.rmtree(tree, ignore_errors=True)


def c17(case):
    case.expect(not os.path.lexists(LEGACY), f"the old location exists: {listing(LEGACY)}")
    left = conn_files()
    case.expect(not left, f"connection files left: {describe(left)}")
    for root, label in ((RT, "RT"), (JRT, "JRT"), (JDRT, "JUPYTER_DATA_DIR/runtime/jupynvim"),
                        (TRT, "TRT")):
        b = backend_dirs(root)
        case.expect(not b, f"backend dirs left in {label}: {[x.name for x in b]}")


def c24(case):
    """The root moved away while the backend runs, and a dir put in its place
    with a symlink named like the backend dir that points to another dir of
    the user (with a dir named like the kernel dir in it): the exit (stdin
    closed, as on :qa) and the guard leave that dir alone, and the backend
    dir, moved away with its root, is removed."""
    base = WORK / "c24"
    make_dir(base)
    given = base / "given"
    make_dir(given)
    root = given / "jupynvim"
    core = case.core(env_set={"JUPYNVIM_RUNTIME_DIR": str(given)})
    _, new = started_kernel(case, core, extra=(root,))
    check_private(case, core, new, root, "JUPYNVIM_RUNTIME_DIR/jupynvim")
    bd = backend_dirs(root, core.p.pid)[0]
    kd = kernel_dirs(bd)[0]
    kpid = kernel_pid(core)
    g = guard_pid(core)
    case.note(g)
    victim = base / "victim"
    files = [victim / r for r in ("a", "b/c", "b/d/e", "lock", f"{kd.name}/connection.json")]
    for f in files:
        f.parent.mkdir(parents=True, exist_ok=True)
        f.write_bytes(b"x")
    aside = given / "aside"
    os.rename(root, aside)
    make_dir(root)
    os.symlink(victim, root / bd.name)
    core._stop = True
    core.p.stdin.close()
    try:
        core.p.wait(10)
    except subprocess.TimeoutExpired:
        raise Fail("the backend did not exit within 10 s of its stdin closing")
    if case.expect(g is not None, "no guard process"):
        case.expect(wait_until(lambda: dead(g), 2),
                    f"the guard (pid {g}) still runs 2 s after the backend exited")
    case.expect(wait_until(lambda: dead(kpid), 3),
                f"the kernel (pid {kpid}) still runs 3 s after the backend exited")
    gone = [rel(f) for f in files if not f.exists()]
    case.expect(not gone, f"the exit removed files through the symlink at the backend dir's "
                          f"path: {gone}")
    case.expect((root / bd.name).is_symlink(), "the symlink at the backend dir's path is gone")
    moved = aside / bd.name
    case.expect(not os.path.lexists(moved), f"the backend dir moved away with its root is still "
                                            f"there: {listing(moved)}")


def c25(variant):
    """a, b: XDG_RUNTIME_DIR unset (a) or naming a dir that does not exist (b,
    as an srun on a compute node inherits it), JUPYTER_RUNTIME_DIR unset, and
    Jupyter's data dir below dirs the user's group can write to (what umask
    002 and `ipykernel install --user` make): the kernel starts with its file
    in TRT, 0600 in 0700 dirs; nothing is made below the refused dirs;
    core.log says why each candidate was skipped; nothing is left after the
    exit. c: JUPYNVIM_RUNTIME_DIR a sticky dir anyone can write to, holding a
    jupynvim dir an older version made (775, with its file): the root is
    jupynvim-<uid> in it, and that jupynvim is left as it is."""
    def fn(case):
        base = WORK / f"c25{variant}"
        make_dir(base)
        if variant == "c":
            shared = base / "shared"
            make_dir(shared, 0o1777)
            old = shared / "jupynvim"
            make_dir(old, 0o775)
            old_file = old / f"kernel-{uuid.uuid4()}.json"
            write_private(old_file, b"{}", 0o644)
            root, label = shared / f"jupynvim-{os.geteuid()}", "JUPYNVIM_RUNTIME_DIR/jupynvim-<uid>"
            mark = log_mark()
            core = case.core(env_set={"JUPYNVIM_RUNTIME_DIR": str(shared)})
            _, new = started_kernel(case, core, extra=(root,))
            check_private(case, core, new, root, label)
            want = f"runtime: kernel files in {root} (JUPYNVIM_RUNTIME_DIR)"
            case.expect(want in log_since(mark), f"no '{want}' line in core.log")
            finish(case, core)
            case.expect(perm(old) == 0o775 and sorted(os.listdir(old)) == [old_file.name],
                        f"the jupynvim already there was changed: {mode_text(old)}, {listing(old)}")
            case.expect(perm(shared) == 0o777 and os.stat(shared).st_mode & 0o1000,
                        f"the dir given was changed: {mode_text(shared)}")
            left = backend_dirs(root)
            case.expect(not left, f"backend dirs left in {label}: {[b.name for b in left]}")
            return
        home = base / "home"
        make_dir(home)
        jdata = home / ".local" / "share" / "jupyter"
        for d in (home / ".local", home / ".local" / "share", jdata):
            make_dir(d, 0o775)
        env_set = {"JUPYTER_DATA_DIR": str(jdata)}
        env_unset = ["JUPYTER_RUNTIME_DIR"]
        missing = base / "run-missing"
        if variant == "a":
            env_unset.append("XDG_RUNTIME_DIR")
        else:
            env_set["XDG_RUNTIME_DIR"] = str(missing)
        mark = log_mark()
        core = case.core(env_set=env_set, env_unset=tuple(env_unset))
        _, new = started_kernel(case, core)
        check_private(case, core, new, TRT, "TRT")
        log = log_since(mark)
        whys = [f"runtime: not using Jupyter runtime dir {jdata / 'runtime' / 'jupynvim'}: "
                f"{os.path.realpath(home / '.local')} has mode 775",
                f"runtime: kernel files in {TRT} (system temp dir)"]
        if variant == "b":
            whys.append(f"runtime: not using XDG_RUNTIME_DIR {missing / 'jupynvim'}: "
                        f"{missing} does not exist")
        for why in whys:
            case.expect(why in log, f"no '{why}' line in core.log")
        case.expect(not os.path.lexists(jdata / "runtime"),
                    f"made {rel(jdata / 'runtime')} below a dir its group can write to")
        case.expect(not os.path.lexists(missing), f"made the missing XDG_RUNTIME_DIR {rel(missing)}")
        case.expect(perm(jdata) == 0o775 and perm(home / ".local") == 0o775,
                    f"the user's dirs were changed: {mode_text(home / '.local')}, {mode_text(jdata)}")
        finish(case, core)
        left = backend_dirs(TRT)
        case.expect(not left, f"backend dirs left in TRT after the backend exited: "
                              f"{[b.name for b in left]}")
    return fn


def acl_lines(p):
    """The access control list entries `ls -le` shows for p itself (macOS)."""
    out = subprocess.run(["/bin/ls", "-led", str(p)], capture_output=True, text=True).stdout
    return [ln.strip() for ln in out.splitlines()[1:] if ln.strip()]


def c26(case):
    """JUPYNVIM_RUNTIME_DIR a 755 dir whose access control list lets everyone
    add and delete entries: refused (a WARN line names the entry), RT used,
    nothing made in it. Linux: a POSIX ACL entry that lets another user
    write, set on a 755 dir, shows as mode 775 and is refused the same way.
    macOS also: a root made in a dir with entries its subdirs inherit keeps
    none, nor do the backend dir, the kernel dir and the file."""
    base = WORK / "c26"
    make_dir(base)
    d = base / "acl"
    make_dir(d, 0o755)
    case.undo.append(lambda: scrub(base))
    if sys.platform == "darwin":
        r = subprocess.run(["/bin/chmod", "+a", "group:everyone allow add_file,add_subdirectory,"
                            "delete_child", str(d)], capture_output=True, text=True)
        case.require(r.returncode == 0, f"chmod +a failed: {r.stderr.strip()}")
        why = (f"runtime: not using JUPYNVIM_RUNTIME_DIR {d / 'jupynvim'}: {os.path.realpath(d)} "
               f"has an access control list entry that gives group 12 "
               f"add_file,add_subdirectory,delete_child")
    else:
        # system.posix_acl_access: version 2, then (tag, perm, id) entries:
        # the owner rwx, user 4242 rwx, the group r-x, the mask rwx, others r-x
        entries = [(0x01, 7, 0xFFFFFFFF), (0x02, 7, 4242), (0x04, 5, 0xFFFFFFFF),
                   (0x10, 7, 0xFFFFFFFF), (0x20, 5, 0xFFFFFFFF)]
        blob = struct.pack("<I", 2) + b"".join(struct.pack("<HHI", *e) for e in entries)
        try:
            os.setxattr(d, "system.posix_acl_access", blob)
        except OSError as e:
            raise Fail(f"cannot set a POSIX ACL on {rel(d)}: {e}")
        case.require(perm(d) == 0o775, f"the ACL left mode {mode_text(d)}, want 775")
        why = (f"runtime: not using JUPYNVIM_RUNTIME_DIR {d / 'jupynvim'}: {os.path.realpath(d)} "
               f"has mode 775")
    mark = log_mark()
    core = case.core(env_set={"JUPYNVIM_RUNTIME_DIR": str(d)})
    _, new = started_kernel(case, core)
    check_private(case, core, new, RT, "RT")
    case.expect(why in log_since(mark), f"no '{why}' line in core.log")
    case.expect(not os.path.lexists(d / "jupynvim"), f"made a root in it: {listing(d)}")
    finish(case, core)
    if sys.platform != "darwin":
        return
    p = base / "inherit"
    make_dir(p)
    r = subprocess.run(["/bin/chmod", "+a", "group:everyone allow list,search,read,file_inherit,"
                        "directory_inherit", str(p)], capture_output=True, text=True)
    case.require(r.returncode == 0, f"chmod +a failed: {r.stderr.strip()}")
    root = p / "jupynvim"
    mark = log_mark()
    core = case.core(env_set={"JUPYNVIM_RUNTIME_DIR": str(p)})
    _, new = started_kernel(case, core, extra=(root,))
    bd, kd, conn = check_private(case, core, new, root, "JUPYNVIM_RUNTIME_DIR/jupynvim")
    for x in (root, bd, kd, conn, bd / "lock"):
        lines = acl_lines(x)
        case.expect(not lines, f"{rel(x)} has access control list entries: {lines}")
    want = f"runtime: removed the access control list of {root}"
    case.expect(want in log_since(mark), f"no '{want}' line in core.log")
    finish(case, core)
    left = backend_dirs(root)
    case.expect(not left, f"backend dirs left after the backend exited: {[b.name for b in left]}")


def deep_chain(top, depth, side=None):
    """top/c/c/.../c, depth dirs, made without working more than two levels
    below top (each new dir is made in top and the chain moved into it);
    side(i, d) runs on the chain's top dir d when it is i levels from the
    bottom."""
    top = Path(top)
    os.mkdir(top / "c", 0o700)
    for i in range(1, depth):
        if side:
            side(i, top / "c")
        os.mkdir(top / "p", 0o700)
        os.rename(top / "c", top / "p" / "c")
        os.rename(top / "p", top / "c")


REMOVE_WARN = "runtime: cannot remove "


def c27(case):
    """A tree 3000 dirs deep in a kernel's dir (only the user's own code can
    put one there), with the backend limited to 256 open files: stop_kernel
    removes it, the backend still answers, nothing is logged. With an entry
    deep inside that cannot be removed (a file in a dir without the write
    bit): the rest goes, and core.log gets one line. A dead backend dir
    holding such a tree goes in the next backend's start sweep, which keeps
    running too."""
    depth = 3000
    core = case.core(nofile=256)
    started_kernel(case, core)
    bd = backend_dirs(RT, core.p.pid)
    case.require(len(bd) == 1, "no backend dir of this backend in RT")
    bd = bd[0]
    # what a failed removal leaves would be too deep for the other cases'
    # checks and for shutil
    case.undo.append(lambda: scrub(bd))
    kd = kernel_dirs(bd)[0]
    deep_chain(kd, depth)
    mark = log_mark()
    err, _ = core.call("stop_kernel", {"session_id": core.sid}, timeout=60)
    case.require(err is None, f"stop_kernel failed: {err}")
    case.expect(wait_until(lambda: not kd.exists(), 30),
                f"the kernel dir with a tree {depth} dirs deep is still there 30 s after "
                f"stop_kernel: {listing(kd)}")
    err, res = core.call("ping", {}, timeout=5)
    case.expect(err is None and res == "pong" and core.p.poll() is None,
                f"the backend no longer answers after stop_kernel (rc {core.p.poll()}, err {err})")
    lines = [ln for ln in log_since(mark).splitlines() if REMOVE_WARN in ln]
    case.expect(not lines, f"{len(lines)} '{REMOVE_WARN}' line(s) in core.log: "
                           f"{short_cmd(lines[0]) if lines else ''}")

    # one entry that cannot be removed, 1500 dirs down
    err, _ = core.call("start_kernel", {"session_id": core.sid}, timeout=20)
    case.require(err is None, f"the second start_kernel failed: {err}")
    case.note_tree(core)
    kd2 = kernel_dirs(bd)
    case.require(len(kd2) == 1, f"expected one kernel dir, found {[k.name for k in kd2]}")
    kd2 = kd2[0]

    def side(i, d):
        if i == depth // 2:
            os.mkdir(d / "ro", 0o700)
            write_private(d / "ro" / "x")
            os.chmod(d / "ro", 0o500)
    deep_chain(kd2, depth, side)
    case.undo.append(lambda: scrub(kd2))
    mark = log_mark()
    err, _ = core.call("stop_kernel", {"session_id": core.sid}, timeout=60)
    case.require(err is None, f"stop_kernel failed: {err}")
    err, res = core.call("ping", {}, timeout=5)
    case.expect(err is None and res == "pong" and core.p.poll() is None,
                f"the backend no longer answers after stop_kernel (rc {core.p.poll()}, err {err})")
    lines = wait_until(lambda: [ln for ln in log_since(mark).splitlines() if REMOVE_WARN in ln], 30) or []
    time.sleep(0.2)
    lines = [ln for ln in log_since(mark).splitlines() if REMOVE_WARN in ln]
    case.expect(len(lines) == 1 and "1 entry in it could not be removed" in lines[0]
                and "Permission denied" in lines[0] and len(lines[0]) < 1000,
                f"want one '{REMOVE_WARN}' line naming 1 entry, got {len(lines)}: "
                f"{short_cmd(lines[0]) if lines else ''}")
    case.expect(kd2.exists(), "the kernel dir went with an entry it could not remove")
    # writable again: the exit removes the rest with the backend dir
    subprocess.run(["/bin/chmod", "-R", "u+rwx", str(kd2)], capture_output=True)
    finish(case, core)
    case.expect(not bd.exists(), f"the backend dir is still there after the exit: {listing(bd)}")

    # a dead backend dir of this host (its lock free) with such a tree: the
    # next start's sweep
    tok = BDIR_RE.match(bd.name)["tok"]
    dead = plant_backend_dir(case, RT, f"core-{tok}-6-ffffffffffff", kernel=True)
    case.undo.append(lambda: scrub(dead))
    deep_chain(dead / ("kernel-" + "0" * 32), depth)
    mark = log_mark()
    core2 = case.core(nofile=256)
    swept = wait_until(lambda: not dead.exists(), 60)
    case.expect(swept, f"the dead backend dir with a tree {depth} dirs deep is still there 60 s "
                       f"after a start{unswept(wait_sweep(mark, 1))}")
    err, res = core2.call("ping", {}, timeout=5)
    case.expect(err is None and res == "pong" and core2.p.poll() is None,
                f"the backend no longer answers after its start sweep (rc {core2.p.poll()})")
    lines = [ln for ln in log_since(mark).splitlines() if REMOVE_WARN in ln]
    case.expect(not lines, f"{len(lines)} '{REMOVE_WARN}' line(s) in core.log: "
                           f"{short_cmd(lines[0]) if lines else ''}")
    finish(case, core2)


CASES = [
    ("C1", "C1 the files are private", c_private(None)),
    ("C2", "C2 the files are private under umask 000", c_private(0)),
    ("C3", "C3 stop_kernel removes the kernel's dir", c3),
    ("C3b", "C3b a kernel that exits by itself takes its dir with it", c3b),
    ("C4", "C4 restart_kernel replaces the kernel's dir", c4),
    ("C5-eof", "C5 backend exit removes everything (stdin closed)", c5("eof")),
    ("C5-term", "C5 backend exit removes everything (SIGTERM)", c5("term")),
    ("C5-hup", "C5 backend exit removes everything (SIGHUP)", c5("hup")),
    ("C6", "C6 backend killed: kernel stopped and files removed", c6),
    ("C7", "C7 backend killed: a kernel behind a wrapper stops too", c7),
    ("C8", "C8 stop_kernel stops a wrapper's kernel too", c8),
    ("C9", "C9 the kernel exits without its backend, and the next start removes the files", c9),
    ("C10", "C10 the guard comes back when it dies", c10),
    ("C11a", "C11a the start sweep removes only dead backends' dirs (RT)", c11a),
    ("C11b", "C11b the start sweep keeps other hosts' dirs (Jupyter runtime dir)", c11b),
    ("C11c", "C11c another host's old dirs in a shared root go, recent or locked ones stay",
     c11c),
    ("C12", "C12 old connection files go at the next start", c12),
    ("C13", "C13 ports are bound by the kernel before they are written", c13),
    ("C14", "C14 start_kernel answers right after the kernel bound its ports", c14),
    ("C15a", "C15a kernels that do not write ports back get reserved ports", c15a),
    ("C15b", "C15b a reserved start whose ports are taken is retried", c15b),
    ("C15c", "C15c a reserved start counts only an answer signed with the file's key", c15c),
    ("C16a", "C16a XDG_RUNTIME_DIR of mode 755: the Jupyter runtime dir", c16("a")),
    ("C16b", "C16b XDG_RUNTIME_DIR missing: the Jupyter runtime dir", c16("b")),
    ("C16c", "C16c XDG_RUNTIME_DIR/jupynvim a symlink: the Jupyter runtime dir", c16("c")),
    ("C16d", "C16d JUPYNVIM_RUNTIME_DIR, missing parents made 0700", c16("d")),
    ("C16e", "C16e no XDG or Jupyter runtime dir: JUPYTER_DATA_DIR/runtime", c16("e")),
    ("C16f", "C16f JUPYNVIM_RUNTIME_DIR its group can write to: refused, the next one used",
     c16("f")),
    ("C16g", "C16g JUPYNVIM_RUNTIME_DIR a symlink to a dir", c16("g")),
    ("C16h", "C16h JUPYNVIM_RUNTIME_DIR below a dir its group can write to: refused", c16("h")),
    ("C18", "C18 one backend's start leaves another live backend alone", c18),
    ("C19", "C19 the guard on its own", c19),
    ("C20", "C20 a backend dir removed while its backend runs comes back", c20),
    ("C21", "C21 a kernel start in flight when the backend exits is stopped too", c21),
    ("C22", "C22 a kernel's leftover child stops with it", c22),
    ("C23-term", "C23 term: the backend exits on SIGTERM while its stdin stays open",
     c23(signal.SIGTERM)),
    ("C23-hup", "C23 hup: the backend exits on SIGHUP while its stdin stays open",
     c23(signal.SIGHUP)),
    ("C23-save", "C23 save: a save or file write in progress at SIGTERM or SIGHUP is finished first",
     c23_save),
    ("C23-rm", "C23 rm: a recursive removal in progress at SIGTERM is finished first", c23_rm),
    ("C24", "C24 the exit removes its backend dir through the root it holds open", c24),
    ("C25a", "C25a no XDG_RUNTIME_DIR, Jupyter's dir below a dir its group can write to: TRT",
     c25("a")),
    ("C25b", "C25b XDG_RUNTIME_DIR missing, Jupyter's dir below a dir its group can write to: TRT",
     c25("b")),
    ("C25c", "C25c JUPYNVIM_RUNTIME_DIR a sticky dir anyone can write to: jupynvim-<uid> in it",
     c25("c")),
    ("C26", "C26 a dir whose access control list lets others add and delete entries is refused",
     c26),
    ("C27", "C27 a tree thousands of dirs deep goes without stopping the backend", c27),
    ("C17", "C17 nothing left in the old location or the runtime dirs", c17),
]


def run_case(name, fn):
    case = Case(name)
    t0 = time.monotonic()
    try:
        fn(case)
    except Fail as e:
        case.fails.append(str(e))
    except Exception as e:
        case.fails.append(f"crash: {e!r}")
    finally:
        try:
            case.cleanup()
        except Exception as e:
            case.fails.append(f"cleanup crash: {e!r}")
    report(f"{name} ({time.monotonic() - t0:.1f} s)", not case.fails, "; ".join(case.fails))


def done(t0):
    print(f"\n  runtime {time.monotonic() - t0:.1f} s")
    print(f"connfiles: {PASS}/{PASS + FAIL} passed")
    sys.exit(0 if FAIL == 0 else 1)


def main(argv):
    t0 = time.monotonic()
    print("connfiles spec: kernel connection files")
    why = init_paths()
    if why:
        report("a run environment is active", False, why)
        done(t0)
    try:
        if IMPORT_ERROR is not None:
            report("import backend_integration", False, repr(IMPORT_ERROR))
            done(t0)
        if not CORE.is_file():
            report("the backend binary is built", False, str(CORE))
            done(t0)
        provision()
        wanted = [a for a in argv if a]
        for cid, name, fn in CASES:
            # C1 is C1 alone; C3 takes C3b, C5 the three C5 runs, C16 C16a to C16e
            if wanted and not any(cid == w or (cid.startswith(w) and not cid[len(w)].isdigit())
                                  for w in wanted):
                continue
            run_case(name, fn)
    finally:
        shutil.rmtree(WORK, ignore_errors=True)
    done(t0)


if __name__ == "__main__":
    main(sys.argv[1:])
