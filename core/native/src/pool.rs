//! The worker pool: three priority lanes, detached worker threads, cancel,
//! and completions collected by poll after a wake byte.
//!
//! Lock order, everywhere: `q`, then `done`, then the wake socket's lock;
//! never the reverse. No lock is held while a job runs.
//!
//! A submit takes no lock unless it has to wake a worker. It pushes its job
//! onto the inbox, a lock-free stack that only a holder of `q` takes from:
//! a worker moves the whole inbox into the lanes (in submit order) before
//! every pop, cancel moves it before it looks for a queued job, close drops
//! it. So the submitting thread (Neovim's UI thread) does not wait for `q`,
//! which every worker takes for every job it starts and finishes (on macOS
//! a contended mutex sleeps in the kernel at once).
//!
//! Waking a parked worker is a syscall, made only when needed:
//! - A worker parks (waits on `cv` under `q`) only after raising `parked`
//!   and looking at the inbox once more; a submit pushes, then reads
//!   `parked`. Both are SeqCst, so either the worker sees the job or the
//!   submit sees the parked worker. A submit that sees one takes `q` (by
//!   then that worker waits, or has seen the job) and claims a wake for an
//!   idle worker (`woken`).
//! - A submit wakes a worker only when no claimed wake is on its way
//!   (`waking` mirrors `woken` outside `q`): a worker leaving its wait gives
//!   up its claim and moves the inbox in that same hold of `q`, so it takes
//!   this job too.
//! - A worker that finds more jobs in the lanes than the one it takes
//!   wakes idle workers for them, so a burst wakes the pool from the
//!   workers, not from the submitting thread.

use std::collections::{HashMap, VecDeque};
use std::io;
use std::os::fd::OwnedFd;
use std::ptr;
use std::sync::atomic::{AtomicBool, AtomicPtr, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Condvar, Mutex, MutexGuard};
use std::thread;

use crate::abi::{CANCELLED, EINVAL, EKIND, ENOJOB, ERR, ESHUTDOWN, FLAG_COPY, OK, PANIC, PRIO_MASK};
use crate::jobs::{self, JobCx, JobErr};
use crate::panic::guard;
use crate::wake::Wake;

/// The most workers a pool takes.
pub const MAX_WORKERS: u32 = 64;
/// Worker stack size: deep enough for the recursive engines later kinds run.
const STACK_SIZE: usize = 8 << 20;
/// The number of priority lanes (visible, normal, background).
const LANES: usize = 3;

/// One finished job, as `jnv_poll` hands it over.
#[derive(Debug)]
pub struct Done {
    pub job: u64,
    pub kind: u32,
    pub status: i32,
    pub result: Option<Vec<u8>>,
}

/// A borrowed input: the caller's pointer and length. The caller keeps the
/// bytes alive and unchanged until the job's completion is polled (or for
/// the rest of the process after close), which is what makes sending the
/// pointer to a worker sound.
struct SendPtr(*const u8, usize);
// SAFETY: see the type's contract above; the bytes are only read.
unsafe impl Send for SendPtr {}

enum Input {
    Borrowed(SendPtr),
    Owned(Vec<u8>),
}

impl Input {
    /// The input bytes. A borrowed input keeps the caller's pointer even when
    /// it is empty (PTR reports it); only NULL, which submit allows with
    /// length 0 alone, becomes the empty slice.
    fn as_slice(&self) -> &[u8] {
        match self {
            Input::Owned(v) => v,
            Input::Borrowed(p) if p.0.is_null() => &[],
            // SAFETY: non-null, and valid for p.1 bytes per the borrowing
            // contract (for p.1 == 0 any non-null pointer is valid).
            Input::Borrowed(p) => unsafe { std::slice::from_raw_parts(p.0, p.1) },
        }
    }
}

struct Job {
    id: u64,
    kind: u32,
    input: Input,
    cancel: Arc<AtomicBool>,
}

/// A submitted job on the inbox, newest first.
struct Node {
    job: Job,
    prio: usize,
    next: *mut Node,
}

struct Queues {
    lanes: [VecDeque<Job>; LANES],
    /// Jobs a worker is running, with their cancel flags.
    running: HashMap<u64, Arc<AtomicBool>>,
    /// Workers in their condvar wait, or woken and not yet back to the lanes.
    idle: usize,
    /// Wakes claimed for idle workers and not yet taken up by one.
    woken: usize,
    shutdown: bool,
}

impl Queues {
    /// The next job: the lowest-numbered (most urgent) non-empty lane,
    /// first in first out inside it.
    fn pop(&mut self) -> Option<Job> {
        self.lanes.iter_mut().find_map(|lane| lane.pop_front())
    }

    /// Claim wakes for up to `n` idle workers no claimed wake is on its way
    /// to; the number claimed, each to be followed by a notify once `q` is
    /// released. (`woken` never exceeds `idle`: it is raised only up to it,
    /// and a worker leaving its wait lowers `idle` and, when not 0, `woken`.)
    fn claim(&mut self, sh: &Shared, n: usize) -> usize {
        let k = n.min(self.idle.saturating_sub(self.woken));
        if k > 0 {
            self.woken += k;
            sh.waking.store(self.woken, Ordering::SeqCst);
        }
        k
    }
}

pub(crate) struct Shared {
    q: Mutex<Queues>,
    cv: Condvar,
    /// Jobs submitted and not yet moved into the lanes (a stack, newest
    /// first). Pushed without a lock; taken whole, only under `q`.
    inbox: AtomicPtr<Node>,
    /// `Queues::idle`, readable without `q`.
    parked: AtomicUsize,
    /// `Queues::woken`, readable without `q`.
    waking: AtomicUsize,
    /// Set by close under `q`; a submit that sees it is refused.
    closed: AtomicBool,
    done: Mutex<VecDeque<Done>>,
    wake: Wake,
    next: AtomicU64,
    /// Condvar notifies a submit made (tests and diagnostics).
    notifies: AtomicU64,
    #[cfg(test)]
    gate: Gate,
}

/// Tests only: a point where the first thread to reach it stops once armed,
/// so a test can act while that thread is exactly there. The three points
/// in a worker's wait for work stop it holding `q`; the one in submit stops
/// the submitting thread before its push. It opens when the test opens it,
/// or after 2 s.
#[cfg(test)]
#[derive(Default)]
struct Gate {
    /// The point armed: 0 none, or one of the `GATE_*` points below.
    armed: AtomicUsize,
    held: AtomicBool,
    open: AtomicBool,
}

/// After a worker found no job, before it counts itself idle.
#[cfg(test)]
const GATE_PARK: usize = 1;
/// Right after a worker's wait returns, before it gives up its claim.
#[cfg(test)]
const GATE_WOKEN: usize = 2;
/// Right after a worker counts itself parked, before its last look at the
/// inbox.
#[cfg(test)]
const GATE_RAISED: usize = 3;
/// In submit, after the job is made and before it is pushed (and so before
/// the submit reads `parked`).
#[cfg(test)]
const GATE_SUBMIT: usize = 4;

#[cfg(test)]
impl Gate {
    fn pass(&self, at: usize) {
        if self.armed.compare_exchange(at, 0, Ordering::SeqCst, Ordering::SeqCst).is_err() {
            return;
        }
        self.held.store(true, Ordering::SeqCst);
        let end = std::time::Instant::now() + std::time::Duration::from_secs(2);
        while !self.open.load(Ordering::SeqCst) && std::time::Instant::now() < end {
            thread::sleep(std::time::Duration::from_micros(100));
        }
        self.held.store(false, Ordering::SeqCst);
    }
}

/// Free a list of inbox nodes and the jobs in them.
fn free_nodes(mut p: *mut Node) {
    while !p.is_null() {
        // SAFETY: every node was made by Box::into_raw in submit and is
        // reachable from exactly one list, which its taker owns.
        let node = unsafe { Box::from_raw(p) };
        p = node.next;
    }
}

/// Move every job on the inbox into its lane, oldest first. Under `q`.
fn take_inbox(sh: &Shared, q: &mut Queues) {
    if sh.inbox.load(Ordering::SeqCst).is_null() {
        return;
    }
    // Reverse the stack (newest first) so the lanes get submit order.
    let mut p = sh.inbox.swap(ptr::null_mut(), Ordering::SeqCst);
    let mut oldest: *mut Node = ptr::null_mut();
    while !p.is_null() {
        // SAFETY: the swap made this list ours alone; see free_nodes.
        let n = unsafe { &mut *p };
        let next = n.next;
        n.next = oldest;
        oldest = p;
        p = next;
    }
    while !oldest.is_null() {
        // SAFETY: as above; each node is taken back exactly once.
        let node = unsafe { Box::from_raw(oldest) };
        oldest = node.next;
        let Node { job, prio, .. } = *node;
        q.lanes[prio].push_back(job);
    }
}

/// A pool of worker threads. Dropping it closes it.
pub struct Pool {
    shared: Arc<Shared>,
    workers: usize,
}

/// Lock, recovering from poisoning: nothing here may panic outside a guard.
pub(crate) fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

/// The automatic worker count on a machine with `cores` cores: all but one
/// (left for Neovim and the terminal), at least 1 and at most 4.
pub(crate) fn auto_workers(cores: usize) -> usize {
    cores.saturating_sub(1).clamp(1, 4)
}

/// The worker count for a requested one: 0 is automatic ([`auto_workers`]),
/// 1 to 64 are taken as given, more is refused.
pub fn resolve_workers(requested: u32) -> io::Result<usize> {
    match requested {
        0 => {
            let cores = thread::available_parallelism().map(|n| n.get()).unwrap_or(1);
            Ok(auto_workers(cores))
        }
        1..=MAX_WORKERS => Ok(requested as usize),
        _ => Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("workers must be 0 (automatic) or 1 to {MAX_WORKERS}, got {requested}"),
        )),
    }
}

impl Pool {
    /// Start a pool and its wake socket; returns the pool and the wake
    /// socket's read end for the caller to watch.
    pub fn new(workers: u32) -> io::Result<(Pool, OwnedFd)> {
        let n = resolve_workers(workers)?;
        let (wake, rx) = Wake::new()?;
        let shared = Arc::new(Shared {
            q: Mutex::new(Queues {
                lanes: Default::default(),
                running: HashMap::new(),
                idle: 0,
                woken: 0,
                shutdown: false,
            }),
            cv: Condvar::new(),
            inbox: AtomicPtr::new(ptr::null_mut()),
            parked: AtomicUsize::new(0),
            waking: AtomicUsize::new(0),
            closed: AtomicBool::new(false),
            done: Mutex::new(VecDeque::new()),
            wake,
            next: AtomicU64::new(1),
            notifies: AtomicU64::new(0),
            #[cfg(test)]
            gate: Gate::default(),
        });
        let pool = Pool { shared, workers: n };
        for i in 0..n {
            let sh = pool.shared.clone();
            let spawned = thread::Builder::new()
                .name(format!("jnv-worker-{i}"))
                .stack_size(STACK_SIZE)
                .spawn(move || {
                    let _ = guard(|| worker_loop(&sh));
                });
            match spawned {
                // Detached: never joined, so closing never waits for a job.
                Ok(handle) => drop(handle),
                // Dropping the pool closes it, which stops the workers
                // already started.
                Err(e) => return Err(e),
            }
        }
        Ok((pool, rx))
    }

    /// The number of worker threads.
    pub fn workers(&self) -> usize {
        self.workers
    }

    /// Queue a job. `flags` is a priority (0 visible, 1 normal,
    /// 2 background) plus optionally [`FLAG_COPY`]. Returns the job id
    /// (from 1, increasing) or a status: EINVAL for bad flags, NULL with a
    /// length, or a copy that cannot be allocated; EKIND for an unsupported
    /// kind; ESHUTDOWN after close.
    ///
    /// # Safety
    /// `ptr` is NULL with `len` 0, or valid for `len` bytes. Without
    /// [`FLAG_COPY`] the bytes stay valid and unchanged until the job's
    /// completion is polled, or for the rest of the process after close.
    pub unsafe fn submit(&self, kind: u32, flags: u32, ptr: *const u8, len: usize) -> Result<u64, i32> {
        let prio = flags & PRIO_MASK;
        if prio as usize >= LANES || flags & !(PRIO_MASK | FLAG_COPY) != 0 {
            return Err(EINVAL);
        }
        if ptr.is_null() && len > 0 {
            return Err(EINVAL);
        }
        if !jobs::supported(kind) {
            return Err(EKIND);
        }
        // Copy before anything is queued, so a large copy never stalls workers.
        let input = if flags & FLAG_COPY != 0 {
            // SAFETY: non-null and valid for len bytes (the caller's contract).
            let src: &[u8] = if len == 0 { &[] } else { unsafe { std::slice::from_raw_parts(ptr, len) } };
            let mut v = Vec::new();
            // An allocation failure is refused, never an abort of the host.
            if v.try_reserve_exact(len).is_err() {
                return Err(EINVAL);
            }
            v.extend_from_slice(src);
            Input::Owned(v)
        } else {
            Input::Borrowed(SendPtr(ptr, len))
        };
        let sh = &*self.shared;
        if sh.closed.load(Ordering::SeqCst) {
            return Err(ESHUTDOWN);
        }
        let id = sh.next.fetch_add(1, Ordering::Relaxed);
        let node = Box::into_raw(Box::new(Node {
            job: Job { id, kind, input, cancel: Arc::new(AtomicBool::new(false)) },
            prio: prio as usize,
            next: ptr::null_mut(),
        }));
        #[cfg(test)]
        sh.gate.pass(GATE_SUBMIT);
        let mut head = sh.inbox.load(Ordering::Relaxed);
        loop {
            // SAFETY: the node is ours until the push below succeeds.
            unsafe { (*node).next = head };
            match sh.inbox.compare_exchange_weak(head, node, Ordering::SeqCst, Ordering::Relaxed) {
                Ok(_) => break,
                Err(now) => head = now,
            }
        }
        // After the push (see the module comment): a worker counted as
        // parked may be waiting without having seen this job, so one is
        // woken, unless a claimed wake is on its way already. A busy pool,
        // or one being woken, costs the submit nothing more.
        if sh.parked.load(Ordering::SeqCst) > 0 && sh.waking.load(Ordering::SeqCst) == 0 {
            let mut q = lock(&sh.q);
            let wake = if q.woken == 0 { q.claim(sh, 1) } else { 0 };
            drop(q);
            if wake > 0 {
                sh.notifies.fetch_add(1, Ordering::Relaxed);
                sh.cv.notify_one();
            }
        }
        Ok(id)
    }

    /// Cancel a job. Queued: removed, and a CANCELLED completion is queued
    /// at once (with a wake). Running: its cancel flag is set and it
    /// completes with whatever status it reaches. ENOJOB when the id is
    /// neither queued nor running, ESHUTDOWN after close.
    pub fn cancel(&self, job: u64) -> i32 {
        let sh = &*self.shared;
        let mut q = lock(&sh.q);
        if q.shutdown {
            return ESHUTDOWN;
        }
        take_inbox(sh, &mut q);
        let mut removed = None;
        for lane in q.lanes.iter_mut() {
            if let Some(at) = lane.iter().position(|j| j.id == job) {
                removed = lane.remove(at);
                break;
            }
        }
        if let Some(j) = removed {
            drop(q);
            lock(&sh.done).push_back(Done {
                job: j.id,
                kind: j.kind,
                status: CANCELLED,
                result: Some(b"cancelled".to_vec()),
            });
            sh.wake.signal();
            return OK;
        }
        match q.running.get(&job) {
            Some(flag) => {
                flag.store(true, Ordering::Relaxed);
                OK
            }
            None => ENOJOB,
        }
    }

    /// Move up to `max` completions out, in completion order. Re-arms the
    /// wake first, so a completion that lands after this call always writes
    /// a new wake byte. `max == 0` moves nothing and changes nothing.
    pub fn poll(&self, max: usize) -> Vec<Done> {
        if max == 0 {
            return Vec::new();
        }
        let sh = &*self.shared;
        sh.wake.reset();
        let mut done = lock(&sh.done);
        let n = max.min(done.len());
        done.drain(..n).collect()
    }

    /// Shut down without waiting: queued jobs are dropped without
    /// completions, running jobs get their cancel flag, idle workers wake
    /// and exit, and the wake socket's write end is closed. Workers are
    /// never joined; one still finishing a job exits when it is done.
    /// Calling it again only frees a job a submit racing the first call
    /// pushed after it (dropping the pool calls it again).
    pub fn close(&self) {
        let sh = &*self.shared;
        let mut q = lock(&sh.q);
        q.shutdown = true;
        sh.closed.store(true, Ordering::SeqCst);
        free_nodes(sh.inbox.swap(ptr::null_mut(), Ordering::SeqCst));
        for lane in q.lanes.iter_mut() {
            lane.clear();
        }
        for flag in q.running.values() {
            flag.store(true, Ordering::Relaxed);
        }
        drop(q);
        sh.cv.notify_all();
        sh.wake.close();
    }

    /// Wake bytes written so far (tests and diagnostics).
    pub fn wake_writes(&self) -> u64 {
        self.shared.wake.writes()
    }

    /// Condvar notifies submits made so far (tests and diagnostics).
    pub fn notifies(&self) -> u64 {
        self.shared.notifies.load(Ordering::Relaxed)
    }
}

impl Drop for Pool {
    fn drop(&mut self) {
        self.close();
    }
}

/// A worker: take the most urgent job, run it under the panic guard with no
/// lock held, publish its completion and wake the caller; exit on shutdown.
fn worker_loop(sh: &Shared) {
    loop {
        let job = {
            let mut q = lock(&sh.q);
            loop {
                if q.shutdown {
                    return;
                }
                take_inbox(sh, &mut q);
                if let Some(job) = q.pop() {
                    q.running.insert(job.id, job.cancel.clone());
                    // more jobs than this one: wake parked workers for them
                    let more = q.lanes.iter().map(VecDeque::len).sum();
                    let wake = q.claim(sh, more);
                    drop(q);
                    for _ in 0..wake {
                        sh.cv.notify_one();
                    }
                    break job;
                }
                #[cfg(test)]
                sh.gate.pass(GATE_PARK);
                q.idle += 1;
                sh.parked.fetch_add(1, Ordering::SeqCst);
                #[cfg(test)]
                sh.gate.pass(GATE_RAISED);
                // one more look, now that a submit can see this worker parked
                if !sh.inbox.load(Ordering::SeqCst).is_null() {
                    q.idle -= 1;
                    sh.parked.fetch_sub(1, Ordering::SeqCst);
                    continue;
                }
                q = sh.cv.wait(q).unwrap_or_else(|e| e.into_inner());
                #[cfg(test)]
                sh.gate.pass(GATE_WOKEN);
                q.idle -= 1;
                sh.parked.fetch_sub(1, Ordering::SeqCst);
                // a claimed wake is taken up here, and the inbox is moved
                // (at the top) in this same hold of `q`
                if q.woken > 0 {
                    q.woken -= 1;
                    sh.waking.store(q.woken, Ordering::SeqCst);
                }
            }
        };
        let r = guard(|| jobs::run(job.kind, job.input.as_slice(), &JobCx { cancel: &job.cancel }));
        let (status, result) = match r {
            Ok(Ok(v)) => (OK, v),
            Ok(Err(JobErr::Err(m))) => (ERR, Some(m.into_bytes())),
            Ok(Err(JobErr::Cancelled)) => (CANCELLED, Some(b"cancelled".to_vec())),
            Err(m) => (PANIC, Some(m.into_bytes())),
        };
        lock(&sh.q).running.remove(&job.id);
        let Job { id, kind, input, .. } = job;
        // Nothing reads the input past this point: once the completion is
        // published the caller may free a borrowed one. An owned copy is
        // freed here, before the caller hears about the job.
        drop(input);
        lock(&sh.done).push_back(Done { job: id, kind, status, result });
        sh.wake.signal();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::abi::*;
    use std::collections::HashSet;
    use std::io::{ErrorKind, Read};
    use std::os::unix::io::AsRawFd;
    use std::os::unix::net::UnixStream;
    use std::sync::mpsc;
    use std::time::{Duration, Instant};

    struct Harness {
        pool: Pool,
        rx: UnixStream,
    }

    fn open(workers: u32) -> Harness {
        let (pool, fd) = Pool::new(workers).expect("pool");
        let rx = UnixStream::from(fd);
        rx.set_nonblocking(true).unwrap();
        Harness { pool, rx }
    }

    fn submit(h: &Harness, kind: u32, flags: u32, data: &[u8]) -> u64 {
        unsafe { h.pool.submit(kind, flags, data.as_ptr(), data.len()) }.expect("submit")
    }

    fn sleep_job(h: &Harness, ms: u32) -> u64 {
        submit(h, KIND_SLEEP, PRIO_NORMAL | FLAG_COPY, &ms.to_le_bytes())
    }

    /// Read every byte the wake socket holds; true when the write end is closed.
    fn drain(rx: &UnixStream) -> bool {
        let mut buf = [0u8; 256];
        loop {
            match (&*rx).read(&mut buf) {
                Ok(0) => return true,
                Ok(_) => {}
                Err(e) if e.kind() == ErrorKind::Interrupted => {}
                Err(_) => return false,
            }
        }
    }

    /// Wait up to `ms` for the wake socket to become readable (a byte, or end
    /// of file); true when it did.
    fn wait_readable(rx: &UnixStream, ms: i32) -> bool {
        let end = Instant::now() + Duration::from_millis(ms.max(1) as u64);
        loop {
            let left = end.saturating_duration_since(Instant::now()).as_millis().max(1) as i32;
            let mut p = libc::pollfd { fd: rx.as_raw_fd(), events: libc::POLLIN, revents: 0 };
            let r = unsafe { libc::poll(&mut p, 1, left) };
            if r > 0 {
                return true;
            }
            if r == 0 || std::io::Error::last_os_error().kind() != ErrorKind::Interrupted {
                return false;
            }
        }
    }

    /// Poll until a call returns fewer than 64, as the Lua pump does.
    fn poll_all(h: &Harness, out: &mut Vec<Done>) -> usize {
        let before = out.len();
        loop {
            let got = h.pool.poll(64);
            let k = got.len();
            out.extend(got);
            if k < 64 {
                return out.len() - before;
            }
        }
    }

    /// How long a published completion's wake byte may take to follow it:
    /// the worker signals right after publishing, so only a preempted worker
    /// is ever late. Generous, so a loaded machine never fails a good run.
    const WAKE_GRACE_MS: i32 = 2000;

    /// Collect completions the way the Lua side does: poll, and when nothing
    /// is there, wait for the wake byte. A completion must never arrive
    /// without one: when the wait runs out and a last poll still finds
    /// completions, their wake byte must follow within [`WAKE_GRACE_MS`] (it
    /// may be in flight between publish and signal), or the wake was lost
    /// and the test fails. So a lost wake fails here instead of only making
    /// the test slower.
    fn collect(h: &Harness, n: usize, timeout: Duration) -> Vec<Done> {
        let end = Instant::now() + timeout;
        let mut out = Vec::new();
        loop {
            poll_all(h, &mut out);
            if out.len() >= n {
                return out;
            }
            let now = Instant::now();
            if now >= end {
                return out;
            }
            if wait_readable(&h.rx, (end - now).as_millis().min(10_000) as i32) {
                drain(&h.rx);
                continue;
            }
            let late = poll_all(h, &mut out);
            if late > 0 {
                assert!(
                    wait_readable(&h.rx, WAKE_GRACE_MS),
                    "lost wake: {late} completion(s) were published but no wake byte came"
                );
                drain(&h.rx);
            }
        }
    }

    fn wait_running(h: &Harness, id: u64) {
        let end = Instant::now() + Duration::from_secs(2);
        while Instant::now() < end {
            if lock(&h.pool.shared.q).running.contains_key(&id) {
                return;
            }
            std::thread::sleep(Duration::from_micros(200));
        }
        panic!("job {id} never started");
    }

    fn result(d: &Done) -> &[u8] {
        d.result.as_deref().expect("a result")
    }

    /// Wait up to 2 s until exactly `n` workers are in their idle wait.
    fn wait_idle(h: &Harness, n: usize) {
        let end = Instant::now() + Duration::from_secs(2);
        while Instant::now() < end {
            if lock(&h.pool.shared.q).idle == n {
                return;
            }
            std::thread::sleep(Duration::from_micros(200));
        }
        panic!("never {n} idle workers (now {})", lock(&h.pool.shared.q).idle);
    }

    /// Wait up to 2 s until a worker stops at the armed gate.
    fn wait_gate(h: &Harness) {
        let g = &h.pool.shared.gate;
        let end = Instant::now() + Duration::from_secs(2);
        while !g.held.load(Ordering::SeqCst) {
            assert!(Instant::now() < end, "no worker reached the gate");
            std::thread::sleep(Duration::from_micros(100));
        }
    }

    #[test]
    fn a_submit_wakes_a_worker_only_when_one_is_idle() {
        // A condvar notify can cost a syscall even with no waiter, so a
        // submit pays for one only when a worker waits for work.
        let h = open(1);
        wait_idle(&h, 1);
        let n0 = h.pool.notifies();
        let first = submit(&h, KIND_ECHO, PRIO_NORMAL, b"first");
        assert_eq!(h.pool.notifies() - n0, 1, "a submit to an idle worker wakes it");
        let got = collect(&h, 1, Duration::from_secs(5));
        assert_eq!(got.len(), 1);
        assert_eq!((got[0].job, got[0].status), (first, OK));
        assert_eq!(result(&got[0]), b"first");
        wait_idle(&h, 1);
        let sleep = sleep_job(&h, 300);
        wait_running(&h, sleep);
        let n1 = h.pool.notifies();
        let inputs: Vec<Vec<u8>> = (0..100).map(|i| format!("echo {i}").into_bytes()).collect();
        let ids: Vec<u64> = inputs.iter().map(|d| submit(&h, KIND_ECHO, PRIO_NORMAL, d)).collect();
        assert_eq!(h.pool.notifies() - n1, 0, "a submit while every worker is busy wakes none");
        let got = collect(&h, 101, Duration::from_secs(5));
        assert_eq!(got.len(), 101, "every job completes without a notify of its own");
        assert_eq!((got[0].job, got[0].status), (sleep, OK));
        for (d, (id, want)) in got[1..].iter().zip(ids.iter().zip(&inputs)) {
            assert_eq!((d.job, d.status), (*id, OK));
            assert_eq!(result(d), &want[..]);
        }
    }

    #[test]
    fn idle_workers_all_start_at_once() {
        // Four jobs submitted back to back to four idle workers run at the
        // same time: each submit wakes a worker while one is idle, also
        // when the lane already holds a job no worker has taken yet.
        let h = open(4);
        wait_idle(&h, 4);
        let ids: Vec<u64> = (0..4).map(|_| sleep_job(&h, 1000)).collect();
        let end = Instant::now() + Duration::from_millis(500);
        let mut all = false;
        while !all && Instant::now() < end {
            let q = lock(&h.pool.shared.q);
            all = ids.iter().all(|id| q.running.contains_key(id));
            drop(q);
            if !all {
                std::thread::sleep(Duration::from_micros(200));
            }
        }
        for id in &ids {
            assert_eq!(h.pool.cancel(*id), OK);
        }
        assert!(all, "four idle workers must take four jobs at once");
        let got = collect(&h, 4, Duration::from_secs(2));
        assert_eq!(got.len(), 4);
        assert!(got.iter().all(|d| d.status == CANCELLED), "{got:?}");
    }

    #[test]
    fn a_submit_never_waits_for_the_lock_the_workers_share() {
        // A worker holds `q` for every job it takes and finishes, and one
        // that is preempted while it holds it would stall a submit that
        // needs it. Here the test holds `q` itself, its only worker busy:
        // 100 submits from another thread must all return meanwhile.
        let h = open(1);
        let sleep = sleep_job(&h, 300);
        wait_running(&h, sleep);
        let inputs: Arc<Vec<Vec<u8>>> = Arc::new((0..100).map(|i| format!("held {i}").into_bytes()).collect());
        let held = lock(&h.pool.shared.q);
        let (tx, rx) = mpsc::channel();
        let ids = std::thread::scope(|s| {
            let ins = inputs.clone();
            let pool = &h.pool;
            let t = s.spawn(move || {
                let ids: Vec<u64> = ins
                    .iter()
                    .map(|d| unsafe { pool.submit(KIND_ECHO, PRIO_NORMAL, d.as_ptr(), d.len()) }.expect("submit"))
                    .collect();
                tx.send(()).unwrap();
                ids
            });
            let returned = rx.recv_timeout(Duration::from_secs(1)).is_ok();
            drop(held);
            let ids = t.join().unwrap();
            assert!(returned, "a submit waited for the lock a worker holds");
            ids
        });
        let got = collect(&h, 101, Duration::from_secs(5));
        assert_eq!(got.len(), 101);
        assert_eq!((got[0].job, got[0].status), (sleep, OK));
        for (d, (id, want)) in got[1..].iter().zip(ids.iter().zip(inputs.iter())) {
            assert_eq!((d.job, d.status), (*id, OK));
            assert_eq!(result(d), &want[..]);
        }
    }

    #[test]
    fn a_burst_to_idle_workers_leaves_the_waking_to_the_workers() {
        // Waking a parked worker is a syscall. A submit makes one only when
        // no wake is on its way already, and a worker that finds more jobs
        // than the one it takes wakes the others, so a burst to an idle
        // pool costs the submitting thread a handful of wakes, not one per
        // job (or per job taken by a worker not yet back).
        let h = open(4);
        wait_idle(&h, 4);
        let n0 = h.pool.notifies();
        for _ in 0..10_000 {
            submit(&h, KIND_NOP, PRIO_NORMAL, b"burst");
        }
        let made = h.pool.notifies() - n0;
        let got = collect(&h, 10_000, Duration::from_secs(10));
        assert_eq!(got.len(), 10_000);
        assert!(got.iter().all(|d| d.status == OK));
        assert!(made <= 100, "the submitting thread woke a worker {made} times for 10,000 jobs");
    }

    #[test]
    fn a_visible_job_submitted_while_others_wait_runs_first() {
        // b1 runs, b2 waits in its lane; v, submitted then, runs before b2.
        let h = open(1);
        let first = sleep_job(&h, 150);
        wait_running(&h, first);
        let b1 = submit(&h, KIND_SLEEP, PRIO_BACKGROUND | FLAG_COPY, &150u32.to_le_bytes());
        let b2 = submit(&h, KIND_ECHO, PRIO_BACKGROUND, b"b2");
        wait_running(&h, b1);
        let v = submit(&h, KIND_ECHO, PRIO_VISIBLE, b"v");
        let got = collect(&h, 4, Duration::from_secs(5));
        let order: Vec<u64> = got.iter().map(|d| d.job).collect();
        assert_eq!(order, vec![first, b1, v, b2]);
        assert!(got.iter().all(|d| d.status == OK), "{got:?}");
    }

    #[test]
    fn a_job_pushed_after_close_is_freed_when_the_pool_is_dropped() {
        // A submit that races close can push its job after close emptied
        // the inbox (it read `closed` before close set it). No worker takes
        // it; dropping the pool closes again, which frees it.
        let h = open(1);
        let sh = h.pool.shared.clone();
        h.pool.close();
        let flag = Arc::new(AtomicBool::new(false));
        let node = Box::into_raw(Box::new(Node {
            job: Job { id: 0, kind: KIND_NOP, input: Input::Owned(vec![1, 2, 3]), cancel: flag.clone() },
            prio: PRIO_NORMAL as usize,
            next: std::ptr::null_mut(),
        }));
        sh.inbox.store(node, Ordering::SeqCst);
        std::thread::sleep(Duration::from_millis(20));
        assert_eq!(Arc::strong_count(&flag), 2, "no worker takes a job after close");
        drop(h);
        assert_eq!(Arc::strong_count(&flag), 1, "dropping the pool frees the job left in the inbox");
        assert!(sh.inbox.load(Ordering::SeqCst).is_null());
    }

    #[test]
    fn a_worker_about_to_park_takes_a_job_pushed_just_before() {
        // The worker has found no job and has not counted itself idle yet,
        // so a submit now sees no parked worker and wakes none. Its last
        // look at the inbox, after it counts itself idle, finds the job.
        let h = open(1);
        wait_idle(&h, 1);
        let g = &h.pool.shared.gate;
        g.armed.store(GATE_PARK, Ordering::SeqCst);
        let a = submit(&h, KIND_NOP, PRIO_NORMAL, b"");
        wait_gate(&h);
        assert_eq!(h.pool.shared.parked.load(Ordering::SeqCst), 0);
        let n0 = h.pool.notifies();
        let b = submit(&h, KIND_ECHO, PRIO_NORMAL, b"b");
        assert_eq!(h.pool.notifies() - n0, 0, "no worker is parked, so the submit wakes none");
        g.open.store(true, Ordering::SeqCst);
        let got = collect(&h, 2, Duration::from_secs(2));
        let jobs: Vec<(u64, i32)> = got.iter().map(|d| (d.job, d.status)).collect();
        assert_eq!(jobs, vec![(a, OK), (b, OK)], "the job pushed just before the worker parked never ran");
    }

    #[test]
    fn a_submit_while_a_wake_is_on_its_way_wakes_no_other_worker() {
        // The first submit wakes one of three parked workers; it stops right
        // after its wait returns, its claim not yet given up. Submits now
        // wake nobody: that worker moves the inbox when it goes on, and
        // wakes the others for the jobs beyond its own.
        let h = open(3);
        wait_idle(&h, 3);
        let g = &h.pool.shared.gate;
        g.armed.store(GATE_WOKEN, Ordering::SeqCst);
        let n0 = h.pool.notifies();
        let mut ids = vec![submit(&h, KIND_NOP, PRIO_NORMAL, b"")];
        wait_gate(&h);
        for _ in 0..3 {
            ids.push(submit(&h, KIND_NOP, PRIO_NORMAL, b""));
        }
        let made = h.pool.notifies() - n0;
        // Still at the gate: no submit waited for `q`, which that worker
        // holds there. One that took it would have waited until the gate
        // opened on its own, 2 s on.
        let still_held = g.held.load(Ordering::SeqCst);
        g.open.store(true, Ordering::SeqCst);
        assert!(still_held, "a submit waited for the worker holding q while its wake was on its way");
        assert_eq!(made, 1, "a submit woke a second worker while the first was on its way");
        let got = collect(&h, 4, Duration::from_secs(2));
        let mut done: Vec<u64> = got.iter().map(|d| d.job).collect();
        done.sort_unstable();
        assert_eq!(done, ids);
    }

    #[test]
    fn a_job_on_the_inbox_once_a_worker_counts_itself_parked_is_taken_by_its_last_look() {
        // The worker's half of the pair: it raises `parked`, then looks at
        // the inbox once more. A job on the inbox by then (here put there
        // with no wake at all, as a submit that read `parked` just before the
        // raise leaves it) is found by that look and runs. Looked at before
        // the raise, it would wait on the inbox with every worker asleep.
        let h = open(1);
        wait_idle(&h, 1);
        let g = &h.pool.shared.gate;
        g.armed.store(GATE_RAISED, Ordering::SeqCst);
        let a = submit(&h, KIND_NOP, PRIO_NORMAL, b"");
        wait_gate(&h);
        let sh = &h.pool.shared;
        let id = sh.next.fetch_add(1, Ordering::Relaxed);
        let node = Box::into_raw(Box::new(Node {
            job: Job { id, kind: KIND_NOP, input: Input::Owned(Vec::new()), cancel: Arc::new(AtomicBool::new(false)) },
            prio: PRIO_NORMAL as usize,
            next: std::ptr::null_mut(),
        }));
        sh.inbox.store(node, Ordering::SeqCst);
        g.open.store(true, Ordering::SeqCst);
        let got = collect(&h, 2, Duration::from_secs(2));
        let jobs: Vec<u64> = got.iter().map(|d| d.job).collect();
        assert_eq!(jobs, vec![a, id], "the job on the inbox before the last look never ran");
    }

    #[test]
    fn a_submit_reads_parked_only_after_its_push() {
        // The submit's half of the pair: it pushes, then reads `parked`.
        // Here it stops just before its push while the only worker finishes
        // its job, finds the inbox empty and parks. When the submit goes on,
        // its read comes after its push, so it sees the parked worker and
        // wakes it. Read before the push, it would have seen a busy worker,
        // woken none, and the job would never run.
        let h = open(1);
        let sleep = sleep_job(&h, 50);
        wait_running(&h, sleep);
        let g = &h.pool.shared.gate;
        g.armed.store(GATE_SUBMIT, Ordering::SeqCst);
        let late = std::thread::scope(|s| {
            let pool = &h.pool;
            let t = s.spawn(move || {
                let data: &'static [u8] = b"late";
                unsafe { pool.submit(KIND_ECHO, PRIO_NORMAL, data.as_ptr(), data.len()) }.expect("submit")
            });
            wait_gate(&h);
            // the worker is in its wait (it holds `q` from counting itself
            // idle until the wait releases it)
            wait_idle(&h, 1);
            g.open.store(true, Ordering::SeqCst);
            t.join().unwrap()
        });
        let got = collect(&h, 2, Duration::from_secs(2));
        let jobs: Vec<(u64, i32)> = got.iter().map(|d| (d.job, d.status)).collect();
        assert_eq!(jobs, vec![(sleep, OK), (late, OK)], "the job pushed while the only worker parked never ran");
        assert_eq!(result(&got[1]), b"late");
    }

    #[test]
    fn parked_workers_always_wake_for_new_work() {
        // Each round starts with every worker parked, or (the rounds that do
        // not wait) with workers on their way to park, so a submit has to
        // wake one. A wake lost between a worker's last look for work and
        // its wait leaves a job no worker takes, and collect comes back
        // short.
        for workers in [1u32, 2, 4] {
            let h = open(workers);
            for round in 0..300u32 {
                wait_idle(&h, workers as usize);
                let k = (round % 5 + 1) as usize;
                for _ in 0..k {
                    submit(&h, KIND_NOP, PRIO_NORMAL, b"");
                }
                let got = collect(&h, k, Duration::from_secs(2));
                assert_eq!(got.len(), k, "{workers} workers, round {round}: a job never ran");
            }
            for round in 0..5000u32 {
                submit(&h, KIND_NOP, PRIO_NORMAL, b"");
                let got = collect(&h, 1, Duration::from_secs(2));
                assert_eq!(got.len(), 1, "{workers} workers, round {round} without a wait: a job never ran");
            }
        }
    }

    #[test]
    fn echo_round_trip() {
        let h = open(2);
        let data = b"hello\0world".to_vec();
        let id = submit(&h, KIND_ECHO, PRIO_NORMAL, &data);
        assert_eq!(id, 1, "ids start at 1");
        let got = collect(&h, 1, Duration::from_secs(5));
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].job, id);
        assert_eq!(got[0].kind, KIND_ECHO);
        assert_eq!(got[0].status, OK);
        assert_eq!(result(&got[0]), &data[..]);
        let id2 = submit(&h, KIND_NOP, PRIO_NORMAL, b"");
        assert_eq!(id2, 2, "ids increase");
        let got = collect(&h, 1, Duration::from_secs(5));
        assert_eq!(got[0].job, id2);
        assert!(got[0].result.is_none());
    }

    #[test]
    fn visible_lane_first_then_normal_then_background_fifo_inside() {
        let h = open(1);
        let sleep = sleep_job(&h, 200);
        wait_running(&h, sleep);
        // Interleaved submission: b0 n0 v0 b1 n1 v1 b2 n2 v2. The inputs are
        // borrowed, so they live until every completion is collected.
        let mut inputs: Vec<(u32, String)> = Vec::new();
        for i in 0..3 {
            for (prio, tag) in [(PRIO_BACKGROUND, "b"), (PRIO_NORMAL, "n"), (PRIO_VISIBLE, "v")] {
                inputs.push((prio, format!("{tag}{i}")));
            }
        }
        let mut ids = std::collections::HashMap::new();
        for (prio, name) in &inputs {
            ids.insert(submit(&h, KIND_ECHO, *prio, name.as_bytes()), name.clone());
        }
        let got = collect(&h, 10, Duration::from_secs(5));
        assert_eq!(got.len(), 10);
        assert_eq!(got[0].job, sleep);
        assert_eq!(got[0].status, OK);
        let order: Vec<String> = got[1..]
            .iter()
            .map(|d| {
                assert_eq!(d.status, OK);
                let name = String::from_utf8(result(d).to_vec()).unwrap();
                assert_eq!(ids[&d.job], name);
                name
            })
            .collect();
        assert_eq!(order, ["v0", "v1", "v2", "n0", "n1", "n2", "b0", "b1", "b2"]);
    }

    #[test]
    fn cancel_queued_completes_at_once_and_never_runs() {
        let h = open(1);
        let sleep = sleep_job(&h, 200);
        wait_running(&h, sleep);
        let victim = submit(&h, KIND_PANIC, PRIO_VISIBLE, b"must never run");
        assert_eq!(h.pool.cancel(victim), OK);
        let got = collect(&h, 1, Duration::from_secs(5));
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].job, victim, "the cancel arrives before the SLEEP ends");
        assert_eq!(got[0].kind, KIND_PANIC);
        assert_eq!(got[0].status, CANCELLED);
        assert_eq!(result(&got[0]), b"cancelled");
        assert_eq!(h.pool.cancel(victim), ENOJOB);
        let after = submit(&h, KIND_NOP, PRIO_BACKGROUND, b"");
        let rest = collect(&h, 2, Duration::from_secs(5));
        let jobs: Vec<(u64, i32)> = rest.iter().map(|d| (d.job, d.status)).collect();
        assert_eq!(jobs, vec![(sleep, OK), (after, OK)]);
        // Nothing else ever arrives: the cancelled PANIC job never ran.
        assert!(collect(&h, 1, Duration::from_millis(50)).is_empty());
    }

    #[test]
    fn cancel_running_sleep_completes_cancelled_within_100ms() {
        let h = open(1);
        let id = sleep_job(&h, 5000);
        wait_running(&h, id);
        let t = Instant::now();
        assert_eq!(h.pool.cancel(id), OK);
        let got = collect(&h, 1, Duration::from_secs(2));
        let el = t.elapsed();
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].job, id);
        assert_eq!(got[0].status, CANCELLED);
        assert_eq!(result(&got[0]), b"cancelled");
        assert!(el < Duration::from_millis(100), "{el:?}");
    }

    #[test]
    fn cancel_of_an_unknown_or_finished_id_is_enojob() {
        let h = open(1);
        assert_eq!(h.pool.cancel(12345), ENOJOB);
        assert_eq!(h.pool.cancel(0), ENOJOB);
        let id = submit(&h, KIND_NOP, PRIO_NORMAL, b"");
        assert_eq!(collect(&h, 1, Duration::from_secs(5)).len(), 1);
        assert_eq!(h.pool.cancel(id), ENOJOB);
    }

    #[test]
    fn a_panicking_job_is_reported_and_the_worker_survives() {
        let h = open(1);
        let p = submit(&h, KIND_PANIC, PRIO_NORMAL, b"boom");
        let e = submit(&h, KIND_ECHO, PRIO_NORMAL, b"after");
        let got = collect(&h, 2, Duration::from_secs(5));
        assert_eq!(got.len(), 2);
        assert_eq!((got[0].job, got[0].status), (p, PANIC));
        let m = String::from_utf8_lossy(result(&got[0])).into_owned();
        assert!(m.contains("jnv test panic: boom"), "{m}");
        assert_eq!((got[1].job, got[1].status), (e, OK));
        assert_eq!(result(&got[1]), b"after");
    }

    #[test]
    fn errors_are_reported_with_their_message() {
        let h = open(1);
        let id = submit(&h, KIND_SLEEP, PRIO_NORMAL, &[1, 2, 3]);
        let got = collect(&h, 1, Duration::from_secs(5));
        assert_eq!((got[0].job, got[0].status), (id, ERR));
        assert_eq!(result(&got[0]), b"SLEEP wants 4 bytes (u32 milliseconds)");
    }

    #[test]
    fn close_is_fast_and_final() {
        let h = open(1);
        let id = sleep_job(&h, 2000);
        wait_running(&h, id);
        let queued = sleep_job(&h, 10);
        let t = Instant::now();
        h.pool.close();
        let el = t.elapsed();
        assert!(el < Duration::from_millis(5), "close took {el:?}");
        let data = b"late";
        assert_eq!(
            unsafe { h.pool.submit(KIND_ECHO, PRIO_NORMAL, data.as_ptr(), data.len()) },
            Err(ESHUTDOWN)
        );
        assert_eq!(h.pool.cancel(id), ESHUTDOWN);
        assert_eq!(h.pool.cancel(queued), ESHUTDOWN);
        // The wake write end is closed: the reader reaches end of file.
        let end = Instant::now() + Duration::from_secs(1);
        let mut eof = false;
        while !eof && Instant::now() < end {
            wait_readable(&h.rx, 50);
            eof = drain(&h.rx);
        }
        assert!(eof, "the wake write end must be closed by close()");
        // Closing again is harmless.
        h.pool.close();
    }

    #[test]
    fn close_never_waits_for_a_worker() {
        // Hold the completion queue so the worker cannot finish its job: a
        // close that waited for workers (a join) would block here.
        let h = open(1);
        let id = sleep_job(&h, 2000);
        wait_running(&h, id);
        let pool = &h.pool;
        let r = std::thread::scope(|s| {
            let held = lock(&pool.shared.done);
            let (tx, rx) = mpsc::channel();
            s.spawn(move || {
                let t = Instant::now();
                pool.close();
                let _ = tx.send(t.elapsed());
            });
            let r = rx.recv_timeout(Duration::from_millis(500));
            drop(held);
            r
        });
        let el = r.expect("close() waited for a worker that could not finish");
        assert!(el < Duration::from_millis(5), "close took {el:?}");
    }

    #[test]
    fn ptr_is_borrowed_by_default_and_copied_with_the_flag() {
        let h = open(2);
        let data = vec![7u8; 32];
        let borrowed = submit(&h, KIND_PTR, PRIO_NORMAL, &data);
        let copied = submit(&h, KIND_PTR, PRIO_NORMAL | FLAG_COPY, &data);
        let got = collect(&h, 2, Duration::from_secs(5));
        assert_eq!(got.len(), 2);
        let addr = |id: u64| {
            let d = got.iter().find(|d| d.job == id).expect("completion");
            assert_eq!(d.status, OK);
            u64::from_le_bytes(result(d).try_into().unwrap())
        };
        assert_eq!(addr(borrowed), data.as_ptr() as u64);
        assert_ne!(addr(copied), data.as_ptr() as u64);
    }

    #[test]
    fn copy_flag_snapshots_the_input() {
        let h = open(1);
        let sleep = sleep_job(&h, 50);
        wait_running(&h, sleep);
        let mut data = b"original".to_vec();
        let id = submit(&h, KIND_ECHO, PRIO_NORMAL | FLAG_COPY, &data);
        data.copy_from_slice(b"changed!");
        let got = collect(&h, 2, Duration::from_secs(5));
        let d = got.iter().find(|d| d.job == id).unwrap();
        assert_eq!(result(d), b"original");
    }

    #[test]
    fn invalid_submits_are_rejected_and_never_complete() {
        let h = open(1);
        let data = b"x";
        let s = |kind: u32, flags: u32, ptr: *const u8, len: usize| unsafe {
            h.pool.submit(kind, flags, ptr, len)
        };
        assert_eq!(s(KIND_ECHO, PRIO_NORMAL, std::ptr::null(), 5), Err(EINVAL));
        assert_eq!(s(KIND_ECHO, 3, data.as_ptr(), 1), Err(EINVAL));
        assert_eq!(s(KIND_ECHO, 3 | FLAG_COPY, data.as_ptr(), 1), Err(EINVAL));
        for bad in [4u32, 8, 128, 512, 1 << 16, 1 << 31] {
            assert_eq!(s(KIND_ECHO, bad, data.as_ptr(), 1), Err(EINVAL), "flag {bad}");
        }
        assert_eq!(s(0, PRIO_NORMAL, data.as_ptr(), 1), Err(EKIND));
        assert_eq!(s(8, PRIO_NORMAL, data.as_ptr(), 1), Err(EKIND));
        assert_eq!(s(u32::MAX, PRIO_NORMAL, data.as_ptr(), 1), Err(EKIND));
        // NULL with length 0 is an empty input.
        let ok = s(KIND_ECHO, PRIO_BACKGROUND, std::ptr::null(), 0).expect("empty input");
        let ok2 = s(KIND_ECHO, PRIO_VISIBLE | FLAG_COPY, std::ptr::null(), 0).expect("empty copy");
        let got = collect(&h, 2, Duration::from_secs(5));
        let mut ids: Vec<u64> = got.iter().map(|d| d.job).collect();
        ids.sort_unstable();
        assert_eq!(ids, vec![ok, ok2]);
        assert!(got.iter().all(|d| d.status == OK && d.result.as_deref() == Some(&b""[..])));
        assert!(collect(&h, 1, Duration::from_millis(50)).is_empty());
    }

    #[test]
    fn twenty_thousand_jobs_each_come_back_exactly_once() {
        let h = open(4);
        let mut sent = HashSet::new();
        for i in 0..20_000u32 {
            let id = unsafe { h.pool.submit(KIND_NOP, i % 3, std::ptr::null(), 0) }.unwrap();
            assert!(sent.insert(id));
        }
        let got = collect(&h, 20_000, Duration::from_secs(20));
        assert_eq!(got.len(), 20_000);
        let mut seen = HashSet::new();
        for d in &got {
            assert_eq!((d.kind, d.status), (KIND_NOP, OK));
            assert!(d.result.is_none());
            assert!(seen.insert(d.job), "job {} came back twice", d.job);
        }
        assert_eq!(seen, sent);
        assert!(collect(&h, 1, Duration::from_millis(50)).is_empty());
        assert!(h.pool.wake_writes() >= 1);
    }

    #[test]
    fn poll_respects_its_limit_and_keeps_completion_order() {
        let h = open(1);
        let ids: Vec<u64> = (0..5).map(|_| submit(&h, KIND_NOP, PRIO_NORMAL, b"")).collect();
        let end = Instant::now() + Duration::from_secs(5);
        while lock(&h.pool.shared.done).len() < 5 && Instant::now() < end {
            std::thread::sleep(Duration::from_millis(1));
        }
        let a = h.pool.poll(2);
        let b = h.pool.poll(2);
        let c = h.pool.poll(2);
        assert_eq!((a.len(), b.len(), c.len()), (2, 2, 1));
        assert!(h.pool.poll(2).is_empty());
        assert!(h.pool.poll(0).is_empty());
        let order: Vec<u64> = a.iter().chain(&b).chain(&c).map(|d| d.job).collect();
        assert_eq!(order, ids);
    }

    #[test]
    fn worker_count() {
        let avail = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(1);
        let auto = (avail.saturating_sub(1)).clamp(1, 4);
        assert_eq!(resolve_workers(0).unwrap(), auto);
        assert!((1..=4).contains(&auto));
        assert_eq!(resolve_workers(1).unwrap(), 1);
        assert_eq!(resolve_workers(64).unwrap(), 64);
        assert_eq!(resolve_workers(65).unwrap_err().kind(), ErrorKind::InvalidInput);
        assert_eq!(resolve_workers(u32::MAX).unwrap_err().kind(), ErrorKind::InvalidInput);
        let h = open(0);
        assert_eq!(h.pool.workers(), auto);
        assert_eq!(open(3).pool.workers(), 3);
        assert!(Pool::new(65).is_err());
    }

    #[test]
    fn auto_workers_leaves_one_core_and_caps_at_four() {
        // The automatic count for every core count, not only this machine's.
        let want = [(1, 1), (2, 1), (3, 2), (4, 3), (5, 4), (6, 4), (16, 4), (128, 4)];
        for (cores, workers) in want {
            assert_eq!(auto_workers(cores), workers, "{cores} cores");
        }
        // A machine that reports no cores at all still gets one worker.
        assert_eq!(auto_workers(0), 1);
    }

    #[test]
    fn ptr_of_a_borrowed_empty_input_is_the_callers_pointer() {
        // A Lua "" is a non-null pointer with length 0; the job reads from
        // the caller's pointer, as for any borrowed input.
        let h = open(1);
        let data = [1u8; 8];
        let id = unsafe { h.pool.submit(KIND_PTR, PRIO_NORMAL, data.as_ptr(), 0) }.unwrap();
        let got = collect(&h, 1, Duration::from_secs(5));
        assert_eq!((got[0].job, got[0].status), (id, OK));
        let addr = u64::from_le_bytes(result(&got[0]).try_into().unwrap());
        assert_eq!(addr, data.as_ptr() as u64, "borrowed PTR with len 0 reports {addr:#x}");
    }

    /// Waits up to `ms` for the wake socket and reads what is there: the
    /// number of bytes (0 when no byte arrived in time).
    fn wake_bytes_within(rx: &UnixStream, ms: i32) -> usize {
        wait_readable(rx, ms);
        let mut buf = [0u8; 64];
        (&*rx).read(&mut buf).unwrap_or(0)
    }

    #[test]
    fn every_batch_after_a_poll_writes_a_new_wake_byte() {
        let h = open(1);
        for round in 0..3 {
            let id = submit(&h, KIND_NOP, PRIO_NORMAL, b"");
            assert_eq!(wake_bytes_within(&h.rx, 2000), 1, "round {round}: one wake byte");
            let got = h.pool.poll(64);
            assert_eq!(got.len(), 1, "round {round}");
            assert_eq!(got[0].job, id);
        }
    }

    #[test]
    fn cancel_of_a_queued_job_wakes_the_caller() {
        let h = open(1);
        let sleep = sleep_job(&h, 300);
        wait_running(&h, sleep);
        let victim = submit(&h, KIND_ECHO, PRIO_NORMAL, b"queued");
        assert_eq!(h.pool.cancel(victim), OK);
        assert_eq!(wake_bytes_within(&h.rx, 150), 1, "the CANCELLED completion must wake at once");
        let got = h.pool.poll(64);
        assert_eq!((got[0].job, got[0].status), (victim, CANCELLED));
    }

    #[test]
    fn close_cancels_the_running_job_and_drops_the_queued_one() {
        let h = open(1);
        let id = sleep_job(&h, 2000);
        wait_running(&h, id);
        let queued = sleep_job(&h, 10);
        h.pool.close();
        let end = Instant::now() + Duration::from_millis(200);
        let mut status = None;
        while Instant::now() < end {
            if let Some(d) = lock(&h.pool.shared.done).iter().find(|d| d.job == id) {
                status = Some(d.status);
                break;
            }
            std::thread::sleep(Duration::from_millis(1));
        }
        assert_eq!(status, Some(CANCELLED), "the running job must see its cancel flag at close");
        std::thread::sleep(Duration::from_millis(50));
        assert!(lock(&h.pool.shared.done).iter().all(|d| d.job != queued), "queued jobs complete nothing");
        assert!(lock(&h.pool.shared.q).lanes.iter().all(|l| l.is_empty()), "queued jobs are dropped");
    }

    #[test]
    fn a_poll_rearms_the_wake_before_it_takes_completions() {
        // A completion published while a poll is collecting must write a new
        // byte, so poll re-arms the wake before it takes completions. Hold
        // the completion queue so a poll stops right where it takes them,
        // and signal (as a worker does after publishing) until a byte comes:
        // a poll that re-armed first lets one through; one that re-arms only
        // after collecting never does, whatever the timing.
        let h = open(1);
        let id = submit(&h, KIND_NOP, PRIO_NORMAL, b"");
        // The NOP's wake leaves the flag pending; the caller reads the byte
        // and polls, as the Lua side does.
        assert_eq!(wake_bytes_within(&h.rx, 2000), 1);
        let sh = &*h.pool.shared;
        let pool = &h.pool;
        let (woke, got) = std::thread::scope(|s| {
            let held = lock(&sh.done);
            let poller = s.spawn(move || pool.poll(64));
            let end = Instant::now() + Duration::from_secs(2);
            let mut woke = false;
            while !woke && Instant::now() < end {
                sh.wake.signal();
                woke = wait_readable(&h.rx, 1);
            }
            drop(held);
            (woke, poller.join().unwrap())
        });
        assert!(woke, "a poll in progress must re-arm the wake before it takes completions");
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].job, id);
    }

    #[test]
    fn the_wake_byte_follows_the_published_completion() {
        // A wake byte announces completions poll can already take: the
        // worker publishes first and signals after. Hold the completion
        // queue so the worker cannot publish; until it can, no byte may come
        // (a byte before the completion is a lost wake once the caller has
        // polled in between).
        let h = open(1);
        let sh = &*h.pool.shared;
        let held = lock(&sh.done);
        let id = submit(&h, KIND_NOP, PRIO_NORMAL, b"");
        // Wait until the worker has run the job (it has left the lanes and
        // the running set) and is about to publish. Taking `q` while holding
        // `done` cannot deadlock: no code holds `q` while it waits for `done`.
        let end = Instant::now() + Duration::from_secs(2);
        loop {
            let q = lock(&sh.q);
            if q.lanes.iter().all(|l| l.is_empty()) && !q.running.contains_key(&id) {
                break;
            }
            drop(q);
            assert!(Instant::now() < end, "job {id} never ran");
            std::thread::sleep(Duration::from_micros(200));
        }
        assert!(!wait_readable(&h.rx, 200), "a wake byte came before its completion was published");
        drop(held);
        let got = collect(&h, 1, Duration::from_secs(5));
        assert_eq!(got.len(), 1);
        assert_eq!((got[0].job, got[0].status), (id, OK));
    }

    #[test]
    fn the_last_completion_of_every_round_wakes_the_caller() {
        let h = open(4);
        for round in 0..2000 {
            let mut want: HashSet<u64> = HashSet::new();
            for _ in 0..3 {
                want.insert(unsafe { h.pool.submit(KIND_NOP, PRIO_NORMAL, std::ptr::null(), 0) }.unwrap());
            }
            while !want.is_empty() {
                assert!(
                    wait_readable(&h.rx, 1000),
                    "round {round}: lost wake, {} jobs outstanding",
                    want.len()
                );
                drain(&h.rx);
                let mut got = Vec::new();
                poll_all(&h, &mut got);
                for d in got {
                    assert!(want.remove(&d.job));
                }
            }
        }
    }

    #[test]
    fn close_lets_idle_workers_exit() {
        let h = open(4);
        let sh = h.pool.shared.clone();
        // The pool, four workers and this clone.
        assert_eq!(Arc::strong_count(&sh), 6);
        // Every worker waits for work, so close has to wake them.
        wait_idle(&h, 4);
        h.pool.close();
        let end = Instant::now() + Duration::from_millis(500);
        while Arc::strong_count(&sh) > 2 && Instant::now() < end {
            std::thread::sleep(Duration::from_millis(1));
        }
        assert_eq!(Arc::strong_count(&sh), 2, "idle workers must exit after close");
    }

    #[test]
    fn dropping_the_pool_lets_workers_exit() {
        let h = open(3);
        let sh = h.pool.shared.clone();
        assert_eq!(Arc::strong_count(&sh), 5);
        drop(h);
        let end = Instant::now() + Duration::from_millis(500);
        while Arc::strong_count(&sh) > 1 && Instant::now() < end {
            std::thread::sleep(Duration::from_millis(1));
        }
        assert_eq!(Arc::strong_count(&sh), 1, "workers must exit once the pool is dropped");
    }

    #[test]
    fn a_running_job_finishing_after_close_never_writes_a_wake_byte() {
        let h = open(1);
        let id = sleep_job(&h, 30);
        wait_running(&h, id);
        // Drain whatever is there, then close while the job runs.
        drain(&h.rx);
        h.pool.close();
        // The job sees its cancel flag and completes; the wake end is closed,
        // so the reader sees only end of file, never a byte.
        let mut buf = [0u8; 16];
        let end = Instant::now() + Duration::from_millis(500);
        let mut bytes = 0;
        loop {
            wait_readable(&h.rx, 50);
            match (&h.rx).read(&mut buf) {
                Ok(0) => break,
                Ok(n) => bytes += n,
                Err(_) => {}
            }
            assert!(Instant::now() < end, "no end of file after close");
        }
        assert_eq!(bytes, 0, "a byte was written after close");
    }

    #[test]
    fn many_cancels_and_completions_interleaved_never_lose_or_duplicate() {
        let h = open(4);
        let mut want: HashSet<u64> = HashSet::new();
        let mut ids = Vec::new();
        for i in 0..3000u32 {
            let id = unsafe { h.pool.submit(KIND_NOP, i % 3, std::ptr::null(), 0) }.unwrap();
            want.insert(id);
            ids.push(id);
            if i % 7 == 0 {
                let r = h.pool.cancel(ids[(i as usize) / 2]);
                assert!(r == OK || r == ENOJOB, "cancel gave {r}");
            }
        }
        let got = collect(&h, 3000, Duration::from_secs(20));
        let mut seen = HashSet::new();
        for d in &got {
            assert!(d.status == OK || d.status == CANCELLED, "status {}", d.status);
            assert!(seen.insert(d.job), "job {} twice", d.job);
        }
        assert_eq!(seen, want);
    }
}
