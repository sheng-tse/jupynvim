//! Kernel lifecycle and code execution RPCs.

use anyhow::{anyhow, Context, Result};
use serde_json::{json, Value as Json};
use std::path::PathBuf;
use std::sync::Arc;

use super::Server;
use crate::kernel::Kernel;
use crate::kernelspec;
use crate::widgets::Effect;

/// The kernelspec for an interpreter handed over as `python_path`. Nothing is
/// registered for it: argv launches `python -m ipykernel_launcher` with the
/// usual `{connection_file}` substitution, the way `ipykernel install` writes
/// one. An interpreter under a `.pixi` directory belongs to a Pixi env and is
/// named so (`pixi-python`, shown as "Python (Pixi)"); any other is a venv
/// (`venv-python`, "Python (venv)"). `path` is the env root: the
/// interpreter's directory, or its parent when that is `bin` or `Scripts`
/// (Pixi puts `python.exe` at the root of the env on Windows).
fn python_path_spec(py: String) -> kernelspec::KernelSpec {
    let path_buf = std::path::PathBuf::from(&py);
    let dir = path_buf.parent();
    let in_bin = dir
        .and_then(|d| d.file_name())
        .map_or(false, |n| n == "bin" || n.to_string_lossy().eq_ignore_ascii_case("Scripts"));
    let root = if in_bin { dir.and_then(|d| d.parent()) } else { dir }
        .map(|p| p.to_path_buf())
        .unwrap_or_else(|| path_buf.clone());
    // Identify Pixi environments from the interpreter path.
    let is_pixi = path_buf
        .components()
        .any(|component| component.as_os_str() == ".pixi");
    let (name, display_name) = if is_pixi {
        ("pixi-python", "Python (Pixi)")
    } else {
        ("venv-python", "Python (venv)")
    };
    kernelspec::KernelSpec {
        name: name.to_string(),
        path: root,
        argv: vec![
            py,
            "-m".to_string(),
            "ipykernel_launcher".to_string(),
            "-f".to_string(),
            "{connection_file}".to_string(),
        ],
        display_name: display_name.to_string(),
        language: "python".to_string(),
        interrupt_mode: None,
        env: std::collections::HashMap::new(),
        metadata: serde_json::Value::Null,
    }
}

impl Server {
    pub(super) fn list_kernels(&self, p: Json) -> Result<Json> {
        // Optional `dir` (a notebook's directory): include kernels from
        // project-local envs (.venv/venv/env and Pixi's default env, walking
        // up) in the listing.
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
        // uses this to point at a project-local .venv/bin/python (or a Pixi
        // env's python) without requiring
        // `python -m ipykernel install --user --name foo` first.
        // Constructed kernelspec mimics what `ipykernel install` would
        // produce: argv launches python -m ipykernel_launcher with the
        // standard {connection_file} substitution.
        let spec = if let Some(py) = p.get("python_path").and_then(|v| v.as_str()) {
            python_path_spec(py.to_string())
        } else {
            let explicit = p.get("kernel_name").and_then(|v| v.as_str());
            let nb_dir = session.path.parent().map(|d| d.to_path_buf());
            let language = session.notebook.read().kernel_language();
            // Auto-venv (backend side, so it works for REMOTE notebooks too):
            // with no explicitly chosen kernel and a python notebook, a
            // project-local env (.venv/venv/env, then Pixi's default env, in
            // each dir walking up from the notebook) takes priority, with the
            // same semantics as the frontend's local detection. Explicit
            // picker choices always win.
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
                let probe = crate::kernel::command(&py)
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
                    let out = crate::kernel::command(&py)
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
        // Taken before the kernel moves into its slot: the widget path sends
        // through this sender, never through the kernel.
        let comm_sender = kernel.comm_sender();
        let kernel_name = kernel.spec().name.clone();
        // What actually started, which after a picker switch or a language
        // fallback is not what the notebook's metadata says.
        let language = kernel.spec().language.clone();
        let argv = kernel.spec().argv.clone();
        let mut rx = kernel
            .take_events()
            .await
            .ok_or_else(|| anyhow!("kernel events already taken"))?;
        let mut exited = kernel.exit_watch();
        let kernel_session = kernel.session().to_string();

        let kgen = {
            let mut slot = session.kernel.write().await;
            // From here on only this kernel's events reach a cell: a kernel
            // this one replaces sends none, whatever it still had on its way.
            let kgen = session.retire_kernel();
            // Drop alone doesn't kill the child process — only Kernel::kill
            // does. Without explicit kill, re-calling start_kernel orphans
            // the previous ipykernel_launcher (process leak).
            if let Some(old) = slot.take() {
                let _ = old.kill().await;
            }
            *slot = Some(kernel);
            kgen
        };

        // Every model of the previous kernel is dead from here on, so a widget
        // request in between is refused rather than sent to a kernel that does
        // not know the comm. Then the new kernel's sender is installed.
        let reset = session.widgets_reset();
        self.run_widget_effects(&session, &sid, reset);
        *session.widgets.comm_tx.write() = Some(comm_sender);
        let gen = session.widgets.store.lock().gen();

        // Spawn event pump: kernel events → session → frontend notifications
        let server = self.clone();
        let session_clone = session.clone();
        let sid_clone = sid.clone();
        tokio::spawn(async move {
            while let Some(ev) = rx.recv().await {
                if let Some(note) = server.pump_event(&session_clone, &sid_clone, gen, kgen, &ev) {
                    server.notify("kernel_event", note).await;
                }
            }
            tracing::info!("kernel events channel closed for session {sid_clone}");
        });

        // A kernel that exits by itself (a crash, the system out of memory,
        // exit() in a cell) leaves the session with no kernel.
        let server = self.clone();
        let session_clone = session.clone();
        let sid_clone = sid.clone();
        tokio::spawn(async move {
            if exited.wait_for(|e| *e).await.is_ok() {
                server.kernel_exited(&session_clone, &sid_clone, kgen, &kernel_session).await;
            }
        });

        Ok(json!({ "kernel_name": kernel_name, "language": language, "argv": argv }))
    }

    /// One event of the pump of the kernel of generation `kgen` (`gen`: the
    /// widget store's generation it started with). The widget step first:
    /// comm traffic and our own messages' output end there, and a stale
    /// kernel's comm events are dropped. A kernel that was stopped, replaced
    /// or found dead sends nothing more to a cell, neither to the notebook
    /// model nor to the frontend. That is checked and the cell event sent
    /// under the generation's lock, so a stop's answer (or the exit notice)
    /// follows every cell event sent before the generation moved on, and none
    /// comes after. Returns the `kernel_event` note for an event no cell takes.
    fn pump_event(self: &Arc<Self>, session: &Arc<crate::session::Session>, sid: &str, gen: u64, kgen: u64,
                  ev: &crate::kernel::KernelEvent) -> Option<Json> {
        let pre = session.widget_pre(ev, gen);
        self.run_widget_effects(session, sid, pre.effects);
        if pre.consumed {
            return None;
        }
        let current = session.kernel_gen.lock();
        if *current != kgen {
            return None;
        }
        match session.apply_event(ev) {
            Some((cell_id, payload)) => {
                let note = json!({ "session_id": sid, "cell_id": cell_id, "event": payload });
                self.notify_now("cell_event", super::json_to_mp(&note));
                None
            }
            None => Some(json!({
                "session_id": sid,
                "event": json!({ "kind": "global", "raw": format!("{ev:?}") }),
            })),
        }
    }

    /// The kernel of generation `kgen` exited. Unless a stop, a restart or a
    /// new kernel already moved the generation on (then the exit is theirs),
    /// the session's slot is emptied, so a run sent from now on is refused
    /// as "kernel not started" instead of waiting for a kernel that is gone,
    /// and the frontend is told with a `kernel_event` of kind "exited", which
    /// no event of that kernel follows. Its widget models stay, dead, as
    /// after a stop.
    async fn kernel_exited(&self, session: &Arc<crate::session::Session>, sid: &str, kgen: u64, kernel_session: &str) {
        let dead = {
            let mut slot = session.kernel.write().await;
            let mut current = session.kernel_gen.lock();
            if *current != kgen || slot.as_ref().map(|k| k.session()) != Some(kernel_session) {
                return;
            }
            *current += 1;
            let dead = slot.take();
            let note = json!({ "session_id": sid, "event": { "kind": "exited" } });
            self.notify_now("kernel_event", super::json_to_mp(&note));
            dead
        };
        tracing::warn!("kernel of session {sid} exited by itself");
        self.retire_widgets(session, sid);
        drop(dead);
    }

    /// No widget message goes to the session's kernel any more, and its
    /// models stay on screen, dead (a stop, a kernel that died).
    fn retire_widgets(&self, s: &crate::session::Session, sid: &str) {
        *s.widgets.comm_tx.write() = None;
        let reset = s.widgets_reset();
        debug_assert!(
            reset.iter().all(|e| matches!(e, Effect::Notify { .. })),
            "a widget reset sends no kernel message"
        );
        for effect in reset {
            if let Effect::Notify { event, buffers } = effect {
                self.notify_widget_event(sid, event, buffers);
            }
        }
    }

    pub(super) async fn stop_kernel(&self, p: Json) -> Result<Json> {
        let sid = p
            .get("session_id")
            .and_then(|v| v.as_str())
            .ok_or_else(|| anyhow!("session_id required"))?;
        let s = self.sessions.get(sid).ok_or_else(|| anyhow!("no session"))?.clone();
        // No widget message goes to a kernel that is being stopped.
        *s.widgets.comm_tx.write() = None;
        let k = {
            let mut slot = s.kernel.write().await;
            // None of its events reach a cell once this answers.
            s.retire_kernel();
            slot.take()
        };
        let killed = match k {
            Some(k) => k.kill().await,
            None => Ok(()),
        };
        // The models stay on screen, dead. This runs even when the kill failed.
        self.retire_widgets(&s, sid);
        killed?;
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

    pub(super) async fn execute(self: &Arc<Self>, p: Json) -> Result<Json> {
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
        // The captures of Output widgets that wait for the cadence reach the kernel
        // before the cell runs: the cell reads the outputs as they stand.
        let flushed = session.widgets.store.lock().flush_before_request();
        self.run_widget_effects(&session, sid, flushed);
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
    pub(super) async fn execute_silent(self: &Arc<Self>, p: Json) -> Result<Json> {
        let sid = p.get("session_id").and_then(|v| v.as_str()).ok_or_else(|| anyhow!("session_id"))?;
        let code = p.get("code").and_then(|v| v.as_str()).ok_or_else(|| anyhow!("code"))?;
        let session = self.sessions.get(sid).ok_or_else(|| anyhow!("no session"))?.clone();
        let guard = session.kernel.read().await;
        let kernel = guard.as_ref().ok_or_else(|| anyhow!("kernel not started"))?;
        // As in `execute`: the captures waiting for the cadence go out first.
        let flushed = session.widgets.store.lock().flush_before_request();
        self.run_widget_effects(&session, sid, flushed);
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::Path;

    /// A server whose output channel the test reads, with one session whose
    /// only cell `c` owns the request "m1".
    fn pump_fixture() -> (Arc<Server>, Arc<crate::session::Session>, tokio::sync::mpsc::UnboundedReceiver<rmpv::Value>) {
        let server = Server::new();
        let (tx, rx) = tokio::sync::mpsc::unbounded_channel();
        let _ = server.out.set(tx);
        let session = crate::session::Session::open("s".into(), PathBuf::from("jupynvim-pump-test-no-such.ipynb"))
            .expect("an empty session opens");
        session.notebook.write().cells[0].id = "c".into();
        session.msg_to_cell.insert("m1".into(), "c".into());
        server.sessions.insert("s".into(), session.clone());
        (server, session, rx)
    }

    fn stream(text: &str) -> crate::kernel::KernelEvent {
        crate::kernel::KernelEvent::Stream {
            msg_id: "o".into(),
            parent_msg_id: Some("m1".into()),
            name: "stdout".into(),
            text: text.into(),
        }
    }

    fn cell_events(rx: &mut tokio::sync::mpsc::UnboundedReceiver<rmpv::Value>) -> usize {
        let mut n = 0;
        while let Ok(m) = rx.try_recv() {
            if let rmpv::Value::Array(a) = m {
                if a.get(1).and_then(|v| v.as_str()) == Some("cell_event") {
                    n += 1;
                }
            }
        }
        n
    }

    #[test]
    fn a_retired_kernel_sends_no_cell_event() {
        let (server, session, mut rx) = pump_fixture();
        let kgen = session.retire_kernel();
        let gen = session.widgets.store.lock().gen();
        assert!(server.pump_event(&session, "s", gen, kgen, &stream("one\n")).is_none());
        assert_eq!(cell_events(&mut rx), 1, "the current kernel's output reaches the frontend");
        assert_eq!(session.notebook.read().cells[0].outputs.len(), 1, "and the notebook");
        // a stop, a restart or the kernel's death moves the generation on
        session.retire_kernel();
        assert!(server.pump_event(&session, "s", gen, kgen, &stream("two\n")).is_none());
        assert_eq!(cell_events(&mut rx), 0, "an event of a retired kernel is not sent");
        let nb = session.notebook.read();
        assert_eq!(nb.cells[0].outputs.len(), 1, "nor applied to the notebook");
        assert_eq!(nb.cells[0].outputs[0]["text"], "one\n");
    }

    /// The stop's side: the generation moved on, then its answer sent. A pump
    /// running all the while on another thread never sends a cell event
    /// after that answer (the check and the send are one step under the
    /// lock). Each round races the two; the order holds in every one.
    #[test]
    fn no_cell_event_follows_the_answer_of_a_stop() {
        use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
        for round in 0..200 {
            let (server, session, mut rx) = pump_fixture();
            let kgen = session.retire_kernel();
            let gen = session.widgets.store.lock().gen();
            let stop = Arc::new(AtomicBool::new(false));
            let sent = Arc::new(AtomicUsize::new(0));
            let (s2, sess2, stop2, sent2) = (server.clone(), session.clone(), stop.clone(), sent.clone());
            let pump = std::thread::spawn(move || {
                while !stop2.load(Ordering::Acquire) {
                    s2.pump_event(&sess2, "s", gen, kgen, &stream("x"));
                    sent2.fetch_add(1, Ordering::Release);
                }
            });
            while sent.load(Ordering::Acquire) < 3 {
                std::thread::yield_now();
            }
            session.retire_kernel();
            server.notify_now("answer", rmpv::Value::Nil);
            stop.store(true, Ordering::Release);
            pump.join().expect("the pump thread ends");
            let mut answered = false;
            while let Ok(m) = rx.try_recv() {
                if let rmpv::Value::Array(a) = m {
                    match a.get(1).and_then(|v| v.as_str()) {
                        Some("answer") => answered = true,
                        Some("cell_event") => assert!(!answered, "round {round}: a cell event came after the stop's answer"),
                        _ => {}
                    }
                }
            }
            assert!(answered);
        }
    }

    #[test]
    fn a_new_kernel_retires_the_one_it_replaces() {
        let (server, session, mut rx) = pump_fixture();
        let old = session.retire_kernel();
        let new = session.retire_kernel();
        let gen = session.widgets.store.lock().gen();
        server.pump_event(&session, "s", gen, old, &stream("late\n"));
        assert_eq!(cell_events(&mut rx), 0, "the replaced kernel's late event is dropped");
        server.pump_event(&session, "s", gen, new, &stream("now\n"));
        assert_eq!(cell_events(&mut rx), 1, "the new kernel's event is sent");
    }

    #[test]
    fn python_path_spec_names_a_pixi_env() {
        let py = "/p/proj/.pixi/envs/default/bin/python";
        let spec = python_path_spec(py.to_string());
        assert_eq!(spec.name, "pixi-python");
        assert_eq!(spec.display_name, "Python (Pixi)");
        assert_eq!(spec.argv[0], py);
        assert_eq!(&spec.argv[1..], ["-m", "ipykernel_launcher", "-f", "{connection_file}"]);
        assert_eq!(spec.path, Path::new("/p/proj/.pixi/envs/default"), "path is the env root");
        assert_eq!(spec.language, "python");
        assert!(spec.metadata.is_null(), "no ipykernel install is asked for");
    }

    #[test]
    fn python_path_spec_names_a_venv() {
        let py = "/p/proj/.venv/bin/python";
        let spec = python_path_spec(py.to_string());
        assert_eq!(spec.name, "venv-python");
        assert_eq!(spec.display_name, "Python (venv)");
        assert_eq!(spec.argv[0], py);
        assert_eq!(spec.path, Path::new("/p/proj/.venv"));
    }

    #[test]
    fn python_path_spec_is_pixi_only_for_a_dot_pixi_dir() {
        // a dir that merely ends in .pixi is not Pixi's .pixi
        let spec = python_path_spec("/p/x.pixi/bin/python".to_string());
        assert_eq!(spec.name, "venv-python");
        assert_eq!(spec.display_name, "Python (venv)");
        let spec = python_path_spec("/p/pixi/envs/default/bin/python".to_string());
        assert_eq!(spec.name, "venv-python");
    }

    #[test]
    fn python_path_spec_env_root_for_python_exe_at_the_root() {
        // Pixi on Windows puts python.exe at the env root, not in bin or Scripts
        let spec = python_path_spec("/p/proj/.pixi/envs/default/python.exe".to_string());
        assert_eq!(spec.name, "pixi-python");
        assert_eq!(spec.path, Path::new("/p/proj/.pixi/envs/default"));
    }
}
