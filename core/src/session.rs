// Session = one open notebook + its kernel + its cell↔msg_id state.
//
// We track which msg_id belongs to which cell so iopub events can be routed
// back to the correct cell on the frontend.

use anyhow::{anyhow, Result};
use dashmap::DashMap;
use parking_lot::RwLock;
use serde::Serialize;
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use tokio::sync::RwLock as AsyncRwLock;

use crate::kernel::{Kernel, KernelEvent};
use crate::notebook::{Cell, CellType, Notebook};
use crate::widgets::{
    apply_widget_metadata, remove_state_entry, view_ids, view_ids_in_cells, Effect, Store, Widgets,
};

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
    /// Cells with a clear_output(wait=True) not applied yet. Per the Jupyter
    /// messaging spec the clear happens when the next output arrives, which
    /// is what lets a live-updating loop replace its frame instead of
    /// stacking one per iteration.
    pub clear_pending: DashMap<String, ()>,
    /// The widget models of the current kernel (see widgets.rs).
    pub widgets: crate::widgets::Widgets,
}

/// What the event pump does with a kernel event before the cell path: the
/// effects to run, and whether the event is fully handled by the widget path.
pub struct WidgetPre {
    pub effects: Vec<crate::widgets::Effect>,
    pub consumed: bool,
}

impl Session {
    pub fn open(id: String, path: PathBuf) -> Result<Arc<Self>> {
        let mut nb = if path.exists() {
            Notebook::read(&path)?
        } else {
            Notebook::empty()
        };
        // The saved widget state becomes the store's (dead) models; the store
        // is the only copy from here on, and save writes what the views reach.
        let widgets = Widgets::default();
        take_saved_widgets(&mut nb, &mut widgets.store.lock());
        Ok(Arc::new(Self {
            id,
            path,
            notebook: RwLock::new(nb),
            kernel: AsyncRwLock::new(None),
            msg_to_cell: DashMap::new(),
            clear_pending: DashMap::new(),
            widgets,
        }))
    }

    /// The event pump's widget step, run before the cell path for every kernel
    /// event. `gen` is the kernel generation the pump was started with (see
    /// Store::gen): once the kernel was restarted or stopped, its late comm
    /// events are consumed with no effect, so they never bring a model back.
    /// Comm events go to the store. The output of a callback (comm_cell) or of
    /// an Output widget's capture is routed here; everything else passes on.
    pub fn widget_pre(&self, ev: &KernelEvent, gen: u64) -> WidgetPre {
        let (pre, finished) = {
            let mut store = self.widgets.store.lock();
            widget_pre_locked(&mut store, ev, gen)
        };
        if let Some(msg_id) = finished {
            self.widgets.comm_cell.remove(&msg_id);
        }
        pre
    }

    /// The first code cell, in notebook order, that shows the widget `model_id` (see
    /// Store::first_cell_reaching). The callback output of a comm message (an update,
    /// a custom message or an outputs flush) that names no cell goes there. The
    /// notebook is read and released before the store is taken.
    pub fn cell_showing(&self, model_id: &str) -> Option<String> {
        let cells: Vec<(String, Vec<String>)> = {
            let nb = self.notebook.read();
            nb.cells
                .iter()
                .filter(|c| matches!(c.cell_type, CellType::Code))
                .map(|c| (c.id.clone(), view_ids(&c.outputs)))
                .filter(|(_, views)| !views.is_empty())
                .collect()
        };
        self.widgets.store.lock().first_cell_reaching(&cells, model_id)
    }

    /// A kernel stopped or restarted: no callback output is routed any more,
    /// and every model is dead (kept, not connected). Returns the effects.
    pub fn widgets_reset(&self) -> Vec<Effect> {
        self.widgets.comm_cell.clear();
        // The models the cells show stay; the store drops the other dead ones.
        let roots = view_ids_in_cells(&self.notebook.read().cells);
        self.widgets.store.lock().reset(&roots)
    }

    pub fn snapshot(&self) -> SessionSnapshot {
        // The store is read and released before the notebook is taken.
        let widgets = self.widgets.store.lock().models_json();
        let nb = self.notebook.read();
        SessionSnapshot {
            id: self.id.clone(),
            path: self.path.to_string_lossy().to_string(),
            cells: nb.cells.iter().map(CellSnapshot::from).collect(),
            kernel_name: nb.kernel_name(),
            metadata: nb.metadata.clone(),
            widgets,
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
        self.write_to(&self.path)
    }

    /// Writes the notebook with the widget state its views reach (see
    /// widgets.rs export_saved). The cells, the store and the metadata are read
    /// one lock at a time: the store is taken and released before the notebook,
    /// never both at once. A view that appears between the reads sends the
    /// round again; after the last round the state of that round is written.
    /// The written metadata is a copy: the notebook keeps what it loaded, and
    /// the store stays the only copy of the widget state.
    fn write_to(&self, path: &Path) -> Result<()> {
        const ROUNDS: usize = 3;
        let mut round = 0;
        loop {
            round += 1;
            let roots = view_ids_in_cells(&self.notebook.read().cells);
            let (exported, foreign) = {
                let store = self.widgets.store.lock();
                (store.export_saved(&roots), store.foreign_saved)
            };
            let nb = self.notebook.read();
            if round < ROUNDS && view_ids_in_cells(&nb.cells) != roots {
                continue;
            }
            let mut metadata = nb.metadata.clone();
            apply_widget_metadata(&mut metadata, exported, foreign);
            return nb.write_with_metadata(path, metadata);
        }
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
        self.write_to(path)
    }

    /// Apply a kernel event to notebook state (mutate cell outputs, exec count).
    /// Returns (cell_id, augmented event payload to send to frontend).
    pub fn apply_event(&self, ev: &KernelEvent) -> Option<(String, Value)> {
        let parent = match ev {
            // Widget comm traffic belongs to the widget store, never to a cell.
            KernelEvent::CommOpen { .. } | KernelEvent::CommMsg { .. } | KernelEvent::CommClose { .. } => {
                return None
            }
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
        // The output of a widget callback (comm_cell) belongs to the widget's
        // cell. Every other event of an execution maps through msg_to_cell.
        let cell_id = match self.msg_to_cell.get(&parent) {
            Some(cell) => cell.clone(),
            None => {
                // A display handle updated by a callback (dh.update) belongs to
                // the callback's cell too, as in the classic notebook.
                let output = matches!(
                    ev,
                    KernelEvent::Stream { .. }
                        | KernelEvent::DisplayData { .. }
                        | KernelEvent::ExecuteResult { .. }
                        | KernelEvent::Error { .. }
                        | KernelEvent::ClearOutput { .. }
                        | KernelEvent::UpdateDisplayData { .. }
                );
                if !output {
                    return None;
                }
                self.widgets.comm_cell.get(&parent)?.clone()
            }
        };

        let mut nb = self.notebook.write();

        // A display handle's update can target outputs in any cell, so it is
        // resolved against the whole notebook before one cell is borrowed.
        if let KernelEvent::UpdateDisplayData { data, metadata, transient, .. } = ev {
            let display_id = transient.get("display_id").and_then(|v| v.as_str())?;
            let mut cells = Vec::new();
            for c in nb.cells.iter_mut() {
                let mut hit = false;
                for o in c.outputs.iter_mut() {
                    if output_display_id(o) == Some(display_id) {
                        o["data"] = data.clone();
                        o["metadata"] = metadata.clone();
                        hit = true;
                    }
                }
                if hit {
                    cells.push(c.id.clone());
                }
            }
            return Some((cell_id, json!({
                "kind": "update_display_data", "display_id": display_id,
                "data": data, "metadata": metadata, "cells": cells,
            })));
        }

        let cell = nb.cells.iter_mut().find(|c| c.id == cell_id)?;

        // The deferred half of clear_output(wait=True): the first output after
        // it replaces what was there. The payload says so, so the frontend
        // clears at the same point instead of tracking it separately.
        let is_output = matches!(ev,
            KernelEvent::Stream { .. } | KernelEvent::DisplayData { .. }
            | KernelEvent::ExecuteResult { .. } | KernelEvent::Error { .. });
        let clear_first = is_output && self.clear_pending.remove(&cell_id).is_some();
        if clear_first {
            cell.outputs.clear();
        }

        let mut payload = match ev {
            // Unreachable here (the parent match returns first); kept so the
            // match stays exhaustive without a panic path in the event pump.
            KernelEvent::CommOpen { .. } | KernelEvent::CommMsg { .. } | KernelEvent::CommClose { .. } => {
                return None
            }
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
            KernelEvent::DisplayData { data, metadata, transient, .. } => {
                let mut out = json!({
                    "output_type": "display_data",
                    "data": data,
                    "metadata": metadata,
                });
                // Kept in memory so update_display_data can find this output.
                // Not part of nbformat: Cell::to_json drops it on save.
                if transient.get("display_id").is_some() {
                    out["transient"] = transient.clone();
                }
                cell.outputs.push(out);
                json!({ "kind": "display_data", "data": data, "metadata": metadata,
                        "transient": transient })
            }
            KernelEvent::UpdateDisplayData { .. } => unreachable!("handled above"),
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
                self.clear_pending.remove(&cell_id);
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
                if *wait {
                    self.clear_pending.insert(cell_id.clone(), ());
                } else {
                    cell.outputs.clear();
                }
                json!({ "kind": "clear_output", "wait": wait })
            }
            KernelEvent::KernelInfo { info, .. } => {
                json!({ "kind": "kernel_info", "info": info })
            }
        };
        if clear_first {
            payload["clear_first"] = json!(true);
        }
        Some((cell_id, payload))
    }
}

/// widget_pre under the store lock. The second value is the msg_id of one of
/// our messages whose idle just arrived: its comm_cell entry ends (the caller
/// removes it after the lock is released).
fn widget_pre_locked(store: &mut Store, ev: &KernelEvent, gen: u64) -> (WidgetPre, Option<String>) {
    if gen != store.gen() {
        // A pump of a kernel that was restarted or stopped: its comm events are
        // consumed with no effect; the rest is the cell path's, as before.
        return (WidgetPre { effects: Vec::new(), consumed: ev.is_comm() }, None);
    }
    let none = |effects: Vec<Effect>, consumed: bool| {
        (WidgetPre { effects, consumed }, None)
    };
    match ev {
        KernelEvent::CommOpen { comm_id, target_name, data, metadata, buffers, .. } => {
            none(store.comm_open(comm_id, target_name, data, metadata, buffers), true)
        }
        KernelEvent::CommMsg { comm_id, data, buffers, parent_msg_id, .. } => {
            none(store.comm_msg(comm_id, data, buffers, parent_msg_id.as_deref()), true)
        }
        KernelEvent::CommClose { comm_id, .. } => none(store.comm_close(comm_id), true),
        KernelEvent::Status { execution_state, parent_msg_id: Some(parent), .. } => {
            let idle = execution_state == "idle";
            // Read before on_idle, which ends the message (it is no longer ours).
            let ours = store.is_ours(parent);
            // An idle always reaches the store: it ends an update in flight of
            // ours, and is a no-op for any other parent.
            let effects = if idle { store.on_idle(parent) } else { Vec::new() };
            if ours {
                // Our busy and idle are not kernel events: no notification to Lua.
                let finished = if idle { Some(parent.clone()) } else { None };
                (WidgetPre { effects, consumed: true }, finished)
            } else {
                (WidgetPre { effects, consumed: false }, None)
            }
        }
        KernelEvent::Stream { parent_msg_id: Some(parent), .. }
        | KernelEvent::DisplayData { parent_msg_id: Some(parent), .. }
        | KernelEvent::ExecuteResult { parent_msg_id: Some(parent), .. }
        | KernelEvent::Error { parent_msg_id: Some(parent), .. }
        | KernelEvent::ClearOutput { parent_msg_id: Some(parent), .. } => {
            match store.route_output(parent, ev) {
                Some(effects) => none(effects, true),
                None => none(Vec::new(), false),
            }
        }
        KernelEvent::UpdateDisplayData { data, metadata, transient, .. } => {
            // Every Output widget showing the display is updated; the cell's
            // own outputs are still updated by the cell path.
            match transient.get("display_id").and_then(Value::as_str) {
                Some(display_id) => none(store.update_display(display_id, data, metadata), false),
                None => none(Vec::new(), false),
            }
        }
        _ => none(Vec::new(), false),
    }
}

/// The display_id an output was created with, if it has one.
fn output_display_id(o: &Value) -> Option<&str> {
    o.get("transient")?.get("display_id")?.as_str()
}

/// Moves the state entry of `metadata.widgets` out of the notebook into the
/// store (as dead models). Only that entry leaves: a key next to it stays in
/// the notebook, and the widgets object goes with the last of its keys. A
/// block that cannot be read stays where it is and the store records it, so
/// save writes it back unchanged unless reachable state replaces it.
fn take_saved_widgets(nb: &mut Notebook, store: &mut Store) {
    let Some(block) = nb.metadata.get("widgets") else {
        return;
    };
    match store.load_saved(block) {
        Ok(loaded) => {
            tracing::debug!(models = loaded, "saved widget state moved into the store");
            remove_state_entry(&mut nb.metadata);
        }
        Err(e) => {
            tracing::warn!("metadata.widgets kept as it is: {e}");
            store.foreign_saved = true;
        }
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct SessionSnapshot {
    pub id: String,
    pub path: String,
    pub cells: Vec<CellSnapshot>,
    pub kernel_name: Option<String>,
    pub metadata: Value,
    /// The widget models of the store, in the saved-state shape (see
    /// widgets.rs models_json), buffers base64, `live` set for the current kernel.
    pub widgets: Vec<Value>,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::kernel::KernelEvent;
    use crate::widgets::STATE_MIME;
    use bytes::Bytes;

    fn session_with_one_code_cell() -> (Session, String) {
        let nb = Notebook::empty(); // one empty code cell
        let cell_id = nb.cells[0].id.clone();
        let s = Session {
            id: "s1".into(),
            path: std::env::temp_dir().join("jupynvim-test.ipynb"),
            notebook: RwLock::new(nb),
            kernel: AsyncRwLock::new(None),
            msg_to_cell: DashMap::new(),
            clear_pending: DashMap::new(),
            widgets: Default::default(),
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

    fn outputs(s: &Session, cell_id: &str) -> Vec<Value> {
        let nb = s.notebook.read();
        nb.cells.iter().find(|c| c.id == cell_id).unwrap().outputs.clone()
    }

    fn display(png: &str, display_id: Option<&str>) -> KernelEvent {
        KernelEvent::DisplayData {
            msg_id: "d".into(),
            parent_msg_id: Some("msg1".into()),
            data: json!({ "image/png": png }),
            metadata: json!({}),
            transient: display_id.map(|d| json!({ "display_id": d })).unwrap_or(json!({})),
        }
    }

    #[test]
    fn clear_output_wait_replaces_on_the_next_output() {
        // A live plot loop: display, clear_output(wait=True), display, ...
        // Each clear must land when the next frame arrives, leaving one frame,
        // not one per iteration (JupyterLab keeps 1; this used to keep all).
        let (s, cid) = session_with_one_code_cell();
        for frame in ["F1", "F2", "F3"] {
            s.apply_event(&KernelEvent::ClearOutput { parent_msg_id: Some("msg1".into()), wait: true });
            let (_, payload) = s.apply_event(&display(frame, None)).unwrap();
            if frame != "F1" {
                assert_eq!(payload["clear_first"], json!(true), "frontend not told to clear");
            }
        }
        let outs = outputs(&s, &cid);
        assert_eq!(outs.len(), 1, "frames stacked: {outs:?}");
        assert_eq!(outs[0]["data"]["image/png"], json!("F3"));
    }

    #[test]
    fn clear_output_wait_does_not_clear_early() {
        // Until the next output arrives the old one stays, so there is no
        // blank flash between frames.
        let (s, cid) = session_with_one_code_cell();
        s.apply_event(&display("F1", None));
        s.apply_event(&KernelEvent::ClearOutput { parent_msg_id: Some("msg1".into()), wait: true });
        assert_eq!(outputs(&s, &cid).len(), 1);
        s.apply_event(&KernelEvent::ClearOutput { parent_msg_id: Some("msg1".into()), wait: false });
        assert_eq!(outputs(&s, &cid).len(), 0, "clear_output(wait=False) is immediate");
    }

    #[test]
    fn update_display_data_replaces_the_displayed_output() {
        // h = display(fig, display_id=True); h.update(fig2) must show and save
        // fig2. The update used to be forwarded and then dropped.
        let (s, cid) = session_with_one_code_cell();
        s.apply_event(&display("OLD", Some("h1")));
        s.apply_event(&display("OTHER", Some("h2")));
        let (_, payload) = s.apply_event(&KernelEvent::UpdateDisplayData {
            msg_id: "u".into(),
            parent_msg_id: Some("msg1".into()),
            data: json!({ "image/png": "NEW" }),
            metadata: json!({}),
            transient: json!({ "display_id": "h1" }),
        }).unwrap();
        let outs = outputs(&s, &cid);
        assert_eq!(outs[0]["data"]["image/png"], json!("NEW"));
        assert_eq!(outs[1]["data"]["image/png"], json!("OTHER"), "wrong display updated");
        assert_eq!(payload["cells"], json!([cid.clone()]));

        // transient is how the update found its target; it is not nbformat
        let saved = s.notebook.read().cells[0].to_json();
        assert!(saved["outputs"][0].get("transient").is_none(), "transient leaked into the .ipynb");
        assert_eq!(saved["outputs"][0]["data"]["image/png"], json!("NEW"));
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

    #[test]
    fn widget_comm_events_never_reach_a_cell() {
        // Comm traffic is routed to the widget store, so even with a parent
        // that maps to a cell it must not add outputs or send a cell event.
        let (s, cid) = session_with_one_code_cell();
        let comm = [
            KernelEvent::CommOpen {
                msg_id: "c".into(),
                parent_msg_id: Some("msg1".into()),
                comm_id: "w1".into(),
                target_name: "jupyter.widget".into(),
                data: json!({}),
                metadata: json!({}),
                buffers: Vec::new(),
            },
            KernelEvent::CommMsg {
                msg_id: "m".into(),
                parent_msg_id: Some("msg1".into()),
                comm_id: "w1".into(),
                data: json!({ "method": "update" }),
                buffers: Vec::new(),
            },
            KernelEvent::CommClose {
                parent_msg_id: Some("msg1".into()),
                comm_id: "w1".into(),
                data: json!({}),
            },
        ];
        for ev in &comm {
            assert!(s.apply_event(ev).is_none(), "comm event produced a cell event: {ev:?}");
        }
        assert!(outputs(&s, &cid).is_empty(), "comm event added an output");
    }

    fn comm_open_event(comm_id: &str, state: Value) -> KernelEvent {
        KernelEvent::CommOpen {
            msg_id: format!("open-{comm_id}"),
            parent_msg_id: None,
            comm_id: comm_id.into(),
            target_name: "jupyter.widget".into(),
            data: json!({ "state": state }),
            metadata: json!({}),
            buffers: Vec::new(),
        }
    }

    fn comm_msg_event(comm_id: &str, data: Value, buffers: Vec<Bytes>) -> KernelEvent {
        KernelEvent::CommMsg {
            msg_id: format!("msg-{comm_id}"),
            parent_msg_id: Some("k1".into()),
            comm_id: comm_id.into(),
            data,
            buffers,
        }
    }

    fn comm_close_event(comm_id: &str) -> KernelEvent {
        KernelEvent::CommClose {
            parent_msg_id: Some("k1".into()),
            comm_id: comm_id.into(),
            data: json!({}),
        }
    }

    fn stream_event(parent: &str, text: &str) -> KernelEvent {
        KernelEvent::Stream {
            msg_id: format!("stream-{parent}"),
            parent_msg_id: Some(parent.into()),
            name: "stdout".into(),
            text: text.into(),
        }
    }

    #[test]
    fn callback_output_routes_to_the_widget_cell() {
        // A widget callback's output lands in the cell that shows the widget:
        // the core maps the callback's msg_id to that cell (comm_cell). A
        // status of the same msg_id is not a cell event.
        let (s, cid) = session_with_one_code_cell();
        s.widgets.comm_cell.insert("m1".into(), cid.clone());
        let (cell, payload) = s
            .apply_event(&stream_event("m1", "clicked\n"))
            .expect("the callback's output has no cell");
        assert_eq!(cell, cid);
        assert_eq!(payload["kind"], json!("stream"));
        assert_eq!(outputs(&s, &cid)[0]["text"], json!("clicked\n"));
        let busy = KernelEvent::Status {
            parent_msg_id: Some("m1".into()),
            execution_state: "busy".into(),
        };
        assert!(s.apply_event(&busy).is_none(), "a callback's status reached the cell");
    }

    #[test]
    fn widget_pre_consumes_comm_and_captured_output() {
        // A comm open, message and close are consumed by the store, and each
        // reaches Lua: the update with its buffer, the close with the model
        // removed. An output for a parent no Output widget captures is not
        // consumed. An output for a captured parent is consumed, goes to that
        // widget, and never reaches the cell.
        let (s, cid) = session_with_one_code_cell();
        let gen = s.widgets.store.lock().gen();
        let open = comm_open_event(
            "out1",
            json!({ "_model_name": "OutputModel", "msg_id": "cap1", "outputs": [] }),
        );
        let pre = s.widget_pre(&open, gen);
        assert!(pre.consumed, "a comm_open was not consumed");
        assert!(s.widgets.store.lock().get("out1").is_some(), "the model was not stored");

        let other = s.widget_pre(&stream_event("uncaptured", "x"), gen);
        assert!(!other.consumed, "an output nobody captures was consumed");
        assert!(other.effects.is_empty());

        let captured = s.widget_pre(&stream_event("cap1", "inside\n"), gen);
        assert!(captured.consumed, "a captured output was not consumed");
        assert!(
            matches!(captured.effects.first(), Some(Effect::Notify { .. })),
            "the captured output was not sent to Lua: {:?}",
            captured.effects
        );
        assert!(outputs(&s, &cid).is_empty(), "a captured output reached the cell");

        // A kernel-side update with a binary buffer, then a close of the same
        // model: both consumed, both reach Lua, and the close removes the model.
        let update = comm_msg_event(
            "out1",
            json!({ "method": "update", "state": {}, "buffer_paths": [["value"]] }),
            vec![Bytes::from_static(b"\x01\x02")],
        );
        let pre = s.widget_pre(&update, gen);
        assert!(pre.consumed, "a kernel comm_msg was not consumed");
        assert!(
            pre.effects.iter().any(
                |e| matches!(e, Effect::Notify { event, .. } if event["kind"] == json!("update"))
            ),
            "the kernel update was not sent to Lua: {:?}",
            pre.effects
        );
        let pre = s.widget_pre(&comm_close_event("out1"), gen);
        assert!(pre.consumed, "a kernel comm_close was not consumed");
        assert!(
            pre.effects.iter().any(
                |e| matches!(e, Effect::Notify { event, .. } if event["kind"] == json!("close"))
            ),
            "the kernel close was not sent to Lua: {:?}",
            pre.effects
        );
        assert!(
            s.widgets.store.lock().get("out1").is_none(),
            "the closed model is still stored"
        );
    }

    #[test]
    fn widget_pre_drops_events_of_an_older_kernel() {
        // After a restart the old kernel's events may still be queued in its
        // channel. Events of the old generation are consumed and open nothing;
        // the current generation opens its models.
        let (s, _) = session_with_one_code_cell();
        let old_gen = s.widgets.store.lock().gen();
        let _ = s.widgets_reset();
        let new_gen = s.widgets.store.lock().gen();
        assert!(new_gen > old_gen, "a reset did not move the generation on");

        let late = s.widget_pre(&comm_open_event("old", json!({ "_model_name": "ButtonModel" })), old_gen);
        assert!(late.consumed, "a late event of the old kernel was not consumed");
        assert!(late.effects.is_empty(), "a late event of the old kernel reached Lua");
        assert!(s.widgets.store.lock().get("old").is_none(), "a dead kernel's model came back");

        let fresh = s.widget_pre(&comm_open_event("new", json!({ "_model_name": "ButtonModel" })), new_gen);
        assert!(fresh.consumed);
        assert!(s.widgets.store.lock().get("new").is_some(), "the current kernel's model is missing");
    }

    #[test]
    fn widget_pre_consumes_status_of_our_messages() {
        // The busy and idle of a message the core sent are consumed: they do
        // not become kernel events. The idle ends the message (it is no longer
        // ours). A status of someone else's parent is not consumed.
        let (s, _) = session_with_one_code_cell();
        let gen = s.widgets.store.lock().gen();
        s.widget_pre(&comm_open_event("b", json!({ "_model_name": "ButtonModel" })), gen);
        let (_, msg_id) = s
            .widgets
            .store
            .lock()
            .frontend_custom("b", json!({ "event": "click" }), Vec::new(), None)
            .expect("the button is live");
        assert!(s.widgets.store.lock().is_ours(&msg_id), "setup: the click is not ours");

        let busy = KernelEvent::Status {
            parent_msg_id: Some(msg_id.clone()),
            execution_state: "busy".into(),
        };
        assert!(s.widget_pre(&busy, gen).consumed, "busy of our message was not consumed");
        let idle = KernelEvent::Status {
            parent_msg_id: Some(msg_id.clone()),
            execution_state: "idle".into(),
        };
        assert!(s.widget_pre(&idle, gen).consumed, "idle of our message was not consumed");
        assert!(!s.widgets.store.lock().is_ours(&msg_id), "the idle did not end our message");

        let unrelated = KernelEvent::Status {
            parent_msg_id: Some("unrelated".into()),
            execution_state: "idle".into(),
        };
        assert!(!s.widget_pre(&unrelated, gen).consumed, "an unrelated idle was consumed");
    }

    /// A notebook JSON: one code cell showing the widget views `shown`, and
    /// `metadata.widgets` holding the models `saved` (a version 2 block).
    fn widget_notebook(shown: &[&str], saved: &[&str]) -> Value {
        let mut state = serde_json::Map::new();
        for id in saved {
            state.insert(
                id.to_string(),
                json!({
                    "model_name": "IntSliderModel",
                    "model_module": "@jupyter-widgets/controls",
                    "model_module_version": "2.0.0",
                    "state": {"_model_name": "IntSliderModel", "value": 3},
                }),
            );
        }
        let outputs: Vec<Value> = shown
            .iter()
            .map(|id| {
                json!({
                    "output_type": "display_data",
                    "data": {
                        "application/vnd.jupyter.widget-view+json":
                            {"version_major": 2, "version_minor": 0, "model_id": id},
                        "text/plain": "IntSlider(value=3)",
                    },
                    "metadata": {},
                })
            })
            .collect();
        json!({
            "cells": [{
                "cell_type": "code", "id": "c1", "metadata": {}, "source": "w",
                "execution_count": 1, "outputs": outputs,
            }],
            "metadata": {
                "kernelspec": {"name": "python3", "display_name": "Python 3", "language": "python"},
                "widgets": {"application/vnd.jupyter.widget-state+json":
                    {"version_major": 2, "version_minor": 0, "state": state}},
            },
            "nbformat": 4,
            "nbformat_minor": 5,
        })
    }

    /// A notebook file in the temp dir, written from JSON and removed on drop.
    struct TempNb(PathBuf);

    impl TempNb {
        fn new(nb: &Value) -> Self {
            let path = std::env::temp_dir().join(format!(
                "jupynvim-widgets-{}-{}.ipynb",
                std::process::id(),
                uuid::Uuid::new_v4()
            ));
            std::fs::write(&path, nb.to_string()).expect("write the test notebook");
            Self(path)
        }

        fn read(&self) -> Value {
            let raw = std::fs::read_to_string(&self.0).expect("read the saved notebook");
            serde_json::from_str(&raw).expect("the saved notebook is JSON")
        }
    }

    impl Drop for TempNb {
        fn drop(&mut self) {
            let _ = std::fs::remove_file(&self.0);
        }
    }

    #[test]
    fn callback_update_display_reaches_the_cells() {
        // dh.update(...) inside a widget callback: the update reaches the cell
        // that holds the display, which is the callback's cell (comm_cell).
        let (s, cid) = session_with_one_code_cell();
        s.apply_event(&display("F1", Some("d1")));
        s.widgets.comm_cell.insert("m1".into(), cid.clone());
        let update = KernelEvent::UpdateDisplayData {
            msg_id: "u".into(),
            parent_msg_id: Some("m1".into()),
            data: json!({ "text/plain": "updated" }),
            metadata: json!({}),
            transient: json!({ "display_id": "d1" }),
        };
        let (cell, payload) = s
            .apply_event(&update)
            .expect("the callback's display update has no cell");
        assert_eq!(cell, cid);
        assert_eq!(payload["kind"], json!("update_display_data"));
        assert_eq!(payload["cells"], json!([cid]));
        assert_eq!(outputs(&s, &cid)[0]["data"], json!({ "text/plain": "updated" }));
    }

    #[test]
    fn a_restart_keeps_the_models_a_cell_shows() {
        // The roots of a reset are the views of the cells: the saved model a cell
        // shows stays dead, and the one no cell shows is dropped with the restart.
        let file = TempNb::new(&widget_notebook(&["a"], &["a", "b"]));
        let s = Session::open("s".into(), file.0.clone()).unwrap();
        let fx = s.widgets_reset();
        let pruned = match fx.first() {
            Some(crate::widgets::Effect::Notify { event, .. }) => event["pruned"].clone(),
            other => panic!("no reset event: {other:?}"),
        };
        assert_eq!(
            pruned,
            json!(["b"]),
            "only the model no cell shows is dropped"
        );
        let store = s.widgets.store.lock();
        assert!(store.get("a").is_some(), "the model the cell shows stays");
        assert!(store.get("b").is_none(), "the model nothing shows is gone");
    }

    #[test]
    fn a_restart_keeps_the_saved_link_between_shown_models_in_the_file() {
        // The notebook's saved state holds a jslink between the two sliders its cell
        // shows. A kernel start (every open runs one) and a save leave the link in the
        // file: the restart keeps it dead and the export writes it.
        let mut nb = widget_notebook(&["a", "b"], &["a", "b"]);
        nb["metadata"]["widgets"][STATE_MIME]["state"]["l"] = json!({
            "model_name": "LinkModel",
            "model_module": "@jupyter-widgets/controls",
            "model_module_version": "2.0.0",
            "state": {
                "_model_name": "LinkModel",
                "source": ["IPY_MODEL_a", "value"],
                "target": ["IPY_MODEL_b", "value"],
            },
        });
        let file = TempNb::new(&nb);
        let s = Session::open("s".into(), file.0.clone()).unwrap();
        let _ = s.widgets_reset();
        s.save().expect("the notebook saves");
        let saved = file.read();
        let state = &saved["metadata"]["widgets"][STATE_MIME]["state"];
        assert!(
            state.get("l").is_some(),
            "the link between the shown sliders was dropped from the file"
        );
        assert_eq!(state["l"]["state"]["target"], json!(["IPY_MODEL_b", "value"]));
    }

    #[test]
    fn an_output_widget_wins_over_the_callback_cell() {
        // interact runs its callback inside `with out:` on the update's msg_id. The
        // core maps that msg_id to the cell that shows the widget (comm_cell), and
        // the Output widget captures the same msg_id. The capture wins: the print
        // goes to the Output widget, and the cell gets nothing.
        let (s, cid) = session_with_one_code_cell();
        let gen = s.widgets.store.lock().gen();
        s.widgets.comm_cell.insert("m1".into(), cid.clone());
        let open = comm_open_event(
            "out2",
            json!({ "_model_name": "OutputModel", "msg_id": "m1", "outputs": [] }),
        );
        assert!(
            s.widget_pre(&open, gen).consumed,
            "the Output model was not opened"
        );

        // The pump's order: the widget step first, then the cell path for an
        // event the step did not consume.
        let ev = stream_event("m1", "value 7\n");
        let pre = s.widget_pre(&ev, gen);
        if !pre.consumed {
            let _ = s.apply_event(&ev);
        }
        assert!(
            outputs(&s, &cid).is_empty(),
            "the callback's print reached the cell"
        );
        assert!(
            pre.consumed,
            "the callback's print was not captured by the Output widget"
        );
        let shown = s
            .widgets
            .store
            .lock()
            .get("out2")
            .expect("the Output model is stored")
            .state["outputs"]
            .clone();
        assert_eq!(
            shown,
            json!([{ "output_type": "stream", "name": "stdout", "text": "value 7\n" }]),
            "the Output widget holds the print"
        );
    }

    #[test]
    fn open_moves_saved_widgets_into_the_store() {
        // The saved block leaves the notebook: its models become dead models
        // of the store, and the snapshot lists them for the frontend.
        let file = TempNb::new(&widget_notebook(&["a"], &["a", "b"]));
        let s = Session::open("s".into(), file.0.clone()).unwrap();
        assert!(
            s.notebook.read().metadata.get("widgets").is_none(),
            "metadata.widgets was kept in the notebook"
        );
        {
            let store = s.widgets.store.lock();
            assert_eq!(store.len(), 2, "the saved models did not reach the store");
            for id in ["a", "b"] {
                let m = store.get(id).expect("a saved model is missing from the store");
                assert!(!m.live, "a saved model is live before any kernel");
            }
        }
        let snap = serde_json::to_value(s.snapshot()).unwrap();
        let models = snap["widgets"].as_array().expect("the snapshot has no widgets");
        assert_eq!(models.len(), 2, "snapshot widgets: {models:?}");
        assert!(
            models.iter().all(|m| m["live"] == json!(false)),
            "a saved model is live in the snapshot"
        );
    }

    #[test]
    fn save_writes_reachable_widget_state() {
        // Only the models the cells show, and what they reach, are saved: b is
        // in the block, but no view shows it, so it is not written back.
        let file = TempNb::new(&widget_notebook(&["a"], &["a", "b"]));
        let s = Session::open("s".into(), file.0.clone()).unwrap();
        s.save().unwrap();
        let saved = file.read();
        let block = &saved["metadata"]["widgets"]["application/vnd.jupyter.widget-state+json"];
        let state = block["state"].as_object().cloned().unwrap_or_default();
        let ids: Vec<String> = state.keys().cloned().collect();
        assert_eq!(ids, vec!["a".to_string()], "saved models: {ids:?}");
        assert_eq!(block["state"]["a"]["state"]["value"], json!(3));
    }

    #[test]
    fn save_keeps_a_foreign_widgets_block() {
        // A block this version cannot read (format 3) is flagged, and is
        // written back exactly as it was saved.
        let foreign = json!({"application/vnd.jupyter.widget-state+json": {
            "version_major": 3, "version_minor": 0, "state": {"x": {"future": true}},
        }});
        let mut nb = widget_notebook(&[], &[]);
        nb["metadata"]["widgets"] = foreign.clone();
        let file = TempNb::new(&nb);
        let s = Session::open("s".into(), file.0.clone()).unwrap();
        assert!(s.widgets.store.lock().foreign_saved, "the unreadable block was not flagged");
        s.save().unwrap();
        assert_eq!(
            file.read()["metadata"]["widgets"],
            foreign,
            "the foreign block was not written back as it was"
        );
    }

    #[test]
    fn save_drops_widgets_when_no_view_is_left() {
        // Clearing the outputs leaves no view, so nothing is reachable and the
        // saved state goes with them.
        let file = TempNb::new(&widget_notebook(&["a"], &["a"]));
        let s = Session::open("s".into(), file.0.clone()).unwrap();
        s.clear_outputs();
        s.save().unwrap();
        assert!(
            file.read()["metadata"].get("widgets").is_none(),
            "the saved state outlived its views"
        );
    }

    /// The Colab shape: the state entries sit straight under the state mime,
    /// with no version_major, so the block cannot be read.
    fn colab_shaped_block() -> Value {
        json!({"application/vnd.jupyter.widget-state+json": {
            "old": {"model_name": "IntSliderModel", "model_module": "@jupyter-widgets/controls",
                    "state": {"value": 1}},
        }})
    }

    /// A foreign block is replaced by the state a live view reaches; once the
    /// outputs are cleared nothing is reachable, so the save writes the
    /// foreign block back as it was loaded, never the state of the earlier save.
    fn foreign_block_replaced_then_cleared(foreign: Value) {
        let mut nb = widget_notebook(&[], &[]);
        nb["metadata"]["widgets"] = foreign.clone();
        let file = TempNb::new(&nb);
        let s = Session::open("s".into(), file.0.clone()).unwrap();
        {
            let mut store = s.widgets.store.lock();
            let _ = store.comm_open(
                "k",
                "jupyter.widget",
                &json!({"state": {"_model_name": "IntSliderModel", "value": 1}}),
                &json!({}),
                &[],
            );
        }
        s.notebook.write().cells[0].outputs = vec![json!({
            "output_type": "display_data", "metadata": {},
            "data": {"application/vnd.jupyter.widget-view+json":
                {"version_major": 2, "version_minor": 0, "model_id": "k"}},
        })];
        s.save().unwrap();
        let first = file.read()["metadata"]["widgets"].clone();
        assert_eq!(
            first[STATE_MIME]["version_major"],
            json!(2),
            "setup: the reachable state did not replace the foreign block"
        );
        s.clear_outputs();
        s.save().unwrap();
        assert_eq!(
            file.read()["metadata"]["widgets"],
            foreign,
            "the save after the outputs were cleared did not write the foreign block back"
        );
    }

    #[test]
    fn foreign_v3_block_replaced_then_cleared_writes_the_original() {
        foreign_block_replaced_then_cleared(json!({"application/vnd.jupyter.widget-state+json": {
            "version_major": 3, "version_minor": 0, "state": {"x": {"future": true}},
        }}));
    }

    #[test]
    fn colab_block_replaced_then_cleared_writes_the_original() {
        foreign_block_replaced_then_cleared(colab_shaped_block());
    }

    #[test]
    fn save_does_not_keep_the_written_block_in_memory() {
        // The file gets the written block; the notebook keeps none, because the
        // store is the only copy of the widget state.
        let file = TempNb::new(&widget_notebook(&["a"], &["a"]));
        let s = Session::open("s".into(), file.0.clone()).unwrap();
        s.save().unwrap();
        assert!(
            file.read()["metadata"].get("widgets").is_some(),
            "setup: nothing was written"
        );
        assert!(
            s.snapshot().metadata.get("widgets").is_none(),
            "the written block stayed in the notebook metadata"
        );
    }

    #[test]
    fn widgets_siblings_survive_open_and_save() {
        // Only the state entry belongs to the store: a key next to it stays in
        // the notebook, is written back with the state, and is written alone
        // when no view is left.
        let mut nb = widget_notebook(&["a"], &["a"]);
        nb["metadata"]["widgets"]["sibling"] = json!({"x": 1});
        let file = TempNb::new(&nb);
        let s = Session::open("s".into(), file.0.clone()).unwrap();
        assert_eq!(
            s.snapshot().metadata["widgets"],
            json!({"sibling": {"x": 1}}),
            "open took more than the state entry"
        );
        s.save().unwrap();
        let saved = file.read();
        assert_eq!(
            saved["metadata"]["widgets"]["sibling"],
            json!({"x": 1}),
            "the sibling was lost on save"
        );
        assert_eq!(
            saved["metadata"]["widgets"][STATE_MIME]["state"]["a"]["state"]["value"],
            json!(3),
            "the reachable state was not written"
        );
        s.clear_outputs();
        s.save().unwrap();
        assert_eq!(
            file.read()["metadata"]["widgets"],
            json!({"sibling": {"x": 1}}),
            "the state entry outlived its views, or the sibling went with it"
        );
    }
}
