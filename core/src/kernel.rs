// Spawn a Jupyter kernel and own its 5 ZMQ sockets (shell, iopub, stdin, control, hb).
//
// Connection-file based handshake: write JSON with random ports + HMAC key, kernel
// reads it via {connection_file} substitution in argv, then we connect.

use anyhow::{anyhow, Context, Result};
use bytes::Bytes;
use dashmap::DashMap;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;
use tokio::process::{Child, Command};
use tokio::sync::{mpsc, oneshot, Mutex};
use uuid::Uuid;
use zeromq::{DealerSocket, Socket, SocketRecv, SocketSend, SubSocket, ZmqMessage};

use crate::kernelspec::KernelSpec;
use crate::protocol::{self, Message};

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
    pub fn new_localhost(kernel_name: &str) -> Result<Self> {
        let ports = pick_ports(5)?;
        let key = Uuid::new_v4().to_string();
        Ok(Self {
            ip: "127.0.0.1".to_string(),
            transport: "tcp".to_string(),
            shell_port: ports[0],
            iopub_port: ports[1],
            stdin_port: ports[2],
            control_port: ports[3],
            hb_port: ports[4],
            key,
            signature_scheme: "hmac-sha256".to_string(),
            kernel_name: kernel_name.to_string(),
        })
    }

    pub fn endpoint(&self, port: u16) -> String {
        format!("{}://{}:{}", self.transport, self.ip, port)
    }
}

fn pick_ports(n: usize) -> Result<Vec<u16>> {
    use std::net::TcpListener;
    let mut ports = Vec::with_capacity(n);
    let mut listeners = Vec::with_capacity(n);
    for _ in 0..n {
        let l = TcpListener::bind("127.0.0.1:0")?;
        let p = l.local_addr()?.port();
        ports.push(p);
        listeners.push(l);
    }
    drop(listeners); // release before kernel binds
    Ok(ports)
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
}

pub struct Kernel {
    spec: KernelSpec,
    conn: ConnectionInfo,
    session: String,
    child: Mutex<Child>,
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
    pub async fn launch(spec: KernelSpec, cwd: Option<PathBuf>) -> Result<Self> {
        let conn = ConnectionInfo::new_localhost(&spec.name)?;
        let conn_path = write_connection_file(&conn)?;
        tracing::info!(?conn_path, kernel = %spec.name, "launching kernel");

        let argv: Vec<String> = spec
            .argv
            .iter()
            .map(|a| {
                a.replace("{connection_file}", conn_path.to_string_lossy().as_ref())
                    .replace("{resource_dir}", spec.path.to_string_lossy().as_ref())
            })
            .collect();

        if argv.is_empty() {
            return Err(anyhow!("kernel '{}' has empty argv", spec.name));
        }

        let mut cmd = Command::new(&argv[0]);
        cmd.args(&argv[1..]);
        for (k, v) in &spec.env {
            cmd.env(k, v);
        }
        // Validate cwd before passing — chdir() failing inside spawn returns
        // the same ENOENT as a missing argv[0], which is hard to distinguish.
        // Fall back to the backend's own cwd if the requested one doesn't
        // exist (e.g., notebook path that exists in our fs view but the
        // kernel process can't reach for some reason).
        let resolved_cwd = match cwd {
            Some(d) if d.exists() => Some(d),
            Some(d) => {
                tracing::warn!("kernel cwd {} does not exist; spawning without chdir", d.display());
                None
            }
            None => None,
        };
        if let Some(d) = &resolved_cwd {
            cmd.current_dir(d);
        }
        cmd.stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .kill_on_drop(true);

        let argv0_exists = std::path::Path::new(&argv[0]).exists();
        let child = cmd.spawn().with_context(|| {
            format!(
                "spawning {:?} (cwd={:?}, argv0_exists={}, env_keys={:?})",
                argv,
                resolved_cwd,
                argv0_exists,
                spec.env.keys().collect::<Vec<_>>()
            )
        })?;
        let session = Uuid::new_v4().to_string();

        // Connect sockets — wait briefly for kernel to bind
        let (shell, control, iopub) = connect_sockets(&conn).await?;

        let (tx, rx) = mpsc::unbounded_channel::<KernelEvent>();
        let tx_iopub = tx.clone();
        let tx_shell = tx.clone();
        let tx_pipes = tx.clone();
        let key = conn.key.as_bytes().to_vec();
        let iopub_handle = tokio::spawn(iopub_loop(iopub, key.clone(), tx_iopub));

        // Single owner per shell/control: tokio::select on outgoing channel + socket recv
        let (shell_tx, shell_rx) = mpsc::unbounded_channel::<ZmqMessage>();
        let (control_tx, control_rx) = mpsc::unbounded_channel::<ZmqMessage>();
        let pending: Arc<DashMap<String, oneshot::Sender<Value>>> = Arc::new(DashMap::new());
        tokio::spawn(socket_owner(
            shell,
            shell_rx,
            key.clone(),
            tx_shell,
            "shell",
            Some(pending.clone()),
        ));
        let _ = tokio::spawn(socket_owner(control, control_rx, key, tx, "control", None));

        let active_msg_id: Arc<parking_lot::Mutex<Option<String>>> =
            Arc::new(parking_lot::Mutex::new(None));

        // Drain kernel's stdout/stderr pipes and forward as Stream events.
        // IPython's `!cmd` shell magic writes to fd 1 directly (via subprocess
        // inheriting the kernel's stdout) — bypassing sys.stdout's iopub
        // redirection. Without this drain the output is lost AND the pipe
        // can fill and block the kernel subprocess.
        let mut child = child;
        let stdout = child.stdout.take();
        let stderr = child.stderr.take();
        if let Some(s) = stdout {
            tokio::spawn(drain_pipe(s, "stdout".to_string(),
                active_msg_id.clone(), tx_pipes.clone()));
        }
        if let Some(s) = stderr {
            tokio::spawn(drain_pipe(s, "stderr".to_string(),
                active_msg_id.clone(), tx_pipes));
        }

        Ok(Self {
            spec,
            conn,
            session,
            child: Mutex::new(child),
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

    pub async fn kill(&self) -> Result<()> {
        self.iopub_handle.abort();
        let mut child = self.child.lock().await;
        let _ = child.start_kill();
        let _ = child.wait().await;
        Ok(())
    }
}

fn write_connection_file(conn: &ConnectionInfo) -> Result<PathBuf> {
    let dir = std::env::temp_dir().join("jupynvim");
    std::fs::create_dir_all(&dir)?;
    let path = dir.join(format!("kernel-{}.json", Uuid::new_v4()));
    let val = json!({
        "ip": conn.ip,
        "transport": conn.transport,
        "shell_port": conn.shell_port,
        "iopub_port": conn.iopub_port,
        "stdin_port": conn.stdin_port,
        "control_port": conn.control_port,
        "hb_port": conn.hb_port,
        "key": conn.key,
        "signature_scheme": conn.signature_scheme,
        "kernel_name": conn.kernel_name,
    });
    std::fs::write(&path, serde_json::to_vec_pretty(&val)?)?;
    Ok(path)
}

async fn connect_sockets(
    conn: &ConnectionInfo,
) -> Result<(DealerSocket, DealerSocket, SubSocket)> {
    // Kernel needs a moment to bind its sockets; retry briefly
    let mut shell = DealerSocket::new();
    let mut control = DealerSocket::new();
    let mut iopub = SubSocket::new();
    iopub.subscribe("").await.map_err(|e| anyhow!("iopub subscribe: {e}"))?;

    let attempts = 50;
    let delay = Duration::from_millis(100);
    for i in 0..attempts {
        let r1 = shell.connect(&conn.endpoint(conn.shell_port)).await;
        let r2 = control.connect(&conn.endpoint(conn.control_port)).await;
        let r3 = iopub.connect(&conn.endpoint(conn.iopub_port)).await;
        if r1.is_ok() && r2.is_ok() && r3.is_ok() {
            return Ok((shell, control, iopub));
        }
        if i + 1 == attempts {
            return Err(anyhow!(
                "could not connect kernel sockets: shell={:?} control={:?} iopub={:?}",
                r1.err(),
                r2.err(),
                r3.err()
            ));
        }
        tokio::time::sleep(delay).await;
    }
    unreachable!()
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
/// redirection — so this output never reaches the iopub_loop.
async fn drain_pipe<R>(
    pipe: R,
    stream_name: String,
    active: Arc<parking_lot::Mutex<Option<String>>>,
    tx: mpsc::UnboundedSender<KernelEvent>,
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
        _ => None,
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
