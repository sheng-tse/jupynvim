#!/usr/bin/env python3
"""Find, wait for and stop the processes of one test run.

The rule: only processes this run provably started are ever listed or
signalled. A process is the run's (the run made by tests/lib/test_env.sh,
JNV_RUN_ROOT) when all three hold:

  1. it refers to the run: its command line names the run dir or the run's
     tmux socket prefix (jnv-<JNV_RUN_ID>-), or its working dir or one of
     its open files is inside the run dir;
  2. it started after the run dir was made, so a process that was already
     running is never taken for the run's;
  3. the run started it: the process or one of its ancestors is
     a. the run's owner, the shell that made the run ($JNV_RUN_ROOT/owner
        holds its pid and start, so a pid used again never matches);
     b. a tmux server of the run, started after the run dir:
        tests/lib/tmux.sh records each server's pid and start in
        $JNV_RUN_ROOT/tmux-sockets, and a recorded server that is still
        the same process counts; so does, should that record be missing, a
        daemon (parent pid 1, a session of its own) whose command line is
        the one tests/lib/tmux.sh starts a server of this run with (the
        run's private socket name and the run's own tmux.conf);
     c. on Linux, a process started after the run dir whose environment
        has JNV_RUN_ROOT=<the run dir, or a dir in it> (an orphan may be
        adopted by a subreaper there, not pid 1);
     d. where that environment cannot be read (macOS), a process started
        after the run dir whose parent is pid 1 (its own parent has exited)
        and that is in the owner's process group (recorded in
        $JNV_RUN_ROOT/owner.info) or a recorded server's, or in a session
        whose leader still runs and was started by the run (a pane of the
        run's tmux server): an orphaned backend or kernel, or what the run
        left when its owner was killed.

A process is born into the process group and the session of its parent, so
group and session are evidence of who started it. A process someone else
started has a parent of its own, or, once that parent has exited, its own
group: a GUI app, a tmux or screen server, each job of an interactive shell
and each command an agent runs lead groups of their own. Such a process that
refers to the run (a tail -F or an editor on a file in the run dir, a tmux
server or a shell someone started in it) is reported on stderr and left
alone: it is never signalled and never counted as left over. The checker
itself, its ancestors, every process it starts and pid 1 are never listed.
Nothing is matched by program name or pattern, and nothing is signalled by
process group.

What cannot be told apart where no environment can be read (macOS): a
process someone else started in the owner's own process group (in the same
non-interactive command that started the suite, such as a shell script that
runs `bash tests/run_all.sh & tail -F <run dir>/... &`) that refers to the
run and whose parent has since exited looks like an orphan of the run. And
the other way: a process of the run that is orphaned after its session
leader has also exited (a pane whose shell is gone), or that put itself in
a new group or session, is not provably the run's. It is reported, not stopped. tests/lib/tmux.sh still stops what a
session or server stop orphans, from the snapshot it takes first.

A process is identified by its pid and its start: the start time ps prints
on macOS (fixed when the process starts), and on Linux the start in clock
ticks since boot from /proc/<pid>/stat, which a step of the wall clock
(an NTP step, a resume from sleep) does not move. On Linux "started after
the run dir" compares those ticks too, with the ticks of a process started
right before the run dir (owner.info).

Run it with python3 -I (standard library only):

  run_procs.py scan [--grace SECS] [--kill] [--quiet]
      Print pid<TAB>command for each run process. Exit 0 when there is none
      and 1 when there is any. --grace waits up to SECS seconds for the
      processes that name the run to end before the full scan. --kill stops
      what it found: TERM, up to 3 s, then KILL. A process that refers to
      the run but was not started by it is named on stderr (not with
      --quiet), and is neither listed nor stopped.
  run_procs.py snapshot PID...
      Print pid<TAB>start<TAB>command for each PID that is the run's (rule
      2 and 3; a PID that is not is skipped, with a line on stderr) and
      every process under it (the start is the identity reap checks).
  run_procs.py reap --timeout SECS --label TEXT
      Read a snapshot on stdin and wait until every process in it (same pid,
      same start) is gone: exit 0. At the timeout stop the rest that are
      still provably the run's (TERM, 3 s, KILL; an orphan the snapshot
      itself lists counts as the run's under rule 3), append
      label<TAB>pid<TAB>command for each one left to JNV_LEAKS_FILE
      (default $JNV_RUN_ROOT/leaks), print LEAK lines and exit 1.
  run_procs.py cleanup
      What the shell that made the run does when it exits: stop every run
      process (as scan --kill) and remove the run's tmux socket files that
      no server answers on (tmux leaves its socket behind when it is
      killed). Prints nothing. Exit 0, or 1 when a process had to be
      stopped, or 3 when a process under the run's owner still runs
      afterwards (one that does not refer to the run, so it was not
      stopped): the run dir should then stay, for a later sweep to remove
      once that process has ended.
  run_procs.py sweep
      For every other run dir next to this one (a jnv.* dir in the same dir,
      owned by this user) whose owner is gone and that was not kept
      (JNV_KEEP_RUN=1 leaves a file named kept in it): the cleanup above
      for that run, then remove its dir: it is claimed by a rename first
      (only one sweep can rename a dir, while two rmdir calls on one dir
      can both succeed on macOS), then everything in it goes, its owner
      file last, so a removal that is cut short is finished by a later
      sweep (a claimed dir whose sweep still runs is left to it). A run that was killed (KILL, a closed terminal, a tool timeout)
      cleans nothing up itself. A dir is left in place for a later sweep
      while a process that may be that run's still runs (rule 2 and 3, also
      when it does not refer to the run, such as a section that makes dirs
      under TMPDIR later; so also an orphan someone else left in the killed
      owner's process group), and a dir with no owner file
      is never touched (a run being made right now, or one from before owner
      files). The sweep that removes a dir prints a line on stderr for it.

Exit 2 on a usage error, or when JNV_RUN_ROOT is not a run dir made by
test_env.sh (an absolute path whose last part starts with jnv.).
"""
import os
import re
import shutil
import signal
import socket
import stat
import subprocess
import sys
import time

# ps prints start times in the C locale and, here, in UTC, so the same
# process always reads the same, whatever the caller's language or time
# zone; tests/lib/test_env.sh writes the owner's start time the same way.
PS_ENV = dict(os.environ, LC_ALL="C", TZ="UTC0")
SPAWNED = set()  # pids of the processes this checker started
STOP_WAIT = 3.0  # seconds between TERM and KILL
LINUX = sys.platform.startswith("linux")
# removed last, in this order, so a run dir is never left without its owner
# file while anything else of it is still there
OWNER_FILES = ("owner.info", "owner")
# a sweep claims a dead run's dir by renaming it to <dir>.removing-<pid>
CLAIM = ".removing-"


def die(msg):
    print("run_procs: " + msg, file=sys.stderr)
    sys.exit(2)


def warn(msg):
    print("run_procs: " + msg, file=sys.stderr)


def run(cmd, timeout=None):
    """stdout of cmd (stderr dropped), or None when it cannot run or times out."""
    try:
        p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                             stdin=subprocess.DEVNULL, env=PS_ENV, text=True,
                             errors="replace")
    except OSError:
        return None
    SPAWNED.add(p.pid)
    try:
        out, _ = p.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        p.kill()
        p.communicate()
        return None
    return out


def norm(text):
    """A start time with its spacing made canonical."""
    return " ".join(text.split())


def proc_stat(pid):
    """Linux: (state, process group, session, start in ticks since boot)
    from /proc/<pid>/stat, or None when it is gone."""
    try:
        with open("/proc/%d/stat" % pid, "rb") as f:
            data = f.read()
    except OSError:
        return None
    # the command name, in parentheses, may hold spaces and parentheses
    f = data[data.rfind(b")") + 2:].split()
    if len(f) < 20:
        return None
    try:
        return f[0].decode(), int(f[2]), int(f[3]), f[19].decode()
    except (ValueError, UnicodeDecodeError):
        return None


def same_start(now, recorded):
    """A start read now is the start recorded earlier (both from this
    module or tests/lib/test_env.sh, so of the same kind)."""
    return now is not None and recorded is not None and now == norm(recorded)


def getsid(pid):
    try:
        return os.getsid(pid)
    except OSError:
        return None


def is_run_dir(p):
    base = os.path.basename(p)
    return bool(p) and p != "/" and base.startswith("jnv.") and len(base) > 4


def read_owner(d):
    """(pid, start) the owner file of the run dir d names, or None."""
    try:
        with open(os.path.join(d, "owner")) as f:
            text = f.read()
    except OSError:
        return None
    f = text.strip().split("\t", 1)
    if len(f) != 2 or not f[0].isdigit() or not f[1].strip():
        return None
    return int(f[0]), norm(f[1])


def read_info(d):
    """{name: number} from owner.info: pgid (the owner's process group) and,
    on Linux, born (the start in ticks of a process started right before
    the run dir)."""
    out = {}
    try:
        with open(os.path.join(d, "owner.info")) as f:
            for line in f:
                k, _, v = line.strip().partition("=")
                if k in ("pgid", "born") and v.isdigit():
                    out[k] = int(v)
    except OSError:
        pass
    return out


def read_servers(d):
    """[(socket path, pid or None, start or None)] from tmux-sockets: one
    line per server, the path, then (since servers are recorded with them)
    its pid and start, tab separated."""
    out = []
    try:
        with open(os.path.join(d, "tmux-sockets")) as f:
            for line in f:
                f3 = line.rstrip("\n").split("\t")
                path = f3[0].strip()
                if not path.startswith("/"):
                    continue
                if len(f3) >= 3 and f3[1].isdigit() and f3[2].strip():
                    out.append((path, int(f3[1]), norm(f3[2])))
                else:
                    out.append((path, None, None))
    except OSError:
        pass
    return out


class Run:
    """A run dir, checked before anything is matched: the one in the
    environment, or ROOT (sweep)."""

    def __init__(self, root=None):
        from_env = root is None
        if from_env:
            root = os.environ.get("JNV_RUN_ROOT", "")
            if not root:
                die("JNV_RUN_ROOT is not set: source tests/lib/test_env.sh first")
        if not os.path.isabs(root):
            die("JNV_RUN_ROOT is not an absolute path: %s" % root)
        root = root.rstrip("/")
        real = os.path.realpath(root) if root else ""
        for p in (root, real):
            if not is_run_dir(p):
                die("JNV_RUN_ROOT is not a run dir made by test_env.sh: %s" % (p or "/"))
        if not os.path.isdir(real):
            die("JNV_RUN_ROOT is not a directory: %s" % root)
        rid = os.path.basename(root)[4:]
        env_id = os.environ.get("JNV_RUN_ID", "") if from_env else ""
        if env_id and env_id != rid:
            die("JNV_RUN_ID (%s) does not match JNV_RUN_ROOT (%s)" % (env_id, root))
        self.root, self.real = root, real
        self.roots = {root, real}
        self.tag = "jnv-%s-" % rid
        # The run dir's name (mktemp made it unique) as a whole path part:
        # a command line may spell the dir's path another way than the one
        # given here (macOS /var and /private/var, a symlinked TMPDIR).
        self.name_re = re.compile(r"/" + re.escape(os.path.basename(root)) + r"(?![\w.-])")
        # the command line tests/lib/tmux.sh starts a server of this run with
        # (its config path by the run dir's name, however the path is spelled)
        self.server_re = re.compile(r"(?:^|/)tmux\s(?:.*\s)?-L\s+" + re.escape(self.tag)
                                    + r"\d+\s(?:.*\s)?-f\s+(?:.*/)?"
                                    + re.escape(os.path.basename(root))
                                    + r"/tmux\.conf\s(?:.*\s)?start-server(?:\s|$)")
        self.born = birth_time(real)
        info = read_info(real)
        self.owner_group = info.get("pgid")
        self.born_ticks = info.get("born") if LINUX else None
        self.servers = read_servers(real)

    def named_in(self, cmd):
        """cmd names the run dir (or a path in it) or the run's tmux sockets."""
        return self.tag in cmd or bool(self.name_re.search(cmd))

    def inside(self, path):
        return path == self.real or path.startswith(self.real + "/")

    def owner(self):
        """(pid, start) the run's owner file names, or None."""
        return read_owner(self.real)


def birth_time(path):
    """When path was made: its birth time where the file system keeps one,
    else the earliest time stamp on it and its entries (never earlier)."""
    st = os.stat(path)
    born = getattr(st, "st_birthtime", 0) or 0
    if not born and shutil.which("stat"):
        out = (run(["stat", "-c", "%W", path], timeout=5) or "").strip()
        if out.isdigit() and int(out) > 0:
            born = float(out)
    if not born:
        stamps = [st.st_mtime, st.st_ctime]
        try:
            for e in os.scandir(path):
                s = e.stat(follow_symlinks=False)
                stamps += [s.st_mtime, s.st_ctime]
        except OSError:
            pass
        born = min(stamps)
    return born


def etime_secs(text):
    """Seconds in a ps etime value, [[dd-]hh:]mm:ss."""
    days, _, hms = text.rpartition("-")
    parts = [int(x) for x in hms.split(":")]
    if not 1 <= len(parts) <= 3:
        raise ValueError(text)
    while len(parts) < 3:
        parts.insert(0, 0)
    return int(days or 0) * 86400 + parts[0] * 3600 + parts[1] * 60 + parts[2]


class Procs:
    """One reading of the process table: parent, process group, state, start
    estimate (for the age test where no ticks are known), lstart and command
    of every process; on Linux the start in ticks is read from /proc when
    asked for.

    The start estimate is the time read after ps returns minus the elapsed
    time ps gives: whole seconds, so up to one second early and never more."""

    def __init__(self):
        out = run(["ps", "-A", "-ww", "-o", "pid=,ppid=,pgid=,stat=,etime=,lstart=,command="])
        now = time.time()
        if out is None:
            die("ps failed")
        self.ppid, self.pgid, self.state, self.start, self.lstart, self.cmd = {}, {}, {}, {}, {}, {}
        self._stat = {}
        for row in out.splitlines():
            f = row.split(None, 10)
            if len(f) < 10 or not (f[0].isdigit() and f[1].isdigit() and f[2].isdigit()):
                continue
            pid = int(f[0])
            self.ppid[pid] = int(f[1])
            self.pgid[pid] = int(f[2])
            self.state[pid] = f[3]
            self.lstart[pid] = norm(" ".join(f[5:10]))
            self.cmd[pid] = f[10] if len(f) > 10 else ""
            try:
                self.start[pid] = now - etime_secs(f[4])
            except ValueError:
                pass  # no start, so never provably the run's
        self.kids = {}
        for p, pp in self.ppid.items():
            self.kids.setdefault(pp, []).append(p)

    def ticks(self, pid):
        """Linux: the start of pid in clock ticks since boot, or None."""
        if not LINUX or pid not in self.ppid:
            return None
        if pid not in self._stat:
            self._stat[pid] = proc_stat(pid)
        st = self._stat[pid]
        return st[3] if st else None

    def ident(self, pid):
        """The start that identifies pid: ticks since boot on Linux, the ps
        start time elsewhere."""
        return self.ticks(pid) if LINUX else self.lstart.get(pid)

    def same(self, pid, recorded):
        """pid runs as the process whose start was recorded (a start in
        ticks on Linux, or a ps start time, as an older owner file holds)."""
        if pid not in self.ppid or not recorded:
            return False
        if LINUX and recorded.isdigit():
            return self.ticks(pid) == recorded
        return self.lstart.get(pid) == norm(recorded)


def excluded(procs):
    """The checker, its ancestors, its children and pid 0 and 1."""
    me = os.getpid()
    out = {0, 1, me} | SPAWNED
    p = os.getppid()
    while p > 1 and p not in out:
        out.add(p)
        p = procs.ppid.get(p, 0)
    out |= set(procs.kids.get(me, ()))
    return out


def young(run_, procs, p):
    """p started after the run dir. On Linux, with the run's ticks known,
    its start in ticks is at least those (no wall clock takes part).
    Elsewhere a start estimate at least one second before the run dir's
    birth is a real start before it (the estimate is never a second early
    or more)."""
    if run_.born_ticks is not None:
        t = procs.ticks(p)
        if t is not None and t.isdigit():
            return int(t) >= run_.born_ticks
    s = procs.start.get(p)
    return s is not None and s > run_.born - 1


def environ_mark(run_, pid):
    """Linux: True when pid's environment has JNV_RUN_ROOT set to the run
    dir or a dir in it, False when it has not, None when it cannot be read
    (or not Linux)."""
    if not LINUX:
        return None
    try:
        with open("/proc/%d/environ" % pid, "rb") as f:
            env = f.read()
    except OSError:
        return None
    for item in env.split(b"\0"):
        if item.startswith(b"JNV_RUN_ROOT="):
            v = os.fsdecode(item[len(b"JNV_RUN_ROOT="):]).rstrip("/")
            if v in run_.roots or v.startswith(run_.root + "/") \
                    or os.path.realpath(v) == run_.real or run_.inside(os.path.realpath(v)):
                return True
    return False


class Lineage:
    """Rule 3: which processes the run started.

    orphans are pids that count as the run's when their parent is pid 1
    whatever their group or session (reap: the pids of the run's own
    snapshot, taken while they were provably the run's)."""

    def __init__(self, run_, procs, orphans=()):
        self.run, self.p = run_, procs
        self.orphans = set(orphans)
        o = run_.owner()
        self.owner = o[0] if o and procs.same(o[0], o[1]) else None
        # the recorded tmux servers that are still the same process
        self.servers = {pid for _, pid, ident in run_.servers
                        if pid is not None and procs.same(pid, ident)}
        self.groups = set(self.servers)  # a server leads its own group
        if run_.owner_group:
            self.groups.add(run_.owner_group)
        self.memo, self.busy = {}, set()

    def anchor(self, q):
        if q == self.owner:
            return True
        if not young(self.run, self.p, q):
            return False
        if q in self.servers or self.unrecorded_server(q):
            return True
        mark = environ_mark(self.run, q)
        if mark is not None:
            return mark
        if self.p.ppid.get(q) != 1:
            return False
        if q in self.orphans or self.p.pgid.get(q) in self.groups:
            return True
        return self.in_run_session(q)

    def unrecorded_server(self, q):
        """q is a tmux server tests/lib/tmux.sh started for this run whose
        record is missing (the shell that records it was cut short): a
        daemon leading a session of its own, started with the run's private
        socket name and the run's config."""
        return self.p.ppid.get(q) == 1 and getsid(q) == q \
            and bool(self.run.server_re.search(self.p.cmd.get(q, "")))

    def in_run_session(self, q):
        """q's session leader still runs, and the run started it (a session
        only ever holds its leader and what was forked inside it, and the
        id of a session that still has a process is never given to a new
        process)."""
        s = getsid(q)
        if s is None or s == q or s not in self.p.ppid or s in self.busy \
                or getsid(s) != s:
            return False
        if s != self.owner and not young(self.run, self.p, s):
            return False
        self.busy.add(s)
        try:
            return self.started(s)
        finally:
            self.busy.discard(s)

    def started(self, pid):
        """pid or one of its ancestors is an anchor (the owner, a server, or
        an orphan of the run)."""
        chain, q, found = [], pid, False
        while q > 1 and q in self.p.ppid and q not in chain:
            if q in self.memo:
                found = self.memo[q]
                break
            chain.append(q)
            if self.anchor(q):
                found = True
                break
            q = self.p.ppid[q]
        for c in chain:
            self.memo[c] = found
        return found


def by_argv(run_, procs):
    return {p for p, cmd in procs.cmd.items() if run_.named_in(cmd)}


def by_files(run_):
    if LINUX:
        return by_files_proc(run_)
    return by_files_lsof(run_)


def by_files_lsof(run_):
    lsof = shutil.which("lsof") or ("/usr/sbin/lsof" if os.access("/usr/sbin/lsof", os.X_OK) else "")
    if not lsof:
        warn("no lsof, open files not checked")
        return set()
    out = run([lsof, "-n", "-P", "-w", "-F", "pn", "+D", run_.real], timeout=20)
    if out is None:
        warn("lsof did not finish within 20s, open files not checked")
        return set()
    found, pid = set(), None
    for line in out.splitlines():
        if line.startswith("p") and line[1:].isdigit():
            pid = int(line[1:])
        elif line.startswith("n") and pid is not None and run_.inside(line[1:]):
            found.add(pid)
    return found


def by_files_proc(run_):
    found = set()
    try:
        names = os.listdir("/proc")
    except OSError:
        return found
    for name in names:
        if not name.isdigit():
            continue
        base = "/proc/" + name
        links = [base + "/cwd"]
        try:
            links += [base + "/fd/" + fd for fd in os.listdir(base + "/fd")]
        except OSError:
            pass  # not ours to read, or gone
        for link in links:
            try:
                target = os.readlink(link)
            except OSError:
                continue
            if target.endswith(" (deleted)"):
                target = target[:-len(" (deleted)")]
            if run_.inside(target):
                found.add(int(name))
                break
    return found


def idents(pids):
    """{pid: (stat, start)} for the pids that exist, the start as
    Procs.ident gives it."""
    pids = sorted(set(pids))
    if not pids:
        return {}
    got = {}
    if LINUX:
        for p in pids:
            st = proc_stat(p)
            if st:
                got[p] = (st[0], st[3])
        return got
    out = run(["ps", "-o", "pid=,stat=,lstart=", "-p", ",".join(str(p) for p in pids)]) or ""
    for row in out.splitlines():
        f = row.split(None, 2)
        if len(f) == 3 and f[0].isdigit():
            got[int(f[0])] = (f[1], norm(f[2]))
    return got


def alive(ids):
    """The pids of {pid: start} still running as the same process (an exited
    process waiting for its parent counts as gone)."""
    now = idents(ids)
    return [p for p, ls in ids.items()
            if p in now and not now[p][0].startswith("Z") and same_start(now[p][1], ls)]


def send(pid, sig):
    try:
        os.kill(pid, sig)
    except OSError:
        pass


def stop(ids):
    """TERM every process of {pid: start}, wait up to 3 s, KILL the rest.
    Returns {pid: "TERM" or "KILL"}, the signal that ended each."""
    how = {}
    for p in alive(ids):
        send(p, signal.SIGTERM)
        how[p] = "TERM"
    end = time.time() + STOP_WAIT
    left = alive(ids)
    while left and time.time() < end:
        time.sleep(0.1)
        left = alive(ids)
    for p in left:
        send(p, signal.SIGKILL)
        how[p] = "KILL"
    if left:
        end = time.time() + 1.0
        while alive({p: ids[p] for p in left}) and time.time() < end:
            time.sleep(0.05)
    return how


def find(run_, full):
    """({pid: command} of the run's processes, {pid: command} of those that
    refer to the run and started after it but were not started by it);
    full adds the open-file check.

    The open files are read first and the process table after, so every pid
    lsof saw is in the table, and lsof itself is not."""
    files = by_files(run_) if full else set()
    procs = Procs()
    refer = by_argv(run_, procs) | (files & set(procs.ppid))
    excl = excluded(procs)
    cands = {p for p in refer if p not in excl and young(run_, procs, p)}
    lin = Lineage(run_, procs)
    mine = {p for p in cands if lin.started(p)}
    return ({p: procs.cmd[p] for p in mine},
            {p: procs.cmd[p] for p in cands - mine})


def holders(run_, under_owner=False):
    """{pid: command} of the processes the run started (rule 2 and 3) that
    still run, whether they refer to the run or not: while one runs, it may
    still write into the run dir (a section that makes a dir under TMPDIR),
    so the dir stays until it has ended. With under_owner (the owner's own
    exit, where the owner still runs), only the processes under the owner:
    its process group may hold orphans someone else left there (another
    suite started by the same command), which must not keep a run that is
    ending normally from removing its dir."""
    procs = Procs()
    excl = excluded(procs)
    lin = Lineage(run_, procs)

    def below_owner(p):
        q, seen = p, set()
        while q > 1 and q in procs.ppid and q not in seen:
            if q == lin.owner:
                return True
            seen.add(q)
            q = procs.ppid[q]
        return False
    started = below_owner if under_owner else lin.started
    return {p: procs.cmd[p] for p in procs.ppid
            if p not in excl and not procs.state.get(p, "").startswith("Z")
            and young(run_, procs, p) and started(p)}


def stop_found(found):
    """Stop the processes of {pid: command}; {pid: signal} as stop() gives."""
    if not found:
        return {}
    ids = {p: v[1] for p, v in idents(found).items()}
    return stop(ids)


def note_others(others):
    for p in sorted(others):
        warn("%d refers to the run but the run did not start it; left alone: %s"
             % (p, others[p][:200]))


def cmd_scan(args):
    grace, kill, quiet = 0.0, False, False
    it = iter(args)
    for a in it:
        if a == "--grace":
            try:
                grace = float(next(it))
            except (StopIteration, ValueError):
                die("--grace needs a number of seconds")
        elif a == "--kill":
            kill = True
        elif a == "--quiet":
            quiet = True
        else:
            die("scan: unknown argument %s" % a)
    run_ = Run()
    if grace > 0:
        end = time.time() + grace
        while find(run_, full=False)[0] and time.time() < end:
            time.sleep(1)
    found, others = find(run_, full=True)
    if not quiet:
        for p in sorted(found):
            print("%d\t%s" % (p, found[p][:200]))
        sys.stdout.flush()
        note_others(others)
    if found and kill:
        how = stop_found(found)
        if not quiet:
            for p in sorted(how):
                print("stopped %d (%s): %s" % (p, how[p], found[p][:200]))
    sys.stdout.flush()
    return 1 if found else 0


def started_set(run_, procs, pids, orphans=()):
    """The pids that are the run's under rules 2 and 3 (and not excluded)."""
    excl = excluded(procs)
    lin = Lineage(run_, procs, orphans)
    ok = {p for p in pids
          if p in procs.ppid and p not in excl and young(run_, procs, p) and lin.started(p)}
    return ok, excl


def cmd_snapshot(args):
    try:
        want = [int(a) for a in args]
    except ValueError:
        die("snapshot: PIDs must be numbers")
    run_ = Run()
    procs = Procs()
    roots = [p for p in want if p in procs.ppid]
    ok, excl = started_set(run_, procs, roots)
    for p in roots:
        if p not in ok:
            warn("snapshot: %d is not provably this run's; it and what runs under it are"
                 " not listed" % p)
    # Down from the roots the run started, only through processes that
    # started after the run dir (all of them, below such a root).
    order, seen = [], set()
    queue = [p for p in roots if p in ok]
    while queue:
        p = queue.pop(0)
        if p in seen:
            continue
        seen.add(p)
        order.append(p)
        queue += [c for c in sorted(procs.kids.get(p, []))
                  if c not in excl and young(run_, procs, c)]
    for p in order:
        ident = procs.ident(p)
        if ident and not procs.state.get(p, "").startswith("Z"):
            print("%d\t%s\t%s" % (p, ident, procs.cmd[p]))
    return 0


def cmd_reap(args):
    timeout, label = None, None
    it = iter(args)
    for a in it:
        if a == "--timeout":
            try:
                timeout = float(next(it))
            except (StopIteration, ValueError):
                die("--timeout needs a number of seconds")
        elif a == "--label":
            label = next(it, None)
        else:
            die("reap: unknown argument %s" % a)
    if timeout is None or label is None:
        die("reap needs --timeout SECS and --label TEXT")
    run_ = Run()
    ids, cmds = {}, {}
    for line in sys.stdin.read().splitlines():
        f = line.split("\t", 2)
        if len(f) < 2 or not f[0].isdigit() or not f[1].strip():
            if line.strip():
                warn("reap: not a snapshot line: %r" % line[:200])
            continue
        p = int(f[0])
        ids[p] = norm(f[1])
        cmds[p] = f[2] if len(f) > 2 else ""
    end = time.time() + timeout
    left = alive(ids)
    while left and time.time() < end:
        time.sleep(0.1)
        left = alive(ids)
    if not left:
        return 0
    # Signal only what is still provably the run's: the same process, and
    # started by the run (an orphan this snapshot lists counts as the run's:
    # the run's own session or server stop just made it one).
    procs = Procs()
    ok, _ = started_set(run_, procs, [p for p in left if procs.same(p, ids[p])],
                        orphans=set(ids))
    for p in left:
        if p not in ok:
            warn("reap: not signalling %d, not provably this run's" % p)
    stop({p: ids[p] for p in left if p in ok})
    leaks = os.environ.get("JNV_LEAKS_FILE") or os.path.join(run_.root, "leaks")
    try:
        with open(leaks, "a") as f:
            for p in sorted(left):
                f.write("%s\t%d\t%s\n" % (label, p, cmds[p]))
    except OSError as e:
        warn("reap: cannot write %s: %s" % (leaks, e))
    for p in sorted(left):
        print("LEAK %s %d %s" % (label, p, cmds[p][:200]))
    sys.stdout.flush()
    return 1


# ── tmux sockets ────────────────────────────────────────

def tmux_socket_dirs(run_):
    """Where the run's tmux servers put their sockets: the dirs of the paths
    tests/lib/tmux.sh recorded in the run, and the dir its wrapper uses
    (tmux's own default for the caller: the dir in JNV_TMUX_TMPDIR, the
    caller's TMUX_TMPDIR, else the system temp dir, plus tmux-<uid>), for a
    server killed before its path was recorded."""
    dirs = [os.path.dirname(path) for path, _, _ in run_.servers
            if os.path.basename(path).startswith(run_.tag)]
    # tmux's compiled-in default is the system temp dir itself, not TMPDIR
    base = os.environ.get("JNV_TMUX_TMPDIR") or os.path.join("/", "tmp")
    dirs.append(os.path.join(os.path.realpath(base), "tmux-%d" % os.getuid()))
    out = []
    for d in dirs:
        if d not in out:
            out.append(d)
    return out


def socket_answers(path):
    """A server accepts connections on the socket (or that cannot be told)."""
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(2)
    try:
        s.connect(path)
        return True
    except (ConnectionRefusedError, FileNotFoundError):
        return False
    except OSError:
        return True
    finally:
        s.close()


def remove_dead_sockets(run_):
    """Remove the run's tmux socket files (jnv-<id>-*, sockets of this user)
    that no server answers on. Returns (removed, still answered)."""
    removed, live = [], []
    for d in tmux_socket_dirs(run_):
        try:
            names = sorted(os.listdir(d))
        except OSError:
            continue
        for n in names:
            if not n.startswith(run_.tag):
                continue
            p = os.path.join(d, n)
            try:
                st = os.lstat(p)
            except OSError:
                continue
            if not stat.S_ISSOCK(st.st_mode) or st.st_uid != os.getuid():
                continue
            if socket_answers(p):
                live.append(p)
                continue
            try:
                os.unlink(p)
                removed.append(p)
            except OSError:
                pass
    return removed, live


def cleanup(run_):
    """Stop every run process, then remove the run's dead tmux sockets.
    Returns (processes stopped, sockets removed)."""
    found, _ = find(run_, full=True)
    stop_found(found)
    removed, _ = remove_dead_sockets(run_)
    return found, removed


def cmd_cleanup(args):
    if args:
        die("cleanup takes no arguments")
    run_ = Run()
    found, _ = cleanup(run_)
    if holders(run_, under_owner=True):
        return 3
    return 1 if found else 0


def remove_tree(d):
    """Remove the dir d, making read-only dirs in it writable on the way.
    Nothing outside d is ever changed: not its parent (the caller's temp
    dir), even when d itself cannot be removed or another sweep removed it
    first."""
    retried = set()

    def inside(p):
        return p == d or p.startswith(d + "/")

    def retry(func, path, exc):
        err = exc[1] if isinstance(exc, tuple) else exc  # onerror gives exc_info
        if isinstance(err, FileNotFoundError):
            return  # gone already: another sweep removed it
        try:
            parent = os.path.dirname(path)
            if inside(parent):
                os.chmod(parent, 0o700)
            is_dir = inside(path) and os.path.isdir(path) and not os.path.islink(path)
            if is_dir:
                os.chmod(path, 0o700)
            if func in (os.unlink, os.remove, os.rmdir):
                func(path)
            elif is_dir and path not in retried:
                # a dir that could not be opened or listed: again, now that
                # it is readable (once, so a dir that stays unreadable ends it)
                retried.add(path)
                rmtree(path)
        except OSError:
            pass

    def rmtree(p):
        if sys.version_info >= (3, 12):
            shutil.rmtree(p, onexc=retry)
        else:
            shutil.rmtree(p, onerror=retry)
    if os.path.islink(d) or not os.path.isdir(d):
        return not os.path.lexists(d)
    rmtree(d)
    return not os.path.lexists(d)


def remove_run_dir(d):
    """Remove the run dir d, and say whether this call did. It is claimed
    first, by renaming it to <d>.removing-<pid>: of several sweeps at once
    only one can rename it (two rmdir calls on one dir can both report
    success on macOS, so rmdir cannot tell). The claimed dir is then
    emptied, its owner file last (empty_run_dir). True only when this call
    claimed and removed it; when an entry cannot be removed, the dir goes
    back under its own name, owner file and all, for a later sweep (and if
    that name is taken meanwhile, the claimed dir keeps its owner file and
    a later sweep finishes it under the claimed name)."""
    claim = "%s%s%d" % (d, CLAIM, os.getpid())
    try:
        os.rename(d, claim)
    except OSError:
        return False  # another sweep claimed it, or it cannot be moved
    try:
        if empty_run_dir(claim):
            return True
    except Exception as e:  # never leave a claimed dir behind for nothing
        warn("cannot remove %s: %r" % (d, e))
    try:
        os.rename(claim, d)
    except OSError:
        pass
    return False


def claimed_by_live(d, procs):
    """d is a run dir that a sweep claimed (renamed) and is still removing:
    the sweep named in it still runs."""
    base = os.path.basename(d)
    i = base.rfind(CLAIM)
    pid = base[i + len(CLAIM):] if i >= 0 else ""
    return pid.isdigit() and int(pid) in procs.ppid


def empty_run_dir(d):
    """Remove the run dir d: everything in it but the owner files, then
    owner.info, then owner, then the dir, so a removal that is cut short or
    fails always leaves the owner file and a later sweep finishes it. True
    only when the dir is removed; when an entry could not be removed or a
    new one appeared, the owner file is kept, or put back."""
    saved = {}
    for n in OWNER_FILES:
        try:
            with open(os.path.join(d, n)) as f:
                saved[n] = f.read()
        except OSError:
            pass
    try:
        names = os.listdir(d)
    except OSError:
        return False
    for n in names:
        if n in OWNER_FILES:
            continue
        p = os.path.join(d, n)
        try:
            if os.path.isdir(p) and not os.path.islink(p):
                remove_tree(p)
            else:
                os.unlink(p)
        except FileNotFoundError:
            pass
        except OSError:
            return False
    try:
        if any(n not in OWNER_FILES for n in os.listdir(d)):
            return False
    except OSError:
        return False
    for n in OWNER_FILES:
        try:
            os.unlink(os.path.join(d, n))
        except FileNotFoundError:
            pass
        except OSError:
            return False
    try:
        os.rmdir(d)
        return True
    except FileNotFoundError:
        return False  # another sweep removed it
    except OSError:
        # a new entry appeared after the check: the owner files go back
        # (owner last, so a sweep never sees it without owner.info), and a
        # later sweep can still tell whose dir this is
        for n in OWNER_FILES:
            if n in saved:
                try:
                    with open(os.path.join(d, n + ".part"), "w") as f:
                        f.write(saved[n])
                    os.rename(os.path.join(d, n + ".part"), os.path.join(d, n))
                except OSError:
                    pass
        return False


def cmd_sweep(args):
    if args:
        die("sweep takes no arguments")
    me = Run()
    base = os.path.dirname(me.real)
    uid = os.getuid()
    try:
        names = sorted(os.listdir(base))
    except OSError as e:
        die("sweep: cannot list %s: %s" % (base, e))
    cands = []
    for n in names:
        d = os.path.join(base, n)
        if not is_run_dir(d) or d == me.real or n.startswith(os.path.basename(me.real) + CLAIM):
            continue
        try:
            st = os.lstat(d)
        except OSError:
            continue
        if not stat.S_ISDIR(st.st_mode) or st.st_uid != uid \
                or os.path.lexists(os.path.join(d, "kept")):
            continue
        o = read_owner(d)
        if o is not None:
            cands.append((d, o))
    if not cands:
        return 0
    procs = Procs()
    for d, (pid, ident) in cands:
        if procs.same(pid, ident) or claimed_by_live(d, procs):
            continue  # its owner still runs (a live run), or a sweep removes it now
        try:
            run_ = Run(d)
            found, removed = cleanup(run_)
            held = holders(run_)
        except (SystemExit, OSError):
            continue  # gone meanwhile (another sweep), or not a run dir
        if held:
            print("test env: left %s in place for now, a run that ended without cleaning up:"
                  " %d processes that may be its still run (%s); a later run's setup removes"
                  " it" % (d, len(held), " ".join(str(p) for p in sorted(held))),
                  file=sys.stderr)
            continue
        if remove_run_dir(d):
            print("test env: removed %s, left by a run that ended without cleaning up"
                  " (%d processes stopped, %d tmux sockets removed)"
                  % (d, len(found), len(removed)), file=sys.stderr)
        elif os.path.lexists(os.path.join(d, "owner")):
            print("test env: could not remove all of %s, left by a run that ended without"
                  " cleaning up; a later run's setup tries again" % d, file=sys.stderr)
    return 0


def main(argv):
    cmds = {"scan": cmd_scan, "snapshot": cmd_snapshot, "reap": cmd_reap,
            "cleanup": cmd_cleanup, "sweep": cmd_sweep}
    if not argv or argv[0] not in cmds:
        die("usage: run_procs.py scan [--grace SECS] [--kill] [--quiet] | "
            "snapshot PID... | reap --timeout SECS --label TEXT | cleanup | sweep")
    return cmds[argv[0]](argv[1:])


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
