//! Language-server proxy RPCs.

use anyhow::{anyhow, Context, Result};
use serde_json::{json, Value as Json};
use std::path::PathBuf;
use std::sync::Arc;

use super::{find_subslice, LspEntry, Server};

impl Server {
    // ===========================================================
    // LSP relay (Phase 6): spawn a language server on the remote with raw
    // stdio, translate between its Content-Length framed JSON-RPC and the
    // frontend's plain-JSON msgpack. The backend owns framing; the Lua side
    // speaks JSON-RPC tables and does URI rewriting.
    // ===========================================================
    pub(super) async fn lsp_start(self: Arc<Self>, p: Json) -> Result<Json> {
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

    pub(super) async fn lsp_send(&self, p: Json) -> Result<Json> {
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

    pub(super) async fn lsp_stop(&self, p: Json) -> Result<Json> {
        let lsp_id = p.get("lsp_id").and_then(|v| v.as_u64())
            .ok_or_else(|| anyhow!("lsp_id required"))? as u32;
        if let Some((_, entry)) = self.lsps.remove(&lsp_id) {
            let _ = entry.child.lock().start_kill();
        }
        Ok(json!({ "ok": true }))
    }
}
