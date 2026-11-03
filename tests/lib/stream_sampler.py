"""Follow the processes that carry a run of tests/stream_measure_screen.sh.

usage: python3 -I tests/lib/stream_sampler.py RUN PID [PID...]

PID are the roots (the multiplexer's server and the pane's process); their
descendants are followed too, looked up once a second (proc_listpids on macOS, a
system call per process, because one ps there costs 2 % of a core; one ps
elsewhere). 20 times a second the sampler reads every followed process's CPU
seconds and the seconds it was runnable but waiting for a CPU (proc_counters of
tests/lib/vkitty/perfclock.py: proc_pid_rusage on macOS, /proc/<pid>/schedstat on
Linux) and appends one line to RUN/procs.jsonl:

  {"t": <time.monotonic()>, "m": <the last mark in RUN/marks.log or null>,
   "p": {"<pid>": [<cpu seconds>, <seconds waiting for a CPU>], ...},
   "idle": <the share of all the host's CPU time that was idle since the previous
            reading, 0 to 1, or null when the platform does not tell>}

The test appends each mark's name to RUN/marks.log once the recorder has
acknowledged it, so every line says which step the run was in. When a round finds
several new marks (two marks closer together than a round), each gets a line of its
own with that round's readings, so no mark is left without a reading. The sampler stops
after one last round when RUN/end exists, when every root has been gone for 2 s,
or after 900 s. On a platform without counters it writes one line with "p": {}
and "unknown": true and exits 0. Any error is one line on stderr and exit 2.

Stdlib only: the harness's package (numpy, Pillow) is not imported, perfclock.py
is loaded by its path.
"""
import ctypes
import importlib.util
import json
import os
import subprocess
import sys
import time

sys.dont_write_bytecode = True

ROUND_S = 0.05          # one round
TREE_EVERY = 20         # rounds between two looks at the process tree
GONE_S = 2.0            # every root gone this long ends the run
MAX_S = 900.0
PROC_PPID_ONLY = 6      # proc_listpids: the children of one process (sys/proc_info.h)


def load_counters():
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "vkitty", "perfclock.py")
    spec = importlib.util.spec_from_file_location("jnv_perfclock", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod.proc_counters


def stat_ticks(line):
    """(idle, total) ticks of the first line of /proc/stat: idle with iowait, the total without
    guest time, which user time already holds."""
    f = [int(x) for x in line.split()[1:]]
    return f[3] + (f[4] if len(f) > 4 else 0), sum(f[:8])


def host_ticks():
    """A function giving the host's (idle, total) CPU ticks of all CPUs, or None."""
    if sys.platform == "darwin":
        try:
            lib = ctypes.CDLL(None)
            lib.mach_host_self.restype = ctypes.c_uint
            lib.host_processor_info.argtypes = [ctypes.c_uint, ctypes.c_int, ctypes.POINTER(ctypes.c_uint),
                                                ctypes.POINTER(ctypes.c_void_p), ctypes.POINTER(ctypes.c_uint)]
            lib.vm_deallocate.argtypes = [ctypes.c_uint, ctypes.c_void_p, ctypes.c_size_t]
            task = ctypes.c_uint.in_dll(lib, "mach_task_self_")
            host = lib.mach_host_self()
        except (AttributeError, OSError, ValueError):
            return None

        def read():
            n, info, cnt = ctypes.c_uint(), ctypes.c_void_p(), ctypes.c_uint()
            if lib.host_processor_info(host, 2, ctypes.byref(n), ctypes.byref(info),
                                       ctypes.byref(cnt)) != 0:
                return None
            arr = ctypes.cast(info, ctypes.POINTER(ctypes.c_int))
            idle = total = 0
            for i in range(n.value):
                t = [arr[i * 4 + k] & 0xFFFFFFFF for k in range(4)]   # user, system, idle, nice
                idle += t[2]
                total += sum(t)
            lib.vm_deallocate(task.value, info, cnt.value * 4)
            return idle, total
        return read if read() else None
    if sys.platform.startswith("linux"):
        def read():
            try:
                with open("/proc/stat", encoding="ascii") as fh:
                    return stat_ticks(fh.readline())
            except (OSError, ValueError, IndexError):
                return None
        return read if read() else None
    return None


def child_lister():
    """A function giving a pid's children with one system call, or None where the platform has
    none. A look that fails gives no children (proc_listpids returns 0 then, as for a process
    with none), and tree() keeps what it knew."""
    if sys.platform != "darwin":
        return None
    try:
        fn = ctypes.CDLL(None).proc_listpids
    except (AttributeError, OSError):
        return None
    fn.argtypes = [ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p, ctypes.c_int]
    fn.restype = ctypes.c_int
    buf = (ctypes.c_int * 4096)()

    def children(pid):
        got = fn(PROC_PPID_ONLY, pid, buf, ctypes.sizeof(buf))
        return [p for p in buf[:max(0, got) // ctypes.sizeof(ctypes.c_int)] if p > 0]
    return children


def ps_children():
    """Every process's children from one ps, or None when it fails or takes too long."""
    try:
        out = subprocess.run(["ps", "-axo", "pid=,ppid="], capture_output=True, text=True,
                             timeout=5).stdout
    except (subprocess.TimeoutExpired, OSError):
        return None
    kids = {}
    for line in out.splitlines():
        f = line.split()
        if len(f) == 2 and f[0].isdigit() and f[1].isdigit():
            kids.setdefault(int(f[1]), []).append(int(f[0]))
    return kids


def tree(roots, known, children=None):
    """known plus every descendant of the roots now, the walk going through processes already
    known, so a child they started since the last look is found. children(pid) gives a pid's
    children; without it one ps gives them all. A look that fails leaves the set as it is: the
    set only grows."""
    if children is None:
        kids = ps_children()
        if kids is None:
            return known
        children = kids.get
    seen = set()
    todo = list(roots)
    while todo:
        pid = todo.pop()
        if pid not in seen:
            seen.add(pid)
            todo.extend(children(pid) or ())
    return known | seen


class Marks:
    """The complete lines of marks.log, read from where the previous round stopped."""

    def __init__(self, path):
        self.path, self.off, self.rest, self.last = path, 0, b"", None

    def poll(self):
        """The names that arrived since the last call, in order; self.last is the newest."""
        try:
            with open(self.path, "rb") as fh:
                fh.seek(self.off)
                data = fh.read()
        except OSError:
            return []
        self.off += len(data)
        lines = (self.rest + data).split(b"\n")
        self.rest = lines.pop()
        names = [ln.strip().decode("utf-8", "replace") for ln in lines if ln.strip()]
        if names:
            self.last = names[-1]
        return names


def main(argv):
    if len(argv) < 3 or not all(a.isdigit() for a in argv[2:]):
        print("stream_sampler: usage: stream_sampler.py RUN PID [PID...]", file=sys.stderr)
        return 2
    run, roots = argv[1], [int(a) for a in argv[2:]]
    proc_counters = load_counters()
    marks = Marks(os.path.join(run, "marks.log"))
    known = set(roots)
    children = child_lister()
    ticks = host_ticks()
    before = ticks() if ticks else None
    start = time.monotonic()
    # the first reading comes a round after the host's first ticks, so its
    # idle share covers a round too (right after them no tick may have passed)
    nxt = start + (ROUND_S if before else 0.0)
    time.sleep(max(0.0, nxt - time.monotonic()))
    gone_since = None
    n = 0
    with open(os.path.join(run, "procs.jsonl"), "a") as out:
        while True:
            last = os.path.exists(os.path.join(run, "end"))
            if n % TREE_EVERY == 0:
                known = tree(roots, known, children)
            new = marks.poll()
            m = marks.last
            now = time.monotonic()
            p = {}
            for pid in sorted(known):
                c = proc_counters(pid)
                if c is not None:
                    p[str(pid)] = [round(c[0], 6), round(c[1], 6)]
            if n == 0 and not p:
                out.write(json.dumps({"t": round(now, 4), "m": m, "p": {}, "unknown": True}) + "\n")
                out.flush()
                return 0
            idle = None
            if ticks:
                after = ticks()
                if after and before and after[1] > before[1]:
                    idle = round((after[0] - before[0]) / (after[1] - before[1]), 3)
                before = after
            for name in new[:-1]:
                out.write(json.dumps({"t": round(now, 4), "m": name, "p": p}, separators=(",", ":")) + "\n")
            out.write(json.dumps({"t": round(now, 4), "m": m, "p": p, "idle": idle}, separators=(",", ":")) + "\n")
            out.flush()
            n += 1
            if last or now - start >= MAX_S:
                return 0
            if any(str(r) in p for r in roots):
                gone_since = None
            elif gone_since is None:
                gone_since = now
            elif now - gone_since >= GONE_S:
                return 0
            nxt += ROUND_S
            now = time.monotonic()
            if nxt < now:
                nxt = now
            time.sleep(nxt - now)


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except Exception as e:  # one line for the test to fail on
        print("stream_sampler: %s: %s" % (type(e).__name__, e), file=sys.stderr)
        sys.exit(2)
