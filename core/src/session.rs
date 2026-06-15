// Session = one open notebook + its kernel + its cell↔msg_id state.
//
// We track which msg_id belongs to which cell so iopub events can be routed
// back to the correct cell on the frontend.

use anyhow::{anyhow, Result};
use dashmap::DashMap;
use parking_lot::RwLock;
use serde::Serialize;
use serde_json::{json, Value};
use std::path::PathBuf;
use std::sync::Arc;
use tokio::sync::RwLock as AsyncRwLock;

use crate::kernel::{Kernel, KernelEvent};
use crate::notebook::{Cell, CellType, Notebook};

/// Record the Jupyter end-of-execution time (`shell.execute_reply`) on a cell.
/// Only stamps when the start (`iopub.execute_input`) is already present and the
/// end isn't yet, so it is idempotent: the iopub status:idle path and the shell
/// execute_reply path can both call it and whichever runs first wins. Requiring
/// the start to exist is what makes this race-proof — status:idle is always
/// applied after execute_input on the shared iopub stream.
fn stamp_end(cell: &mut Cell) {
    if let Some(exec) = cell
        .metadata
        .get_mut("execution")
        .and_then(|v| v.as_object_mut())
    {
        if exec.contains_key("iopub.execute_input") && !exec.contains_key("shell.execute_reply") {
            exec.insert(
                "shell.execute_reply".into(),
                json!(chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true)),
            );
        }
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct CellSnapshot {
    pub id: String,
    pub cell_type: String,
    pub source: String,
    pub execution_count: Option<u64>,
    pub outputs: Vec<Value>,
    pub metadata: Value,
}

impl From<&Cell> for CellSnapshot {
    fn from(c: &Cell) -> Self {
        Self {
            id: c.id.clone(),
            cell_type: c.cell_type.as_str().to_string(),
            source: c.source.clone(),
            execution_count: c.execution_count,
            outputs: c.outputs.clone(),
            metadata: c.metadata.clone(),
        }
    }
}

pub struct Session {
    pub id: String,
    pub path: PathBuf,
    pub notebook: RwLock<Notebook>,
    pub kernel: AsyncRwLock<Option<Kernel>>,
    /// Map msg_id → cell_id, so iopub events route to a cell
    pub msg_to_cell: DashMap<String, String>,
}

impl Session {
    pub fn open(id: String, path: PathBuf) -> Result<Arc<Self>> {
        let nb = if path.exists() {
            Notebook::read(&path)?
        } else {
            Notebook::empty()
        };
        Ok(Arc::new(Self {
            id,
            path,
            notebook: RwLock::new(nb),
            kernel: AsyncRwLock::new(None),
            msg_to_cell: DashMap::new(),
        }))
    }

    pub fn snapshot(&self) -> SessionSnapshot {
        let nb = self.notebook.read();
        SessionSnapshot {
            id: self.id.clone(),
            path: self.path.to_string_lossy().to_string(),
            cells: nb.cells.iter().map(CellSnapshot::from).collect(),
            kernel_name: nb.kernel_name(),
            metadata: nb.metadata.clone(),
        }
    }

    pub fn cell_index(&self, cell_id: &str) -> Option<usize> {
        let nb = self.notebook.read();
        nb.cells.iter().position(|c| c.id == cell_id)
    }

    pub fn update_cell_source(&self, cell_id: &str, source: String) -> Result<()> {
        let mut nb = self.notebook.write();
        let c = nb
            .cells
            .iter_mut()
            .find(|c| c.id == cell_id)
            .ok_or_else(|| anyhow!("cell {cell_id} not found"))?;
        c.source = source;
        Ok(())
    }

    pub fn set_cell_type(&self, cell_id: &str, ct: CellType) -> Result<()> {
        let mut nb = self.notebook.write();
        let c = nb
            .cells
            .iter_mut()
            .find(|c| c.id == cell_id)
            .ok_or_else(|| anyhow!("cell not found"))?;
        // Switching to non-code clears execution state
        if !matches!(ct, CellType::Code) {
            c.execution_count = None;
            c.outputs.clear();
        }
        c.cell_type = ct;
        Ok(())
    }

    pub fn insert_cell(&self, after_index: Option<usize>, cell_type: CellType) -> Result<String> {
        let mut nb = self.notebook.write();
        let new_cell = match cell_type {
            CellType::Code => Cell::new_code(),
            CellType::Markdown => Cell::new_markdown(""),
            CellType::Raw => {
                let mut c = Cell::new_code();
                c.cell_type = CellType::Raw;
                c
            }
        };
        let id = new_cell.id.clone();
        let idx = match after_index {
            Some(i) => (i + 1).min(nb.cells.len()),
            None => 0,
        };
        nb.cells.insert(idx, new_cell);
        Ok(id)
    }

    pub fn delete_cell(&self, cell_id: &str) -> Result<()> {
        let mut nb = self.notebook.write();
        let idx = nb
            .cells
            .iter()
            .position(|c| c.id == cell_id)
            .ok_or_else(|| anyhow!("cell not found"))?;
        nb.cells.remove(idx);
        if nb.cells.is_empty() {
            nb.cells.push(Cell::new_code());
        }
        Ok(())
    }

    pub fn move_cell(&self, cell_id: &str, delta: i64) -> Result<usize> {
        let mut nb = self.notebook.write();
        let idx = nb
            .cells
            .iter()
            .position(|c| c.id == cell_id)
            .ok_or_else(|| anyhow!("cell not found"))?;
        let new_idx = ((idx as i64 + delta).max(0) as usize).min(nb.cells.len() - 1);
        if new_idx == idx {
            return Ok(idx);
        }
        let cell = nb.cells.remove(idx);
        nb.cells.insert(new_idx, cell);
        Ok(new_idx)
    }

    pub fn save(&self) -> Result<()> {
        let nb = self.notebook.read();
        nb.write(&self.path)?;
        Ok(())
    }

    /// Wipe outputs and execution_count from every cell in the session.
    pub fn clear_outputs(&self) {
        let mut nb = self.notebook.write();
        for cell in nb.cells.iter_mut() {
            cell.outputs.clear();
            cell.execution_count = None;
            // drop the execution-timing stamp too, so it isn't re-saved and the
            // frontend can't rebuild the "✓ 1.6s" badge from it after a clear
            if let Some(obj) = cell.metadata.as_object_mut() {
                obj.remove("execution");
            }
        }
    }

    /// Wipe outputs, execution_count and timing for a single cell by id.
    pub fn clear_cell_output(&self, cell_id: &str) {
        let mut nb = self.notebook.write();
        if let Some(cell) = nb.cells.iter_mut().find(|c| c.id == cell_id) {
            cell.outputs.clear();
            cell.execution_count = None;
            if let Some(obj) = cell.metadata.as_object_mut() {
                obj.remove("execution");
            }
        }
    }

    /// Replace the cell list wholesale from a frontend snapshot.
    /// Outputs/exec_count are preserved for cells whose id is in the new list.
    /// Cells absent from `incoming` are dropped (this is how the buffer drives
    /// deletion). Cells with id starting "new_" get a fresh id.
    pub fn replace_cells(&self, incoming: Vec<(String, String, String)>) -> Result<Vec<String>> {
        let mut nb = self.notebook.write();
        // Index existing cells by id for output preservation
        let mut existing: std::collections::HashMap<String, Cell> = std::collections::HashMap::new();
        for c in nb.cells.drain(..) {
            existing.insert(c.id.clone(), c);
        }
        let mut new_ids = Vec::with_capacity(incoming.len());
        let mut new_cells = Vec::with_capacity(incoming.len());
        for (id, ctype, source) in incoming {
            let cell_type = CellType::from_str(&ctype);
            let final_id = if id.starts_with("new_") || id.is_empty() {
                let mut c = match cell_type {
                    CellType::Code => Cell::new_code(),
                    CellType::Markdown => Cell::new_markdown(""),
                    CellType::Raw => {
                        let mut c = Cell::new_code();
                        c.cell_type = CellType::Raw;
                        c
                    }
                };
                c.source = source;
                let id = c.id.clone();
                new_cells.push(c);
                id
            } else if let Some(mut prev) = existing.remove(&id) {
                // Cell type change clears outputs
                if std::mem::discriminant(&prev.cell_type) != std::mem::discriminant(&cell_type) {
                    prev.outputs.clear();
                    prev.execution_count = None;
                }
                prev.cell_type = cell_type;
                prev.source = source;
                new_cells.push(prev);
                id
            } else {
                // ID claimed but doesn't exist; create fresh with that id
                let mut c = Cell::new_code();
                c.id = id.clone();
                c.cell_type = cell_type;
                c.source = source;
                new_cells.push(c);
                id
            };
            new_ids.push(final_id);
        }
        nb.cells = new_cells;
        if nb.cells.is_empty() {
            nb.cells.push(Cell::new_code());
            new_ids.push(nb.cells[0].id.clone());
        }
        Ok(new_ids)
    }

    pub fn save_to(&self, path: &PathBuf) -> Result<()> {
        let nb = self.notebook.read();
        nb.write(path)?;
        Ok(())
    }

    /// Apply a kernel event to notebook state (mutate cell outputs, exec count).
    /// Returns (cell_id, augmented event payload to send to frontend).
    pub fn apply_event(&self, ev: &KernelEvent) -> Option<(String, Value)> {
        let parent = match ev {
            KernelEvent::Stream { parent_msg_id, .. } => parent_msg_id.clone(),
            KernelEvent::DisplayData { parent_msg_id, .. } => parent_msg_id.clone(),
            KernelEvent::ExecuteResult { parent_msg_id, .. } => parent_msg_id.clone(),
            KernelEvent::Error { parent_msg_id, .. } => parent_msg_id.clone(),
            KernelEvent::Status { parent_msg_id, .. } => parent_msg_id.clone(),
            KernelEvent::ExecuteInput { parent_msg_id, .. } => parent_msg_id.clone(),
            KernelEvent::ExecuteReply { parent_msg_id, .. } => parent_msg_id.clone(),
            KernelEvent::UpdateDisplayData { parent_msg_id, .. } => parent_msg_id.clone(),
            KernelEvent::ClearOutput { parent_msg_id, .. } => parent_msg_id.clone(),
            KernelEvent::KernelInfo { parent_msg_id, .. } => parent_msg_id.clone(),
        }?;
        let cell_id = self.msg_to_cell.get(&parent)?.clone();

        let mut nb = self.notebook.write();
        let cell = nb.cells.iter_mut().find(|c| c.id == cell_id)?;

        let payload = match ev {
            KernelEvent::Stream { name, text, .. } => {
                let out = json!({
                    "output_type": "stream",
                    "name": name,
                    "text": text,
                });
                // Coalesce consecutive streams of same name
                if let Some(last) = cell.outputs.last_mut() {
                    if last.get("output_type").and_then(|v| v.as_str()) == Some("stream")
                        && last.get("name").and_then(|v| v.as_str()) == Some(name.as_str())
                    {
                        let prev = last
                            .get("text")
                            .and_then(|v| v.as_str())
                            .unwrap_or("")
                            .to_string();
                        last["text"] = Value::String(prev + text);
                    } else {
                        cell.outputs.push(out.clone());
                    }
                } else {
                    cell.outputs.push(out.clone());
                }
                json!({ "kind": "stream", "name": name, "text": text })
            }
            KernelEvent::DisplayData { data, metadata, .. } => {
                let out = json!({
                    "output_type": "display_data",
                    "data": data,
                    "metadata": metadata,
                });
                cell.outputs.push(out.clone());
                json!({ "kind": "display_data", "data": data, "metadata": metadata })
            }
            KernelEvent::UpdateDisplayData { data, metadata, .. } => {
                json!({ "kind": "update_display_data", "data": data, "metadata": metadata })
            }
            KernelEvent::ExecuteResult {
                execution_count,
                data,
                metadata,
                ..
            } => {
                cell.execution_count = Some(*execution_count);
                let out = json!({
                    "output_type": "execute_result",
                    "execution_count": execution_count,
                    "data": data,
                    "metadata": metadata,
                });
                cell.outputs.push(out.clone());
                json!({ "kind": "execute_result", "execution_count": execution_count, "data": data })
            }
            KernelEvent::Error {
                ename,
                evalue,
                traceback,
                ..
            } => {
                let out = json!({
                    "output_type": "error",
                    "ename": ename,
                    "evalue": evalue,
                    "traceback": traceback,
                });
                cell.outputs.push(out.clone());
                json!({ "kind": "error", "ename": ename, "evalue": evalue, "traceback": traceback })
            }
            KernelEvent::ExecuteInput { execution_count, .. } => {
                cell.execution_count = Some(*execution_count);
                cell.outputs.clear(); // clear previous outputs at start of new execution
                // Record Jupyter-standard timing metadata (the same keys
                // JupyterLab's "record timing" writes and VSCode reads), so
                // the execution duration survives save + reopen.
                if !cell.metadata.is_object() {
                    cell.metadata = json!({});
                }
                cell.metadata["execution"] = json!({
                    "iopub.execute_input":
                        chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true),
                });
                json!({ "kind": "execute_input", "execution_count": execution_count })
            }
            KernelEvent::Status { execution_state, .. } => {
                // Stamp the end-of-execution time here, on the iopub
                // status:idle event, rather than relying solely on the shell
                // execute_reply. execute_input (iopub) and execute_reply
                // (shell) arrive on two sockets drained by two tasks into one
                // channel, so execute_reply can be applied BEFORE the
                // execute_input that creates metadata.execution — and the end
                // stamp is then dropped, so the duration vanishes after
                // save+reopen. status:idle rides the same iopub stream as
                // execute_input, so it is always applied after it. We write
                // the JupyterLab/VSCode key shell.execute_reply so the timing
                // round-trips for those tools too. stamp_end is idempotent, so
                // this and the execute_reply arm below cooperate: whichever
                // runs first records the end and the other is a no-op.
                if execution_state == "idle" {
                    stamp_end(cell);
                }
                json!({ "kind": "status", "state": execution_state })
            }
            KernelEvent::ExecuteReply {
                status,
                execution_count,
                ..
            } => {
                stamp_end(cell); // fallback; status:idle above is the primary path
                json!({ "kind": "execute_reply", "status": status, "execution_count": execution_count })
            }
            KernelEvent::ClearOutput { wait, .. } => {
                if !wait {
                    cell.outputs.clear();
                }
                json!({ "kind": "clear_output", "wait": wait })
            }
            KernelEvent::KernelInfo { info, .. } => {
                json!({ "kind": "kernel_info", "info": info })
            }
        };
        Some((cell_id, payload))
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct SessionSnapshot {
    pub id: String,
    pub path: String,
    pub cells: Vec<CellSnapshot>,
    pub kernel_name: Option<String>,
    pub metadata: Value,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::kernel::KernelEvent;

    fn session_with_one_code_cell() -> (Session, String) {
        let nb = Notebook::empty(); // one empty code cell
        let cell_id = nb.cells[0].id.clone();
        let s = Session {
            id: "s1".into(),
            path: PathBuf::from("/tmp/jupynvim-test.ipynb"),
            notebook: RwLock::new(nb),
            kernel: AsyncRwLock::new(None),
            msg_to_cell: DashMap::new(),
        };
        s.msg_to_cell.insert("msg1".into(), cell_id.clone());
        (s, cell_id)
    }

    fn execution(s: &Session, cell_id: &str) -> Value {
        let nb = s.notebook.read();
        nb.cells
            .iter()
            .find(|c| c.id == cell_id)
            .unwrap()
            .metadata
            .get("execution")
            .cloned()
            .unwrap_or(json!(null))
    }

    #[test]
    fn clear_outputs_drops_execution_metadata() {
        // Clearing a cell's output must also drop metadata.execution, else the
        // frontend's saved_duration_ns rebuilds the "✓ 1.6s" badge from it.
        let (s, cid) = session_with_one_code_cell();
        {
            let mut nb = s.notebook.write();
            let cell = nb.cells.iter_mut().find(|c| c.id == cid).unwrap();
            cell.execution_count = Some(4);
            cell.metadata["execution"] = json!({
                "iopub.execute_input": "2026-06-13T00:00:00.100Z",
                "shell.execute_reply": "2026-06-13T00:00:00.450Z",
            });
        }
        assert!(execution(&s, &cid) != json!(null), "setup: timing should be set");
        s.clear_outputs();
        let nb = s.notebook.read();
        let cell = nb.cells.iter().find(|c| c.id == cid).unwrap();
        assert!(cell.execution_count.is_none(), "execution_count not cleared");
        assert!(
            cell.metadata.get("execution").is_none(),
            "timing metadata not cleared by clear_outputs"
        );
    }

    #[test]
    fn end_stamp_survives_reply_before_input_race() {
        // The bug: shell execute_reply (its own socket/task) gets applied
        // BEFORE the iopub execute_input that creates metadata.execution, so
        // the old code dropped the end stamp and the duration vanished after
        // save+reopen. status:idle (same iopub stream as execute_input, always
        // applied after it) must still record the end.
        let (s, cell_id) = session_with_one_code_cell();
        s.apply_event(&KernelEvent::ExecuteReply {
            parent_msg_id: Some("msg1".into()),
            status: "ok".into(),
            execution_count: 4,
        });
        s.apply_event(&KernelEvent::ExecuteInput {
            parent_msg_id: Some("msg1".into()),
            execution_count: 4,
            code: "x = 1".into(),
        });
        s.apply_event(&KernelEvent::Status {
            parent_msg_id: Some("msg1".into()),
            execution_state: "idle".into(),
        });
        let exec = execution(&s, &cell_id);
        assert!(exec.get("iopub.execute_input").is_some(), "start missing");
        assert!(
            exec.get("shell.execute_reply").is_some(),
            "end stamp lost to the reply-before-input race"
        );
    }

    #[test]
    fn end_stamp_normal_order() {
        let (s, cell_id) = session_with_one_code_cell();
        s.apply_event(&KernelEvent::ExecuteInput {
            parent_msg_id: Some("msg1".into()),
            execution_count: 1,
            code: "x = 1".into(),
        });
        s.apply_event(&KernelEvent::ExecuteReply {
            parent_msg_id: Some("msg1".into()),
            status: "ok".into(),
            execution_count: 1,
        });
        let exec = execution(&s, &cell_id);
        assert!(exec.get("shell.execute_reply").is_some(), "end missing");
    }

    #[test]
    fn status_idle_without_execution_is_noop() {
        // A bare status:idle (e.g. from kernel startup, no execute_input) must
        // not invent an execution object.
        let (s, cell_id) = session_with_one_code_cell();
        s.apply_event(&KernelEvent::Status {
            parent_msg_id: Some("msg1".into()),
            execution_state: "idle".into(),
        });
        assert!(execution(&s, &cell_id).is_null(), "idle fabricated execution metadata");
    }
}
