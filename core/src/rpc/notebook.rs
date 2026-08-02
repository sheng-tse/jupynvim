//! Notebook document RPCs: open/save and cell edits.

use anyhow::{anyhow, Result};
use serde_json::{json, Value as Json};
use uuid::Uuid;

use super::{arg_path, Server};
use crate::notebook::CellType;
use crate::session::Session;

impl Server {
    pub(super) async fn open(&self, p: Json) -> Result<Json> {
        // arg_path expands `~/`, `~`, `/~/...` to the server-process's $HOME
        // so frontends can send tilde-prefixed paths without local expansion.
        let path = arg_path(&p, "path")?;
        let id = Uuid::new_v4().to_string();
        let session = Session::open(id.clone(), path)?;
        self.sessions.insert(id.clone(), session.clone());
        let snap = session.snapshot();
        Ok(json!({ "session_id": id, "snapshot": snap }))
    }

    pub(super) async fn close(&self, p: Json) -> Result<Json> {
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

    pub(super) fn snapshot(&self, p: Json) -> Result<Json> {
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

    pub(super) async fn update_cell_source(&self, p: Json) -> Result<Json> {
        let sid = p.get("session_id").and_then(|v| v.as_str()).ok_or_else(|| anyhow!("session_id"))?;
        let cell_id = p.get("cell_id").and_then(|v| v.as_str()).ok_or_else(|| anyhow!("cell_id"))?;
        let source = p.get("source").and_then(|v| v.as_str()).ok_or_else(|| anyhow!("source"))?.to_string();
        let s = self.sessions.get(sid).ok_or_else(|| anyhow!("no session"))?;
        s.update_cell_source(cell_id, source)?;
        Ok(json!({ "ok": true }))
    }

    pub(super) async fn set_cell_type(&self, p: Json) -> Result<Json> {
        let sid = p.get("session_id").and_then(|v| v.as_str()).ok_or_else(|| anyhow!("session_id"))?;
        let cell_id = p.get("cell_id").and_then(|v| v.as_str()).ok_or_else(|| anyhow!("cell_id"))?;
        let cell_type = p.get("cell_type").and_then(|v| v.as_str()).ok_or_else(|| anyhow!("cell_type"))?;
        let s = self.sessions.get(sid).ok_or_else(|| anyhow!("no session"))?;
        s.set_cell_type(cell_id, CellType::from_str(cell_type))?;
        Ok(json!({ "ok": true }))
    }

    pub(super) async fn insert_cell(&self, p: Json) -> Result<Json> {
        let sid = p.get("session_id").and_then(|v| v.as_str()).ok_or_else(|| anyhow!("session_id"))?;
        let after_index = p.get("after_index").and_then(|v| v.as_i64()).map(|i| i as usize);
        let cell_type = p.get("cell_type").and_then(|v| v.as_str()).unwrap_or("code");
        let s = self.sessions.get(sid).ok_or_else(|| anyhow!("no session"))?;
        let id = s.insert_cell(after_index, CellType::from_str(cell_type))?;
        Ok(json!({ "cell_id": id }))
    }

    pub(super) async fn delete_cell(&self, p: Json) -> Result<Json> {
        let sid = p.get("session_id").and_then(|v| v.as_str()).ok_or_else(|| anyhow!("session_id"))?;
        let cell_id = p.get("cell_id").and_then(|v| v.as_str()).ok_or_else(|| anyhow!("cell_id"))?;
        let s = self.sessions.get(sid).ok_or_else(|| anyhow!("no session"))?;
        s.delete_cell(cell_id)?;
        Ok(json!({ "ok": true }))
    }

    pub(super) async fn move_cell(&self, p: Json) -> Result<Json> {
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
    pub(super) async fn replace_cells(&self, p: Json) -> Result<Json> {
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

    pub(super) async fn save(&self, p: Json) -> Result<Json> {
        let sid = p.get("session_id").and_then(|v| v.as_str()).ok_or_else(|| anyhow!("session_id"))?;
        let s = self.sessions.get(sid).ok_or_else(|| anyhow!("no session"))?;
        s.save()?;
        Ok(json!({ "ok": true }))
    }

    /// Clear outputs and execution_count for every cell in the session.
    /// Mirrors `jupyter nbconvert --clear-output` semantics.
    pub(super) async fn clear_outputs(&self, p: Json) -> Result<Json> {
        let sid = p.get("session_id").and_then(|v| v.as_str()).ok_or_else(|| anyhow!("session_id"))?;
        let s = self.sessions.get(sid).ok_or_else(|| anyhow!("no session"))?.clone();
        s.clear_outputs();
        Ok(json!({ "ok": true }))
    }

    /// Clear outputs and execution_count of a single cell by id.
    pub(super) async fn clear_cell_output(&self, p: Json) -> Result<Json> {
        let sid = p.get("session_id").and_then(|v| v.as_str()).ok_or_else(|| anyhow!("session_id"))?;
        let cell_id = p.get("cell_id").and_then(|v| v.as_str()).ok_or_else(|| anyhow!("cell_id"))?;
        let s = self.sessions.get(sid).ok_or_else(|| anyhow!("no session"))?.clone();
        s.clear_cell_output(cell_id);
        Ok(json!({ "ok": true }))
    }

    pub(super) async fn save_as(&self, p: Json) -> Result<Json> {
        let sid = p.get("session_id").and_then(|v| v.as_str()).ok_or_else(|| anyhow!("session_id"))?;
        let path = arg_path(&p, "path")?;
        let s = self.sessions.get(sid).ok_or_else(|| anyhow!("no session"))?;
        s.save_to(&path)?;
        Ok(json!({ "ok": true }))
    }
}
