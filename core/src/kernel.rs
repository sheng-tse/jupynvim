// Start a Jupyter kernel and own its sockets (shell, control, iopub).
//
// Each start writes its connection file into a dir of its own in the
// backend's private runtime dir (connfile.rs); the dir is removed when the
// kernel exits for any reason. An ipykernel gets port 0 for every socket,
// binds its own ports and writes them back to the file, and the backend
// connects once they are there. Other kernels (IJulia, IRkernel and the
// rest never write their ports back) get ports held in TIME_WAIT, which
// nobody binding port 0 is handed, and count as started only once they
// answer a kernel_info_request signed with the file's key; a start whose
// ports were taken anyway is retried with new ones. Each kernel runs in a
// session of its own, is registered with the kernel guard process
// (guard.rs), and is stopped with its whole process group, also when only
// its own process exits.

use anyhow::{anyhow, Context, Result};
use bytes::Bytes;
use dashmap::DashMap;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::future::Future;
use std::net::Ipv4Addr;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::process::{Child, Command};
use tokio::sync::{mpsc, oneshot, watch, Mutex};
use tokio::task::JoinHandle;
use uuid::Uuid;
use zeromq::{DealerSocket, Socket, SocketRecv, SocketSend, SubSocket, ZmqMessage};

use crate::connfile::{KernelDir, Runtime};
use crate::kernelspec::KernelSpec;
use crate::protocol::{self, Message};

/// How long a start may take while the kernel's process runs (a first-run
/// Julia precompile takes minutes); a process that exits ends it at once.
const START_TIMEOUT: Duration = Duration::from_secs(300);
/// How often a starting kernel is looked at. The connection file a kernel
/// writes its ports back to is read every POLL all along (a read costs
/// almost nothing, and a slow start is not made slower). Reserved ports
/// are probed every POLL for the first POLL_FAST_FOR after the spawn (a
/// kernel that starts fast is seen at once), then every POLL_SLOW (one that
/// takes minutes, such as a first-run Julia precompile, is not probed
/// hundreds of times a second all along).
const POLL: Duration = Duration::from_millis(5);
const POLL_FAST_FOR: Duration = Duration::from_secs(1);
const POLL_SLOW: Duration = Duration::from_millis(50);
/// What a start of a kernel taken for ipykernel waits for: the kernel
/// writing back the ports it bound (pause, late).
const WRITE_PORTS: &str = "write its ports";
/// zeromq's connect retries a refused connection forever, so each one is
/// bounded.
const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
/// A probe of one port during a start (loopback answers at once).
const PROBE_TIMEOUT: Duration = Duration::from_secs(1);
/// Starts of a kernel given reserved ports: the first two with ports held
/// in TIME_WAIT, the last with ports held until just before the spawn.
const RESERVED_ATTEMPTS: u32 = 3;
/// How much of a kernel's stderr is kept for a failed start's message.
const TAIL_MAX: usize = 8192;
/// The end of a kernel's stderr while it starts; None once the start is over.
type StartTail = Arc<parking_lot::Mutex<Option<String>>>;
/// Room above the highest open fd for fds other threads open before a fork.
const FD_MARGIN: libc::c_int = 256;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ConnectionInfo {
    pub ip: String,
    pub transport: String,
    pub shell_port: u16,
    pub iopub_port: u16,
    pub stdin_port: u16,
    pub control_port: u16,
    pub hb_port: u16,
    pub key: String,
    pub signature_scheme: String,
    pub kernel_name: String,
}

impl ConnectionInfo {
    /// Localhost over tcp with a new key; `ports` in the order shell,
    /// iopub, stdin, control, hb (0: the kernel binds one itself).
    pub fn new(kernel_name: &str, ports: [u16; 5]) -> Self {
        Self {
            ip: "127.0.0.1".to_string(),
            transport: "tcp".to_string(),
            shell_port: ports[0],
            iopub_port: ports[1],
            stdin_port: ports[2],
            control_port: ports[3],
            hb_port: ports[4],
            key: Uuid::new_v4().to_string(),
            signature_scheme: "hmac-sha256".to_string(),
            kernel_name: kernel_name.to_string(),
        }
    }

    /// The ports in the order shell, iopub, stdin, control, hb.
    pub fn ports(&self) -> [u16; 5] {
        [self.shell_port, self.iopub_port, self.stdin_port, self.control_port, self.hb_port]
    }

    /// The same connection with other ports. (connfile.rs builds the info
    /// a kernel wrote back by itself; this is the same rule.)
    #[cfg_attr(not(test), allow(dead_code))]
    pub fn with_ports(&self, ports: [u16; 5]) -> Self {
        Self {
            shell_port: ports[0],
            iopub_port: ports[1],
            stdin_port: ports[2],
            control_port: ports[3],
            hb_port: ports[4],
            ..self.clone()
        }
    }

    pub fn endpoint(&self, port: u16) -> String {
        format!("{}://{}:{}", self.transport, self.ip, port)
    }
}

/// Who chooses a kernel's ports.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PortMode {
    /// Every port is written as 0; the kernel binds its own and writes
    /// them back to the connection file (ipykernel does).
    KernelBinds,
    /// The kernel binds the ports it is given and never writes them back:
    /// they are reserved for it (reserve_ports).
    Reserved,
}

impl PortMode {
    /// `metadata.jupynvim.ports` ("kernel" or "reserved") when the
    /// kernelspec sets it. Else KernelBinds for an ipykernel (an argv
    /// element `ipykernel`, or one with `ipykernel_launcher` in it: the
    /// module, the launcher script and shell wrappers around them) and for
    /// a kernel jupynvim gives ipykernel itself (`ensure_ipykernel`), and
    /// Reserved for every other kernel.
    pub fn for_spec(spec: &KernelSpec) -> PortMode {
        match spec.metadata.pointer("/jupynvim/ports").and_then(Value::as_str) {
            Some("kernel") => return PortMode::KernelBinds,
            Some("reserved") => return PortMode::Reserved,
            _ => {}
        }
        let ensured = spec.metadata.pointer("/jupynvim/ensure_ipykernel").and_then(Value::as_bool) == Some(true);
        if ensured || spec.argv.iter().any(|a| a == "ipykernel" || a.contains("ipykernel_launcher")) {
            PortMode::KernelBinds
        } else {
            PortMode::Reserved
        }
    }
}

/// `n` distinct ports for a kernel that binds the ports it is given. Each
/// is left in TIME_WAIT by a connection to it that its own side closed
/// first: a bind without SO_REUSEADDR is then refused, and binding port 0
/// never hands it out, while a listener that sets SO_REUSEADDR (libzmq,
/// Rust std and tokio do) binds it. TIME_WAIT lasts about 30 s on macOS
/// and 60 s on Linux.
pub fn reserve_ports(n: usize) -> std::io::Result<Vec<u16>> {
    use std::io::Read;
    use std::net::{TcpListener, TcpStream};
    let mut held = Vec::with_capacity(n);
    let mut ports = Vec::with_capacity(n);
    while ports.len() < n {
        // held until all n are made, so they are distinct
        let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0))?;
        let addr = listener.local_addr()?;
        let mut client = TcpStream::connect(addr)?;
        let (server, _) = listener.accept()?;
        // the side bound to the port closes first, so the TIME_WAIT is on
        // the port's side of the connection
        drop(server);
        client.set_read_timeout(Some(PROBE_TIMEOUT))?;
        let _ = client.read(&mut [0u8; 1]); // end of file: the close arrived
        drop(client);
        ports.push(addr.port());
        held.push(listener);
    }
    Ok(ports)
}

/// `n` distinct ports with a listener on each, dropped just before the
/// kernel starts: the last attempt, for a kernel whose sockets lack
/// SO_REUSEADDR and so cannot bind a port in TIME_WAIT.
fn pick_held(n: usize) -> std::io::Result<(Vec<u16>, Vec<std::net::TcpListener>)> {
    let mut held = Vec::with_capacity(n);
    let mut ports = Vec::with_capacity(n);
    for _ in 0..n {
        let listener = std::net::TcpListener::bind((Ipv4Addr::LOCALHOST, 0))?;
        ports.push(listener.local_addr()?.port());
        held.push(listener);
    }
    Ok((ports, held))
}

fn port_list(ports: &[u16; 5]) -> String {
    ports.iter().map(u16::to_string).collect::<Vec<_>>().join(",")
}

/// The wait before the next probe of a starting kernel's reserved ports,
/// `since` its spawn.
fn poll_step(since: Duration) -> Duration {
    if since < POLL_FAST_FOR {
        POLL
    } else {
        POLL_SLOW
    }
}

/// Appends `text` to a kernel's stderr tail, keeping its last TAIL_MAX
/// bytes, cut on a char boundary.
fn push_tail(tail: &mut String, text: &str) {
    tail.push_str(text);
    if tail.len() > TAIL_MAX {
        let mut cut = tail.len() - TAIL_MAX;
        while !tail.is_char_boundary(cut) {
            cut += 1;
        }
        tail.drain(..cut);
    }
}

/// The last `n` lines of `s`, without the final newline.
fn last_lines(s: &str, n: usize) -> &str {
    let t = s.trim_end_matches(['\n', '\r']);
    let start = t.rmatch_indices('\n').nth(n.saturating_sub(1)).map_or(0, |(i, _)| i + 1);
    &t[start..]
}

/// Why a start failed: AddrInUse when the kernel's stderr says its address
/// was in use (its ports were taken; a new attempt gets new ones).
enum LaunchError {
    AddrInUse(anyhow::Error),
    Other(anyhow::Error),
}

fn classify(tail: &str, err: anyhow::Error) -> LaunchError {
    if tail.contains("Address already in use") || tail.contains("EADDRINUSE") {
        LaunchError::AddrInUse(err)
    } else {
        LaunchError::Other(err)
    }
}

/// A running kernel's process group, the dir of its start, and the task
/// that owns its process (which reports the exit on `exited`).
struct KernelProc {
    pgid: i32,
    exited: watch::Receiver<bool>,
    dir: Arc<KernelDir>,
    /// set once the group was sent SIGKILL (shared with that task)
    killed: Arc<AtomicBool>,
}

impl KernelProc {
    fn kill_group(&self) {
        kill_group_once(self.pgid, &self.killed)
    }
}

/// SIGKILL to a kernel's process group, at most once per kernel: once the
/// group is gone, its id can be another group's.
fn kill_group_once(pgid: i32, killed: &AtomicBool) {
    if !killed.swap(true, Ordering::AcqRel) && pgid > 1 {
        // SAFETY: killpg only sends a signal. A pgid above 1 names one
        // process group, the kernel's own (it leads a session of its own),
        // never the backend's and never every process.
        unsafe { libc::killpg(pgid, libc::SIGKILL) };
    }
}

/// The kernel's process leads a session of its own: no controlling
/// terminal, none of the terminal's signals, and its whole group can be
/// stopped. It also keeps no fd above 2 across the exec (no_inherited_fds).
fn own_session(cmd: &mut Command) {
    // SAFETY: the closure runs in the child between fork and exec. It
    // calls only setsid, which is async-signal-safe, and allocates nothing.
    unsafe {
        cmd.pre_exec(|| {
            if libc::setsid() == -1 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        });
    }
    no_inherited_fds(cmd.as_std_mut());
}

/// A Command for any other process the backend starts (a language server,
/// a command the frontend runs, a Python probe): it keeps no fd above 2
/// across its exec (no_inherited_fds), so it never holds the guard's pipe.
pub(crate) fn command(program: impl AsRef<std::ffi::OsStr>) -> Command {
    let mut cmd = Command::new(program);
    no_inherited_fds(cmd.as_std_mut());
    cmd
}

/// The process `cmd` starts keeps no fd above 2 across its exec. Rust's std
/// on macOS makes a pipe or socket first and sets close-on-exec on it
/// after, so one made on another thread at the moment of the fork would
/// stay open in the new process for its whole life: a kernel's pipe that
/// a guard holds never reaches end of file while that guard lives, nor the
/// guard's pipe while a kernel, a language server or any other process the
/// backend started holds it. For every process the backend starts.
pub(crate) fn no_inherited_fds(cmd: &mut std::process::Command) {
    use std::os::unix::process::CommandExt;
    let last = highest_fd_to_mark();
    // SAFETY: the closure runs in the child between fork and exec, after
    // std set up its stdin, stdout and stderr. It calls only fcntl, which
    // is async-signal-safe, and allocates nothing.
    unsafe {
        cmd.pre_exec(move || {
            for fd in 3..=last {
                let flags = libc::fcntl(fd, libc::F_GETFD);
                if flags >= 0 && flags & libc::FD_CLOEXEC == 0 {
                    libc::fcntl(fd, libc::F_SETFD, flags | libc::FD_CLOEXEC);
                }
            }
            Ok(())
        });
    }
}

/// The highest fd a process forked now can have: the highest open one, plus
/// room for fds other threads open before the fork (a new fd takes the
/// lowest free number), within the fd limit.
fn highest_fd_to_mark() -> libc::c_int {
    let mut rl = libc::rlimit { rlim_cur: 0, rlim_max: 0 };
    // SAFETY: getrlimit only fills the struct it is given.
    let limit = if unsafe { libc::getrlimit(libc::RLIMIT_NOFILE, &mut rl) } == 0 {
        rl.rlim_cur.min(1 << 20) as libc::c_int
    } else {
        1 << 16
    };
    let open = std::fs::read_dir("/dev/fd").ok().map(|dir| {
        dir.filter_map(|e| e.ok()?.file_name().to_str()?.parse::<libc::c_int>().ok()).max().unwrap_or(2)
    });
    match open {
        Some(highest) => highest.saturating_add(FD_MARGIN).min(limit - 1),
        None => (limit - 1).min(1 << 16),
    }
}

/// The kernel's command: the kernelspec's env, then JPY_PARENT_PID (an
/// ipykernel exits within a second once this process is gone, even when
/// the guard is gone too), stdin closed, stdout and stderr read by the
/// backend, a session of its own.
fn kernel_command(spec: &KernelSpec, argv: &[String], cwd: Option<&Path>) -> Command {
    let mut cmd = Command::new(&argv[0]);
    cmd.args(&argv[1..]);
    for (k, v) in &spec.env {
        cmd.env(k, v);
    }
    cmd.env("JPY_PARENT_PID", std::process::id().to_string());
    if let Some(d) = cwd {
        cmd.current_dir(d);
    }
    cmd.stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped()).kill_on_drop(true);
    own_session(&mut cmd);
    cmd
}

/// Why a start stopped after the spawn.
enum Stop {
    /// the kernel's process exited (not reaped yet: abort reaps it)
    Exited,
    Failed(anyhow::Error),
}

/// What a wait during a start ended with.
enum During<T> {
    Done(T),
    Exited,
    Late,
}

/// `fut`, unless the kernel's process exits first or `until` passes.
async fn during<F: Future>(child: &mut Leader, until: tokio::time::Instant, fut: F) -> During<F::Output> {
    tokio::select! {
        biased;
        () = child.exit() => During::Exited,
        v = fut => During::Done(v),
        _ = tokio::time::sleep_until(until) => During::Late,
    }
}

/// A kernel's process, and the sight of its exit without reaping it. While
/// an exited process is not reaped its pid, and so its group's id, cannot
/// be given to another process; so whatever else runs in its group is sent
/// SIGKILL (kill_group_once) before it is reaped (Child::wait), and the
/// signal can reach no other group.
struct Leader {
    child: Child,
    /// true once the process has exited, seen by a thread of its own that
    /// waits with WNOWAIT (wait_exited_unreaped); None when that thread
    /// cannot be started, and the exit is then seen by reaping the process
    exited: Option<watch::Receiver<bool>>,
}

impl Leader {
    fn new(child: Child) -> Leader {
        let exited = child.id().and_then(|pid| {
            let (tx, rx) = watch::channel(false);
            // Not tokio's blocking pool: dropping the runtime at exit waits
            // for every task still running there.
            let spawned = std::thread::Builder::new()
                .name("jnv-kexit".into())
                .stack_size(64 * 1024)
                .spawn(move || {
                    wait_exited_unreaped(pid);
                    tx.send_replace(true);
                });
            match spawned {
                Ok(_) => Some(rx),
                Err(e) => {
                    tracing::warn!("kernel: cannot start a thread to see pid {pid} exit ({e}); it is reaped at its exit");
                    None
                }
            }
        });
        Leader { child, exited }
    }

    /// Resolves once the process has exited; it is not reaped yet unless no
    /// thread could watch it.
    async fn exit(&mut self) {
        if let Some(rx) = &mut self.exited {
            if rx.wait_for(|e| *e).await.is_ok() {
                return;
            }
        }
        let _ = self.child.wait().await;
    }
}

/// Blocks until the child process `pid` has exited, and leaves it
/// unreaped (waitid with WEXITED | WNOWAIT). Returns at once when it is not
/// a child of this process any more.
// id_t is a u32 on macOS and on Linux.
#[allow(clippy::unnecessary_cast)]
fn wait_exited_unreaped(pid: u32) {
    let id = pid as libc::id_t;
    loop {
        // SAFETY: info is a valid siginfo_t for the call to fill in; waitid
        // with WNOWAIT only reads the child's state.
        let mut info: libc::siginfo_t = unsafe { std::mem::zeroed() };
        let rc = unsafe { libc::waitid(libc::P_PID, id, &mut info, libc::WEXITED | libc::WNOWAIT) };
        if rc == 0 || std::io::Error::last_os_error().raw_os_error() != Some(libc::EINTR) {
            return;
        }
    }
}

/// Output produced by a running cell or kernel idle/busy transitions, etc.
#[derive(Debug, Clone, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum KernelEvent {
    Stream {
        msg_id: String,
        parent_msg_id: Option<String>,
        name: String, // "stdout" | "stderr"
        text: String,
    },
    DisplayData {
        msg_id: String,
        parent_msg_id: Option<String>,
        data: Value,     // mime bundle
        metadata: Value,
        transient: Value,
    },
    ExecuteResult {
        msg_id: String,
        parent_msg_id: Option<String>,
        execution_count: u64,
        data: Value,
        metadata: Value,
    },
    Error {
        msg_id: String,
        parent_msg_id: Option<String>,
        ename: String,
        evalue: String,
        traceback: Vec<String>,
    },
    Status {
        execution_state: String, // "busy" | "idle" | "starting"
        parent_msg_id: Option<String>,
    },
    ExecuteInput {
        parent_msg_id: Option<String>,
        execution_count: u64,
        code: String,
    },
    ExecuteReply {
        parent_msg_id: Option<String>,
        status: String, // "ok" | "error" | "abort"
        execution_count: u64,
    },
    UpdateDisplayData {
        msg_id: String,
        parent_msg_id: Option<String>,
        data: Value,
        metadata: Value,
        transient: Value,
    },
    ClearOutput {
        parent_msg_id: Option<String>,
        wait: bool,
    },
    KernelInfo {
        parent_msg_id: Option<String>,
        info: Value,
    },
    /// Widget comm traffic (ipywidgets). Binary buffers stay bytes. The JSON
    /// form skips them; the derived Debug form prints them, so a comm event must
    /// never reach a Debug-formatted path such as the pump's kernel_event
    /// fallback (the pump hands every comm event to widget_pre, which consumes it).
    CommOpen {
        msg_id: String,
        parent_msg_id: Option<String>,
        comm_id: String,
        target_name: String,
        data: Value,
        metadata: Value,
        #[serde(skip)]
        buffers: Vec<Bytes>,
    },
    CommMsg {
        msg_id: String,
        parent_msg_id: Option<String>,
        comm_id: String,
        data: Value,
        #[serde(skip)]
        buffers: Vec<Bytes>,
    },
    CommClose {
        parent_msg_id: Option<String>,
        comm_id: String,
        data: Value,
    },
}

impl KernelEvent {
    /// True for the widget comm variants, which the event pump hands to the
    /// widget store instead of the cell or global notification path.
    pub fn is_comm(&self) -> bool {
        matches!(
            self,
            KernelEvent::CommOpen { .. } | KernelEvent::CommMsg { .. } | KernelEvent::CommClose { .. }
        )
    }
}

pub struct Kernel {
    spec: KernelSpec,
    conn: ConnectionInfo,
    session: String,
    /// its process group, the dir of its start, its exit
    process: KernelProc,
    /// Outgoing-frame channel for shell socket (the socket-owning task drains this)
    shell_tx: mpsc::UnboundedSender<ZmqMessage>,
    /// Outgoing-frame channel for control socket
    control_tx: mpsc::UnboundedSender<ZmqMessage>,
    iopub_handle: tokio::task::JoinHandle<()>,
    /// Take this once with `take_events()` and drive it from a single consumer task.
    events: Mutex<Option<mpsc::UnboundedReceiver<KernelEvent>>>,
    /// The most recent execute_request msg_id. Used to attribute raw stdout/
    /// stderr from the kernel process (e.g., IPython `!cmd` shell output that
    /// IPython didn't capture via sys.stdout) to a cell. Updated on every
    /// execute_request send.
    active_msg_id: Arc<parking_lot::Mutex<Option<String>>>,
    /// Outstanding shell requests awaiting their reply, keyed by msg_id.
    /// `complete` and `inspect` register a oneshot here BEFORE sending so the
    /// socket owner can deliver the matching reply directly. execute_request
    /// uses iopub events for streaming output and doesn't wait on this map.
    pending: Arc<DashMap<String, oneshot::Sender<Value>>>,
}

impl Kernel {
    /// Starts a kernel from `spec`: one attempt for a kernel that binds its
    /// own ports, up to RESERVED_ATTEMPTS for one given reserved ports,
    /// whose ports someone else can still take (then it exits with an
    /// address in use, and the next attempt gets new ports).
    pub async fn launch(spec: KernelSpec, cwd: Option<PathBuf>) -> Result<Self> {
        let rt = crate::connfile::runtime()?;
        let mode = PortMode::for_spec(&spec);
        let attempts = match mode {
            PortMode::KernelBinds => 1,
            PortMode::Reserved => RESERVED_ATTEMPTS,
        };
        let mut attempt = 1;
        loop {
            match Self::launch_once(&spec, cwd.clone(), rt, mode, attempt).await {
                Ok(kernel) => return Ok(kernel),
                Err(LaunchError::AddrInUse(e)) if attempt < attempts => {
                    tracing::info!("kernel start: attempt {attempt} failed: {e:#}");
                    attempt += 1;
                    tracing::warn!(
                        "kernel start: address in use, retrying with new ports (attempt {attempt} of {RESERVED_ATTEMPTS})"
                    );
                }
                Err(LaunchError::AddrInUse(e) | LaunchError::Other(e)) => return Err(e),
            }
        }
    }

    async fn launch_once(
        spec: &KernelSpec,
        cwd: Option<PathBuf>,
        rt: &'static Runtime,
        mode: PortMode,
        attempt: u32,
    ) -> Result<Self, LaunchError> {
        use LaunchError::Other;
        let name = &spec.name;
        // 1. A dir of its own for this start (made again when something
        // removed the backend's dir).
        let kdir = rt.new_kernel_dir().map_err(Other)?;

        // 2. The ports.
        let mut held = Vec::new();
        let (ports, how) = match (mode, attempt) {
            (PortMode::KernelBinds, _) => ([0; 5], None),
            (PortMode::Reserved, 1 | 2) => {
                let v = tokio::task::spawn_blocking(|| reserve_ports(5))
                    .await
                    .map_err(|e| Other(anyhow!("reserving ports for kernel '{name}': {e}")))?
                    .map_err(|e| Other(anyhow!("cannot reserve ports for kernel '{name}': {e}")))?;
                (five(v).map_err(Other)?, Some("reserved"))
            }
            (PortMode::Reserved, _) => {
                let (v, listeners) =
                    pick_held(5).map_err(|e| Other(anyhow!("cannot pick ports for kernel '{name}': {e}")))?;
                held = listeners;
                (five(v).map_err(Other)?, Some("picked"))
            }
        };

        // 3. The connection file (0600, a new file).
        let conn = ConnectionInfo::new(name, ports);
        if let Some(how) = how {
            tracing::info!("kernel ports: {how} {}", port_list(&conn.ports()));
        }
        kdir.write_connection(&conn).map_err(Other)?;

        // 4. The command.
        let conn_path = kdir.conn_path();
        tracing::info!(conn = %conn_path.display(), kernel = %name, ?mode, attempt, "launching kernel");
        let argv: Vec<String> = spec
            .argv
            .iter()
            .map(|a| {
                a.replace("{connection_file}", conn_path.to_string_lossy().as_ref())
                    .replace("{resource_dir}", spec.path.to_string_lossy().as_ref())
            })
            .collect();
        if argv.is_empty() {
            return Err(Other(anyhow!("kernel '{name}' has empty argv")));
        }
        // A cwd that is missing fails the spawn with the same ENOENT as a
        // missing argv[0], so it is checked here; the kernel then runs in
        // the backend's own cwd.
        let resolved_cwd = match cwd {
            Some(d) if d.exists() => Some(d),
            Some(d) => {
                tracing::warn!("kernel cwd {} does not exist; spawning without chdir", d.display());
                None
            }
            None => None,
        };
        let mut cmd = kernel_command(spec, &argv, resolved_cwd.as_deref());

        // 5. The spawn; from now on the kernel's group is registered with
        // the guard.
        drop(held);
        let argv0_exists = Path::new(&argv[0]).exists();
        let child = cmd
            .spawn()
            .with_context(|| {
                format!(
                    "spawning {:?} (cwd={:?}, argv0_exists={}, env_keys={:?})",
                    argv,
                    resolved_cwd,
                    argv0_exists,
                    spec.env.keys().collect::<Vec<_>>()
                )
            })
            .map_err(Other)?;
        let Some(pid) = child.id() else {
            return Err(Other(anyhow!("kernel '{name}' was gone right after its spawn")));
        };
        let mut child = Leader::new(child);
        // it leads its own session, so its group id is its pid
        let pgid = pid as i32;
        crate::guard::register(pgid);
        let t_spawn = Instant::now();
        let deadline = tokio::time::Instant::from_std(t_spawn + START_TIMEOUT);

        // 6. Its stdout and stderr are read from now on (a full pipe would
        // block it); until the start is over, the end of its stderr is kept
        // for an error message.
        let (tx, rx) = mpsc::unbounded_channel::<KernelEvent>();
        let active_msg_id: Arc<parking_lot::Mutex<Option<String>>> = Arc::new(parking_lot::Mutex::new(None));
        let tail: StartTail = Arc::new(parking_lot::Mutex::new(Some(String::new())));
        // IPython's `!cmd` shell magic writes to the kernel's fd 1 directly
        // (a subprocess inherits it), not through sys.stdout's iopub
        // redirection, so the pipes are forwarded as Stream events.
        if let Some(s) = child.child.stdout.take() {
            tokio::spawn(drain_pipe(s, "stdout".to_string(), active_msg_id.clone(), tx.clone(), None));
        }
        let stderr_task = child.child.stderr.take().map(|s| {
            tokio::spawn(drain_pipe(s, "stderr".to_string(), active_msg_id.clone(), tx.clone(), Some(tail.clone())))
        });

        // 7 to 9. Its ports, the sockets, and for reserved ports its answer.
        let session = Uuid::new_v4().to_string();
        let (conn, shell, control, iopub) =
            match bring_up(&mut child, name, &kdir, conn, mode, t_spawn, deadline, &session).await {
                Ok(up) => up,
                Err(stop) => return Err(abort(child, pgid, &kdir, stderr_task, &tail, name, stop).await),
            };
        // the start is over: its stderr is no longer kept
        *tail.lock() = None;

        // 10. Running.
        tracing::info!("kernel sockets connected {} ms after spawn", t_spawn.elapsed().as_millis());
        let key = conn.key.as_bytes().to_vec();
        let iopub_handle = tokio::spawn(iopub_loop(iopub, key.clone(), tx.clone()));
        // One owner per shell and control socket: a select on its outgoing
        // channel and the socket's recv.
        let (shell_tx, shell_rx) = mpsc::unbounded_channel::<ZmqMessage>();
        let (control_tx, control_rx) = mpsc::unbounded_channel::<ZmqMessage>();
        let pending: Arc<DashMap<String, oneshot::Sender<Value>>> = Arc::new(DashMap::new());
        tokio::spawn(socket_owner(shell, shell_rx, key.clone(), tx.clone(), "shell", Some(pending.clone())));
        tokio::spawn(socket_owner(control, control_rx, key, tx, "control", None));

        // 11. A task owns the kernel's process from now on.
        let (tx_exit, exited) = watch::channel(false);
        let killed = Arc::new(AtomicBool::new(false));
        tokio::spawn(watch_exit(child, pgid, kdir.clone(), killed.clone(), tx_exit));

        // 12.
        Ok(Self {
            spec: spec.clone(),
            conn,
            session,
            process: KernelProc { pgid, exited, dir: kdir, killed },
            shell_tx,
            control_tx,
            iopub_handle,
            events: Mutex::new(Some(rx)),
            pending,
            active_msg_id,
        })
    }

    pub fn spec(&self) -> &KernelSpec { &self.spec }
    pub fn session(&self) -> &str { &self.session }

    /// Move the events receiver out. Returns None if already taken.
    pub async fn take_events(&self) -> Option<mpsc::UnboundedReceiver<KernelEvent>> {
        self.events.lock().await.take()
    }

    /// Send `execute_request`. Returns the msg_id that's already known BEFORE
    /// the bytes hit the wire — so callers can register routing tables before
    /// iopub events start coming back.
    pub async fn execute(&self, code: &str) -> Result<String> {
        self.execute_with_id(code, Uuid::new_v4().to_string()).await
    }

    /// Same as `execute`, but the msg_id is provided externally — handy for
    /// pre-registering msg_id → cell_id BEFORE the request goes out, avoiding
    /// the race where iopub events arrive before the routing map is updated.
    pub async fn execute_with_id(&self, code: &str, msg_id: String) -> Result<String> {
        self.execute_with_id_opts(code, msg_id, false, true).await
    }

    /// `execute_with_id` with explicit silent and store_history flags.
    /// silent=true tells the kernel not to broadcast iopub results AND
    /// not to increment the execution counter. store_history=false also
    /// keeps the run out of Out[N] cache.
    pub async fn execute_with_id_opts(
        &self,
        code: &str,
        msg_id: String,
        silent: bool,
        store_history: bool,
    ) -> Result<String> {
        let mut msg = Message::new(
            "execute_request",
            self.session.clone(),
            protocol::execute_request(code, silent, store_history),
        );
        msg.header.msg_id = msg_id.clone();
        // Mark this as the active execute so drain_pipe can attribute raw
        // stdout/stderr lines (from !cmd) to the right cell.
        if !silent {
            *self.active_msg_id.lock() = Some(msg_id.clone());
        }
        let key = self.conn.key.as_bytes();
        let frames = msg.to_frames(key)?;
        let zmsg = frames_to_zmq(frames);
        self.shell_tx.send(zmsg).map_err(|_| anyhow!("shell channel closed"))?;
        Ok(msg_id)
    }

    /// Send `complete_request` and await the kernel's `complete_reply`.
    /// Returns the reply content as JSON: `{matches, cursor_start, cursor_end,
    /// metadata, status}`. Times out at 2s.
    pub async fn complete(&self, code: &str, cursor_pos: usize) -> Result<Value> {
        self.shell_request(
            "complete_request",
            json!({ "code": code, "cursor_pos": cursor_pos }),
        )
        .await
    }

    /// Send `inspect_request` and await the kernel's `inspect_reply`.
    /// Returns `{status, found, data, metadata}`. detail_level 0 = brief, 1 = full.
    pub async fn inspect(&self, code: &str, cursor_pos: usize, detail_level: u8) -> Result<Value> {
        self.shell_request(
            "inspect_request",
            json!({ "code": code, "cursor_pos": cursor_pos, "detail_level": detail_level }),
        )
        .await
    }

    /// Send a shell-channel request that expects a single reply (not iopub
    /// events). Registers a oneshot in `pending` keyed by msg_id BEFORE the
    /// frame goes out, so the socket owner can route the reply directly.
    async fn shell_request(&self, msg_type: &'static str, content: Value) -> Result<Value> {
        let msg_id = Uuid::new_v4().to_string();
        let (tx, rx) = oneshot::channel();
        self.pending.insert(msg_id.clone(), tx);

        let mut msg = Message::new(msg_type, self.session.clone(), content);
        msg.header.msg_id = msg_id.clone();
        let key = self.conn.key.as_bytes();
        let frames = msg.to_frames(key)?;
        let zmsg = frames_to_zmq(frames);
        if self.shell_tx.send(zmsg).is_err() {
            self.pending.remove(&msg_id);
            return Err(anyhow!("shell channel closed"));
        }

        match tokio::time::timeout(Duration::from_millis(2000), rx).await {
            Ok(Ok(reply)) => Ok(reply),
            Ok(Err(_)) => {
                self.pending.remove(&msg_id);
                Err(anyhow!("{msg_type} reply dropped"))
            }
            Err(_) => {
                self.pending.remove(&msg_id);
                Err(anyhow!("{msg_type} timed out"))
            }
        }
    }

    /// A synchronous sender for this kernel's comm traffic: it owns a clone of
    /// the shell channel and the signing key (see CommSender). The session keeps
    /// it for as long as this kernel is its current one.
    pub fn comm_sender(&self) -> CommSender {
        CommSender::new(
            self.shell_tx.clone(),
            self.conn.key.as_bytes().to_vec(),
            self.session.clone(),
        )
    }

    pub async fn kernel_info(&self) -> Result<()> {
        let msg = Message::new(
            "kernel_info_request",
            self.session.clone(),
            protocol::kernel_info_request(),
        );
        let key = self.conn.key.as_bytes();
        let frames = msg.to_frames(key)?;
        self.shell_tx.send(frames_to_zmq(frames)).map_err(|_| anyhow!("shell closed"))?;
        Ok(())
    }

    pub async fn interrupt(&self) -> Result<()> {
        let msg = Message::new(
            "interrupt_request",
            self.session.clone(),
            protocol::interrupt_request(),
        );
        let key = self.conn.key.as_bytes();
        let frames = msg.to_frames(key)?;
        self.control_tx.send(frames_to_zmq(frames)).map_err(|_| anyhow!("control closed"))?;
        Ok(())
    }

    pub async fn shutdown(&self, restart: bool) -> Result<()> {
        let msg = Message::new(
            "shutdown_request",
            self.session.clone(),
            protocol::shutdown_request(restart),
        );
        let key = self.conn.key.as_bytes();
        let frames = msg.to_frames(key)?;
        self.control_tx.send(frames_to_zmq(frames)).map_err(|_| anyhow!("control closed"))?;
        Ok(())
    }

    /// Stops the kernel with its whole process group and waits, up to 5 s,
    /// for the task that owns its process to see it exit (that task removes
    /// its dir and unregisters it from the guard; both are done here too,
    /// for a kernel that did not exit in time).
    pub async fn kill(&self) -> Result<()> {
        self.iopub_handle.abort();
        self.process.kill_group();
        let mut exited = self.process.exited.clone();
        let wait = async move { exited.wait_for(|e| *e).await.is_ok() };
        if tokio::time::timeout(Duration::from_secs(5), wait).await.is_err() {
            tracing::warn!(pgid = self.process.pgid, "kernel: still running 5 s after SIGKILL");
        }
        self.process.dir.remove();
        crate::guard::unregister(self.process.pgid);
        Ok(())
    }
}

impl Drop for Kernel {
    /// Whatever path drops a kernel, its group is stopped and its dir and
    /// registration go (each step happens once, so after kill() this does
    /// nothing).
    fn drop(&mut self) {
        self.iopub_handle.abort();
        self.process.kill_group();
        self.process.dir.remove();
        crate::guard::unregister(self.process.pgid);
    }
}

fn five(v: Vec<u16>) -> Result<[u16; 5]> {
    v.try_into().map_err(|v: Vec<u16>| anyhow!("expected 5 ports, got {}", v.len()))
}

/// Owns a running kernel's process until it exits, for any reason. Then
/// whatever else runs in its group is stopped while the process is not
/// reaped yet (Leader), the process is reaped, its dir is removed and its
/// group unregistered from the guard (so the guard never signals a group id
/// that may be reused), and only then is the exit reported.
async fn watch_exit(
    mut child: Leader,
    pgid: i32,
    dir: Arc<KernelDir>,
    killed: Arc<AtomicBool>,
    tx_exit: watch::Sender<bool>,
) {
    child.exit().await;
    #[cfg(test)]
    tests::note_kill(pgid);
    kill_group_once(pgid, &killed);
    let st = child.child.wait().await;
    tracing::info!(?st, pgid, "kernel process exited");
    dir.remove();
    crate::guard::unregister(pgid);
    tx_exit.send_replace(true);
}

/// Steps 7 to 9 of a start, each ended early by the kernel's exit and
/// bounded by `deadline`: the kernel's ports, the connected shell, control
/// and iopub sockets, and for reserved ports a signed kernel_info_reply.
#[allow(clippy::too_many_arguments)]
async fn bring_up(
    child: &mut Leader,
    name: &str,
    kdir: &KernelDir,
    conn: ConnectionInfo,
    mode: PortMode,
    t_spawn: Instant,
    deadline: tokio::time::Instant,
    session: &str,
) -> Result<(ConnectionInfo, DealerSocket, DealerSocket, SubSocket), Stop> {
    match mode {
        PortMode::KernelBinds => {
            // 7. The kernel wrote back the ports it bound.
            let conn = loop {
                #[cfg(test)]
                tests::WRITE_BACK_READS.with(|r| r.borrow_mut().push(t_spawn.elapsed()));
                match kdir.read_written_back(&conn) {
                    Ok(Some(c)) => {
                        tracing::info!("kernel ports: written back by the kernel in {} ms", t_spawn.elapsed().as_millis());
                        break c;
                    }
                    Ok(None) => {}
                    Err(e) => return Err(Stop::Failed(e)),
                }
                pause(child, deadline, POLL, name, WRITE_PORTS).await?;
            };
            // 8. Its own ports, bound before they were written: a failed
            // connect is a failed start.
            let (shell, control, iopub) = connect_all(child, deadline, &conn, name).await?;
            Ok((conn, shell, control, iopub))
        }
        PortMode::Reserved => {
            // 7 and 8. The ports were reserved, but another process can
            // still hold one: then a connect finds that process (it fails,
            // or never completes) while the kernel, which cannot bind the
            // port, exits with an address in use, and that exit ends the
            // start (a new attempt gets new ports). So until the kernel's
            // sockets answer, its exit or the deadline, the ports are
            // probed and connected again.
            let mut misses = 0u32;
            let (shell, control, iopub) = loop {
                wait_open(child, deadline, t_spawn, &conn, name).await?;
                match connect_all(child, deadline, &conn, name).await {
                    Ok(sockets) => break sockets,
                    Err(Stop::Failed(e)) => {
                        if misses == 0 {
                            tracing::info!("kernel start: {e:#}; trying again while the kernel runs");
                        }
                        misses += 1;
                        pause(child, deadline, poll_step(t_spawn.elapsed()), name, "open its ports").await?;
                    }
                    Err(stop) => return Err(stop),
                }
            };
            if misses > 0 {
                tracing::info!("kernel start: the sockets connected after {misses} failed tries");
            }
            // 9. The kernel counts as started only once it answers, signed
            // with this file's key: the ports are its own.
            let mut shell = shell;
            kernel_info_handshake(child, deadline, &mut shell, &conn, session, name).await?;
            Ok((conn, shell, control, iopub))
        }
    }
}

fn late(name: &str, what: &str) -> Stop {
    // A kernel taken for ipykernel that never writes its ports back is
    // most likely another kernel: name the setting that gives it reserved
    // ports.
    let hint = if what == WRITE_PORTS {
        "; if it is not ipykernel, add \"jupynvim\": {\"ports\": \"reserved\"} to the metadata of its kernel.json"
    } else {
        ""
    };
    Stop::Failed(anyhow!("kernel '{name}' did not {what} within {} s{hint}", START_TIMEOUT.as_secs()))
}

/// Waits `d`, ended early by the kernel's exit or the deadline (`what` the
/// kernel did not do by then).
async fn pause(
    child: &mut Leader,
    deadline: tokio::time::Instant,
    d: Duration,
    name: &str,
    what: &str,
) -> Result<(), Stop> {
    #[cfg(test)]
    if what == WRITE_PORTS {
        tests::WRITE_BACK_PAUSE_MAX.with(|m| m.set(m.get().max(d)));
    }
    match during(child, deadline, tokio::time::sleep(d)).await {
        During::Done(()) => Ok(()),
        During::Exited => Err(Stop::Exited),
        During::Late => Err(late(name, what)),
    }
}

/// Until something accepts a connection on the shell, iopub and control
/// ports (a refused connect returns at once on loopback, so the sockets'
/// connects never meet zeromq's backoff). Probed as often as poll_step says
/// for the time since the spawn (`t_spawn`).
async fn wait_open(
    child: &mut Leader,
    deadline: tokio::time::Instant,
    t_spawn: Instant,
    conn: &ConnectionInfo,
    name: &str,
) -> Result<(), Stop> {
    let ports = [conn.shell_port, conn.iopub_port, conn.control_port];
    let mut open = [false; 3];
    loop {
        #[cfg(test)]
        tests::PROBE_ROUNDS.with(|n| n.set(n.get() + 1));
        let probe = async {
            for (i, p) in ports.iter().enumerate() {
                if !open[i] {
                    let c = tokio::net::TcpStream::connect((conn.ip.as_str(), *p));
                    open[i] = matches!(tokio::time::timeout(PROBE_TIMEOUT, c).await, Ok(Ok(_)));
                }
            }
            open.iter().all(|o| *o)
        };
        match during(child, deadline, probe).await {
            During::Done(true) => return Ok(()),
            During::Done(false) => {}
            During::Exited => return Err(Stop::Exited),
            During::Late => return Err(late(name, "open its ports")),
        }
        pause(child, deadline, poll_step(t_spawn.elapsed()), name, "open its ports").await?;
    }
}

/// New shell, control and iopub sockets connected to the kernel's ports
/// (iopub subscribes to everything before it connects).
async fn connect_all(
    child: &mut Leader,
    deadline: tokio::time::Instant,
    conn: &ConnectionInfo,
    name: &str,
) -> Result<(DealerSocket, DealerSocket, SubSocket), Stop> {
    let mut shell = DealerSocket::new();
    let mut control = DealerSocket::new();
    let mut iopub = SubSocket::new();
    iopub.subscribe("").await.map_err(|e| Stop::Failed(anyhow!("iopub subscribe: {e}")))?;
    connect_one(child, deadline, &mut shell, &conn.endpoint(conn.shell_port), name, "shell").await?;
    connect_one(child, deadline, &mut control, &conn.endpoint(conn.control_port), name, "control").await?;
    connect_one(child, deadline, &mut iopub, &conn.endpoint(conn.iopub_port), name, "iopub").await?;
    Ok((shell, control, iopub))
}

/// Sends a kernel_info_request on shell and waits for its reply, signed with
/// the connection's key; anything else on shell is skipped.
async fn kernel_info_handshake(
    child: &mut Leader,
    deadline: tokio::time::Instant,
    shell: &mut DealerSocket,
    conn: &ConnectionInfo,
    session: &str,
    name: &str,
) -> Result<(), Stop> {
    let what = "answer kernel_info";
    let key = conn.key.as_bytes();
    let request = Message::new("kernel_info_request", session.to_string(), protocol::kernel_info_request());
    let id = request.header.msg_id.clone();
    let frames = request.to_frames(key).map_err(Stop::Failed)?;
    match during(child, deadline, shell.send(frames_to_zmq(frames))).await {
        During::Done(Ok(())) => {}
        During::Done(Err(e)) => return Err(Stop::Failed(anyhow!("kernel '{name}': kernel_info_request: {e}"))),
        During::Exited => return Err(Stop::Exited),
        During::Late => return Err(late(name, what)),
    }
    loop {
        match during(child, deadline, shell.recv()).await {
            During::Done(Ok(z)) => match Message::from_frames(zmq_to_frames(z), key) {
                Ok(m) if m.header.msg_type == "kernel_info_reply"
                    && m.parent_header.get("msg_id").and_then(Value::as_str) == Some(id.as_str()) =>
                {
                    return Ok(())
                }
                Ok(m) => tracing::info!("kernel start: {} on shell before the kernel_info_reply; skipped", m.header.msg_type),
                Err(e) if e.to_string().starts_with("HMAC") => {
                    tracing::warn!("kernel start: a message on shell failed its signature check; skipped")
                }
                Err(e) => tracing::warn!("kernel start: a message on shell was skipped: {e}"),
            },
            During::Done(Err(e)) => {
                tracing::warn!("kernel start: shell recv: {e}");
                pause(child, deadline, Duration::from_millis(50), name, what).await?;
            }
            During::Exited => return Err(Stop::Exited),
            During::Late => return Err(late(name, what)),
        }
    }
}

/// Connects one socket to the kernel, ended early by the kernel's exit and
/// bounded by CONNECT_TIMEOUT (zeromq's connect never gives up by itself).
async fn connect_one<S: Socket>(
    child: &mut Leader,
    deadline: tokio::time::Instant,
    sock: &mut S,
    endpoint: &str,
    name: &str,
    label: &str,
) -> Result<(), Stop> {
    let until = deadline.min(tokio::time::Instant::now() + CONNECT_TIMEOUT);
    match during(child, until, sock.connect(endpoint)).await {
        During::Done(Ok(())) => Ok(()),
        During::Done(Err(e)) => Err(Stop::Failed(anyhow!("kernel '{name}': connecting its {label} socket to {endpoint}: {e}"))),
        During::Exited => Err(Stop::Exited),
        During::Late => Err(Stop::Failed(anyhow!(
            "kernel '{name}': its {label} socket at {endpoint} did not connect within {} s",
            CONNECT_TIMEOUT.as_secs()
        ))),
    }
}

/// Ends a start that failed after the spawn: the kernel's group is stopped,
/// unregistered and its dir removed; then the error, with the end of the
/// kernel's stderr, classified as an address in use or not.
async fn abort(
    mut child: Leader,
    pgid: i32,
    kdir: &KernelDir,
    stderr_task: Option<JoinHandle<()>>,
    tail: &StartTail,
    name: &str,
    stop: Stop,
) -> LaunchError {
    // the group first, then the process is reaped (Leader)
    #[cfg(test)]
    tests::note_kill(pgid);
    kill_group_once(pgid, &AtomicBool::new(false));
    let st = tokio::time::timeout(Duration::from_secs(2), child.child.wait()).await;
    crate::guard::unregister(pgid);
    kdir.remove();
    // the rest of its stderr: every process that wrote it is gone now
    if let Some(t) = stderr_task {
        let _ = tokio::time::timeout(Duration::from_secs(1), t).await;
    }
    let tail = tail.lock().take().unwrap_or_default();
    let out = last_lines(&tail, 20);
    let err = match stop {
        Stop::Exited => {
            let st = match st {
                Ok(Ok(s)) => s.to_string(),
                Ok(Err(e)) => format!("status unknown: {e}"),
                Err(_) => "status unknown: not reaped within 2 s".to_string(),
            };
            anyhow!("kernel '{name}' exited during start ({st}): {}", if out.is_empty() { "nothing on stderr" } else { out })
        }
        Stop::Failed(e) if out.is_empty() => e,
        Stop::Failed(e) => anyhow!("{e:#}; its stderr ended with:\n{out}"),
    };
    classify(&tail, err)
}

/// Owns a DEALER socket. Drains an outgoing channel and recv()s replies.
/// Replies are parsed and forwarded as ExecuteReply (or other shell-side msg).
async fn socket_owner(
    mut sock: DealerSocket,
    mut out_rx: mpsc::UnboundedReceiver<ZmqMessage>,
    key: Vec<u8>,
    tx: mpsc::UnboundedSender<KernelEvent>,
    label: &'static str,
    pending: Option<Arc<DashMap<String, oneshot::Sender<Value>>>>,
) {
    loop {
        tokio::select! {
            biased; // prefer sends so outgoing isn't starved by recv
            out = out_rx.recv() => {
                match out {
                    Some(zmsg) => {
                        if let Err(e) = sock.send(zmsg).await {
                            tracing::warn!("{label} send: {e}");
                        }
                    }
                    None => {
                        tracing::info!("{label} outgoing channel closed; owner exit");
                        return;
                    }
                }
            }
            recv = sock.recv() => {
                match recv {
                    Ok(zmsg) => {
                        let frames = zmq_to_frames(zmsg);
                        match Message::from_frames(frames, &key) {
                            Ok(reply) => {
                                let parent = reply
                                    .parent_header
                                    .get("msg_id")
                                    .and_then(|v| v.as_str())
                                    .map(|s| s.to_string());
                                // If a caller is awaiting this msg_id (complete_request,
                                // inspect_request, etc.), deliver the content directly
                                // via the oneshot and skip the events-channel path.
                                if let (Some(map), Some(pid)) = (pending.as_ref(), parent.as_ref()) {
                                    if let Some((_, sender)) = map.remove(pid) {
                                        let _ = sender.send(reply.content);
                                        continue;
                                    }
                                }
                                let status = reply
                                    .content
                                    .get("status")
                                    .and_then(|v| v.as_str())
                                    .unwrap_or("unknown")
                                    .to_string();
                                let exec_count = reply
                                    .content
                                    .get("execution_count")
                                    .and_then(|v| v.as_u64())
                                    .unwrap_or(0);
                                if reply.header.msg_type == "kernel_info_reply" {
                                    let _ = tx.send(KernelEvent::KernelInfo {
                                        parent_msg_id: parent,
                                        info: reply.content,
                                    });
                                } else {
                                    let _ = tx.send(KernelEvent::ExecuteReply {
                                        parent_msg_id: parent,
                                        status,
                                        execution_count: exec_count,
                                    });
                                }
                            }
                            Err(e) => tracing::warn!("{label} reply parse: {e}"),
                        }
                    }
                    Err(e) => {
                        tracing::warn!("{label} recv error: {e}");
                        tokio::time::sleep(Duration::from_millis(50)).await;
                    }
                }
            }
        }
    }
}

/// Read lines from a kernel-process pipe (stdout or stderr) and emit each as
/// a synthetic Stream event attributed to the most recent execute_request.
/// Necessary because IPython's `!cmd` shell magic writes to the kernel's
/// real fd 1 (via subprocess inherit), not through sys.stdout's iopub
/// redirection, so this output never reaches the iopub_loop. With `tail`,
/// the end of what was read is kept there too (push_tail) until the start
/// is over (the tail is None from then on, and this lets go of it).
async fn drain_pipe<R>(
    pipe: R,
    stream_name: String,
    active: Arc<parking_lot::Mutex<Option<String>>>,
    tx: mpsc::UnboundedSender<KernelEvent>,
    mut tail: Option<StartTail>,
)
where
    R: tokio::io::AsyncRead + Unpin + Send + 'static,
{
    use tokio::io::{AsyncBufReadExt, BufReader};
    let mut reader = BufReader::new(pipe);
    let mut buf = Vec::with_capacity(1024);
    tracing::info!("drain_pipe({}) started", stream_name);
    loop {
        buf.clear();
        match reader.read_until(b'\n', &mut buf).await {
            Ok(0) => {
                tracing::info!("drain_pipe({}) EOF", stream_name);
                break;
            }
            Ok(_) => {
                let text = String::from_utf8_lossy(&buf).to_string();
                let started = tail.as_ref().is_some_and(|t| match t.lock().as_mut() {
                    Some(kept) => {
                        push_tail(kept, &text);
                        false
                    }
                    None => true,
                });
                if started {
                    tail = None;
                }
                let parent = active.lock().clone();
                tracing::info!("drain_pipe({}) got {} bytes, parent={:?}", stream_name, buf.len(), parent);
                if tx.send(KernelEvent::Stream {
                    msg_id: Uuid::new_v4().to_string(),
                    parent_msg_id: parent,
                    name: stream_name.clone(),
                    text,
                }).is_err() {
                    return;
                }
            }
            Err(e) => {
                tracing::warn!("drain_pipe({}) read error: {e}", stream_name);
                return;
            }
        }
    }
}

async fn iopub_loop(mut sock: SubSocket, key: Vec<u8>, tx: mpsc::UnboundedSender<KernelEvent>) {
    loop {
        match sock.recv().await {
            Ok(zmsg) => {
                let frames = zmq_to_frames(zmsg);
                match Message::from_frames(frames, &key) {
                    Ok(msg) => {
                        let parent = msg
                            .parent_header
                            .get("msg_id")
                            .and_then(|v| v.as_str())
                            .unwrap_or("")
                            .to_string();
                        tracing::info!(
                            "iopub recv type={} parent={}",
                            msg.header.msg_type,
                            parent
                        );
                        if let Some(ev) = iopub_to_event(&msg) {
                            if tx.send(ev).is_err() {
                                tracing::info!("iopub event channel closed; iopub loop exit");
                                return;
                            }
                        } else {
                            tracing::info!("iopub: no event mapping for type {}", msg.header.msg_type);
                        }
                    }
                    Err(e) => tracing::warn!("iopub parse: {e}"),
                }
            }
            Err(e) => {
                tracing::warn!("iopub recv: {e}");
                tokio::time::sleep(Duration::from_millis(50)).await;
            }
        }
    }
}

fn iopub_to_event(msg: &Message) -> Option<KernelEvent> {
    let parent = msg
        .parent_header
        .get("msg_id")
        .and_then(|v| v.as_str())
        .map(|s| s.to_string());
    let msg_id = msg.header.msg_id.clone();
    let c = &msg.content;
    match msg.header.msg_type.as_str() {
        "stream" => Some(KernelEvent::Stream {
            msg_id,
            parent_msg_id: parent,
            name: c.get("name").and_then(|v| v.as_str()).unwrap_or("stdout").to_string(),
            text: c.get("text").and_then(|v| v.as_str()).unwrap_or("").to_string(),
        }),
        "display_data" => Some(KernelEvent::DisplayData {
            msg_id,
            parent_msg_id: parent,
            data: c.get("data").cloned().unwrap_or(json!({})),
            metadata: c.get("metadata").cloned().unwrap_or(json!({})),
            transient: c.get("transient").cloned().unwrap_or(json!({})),
        }),
        "update_display_data" => Some(KernelEvent::UpdateDisplayData {
            msg_id,
            parent_msg_id: parent,
            data: c.get("data").cloned().unwrap_or(json!({})),
            metadata: c.get("metadata").cloned().unwrap_or(json!({})),
            transient: c.get("transient").cloned().unwrap_or(json!({})),
        }),
        "execute_result" => Some(KernelEvent::ExecuteResult {
            msg_id,
            parent_msg_id: parent,
            execution_count: c.get("execution_count").and_then(|v| v.as_u64()).unwrap_or(0),
            data: c.get("data").cloned().unwrap_or(json!({})),
            metadata: c.get("metadata").cloned().unwrap_or(json!({})),
        }),
        "error" => Some(KernelEvent::Error {
            msg_id,
            parent_msg_id: parent,
            ename: c.get("ename").and_then(|v| v.as_str()).unwrap_or("").to_string(),
            evalue: c.get("evalue").and_then(|v| v.as_str()).unwrap_or("").to_string(),
            traceback: c
                .get("traceback")
                .and_then(|v| v.as_array())
                .map(|a| {
                    a.iter()
                        .filter_map(|t| t.as_str().map(|s| s.to_string()))
                        .collect()
                })
                .unwrap_or_default(),
        }),
        "status" => Some(KernelEvent::Status {
            execution_state: c
                .get("execution_state")
                .and_then(|v| v.as_str())
                .unwrap_or("idle")
                .to_string(),
            parent_msg_id: parent,
        }),
        "execute_input" => Some(KernelEvent::ExecuteInput {
            parent_msg_id: parent,
            execution_count: c.get("execution_count").and_then(|v| v.as_u64()).unwrap_or(0),
            code: c.get("code").and_then(|v| v.as_str()).unwrap_or("").to_string(),
        }),
        "clear_output" => Some(KernelEvent::ClearOutput {
            parent_msg_id: parent,
            wait: c.get("wait").and_then(|v| v.as_bool()).unwrap_or(false),
        }),
        "comm_open" => Some(KernelEvent::CommOpen {
            msg_id,
            parent_msg_id: parent,
            comm_id: c.get("comm_id").and_then(|v| v.as_str()).unwrap_or("").to_string(),
            target_name: c.get("target_name").and_then(|v| v.as_str()).unwrap_or("").to_string(),
            data: c.get("data").cloned().unwrap_or(json!({})),
            metadata: msg.metadata.clone(),
            buffers: msg.buffers.clone(),
        }),
        "comm_msg" => Some(KernelEvent::CommMsg {
            msg_id,
            parent_msg_id: parent,
            comm_id: c.get("comm_id").and_then(|v| v.as_str()).unwrap_or("").to_string(),
            data: c.get("data").cloned().unwrap_or(json!({})),
            buffers: msg.buffers.clone(),
        }),
        "comm_close" => Some(KernelEvent::CommClose {
            parent_msg_id: parent,
            comm_id: c.get("comm_id").and_then(|v| v.as_str()).unwrap_or("").to_string(),
            data: c.get("data").cloned().unwrap_or(json!({})),
        }),
        _ => None,
    }
}

/// An outgoing comm message with our own msg_id, metadata and binary buffers.
/// `Message::to_frames` turns it into the signed wire format.
fn comm_message(
    session: &str,
    msg_type: &str,
    content: Value,
    metadata: Value,
    buffers: Vec<Bytes>,
    msg_id: String,
) -> Message {
    let mut msg = Message::new(msg_type, session, content);
    msg.header.msg_id = msg_id;
    msg.metadata = metadata;
    msg.buffers = buffers;
    msg
}

/// Synchronous sender for widget comm traffic. It owns a clone of the kernel's
/// shell channel sender and the signing key, so a caller sends without an
/// await and without holding the kernel.
#[derive(Clone)]
pub struct CommSender {
    shell_tx: mpsc::UnboundedSender<ZmqMessage>,
    key: Vec<u8>,
    session: String,
}

impl CommSender {
    pub(crate) fn new(
        shell_tx: mpsc::UnboundedSender<ZmqMessage>,
        key: Vec<u8>,
        session: String,
    ) -> Self {
        Self { shell_tx, key, session }
    }

    /// Build, sign and push one comm message under `msg_id`. Binary buffers
    /// follow the content frame.
    pub fn send(
        &self,
        msg_type: &str,
        content: Value,
        metadata: Value,
        buffers: Vec<Bytes>,
        msg_id: String,
    ) -> Result<()> {
        let msg = comm_message(&self.session, msg_type, content, metadata, buffers, msg_id);
        let frames = msg.to_frames(&self.key)?;
        self.shell_tx
            .send(frames_to_zmq(frames))
            .map_err(|_| anyhow!("shell channel closed"))
    }
}

fn frames_to_zmq(frames: Vec<Bytes>) -> ZmqMessage {
    let mut iter = frames.into_iter();
    let first = iter.next().unwrap_or_default();
    let mut zmsg = ZmqMessage::from(first);
    for f in iter {
        zmsg.push_back(f);
    }
    zmsg
}

fn zmq_to_frames(zmsg: ZmqMessage) -> Vec<Bytes> {
    zmsg.into_vec()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::{BTreeSet, HashMap};
    use std::io::ErrorKind;
    use std::net::{Ipv4Addr, SocketAddr};
    use std::time::Instant;

    const KEY: &[u8] = b"0123456789abcdef";

    /// The kernel's iopub frames for `msg`: a topic frame, then the signed
    /// wire format. Parsing them back covers framing, HMAC and buffer frames.
    fn on_iopub(msg: &Message) -> Message {
        let mut frames = vec![Bytes::from_static(b"comm")];
        frames.extend(msg.to_frames(KEY).unwrap());
        Message::from_frames(frames, KEY).unwrap()
    }

    /// A kernel message sent as the reply to execute_request "exec-1".
    fn from_execute(msg_type: &str, content: Value) -> Message {
        let mut msg = Message::new(msg_type, "kernel-session", content);
        msg.parent_header = json!({ "msg_id": "exec-1", "msg_type": "execute_request" });
        msg
    }

    #[test]
    fn comm_open_becomes_an_event_with_its_buffers() {
        let mut msg = from_execute(
            "comm_open",
            json!({
                "comm_id": "c1",
                "target_name": "jupyter.widget",
                "data": {
                    "state": { "_model_name": "ImageModel" },
                    "buffer_paths": [["value"]],
                },
            }),
        );
        msg.metadata = json!({ "version": "2.1.0" });
        msg.buffers = vec![Bytes::from_static(b"\x89PNG")];

        let parsed = on_iopub(&msg);
        match iopub_to_event(&parsed) {
            Some(KernelEvent::CommOpen {
                msg_id,
                parent_msg_id,
                comm_id,
                target_name,
                data,
                metadata,
                buffers,
            }) => {
                assert_eq!(msg_id, parsed.header.msg_id);
                assert_eq!(parent_msg_id.as_deref(), Some("exec-1"));
                assert_eq!(comm_id, "c1");
                assert_eq!(target_name, "jupyter.widget");
                assert_eq!(data["buffer_paths"], json!([["value"]]));
                assert_eq!(data["state"]["_model_name"], "ImageModel");
                assert_eq!(metadata["version"], "2.1.0");
                assert_eq!(buffers.len(), 1);
                assert_eq!(&buffers[0][..], b"\x89PNG");
            }
            other => panic!("expected CommOpen, got {other:?}"),
        }
    }

    #[test]
    fn comm_msg_becomes_an_event() {
        let msg = from_execute(
            "comm_msg",
            json!({
                "comm_id": "c1",
                "data": { "method": "update", "state": { "value": 3 } },
            }),
        );

        let parsed = on_iopub(&msg);
        match iopub_to_event(&parsed) {
            Some(KernelEvent::CommMsg {
                msg_id,
                parent_msg_id,
                comm_id,
                data,
                buffers,
            }) => {
                assert_eq!(msg_id, parsed.header.msg_id);
                assert_eq!(parent_msg_id.as_deref(), Some("exec-1"));
                assert_eq!(comm_id, "c1");
                assert_eq!(data, json!({ "method": "update", "state": { "value": 3 } }));
                assert!(buffers.is_empty());
            }
            other => panic!("expected CommMsg, got {other:?}"),
        }
    }

    #[test]
    fn comm_msg_with_a_buffer_becomes_an_event() {
        // A binary value travels as a buffer next to its buffer_paths entry.
        // The event must carry the path and the same bytes.
        let mut msg = from_execute(
            "comm_msg",
            json!({
                "comm_id": "c1",
                "data": { "method": "update", "state": {}, "buffer_paths": [["value"]] },
            }),
        );
        msg.buffers = vec![Bytes::from_static(b"\x89PNG-two")];

        let parsed = on_iopub(&msg);
        match iopub_to_event(&parsed) {
            Some(KernelEvent::CommMsg {
                comm_id,
                data,
                buffers,
                ..
            }) => {
                assert_eq!(comm_id, "c1");
                assert_eq!(data["buffer_paths"], json!([["value"]]));
                assert_eq!(buffers.len(), 1);
                assert_eq!(&buffers[0][..], b"\x89PNG-two");
            }
            other => panic!("expected CommMsg, got {other:?}"),
        }
    }

    #[test]
    fn comm_close_becomes_an_event() {
        let msg = from_execute(
            "comm_close",
            json!({ "comm_id": "c1", "data": { "reason": "x" } }),
        );

        let parsed = on_iopub(&msg);
        match iopub_to_event(&parsed) {
            Some(KernelEvent::CommClose {
                parent_msg_id,
                comm_id,
                data,
            }) => {
                assert_eq!(parent_msg_id.as_deref(), Some("exec-1"));
                assert_eq!(comm_id, "c1");
                assert_eq!(data, json!({ "reason": "x" }));
            }
            other => panic!("expected CommClose, got {other:?}"),
        }
    }

    #[test]
    fn comm_open_without_a_parent_has_no_parent_msg_id() {
        // A kernel can open a comm outside any execute request (for example
        // while it starts); the parent header is then the empty object.
        let msg = Message::new(
            "comm_open",
            "kernel-session",
            json!({ "comm_id": "c2", "target_name": "jupyter.widget", "data": {} }),
        );

        match iopub_to_event(&on_iopub(&msg)) {
            Some(KernelEvent::CommOpen { parent_msg_id, comm_id, .. }) => {
                assert_eq!(parent_msg_id, None);
                assert_eq!(comm_id, "c2");
            }
            other => panic!("expected CommOpen, got {other:?}"),
        }
    }

    #[test]
    fn is_comm_is_true_only_for_widget_comm_events() {
        let open = KernelEvent::CommOpen {
            msg_id: "m".into(),
            parent_msg_id: None,
            comm_id: "c".into(),
            target_name: "jupyter.widget".into(),
            data: json!({}),
            metadata: json!({}),
            buffers: Vec::new(),
        };
        let msg = KernelEvent::CommMsg {
            msg_id: "m".into(),
            parent_msg_id: None,
            comm_id: "c".into(),
            data: json!({}),
            buffers: Vec::new(),
        };
        let close = KernelEvent::CommClose {
            parent_msg_id: None,
            comm_id: "c".into(),
            data: json!({}),
        };
        let status = KernelEvent::Status {
            execution_state: "idle".into(),
            parent_msg_id: None,
        };
        assert!(open.is_comm());
        assert!(msg.is_comm());
        assert!(close.is_comm());
        assert!(!status.is_comm());
    }

    #[test]
    fn outgoing_comm_frames_carry_the_msg_id_metadata_and_buffers() {
        let msg = comm_message(
            "kernel-session",
            "comm_msg",
            json!({ "comm_id": "c1", "data": { "method": "custom", "content": { "event": "click" } } }),
            json!({ "version": "2.1.0" }),
            vec![Bytes::from_static(b"\x00\x01\x02")],
            "ui-1".to_string(),
        );
        let mut wire = vec![Bytes::from_static(b"routing-id")];
        wire.extend(msg.to_frames(KEY).unwrap());

        let got = Message::from_frames(wire.clone(), KEY).unwrap();
        assert_eq!(got.header.msg_type, "comm_msg");
        assert_eq!(got.header.msg_id, "ui-1");
        assert_eq!(got.metadata, json!({ "version": "2.1.0" }));
        assert_eq!(got.content["comm_id"], "c1");
        assert_eq!(got.content["data"]["method"], "custom");
        assert_eq!(got.buffers.len(), 1);
        assert_eq!(&got.buffers[0][..], b"\x00\x01\x02");

        // The signature covers the header, parent, metadata and content.
        assert!(Message::from_frames(wire, b"another-key-0000").is_err());
    }

    #[test]
    fn comm_sender_pushes_signed_frames() {
        let (tx, mut rx) = mpsc::unbounded_channel::<ZmqMessage>();
        let sender = CommSender::new(tx, KEY.to_vec(), "kernel-session".to_string());
        sender
            .send(
                "comm_msg",
                json!({
                    "comm_id": "c1",
                    "data": { "method": "update", "state": { "value": 3 } },
                }),
                json!({ "version": "2.1.0" }),
                vec![Bytes::from_static(b"BUF")],
                "ui-2".to_string(),
            )
            .unwrap();

        let frames = zmq_to_frames(rx.try_recv().expect("one message was pushed"));
        let got = Message::from_frames(frames.clone(), KEY).unwrap();
        assert_eq!(got.header.msg_type, "comm_msg");
        assert_eq!(got.header.msg_id, "ui-2");
        assert_eq!(got.metadata, json!({ "version": "2.1.0" }));
        assert_eq!(got.content["data"]["state"]["value"], 3);
        assert_eq!(got.buffers.len(), 1);
        assert_eq!(&got.buffers[0][..], b"BUF");
        assert!(Message::from_frames(frames, b"another-key-0000").is_err());

        // A closed shell channel is an error for the caller, never a panic.
        drop(rx);
        let err = sender
            .send(
                "comm_close",
                json!({ "comm_id": "c1", "data": {} }),
                json!({}),
                Vec::new(),
                "ui-3".into(),
            )
            .unwrap_err();
        assert_eq!(err.to_string(), "shell channel closed");
    }

    fn test_spec(argv: &[&str], metadata: Value) -> KernelSpec {
        KernelSpec {
            name: "k".into(),
            path: PathBuf::from("/x"),
            argv: argv.iter().map(|s| s.to_string()).collect(),
            display_name: "k".into(),
            language: "python".into(),
            interrupt_mode: None,
            env: HashMap::new(),
            metadata,
        }
    }

    #[test]
    fn k1_port_mode_for_spec() {
        use PortMode::*;
        let cf = "{connection_file}";
        let py = ["/py", "-Xfrozen_modules=off", "-m", "ipykernel_launcher", "-f", cf];
        let julia = ["julia", "-i", "--color=yes", "/x/IJulia/src/kernel.jl", cf];
        let cases: Vec<(&str, Vec<&str>, Value, PortMode)> = vec![
            ("the python3 kernelspec", py.to_vec(), Value::Null, KernelBinds),
            ("python -m ipykernel", vec!["/py", "-m", "ipykernel", "-f", cf], Value::Null, KernelBinds),
            ("python -m ipykernel_launcher", vec!["/py", "-m", "ipykernel_launcher", "-f", cf], Value::Null, KernelBinds),
            ("the launcher script by path", vec!["/py", "/site/ipykernel_launcher.py", "-f", cf], Value::Null, KernelBinds),
            ("the launcher script by name", vec!["/py", "ipykernel_launcher.py", "-f", cf], Value::Null, KernelBinds),
            (
                "a shell wrapper that stays the parent (jnv-wrap)",
                vec!["/bin/sh", "-c", "\"$0\" -m ipykernel_launcher -f \"$1\"; exit $?", "/py", cf],
                Value::Null,
                KernelBinds,
            ),
            (
                "a shell wrapper that execs (jnv-slow)",
                vec!["/bin/sh", "-c", "sleep 1; exec \"$0\" -m ipykernel_launcher -f \"$1\"", "/py", cf],
                Value::Null,
                KernelBinds,
            ),
            ("IJulia", julia.to_vec(), Value::Null, Reserved),
            ("IRkernel", vec!["R", "--slave", "-e", "IRkernel::main()", "--args", cf], Value::Null, Reserved),
            ("xeus-python", vec!["xpython", "-f", cf], Value::Null, Reserved),
            ("ports reserved overrides ipykernel", py.to_vec(), json!({"jupynvim": {"ports": "reserved"}}), Reserved),
            ("ports kernel overrides IJulia", julia.to_vec(), json!({"jupynvim": {"ports": "kernel"}}), KernelBinds),
            (
                "ports reserved overrides ensure_ipykernel",
                vec!["/env/bin/python", "-m", "mykernel"],
                json!({"jupynvim": {"ports": "reserved", "ensure_ipykernel": true}}),
                Reserved,
            ),
            ("an unknown ports value is ignored", julia.to_vec(), json!({"jupynvim": {"ports": "auto"}}), Reserved),
            (
                "ensure_ipykernel",
                vec!["/env/bin/python", "-m", "mykernel"],
                json!({"jupynvim": {"ensure_ipykernel": true}}),
                KernelBinds,
            ),
            ("ensure_ipykernel false", julia.to_vec(), json!({"jupynvim": {"ensure_ipykernel": false}}), Reserved),
        ];
        let wrong: Vec<String> = cases
            .iter()
            .filter_map(|(what, argv, meta, want)| {
                let got = PortMode::for_spec(&test_spec(argv, meta.clone()));
                (got != *want).then(|| format!("{what}: {got:?}, want {want:?}"))
            })
            .collect();
        assert!(wrong.is_empty(), "{}", wrong.join("\n"));
    }

    fn plain_bind(port: u16) -> std::io::Result<socket2::Socket> {
        // socket2 sets no SO_REUSEADDR: a bind as plain as it gets
        let s = socket2::Socket::new(socket2::Domain::IPV4, socket2::Type::STREAM, None)?;
        let addr: SocketAddr = (Ipv4Addr::LOCALHOST, port).into();
        s.bind(&addr.into())?;
        Ok(s)
    }

    /// Runs `kernel::tests::<child>` in a process of its own with `var` set:
    /// a socket or pipe made in this process could otherwise be inherited
    /// by a process another test starts at the same moment (Rust's std on
    /// macOS sets close-on-exec only after it made the fd).
    fn run_alone(child: &str, var: &str) {
        let exe = std::env::current_exe().unwrap();
        let out = std::process::Command::new(&exe)
            .args([&format!("kernel::tests::{child}"), "--exact", "--ignored", "--nocapture", "--test-threads=1"])
            .env(var, "1")
            .output()
            .unwrap();
        let text = format!("{}{}", String::from_utf8_lossy(&out.stdout), String::from_utf8_lossy(&out.stderr));
        assert!(out.status.success(), "{text}");
        assert!(text.contains(&format!("{child}: every check ran")), "{text}");
    }

    #[test]
    fn k2_reserved_ports_refuse_a_plain_bind_and_take_a_reuseaddr_one() {
        run_alone("k2_child", "JVTEST_K2");
    }

    #[test]
    #[ignore = "run by k2 in a process of its own"]
    fn k2_child() {
        if std::env::var_os("JVTEST_K2").is_none() {
            return;
        }
        let ports = reserve_ports(5).unwrap();
        assert_eq!(ports.len(), 5);
        assert_eq!(ports.iter().collect::<BTreeSet<_>>().len(), 5, "ports not distinct: {ports:?}");
        let mut wrong = Vec::new();
        for &p in &ports {
            match plain_bind(p) {
                Err(e) if e.kind() == ErrorKind::AddrInUse => {}
                Err(e) => wrong.push(format!("port {p}: a plain bind failed with {e}, not AddrInUse")),
                Ok(_) => wrong.push(format!("port {p} took a plain bind")),
            }
            // what libzmq, std and tokio listeners do (SO_REUSEADDR)
            if let Err(e) = std::net::TcpListener::bind((Ipv4Addr::LOCALHOST, p)) {
                wrong.push(format!("port {p} refused a listener with SO_REUSEADDR: {e}"));
            }
        }
        assert!(wrong.is_empty(), "{}", wrong.join("\n"));
        // The difference: a port picked and released at once takes a plain bind.
        let naive = std::net::TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).unwrap().local_addr().unwrap().port();
        assert!(plain_bind(naive).is_ok(), "a port picked and released at once refused a plain bind");
        println!("k2_child: every check ran");
    }

    #[test]
    fn k8_held_ports_refuse_every_bind_until_released() {
        run_alone("k8_child", "JVTEST_K8");
    }

    #[test]
    #[ignore = "run by k8 in a process of its own"]
    fn k8_child() {
        if std::env::var_os("JVTEST_K8").is_none() {
            return;
        }
        let (ports, held) = pick_held(5).unwrap();
        assert_eq!(ports.len(), 5);
        assert_eq!(ports.iter().collect::<BTreeSet<_>>().len(), 5, "ports not distinct: {ports:?}");
        let mut wrong = Vec::new();
        for &p in &ports {
            if !matches!(plain_bind(p), Err(e) if e.kind() == ErrorKind::AddrInUse) {
                wrong.push(format!("held port {p} did not refuse a plain bind"));
            }
            if !matches!(std::net::TcpListener::bind((Ipv4Addr::LOCALHOST, p)), Err(e) if e.kind() == ErrorKind::AddrInUse) {
                wrong.push(format!("held port {p} did not refuse a listener with SO_REUSEADDR"));
            }
        }
        drop(held);
        for &p in &ports {
            if let Err(e) = plain_bind(p) {
                wrong.push(format!("port {p} refused a plain bind once released: {e}"));
            }
        }
        assert!(wrong.is_empty(), "{}", wrong.join("\n"));
        println!("k8_child: every check ran");
    }

    #[test]
    fn k3_the_stderr_tail_keeps_the_last_8192_bytes_on_a_char_boundary() {
        let mut t = String::new();
        push_tail(&mut t, "x\n");
        assert_eq!(t, "x\n", "a short tail is kept whole");
        let mut t = String::new();
        push_tail(&mut t, &"a".repeat(5000));
        push_tail(&mut t, &"b".repeat(5000));
        assert_eq!(t.len(), TAIL_MAX);
        assert!(t.ends_with(&"b".repeat(5000)) && t.starts_with('a'));
        // 3-byte chars: 12000 bytes, and 8192 is not a char boundary from the end
        let mut t = String::new();
        push_tail(&mut t, &"\u{20ac}".repeat(4000));
        assert_eq!(t.len(), 8190);
        assert!(t.chars().all(|c| c == '\u{20ac}'));
        // one chunk far over the limit
        let mut t = "old".to_string();
        push_tail(&mut t, &"z".repeat(100_000));
        assert_eq!(t, "z".repeat(TAIL_MAX));
        // the last lines of a tail, for the error message
        let text: String = (1..=30).map(|i| format!("line {i}\n")).collect();
        let last = last_lines(&text, 20);
        assert!(last.starts_with("line 11\n") && last.ends_with("line 30"), "{last:?}");
        assert_eq!(last_lines("one\ntwo\n", 20), "one\ntwo");
    }

    #[test]
    fn k4_address_in_use_is_told_apart() {
        let zmq = "Traceback (most recent call last):\n  File \"kernelapp.py\", line 1\n\
                   zmq.error.ZMQError: Address already in use (addr='tcp://127.0.0.1:5555')\n";
        assert!(matches!(classify(zmq, anyhow!("e")), LaunchError::AddrInUse(_)), "ZMQError Address already in use");
        assert!(matches!(classify("bind failed: EADDRINUSE\n", anyhow!("e")), LaunchError::AddrInUse(_)), "EADDRINUSE");
        for other in ["ModuleNotFoundError: No module named 'ipykernel'\n", "", "Permission denied\n"] {
            assert!(matches!(classify(other, anyhow!("e")), LaunchError::Other(_)), "{other:?}");
        }
    }

    // K15: every other process the backend starts (a language server, a
    // command the frontend runs, a Python probe) is made with command(), and
    // keeps no fd above 2 across its exec either: one another thread made at
    // that moment without close-on-exec yet would keep the guard's pipe open
    #[test]
    fn k15_other_processes_keep_no_inherited_fd() {
        run_alone("k15_child", "JVTEST_K15");
    }

    #[test]
    #[ignore = "run by k15 in a process of its own: no other test may start a process while its pipe is open"]
    fn k15_child() {
        if std::env::var_os("JVTEST_K15").is_none() {
            return;
        }
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
        let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
        let (control_kept, free) = rt.block_on(async {
            // control: a process started with a plain Command keeps the fd
            let mut plain = Command::new("/bin/sleep").arg("5").stdin(Stdio::null()).spawn().unwrap();
            let mut other = command("/bin/sleep").arg("5").stdin(Stdio::null()).spawn().unwrap();
            // SAFETY: closes the write end this process holds, nothing else.
            unsafe { libc::close(w) };
            let control_kept = !eof_within(Duration::from_millis(300));
            let _ = plain.kill().await;
            // the control held the write end; now only the other one could
            let free = eof_within(Duration::from_millis(1000));
            let _ = other.kill().await;
            (control_kept, free)
        });
        // SAFETY: closes the read end this test made.
        unsafe { libc::close(r) };
        assert!(control_kept, "control: a process started plainly did not keep the fd, so this test proves nothing");
        assert!(free, "a process made with command() kept a write end it inherited");
        println!("k15_child: every check ran");
    }

    #[test]
    fn k5_a_kernel_leads_a_session_of_its_own_and_keeps_no_inherited_fd() {
        run_alone("k5_child", "JVTEST_K5");
    }

    #[test]
    #[ignore = "run by k5 in a process of its own: no other test may start a process while its pipe is open"]
    fn k5_child() {
        if std::env::var_os("JVTEST_K5").is_none() {
            return;
        }
        // A pipe whose ends lack close-on-exec, as Rust's std on macOS makes
        // one (pipe, then fcntl) on another thread while a kernel starts.
        let mut fds = [0 as libc::c_int; 2];
        // SAFETY: pipe writes two fds into the array it is given.
        assert_eq!(unsafe { libc::pipe(fds.as_mut_ptr()) }, 0);
        let (r, w) = (fds[0], fds[1]);
        let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
        let wrong = rt.block_on(async {
            use tokio::io::AsyncBufReadExt;
            let mut spec = test_spec(&[], Value::Null);
            // the backend's own value comes after the kernelspec's
            spec.env.insert("JPY_PARENT_PID".into(), "1".into());
            let argv: Vec<String> =
                ["/bin/sh", "-c", "echo \"$JPY_PARENT_PID\"; exec sleep 5"].map(String::from).to_vec();
            let mut child = kernel_command(&spec, &argv, None).spawn().unwrap();
            let pid = child.id().unwrap() as libc::pid_t;
            // SAFETY: closes the write end this process holds, nothing else.
            unsafe { libc::close(w) };
            // End of file as soon as no process holds the write end: at once,
            // unless the kernel inherited it.
            let mut pfd = libc::pollfd { fd: r, events: libc::POLLIN, revents: 0 };
            let t = Instant::now();
            // SAFETY: one pollfd, valid for the call.
            let ready = unsafe { libc::poll(&mut pfd, 1, 2000) };
            let took = t.elapsed();
            let mut line = String::new();
            let mut out = tokio::io::BufReader::new(child.stdout.take().unwrap());
            let _ = tokio::time::timeout(Duration::from_secs(2), out.read_line(&mut line)).await;
            // SAFETY: getsid and getpgid only read; killpg signals the child's group, or fails.
            let (sid, pgid) = unsafe { (libc::getsid(pid), libc::getpgid(pid)) };
            unsafe { libc::killpg(pid, libc::SIGKILL) };
            unsafe { libc::kill(pid, libc::SIGKILL) };
            let _ = child.wait().await;
            let mut wrong = Vec::new();
            if ready != 1 || took >= Duration::from_secs(1) {
                wrong.push(format!("the kernel process kept the write end of a pipe it inherited (no end of file within {took:?})"));
            }
            if sid != pid || pgid != pid {
                wrong.push(format!("the kernel process (pid {pid}) is in session {sid} and group {pgid}, not its own"));
            }
            if line.trim() != std::process::id().to_string() {
                wrong.push(format!("JPY_PARENT_PID is {:?}, want this process ({})", line.trim(), std::process::id()));
            }
            wrong
        });
        // SAFETY: closes the read end this test made.
        unsafe { libc::close(r) };
        assert!(wrong.is_empty(), "{}", wrong.join("\n"));
        println!("k5_child: every check ran");
    }

    #[test]
    fn k6_connection_info_ports() {
        let c = ConnectionInfo::new("py", [1, 2, 3, 4, 5]);
        assert_eq!(c.ports(), [1, 2, 3, 4, 5]);
        assert_eq!((c.shell_port, c.iopub_port, c.stdin_port, c.control_port, c.hb_port), (1, 2, 3, 4, 5));
        assert_eq!((c.ip.as_str(), c.transport.as_str(), c.signature_scheme.as_str()), ("127.0.0.1", "tcp", "hmac-sha256"));
        assert_eq!(c.key.len(), 36);
        assert_ne!(c.key, ConnectionInfo::new("py", [0; 5]).key, "every connection gets a key of its own");
        let d = c.with_ports([6, 7, 8, 9, 10]);
        assert_eq!(d.ports(), [6, 7, 8, 9, 10]);
        assert_eq!((d.key, d.kernel_name), (c.key.clone(), c.kernel_name.clone()));
        assert_eq!(c.endpoint(4), "tcp://127.0.0.1:4");
    }

    /// A process that is gone (reaped by whoever its parent is).
    fn gone(pid: libc::pid_t) -> bool {
        // SAFETY: kill with signal 0 only checks that the process exists.
        unsafe { libc::kill(pid, 0) == -1 && std::io::Error::last_os_error().raw_os_error() == Some(libc::ESRCH) }
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn k7_when_the_kernel_exits_its_group_is_stopped_and_its_dir_removed() {
        use tokio::io::AsyncBufReadExt;
        let root = std::env::temp_dir().join(format!("jvtest-kernel-{}-k7", std::process::id()));
        crate::connfile::remove_tree(&root);
        crate::connfile::mkdir_private(&root).unwrap();
        let backend = crate::connfile::BackendDir::create(&root, "k7").unwrap();
        let kdir = backend.new_kernel_dir().unwrap();
        // The kernel's own process exits at once and leaves a sleep in its group.
        let argv: Vec<String> = ["/bin/sh", "-c", "sleep 30 & echo $!; exit 0"].map(String::from).to_vec();
        let mut child = kernel_command(&test_spec(&[], Value::Null), &argv, None).spawn().unwrap();
        let pgid = child.id().unwrap() as i32;
        let mut line = String::new();
        tokio::io::BufReader::new(child.stdout.take().unwrap()).read_line(&mut line).await.unwrap();
        let sleep: libc::pid_t = line.trim().parse().unwrap();
        let (tx_exit, mut exited) = watch::channel(false);
        let killed = Arc::new(AtomicBool::new(false));
        let watcher = tokio::spawn(watch_exit(Leader::new(child), pgid, kdir.clone(), killed.clone(), tx_exit));
        let reported = tokio::time::timeout(Duration::from_secs(5), exited.wait_for(|e| *e)).await.is_ok();
        let dir_gone = !kdir.path().exists();
        let t = Instant::now();
        while !gone(sleep) && t.elapsed() < Duration::from_secs(3) {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        let sleep_gone = gone(sleep);
        if !sleep_gone {
            // SAFETY: the sleep this test started, by pid.
            unsafe { libc::kill(sleep, libc::SIGKILL) };
        }
        let _ = watcher.await;
        backend.remove();
        crate::connfile::remove_tree(&root);
        assert!(reported, "the kernel's exit was not reported");
        assert!(dir_gone, "the kernel dir was still there when the exit was reported");
        assert!(killed.load(Ordering::Acquire), "the group was not marked as stopped");
        assert!(sleep_gone, "the sleep the kernel left in its group still ran 3 s after the kernel exited");
    }

    thread_local! {
        /// The probe rounds wait_open made on this thread.
        pub(super) static PROBE_ROUNDS: std::cell::Cell<usize> = const { std::cell::Cell::new(0) };
        /// The longest pause the write-back loop asked for on this thread
        /// (recorded by pause, for the write-back's WRITE_PORTS).
        pub(super) static WRITE_BACK_PAUSE_MAX: std::cell::Cell<Duration> =
            const { std::cell::Cell::new(Duration::ZERO) };
        /// When, since the spawn, the write-back loop on this thread read the
        /// connection file, each time.
        pub(super) static WRITE_BACK_READS: std::cell::RefCell<Vec<Duration>> =
            const { std::cell::RefCell::new(Vec::new()) };
    }

    // K14 (B3): the connection file a kernel writes its ports back to is read
    // every 5 ms also after the first second (only the reserved-port probe
    // backs off, K10): the loop never asks for a longer pause, and it reads
    // the file far more often after 1.1 s than a 50 ms step could
    #[tokio::test]
    async fn k14_the_write_back_is_read_every_5_ms_all_along() {
        let (root, backend, kdir) = kernel_dir("k14");
        let argv: Vec<String> = ["/bin/sh", "-c", "exec sleep 2.1"].map(String::from).to_vec();
        let mut child = Leader::new(kernel_command(&test_spec(&[], Value::Null), &argv, None).spawn().unwrap());
        let t_spawn = Instant::now();
        let deadline = tokio::time::Instant::now() + Duration::from_secs(30);
        let conn = ConnectionInfo::new("k", [0; 5]);
        WRITE_BACK_PAUSE_MAX.with(|m| m.set(Duration::ZERO));
        WRITE_BACK_READS.with(|r| r.borrow_mut().clear());
        let r = bring_up(&mut child, "k", &kdir, conn, PortMode::KernelBinds, t_spawn, deadline, "s").await;
        let took = t_spawn.elapsed();
        let asked = WRITE_BACK_PAUSE_MAX.with(|m| m.get());
        let reads = WRITE_BACK_READS.with(|r| r.borrow().clone());
        let tail: StartTail = Arc::new(parking_lot::Mutex::new(None));
        let pgid = child.child.id().unwrap() as i32;
        let _ = abort(child, pgid, &kdir, None, &tail, "k", Stop::Exited).await;
        backend.remove();
        crate::connfile::remove_tree(&root);
        let late: Vec<Duration> = reads.iter().copied().filter(|t| *t >= Duration::from_millis(1100)).collect();
        let gap = late.windows(2).map(|w| w[1] - w[0]).max().unwrap_or_default();
        println!(
            "k14: took {took:?}, {} reads, {} after 1.1 s (their longest gap {gap:?}), longest pause asked {asked:?}",
            reads.len(),
            late.len()
        );
        assert!(matches!(r, Err(Stop::Exited)), "the read loop did not end with the kernel's exit");
        assert!(took >= Duration::from_secs(2), "the kernel exited after {took:?}, before the test's 2.1 s");
        assert_eq!(asked, POLL, "the write-back loop paused {asked:?} between two reads");
        // 5 ms apart gives about 200 reads in the second after 1.1 s, a
        // 50 ms step at most 21
        assert!(
            late.len() >= 30,
            "only {} reads of the write-back after 1.1 s, {took:?} after the spawn (longest gap {gap:?})",
            late.len()
        );
    }

    /// What a kernel's process (pid = its group's id) was when its group was
    /// sent SIGKILL by watch_exit or abort.
    #[derive(Clone, Copy, Debug, PartialEq, Eq)]
    pub(super) enum LeaderState {
        Running,
        /// exited, not reaped yet: its pid, the group's id, is still taken
        Unreaped,
        /// reaped: the id can be given to another process
        Reaped,
    }

    static KILLS: parking_lot::Mutex<Vec<(i32, LeaderState)>> = parking_lot::Mutex::new(Vec::new());

    /// The state of the child process `pid`, read without reaping it.
    pub(super) fn leader_state(pid: i32) -> LeaderState {
        // SAFETY: info is a valid siginfo_t for the call to fill in; waitid
        // with WNOWAIT only reads the child's state.
        let mut info: libc::siginfo_t = unsafe { std::mem::zeroed() };
        let rc = unsafe {
            libc::waitid(libc::P_PID, pid as libc::id_t, &mut info, libc::WEXITED | libc::WNOHANG | libc::WNOWAIT)
        };
        if rc != 0 {
            return LeaderState::Reaped;
        }
        #[cfg(target_os = "linux")]
        // SAFETY: waitid filled in a child's state change, which has si_pid.
        let got = unsafe { info.si_pid() };
        #[cfg(not(target_os = "linux"))]
        let got = info.si_pid;
        // no state change: si_pid stays 0
        if got == pid {
            LeaderState::Unreaped
        } else {
            LeaderState::Running
        }
    }

    pub(super) fn note_kill(pgid: i32) {
        KILLS.lock().push((pgid, leader_state(pgid)));
    }

    fn kill_noted(pgid: i32) -> Option<LeaderState> {
        KILLS.lock().iter().find(|(g, _)| *g == pgid).map(|(_, s)| *s)
    }

    /// A backend dir in a root of its own and a kernel dir in it.
    fn kernel_dir(label: &str) -> (PathBuf, crate::connfile::BackendDir, Arc<KernelDir>) {
        let root = std::env::temp_dir().join(format!("jvtest-kernel-{}-{label}", std::process::id()));
        crate::connfile::remove_tree(&root);
        crate::connfile::mkdir_private(&root).unwrap();
        let backend = crate::connfile::BackendDir::create(&root, label).unwrap();
        let kdir = backend.new_kernel_dir().unwrap();
        (root, backend, kdir)
    }

    // K12 (D17): when a running kernel's process exits, its group is sent
    // SIGKILL before the process is reaped, so the group's id cannot have
    // been given to another process yet; then it is reaped
    #[tokio::test(flavor = "multi_thread")]
    async fn k12_the_group_is_stopped_before_its_leader_is_reaped() {
        let (root, backend, kdir) = kernel_dir("k12");
        let argv: Vec<String> = ["/bin/sh", "-c", "exit 0"].map(String::from).to_vec();
        let child = kernel_command(&test_spec(&[], Value::Null), &argv, None).spawn().unwrap();
        let pgid = child.id().unwrap() as i32;
        let (tx_exit, mut exited) = watch::channel(false);
        let killed = Arc::new(AtomicBool::new(false));
        let watcher = tokio::spawn(watch_exit(Leader::new(child), pgid, kdir.clone(), killed.clone(), tx_exit));
        let reported = tokio::time::timeout(Duration::from_secs(5), exited.wait_for(|e| *e)).await.is_ok();
        let _ = watcher.await;
        let after = leader_state(pgid);
        backend.remove();
        crate::connfile::remove_tree(&root);
        assert!(reported, "the kernel's exit was not reported");
        assert_eq!(kill_noted(pgid), Some(LeaderState::Unreaped), "the group was signalled after its leader was reaped");
        assert!(killed.load(Ordering::Acquire));
        assert_eq!(after, LeaderState::Reaped, "the kernel's process was never reaped");
    }

    // K13 (D17): a kernel that exits during its start is seen to exit without
    // being reaped; the start's abort stops its group first, then reaps it
    // and names its exit status
    #[tokio::test(flavor = "multi_thread")]
    async fn k13_a_start_that_ends_with_the_exit_stops_the_group_before_reaping() {
        let (root, backend, kdir) = kernel_dir("k13");
        let argv: Vec<String> = ["/bin/sh", "-c", "echo gone >&2; exit 3"].map(String::from).to_vec();
        let mut child = Leader::new(kernel_command(&test_spec(&[], Value::Null), &argv, None).spawn().unwrap());
        let pgid = child.child.id().unwrap() as i32;
        let deadline = tokio::time::Instant::now() + Duration::from_secs(30);
        let t0 = Instant::now();
        let r = pause(&mut child, deadline, Duration::from_secs(20), "k", WRITE_PORTS).await;
        let took = t0.elapsed();
        let seen = leader_state(pgid);
        let tail: StartTail = Arc::new(parking_lot::Mutex::new(Some("gone\n".to_string())));
        let err = match abort(child, pgid, &kdir, None, &tail, "k", Stop::Exited).await {
            LaunchError::AddrInUse(e) | LaunchError::Other(e) => format!("{e:#}"),
        };
        let after = leader_state(pgid);
        backend.remove();
        crate::connfile::remove_tree(&root);
        assert!(matches!(r, Err(Stop::Exited)), "the wait did not end with the kernel's exit");
        assert!(took < Duration::from_secs(10), "the exit was seen after {took:?}");
        assert_eq!(seen, LeaderState::Unreaped, "the start reaped the kernel's process when it saw it exit");
        assert_eq!(kill_noted(pgid), Some(LeaderState::Unreaped), "abort signalled the group after reaping its leader");
        assert_eq!(after, LeaderState::Reaped, "abort did not reap the kernel's process");
        assert!(err.contains("exited during start (exit status: 3)") && err.contains("gone"), "{err}");
    }

    // K16: the timeout of a kernel taken for ipykernel that never writes its
    // ports back names the setting that gives it reserved ports; no other
    // timeout of a start does
    #[tokio::test]
    async fn k16_a_kernel_that_never_writes_its_ports_is_told_the_fix() {
        let hint = "\"jupynvim\": {\"ports\": \"reserved\"}";
        let text = |s: Stop| match s {
            Stop::Failed(e) => format!("{e:#}"),
            Stop::Exited => panic!("a timeout that reads as the kernel's exit"),
        };
        let w = text(late("k", WRITE_PORTS));
        assert!(w.contains("did not write its ports within 300 s"), "{w}");
        assert!(w.contains(hint), "the timeout of the write-back does not name the fix: {w}");
        let o = text(late("k", "open its ports"));
        assert!(!o.contains(hint) && !o.contains("metadata"), "the timeout of reserved ports names the fix: {o}");

        // the wait for the write-back itself ends with it once its deadline
        // passed (a pause far longer than the deadline, so that the deadline
        // ends it whatever the load)
        let argv: Vec<String> = ["/bin/sh", "-c", "exec sleep 30"].map(String::from).to_vec();
        let mut child = Leader::new(kernel_command(&test_spec(&[], Value::Null), &argv, None).spawn().unwrap());
        let pgid = child.child.id().unwrap() as i32;
        let r = pause(&mut child, tokio::time::Instant::now(), Duration::from_secs(20), "k", WRITE_PORTS).await;
        kill_group_once(pgid, &AtomicBool::new(false));
        let st = tokio::time::timeout(Duration::from_secs(10), child.child.wait()).await;
        let got = match r {
            Err(Stop::Failed(e)) => format!("{e:#}"),
            Err(Stop::Exited) => "the kernel's exit".to_string(),
            Ok(()) => "the end of the pause".to_string(),
        };
        assert!(got.contains(hint), "the wait for the write-back ended with {got}");
        assert!(matches!(st, Ok(Ok(_))), "the sleep was not reaped: {st:?}");
    }

    // K9: a starting kernel's reserved ports are probed every 5 ms in its
    // first second and every 50 ms after that
    #[test]
    fn k9_poll_step() {
        assert_eq!((POLL, POLL_FAST_FOR, POLL_SLOW), (Duration::from_millis(5), Duration::from_secs(1), Duration::from_millis(50)));
        assert_eq!(poll_step(Duration::ZERO), POLL);
        assert_eq!(poll_step(Duration::from_millis(999)), POLL);
        assert_eq!(poll_step(Duration::from_secs(1)), POLL_SLOW);
        assert_eq!(poll_step(START_TIMEOUT), POLL_SLOW);
    }

    // K10: the ports of a kernel given reserved ports are probed far less
    // often once its start has run for a second (a start can take minutes)
    #[tokio::test]
    async fn k10_wait_open_probes_less_often_after_the_first_second() {
        // three ports nothing listens on
        let closed: Vec<u16> = (0..3)
            .map(|_| std::net::TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).unwrap().local_addr().unwrap().port())
            .collect();
        let conn = ConnectionInfo::new("k", [closed[0], closed[1], 0, closed[2], 0]);
        let argv: Vec<String> = ["/bin/sh", "-c", "exec sleep 2.2"].map(String::from).to_vec();
        let mut child = Leader::new(kernel_command(&test_spec(&[], Value::Null), &argv, None).spawn().unwrap());
        let t_spawn = Instant::now();
        let deadline = tokio::time::Instant::now() + Duration::from_secs(30);
        PROBE_ROUNDS.with(|n| n.set(0));
        let r = wait_open(&mut child, deadline, t_spawn, &conn, "k").await;
        let rounds = PROBE_ROUNDS.with(|n| n.get());
        let took = t_spawn.elapsed();
        println!("k10: {rounds} probe rounds in {took:?}");
        assert!(matches!(r, Err(Stop::Exited)), "wait_open did not end with the kernel's exit");
        assert!(took >= Duration::from_secs(2), "the kernel exited after {took:?}, before the test's 2.2 s");
        // about 200 rounds in the first second and 24 in the 1.2 s after it;
        // about 440 at 5 ms all along
        assert!((20..=300).contains(&rounds), "{rounds} probe rounds in {took:?}");
    }

    // K11: a kernel's stderr is kept only while it starts: once the start is
    // over, the reader lets go of the tail at its next line
    #[tokio::test]
    async fn k11_the_stderr_tail_is_kept_only_during_the_start() {
        use tokio::io::AsyncWriteExt;
        let (mut w, r) = tokio::io::duplex(1 << 16);
        let tail: StartTail = Arc::new(parking_lot::Mutex::new(Some(String::new())));
        let (tx, mut rx) = mpsc::unbounded_channel();
        let active = Arc::new(parking_lot::Mutex::new(None));
        let reader = tokio::spawn(drain_pipe(r, "stderr".to_string(), active, tx, Some(tail.clone())));
        w.write_all(b"starting\n").await.unwrap();
        assert!(rx.recv().await.is_some());
        assert_eq!(tail.lock().as_deref(), Some("starting\n"), "a line read during the start was not kept");
        // the start is over
        *tail.lock() = None;
        w.write_all(b"running\n").await.unwrap();
        assert!(rx.recv().await.is_some());
        assert!(tail.lock().is_none(), "a line read after the start was kept");
        assert_eq!(Arc::strong_count(&tail), 1, "the reader still holds the tail after the start");
        drop(w);
        let _ = reader.await;
    }
}
