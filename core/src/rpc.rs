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
}

impl Server {
    pub fn new() -> Arc<Self> {
        Arc::new(Self {
            sessions: DashMap::new(),
            out_tx: Mutex::new(None),
            shutdown: Arc::new(Notify::new()),
            kitty: Mutex::new(None),
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
            other => Err(anyhow!("unknown method '{other}'")),
        }
    }

    // ---- handlers ----

    fn list_kernels(&self) -> Result<Json> {
        let specs = kernelspec::discover_all();
        Ok(serde_json::to_value(specs)?)
    }

    async fn open(&self, p: Json) -> Result<Json> {
        let path = p
            .get("path")
            .and_then(|v| v.as_str())
            .ok_or_else(|| anyhow!("path required"))?;
        let id = Uuid::new_v4().to_string();
        let session = Session::open(id.clone(), PathBuf::from(path))?;
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
        let path = p.get("path").and_then(|v| v.as_str()).ok_or_else(|| anyhow!("path"))?;
        let s = self.sessions.get(sid).ok_or_else(|| anyhow!("no session"))?;
        s.save_to(&PathBuf::from(path))?;
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
