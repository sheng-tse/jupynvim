//! Kernel lifecycle and code execution RPCs.

use anyhow::{anyhow, Context, Result};
use serde_json::{json, Value as Json};
use std::path::PathBuf;
use std::sync::Arc;

use super::Server;
use crate::kernel::Kernel;
use crate::kernelspec;

impl Server {
    pub(super) fn list_kernels(&self, p: Json) -> Result<Json> {
        // Optional `dir` (a notebook's directory): include kernels from
        // project-local venvs (.venv/venv/env walking up) in the listing.
        let dir = p
            .get("dir")
            .and_then(|v| v.as_str())
            .map(|s| {
                if let Some(rest) = s.strip_prefix("~/") {
                    dirs::home_dir().map(|h| h.join(rest)).unwrap_or_else(|| PathBuf::from(s))
                } else {
                    PathBuf::from(s)
                }
            });
        let specs = kernelspec::discover_for_dir(dir.as_deref());
        Ok(serde_json::to_value(specs)?)
    }

    pub(super) async fn start_kernel(self: Arc<Self>, p: Json) -> Result<Json> {
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
            let explicit = p.get("kernel_name").and_then(|v| v.as_str());
            let nb_dir = session.path.parent().map(|d| d.to_path_buf());
            let language = session.notebook.read().kernel_language();
            // Auto-venv (backend side, so it works for REMOTE notebooks too):
            // with no explicitly chosen kernel and a python notebook, a
            // project-local venv (.venv/venv/env walking up from the notebook)
            // takes priority — same semantics as the frontend's local .venv
            // detection. Explicit picker choices always win.
            let auto_venv = p.get("auto_venv").and_then(|v| v.as_bool()).unwrap_or(false);
            let is_python = language.as_deref().map_or(true, |l| l.eq_ignore_ascii_case("python"));
            let auto = if explicit.is_none() && auto_venv && is_python {
                nb_dir.as_deref().and_then(kernelspec::closest_project_python_kernel)
            } else {
                None
            };
            if let Some(spec) = auto {
                tracing::info!("auto_venv: using {}", spec.argv.first().map(|s| s.as_str()).unwrap_or("?"));
                spec
            } else {
                // Pick kernel: explicit > metadata > python3
                let name = explicit
                    .map(|s| s.to_string())
                    .or_else(|| session.notebook.read().kernel_name())
                    .unwrap_or_else(|| "python3".to_string());
                // Resolve with version-tolerant fallback so a notebook saved
                // with kernelspec name "julia" or "julia-1.10" still opens on
                // a machine with only julia-1.12. Resolution includes
                // project-venv kernels for this notebook's dir, so names
                // chosen in the picker (e.g. "python3-myproj-.venv") start.
                kernelspec::discover_with_fallback_in(&name, language.as_deref(), nb_dir.as_deref())
                    .ok_or_else(|| anyhow!("no kernelspec found for '{name}' (and no fallback by language)"))?
            }
        };

        // Synthesized env kernels (env listed without ipykernel): make sure
        // ipykernel is importable, installing it into the env on first use.
        // Zero-setup parity with VSCode's "install ipykernel?" flow, minus
        // the prompt. One-time per env; a normal start after that.
        if spec
            .metadata
            .pointer("/jupynvim/ensure_ipykernel")
            .and_then(|v| v.as_bool())
            .unwrap_or(false)
        {
            if let Some(py) = spec.argv.first().cloned() {
                let probe = tokio::process::Command::new(&py)
                    .args(["-c", "import ipykernel"])
                    .output()
                    .await;
                let have = matches!(probe, Ok(ref o) if o.status.success());
                if !have {
                    tracing::info!("installing ipykernel into {}", py);
                    self.notify("user_message", json!({
                        "level": "info",
                        "text": format!("installing ipykernel into this env (one-time, can take a minute)...\n  {py}"),
                    })).await;
                    let out = tokio::process::Command::new(&py)
                        .args(["-m", "pip", "install", "ipykernel"])
                        .output()
                        .await
                        .with_context(|| format!("running {py} -m pip install ipykernel"))?;
                    if !out.status.success() {
                        return Err(anyhow!(
                            "auto-install of ipykernel into this env failed:\n{}",
                            String::from_utf8_lossy(&out.stderr)
                        ));
                    }
                    self.notify("user_message", json!({
                        "level": "info",
                        "text": "ipykernel installed; starting kernel...",
                    })).await;
                }
            }
        }

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

    pub(super) async fn stop_kernel(&self, p: Json) -> Result<Json> {
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

    pub(super) async fn interrupt_kernel(&self, p: Json) -> Result<Json> {
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

    pub(super) async fn restart_kernel(self: Arc<Self>, p: Json) -> Result<Json> {
        self.stop_kernel(p.clone()).await.ok();
        self.start_kernel(p).await
    }

    pub(super) async fn execute(&self, p: Json) -> Result<Json> {
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
    pub(super) async fn execute_silent(&self, p: Json) -> Result<Json> {
        let sid = p.get("session_id").and_then(|v| v.as_str()).ok_or_else(|| anyhow!("session_id"))?;
        let code = p.get("code").and_then(|v| v.as_str()).ok_or_else(|| anyhow!("code"))?;
        let session = self.sessions.get(sid).ok_or_else(|| anyhow!("no session"))?.clone();
        let guard = session.kernel.read().await;
        let kernel = guard.as_ref().ok_or_else(|| anyhow!("kernel not started"))?;
        let msg_id = uuid::Uuid::new_v4().to_string();
        kernel.execute_with_id_opts(code, msg_id.clone(), true, false).await?;
        Ok(json!({ "msg_id": msg_id }))
    }

    pub(super) async fn complete(&self, p: Json) -> Result<Json> {
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

    pub(super) async fn inspect(&self, p: Json) -> Result<Json> {
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
}
