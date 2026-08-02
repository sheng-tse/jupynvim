//! PTY process RPCs and one-shot command execution.

use anyhow::{anyhow, Context, Result};
use base64::Engine as _;
use serde_json::{json, Value as Json};
use std::path::PathBuf;
use std::sync::Arc;

use super::{ProcessEntry, Server};

impl Server {
    pub(super) async fn proc_spawn(self: Arc<Self>, p: Json) -> Result<Json> {
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

    pub(super) async fn proc_stdin(&self, p: Json) -> Result<Json> {
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

    pub(super) async fn proc_resize(&self, p: Json) -> Result<Json> {
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

    pub(super) async fn proc_kill(&self, p: Json) -> Result<Json> {
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
    // Generic command runner (Phase 6 support): used by the frontend for LSP
    // binary checks (`command -v`) and zero-manual provisioning (running an
    // install recipe). Captures output; not interactive.
    // ===========================================================
    pub(super) async fn run_cmd(&self, p: Json) -> Result<Json> {
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
}
