// msgpack-rpc over stdio.
// Frame layout (Neovim style):
//   Request:      [0, msgid, method, params]
//   Response:     [1, msgid, error|nil, result|nil]
//   Notification: [2, method, params]

use anyhow::{anyhow, Result};
use dashmap::DashMap;
use rmpv::Value as Mp;
use serde_json::{json, Value as Json};
use std::path::PathBuf;
use std::sync::Arc;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::sync::{Mutex, Notify};

use crate::kitty::KittyMode;
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
    /// Bumped per search request; in-flight walks quit when superseded
    /// (live grep types faster than a big NFS walk finishes).
    search_epoch: Arc<std::sync::atomic::AtomicU64>,
    /// At most ONE filesystem walk at a time. Overlapping walks (rapid live
    /// grep keystrokes) saturate the NFS client's request slots and make
    /// everything crawl; the epoch pre-cancels the old walk, this makes the
    /// new one wait for the old one's threads to actually drain.
    search_lock: Arc<tokio::sync::Semaphore>,
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

mod exec;
mod fs;
mod graphics;
mod lsp;
mod notebook;
mod proc;
mod search;

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
            search_epoch: Arc::new(std::sync::atomic::AtomicU64::new(0)),
            search_lock: Arc::new(tokio::sync::Semaphore::new(1)),
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

        // Wake on any of: explicit shutdown, the frontend disconnecting (stdin
        // EOF ends the reader), the writer dying, or a termination signal.
        // Closing a terminal sends SIGHUP; `kill` sends SIGTERM. Without these
        // handlers the default action kills core instantly, no destructors run,
        // and the kernel is orphaned (it lingers as a PPID-1 ipykernel proc).
        let mut sigterm = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())?;
        let mut sighup = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::hangup())?;
        tokio::select! {
            _ = self.shutdown.notified() => tracing::info!("shutdown requested"),
            _ = reader => tracing::info!("frontend disconnected (stdin closed)"),
            _ = writer => tracing::info!("writer task ended"),
            _ = sigterm.recv() => tracing::info!("received SIGTERM"),
            _ = sighup.recv() => tracing::info!("received SIGHUP"),
        }

        // Kill every kernel now, while the runtime is alive. Doing it here is
        // deterministic; Child::kill_on_drop during runtime teardown is not.
        self.shutdown_kernels().await;
        Ok(())
    }

    /// Kill every session's kernel so none is left orphaned when core exits.
    async fn shutdown_kernels(&self) {
        // Snapshot the session handles first so we don't hold DashMap shard
        // guards across .await.
        let sessions: Vec<Arc<Session>> =
            self.sessions.iter().map(|e| e.value().clone()).collect();
        let mut killed = 0;
        for s in sessions {
            let guard = s.kernel.read().await;
            if let Some(k) = guard.as_ref() {
                if let Err(e) = k.kill().await {
                    tracing::warn!("kill kernel on shutdown: {e}");
                } else {
                    killed += 1;
                }
            }
        }
        if killed > 0 {
            tracing::info!("killed {killed} kernel(s) on shutdown");
        }
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
            "list_kernels" => self.list_kernels(p),
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
            "kitty_place_virtual" => self.kitty_place_virtual(p).await,
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
            "search_stream" => self.search_stream(p).await,
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
pub(super) fn arg_path(p: &Json, key: &str) -> Result<PathBuf> {
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
pub(super) fn build_gitignore_matcher(dir: &std::path::Path) -> Option<ignore::gitignore::Gitignore> {
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
pub(super) fn find_subslice(hay: &[u8], needle: &[u8]) -> Option<usize> {
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
