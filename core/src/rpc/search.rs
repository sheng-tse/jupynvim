//! ripgrep-backed search and file listing RPCs.

use anyhow::{anyhow, Result};
use serde_json::{json, Value as Json};
use std::sync::Arc;

use super::{arg_path, Server};

impl Server {
    // ===========================================================
    // Search (Phase 4: ripgrep-equivalent over remote files)
    //
    // Walks the directory tree (gitignore-aware via the `ignore` crate)
    // and matches each line against a regex. Returns matches as quickfix-
    // friendly { path, line, col, text } objects. Single-shot for now;
    // streaming variant can land later if large searches become a problem.
    // ===========================================================
    pub(super) async fn search(&self, p: Json) -> Result<Json> {
        let root = arg_path(&p, "path")?;
        let pattern = p.get("pattern").and_then(|v| v.as_str())
            .ok_or_else(|| anyhow!("pattern required"))?
            .to_string();
        let max = p.get("max").and_then(|v| v.as_u64()).unwrap_or(2000) as usize;
        let case_sensitive = p.get("case_sensitive").and_then(|v| v.as_bool()).unwrap_or(false);
        let fixed_string = p.get("fixed_string").and_then(|v| v.as_bool()).unwrap_or(false);
        let include_hidden = p.get("hidden").and_then(|v| v.as_bool()).unwrap_or(false);
        let excludes: std::collections::HashSet<String> = p.get("excludes")
            .and_then(|v| v.as_array())
            .map(|a| a.iter().filter_map(|x| x.as_str().map(String::from)).collect())
            .unwrap_or_default();

        // Build regex (escape if fixed_string mode)
        let raw = if fixed_string { regex::escape(&pattern) } else { pattern.clone() };
        let regex = regex::RegexBuilder::new(&raw)
            .case_insensitive(!case_sensitive)
            .build()
            .map_err(|e| anyhow!("bad regex: {e}"))?;

        // Parallel walk + match (rg-class, not a naive serial read of every
        // file): multi-threaded walker, size cap + binary sniff so corpora /
        // checkpoints don't get slurped over NFS, and an epoch counter so a
        // NEW search (live grep keystroke) makes superseded walks quit early
        // instead of piling up.
        let my_epoch = self.search_epoch.fetch_add(1, std::sync::atomic::Ordering::SeqCst) + 1;
        let epoch = self.search_epoch.clone();
        // One walk at a time (the epoch bump above makes the old one quit).
        let _permit = self.search_lock.clone().acquire_owned().await.ok();
        let root2 = root.clone();
        let matches = tokio::task::spawn_blocking(move || {
            use std::sync::atomic::{AtomicUsize, Ordering};
            use std::sync::Mutex;
            let out: Mutex<Vec<Json>> = Mutex::new(Vec::new());
            let count = AtomicUsize::new(0);
            let mut builder = ignore::WalkBuilder::new(&root2);
            builder
                .hidden(!include_hidden) // skip dotdirs by default (rg parity; .conda/.cache are huge)
                .follow_links(true)  // symlinked dirs are common on HPC homes
                .ignore(false)       // skip .ignore lookups (1 NFS stat per dir)
                .git_ignore(true)    // respect .gitignore
                .git_global(false)
                .git_exclude(false)  // skip .git/info/exclude lookups per dir
                // NFS walks are latency-bound, not CPU-bound: more threads = faster
                .threads(std::thread::available_parallelism().map(|n| n.get()).unwrap_or(4).min(32));
            if !excludes.is_empty() {
                builder.filter_entry(move |e| {
                    e.file_name().to_str().map_or(true, |n| !excludes.contains(n))
                });
            }
            builder.build_parallel().run(|| {
                let regex = regex.clone();
                let out = &out;
                let count = &count;
                let epoch = &epoch;
                Box::new(move |entry_result| {
                    use ignore::WalkState;
                    if epoch.load(Ordering::Relaxed) != my_epoch {
                        return WalkState::Quit; // superseded by a newer search
                    }
                    if count.load(Ordering::Relaxed) >= max {
                        return WalkState::Quit;
                    }
                    let entry = match entry_result { Ok(e) => e, Err(_) => return WalkState::Continue };
                    if !entry.file_type().map_or(false, |t| t.is_file()) {
                        return WalkState::Continue;
                    }
                    if entry.metadata().map(|m| m.len()).unwrap_or(0) > 2_000_000 {
                        return WalkState::Continue; // skip big files (data, checkpoints)
                    }
                    let bytes = match std::fs::read(entry.path()) {
                        Ok(b) => b,
                        Err(_) => return WalkState::Continue,
                    };
                    if bytes[..bytes.len().min(1024)].contains(&0) {
                        return WalkState::Continue; // binary sniff
                    }
                    let content = String::from_utf8_lossy(&bytes);
                    for (idx, line) in content.lines().enumerate() {
                        if let Some(m) = regex.find(line) {
                            if count.fetch_add(1, Ordering::Relaxed) >= max {
                                return WalkState::Quit;
                            }
                            out.lock().unwrap().push(json!({
                                "path": entry.path().to_string_lossy(),
                                "line": idx + 1,
                                "col": m.start() + 1,
                                "text": line,
                            }));
                        }
                    }
                    WalkState::Continue
                })
            });
            out.into_inner().unwrap_or_default()
        }).await.map_err(|e| anyhow!("search task: {e}"))?;

        let truncated = matches.len() >= max;
        Ok(json!({ "matches": matches, "truncated": truncated }))
    }

    // Streaming variant of `search` for live grep: matches are pushed to the
    // frontend as `search_event` notifications ({sid, matches:[..]} batches,
    // then {sid, done:true}) while the walk runs, so results appear within
    // milliseconds even when the full walk of a big NFS tree takes much
    // longer. The RPC returns immediately. Each call bumps the search epoch,
    // so a new keystroke's search makes superseded walks quit early.
    pub(super) async fn search_stream(self: Arc<Self>, p: Json) -> Result<Json> {
        let root = arg_path(&p, "path")?;
        let sid = p.get("sid").and_then(|v| v.as_u64()).unwrap_or(0);
        let pattern = p.get("pattern").and_then(|v| v.as_str())
            .ok_or_else(|| anyhow!("pattern required"))?
            .to_string();
        let max = p.get("max").and_then(|v| v.as_u64()).unwrap_or(1000) as usize;
        let case_sensitive = p.get("case_sensitive").and_then(|v| v.as_bool()).unwrap_or(false);
        let fixed_string = p.get("fixed_string").and_then(|v| v.as_bool()).unwrap_or(false);
        let include_hidden = p.get("hidden").and_then(|v| v.as_bool()).unwrap_or(false);
        let excludes: std::collections::HashSet<String> = p.get("excludes")
            .and_then(|v| v.as_array())
            .map(|a| a.iter().filter_map(|x| x.as_str().map(String::from)).collect())
            .unwrap_or_default();
        let raw = if fixed_string { regex::escape(&pattern) } else { pattern.clone() };
        let regex = regex::RegexBuilder::new(&raw)
            .case_insensitive(!case_sensitive)
            .build()
            .map_err(|e| anyhow!("bad regex: {e}"))?;

        let my_epoch = self.search_epoch.fetch_add(1, std::sync::atomic::Ordering::SeqCst) + 1;
        let epoch = self.search_epoch.clone();
        // One walk at a time: wait for the (epoch-cancelled) previous walk's
        // threads to drain before hitting the filesystem again. Held by the
        // walker until it finishes.
        let permit = self.search_lock.clone().acquire_owned().await.ok();
        let (tx, mut rx) = tokio::sync::mpsc::channel::<Json>(512);

        // Walker (blocking, parallel). Drops tx when done -> channel closes.
        tokio::task::spawn_blocking(move || {
            let _permit = permit;
            use std::sync::atomic::{AtomicUsize, Ordering};
            let count = AtomicUsize::new(0);
            let mut builder = ignore::WalkBuilder::new(&root);
            builder
                .hidden(!include_hidden)
                .follow_links(true)
                .ignore(false)       // skip .ignore lookups (1 NFS stat per dir)
                .git_ignore(true)
                .git_global(false)
                .git_exclude(false)  // skip .git/info/exclude lookups per dir
                .threads(std::thread::available_parallelism().map(|n| n.get()).unwrap_or(4).min(32));
            if !excludes.is_empty() {
                builder.filter_entry(move |e| {
                    e.file_name().to_str().map_or(true, |n| !excludes.contains(n))
                });
            }
            builder.build_parallel().run(|| {
                let regex = regex.clone();
                let tx = tx.clone();
                let count = &count;
                let epoch = &epoch;
                Box::new(move |entry_result| {
                    use ignore::WalkState;
                    if epoch.load(Ordering::Relaxed) != my_epoch {
                        return WalkState::Quit;
                    }
                    if count.load(Ordering::Relaxed) >= max {
                        return WalkState::Quit;
                    }
                    let entry = match entry_result { Ok(e) => e, Err(_) => return WalkState::Continue };
                    if !entry.file_type().map_or(false, |t| t.is_file()) {
                        return WalkState::Continue;
                    }
                    if entry.metadata().map(|m| m.len()).unwrap_or(0) > 2_000_000 {
                        return WalkState::Continue;
                    }
                    let bytes = match std::fs::read(entry.path()) {
                        Ok(b) => b,
                        Err(_) => return WalkState::Continue,
                    };
                    if bytes[..bytes.len().min(1024)].contains(&0) {
                        return WalkState::Continue;
                    }
                    let content = String::from_utf8_lossy(&bytes);
                    for (idx, line) in content.lines().enumerate() {
                        if let Some(m) = regex.find(line) {
                            if count.fetch_add(1, Ordering::Relaxed) >= max {
                                return WalkState::Quit;
                            }
                            let _ = tx.blocking_send(json!({
                                "path": entry.path().to_string_lossy(),
                                "line": idx + 1,
                                "col": m.start() + 1,
                                "text": line,
                            }));
                        }
                    }
                    WalkState::Continue
                })
            });
        });

        // Drainer: batch matches -> search_event notifications, then done.
        let server = self.clone();
        tokio::spawn(async move {
            let mut batch: Vec<Json> = Vec::new();
            loop {
                match tokio::time::timeout(std::time::Duration::from_millis(60), rx.recv()).await {
                    Ok(Some(v)) => {
                        batch.push(v);
                        if batch.len() >= 100 {
                            let b = std::mem::take(&mut batch);
                            server.notify("search_event", json!({ "sid": sid, "matches": b })).await;
                        }
                    }
                    Ok(None) => break,
                    Err(_) => {
                        if !batch.is_empty() {
                            let b = std::mem::take(&mut batch);
                            server.notify("search_event", json!({ "sid": sid, "matches": b })).await;
                        }
                    }
                }
            }
            if !batch.is_empty() {
                let b = std::mem::take(&mut batch);
                server.notify("search_event", json!({ "sid": sid, "matches": b })).await;
            }
            server.notify("search_event", json!({ "sid": sid, "done": true })).await;
        });

        Ok(json!({ "started": true, "sid": sid }))
    }

    // List files under `path` (recursive, respecting .gitignore) for a remote
    // file picker. Returns paths relative to `path` plus the absolute root, so
    // the frontend can build jupynvim:// URIs. Files only; capped by `max`.
    // `excludes` (dir/file names) prunes bulk junk so a $HOME scan isn't
    // dominated by conda installs and __pycache__.
    pub(super) async fn find_files(&self, p: Json) -> Result<Json> {
        let root = arg_path(&p, "path")?;
        let max = p.get("max").and_then(|v| v.as_u64()).unwrap_or(20000) as usize;
        let include_hidden = p.get("hidden").and_then(|v| v.as_bool()).unwrap_or(false);
        let excludes: std::collections::HashSet<String> = p.get("excludes")
            .and_then(|v| v.as_array())
            .map(|a| a.iter().filter_map(|x| x.as_str().map(String::from)).collect())
            .unwrap_or_default();
        let root2 = root.clone();
        // Pruned dirs (e.g. miniconda3, node_modules): we don't scan their
        // contents, but we still report the DIR paths so the frontend filter
        // can show + navigate into them. Mutex so the (Fn+Send+Sync) walk
        // filter can record into it.
        let pruned = std::sync::Arc::new(std::sync::Mutex::new(Vec::<String>::new()));
        let (files, pruned_out) = tokio::task::spawn_blocking({
            let pruned = pruned.clone();
            let root2 = root2.clone();
            move || {
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
                let root_f = root2.clone();
                let pruned_f = pruned.clone();
                builder.filter_entry(move |e| {
                    let name = e.file_name().to_str().unwrap_or("");
                    if excludes.contains(name) {
                        // record the pruned dir's relative path, then skip it
                        if e.file_type().map_or(false, |t| t.is_dir()) {
                            if let Ok(rel) = e.path().strip_prefix(&root_f) {
                                let mut p = pruned_f.lock().unwrap();
                                if p.len() < 5000 { p.push(rel.to_string_lossy().to_string()); }
                            }
                        }
                        return false;
                    }
                    true
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
            let pr = pruned.lock().unwrap().clone();
            (out, pr)
        }}).await.map_err(|e| anyhow!("find_files task: {e}"))?;
        let truncated = files.len() >= max;
        Ok(json!({ "root": root.to_string_lossy(), "files": files,
                   "pruned_dirs": pruned_out, "truncated": truncated }))
    }
}
