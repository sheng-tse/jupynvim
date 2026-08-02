//! Filesystem RPCs, including the watch/unwatch pair.

use anyhow::{anyhow, Context, Result};
use base64::Engine as _;
use serde_json::{json, Value as Json};
use std::sync::Arc;

use super::{arg_path, build_gitignore_matcher, Server};

impl Server {
    pub(super) async fn fs_list(&self, p: Json) -> Result<Json> {
        let path = arg_path(&p, "path")?;
        // Build a gitignore matcher for this dir (walk up for .git + collect
        // .gitignore files between the repo root and here). Lets the frontend
        // hide gitignored entries by default with an `I` toggle, like snacks.
        let ignore_matcher = build_gitignore_matcher(&path);
        let mut rd = tokio::fs::read_dir(&path).await
            .with_context(|| format!("read_dir {}", path.display()))?;
        let mut entries = Vec::new();
        while let Some(entry) = rd.next_entry().await? {
            // Cost matters here: this used to stat() AND lstat() every entry,
            // sequentially, and the frontend only ever reads name/kind/ignored.
            // On a slow metadata filesystem (PSC's NFS home vs its parallel
            // /ocean) that made listing a 15-entry directory take seconds.
            // file_type() comes from the dirent's d_type with no syscall at
            // all on most filesystems, falling back to one lstat when the
            // filesystem reports DT_UNKNOWN.
            let entry_path = entry.path();
            let ft = match entry.file_type().await {
                Ok(ft) => ft,
                Err(_) => continue,
            };
            // Only a symlink needs a follow: a link to a dir must browse like
            // a dir. Everything else is already decided. A broken link keeps
            // showing up, marked "link" so the frontend can warn.
            let (is_dir, kind) = if ft.is_symlink() {
                match tokio::fs::metadata(&entry_path).await {
                    Ok(m) if m.is_dir() => (true, "dir"),
                    _ => (false, "link"),
                }
            } else if ft.is_dir() {
                (true, "dir")
            } else {
                (false, "file")
            };
            let ignored = ignore_matcher.as_ref()
                .map(|m| m.matched(&entry_path, is_dir).is_ignore())
                .unwrap_or(false);
            entries.push(json!({
                "name": entry.file_name().to_string_lossy(),
                "kind": kind,
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

    pub(super) async fn fs_stat(&self, p: Json) -> Result<Json> {
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

    pub(super) async fn fs_read(&self, p: Json) -> Result<Json> {
        let path = arg_path(&p, "path")?;
        let bytes = tokio::fs::read(&path).await
            .with_context(|| format!("read {}", path.display()))?;
        let b64 = base64::engine::general_purpose::STANDARD.encode(&bytes);
        Ok(json!({ "content_b64": b64, "size": bytes.len() }))
    }

    pub(super) async fn fs_write(&self, p: Json) -> Result<Json> {
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

    pub(super) async fn fs_mkdir(&self, p: Json) -> Result<Json> {
        let path = arg_path(&p, "path")?;
        let parents = p.get("parents").and_then(|v| v.as_bool()).unwrap_or(true);
        if parents {
            tokio::fs::create_dir_all(&path).await?;
        } else {
            tokio::fs::create_dir(&path).await?;
        }
        Ok(json!({ "ok": true }))
    }

    pub(super) async fn fs_rm(&self, p: Json) -> Result<Json> {
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

    pub(super) async fn fs_rename(&self, p: Json) -> Result<Json> {
        let src = arg_path(&p, "src")?;
        let dst = arg_path(&p, "dst")?;
        tokio::fs::rename(&src, &dst).await
            .with_context(|| format!("rename {} -> {}", src.display(), dst.display()))?;
        Ok(json!({ "ok": true }))
    }

    pub(super) async fn fs_realpath(&self, p: Json) -> Result<Json> {
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

    // ===========================================================
    // File watching (Phase 5)
    //
    // fs_watch starts an OS-native filesystem watcher (FSEvent on macOS,
    // inotify on Linux). Change events are pushed as `fs_event` notifications
    // until the client calls fs_unwatch with the returned watcher_id.
    // ===========================================================
    pub(super) async fn fs_watch(self: Arc<Self>, p: Json) -> Result<Json> {
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

    pub(super) async fn fs_unwatch(&self, p: Json) -> Result<Json> {
        let id = p.get("watcher_id").and_then(|v| v.as_u64())
            .ok_or_else(|| anyhow!("watcher_id required"))? as u32;
        self.watchers.remove(&id);
        Ok(json!({ "ok": true }))
    }
}
