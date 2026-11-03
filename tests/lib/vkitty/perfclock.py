"""The clock of the timed cases of tests/vkitty_spec.py (not an entry point).

A timing limit is only as good as the measurement it is compared with, and a shared machine slows
a measurement without any change to the code: the process waits for a CPU, or runs on the slow
cores. This module decides a limit on the measurements the host did not disturb.

  - In-process work (a stream fed in pieces, one render, one relay read) is measured in samples
    with `timed`. A sample is clean when its time on efficiency cores is at most 5 % of its wall
    time (plus 0.2 ms) and either it had no involuntary context switch or the time it was not
    running (wall time minus the thread's CPU time) is at most 5 % of its wall time (plus 0.2
    ms). Blocking (a wait in a select, a read or a lock) is a voluntary switch, so it counts as the
    code's own time and a regression that blocks still fails its limit. (macOS counts a wait in
    time.sleep as an involuntary switch, which README.md lists as a known gap.)
  - Work in other processes (the relay, its child, the live terminal's worker) is followed by a
    `ProcSampler` thread. A run is clean when, summed over those processes, the time they waited
    for a CPU plus their CPU time on efficiency cores is at most 10 % of their CPU time plus 5 ms.
  - A limit passes on any measurement within it (a busy host only makes a measurement slower),
    fails when the clean measurements are beyond it, and is undecided when the host left no clean
    measurement: the case then passes with a note that says so. The limits themselves are not
    changed, and a quiet host decides every one.

Off core time is read on macOS only (proc_pid_rusage, flavor 6). Elsewhere it is unknown (None),
and the rule rests on involuntary switches and lost time.
"""
import collections
import ctypes
import os
import resource
import sys
import threading
import time

# a sample: off core and lost time at most 5 % of wall + 0.2 ms
SHARE, SLACK = 0.05, 0.0002
# followed processes: wait + off core at most 10 % of CPU + 5 ms
PROC_SHARE, PROC_SLACK = 0.10, 0.005
MIN_SHARE, MIN_CLEAN, MIN_CLEAN_READS, TRIES = 0.2, 8, 100, 3
PASS, FAIL, UNDECIDED = "pass", "fail", "undecided"

Verdict = collections.namedtuple("Verdict", "state value basis share")


class Sample:
    """One measurement. value is the figure a median is taken over (the wall time unless the
    caller sets another); clean says the host did not disturb it."""
    __slots__ = ("units", "value", "wall", "cpu", "lost", "switches", "offcore", "clean")

    def __init__(self, units, value, wall, cpu, lost, switches, offcore, clean):
        self.units = units
        self.value = value
        self.wall = wall
        self.cpu = cpu
        self.lost = lost
        self.switches = switches
        self.offcore = offcore
        self.clean = clean

    def __repr__(self):
        return "Sample(%s)" % ", ".join("%s=%r" % (name, getattr(self, name))
                                        for name in self.__slots__)


# ---------------------------------------------------------------- counters ---
# The full rusage_info_v6 of the macOS SDK (sys/resource.h): the 16 byte uuid as two 64 bit words
# and 56 more 64 bit fields, ri_reserved[6] included. Times are in mach ticks.
_V6_FIELDS = (
    "uuid0", "uuid1", "user", "system", "pkg_idle", "intr", "pageins", "wired", "resident",
    "phys", "start", "exit", "c_user", "c_system", "c_idle", "c_intr", "c_pageins", "c_elapsed",
    "dread", "dwritten", "q_default", "q_maint", "q_bg", "q_util", "q_legacy", "q_ui", "q_uint",
    "billed", "serviced", "lwrites", "lmax", "instructions", "cycles", "benergy", "senergy",
    "imax", "runnable", "flags", "user_p", "system_p", "pinstructions", "pcycles", "energy",
    "penergy", "sec", "secp", "neural", "lneural", "ineural", "conclave", "pagewait", "pagehits",
    "r0", "r1", "r2", "r3", "r4", "r5")
_RUSAGE_INFO_V6 = 6


class _TimebaseInfo(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]


_libc = None
_info_type = None
_tick = 0.0          # seconds per mach tick


def _probe():
    """Find proc_pid_rusage and the tick length; leave _libc None where flavor 6 does not work."""
    global _libc, _info_type, _tick
    if sys.platform != "darwin":
        return
    try:
        libc = ctypes.CDLL(None, use_errno=True)
        libc.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
        info_type = type("_RusageInfoV6", (ctypes.Structure,),
                         {"_fields_": [(name, ctypes.c_uint64) for name in _V6_FIELDS]})
        base = _TimebaseInfo()
        libc.mach_timebase_info(ctypes.byref(base))
        if not base.denom:
            return
        info = info_type()
        if libc.proc_pid_rusage(os.getpid(), _RUSAGE_INFO_V6, ctypes.byref(info)) != 0:
            return
    except (AttributeError, OSError, ValueError):
        return
    _libc, _info_type = libc, info_type
    _tick = base.numer / base.denom / 1e9


_probe()
_WHO = getattr(resource, "RUSAGE_THREAD", resource.RUSAGE_SELF)


def _switches():
    """Involuntary context switches: of this thread where the system counts them per thread
    (Linux), else of this process."""
    return resource.getrusage(_WHO).ru_nivcsw


def _v6(pid):
    """The rusage_info_v6 of a process, or None when it is gone or not ours to read."""
    info = _info_type()
    if _libc.proc_pid_rusage(pid, _RUSAGE_INFO_V6, ctypes.byref(info)) != 0:
        return None
    return info


def offcore_seconds():
    """CPU seconds this process has spent on efficiency cores (macOS), or None when that is not
    known on this platform."""
    if _libc is None:
        return None
    info = _v6(os.getpid())
    if info is None:
        return None
    return ((info.user + info.system) - (info.user_p + info.system_p)) * _tick


def proc_counters(pid):
    """(cpu seconds, seconds waiting for a CPU, seconds on efficiency cores or None) of a process
    since it started, or None when the process is gone or the platform has no such counters."""
    if _libc is not None:
        info = _v6(pid)
        if info is None:
            return None
        cpu = (info.user + info.system) * _tick
        wait = max(0.0, info.runnable * _tick - cpu)
        offcore = max(0.0, cpu - (info.user_p + info.system_p) * _tick)
        return cpu, wait, offcore
    if sys.platform.startswith("linux"):
        try:
            with open("/proc/%d/schedstat" % pid, encoding="ascii") as fh:
                fields = fh.read().split()
            return int(fields[0]) / 1e9, int(fields[1]) / 1e9, None
        except (OSError, ValueError, IndexError):
            return None
    return None


# ------------------------------------------------------------------ samples ---

def classify(wall, cpu, switches, offcore):
    """True when the host did not disturb a sample. offcore is None where it is not known."""
    lost = max(0.0, wall - cpu)
    budget = SHARE * wall + SLACK
    return (offcore is None or offcore <= budget) and (switches == 0 or lost <= budget)


def timed(fn, *args, units=1, **kwargs):
    """Call fn(*args, **kwargs) and return (its result, a Sample of the call). The counters are
    read before the clock starts and after it stopped, never inside the timed span. units is the
    amount of work (bytes, say) a rate is taken over."""
    switches0 = _switches()
    offcore0 = offcore_seconds()
    cpu0 = time.thread_time()
    wall0 = time.perf_counter()
    result = fn(*args, **kwargs)
    wall1 = time.perf_counter()
    cpu1 = time.thread_time()
    offcore1 = offcore_seconds()
    switches1 = _switches()
    wall = wall1 - wall0
    cpu = cpu1 - cpu0
    lost = max(0.0, wall - cpu)
    switches = switches1 - switches0
    offcore = None if offcore0 is None or offcore1 is None else max(0.0, offcore1 - offcore0)
    return result, Sample(units, wall, wall, cpu, lost, switches, offcore,
                          classify(wall, cpu, switches, offcore))


# ---------------------------------------------------------- other processes ---

class ProcSampler:
    """Follow other processes while a run lasts: a thread reads the counters of every added
    process every `interval` seconds and keeps the first and the latest reading of each (a process
    that is gone keeps its latest). Use it as a context manager; add() may be called while it
    runs. A run is clean when the followed processes did not wait for a CPU or run on efficiency
    cores for more than a tenth of their CPU time (plus 5 ms)."""

    def __init__(self, interval=0.02):
        self._interval = interval
        self._lock = threading.Lock()
        self._first = {}
        self._last = {}
        self._reads = {}
        self._stop = threading.Event()
        self._thread = None

    def add(self, pid):
        """Follow a process from now on (its first reading is taken at once)."""
        self._read(pid)

    def _read(self, pid):
        got = proc_counters(pid)
        if got is None:
            return
        with self._lock:
            self._first.setdefault(pid, got)
            self._last[pid] = got
            self._reads[pid] = self._reads.get(pid, 0) + 1

    def _pids(self):
        with self._lock:
            return list(self._last)

    def _loop(self):
        while not self._stop.wait(self._interval):
            for pid in self._pids():
                self._read(pid)

    def __enter__(self):
        self._stop.clear()
        self._thread = threading.Thread(target=self._loop, daemon=True)
        self._thread.start()
        return self

    def __exit__(self, *_exc):
        self._stop.set()
        if self._thread is not None:
            self._thread.join()
            self._thread = None
        for pid in self._pids():
            self._read(pid)
        return False

    def totals(self):
        """The CPU seconds, seconds waiting for a CPU and seconds on efficiency cores (None when no
        process gave them) the followed processes used between their first and latest readings,
        and how many processes that sums over (those with two readings)."""
        cpu = wait = offcore = 0.0
        known_off = False
        pids = 0
        with self._lock:
            for pid, first in self._first.items():
                if self._reads.get(pid, 0) < 2:
                    continue
                last = self._last[pid]
                pids += 1
                cpu += max(0.0, last[0] - first[0])
                wait += max(0.0, last[1] - first[1])
                if last[2] is not None and first[2] is not None:
                    offcore += max(0.0, last[2] - first[2])
                    known_off = True
        return {"cpu": cpu, "wait": wait, "offcore": offcore if known_off else None,
                "pids": pids}

    @property
    def known(self):
        """True when at least one process gave two readings."""
        with self._lock:
            return any(n >= 2 for n in self._reads.values())

    def clean(self):
        """True when the followed processes were not disturbed; also True when nothing is known
        (no counters on this platform, or a run too short for two readings)."""
        if not self.known:
            return True
        total = self.totals()
        return total["wait"] + (total["offcore"] or 0.0) <= PROC_SHARE * total["cpu"] + PROC_SLACK


# ----------------------------------------------------------------- verdicts ---

def rate_verdict(samples, limit):
    """Units per second over the samples against a limit that is a lower bound."""
    units = sum(s.units for s in samples)
    wall = sum(s.wall for s in samples)
    rate = units / wall if wall > 0 else 0.0
    if rate >= limit:
        return Verdict(PASS, rate, "all", 1.0)
    clean = [s for s in samples if s.clean]
    clean_units = sum(s.units for s in clean)
    share = clean_units / units if units else 0.0
    if share >= MIN_SHARE and len(clean) >= MIN_CLEAN:
        clean_wall = sum(s.wall for s in clean)
        clean_rate = clean_units / clean_wall if clean_wall > 0 else 0.0
        return Verdict(PASS if clean_rate >= limit else FAIL, clean_rate, "clean", share)
    return Verdict(UNDECIDED, rate, "busy", share)


def p50_verdict(samples, limit):
    """The median of the samples' values against a limit that is an upper bound."""
    values = sorted(s.value for s in samples)
    median = values[len(values) // 2]
    if median <= limit:
        return Verdict(PASS, median, "all", 1.0)
    clean = sorted(s.value for s in samples if s.clean)
    share = len(clean) / len(samples)
    if len(clean) >= MIN_CLEAN_READS and share >= MIN_SHARE:
        clean_median = clean[len(clean) // 2]
        return Verdict(PASS if clean_median <= limit else FAIL, clean_median, "clean", share)
    return Verdict(UNDECIDED, median, "busy", share)


def tries_verdict(tries, limit):
    """Whole measurements, [(value, clean)], against an upper bound: any try within the limit
    passes; else a clean try beyond it fails; else the host left nothing to decide with."""
    within = [value for value, _clean in tries if value <= limit]
    if within:
        return Verdict(PASS, min(within), "all", 1.0)
    clean = [value for value, is_clean in tries if is_clean]
    if clean:
        return Verdict(FAIL, min(clean), "clean", len(clean) / len(tries))
    return Verdict(UNDECIDED, min(value for value, _clean in tries), "busy", 0.0)


def retry(measure, limit, tries=TRIES):
    """Call measure() -> (value, clean) up to `tries` times, stopping after the first try within
    the limit or the first clean one (a clean try beyond the limit is a decided failure). Returns
    (the verdict, the tries made)."""
    made = []
    for _ in range(tries):
        value, clean = measure()
        made.append((value, clean))
        if value <= limit or clean:
            break
    return tries_verdict(made, limit), made
