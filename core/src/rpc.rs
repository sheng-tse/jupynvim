// msgpack-rpc over stdio.
// Frame layout (Neovim style):
//   Request:      [0, msgid, method, params]
//   Response:     [1, msgid, error|nil, result|nil]
//   Notification: [2, method, params]

use anyhow::{anyhow, Context, Result};
use base64::Engine as _;
use dashmap::DashMap;
use rmpv::Value as Mp;
use serde_json::{json, Value as Json};
use std::path::PathBuf;
use std::sync::Arc;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::sync::{Mutex, Notify};
use uuid::Uuid;

use crate::kernel::Kernel;
use crate::kernelspec;
use crate::kitty::{self, KittyMode, LocalTty};
use crate::notebook::CellType;
use crate::session::Session;

pub struct Server {
    sessions: DashMap<String, Arc<Session>>,
    out_tx: Mutex<Option<tokio::sync::mpsc::UnboundedSender<Mp>>>,
    shutdown: Arc<Notify>,
    /// How kitty escape bytes reach the user's terminal. None until the
    /// frontend has called kitty_attach (local TTY or remote-bytes-via-RPC).
    kitty: Mutex<Option<KittyMode>>,
    /// Active proc_spawn'd PTY processes, keyed by our virtual pid.
    procs: DashMap<u32, Arc<ProcessEntry>>,
    next_proc_id: std::sync::atomic::AtomicU32,
    /// Active fs_watch watchers, keyed by virtual watcher_id.
    watchers: DashMap<u32, notify::RecommendedWatcher>,
    next_watcher_id: std::sync::atomic::AtomicU32,
    /// Active relayed LSP servers, keyed by virtual lsp_id.
    lsps: DashMap<u32, Arc<LspEntry>>,
    next_lsp_id: std::sync::atomic::AtomicU32,
}

/// One relayed language server: its child + a writer to its stdin. The reader
/// thread parses LSP Content-Length framing and forwards each JSON message to
/// the frontend as an `lsp_message` notification. The frontend (Lua) speaks
/// plain JSON-RPC tables; the backend owns the framing.
struct LspEntry {
    child: parking_lot::Mutex<tokio::process::Child>,
    stdin: tokio::sync::Mutex<tokio::process::ChildStdin>,
}

/// One PTY-backed remote process. PTY master stays open here; the slave
/// is consumed by the spawned child. A blocking reader task pumps stdout
/// from the master into proc_event notifications.
struct ProcessEntry {
    pty: parking_lot::Mutex<Box<dyn portable_pty::MasterPty + Send>>,
    writer: parking_lot::Mutex<Box<dyn std::io::Write + Send>>,
    child: parking_lot::Mutex<Option<Box<dyn portable_pty::Child + Send + Sync>>>,
}

impl Server {
    pub fn new() -> Arc<Self> {
        Arc::new(Self {
            sessions: DashMap::new(),
            out_tx: Mutex::new(None),
            shutdown: Arc::new(Notify::new()),
            kitty: Mutex::new(None),
            procs: DashMap::new(),
            next_proc_id: std::sync::atomic::AtomicU32::new(1),
            watchers: DashMap::new(),
            next_watcher_id: std::sync::atomic::AtomicU32::new(1),
            lsps: DashMap::new(),
            next_lsp_id: std::sync::atomic::AtomicU32::new(1),
        })
    }

    pub async fn run_stdio(self: Arc<Self>) -> Result<()> {
        let (out_tx, mut out_rx) = tokio::sync::mpsc::unbounded_channel::<Mp>();
        *self.out_tx.lock().await = Some(out_tx);

        // Writer task — owns stdout. Frame each message as <u32 BE length><payload>.
        let writer = tokio::spawn(async move {
            let mut out = tokio::io::stdout();
            while let Some(msg) = out_rx.recv().await {
                let mut buf = Vec::with_capacity(256);
                if let Err(e) = rmpv::encode::write_value(&mut buf, &msg) {
                    tracing::error!("encode rpc: {e}");
                    continue;
                }
                let len = buf.len() as u32;
                let header = len.to_be_bytes();
                if let Err(e) = out.write_all(&header).await {
                    tracing::error!("stdout write hdr: {e}");
                    break;
                }
                if let Err(e) = out.write_all(&buf).await {
                    tracing::error!("stdout write: {e}");
                    break;
                }
                if let Err(e) = out.flush().await {
                    tracing::error!("stdout flush: {e}");
                    break;
                }
            }
        });

        // Reader loop on stdin: <u32 BE length><payload>
        let server = self.clone();
        let reader = tokio::spawn(async move {
            let mut stdin = tokio::io::stdin();
            let mut buf = vec![0u8; 64 * 1024];
            let mut acc: Vec<u8> = Vec::with_capacity(64 * 1024);
            loop {
                let n = match stdin.read(&mut buf).await {
                    Ok(0) => {
                        tracing::info!("stdin EOF");
                        break;
                    }
                    Ok(n) => n,
                    Err(e) => {
                        tracing::error!("stdin read: {e}");
                        break;
                    }
                };
                acc.extend_from_slice(&buf[..n]);
                loop {
                    if acc.len() < 4 {
                        break;
                    }
                    let len = u32::from_be_bytes([acc[0], acc[1], acc[2], acc[3]]) as usize;
                    if acc.len() < 4 + len {
                        break;
                    }
                    let payload = acc[4..4 + len].to_vec();
                    acc.drain(..4 + len);
                    let mut cursor = std::io::Cursor::new(&payload[..]);
                    match rmpv::decode::read_value(&mut cursor) {
                        Ok(val) => {
                            let server2 = server.clone();
                            tokio::spawn(async move {
                                if let Err(e) = server2.handle_message(val).await {
                                    tracing::warn!("handle_message: {e:?}");
                                }
                            });
                        }
                        Err(e) => {
                            tracing::warn!("decode rpc payload: {e}");
                        }
                    }
                }
            }
        });

        tokio::select! {
            _ = self.shutdown.notified() => {}
            _ = reader => {}
            _ = writer => {}
        }
        Ok(())
    }

    async fn send(&self, msg: Mp) {
        let g = self.out_tx.lock().await;
        if let Some(tx) = g.as_ref() {
            let _ = tx.send(msg);
        }
    }

    async fn handle_message(self: Arc<Self>, val: Mp) -> Result<()> {
        let arr = val.as_array().ok_or_else(|| anyhow!("rpc msg not array"))?;
        if arr.is_empty() {
            return Err(anyhow!("empty rpc msg"));
        }
        let kind = arr[0].as_u64().ok_or_else(|| anyhow!("bad kind"))?;
        match kind {
            0 => {
                // request
                if arr.len() < 4 {
                    return Err(anyhow!("bad request"));
                }
                let msgid = arr[1].as_u64().ok_or_else(|| anyhow!("bad msgid"))?;
                let method = arr[2].as_str().ok_or_else(|| anyhow!("bad method"))?.to_string();
                let params = arr[3].clone();
                let server = self.clone();
                tokio::spawn(async move {
                    let server2 = server.clone();
                    let result = server.dispatch(&method, params).await;
                    let resp = match result {
                        Ok(v) => Mp::Array(vec![
                            Mp::from(1u32),
                            Mp::from(msgid),
                            Mp::Nil,
                            json_to_mp(&v),
                        ]),
                        Err(e) => Mp::Array(vec![
                            Mp::from(1u32),
                            Mp::from(msgid),
                            Mp::String(format!("{e:#}").into()),
                            Mp::Nil,
                        ]),
                    };
                    server2.send(resp).await;
                });
            }
            2 => {
                // notification
                if arr.len() < 3 {
                    return Err(anyhow!("bad notification"));
                }
                let method = arr[1].as_str().ok_or_else(|| anyhow!("bad method"))?.to_string();
                let params = arr[2].clone();
                let server = self.clone();
                tokio::spawn(async move {
                    if let Err(e) = server.dispatch(&method, params).await {
                        tracing::warn!("notify {} error: {e:?}", method);
                    }
                });
            }
            1 => { /* responses ignored — we don't make requests from core */ }
            _ => return Err(anyhow!("unknown rpc kind {kind}")),
        }
        Ok(())
    }

    async fn dispatch(self: Arc<Self>, method: &str, params: Mp) -> Result<Json> {
        // msgpack-rpc params is always Array. If length == 1, unwrap so handlers
        // can treat it as a single named-args object.
        let p = match &params {
            Mp::Array(arr) if arr.len() == 1 => mp_to_json(&arr[0]),
            _ => mp_to_json(&params),
        };
        match method {
            "ping" => Ok(json!("pong")),
            "list_kernels" => self.list_kernels(),
            "open" => self.open(p).await,
            "close" => self.close(p).await,
            "snapshot" => self.snapshot(p),
            "start_kernel" => self.start_kernel(p).await,
            "stop_kernel" => self.stop_kernel(p).await,
            "interrupt_kernel" => self.interrupt_kernel(p).await,
            "restart_kernel" => self.restart_kernel(p).await,
            "execute" => self.execute(p).await,
            "execute_silent" => self.execute_silent(p).await,
            "complete" => self.complete(p).await,
            "inspect" => self.inspect(p).await,
            "update_cell_source" => self.update_cell_source(p).await,
            "set_cell_type" => self.set_cell_type(p).await,
            "insert_cell" => self.insert_cell(p).await,
            "delete_cell" => self.delete_cell(p).await,
            "move_cell" => self.move_cell(p).await,
            "clear_outputs" => self.clear_outputs(p).await,
            "clear_cell_output" => self.clear_cell_output(p).await,
            "save" => self.save(p).await,
            "save_as" => self.save_as(p).await,
            "replace_cells" => self.replace_cells(p).await,
            "kitty_attach" => self.kitty_attach(p).await,
            "kitty_transmit_only" => self.kitty_transmit_only(p).await,
            "kitty_transmit_virtual" => self.kitty_transmit_virtual(p).await,
            "kitty_place" => self.kitty_place(p).await,
            "kitty_clear_image" => self.kitty_clear_image(p).await,
            "kitty_clear_visible" => self.kitty_clear_visible(p).await,
            "kitty_clear_all" => self.kitty_clear_all(p).await,
            "fs_list" => self.fs_list(p).await,
            "fs_stat" => self.fs_stat(p).await,
            "fs_read" => self.fs_read(p).await,
            "fs_write" => self.fs_write(p).await,
            "fs_mkdir" => self.fs_mkdir(p).await,
            "fs_rm" => self.fs_rm(p).await,
            "fs_rename" => self.fs_rename(p).await,
            "fs_realpath" => self.fs_realpath(p).await,
            "proc_spawn" => self.proc_spawn(p).await,
            "proc_stdin" => self.proc_stdin(p).await,
            "proc_resize" => self.proc_resize(p).await,
            "proc_kill" => self.proc_kill(p).await,
            "search" => self.search(p).await,
            "find_files" => self.find_files(p).await,
            "fs_watch" => self.fs_watch(p).await,
            "fs_unwatch" => self.fs_unwatch(p).await,
            "run" => self.run_cmd(p).await,
            "lsp_start" => self.lsp_start(p).await,
            "lsp_send" => self.lsp_send(p).await,
            "lsp_stop" => self.lsp_stop(p).await,
            other => Err(anyhow!("unknown method '{other}'")),
        }
    }

    // ---- handlers ----

    fn list_kernels(&self) -> Result<Json> {
        let specs = kernelspec::discover_all();
        Ok(serde_json::to_value(specs)?)
    }

    async fn open(&self, p: Json) -> Result<Json> {
        // arg_path expands `~/`, `~`, `/~/...` to the server-process's $HOME
        // so frontends can send tilde-prefixed paths without local expansion.
        let path = arg_path(&p, "path")?;
        let id = Uuid::new_v4().to_string();
        let session = Session::open(id.clone(), path)?;
        self.sessions.insert(id.clone(), session.clone());
        let snap = session.snapshot();
        Ok(json!({ "session_id": id, "snapshot": snap }))
    }

    async fn close(&self, p: Json) -> Result<Json> {
        let sid = p
            .get("session_id")
            .and_then(|v| v.as_str())
            .ok_or_else(|| anyhow!("session_id required"))?;
        if let Some((_, s)) = self.sessions.remove(sid) {
            let kernel = s.kernel.write().await.take();
            if let Some(k) = kernel {
                let _ = k.kill().await;
            }
        }
        Ok(json!({ "ok": true }))
    }

    fn snapshot(&self, p: Json) -> Result<Json> {
        let sid = p
            .get("session_id")
            .and_then(|v| v.as_str())
            .ok_or_else(|| anyhow!("session_id required"))?;
        let s = self
            .sessions
            .get(sid)
            .ok_or_else(|| anyhow!("session not found"))?;
        Ok(serde_json::to_value(s.snapshot())?)
    }

    async fn start_kernel(self: Arc<Self>, p: Json) -> Result<Json> {
        let sid = p
            .get("session_id")
            .and_then(|v| v.as_str())
            .ok_or_else(|| anyhow!("session_id required"))?
            .to_string();
        let session = self
            .sessions
            .get(&sid)
            .ok_or_else(|| anyhow!("session not found"))?
            .clone();

        // python_path bypasses kernelspec registry entirely. The frontend
        // uses this to point at a project-local .venv/bin/python without
        // requiring `python -m ipykernel install --user --name foo` first.
        // Constructed kernelspec mimics what `ipykernel install` would
        // produce: argv launches python -m ipykernel_launcher with the
        // standard {connection_file} substitution.
        let spec = if let Some(py) = p.get("python_path").and_then(|v| v.as_str()) {
            let py = py.to_string();
            let path_buf = std::path::PathBuf::from(&py);
            let parent = path_buf
                .parent()
                .and_then(|p| p.parent())
                .map(|p| p.to_path_buf())
                .unwrap_or_else(|| path_buf.clone());
            kernelspec::KernelSpec {
                name: "venv-python".to_string(),
                path: parent,
                argv: vec![
                    py,
                    "-m".to_string(),
                    "ipykernel_launcher".to_string(),
                    "-f".to_string(),
                    "{connection_file}".to_string(),
                ],
                display_name: "venv python".to_string(),
                language: "python".to_string(),
                interrupt_mode: None,
                env: std::collections::HashMap::new(),
                metadata: serde_json::Value::Null,
            }
        } else {
            // Pick kernel: explicit > metadata > python3
            let name = p
                .get("kernel_name")
                .and_then(|v| v.as_str())
                .map(|s| s.to_string())
                .or_else(|| session.notebook.read().kernel_name())
                .unwrap_or_else(|| "python3".to_string());

            // Resolve with version-tolerant fallback so a notebook saved with
            // kernelspec name "julia" or "julia-1.10" still opens on a machine
            // with only julia-1.12 installed. Same for python3 vs python3.13,
            // ir vs ir-r-4.5, etc. The notebook's metadata language gives us a
            // last-resort hint for cross-version mismatch.
            let language = session.notebook.read().kernel_language();
            kernelspec::discover_with_fallback(&name, language.as_deref())
                .ok_or_else(|| anyhow!("no kernelspec found for '{name}' (and no fallback by language)"))?
        };

        let cwd = session.path.parent().map(|p| p.to_path_buf());
        let kernel = Kernel::launch(spec, cwd).await?;
        let kernel_name = kernel.spec().name.clone();
        let mut rx = kernel
            .take_events()
            .await
            .ok_or_else(|| anyhow!("kernel events already taken"))?;

        {
            let mut slot = session.kernel.write().await;
            // Drop alone doesn't kill the child process — only Kernel::kill
            // does. Without explicit kill, re-calling start_kernel orphans
            // the previous ipykernel_launcher (process leak).
            if let Some(old) = slot.take() {
                let _ = old.kill().await;
            }
            *slot = Some(kernel);
        }

        // Spawn event pump: kernel events → session → frontend notifications
        let server = self.clone();
        let session_clone = session.clone();
        let sid_clone = sid.clone();
        tokio::spawn(async move {
            while let Some(ev) = rx.recv().await {
                if let Some((cell_id, payload)) = session_clone.apply_event(&ev) {
                    let note = json!({
                        "session_id": sid_clone,
                        "cell_id": cell_id,
                        "event": payload,
                    });
                    server.notify("cell_event", note).await;
                } else {
                    let note = json!({
                        "session_id": sid_clone,
                        "event": json!({ "kind": "global", "raw": format!("{ev:?}") }),
                    });
                    server.notify("kernel_event", note).await;
                }
            }
            tracing::info!("kernel events channel closed for session {sid_clone}");
        });

        Ok(json!({ "kernel_name": kernel_name }))
    }

    async fn stop_kernel(&self, p: Json) -> Result<Json> {
        let sid = p
            .get("session_id")
            .and_then(|v| v.as_str())
            .ok_or_else(|| anyhow!("session_id required"))?;
        let s = self.sessions.get(sid).ok_or_else(|| anyhow!("no session"))?.clone();
        let k = s.kernel.write().await.take();
        if let Some(k) = k {
            k.kill().await?;
        }
        Ok(json!({ "ok": true }))
    }

    async fn interrupt_kernel(&self, p: Json) -> Result<Json> {
        let sid = p
            .get("session_id")
            .and_then(|v| v.as_str())
            .ok_or_else(|| anyhow!("session_id required"))?;
        let s = self.sessions.get(sid).ok_or_else(|| anyhow!("no session"))?.clone();
        let guard = s.kernel.read().await;
        if let Some(k) = guard.as_ref() {
            k.interrupt().await?;
        }
        Ok(json!({ "ok": true }))
    }

    async fn restart_kernel(self: Arc<Self>, p: Json) -> Result<Json> {
        self.stop_kernel(p.clone()).await.ok();
        self.start_kernel(p).await
    }

    async fn execute(&self, p: Json) -> Result<Json> {
        let sid = p
            .get("session_id")
            .and_then(|v| v.as_str())
            .ok_or_else(|| anyhow!("session_id required"))?;
        let cell_id = p
            .get("cell_id")
            .and_then(|v| v.as_str())
            .ok_or_else(|| anyhow!("cell_id required"))?;
        let session = self
            .sessions
            .get(sid)
            .ok_or_else(|| anyhow!("no session"))?
            .clone();
        // Pull source from current cell state
        let source = {
            let nb = session.notebook.read();
            nb.cells
                .iter()
                .find(|c| c.id == cell_id)
                .map(|c| c.source.clone())
                .ok_or_else(|| anyhow!("cell not found"))?
        };
        let guard = session.kernel.read().await;
        let kernel = guard
            .as_ref()
            .ok_or_else(|| anyhow!("kernel not started"))?;
        // Pre-generate msg_id and register routing BEFORE sending so iopub events
        // arriving immediately after will route to the correct cell.
        let msg_id = uuid::Uuid::new_v4().to_string();
        session.msg_to_cell.insert(msg_id.clone(), cell_id.to_string());
        kernel.execute_with_id(&source, msg_id.clone()).await?;
        Ok(json!({ "msg_id": msg_id }))
    }

    /// Run a code snippet on the kernel without binding to any cell. silent
    /// + store_history=false so the run does not increment the execution
    /// counter, doesn't broadcast iopub output, and stays out of the
    /// kernel's Out[N] cache. Used to inject things like the matplotlib
    /// inline magic at kernel start without polluting cell numbering.
    async fn execute_silent(&self, p: Json) -> Result<Json> {
        let sid = p.get("session_id").and_then(|v| v.as_str()).ok_or_else(|| anyhow!("session_id"))?;
        let code = p.get("code").and_then(|v| v.as_str()).ok_or_else(|| anyhow!("code"))?;
        let session = self.sessions.get(sid).ok_or_else(|| anyhow!("no session"))?.clone();
        let guard = session.kernel.read().await;
        let kernel = guard.as_ref().ok_or_else(|| anyhow!("kernel not started"))?;
        let msg_id = uuid::Uuid::new_v4().to_string();
        kernel.execute_with_id_opts(code, msg_id.clone(), true, false).await?;
        Ok(json!({ "msg_id": msg_id }))
    }

    async fn complete(&self, p: Json) -> Result<Json> {
        let sid = p.get("session_id").and_then(|v| v.as_str()).ok_or_else(|| anyhow!("session_id"))?;
        let code = p.get("code").and_then(|v| v.as_str()).ok_or_else(|| anyhow!("code"))?;
        let cursor_pos = p
            .get("cursor_pos")
            .and_then(|v| v.as_u64())
            .ok_or_else(|| anyhow!("cursor_pos"))? as usize;
        let session = self.sessions.get(sid).ok_or_else(|| anyhow!("no session"))?.clone();
        let guard = session.kernel.read().await;
        let kernel = guard.as_ref().ok_or_else(|| anyhow!("kernel not started"))?;
        let reply = kernel.complete(code, cursor_pos).await?;
        Ok(reply)
    }

    async fn inspect(&self, p: Json) -> Result<Json> {
        let sid = p.get("session_id").and_then(|v| v.as_str()).ok_or_else(|| anyhow!("session_id"))?;
        let code = p.get("code").and_then(|v| v.as_str()).ok_or_else(|| anyhow!("code"))?;
        let cursor_pos = p
            .get("cursor_pos")
            .and_then(|v| v.as_u64())
            .ok_or_else(|| anyhow!("cursor_pos"))? as usize;
        let detail_level = p.get("detail_level").and_then(|v| v.as_u64()).unwrap_or(0) as u8;
        let session = self.sessions.get(sid).ok_or_else(|| anyhow!("no session"))?.clone();
        let guard = session.kernel.read().await;
        let kernel = guard.as_ref().ok_or_else(|| anyhow!("kernel not started"))?;
        let reply = kernel.inspect(code, cursor_pos, detail_level).await?;
        Ok(reply)
    }

    async fn update_cell_source(&self, p: Json) -> Result<Json> {
        let sid = p.get("session_id").and_then(|v| v.as_str()).ok_or_else(|| anyhow!("session_id"))?;
        let cell_id = p.get("cell_id").and_then(|v| v.as_str()).ok_or_else(|| anyhow!("cell_id"))?;
        let source = p.get("source").and_then(|v| v.as_str()).ok_or_else(|| anyhow!("source"))?.to_string();
        let s = self.sessions.get(sid).ok_or_else(|| anyhow!("no session"))?;
        s.update_cell_source(cell_id, source)?;
        Ok(json!({ "ok": true }))
    }

    async fn set_cell_type(&self, p: Json) -> Result<Json> {
        let sid = p.get("session_id").and_then(|v| v.as_str()).ok_or_else(|| anyhow!("session_id"))?;
        let cell_id = p.get("cell_id").and_then(|v| v.as_str()).ok_or_else(|| anyhow!("cell_id"))?;
        let cell_type = p.get("cell_type").and_then(|v| v.as_str()).ok_or_else(|| anyhow!("cell_type"))?;
        let s = self.sessions.get(sid).ok_or_else(|| anyhow!("no session"))?;
        s.set_cell_type(cell_id, CellType::from_str(cell_type))?;
        Ok(json!({ "ok": true }))
    }

    async fn insert_cell(&self, p: Json) -> Result<Json> {
        let sid = p.get("session_id").and_then(|v| v.as_str()).ok_or_else(|| anyhow!("session_id"))?;
        let after_index = p.get("after_index").and_then(|v| v.as_i64()).map(|i| i as usize);
        let cell_type = p.get("cell_type").and_then(|v| v.as_str()).unwrap_or("code");
        let s = self.sessions.get(sid).ok_or_else(|| anyhow!("no session"))?;
        let id = s.insert_cell(after_index, CellType::from_str(cell_type))?;
        Ok(json!({ "cell_id": id }))
    }

    async fn delete_cell(&self, p: Json) -> Result<Json> {
        let sid = p.get("session_id").and_then(|v| v.as_str()).ok_or_else(|| anyhow!("session_id"))?;
        let cell_id = p.get("cell_id").and_then(|v| v.as_str()).ok_or_else(|| anyhow!("cell_id"))?;
        let s = self.sessions.get(sid).ok_or_else(|| anyhow!("no session"))?;
        s.delete_cell(cell_id)?;
        Ok(json!({ "ok": true }))
    }

    async fn move_cell(&self, p: Json) -> Result<Json> {
        let sid = p.get("session_id").and_then(|v| v.as_str()).ok_or_else(|| anyhow!("session_id"))?;
        let cell_id = p.get("cell_id").and_then(|v| v.as_str()).ok_or_else(|| anyhow!("cell_id"))?;
        let delta = p.get("delta").and_then(|v| v.as_i64()).unwrap_or(0);
        let s = self.sessions.get(sid).ok_or_else(|| anyhow!("no session"))?;
        let new_idx = s.move_cell(cell_id, delta)?;
        Ok(json!({ "new_index": new_idx }))
    }

    /// Replace the entire cell list of a session. Frontend sends an ordered
    /// array of {id, cell_type, source}; backend preserves outputs by id and
    /// drops cells absent from the list. Returns the new ordered id list.
    async fn replace_cells(&self, p: Json) -> Result<Json> {
        let sid = p.get("session_id").and_then(|v| v.as_str()).ok_or_else(|| anyhow!("session_id"))?;
        let cells = p.get("cells").and_then(|v| v.as_array()).ok_or_else(|| anyhow!("cells array"))?;
        let mut incoming: Vec<(String, String, String)> = Vec::with_capacity(cells.len());
        for c in cells {
            let id = c.get("id").and_then(|v| v.as_str()).unwrap_or("").to_string();
            let ct = c.get("cell_type").and_then(|v| v.as_str()).unwrap_or("code").to_string();
            let src = c.get("source").and_then(|v| v.as_str()).unwrap_or("").to_string();
            incoming.push((id, ct, src));
        }
        let s = self.sessions.get(sid).ok_or_else(|| anyhow!("no session"))?.clone();
        let new_ids = s.replace_cells(incoming)?;
        Ok(json!({ "ids": new_ids }))
    }

    async fn save(&self, p: Json) -> Result<Json> {
        let sid = p.get("session_id").and_then(|v| v.as_str()).ok_or_else(|| anyhow!("session_id"))?;
        let s = self.sessions.get(sid).ok_or_else(|| anyhow!("no session"))?;
        s.save()?;
        Ok(json!({ "ok": true }))
    }

    /// Clear outputs and execution_count for every cell in the session.
    /// Mirrors `jupyter nbconvert --clear-output` semantics.
    async fn clear_outputs(&self, p: Json) -> Result<Json> {
        let sid = p.get("session_id").and_then(|v| v.as_str()).ok_or_else(|| anyhow!("session_id"))?;
        let s = self.sessions.get(sid).ok_or_else(|| anyhow!("no session"))?.clone();
        s.clear_outputs();
        Ok(json!({ "ok": true }))
    }

    /// Clear outputs and execution_count of a single cell by id.
    async fn clear_cell_output(&self, p: Json) -> Result<Json> {
        let sid = p.get("session_id").and_then(|v| v.as_str()).ok_or_else(|| anyhow!("session_id"))?;
        let cell_id = p.get("cell_id").and_then(|v| v.as_str()).ok_or_else(|| anyhow!("cell_id"))?;
        let s = self.sessions.get(sid).ok_or_else(|| anyhow!("no session"))?.clone();
        s.clear_cell_output(cell_id);
        Ok(json!({ "ok": true }))
    }

    async fn save_as(&self, p: Json) -> Result<Json> {
        let sid = p.get("session_id").and_then(|v| v.as_str()).ok_or_else(|| anyhow!("session_id"))?;
        let path = arg_path(&p, "path")?;
        let s = self.sessions.get(sid).ok_or_else(|| anyhow!("no session"))?;
        s.save_to(&path)?;
        Ok(json!({ "ok": true }))
    }

    /// Tell the backend how kitty escapes should reach the user's terminal.
    /// `{ tty: "/dev/tty" }` (or no params) = local mode: backend writes
    /// directly to that TTY. `{ remote: true }` = remote mode: backend
    /// encodes escapes but returns them via RPC for the frontend to write
    /// to its own local /dev/tty. Frontend calls this once at startup.
    async fn kitty_attach(&self, p: Json) -> Result<Json> {
        let remote = p.get("remote").and_then(|v| v.as_bool()).unwrap_or(false);
        let mode = if remote {
            KittyMode::Remote
        } else {
            let path = p.get("tty").and_then(|v| v.as_str()).map(PathBuf::from);
            KittyMode::Local(LocalTty::open(path)?)
        };
        *self.kitty.lock().await = Some(mode);
        Ok(json!({ "ok": true, "remote": remote }))
    }

    /// Emit encoded kitty bytes: write to TTY in local mode, or return as
    /// `escape_b64` in remote mode. `base_response` is merged with the result.
    async fn emit_kitty(&self, bytes: Vec<u8>, mut base_response: serde_json::Map<String, Json>) -> Result<Json> {
        let kitty_lock = self.kitty.lock().await;
        match kitty_lock.as_ref() {
            None => Err(anyhow!("kitty_attach not called")),
            Some(KittyMode::Local(t)) => {
                t.write(&bytes)?;
                Ok(Json::Object(base_response))
            }
            Some(KittyMode::Remote) => {
                let escape_b64 = base64::engine::general_purpose::STANDARD.encode(&bytes);
                base_response.insert("escape_b64".into(), Json::String(escape_b64));
                Ok(Json::Object(base_response))
            }
        }
    }

    /// `a=t`: transmit only, no placement. Used for direct-placement
    /// renderer + GIF frame retransmits. Requires `image_id` (frontend-owned).
    async fn kitty_transmit_only(&self, p: Json) -> Result<Json> {
        let b64 = p.get("png_b64").and_then(|v| v.as_str())
            .ok_or_else(|| anyhow!("png_b64 required"))?;
        let id = p.get("image_id").and_then(|v| v.as_u64())
            .ok_or_else(|| anyhow!("image_id required"))? as u32;
        let png = base64::engine::general_purpose::STANDARD.decode(b64)
            .map_err(|e| anyhow!("base64 decode: {e}"))?;
        let bytes = kitty::encode_transmit_only(id, &png);
        let mut base = serde_json::Map::new();
        base.insert("image_id".into(), json!(id));
        self.emit_kitty(bytes, base).await
    }

    /// `a=T, U=1`: transmit + register for Unicode-placeholder placement.
    /// Requires `image_id`, `cols`, `rows`.
    async fn kitty_transmit_virtual(&self, p: Json) -> Result<Json> {
        let b64 = p.get("png_b64").and_then(|v| v.as_str())
            .ok_or_else(|| anyhow!("png_b64 required"))?;
        let id = p.get("image_id").and_then(|v| v.as_u64())
            .ok_or_else(|| anyhow!("image_id required"))? as u32;
        let cols = p.get("cols").and_then(|v| v.as_u64())
            .ok_or_else(|| anyhow!("cols required"))? as u32;
        let rows = p.get("rows").and_then(|v| v.as_u64())
            .ok_or_else(|| anyhow!("rows required"))? as u32;
        let png = base64::engine::general_purpose::STANDARD.decode(b64)
            .map_err(|e| anyhow!("base64 decode: {e}"))?;
        let bytes = kitty::encode_transmit_virtual(id, &png, cols, rows);
        let mut base = serde_json::Map::new();
        base.insert("image_id".into(), json!(id));
        self.emit_kitty(bytes, base).await
    }

    /// `a=p`: place an already-transmitted image. If `screen_row` and
    /// `screen_col` are provided, wraps with cursor save/move/restore so the
    /// place is atomic (no interleave with other terminal output).
    async fn kitty_place(&self, p: Json) -> Result<Json> {
        let image_id = p.get("image_id").and_then(|v| v.as_u64())
            .ok_or_else(|| anyhow!("image_id required"))? as u32;
        let placement_id = p.get("placement_id").and_then(|v| v.as_u64())
            .ok_or_else(|| anyhow!("placement_id required"))? as u32;
        let cols = p.get("cols").and_then(|v| v.as_u64())
            .ok_or_else(|| anyhow!("cols required"))? as u32;
        let rows = p.get("rows").and_then(|v| v.as_u64())
            .ok_or_else(|| anyhow!("rows required"))? as u32;
        let screen_row = p.get("screen_row").and_then(|v| v.as_u64()).map(|n| n as u32);
        let screen_col = p.get("screen_col").and_then(|v| v.as_u64()).map(|n| n as u32);
        let bytes = match (screen_row, screen_col) {
            (Some(r), Some(c)) => kitty::encode_place_at_screen(image_id, placement_id, cols, rows, r, c),
            _ => kitty::encode_place(image_id, placement_id, cols, rows),
        };
        self.emit_kitty(bytes, serde_json::Map::new()).await
    }

    /// `a=d, d=I`: delete image (and its placements). If `placement_id` is
    /// also given, delete only that placement (image data stays).
    async fn kitty_clear_image(&self, p: Json) -> Result<Json> {
        let image_id = p.get("image_id").and_then(|v| v.as_u64())
            .ok_or_else(|| anyhow!("image_id required"))? as u32;
        let bytes = match p.get("placement_id").and_then(|v| v.as_u64()) {
            Some(pid) => kitty::encode_delete_image_placement(image_id, pid as u32),
            None => kitty::encode_delete_image(image_id),
        };
        self.emit_kitty(bytes, serde_json::Map::new()).await
    }

    /// `a=d, d=a` (lowercase): clear visible placements only; image data stays.
    async fn kitty_clear_visible(&self, _p: Json) -> Result<Json> {
        let bytes = kitty::encode_delete_visible();
        self.emit_kitty(bytes, serde_json::Map::new()).await
    }

    /// `a=d, d=A` (uppercase): nuke all images and placements.
    async fn kitty_clear_all(&self, _p: Json) -> Result<Json> {
        let bytes = kitty::encode_delete_all();
        self.emit_kitty(bytes, serde_json::Map::new()).await
    }

    // ===========================================================
    // Filesystem RPCs (Phase 1 of v0.3 remote-workspace effort).
    //
    // All paths are absolute on the remote filesystem; the leading `~/` is
    // expanded to the server-process's $HOME. File contents are base64
    // (msgpack-safe binary transport — same trick we use for PNGs).
    // ===========================================================

    async fn fs_list(&self, p: Json) -> Result<Json> {
        use std::os::unix::fs::MetadataExt;
        let path = arg_path(&p, "path")?;
        // Build a gitignore matcher for this dir (walk up for .git + collect
        // .gitignore files between the repo root and here). Lets the frontend
        // hide gitignored entries by default with an `I` toggle, like snacks.
        let ignore_matcher = build_gitignore_matcher(&path);
        let mut rd = tokio::fs::read_dir(&path).await
            .with_context(|| format!("read_dir {}", path.display()))?;
        let mut entries = Vec::new();
        while let Some(entry) = rd.next_entry().await? {
            // Follow symlinks to determine "real" kind. A symlink to a dir
            // should browse like a dir; a symlink to a file should read like
            // a file. Fall back to symlink_metadata for broken symlinks so
            // they still show up (marked "link" so frontend can warn).
            let entry_path = entry.path();
            let target_meta = tokio::fs::metadata(&entry_path).await;
            let lnk_meta = tokio::fs::symlink_metadata(&entry_path).await;
            let (meta, is_link) = match (target_meta, lnk_meta) {
                (Ok(m), Ok(lm)) => (m, lm.file_type().is_symlink()),
                (Err(_), Ok(lm)) => (lm.clone(), lm.file_type().is_symlink()), // broken link
                (Ok(m), Err(_)) => (m, false),
                (Err(_), Err(_)) => continue,
            };
            let kind = if meta.is_dir() { "dir" }
                else if is_link { "link" }  // symlink whose target isn't a dir
                else { "file" };
            let mtime = meta.modified().ok()
                .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                .map(|d| d.as_secs() as i64).unwrap_or(0);
            let ignored = ignore_matcher.as_ref()
                .map(|m| m.matched(&entry_path, meta.is_dir()).is_ignore())
                .unwrap_or(false);
            entries.push(json!({
                "name": entry.file_name().to_string_lossy(),
                "kind": kind,
                "size": meta.len(),
                "mode": meta.mode() & 0o777,
                "mtime": mtime,
                "ignored": ignored,
            }));
        }
        // Sort: dirs first, then alphabetical
        entries.sort_by(|a, b| {
            let ak = a.get("kind").and_then(|v| v.as_str()).unwrap_or("");
            let bk = b.get("kind").and_then(|v| v.as_str()).unwrap_or("");
            let an = a.get("name").and_then(|v| v.as_str()).unwrap_or("");
            let bn = b.get("name").and_then(|v| v.as_str()).unwrap_or("");
            match (ak, bk) {
                ("dir", "dir") | ("file", "file") | ("link", "link") => an.cmp(bn),
                ("dir", _) => std::cmp::Ordering::Less,
                (_, "dir") => std::cmp::Ordering::Greater,
                _ => an.cmp(bn),
            }
        });
        Ok(json!({ "path": path.to_string_lossy(), "entries": entries }))
    }

    async fn fs_stat(&self, p: Json) -> Result<Json> {
        use std::os::unix::fs::MetadataExt;
        let path = arg_path(&p, "path")?;
        let meta = tokio::fs::symlink_metadata(&path).await
            .with_context(|| format!("stat {}", path.display()))?;
        let kind = if meta.is_dir() { "dir" }
            else if meta.file_type().is_symlink() { "link" }
            else { "file" };
        let mtime = meta.modified().ok()
            .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
            .map(|d| d.as_secs() as i64).unwrap_or(0);
        Ok(json!({
            "kind": kind,
            "size": meta.len(),
            "mode": meta.mode() & 0o777,
            "mtime": mtime,
        }))
    }

    async fn fs_read(&self, p: Json) -> Result<Json> {
        let path = arg_path(&p, "path")?;
        let bytes = tokio::fs::read(&path).await
            .with_context(|| format!("read {}", path.display()))?;
        let b64 = base64::engine::general_purpose::STANDARD.encode(&bytes);
        Ok(json!({ "content_b64": b64, "size": bytes.len() }))
    }

    async fn fs_write(&self, p: Json) -> Result<Json> {
        let path = arg_path(&p, "path")?;
        let b64 = p.get("content_b64").and_then(|v| v.as_str())
            .ok_or_else(|| anyhow!("content_b64 required"))?;
        let bytes = base64::engine::general_purpose::STANDARD.decode(b64)
            .map_err(|e| anyhow!("base64 decode: {e}"))?;
        if let Some(parent) = path.parent() {
            // Create parent dir if it doesn't exist (parents=true by default for writes)
            let _ = tokio::fs::create_dir_all(parent).await;
        }
        tokio::fs::write(&path, &bytes).await
            .with_context(|| format!("write {}", path.display()))?;
        Ok(json!({ "ok": true, "size": bytes.len() }))
    }

    async fn fs_mkdir(&self, p: Json) -> Result<Json> {
        let path = arg_path(&p, "path")?;
        let parents = p.get("parents").and_then(|v| v.as_bool()).unwrap_or(true);
        if parents {
            tokio::fs::create_dir_all(&path).await?;
        } else {
            tokio::fs::create_dir(&path).await?;
        }
        Ok(json!({ "ok": true }))
    }

    async fn fs_rm(&self, p: Json) -> Result<Json> {
        let path = arg_path(&p, "path")?;
        let recursive = p.get("recursive").and_then(|v| v.as_bool()).unwrap_or(false);
        let meta = tokio::fs::symlink_metadata(&path).await
            .with_context(|| format!("stat {}", path.display()))?;
        if meta.is_dir() && !meta.file_type().is_symlink() {
            if recursive {
                tokio::fs::remove_dir_all(&path).await?;
            } else {
                tokio::fs::remove_dir(&path).await?;
            }
        } else {
            tokio::fs::remove_file(&path).await?;
        }
        Ok(json!({ "ok": true }))
    }

    async fn fs_rename(&self, p: Json) -> Result<Json> {
        let src = arg_path(&p, "src")?;
        let dst = arg_path(&p, "dst")?;
        tokio::fs::rename(&src, &dst).await
            .with_context(|| format!("rename {} -> {}", src.display(), dst.display()))?;
        Ok(json!({ "ok": true }))
    }

    async fn fs_realpath(&self, p: Json) -> Result<Json> {
        let path = arg_path(&p, "path")?;
        let canonical = tokio::fs::canonicalize(&path).await
            .with_context(|| format!("realpath {}", path.display()))?;
        Ok(json!({ "path": canonical.to_string_lossy() }))
    }

    // ===========================================================
    // Process RPCs (Phase 3: remote terminals + tools)
    //
    // proc_spawn allocates a PTY pair and runs the requested command on the
    // slave side. The master fd stays here; a blocking reader task forwards
    // its output to the client as `proc_event` notifications (kind = stdout
    // for data, exit for the final exit code). The client sends keystrokes
    // back via proc_stdin and window-size changes via proc_resize.
    // ===========================================================

    async fn proc_spawn(self: Arc<Self>, p: Json) -> Result<Json> {
        use portable_pty::{native_pty_system, CommandBuilder, PtySize};
        let cmd_str = p.get("cmd").and_then(|v| v.as_str())
            .ok_or_else(|| anyhow!("cmd required"))?;
        let args: Vec<String> = p.get("args").and_then(|v| v.as_array())
            .map(|a| a.iter().filter_map(|x| x.as_str().map(String::from)).collect())
            .unwrap_or_default();
        let cwd = p.get("cwd").and_then(|v| v.as_str()).map(PathBuf::from);
        let cols = p.get("cols").and_then(|v| v.as_u64()).unwrap_or(80) as u16;
        let rows = p.get("rows").and_then(|v| v.as_u64()).unwrap_or(24) as u16;

        let pty_system = native_pty_system();
        let pair = pty_system.openpty(PtySize {
            rows, cols, pixel_width: 0, pixel_height: 0,
        }).map_err(|e| anyhow!("openpty: {e}"))?;

        let mut cmd = CommandBuilder::new(cmd_str);
        cmd.args(&args);
        // Pass through key env from the server's environment unless the client
        // overrode it. Without HOME/PATH a shell barely works.
        for (k, v) in std::env::vars() {
            cmd.env(&k, &v);
        }
        if let Some(env_obj) = p.get("env").and_then(|v| v.as_object()) {
            for (k, v) in env_obj {
                if let Some(s) = v.as_str() {
                    cmd.env(k, s);
                }
            }
        }
        if let Some(c) = cwd {
            cmd.cwd(c);
        } else if let Some(home) = dirs::home_dir() {
            cmd.cwd(home);
        }

        let child = pair.slave.spawn_command(cmd).map_err(|e| anyhow!("spawn: {e}"))?;
        drop(pair.slave);  // close our end of the slave fd
        let writer = pair.master.take_writer().map_err(|e| anyhow!("take_writer: {e}"))?;
        let reader = pair.master.try_clone_reader().map_err(|e| anyhow!("clone_reader: {e}"))?;

        let pid = self.next_proc_id.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let entry = Arc::new(ProcessEntry {
            pty: parking_lot::Mutex::new(pair.master),
            writer: parking_lot::Mutex::new(writer),
            child: parking_lot::Mutex::new(Some(child)),
        });
        self.procs.insert(pid, entry.clone());

        // Blocking reader: pumps PTY output as proc_event notifications.
        // Capture the tokio runtime handle BEFORE spawning the OS thread
        // (that thread is not part of the tokio runtime, so it can't lookup
        // the handle via Handle::current() itself).
        let rt_handle = tokio::runtime::Handle::current();
        let server_for_reader = self.clone();
        let entry_for_reader = entry.clone();
        std::thread::spawn(move || {
            use std::io::Read;
            let mut reader = reader;
            let mut buf = vec![0u8; 8192];
            loop {
                match reader.read(&mut buf) {
                    Ok(0) => break,
                    Ok(n) => {
                        let data = &buf[..n];
                        let b64 = base64::engine::general_purpose::STANDARD.encode(data);
                        let server = server_for_reader.clone();
                        rt_handle.spawn(async move {
                            server.notify("proc_event", json!({
                                "pid": pid,
                                "kind": "stdout",
                                "data_b64": b64,
                            })).await;
                        });
                    }
                    Err(_) => break,
                }
            }
            // PTY EOF → child has exited (or close enough)
            let exit_code = entry_for_reader.child.lock().take()
                .and_then(|mut c| c.wait().ok())
                .map(|s| s.exit_code() as i32)
                .unwrap_or(-1);
            let server = server_for_reader.clone();
            rt_handle.spawn(async move {
                server.notify("proc_event", json!({
                    "pid": pid,
                    "kind": "exit",
                    "code": exit_code,
                })).await;
                server.procs.remove(&pid);
            });
        });

        Ok(json!({ "pid": pid, "cols": cols, "rows": rows }))
    }

    async fn proc_stdin(&self, p: Json) -> Result<Json> {
        use std::io::Write;
        let pid = p.get("pid").and_then(|v| v.as_u64())
            .ok_or_else(|| anyhow!("pid required"))? as u32;
        let b64 = p.get("data_b64").and_then(|v| v.as_str())
            .ok_or_else(|| anyhow!("data_b64 required"))?;
        let bytes = base64::engine::general_purpose::STANDARD.decode(b64)
            .map_err(|e| anyhow!("base64: {e}"))?;
        let entry = self.procs.get(&pid)
            .ok_or_else(|| anyhow!("no process {pid}"))?
            .clone();
        let mut w = entry.writer.lock();
        w.write_all(&bytes).map_err(|e| anyhow!("write: {e}"))?;
        w.flush().ok();
        Ok(json!({ "ok": true }))
    }

    async fn proc_resize(&self, p: Json) -> Result<Json> {
        use portable_pty::PtySize;
        let pid = p.get("pid").and_then(|v| v.as_u64())
            .ok_or_else(|| anyhow!("pid required"))? as u32;
        let cols = p.get("cols").and_then(|v| v.as_u64()).unwrap_or(80) as u16;
        let rows = p.get("rows").and_then(|v| v.as_u64()).unwrap_or(24) as u16;
        let entry = self.procs.get(&pid)
            .ok_or_else(|| anyhow!("no process {pid}"))?
            .clone();
        entry.pty.lock().resize(PtySize {
            rows, cols, pixel_width: 0, pixel_height: 0,
        }).map_err(|e| anyhow!("resize: {e}"))?;
        Ok(json!({ "ok": true }))
    }

    async fn proc_kill(&self, p: Json) -> Result<Json> {
        let pid = p.get("pid").and_then(|v| v.as_u64())
            .ok_or_else(|| anyhow!("pid required"))? as u32;
        let entry = self.procs.get(&pid)
            .ok_or_else(|| anyhow!("no process {pid}"))?
            .clone();
        if let Some(child) = entry.child.lock().as_mut() {
            let _ = child.kill();
        }
        Ok(json!({ "ok": true }))
    }

    // ===========================================================
    // Search (Phase 4: ripgrep-equivalent over remote files)
    //
    // Walks the directory tree (gitignore-aware via the `ignore` crate)
    // and matches each line against a regex. Returns matches as quickfix-
    // friendly { path, line, col, text } objects. Single-shot for now;
    // streaming variant can land later if large searches become a problem.
    // ===========================================================
    async fn search(&self, p: Json) -> Result<Json> {
        let root = arg_path(&p, "path")?;
        let pattern = p.get("pattern").and_then(|v| v.as_str())
            .ok_or_else(|| anyhow!("pattern required"))?
            .to_string();
        let max = p.get("max").and_then(|v| v.as_u64()).unwrap_or(2000) as usize;
        let case_sensitive = p.get("case_sensitive").and_then(|v| v.as_bool()).unwrap_or(false);
        let fixed_string = p.get("fixed_string").and_then(|v| v.as_bool()).unwrap_or(false);

        // Build regex (escape if fixed_string mode)
        let raw = if fixed_string { regex::escape(&pattern) } else { pattern.clone() };
        let regex = regex::RegexBuilder::new(&raw)
            .case_insensitive(!case_sensitive)
            .build()
            .map_err(|e| anyhow!("bad regex: {e}"))?;

        // Walk + match in a blocking task (filesystem I/O + CPU bound).
        let matches = tokio::task::spawn_blocking(move || {
            let mut out = Vec::new();
            let walker = ignore::WalkBuilder::new(&root)
                .hidden(false)       // include dotfiles (match common ripgrep -uu)
                .follow_links(true)  // symlinked dirs are common on HPC homes
                .ignore(true)        // respect .ignore
                .git_ignore(true)    // respect .gitignore
                .git_global(false)
                .git_exclude(true)
                .build();
            for entry_result in walker {
                if out.len() >= max { break; }
                let entry = match entry_result { Ok(e) => e, Err(_) => continue };
                if !entry.file_type().map_or(false, |t| t.is_file()) { continue; }
                let path = entry.path().to_path_buf();
                let content = match std::fs::read_to_string(&path) {
                    Ok(c) => c, Err(_) => continue,
                };
                for (idx, line) in content.lines().enumerate() {
                    if let Some(m) = regex.find(line) {
                        out.push(json!({
                            "path": path.to_string_lossy(),
                            "line": idx + 1,
                            "col": m.start() + 1,
                            "text": line,
                        }));
                        if out.len() >= max { break; }
                    }
                }
            }
            out
        }).await.map_err(|e| anyhow!("search task: {e}"))?;

        let truncated = matches.len() >= max;
        Ok(json!({ "matches": matches, "truncated": truncated }))
    }

    // List files under `path` (recursive, respecting .gitignore) for a remote
    // file picker. Returns paths relative to `path` plus the absolute root, so
    // the frontend can build jupynvim:// URIs. Files only; capped by `max`.
    // `excludes` (dir/file names) prunes bulk junk so a $HOME scan isn't
    // dominated by conda installs and __pycache__.
    async fn find_files(&self, p: Json) -> Result<Json> {
        let root = arg_path(&p, "path")?;
        let max = p.get("max").and_then(|v| v.as_u64()).unwrap_or(20000) as usize;
        let include_hidden = p.get("hidden").and_then(|v| v.as_bool()).unwrap_or(false);
        let excludes: std::collections::HashSet<String> = p.get("excludes")
            .and_then(|v| v.as_array())
            .map(|a| a.iter().filter_map(|x| x.as_str().map(String::from)).collect())
            .unwrap_or_default();
        let root2 = root.clone();
        let files = tokio::task::spawn_blocking(move || {
            let mut out: Vec<String> = Vec::new();
            let mut builder = ignore::WalkBuilder::new(&root2);
            builder
                .hidden(!include_hidden)
                .follow_links(true) // HPC homes are full of symlinked dirs (e.g. ~/github)
                .ignore(true)
                .git_ignore(true)
                .git_global(false)
                .git_exclude(true);
            if !excludes.is_empty() {
                builder.filter_entry(move |e| {
                    e.file_name().to_str().map_or(true, |n| !excludes.contains(n))
                });
            }
            for entry_result in builder.build() {
                if out.len() >= max { break; }
                let entry = match entry_result { Ok(e) => e, Err(_) => continue };
                if !entry.file_type().map_or(false, |t| t.is_file()) { continue; }
                if let Ok(rel) = entry.path().strip_prefix(&root2) {
                    out.push(rel.to_string_lossy().to_string());
                }
            }
            out
        }).await.map_err(|e| anyhow!("find_files task: {e}"))?;
        let truncated = files.len() >= max;
        Ok(json!({ "root": root.to_string_lossy(), "files": files, "truncated": truncated }))
    }

    // ===========================================================
    // File watching (Phase 5)
    //
    // fs_watch starts an OS-native filesystem watcher (FSEvent on macOS,
    // inotify on Linux). Change events are pushed as `fs_event` notifications
    // until the client calls fs_unwatch with the returned watcher_id.
    // ===========================================================
    async fn fs_watch(self: Arc<Self>, p: Json) -> Result<Json> {
        use notify::{Watcher, RecursiveMode};
        let path = arg_path(&p, "path")?;
        let recursive = p.get("recursive").and_then(|v| v.as_bool()).unwrap_or(true);
        let mode = if recursive { RecursiveMode::Recursive } else { RecursiveMode::NonRecursive };

        let watcher_id = self.next_watcher_id.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let rt_handle = tokio::runtime::Handle::current();
        let server = self.clone();
        let mut watcher: notify::RecommendedWatcher = notify::recommended_watcher(
            move |res: notify::Result<notify::Event>| {
                if let Ok(event) = res {
                    // Coarse kind classification — frontends mostly just
                    // need "something changed, reload" anyway.
                    let kind = match event.kind {
                        notify::EventKind::Create(_) => "create",
                        notify::EventKind::Modify(_) => "modify",
                        notify::EventKind::Remove(_) => "remove",
                        _ => "other",
                    };
                    let paths: Vec<String> = event.paths.iter()
                        .map(|p| p.to_string_lossy().to_string())
                        .collect();
                    let server = server.clone();
                    rt_handle.spawn(async move {
                        server.notify("fs_event", json!({
                            "watcher_id": watcher_id,
                            "kind": kind,
                            "paths": paths,
                        })).await;
                    });
                }
            }
        ).map_err(|e| anyhow!("watcher init: {e}"))?;
        watcher.watch(&path, mode).map_err(|e| anyhow!("watch: {e}"))?;
        self.watchers.insert(watcher_id, watcher);
        Ok(json!({ "watcher_id": watcher_id, "path": path.to_string_lossy() }))
    }

    async fn fs_unwatch(&self, p: Json) -> Result<Json> {
        let id = p.get("watcher_id").and_then(|v| v.as_u64())
            .ok_or_else(|| anyhow!("watcher_id required"))? as u32;
        self.watchers.remove(&id);
        Ok(json!({ "ok": true }))
    }

    // ===========================================================
    // Generic command runner (Phase 6 support): used by the frontend for LSP
    // binary checks (`command -v`) and zero-manual provisioning (running an
    // install recipe). Captures output; not interactive.
    // ===========================================================
    async fn run_cmd(&self, p: Json) -> Result<Json> {
        let argv: Vec<String> = p.get("argv").and_then(|v| v.as_array())
            .map(|a| a.iter().filter_map(|x| x.as_str().map(String::from)).collect())
            .ok_or_else(|| anyhow!("argv required"))?;
        if argv.is_empty() { return Err(anyhow!("argv empty")); }
        let mut cmd = tokio::process::Command::new(&argv[0]);
        cmd.args(&argv[1..]);
        if let Some(cwd) = p.get("cwd").and_then(|v| v.as_str()) {
            let path = if let Some(rest) = cwd.strip_prefix("~/") {
                dirs::home_dir().map(|h| h.join(rest)).unwrap_or_else(|| PathBuf::from(cwd))
            } else { PathBuf::from(cwd) };
            if path.exists() { cmd.current_dir(path); }
        }
        // Run through a login shell context isn't needed; inherit our env
        // (which sshd's login shell set up, incl. module loads / conda).
        let out = cmd.output().await
            .with_context(|| format!("run {:?}", argv))?;
        Ok(json!({
            "code": out.status.code().unwrap_or(-1),
            "stdout": String::from_utf8_lossy(&out.stdout),
            "stderr": String::from_utf8_lossy(&out.stderr),
        }))
    }

    // ===========================================================
    // LSP relay (Phase 6): spawn a language server on the remote with raw
    // stdio, translate between its Content-Length framed JSON-RPC and the
    // frontend's plain-JSON msgpack. The backend owns framing; the Lua side
    // speaks JSON-RPC tables and does URI rewriting.
    // ===========================================================
    async fn lsp_start(self: Arc<Self>, p: Json) -> Result<Json> {
        use tokio::process::Command;
        let argv: Vec<String> = p.get("cmd").and_then(|v| v.as_array())
            .map(|a| a.iter().filter_map(|x| x.as_str().map(String::from)).collect())
            .ok_or_else(|| anyhow!("cmd required"))?;
        if argv.is_empty() { return Err(anyhow!("cmd empty")); }
        let mut cmd = Command::new(&argv[0]);
        cmd.args(&argv[1..]);
        if let Some(cwd) = p.get("cwd").and_then(|v| v.as_str()) {
            let path = if let Some(rest) = cwd.strip_prefix("~/") {
                dirs::home_dir().map(|h| h.join(rest)).unwrap_or_else(|| PathBuf::from(cwd))
            } else { PathBuf::from(cwd) };
            if path.exists() { cmd.current_dir(path); }
        }
        if let Some(env_obj) = p.get("env").and_then(|v| v.as_object()) {
            for (k, v) in env_obj {
                if let Some(s) = v.as_str() { cmd.env(k, s); }
            }
        }
        cmd.stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .kill_on_drop(true);
        let mut child = cmd.spawn().with_context(|| format!("spawn lsp {:?}", argv))?;
        let stdout = child.stdout.take().ok_or_else(|| anyhow!("no lsp stdout"))?;
        let stderr = child.stderr.take().ok_or_else(|| anyhow!("no lsp stderr"))?;
        let stdin = child.stdin.take().ok_or_else(|| anyhow!("no lsp stdin"))?;

        let lsp_id = self.next_lsp_id.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let entry = Arc::new(LspEntry {
            child: parking_lot::Mutex::new(child),
            stdin: tokio::sync::Mutex::new(stdin),
        });
        self.lsps.insert(lsp_id, entry);

        // Reader: parse Content-Length framing → emit each JSON message.
        let server = self.clone();
        tokio::spawn(async move {
            use tokio::io::AsyncReadExt;
            let mut reader = stdout;
            let mut buf: Vec<u8> = Vec::with_capacity(16 * 1024);
            let mut chunk = [0u8; 8192];
            loop {
                match reader.read(&mut chunk).await {
                    Ok(0) => break,
                    Ok(n) => buf.extend_from_slice(&chunk[..n]),
                    Err(_) => break,
                }
                // Drain complete framed messages from buf.
                loop {
                    // find header terminator
                    let hdr_end = match find_subslice(&buf, b"\r\n\r\n") {
                        Some(i) => i,
                        None => break,
                    };
                    let header = String::from_utf8_lossy(&buf[..hdr_end]);
                    let len: usize = header.lines()
                        .find_map(|l| l.to_ascii_lowercase().strip_prefix("content-length:")
                            .map(|v| v.trim().to_string()))
                        .and_then(|v| v.parse().ok())
                        .unwrap_or(0);
                    let body_start = hdr_end + 4;
                    if buf.len() < body_start + len { break; } // wait for full body
                    let body = buf[body_start..body_start + len].to_vec();
                    buf.drain(..body_start + len);
                    if let Ok(val) = serde_json::from_slice::<Json>(&body) {
                        server.notify("lsp_message", json!({ "lsp_id": lsp_id, "message": val })).await;
                    }
                }
            }
            server.notify("lsp_message", json!({ "lsp_id": lsp_id, "exit": true })).await;
            server.lsps.remove(&lsp_id);
        });

        // stderr → log (servers chatter there; surface only in logs)
        tokio::spawn(async move {
            use tokio::io::{AsyncBufReadExt, BufReader};
            let mut lines = BufReader::new(stderr).lines();
            while let Ok(Some(line)) = lines.next_line().await {
                tracing::debug!("lsp[{}] stderr: {}", lsp_id, line);
            }
        });

        Ok(json!({ "lsp_id": lsp_id }))
    }

    async fn lsp_send(&self, p: Json) -> Result<Json> {
        use tokio::io::AsyncWriteExt;
        let lsp_id = p.get("lsp_id").and_then(|v| v.as_u64())
            .ok_or_else(|| anyhow!("lsp_id required"))? as u32;
        let msg = p.get("message").ok_or_else(|| anyhow!("message required"))?;
        let body = serde_json::to_vec(msg)?;
        let entry = self.lsps.get(&lsp_id)
            .ok_or_else(|| anyhow!("no lsp {lsp_id}"))?
            .clone();
        let framed = format!("Content-Length: {}\r\n\r\n", body.len());
        let mut w = entry.stdin.lock().await;
        w.write_all(framed.as_bytes()).await.map_err(|e| anyhow!("lsp stdin: {e}"))?;
        w.write_all(&body).await.map_err(|e| anyhow!("lsp stdin: {e}"))?;
        w.flush().await.ok();
        Ok(json!({ "ok": true }))
    }

    async fn lsp_stop(&self, p: Json) -> Result<Json> {
        let lsp_id = p.get("lsp_id").and_then(|v| v.as_u64())
            .ok_or_else(|| anyhow!("lsp_id required"))? as u32;
        if let Some((_, entry)) = self.lsps.remove(&lsp_id) {
            let _ = entry.child.lock().start_kill();
        }
        Ok(json!({ "ok": true }))
    }

    async fn notify(&self, method: &str, params: Json) {
        let msg = Mp::Array(vec![
            Mp::from(2u32),
            Mp::String(method.to_string().into()),
            Mp::Array(vec![json_to_mp(&params)]),
        ]);
        self.send(msg).await;
    }
}

// rmpv <-> serde_json conversion
pub fn mp_to_json(v: &Mp) -> Json {
    match v {
        Mp::Nil => Json::Null,
        Mp::Boolean(b) => Json::Bool(*b),
        Mp::Integer(i) => i
            .as_i64()
            .map(Json::from)
            .or_else(|| i.as_u64().map(Json::from))
            .or_else(|| i.as_f64().and_then(serde_json::Number::from_f64).map(Json::Number))
            .unwrap_or(Json::Null),
        Mp::F32(f) => serde_json::Number::from_f64(*f as f64)
            .map(Json::Number)
            .unwrap_or(Json::Null),
        Mp::F64(f) => serde_json::Number::from_f64(*f)
            .map(Json::Number)
            .unwrap_or(Json::Null),
        Mp::String(s) => Json::String(s.as_str().unwrap_or("").to_string()),
        Mp::Binary(b) => Json::String(base64::Engine::encode(&base64::engine::general_purpose::STANDARD, b)),
        Mp::Array(a) => Json::Array(a.iter().map(mp_to_json).collect()),
        Mp::Map(m) => {
            let mut out = serde_json::Map::with_capacity(m.len());
            for (k, v) in m {
                let key = match k {
                    Mp::String(s) => s.as_str().unwrap_or("").to_string(),
                    other => format!("{other:?}"),
                };
                out.insert(key, mp_to_json(v));
            }
            Json::Object(out)
        }
        Mp::Ext(_, _) => Json::Null,
    }
}

/// Extract a path field from RPC params, expanding `~/` to $HOME on the
/// server side. Lets clients send `~/foo` without worrying about the home
/// path of the remote user.
fn arg_path(p: &Json, key: &str) -> Result<PathBuf> {
    let s = p.get(key).and_then(|v| v.as_str())
        .ok_or_else(|| anyhow!("{key} required"))?;
    // Accept ~/foo, ~ , /~/foo (the URI parser may leave a leading /). All
    // resolve to the server-process's home dir.
    let stripped = s.strip_prefix("/~/").or_else(|| s.strip_prefix("~/"));
    if let Some(rest) = stripped {
        if let Some(home) = dirs::home_dir() {
            return Ok(home.join(rest));
        }
    } else if s == "~" || s == "/~" {
        if let Some(home) = dirs::home_dir() {
            return Ok(home);
        }
    }
    Ok(PathBuf::from(s))
}

/// Build a gitignore matcher for `dir`: find the nearest enclosing git repo
/// (walk up for a `.git`), then add every `.gitignore` from the repo root down
/// to `dir`. Returns None if `dir` isn't inside a git repo. Used by fs_list to
/// flag ignored entries so the explorer can hide them by default.
fn build_gitignore_matcher(dir: &std::path::Path) -> Option<ignore::gitignore::Gitignore> {
    // Locate repo root (nearest ancestor containing .git).
    let mut root = None;
    let mut cur = Some(dir);
    while let Some(d) = cur {
        if d.join(".git").exists() {
            root = Some(d.to_path_buf());
            break;
        }
        cur = d.parent();
    }
    let root = root?;
    // Collect ancestor dirs from root → dir (so deeper .gitignores win).
    let mut chain = Vec::new();
    let mut c = Some(dir);
    while let Some(d) = c {
        chain.push(d.to_path_buf());
        if d == root { break; }
        c = d.parent();
    }
    chain.reverse();
    let mut builder = ignore::gitignore::GitignoreBuilder::new(&root);
    for d in &chain {
        let gi = d.join(".gitignore");
        if gi.exists() {
            let _ = builder.add(gi);
        }
    }
    // Always ignore the .git dir itself.
    let _ = builder.add_line(None, ".git/");
    builder.build().ok()
}

/// Find the first index of `needle` in `hay` (for LSP Content-Length framing).
fn find_subslice(hay: &[u8], needle: &[u8]) -> Option<usize> {
    if needle.is_empty() || hay.len() < needle.len() { return None; }
    hay.windows(needle.len()).position(|w| w == needle)
}

pub fn json_to_mp(v: &Json) -> Mp {
    match v {
        Json::Null => Mp::Nil,
        Json::Bool(b) => Mp::Boolean(*b),
        Json::Number(n) => {
            if let Some(i) = n.as_i64() {
                Mp::from(i)
            } else if let Some(u) = n.as_u64() {
                Mp::from(u)
            } else if let Some(f) = n.as_f64() {
                Mp::F64(f)
            } else {
                Mp::Nil
            }
        }
        Json::String(s) => Mp::String(s.clone().into()),
        Json::Array(a) => Mp::Array(a.iter().map(json_to_mp).collect()),
        Json::Object(o) => Mp::Map(o.iter().map(|(k, v)| (Mp::String(k.clone().into()), json_to_mp(v))).collect()),
    }
}
