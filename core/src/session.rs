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
        }
    }

    /// Wipe outputs and execution_count for a single cell by id.
    pub fn clear_cell_output(&self, cell_id: &str) {
        let mut nb = self.notebook.write();
        if let Some(cell) = nb.cells.iter_mut().find(|c| c.id == cell_id) {
            cell.outputs.clear();
            cell.execution_count = None;
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
                json!({ "kind": "status", "state": execution_state })
            }
            KernelEvent::ExecuteReply {
                status,
                execution_count,
                ..
            } => {
                if let Some(exec) = cell
                    .metadata
                    .get_mut("execution")
                    .and_then(|v| v.as_object_mut())
                {
                    exec.insert(
                        "shell.execute_reply".into(),
                        json!(chrono::Utc::now()
                            .to_rfc3339_opts(chrono::SecondsFormat::Millis, true)),
                    );
                }
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
