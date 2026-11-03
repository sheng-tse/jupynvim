// The kernel guard process.
//
// A backend that starts a kernel also starts one guard process,
// `jupynvim-core --guard <backend dir>`, whose stdin is a pipe from the
// backend. The backend writes `+ <pgid>` when a kernel's process group
// starts and `- <pgid>` when it stops. When the pipe reaches end of file
// (the backend exited in any way, SIGKILL included) the guard sends SIGKILL
// to every group still registered, removes the backend dir (holding its
// lock, as every remover does, which a killed backend lets go of a moment
// after the pipe) and exits. The guard leads a session of its
// own, ignores SIGHUP and SIGINT (a closed terminal or Ctrl-C reaches the
// backend, which then exits and closes the pipe), and ends on SIGTERM
// without stopping anything.
//
// The backend side keeps the set of registered groups. It starts the guard
// at the first kernel start, starts a new one, given the current set, when
// the guard exits early or a kernel start finds none running (at most 5
// such starts in 60 s), and at a clean exit stops every group still
// registered before it closes the pipe; a group registered after that is
// stopped at once.

use std::collections::{BTreeSet, VecDeque};
use std::ffi::OsString;
use std::fs::OpenOptions;
use std::io::{BufRead, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::process::{ChildStdin, Command, Stdio};
use std::time::{Duration, Instant};

use anyhow::{anyhow, Result};
use once_cell::sync::Lazy;

/// Early exits of the guard counted for the respawn limit.
const RESPAWN_WINDOW: Duration = Duration::from_secs(60);
const RESPAWN_MAX: usize = 5;
/// Once its input ended, how long the guard waits for the backend dir's
/// lock while someone holds it (or, where locking fails, while the
/// backend's process is still there), and how often it tries
/// (connfile::remove_backend_dir_waiting).
const LOCK_WAIT: Duration = Duration::from_secs(1);
const LOCK_STEP: Duration = Duration::from_millis(5);

// ── the guard process ───────────────────────────────────

/// What the guard did once its input ended.
#[derive(Debug, PartialEq, Eq)]
pub struct Summary {
    /// process groups it sent SIGKILL to
    pub killed: usize,
    /// whether it removed the backend dir
    pub removed: bool,
}

/// `+ <pgid>` registers a group, `- <pgid>` unregisters it (a trailing
/// newline is fine). A group id must be above 1; anything else is None.
pub fn parse_line(line: &str) -> Option<(bool, i32)> {
    let s = line.trim_end_matches(['\n', '\r']);
    let (add, num) = if let Some(n) = s.strip_prefix("+ ") {
        (true, n)
    } else if let Some(n) = s.strip_prefix("- ") {
        (false, n)
    } else {
        return None;
    };
    if num.is_empty() || !num.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    let pgid: i32 = num.parse().ok()?;
    (pgid > 1).then_some((add, pgid))
}

/// Reads registrations until end of file or a read error, then sends SIGKILL
/// to every group still registered (never its own) and removes the backend
/// dir, only when it is a real dir of the user named like a backend dir, in
/// a root that is usable now, and only through handles
/// (connfile::remove_backend_dir_waiting). The
/// end of the input does not mean the backend's lock is free yet: a killed
/// backend lets go of the pipe first and of its lock a moment later, so a
/// held lock (where locking fails: a backend process not yet reaped) is
/// waited for, up to LOCK_WAIT, while the dir is still there.
/// A last line without its newline is a write the backend did not finish
/// (`+ 12` of `+ 123`), so it is not acted on.
pub fn serve<R: BufRead>(mut input: R, backend_dir: &Path) -> Summary {
    let mut groups = BTreeSet::new();
    let mut line = Vec::new();
    loop {
        line.clear();
        match input.read_until(b'\n', &mut line) {
            Ok(0) | Err(_) => break,
            Ok(_) if line.last() != Some(&b'\n') => break,
            Ok(_) => match std::str::from_utf8(&line).ok().and_then(parse_line) {
                Some((true, g)) => {
                    groups.insert(g);
                }
                Some((false, g)) => {
                    groups.remove(&g);
                }
                None => {}
            },
        }
    }
    // SAFETY: getpgrp has no preconditions and cannot fail.
    let own = unsafe { libc::getpgrp() };
    let killed = groups.iter().filter(|&&g| g != own && kill_group(g)).count();
    let removed = crate::connfile::remove_backend_dir_waiting(backend_dir, LOCK_WAIT, LOCK_STEP);
    Summary { killed, removed }
}

/// SIGKILL to process group `pgid` (above 1); true when it was sent.
fn kill_group(pgid: i32) -> bool {
    // SAFETY: killpg only sends a signal. A pgid above 1 names one process
    // group: never the caller's own (0) and never every process.
    pgid > 1 && unsafe { libc::killpg(pgid, libc::SIGKILL) } == 0
}

/// `jupynvim-core --guard <backend dir>`: the guard process. No tokio
/// runtime and no logging setup; one line is appended to core.log when it
/// stopped or removed anything.
pub fn run(args: &[OsString]) -> Result<()> {
    let dir = args.first().ok_or_else(|| anyhow!("--guard needs the backend dir"))?;
    let dir = std::path::absolute(dir)?;
    // SAFETY: setsid and signal only change this process's session and
    // signal dispositions; no other thread runs yet.
    unsafe {
        libc::setsid();
        libc::signal(libc::SIGHUP, libc::SIG_IGN);
        libc::signal(libc::SIGINT, libc::SIG_IGN);
    }
    let _ = std::env::set_current_dir("/");
    let s = serve(std::io::stdin().lock(), &dir);
    if s.killed > 0 || s.removed {
        append_log(&s, &dir);
    }
    Ok(())
}

fn append_log(s: &Summary, dir: &Path) {
    let path = crate::log_dir(std::env::var_os("JUPYNVIM_LOG_DIR")).join("core.log");
    let ts = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true);
    let what = if s.removed {
        format!("removed {}", dir.display())
    } else {
        format!("{} not removed", dir.display())
    };
    let line = format!(
        "{ts}  INFO jupynvim_core::guard: backend gone; stopped {} kernel group(s), {what}\n",
        s.killed
    );
    if let Ok(mut f) = OpenOptions::new().append(true).create(true).mode(0o600).open(path) {
        let _ = f.write_all(line.as_bytes());
    }
}

// ── the backend side ────────────────────────────────────

#[derive(Default)]
struct State {
    /// the backend dir, once start() was called
    dir: Option<PathBuf>,
    /// the pipe to the running guard
    stdin: Option<ChildStdin>,
    pid: Option<u32>,
    groups: BTreeSet<i32>,
    /// set by finish(): no guard is started any more and every group
    /// registered from then on is stopped at once
    finishing: bool,
    /// when a guard was started again (after an exit, or by a kernel start
    /// while none ran), for the respawn limit
    respawns: VecDeque<Instant>,
}

static STATE: Lazy<parking_lot::Mutex<State>> = Lazy::new(|| parking_lot::Mutex::new(State::default()));

impl State {
    /// Writes to the guard. On an error (the guard is gone) the pipe is
    /// dropped; the thread waiting for the guard starts a new one and gives
    /// it the current set.
    fn send(&mut self, text: &str) {
        if let Some(w) = self.stdin.as_mut() {
            if w.write_all(text.as_bytes()).and_then(|()| w.flush()).is_err() {
                self.stdin = None;
            }
        }
    }

    fn register_in(&mut self, pgid: i32, spawn: &mut dyn FnMut(&mut State) -> bool) {
        if pgid <= 1 {
            return;
        }
        if self.finishing {
            // SAFETY: getpgrp has no preconditions and cannot fail.
            if pgid != unsafe { libc::getpgrp() } {
                kill_group(pgid);
            }
            return;
        }
        if !self.groups.insert(pgid) {
            return;
        }
        if self.stdin.is_some() {
            self.send(&format!("+ {pgid}\n"));
        } else if self.dir.is_some() && self.may_respawn(Instant::now()) {
            // no guard running: start one, which is given every group
            spawn(self);
        }
    }

    /// Whether a guard may be started again at `now`, counting it when it
    /// may: at most RESPAWN_MAX in any RESPAWN_WINDOW. Every start but the
    /// first counts, whether a guard exited or a kernel start found none
    /// running, so a guard that cannot run is not started over and over;
    /// once the window has passed, the next exit or kernel start starts one
    /// again.
    fn may_respawn(&mut self, now: Instant) -> bool {
        while self.respawns.front().is_some_and(|t| now.saturating_duration_since(*t) > RESPAWN_WINDOW) {
            self.respawns.pop_front();
        }
        if self.respawns.len() >= RESPAWN_MAX {
            tracing::warn!("guard: exited {RESPAWN_MAX} times in 60 s; kernels run unguarded");
            return false;
        }
        self.respawns.push_back(now);
        true
    }

    /// The guard `pid` exited at `now`. Unless it was replaced already or
    /// the backend is exiting, a new one is started, within the respawn
    /// limit (may_respawn).
    fn on_exit_in(&mut self, pid: u32, now: Instant, spawn: &mut dyn FnMut(&mut State) -> bool) {
        if self.pid != Some(pid) || self.finishing {
            return;
        }
        self.stdin = None;
        self.pid = None;
        if self.may_respawn(now) {
            tracing::warn!("guard: exited (pid {pid}), starting a new one");
            spawn(self);
        }
    }

    fn unregister_in(&mut self, pgid: i32) {
        if self.groups.remove(&pgid) {
            self.send(&format!("- {pgid}\n"));
        }
    }

    /// Clean exit: stops every registered group, tells the guard they are
    /// gone (so it never signals them again), and closes the pipe. Returns
    /// how many groups were signalled.
    fn finish_in(&mut self) -> usize {
        self.finishing = true;
        let groups = std::mem::take(&mut self.groups);
        // SAFETY: getpgrp has no preconditions and cannot fail.
        let own = unsafe { libc::getpgrp() };
        let n = groups.iter().filter(|&&g| g != own && kill_group(g)).count();
        if !groups.is_empty() {
            let lines: String = groups.iter().map(|g| format!("- {g}\n")).collect();
            self.send(&lines);
        }
        self.stdin = None;
        n
    }
}

/// The binary to start as the guard: on Linux /proc/self/exe (still this
/// binary after its file was replaced), else the path this process runs.
fn guard_exe() -> Option<(PathBuf, OsString)> {
    let exe = std::env::current_exe().ok();
    #[cfg(target_os = "linux")]
    {
        let me = Path::new("/proc/self/exe");
        if me.exists() {
            let arg0 = exe.map(|p| p.into_os_string()).unwrap_or_else(|| OsString::from("jupynvim-core"));
            return Some((me.to_path_buf(), arg0));
        }
    }
    exe.map(|p| {
        let arg0 = p.clone().into_os_string();
        (p, arg0)
    })
}

/// The guard's command: `exe --guard <dir>`, its stdin a pipe from this
/// process, stdout and stderr null, and no other fd of this process (one
/// a kernel start makes on another thread at that moment included). It
/// leads a session of its own by itself (run).
fn guard_command(exe: &Path, arg0: OsString, dir: &Path) -> Command {
    use std::os::unix::process::CommandExt;
    let mut cmd = Command::new(exe);
    cmd.arg0(arg0)
        .arg("--guard")
        .arg(dir)
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    crate::kernel::no_inherited_fds(&mut cmd);
    cmd
}

/// Starts a guard for st.dir and gives it every registered group; a thread
/// waits for it to exit. False when it could not be started.
fn spawn_locked(st: &mut State) -> bool {
    let Some(dir) = st.dir.clone() else { return false };
    let Some((exe, arg0)) = guard_exe() else {
        tracing::warn!("guard: cannot find this binary; kernels run unguarded");
        return false;
    };
    let spawned = guard_command(&exe, arg0, &dir).spawn();
    let mut child = match spawned {
        Ok(c) => c,
        Err(e) => {
            tracing::warn!("guard: cannot start {}: {e}; kernels run unguarded", exe.display());
            return false;
        }
    };
    let pid = child.id();
    st.stdin = child.stdin.take();
    st.pid = Some(pid);
    if !st.groups.is_empty() {
        let lines: String = st.groups.iter().map(|g| format!("+ {g}\n")).collect();
        st.send(&lines);
    }
    tracing::info!("guard: started (pid {pid})");
    let waiter = std::thread::Builder::new().name("jnv-guard-wait".into()).spawn(move || {
        let _ = child.wait();
        on_guard_exit(pid);
    });
    if let Err(e) = waiter {
        tracing::warn!("guard: cannot watch pid {pid}: {e}; it is not started again if it exits");
    }
    true
}

/// The guard `pid` exited (State::on_exit_in).
fn on_guard_exit(pid: u32) {
    STATE.lock().on_exit_in(pid, Instant::now(), &mut spawn_locked)
}

/// Starts the guard for this backend's dir, once. When it cannot be
/// started (logged), kernels run unguarded; a later register tries again.
pub fn start(backend_dir: &Path) {
    let mut st = STATE.lock();
    if st.finishing || st.dir.is_some() {
        return;
    }
    st.dir = Some(backend_dir.to_path_buf());
    spawn_locked(&mut st);
}

/// A kernel's process group started.
pub fn register(pgid: i32) {
    STATE.lock().register_in(pgid, &mut spawn_locked)
}

/// A kernel's process group stopped.
pub fn unregister(pgid: i32) {
    STATE.lock().unregister_in(pgid)
}

/// Clean exit: stops every kernel group still registered (a start in
/// flight, a kernel no session holds yet), then closes the pipe so the
/// guard exits.
pub fn finish() {
    let n = STATE.lock().finish_in();
    if n > 0 {
        tracing::info!("guard: stopped {n} kernel group(s) still running at exit");
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs::{self, File};
    use std::io::Cursor;
    use std::os::unix::process::{CommandExt, ExitStatusExt};
    use std::path::PathBuf;
    use std::process::{Child, Command, Stdio};

    /// A scratch dir of its own per test, removed at the end.
    struct TestDir(PathBuf);

    impl TestDir {
        fn new(name: &str) -> TestDir {
            let p = std::env::temp_dir().join(format!("jvtest-guard-{}-{}", std::process::id(), name));
            let _ = fs::remove_dir_all(&p);
            fs::create_dir_all(&p).unwrap();
            // a runtime root is a private dir; the guard removes nothing
            // from any other
            fs::set_permissions(&p, std::os::unix::fs::PermissionsExt::from_mode(0o700)).unwrap();
            TestDir(p)
        }
    }

    impl Drop for TestDir {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    /// A backend dir made by hand: a lock file nobody holds and a kernel dir
    /// with its connection file.
    fn backend_dir(t: &TestDir, name: &str) -> PathBuf {
        let d = t.0.join(name);
        fs::create_dir(&d).unwrap();
        fs::write(d.join("lock"), b"").unwrap();
        fs::create_dir(d.join("kernel-x")).unwrap();
        fs::write(d.join("kernel-x/connection.json"), b"{}").unwrap();
        d
    }

    /// `sleep 30` leading a session (and process group) of its own, as a
    /// kernel does; its pid is its group id.
    fn sleeper() -> (Child, i32) {
        let mut cmd = Command::new("sleep");
        cmd.arg("30").stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null());
        // SAFETY: setsid is async-signal-safe and touches only the child.
        unsafe {
            cmd.pre_exec(|| {
                if libc::setsid() == -1 {
                    return Err(std::io::Error::last_os_error());
                }
                Ok(())
            });
        }
        let child = cmd.spawn().unwrap();
        let pgid = child.id() as i32;
        (child, pgid)
    }

    fn assert_killed(mut child: Child) {
        let st = child.wait().unwrap();
        assert_eq!(st.signal(), Some(libc::SIGKILL), "the group was not stopped with SIGKILL: {st:?}");
    }

    /// Whether the child still runs (not exited, not a zombie).
    fn still_runs(child: &mut Child) -> bool {
        matches!(child.try_wait(), Ok(None))
    }

    fn end(mut child: Child) {
        let _ = child.kill();
        let _ = child.wait();
    }

    /// The child's exit status once it exited within `limit`, else None.
    fn wait_exit(child: &mut Child, limit: Duration) -> Option<std::process::ExitStatus> {
        let deadline = Instant::now() + limit;
        loop {
            if let Ok(Some(st)) = child.try_wait() {
                return Some(st);
            }
            if Instant::now() >= deadline {
                return None;
            }
            std::thread::sleep(Duration::from_millis(2));
        }
    }

    // G1
    #[test]
    fn g1_parse_line() {
        assert_eq!(parse_line("+ 123"), Some((true, 123)));
        assert_eq!(parse_line("+ 123\n"), Some((true, 123)));
        assert_eq!(parse_line("- 9"), Some((false, 9)));
        assert_eq!(parse_line("- 9\n"), Some((false, 9)));
        assert_eq!(parse_line("+ 2"), Some((true, 2)));
        for bad in ["+ 1", "+ 0", "+ -5", "x", "+ abc", "+ 12 3", "", "+", "+ ", "+123", "* 5", " + 5", "+  5", "+ 99999999999"] {
            assert_eq!(parse_line(bad), None, "{bad:?}");
        }
    }

    // G2
    #[test]
    fn g2_serve_stops_a_registered_group_and_removes_the_dir() {
        let t = TestDir::new("g2");
        let dir = backend_dir(&t, "core-tok-1-aaaaaaaaaaaa");
        let (child, pgid) = sleeper();
        let s = serve(Cursor::new(format!("+ {pgid}\n")), &dir);
        assert_killed(child);
        assert!(!dir.exists(), "the backend dir is still there");
        assert_eq!((s.killed, s.removed), (1, true));
    }

    // G3
    #[test]
    fn g3_an_unregistered_group_keeps_running() {
        let t = TestDir::new("g3");
        let dir = backend_dir(&t, "core-tok-1-aaaaaaaaaaaa");
        let (mut child, pgid) = sleeper();
        // The input ends in a line without its newline: a write the backend
        // did not finish (it was stopped in the middle of it). Such a line
        // may be cut short (`+ 12` of `+ 123`), so it is never acted on.
        let (mut cut, cut_pgid) = sleeper();
        let s = serve(Cursor::new(format!("+ {pgid}\nnot a line\n- {pgid}\n+ {cut_pgid}")), &dir);
        let runs = still_runs(&mut child);
        let cut_runs = still_runs(&mut cut);
        end(child);
        end(cut);
        assert!(runs, "a group registered and then unregistered was stopped");
        assert!(cut_runs, "a group named only in a last line without its newline was stopped");
        assert!(!dir.exists(), "the backend dir is still there");
        assert_eq!((s.killed, s.removed), (0, true));

        // a dir that is not named like a backend dir, or is a symlink to
        // one, is never removed
        for name in ["notes", "core-tok-x-aaaaaaaaaaaa"] {
            let odd = backend_dir(&t, name);
            let s = serve(Cursor::new(""), &odd);
            assert!(!s.removed && odd.join("lock").exists() && odd.join("kernel-x/connection.json").exists(), "{name}");
        }
        let target = backend_dir(&t, "core-tok-2-bbbbbbbbbbbb");
        let link = t.0.join("core-tok-3-cccccccccccc");
        std::os::unix::fs::symlink(&target, &link).unwrap();
        let s = serve(Cursor::new(""), &link);
        assert!(!s.removed && target.join("kernel-x/connection.json").exists());
        assert!(fs::symlink_metadata(&link).unwrap().file_type().is_symlink());
    }

    // G4: a lock held for longer than LOCK_WAIT keeps the dir; the group is
    // stopped all the same, before the wait for the lock begins, not after
    // it. Checked by order, not by deadlines: when the wait begins (a hook
    // in remove_backend_dir_waiting, on this thread) the sleeper must
    // already have ended with SIGKILL (waited for there, with a limit far
    // above any scheduling delay); serve returns no sooner than LOCK_WAIT
    // after that, and no try to take the lock comes sooner than LOCK_STEP
    // after the last one, so it tries at most LOCK_WAIT / LOCK_STEP + 1
    // times (one more allowed for the clock's rounding).
    #[test]
    fn g4_a_held_lock_keeps_the_dir_and_the_group_is_still_stopped() {
        use crate::connfile::tests::{set_hook, Point};
        use std::cell::{Cell, RefCell};
        use std::rc::Rc;
        let t = TestDir::new("g4");
        let dir = backend_dir(&t, "core-tok-1-aaaaaaaaaaaa");
        let holder = File::options().read(true).write(true).open(dir.join("lock")).unwrap();
        holder.try_lock().unwrap();
        let (child, pgid) = sleeper();
        let child = Rc::new(RefCell::new(child));
        // how the sleeper had ended when the wait began, and when that was
        let at_wait: Rc<Cell<Option<(Option<std::process::ExitStatus>, Instant)>>> = Rc::default();
        let tries = Rc::new(Cell::new(0usize));
        let (c, a, n, d) = (child.clone(), at_wait.clone(), tries.clone(), dir.clone());
        set_hook(Some(Box::new(move |point: Point, p: &Path| {
            if p != d {
                return;
            }
            match point {
                Point::GuardWaitBegins => {
                    let st = wait_exit(&mut c.borrow_mut(), Duration::from_secs(20));
                    a.set(Some((st, Instant::now())));
                }
                Point::GuardLockTry => n.set(n.get() + 1),
                _ => {}
            }
        })));
        let s = serve(Cursor::new(format!("+ {pgid}\n")), &dir);
        let returned = Instant::now();
        set_hook(None);
        drop(holder);
        let at_wait = at_wait.get();
        if !matches!(at_wait, Some((Some(_), _))) {
            let mut c = child.borrow_mut();
            let _ = c.kill();
            let _ = c.wait();
        }
        let (st, began) = at_wait.expect("serve never began its wait for the lock");
        assert_eq!(
            st.and_then(|st| st.signal()),
            Some(libc::SIGKILL),
            "the group had not ended with SIGKILL when the wait for the lock began: {st:?}"
        );
        assert!(!s.removed, "a dir whose lock is held was reported removed");
        assert!(dir.join("lock").exists() && dir.join("kernel-x/connection.json").exists());
        assert_eq!(s.killed, 1);
        let waited = returned - began;
        assert!(waited >= LOCK_WAIT, "serve returned {waited:?} after its wait began: it did not wait {LOCK_WAIT:?}");
        let most = (LOCK_WAIT.as_nanos() / LOCK_STEP.as_nanos()) as usize + 2;
        let n = tries.get();
        assert!(
            (1..=most).contains(&n),
            "{n} tries to take the held lock in {waited:?}: more than one every {LOCK_STEP:?} for {LOCK_WAIT:?} ({most})"
        );
    }

    // G8: the input ends before the backend's lock is free (a killed backend
    // lets go of its pipe to the guard first and of its lock a moment
    // later): a lock released within LOCK_WAIT is waited for, then the dir
    // is removed
    #[test]
    fn g8_a_lock_released_soon_after_the_end_of_input_is_waited_for() {
        let t = TestDir::new("g8");
        let dir = backend_dir(&t, "core-tok-1-aaaaaaaaaaaa");
        let holder = File::options().read(true).write(true).open(dir.join("lock")).unwrap();
        holder.try_lock().unwrap();
        let (child, pgid) = sleeper();
        let releaser = std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(100));
            drop(holder);
        });
        let t0 = Instant::now();
        let s = serve(Cursor::new(format!("+ {pgid}\n")), &dir);
        let took = t0.elapsed();
        releaser.join().unwrap();
        assert_killed(child);
        assert!(
            s.removed && !dir.exists(),
            "a lock released 100 ms after the end of input left the dir in place ({s:?}, after {took:?})"
        );
        assert_eq!(s.killed, 1);
        assert!(took >= Duration::from_millis(100) && took < LOCK_WAIT, "serve returned after {took:?}");
    }

    // G10: a backend that exits cleanly removes its dir itself while it
    // holds the lock: the wait ends as soon as the dir is gone. A dir
    // replaced by a symlink while the guard waits is not followed.
    #[test]
    fn g10_the_wait_ends_when_the_dir_goes_and_never_follows_a_symlink() {
        let t = TestDir::new("g10");
        let dir = backend_dir(&t, "core-tok-1-aaaaaaaaaaaa");
        let holder = File::options().read(true).write(true).open(dir.join("lock")).unwrap();
        holder.try_lock().unwrap();
        let d = dir.clone();
        let backend = std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(100));
            fs::remove_dir_all(&d).unwrap();
            drop(holder);
        });
        let t0 = Instant::now();
        let s = serve(Cursor::new(""), &dir);
        let took = t0.elapsed();
        backend.join().unwrap();
        assert!(!s.removed && !dir.exists(), "{s:?}");
        assert!(took < LOCK_WAIT / 2, "serve waited {took:?} for a dir its backend had removed");

        // the dir is moved away and a symlink to another backend dir, whose
        // lock is free, put in its place while the guard waits
        let dir = backend_dir(&t, "core-tok-2-bbbbbbbbbbbb");
        let other = backend_dir(&t, "core-tok-3-cccccccccccc");
        let holder = File::options().read(true).write(true).open(dir.join("lock")).unwrap();
        holder.try_lock().unwrap();
        let (d, o) = (dir.clone(), other.clone());
        let swapper = std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(100));
            fs::rename(&d, d.with_extension("moved")).unwrap();
            std::os::unix::fs::symlink(&o, &d).unwrap();
        });
        let s = serve(Cursor::new(""), &dir);
        swapper.join().unwrap();
        drop(holder);
        assert!(!s.removed, "{s:?}");
        assert!(other.join("lock").exists() && other.join("kernel-x/connection.json").exists(), "removed through a symlink");
        assert!(dir.with_extension("moved").join("kernel-x/connection.json").exists());
    }

    /// Runs `child` (a test marked #[ignore]) in a test process of its own,
    /// where no other test starts a process while it has a pipe open.
    fn run_alone(child: &str, var: &str) {
        let exe = std::env::current_exe().unwrap();
        let out = Command::new(&exe)
            .args([&format!("guard::tests::{child}"), "--exact", "--ignored", "--nocapture", "--test-threads=1"])
            .env(var, "1")
            .output()
            .unwrap();
        let text = format!("{}{}", String::from_utf8_lossy(&out.stdout), String::from_utf8_lossy(&out.stderr));
        assert!(out.status.success(), "{text}");
        assert!(text.contains(&format!("{child}: every check ran")), "{text}");
    }

    // G9: the guard keeps no fd of the backend above 2 across its exec, also
    // one another thread made at that moment and has not yet marked
    // close-on-exec (Rust's std on macOS makes a pipe first and marks it
    // after): a kernel's pipe would otherwise reach end of file only when
    // the guard exits
    #[test]
    fn g9_the_guard_keeps_no_inherited_fd() {
        run_alone("g9_child", "JVTEST_G9");
    }

    #[test]
    #[ignore = "run by g9 in a process of its own: no other test may start a process while its pipe is open"]
    fn g9_child() {
        use std::os::unix::fs::PermissionsExt;
        if std::env::var_os("JVTEST_G9").is_none() {
            return;
        }
        let t = TestDir::new("g9");
        // stands in for this binary: runs a while, whatever its arguments
        let exe = t.0.join("guard-stand-in");
        fs::write(&exe, "#!/bin/sh\nexec sleep 3\n").unwrap();
        fs::set_permissions(&exe, fs::Permissions::from_mode(0o755)).unwrap();
        let mut fds = [0 as libc::c_int; 2];
        // SAFETY: pipe writes two fds, without close-on-exec, into the array.
        assert_eq!(unsafe { libc::pipe(fds.as_mut_ptr()) }, 0);
        let (r, w) = (fds[0], fds[1]);
        // End of file on the read end once no process holds the write end:
        // within `limit` unless a child inherited it.
        let eof_within = |limit: Duration| -> bool {
            let mut pfd = libc::pollfd { fd: r, events: libc::POLLIN, revents: 0 };
            // SAFETY: one pollfd, valid for the call.
            unsafe { libc::poll(&mut pfd, 1, limit.as_millis() as libc::c_int) == 1 }
        };

        // control: a process started without guard_command keeps the fd
        let plain = Command::new(&exe).stdin(Stdio::null()).spawn().unwrap();
        // with guard_command, while this process still has the write end
        let mut guard = guard_command(&exe, exe.clone().into_os_string(), &t.0.join("core-tok-1-aaaaaaaaaaaa"))
            .spawn()
            .unwrap();
        drop(guard.stdin.take());
        // SAFETY: closes the write end this process holds, nothing else.
        unsafe { libc::close(w) };
        let control_kept = !eof_within(Duration::from_millis(300));
        end(plain);
        // the control held the write end; now only the guard could
        let guard_free = eof_within(Duration::from_millis(1000));
        let _ = guard.kill();
        let _ = guard.wait();
        // SAFETY: closes the read end this test made.
        unsafe { libc::close(r) };
        assert!(control_kept, "control: a process started plainly did not keep the fd, so this test proves nothing");
        assert!(guard_free, "the guard kept a write end it inherited: no end of file while it runs");
        println!("g9_child: every check ran");
    }

    // G5
    #[test]
    fn g5_finish_stops_registered_groups_without_a_guard() {
        let t = TestDir::new("g5");
        let mut st = State { dir: Some(t.0.join("core-tok-1-aaaaaaaaaaaa")), ..Default::default() };
        let (child, pgid) = sleeper();
        let mut spawns = 0;
        st.register_in(pgid, &mut |_st: &mut State| {
            spawns += 1;
            false
        });
        assert_eq!(spawns, 1, "no guard was asked for");
        assert!(st.groups.contains(&pgid));
        assert_eq!(st.finish_in(), 1);
        assert!(st.groups.is_empty());
        assert!(st.finishing && st.stdin.is_none());
        assert_killed(child);

        // unregister takes a group out of the set: finish leaves it alone
        let mut st = State::default();
        let (mut child, pgid) = sleeper();
        st.register_in(pgid, &mut |_st: &mut State| panic!("no dir is known, so no guard is started"));
        st.unregister_in(pgid);
        assert_eq!(st.finish_in(), 0);
        let runs = still_runs(&mut child);
        end(child);
        assert!(runs, "finish stopped an unregistered group");
    }

    // G6
    #[test]
    fn g6_register_after_finish_stops_the_group_at_once() {
        let t = TestDir::new("g6");
        let mut st = State { dir: Some(t.0.join("core-tok-1-aaaaaaaaaaaa")), ..Default::default() };
        assert_eq!(st.finish_in(), 0);
        let (child, pgid) = sleeper();
        st.register_in(pgid, &mut |_st: &mut State| panic!("a guard was started after finish"));
        assert!(!st.groups.contains(&pgid), "a group was registered after finish");
        assert_killed(child);
    }

    /// A group id no process group has (never signalled in these tests).
    const NO_GROUP: i32 = 2_000_000_000;

    // G7a: once RESPAWN_MAX guards were started in the last RESPAWN_WINDOW, a
    // kernel start does not start another one; it does once the window
    // has passed
    #[test]
    fn g7a_register_keeps_the_respawn_limit() {
        let t = TestDir::new("g7a");
        let mut st = State { dir: Some(t.0.join("core-tok-1-aaaaaaaaaaaa")), ..Default::default() };
        let now = Instant::now();
        st.respawns.extend(std::iter::repeat_n(now, RESPAWN_MAX));
        let mut spawns = 0;
        st.register_in(NO_GROUP, &mut |_st: &mut State| {
            spawns += 1;
            true
        });
        assert_eq!(spawns, 0, "a kernel start started a guard past the respawn limit");
        assert!(st.groups.contains(&NO_GROUP), "the group was not registered");
        assert_eq!(st.respawns.len(), RESPAWN_MAX);

        // the same starts, all more than RESPAWN_WINDOW ago
        let Some(past) = now.checked_sub(RESPAWN_WINDOW + Duration::from_secs(1)) else { return };
        st.respawns.clear();
        st.respawns.extend(std::iter::repeat_n(past, RESPAWN_MAX));
        st.register_in(NO_GROUP + 1, &mut |_st: &mut State| {
            spawns += 1;
            true
        });
        assert_eq!(spawns, 1, "a kernel start did not start a guard once the window had passed");
        assert_eq!(st.respawns.len(), 1, "the start was not counted, or old starts were kept");
    }

    // G7b: a guard that exits is started again, at most RESPAWN_MAX times in
    // RESPAWN_WINDOW; a later exit, once the window has passed, starts one
    // again; an exit of a guard already replaced, or during the exit, starts
    // none
    #[test]
    fn g7b_guard_exits_keep_the_respawn_limit() {
        let t = TestDir::new("g7b");
        let mut st = State { dir: Some(t.0.join("core-tok-1-aaaaaaaaaaaa")), pid: Some(100), ..Default::default() };
        let t0 = Instant::now();
        let mut next = 100;
        let started = std::cell::RefCell::new(Vec::new());
        let mut spawn = |st: &mut State| {
            next += 1;
            st.pid = Some(next);
            started.borrow_mut().push(next);
            true
        };
        let count = || started.borrow().len();
        for i in 0..RESPAWN_MAX as u64 {
            let pid = st.pid.unwrap();
            st.on_exit_in(pid, t0 + Duration::from_secs(10 * i), &mut spawn);
        }
        assert_eq!(*started.borrow(), vec![101, 102, 103, 104, 105], "a guard that exited was not started again");
        // a sixth exit 50 s after the first: none is started
        st.on_exit_in(105, t0 + Duration::from_secs(50), &mut spawn);
        assert_eq!(count(), RESPAWN_MAX, "a guard was started a sixth time within the window");
        assert_eq!((st.pid, st.stdin.is_none()), (None, true));
        // a kernel start right after that starts none either
        st.register_in(NO_GROUP, &mut spawn);
        assert_eq!(count(), RESPAWN_MAX, "a kernel start started a guard past the limit");

        // once the window has passed for the first start, one more
        st.pid = Some(105);
        st.on_exit_in(105, t0 + RESPAWN_WINDOW + Duration::from_secs(1), &mut spawn);
        assert_eq!(count(), RESPAWN_MAX + 1, "no guard was started once the window had passed");
        assert_eq!(st.respawns.len(), RESPAWN_MAX, "the starts in the window were not counted right");

        // the exit of a guard that is not the current one starts nothing
        st.on_exit_in(42, t0 + RESPAWN_WINDOW * 3, &mut spawn);
        assert_eq!(count(), RESPAWN_MAX + 1);
        assert_eq!(st.pid, Some(106));
        // nor does one during the exit
        st.finishing = true;
        st.on_exit_in(106, t0 + RESPAWN_WINDOW * 3, &mut spawn);
        assert_eq!(count(), RESPAWN_MAX + 1, "a guard was started during the exit");
    }
}
