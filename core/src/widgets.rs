// Widget state in the core: the ipywidgets comm models of one kernel.
//
// The store is pure. Every method returns the effects the caller must run (a
// notification to Lua, a message to the kernel, a timer) and does no I/O and
// no await, so the rules are unit-testable and no lock is held across an
// await. The RPC layer runs the effects.
//
// A model id is the comm id. A binary buffer travels next to its
// `buffer_paths` entry: a path is a list of dict keys (strings) and list
// indices (numbers) below a top-level state key. Echoes (protocol 2.1) are
// filtered here and never reach Lua.

use std::collections::{HashMap, HashSet, VecDeque};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use anyhow::{anyhow, Result};
use base64::Engine as _;
use bytes::Bytes;
use serde_json::{json, Map, Value};
use uuid::Uuid;

use crate::kernel::{CommSender, KernelEvent};
use crate::notebook::{Cell, CellType};

pub const TARGET: &str = "jupyter.widget";
pub const STATE_MIME: &str = "application/vnd.jupyter.widget-state+json";
pub const VIEW_MIME: &str = "application/vnd.jupyter.widget-view+json";
pub const OUTPUT_FLUSH: Duration = Duration::from_millis(500);
pub const INFLIGHT_TIMEOUT: Duration = Duration::from_secs(2);
/// The most copies one change may set off along the links. A copy is an identity
/// and copies stop at the first value that agrees, so this is a guard only.
const LINK_STEP_LIMIT: usize = 10_000;

/// The time the store reads. In tests it is a clock that stands still until
/// `advance_clock` moves it, so the cadence rules are checked with no sleep and no
/// timing margin.
fn now() -> Instant {
    #[cfg(test)]
    {
        CLOCK.with(|c| {
            let t = c.get().unwrap_or_else(Instant::now);
            c.set(Some(t));
            t
        })
    }
    #[cfg(not(test))]
    {
        Instant::now()
    }
}

#[cfg(test)]
thread_local! {
    static CLOCK: std::cell::Cell<Option<Instant>> = const { std::cell::Cell::new(None) };
}

/// Moves the test clock forward by `by`.
#[cfg(test)]
fn advance_clock(by: Duration) {
    CLOCK.with(|c| c.set(Some(c.get().unwrap_or_else(Instant::now) + by)));
}

const MODEL_REF: &str = "IPY_MODEL_";
const OUTPUT_MODEL: &str = "OutputModel";

/// A path into a model state: JSON strings (dict keys) and numbers (0-based
/// list indices). The first element is always a top-level state key.
pub type BufPath = Vec<Value>;

pub struct Model {
    pub model_name: String,
    pub model_module: String,
    pub model_module_version: String,
    /// Binary values are absent here (a dict key) or null (a list slot).
    pub state: Map<String, Value>,
    pub buffers: Vec<(BufPath, Bytes)>,
    /// True while the comm is open on the current kernel.
    pub live: bool,
    /// attr -> msg_id of our last update that carried it.
    expected_echo: HashMap<String, String>,
    /// Our update in flight: its msg_id and when it was sent.
    inflight: Option<(String, Instant)>,
    /// Frontend changes waiting for the in-flight update to finish.
    pending: Map<String, Value>,
    pending_buffers: Vec<(BufPath, Bytes)>,
    pending_cell: Option<String>,
    /// OutputModel only.
    out_clear_pending: bool,
    out_flush_scheduled: bool,
    /// The msg_id of the outputs flush in flight: one flush at a time, answered by
    /// its idle (never by the update timeout).
    out_inflight: Option<String>,
    /// When the last outputs flush went out: the cadence counts from it.
    out_sent_at: Option<Instant>,
}

#[derive(Default)]
pub struct Store {
    models: HashMap<String, Model>,
    /// Captured parent msg_id -> Output model ids, newest last.
    capture: HashMap<String, Vec<String>>,
    /// Our comm_msg msg_id -> model id, while the update is in flight.
    inflight: HashMap<String, String>,
    /// msg_ids of every comm message we sent, until its status idle.
    ours: HashSet<String>,
    /// Output widgets whose captures wait to be sent (their outputs changed since
    /// their last flush). Kept here, so `flush_before_request` finds them without a
    /// walk over every model.
    out_waiting: HashSet<String>,
    /// Kernel generation: incremented by `reset`.
    gen: u64,
    /// metadata.widgets could not be parsed at open and was kept verbatim.
    pub foreign_saved: bool,
    /// The connected link models (LinkModel and DirectionalLinkModel), by id.
    links: HashMap<String, Link>,
    /// Model id -> the links that name it as an end. Kept for an end that is not
    /// connected yet, so a link waits for an end that opens after it.
    link_index: HashMap<String, Vec<String>>,
}

/// A comm message the kernel must receive.
#[derive(Debug, Clone)]
pub struct Outgoing {
    /// "comm_msg" or "comm_close".
    pub msg_type: &'static str,
    pub comm_id: String,
    pub data: Value,
    pub buffers: Vec<Bytes>,
    pub msg_id: String,
    /// The cell a frontend change or custom message names, so the callback's output
    /// goes there. None when the message names no cell (a copy a link makes, an Output
    /// widget's outputs flush, a change sent before its cell was drawn): the RPC layer
    /// then sends the callback's output to the first cell that shows the widget.
    pub cell_id: Option<String>,
}

#[derive(Debug)]
pub enum Effect {
    /// One widget_event to Lua.
    Notify { event: Value, buffers: Vec<Bytes> },
    /// To the kernel.
    Send(Outgoing),
    /// After `delay`, call `Store::flush_outputs` for the model.
    FlushOutputsAfter { model_id: String, delay: Duration },
    /// After `delay`, call `Store::inflight_timeout` for the model and msg_id.
    CheckInflightAfter {
        model_id: String,
        msg_id: String,
        delay: Duration,
    },
}

/// One end of a link: a model and the attribute the link copies.
#[derive(Debug, Clone, PartialEq, Eq)]
struct LinkEnd {
    model: String,
    attr: String,
}

/// A link model. A `LinkModel` (jslink) copies its source to its target and the
/// target back; a `DirectionalLinkModel` (jsdlink) copies the source only. VS Code
/// and JupyterLab do this in the frontend; the store does it here, so every frontend
/// shows the same values and the kernel holds them.
#[derive(Debug, Clone)]
struct Link {
    source: LinkEnd,
    target: LinkEnd,
    two_way: bool,
}

/// Session-level holder. The store is locked for each call and released before
/// any effect runs.
#[derive(Default)]
pub struct Widgets {
    pub store: parking_lot::Mutex<Store>,
    /// Our msg_id -> cell id, for the output of a callback.
    pub comm_cell: dashmap::DashMap<String, String>,
    /// The current kernel's sender; None without a kernel.
    pub comm_tx: parking_lot::RwLock<Option<CommSender>>,
}

impl Model {
    fn blank(name: String, module: String, version: String, live: bool) -> Self {
        Self {
            model_name: name,
            model_module: module,
            model_module_version: version,
            state: Map::new(),
            buffers: Vec::new(),
            live,
            expected_echo: HashMap::new(),
            inflight: None,
            pending: Map::new(),
            pending_buffers: Vec::new(),
            pending_cell: None,
            out_clear_pending: false,
            out_flush_scheduled: false,
            out_inflight: None,
            out_sent_at: None,
        }
    }

    /// A kernel restart: the model keeps its state and is no longer connected.
    fn disconnect(&mut self) {
        self.live = false;
        self.expected_echo.clear();
        self.inflight = None;
        self.pending.clear();
        self.pending_buffers.clear();
        self.pending_cell = None;
        self.out_clear_pending = false;
        self.out_flush_scheduled = false;
        self.out_inflight = None;
        self.out_sent_at = None;
    }
}

impl Store {
    /// Moves the saved widget state of a notebook into the store as dead models.
    /// Returns how many models were loaded.
    pub fn load_saved(&mut self, widgets_md: &Value) -> Result<usize> {
        let block = widgets_md
            .get(STATE_MIME)
            .ok_or_else(|| anyhow!("metadata.widgets has no {STATE_MIME} block"))?;
        let major = block.get("version_major").and_then(Value::as_u64);
        if major != Some(2) {
            return Err(anyhow!("unsupported widget state version_major {major:?}"));
        }
        let entries = block
            .get("state")
            .and_then(Value::as_object)
            .ok_or_else(|| anyhow!("widget state has no state object"))?;
        let mut loaded = 0;
        for (id, entry) in entries {
            let Some(name) = entry.get("model_name").and_then(Value::as_str) else {
                tracing::warn!(model = %id, "saved widget has no model_name; skipped");
                continue;
            };
            let Some(state) = entry.get("state").and_then(Value::as_object) else {
                tracing::warn!(model = %id, "saved widget has no state object; skipped");
                continue;
            };
            let mut model = Model::blank(
                name.to_string(),
                str_of(entry.get("model_module")),
                str_of(entry.get("model_module_version")),
                false,
            );
            let pairs = decode_saved_buffers(id, entry.get("buffers"));
            merge_update(&mut model.state, &mut model.buffers, state.clone(), pairs);
            self.models.insert(id.clone(), model);
            loaded += 1;
        }
        Ok(loaded)
    }

    /// comm_open from the kernel. Any target other than the widget target is
    /// closed back at once, so the kernel never waits on a comm nobody serves.
    pub fn comm_open(
        &mut self,
        comm_id: &str,
        target: &str,
        data: &Value,
        metadata: &Value,
        buffers: &[Bytes],
    ) -> Vec<Effect> {
        if target != TARGET {
            tracing::debug!(
                comm = comm_id,
                target,
                "comm for an unknown target closed back"
            );
            let effect = self.outgoing(
                "comm_close",
                comm_id,
                json!({}),
                Vec::new(),
                new_msg_id(),
                None,
            );
            return vec![effect];
        }
        check_protocol_version(metadata);
        let state = object_or_empty(data.get("state"));
        let pairs = pair_up(comm_id, parse_paths(data.get("buffer_paths")), buffers);
        let paths = paths_json(&pairs);
        let bufs = buffer_bytes(&pairs);
        let mut model = Model::blank(
            str_of(state.get("_model_name")),
            str_of(state.get("_model_module")),
            str_of(state.get("_model_module_version")),
            true,
        );
        merge_update(&mut model.state, &mut model.buffers, state, pairs);
        let event = json!({
            "kind": "open",
            "model_id": comm_id,
            "model_name": model.model_name,
            "model_module": model.model_module,
            "model_module_version": model.model_module_version,
            "state": Value::Object(model.state.clone()),
            "buffer_paths": paths,
            "live": true,
        });
        self.drop_model(comm_id);
        if model.model_name == OUTPUT_MODEL {
            let msg = str_of(model.state.get("msg_id"));
            if !msg.is_empty() {
                self.add_capture(&msg, comm_id);
            }
        }
        let link = link_of(&model);
        self.models.insert(comm_id.to_string(), model);
        let mut effects = vec![Effect::Notify {
            event,
            buffers: bufs,
        }];
        match link {
            Some(link) => {
                self.index_link(comm_id, link);
                effects.extend(self.apply_link(comm_id));
            }
            None => {
                // The links that name this model as an end apply now it is connected.
                let links = self.link_index.get(comm_id).cloned().unwrap_or_default();
                for link_id in links {
                    effects.extend(self.apply_link(&link_id));
                }
            }
        }
        effects
    }

    /// comm_msg from the kernel. `parent` is the msg_id of the request it answers.
    pub fn comm_msg(
        &mut self,
        comm_id: &str,
        data: &Value,
        buffers: &[Bytes],
        parent: Option<&str>,
    ) -> Vec<Effect> {
        let live = match self.models.get(comm_id) {
            Some(model) => model.live,
            None => return Vec::new(),
        };
        if !live {
            tracing::debug!(
                comm = comm_id,
                "comm message for a model that is not connected; dropped"
            );
            return Vec::new();
        }
        match data.get("method").and_then(Value::as_str).unwrap_or("") {
            "update" => self.kernel_update(comm_id, data, buffers),
            "echo_update" => self.kernel_echo(comm_id, data, buffers, parent),
            // The mirror does not read a custom message's buffers, so they are not
            // sent to Lua: the content is. A consumer of binary custom messages
            // reads them where it runs.
            "custom" => vec![Effect::Notify {
                event: json!({
                    "kind": "custom",
                    "model_id": comm_id,
                    "content": data.get("content").cloned().unwrap_or(Value::Null),
                }),
                buffers: Vec::new(),
            }],
            other => {
                tracing::debug!(comm = comm_id, method = other, "comm method not handled");
                Vec::new()
            }
        }
    }

    /// The kernel closed a comm: the model goes, with its captures.
    pub fn comm_close(&mut self, comm_id: &str) -> Vec<Effect> {
        if self.drop_model(comm_id).is_none() {
            return Vec::new();
        }
        vec![Effect::Notify {
            event: json!({ "kind": "close", "model_id": comm_id }),
            buffers: Vec::new(),
        }]
    }

    /// A kernel restart or stop: every model is disconnected and keeps its state,
    /// except the ones no code cell's view reaches (`roots` are the ids the views
    /// name). No cell can show those again, so they are dropped, and their ids go
    /// to Lua in the event. A link model whose two ends are kept stays as a dead
    /// model: the saved state holds it (export_saved keeps the same links), and a
    /// link that copies nothing is harmless. The live links go with the connection
    /// (`links` is cleared), and a new kernel opens new link models. The generation
    /// moves on so late events of the old kernel are dropped.
    pub fn reset(&mut self, roots: &[String]) -> Vec<Effect> {
        self.gen += 1;
        let keep: HashSet<String> = {
            let order = self.reach(roots);
            let position: HashMap<&str, usize> =
                order.iter().enumerate().map(|(i, id)| (*id, i)).collect();
            let mut keep: HashSet<String> = order.iter().map(|id| id.to_string()).collect();
            keep.extend(
                self.links_between(&position)
                    .into_iter()
                    .map(|(_, _, id)| id.to_string()),
            );
            keep
        };
        let mut pruned: Vec<String> = self
            .models
            .keys()
            .filter(|id| !keep.contains(id.as_str()))
            .cloned()
            .collect();
        pruned.sort();
        for id in &pruned {
            self.drop_model(id);
        }
        for model in self.models.values_mut() {
            model.disconnect();
        }
        self.capture.clear();
        self.inflight.clear();
        self.ours.clear();
        self.out_waiting.clear();
        self.links.clear();
        self.link_index.clear();
        vec![Effect::Notify {
            event: json!({ "kind": "reset", "pruned": pruned }),
            buffers: Vec::new(),
        }]
    }

    /// Routes an output event to the Output widget that captures `parent`, if any.
    /// None means the event belongs to the cell.
    pub fn route_output(&mut self, parent: &str, ev: &KernelEvent) -> Option<Vec<Effect>> {
        if !matches!(
            ev,
            KernelEvent::Stream { .. }
                | KernelEvent::DisplayData { .. }
                | KernelEvent::ExecuteResult { .. }
                | KernelEvent::Error { .. }
                | KernelEvent::ClearOutput { .. }
        ) {
            return None;
        }
        let id = self.capture.get(parent)?.last()?.clone();
        let model = self.models.get_mut(&id)?;
        if !model.live || model.model_name != OUTPUT_MODEL {
            return None;
        }
        let slot = model.state.entry("outputs").or_insert_with(|| json!([]));
        if !slot.is_array() {
            *slot = json!([]);
        }
        let outputs = slot.as_array_mut()?;
        let delta = apply_captured(outputs, &mut model.out_clear_pending, ev)?;
        self.out_waiting.insert(id.clone());
        let mut effects = vec![Effect::Notify {
            event: json!({ "kind": "output", "model_id": id, "event": delta }),
            buffers: Vec::new(),
        }];
        // While a flush is in flight no timer is armed: its idle paces what was
        // captured meanwhile (`paced_flush`).
        if !model.out_flush_scheduled && model.out_inflight.is_none() {
            model.out_flush_scheduled = true;
            effects.push(Effect::FlushOutputsAfter {
                model_id: id,
                delay: OUTPUT_FLUSH,
            });
        }
        Some(effects)
    }

    /// update_display_data: replaces the output of every Output widget that
    /// shows the display_id.
    pub fn update_display(
        &mut self,
        display_id: &str,
        data: &Value,
        metadata: &Value,
    ) -> Vec<Effect> {
        let mut effects = Vec::new();
        for (id, model) in self.models.iter_mut() {
            if !model.live || model.model_name != OUTPUT_MODEL {
                continue;
            }
            let Some(Value::Array(outs)) = model.state.get_mut("outputs") else {
                continue;
            };
            let mut hit = false;
            for out in outs.iter_mut() {
                let shows = out
                    .get("transient")
                    .and_then(|t| t.get("display_id"))
                    .and_then(Value::as_str)
                    == Some(display_id);
                if shows {
                    out["data"] = data.clone();
                    out["metadata"] = metadata.clone();
                    hit = true;
                }
            }
            if !hit {
                continue;
            }
            effects.push(Effect::Notify {
                event: json!({
                    "kind": "output",
                    "model_id": id,
                    "event": {
                        "kind": "update_display_data",
                        "display_id": display_id,
                        "data": data,
                        "metadata": metadata,
                    },
                }),
                buffers: Vec::new(),
            });
            self.out_waiting.insert(id.clone());
            if !model.out_flush_scheduled && model.out_inflight.is_none() {
                model.out_flush_scheduled = true;
                effects.push(Effect::FlushOutputsAfter {
                    model_id: id.clone(),
                    delay: OUTPUT_FLUSH,
                });
            }
        }
        effects
    }

    /// The kernel reported idle for `parent`: our message is done. An outputs flush
    /// in flight ends, and whatever was captured meanwhile goes out as `paced_flush`
    /// decides; an update in flight releases its held changes.
    pub fn on_idle(&mut self, parent: &str) -> Vec<Effect> {
        self.ours.remove(parent);
        let Some(model_id) = self.inflight.get(parent).cloned() else {
            return Vec::new();
        };
        let flush_done = self.models.get_mut(&model_id).is_some_and(|m| {
            if m.out_inflight.as_deref() == Some(parent) {
                m.out_inflight = None;
                true
            } else {
                false
            }
        });
        if flush_done {
            self.inflight.remove(parent);
            return self.paced_flush(&model_id);
        }
        self.release(&model_id, parent)
    }

    /// Sends the captured outputs of an Output widget when the cadence allows: after
    /// a capture end, after the idle of a flush, and from the timer (`flush_outputs`,
    /// which clears the flag first). A flush that went out less than OUTPUT_FLUSH ago
    /// is followed by the cadence timer for the rest of that time (one timer at a
    /// time); otherwise they go out now. A free kernel answers at once, so without
    /// this a `with out:` block per loop iteration would send one full copy of the
    /// outputs per block. A busy kernel's idle comes after the cadence, so its
    /// captures go out at once: one flush per round trip.
    fn paced_flush(&mut self, model_id: &str) -> Vec<Effect> {
        let waiting = self.out_waiting.contains(model_id);
        let Some(model) = self.models.get_mut(model_id) else {
            return Vec::new();
        };
        if !waiting || model.out_inflight.is_some() {
            return Vec::new();
        }
        if let Some(sent) = model.out_sent_at {
            let elapsed = now().saturating_duration_since(sent);
            if elapsed < OUTPUT_FLUSH {
                if model.out_flush_scheduled {
                    return Vec::new();
                }
                model.out_flush_scheduled = true;
                return vec![Effect::FlushOutputsAfter {
                    model_id: model_id.to_string(),
                    delay: OUTPUT_FLUSH - elapsed,
                }];
            }
        }
        self.send_outputs(model_id)
    }

    /// A frontend change (a slider drag, a text edit). It is applied at once and
    /// sent unless an update is in flight; then it waits for that one. A sent update
    /// is preceded by the captures waiting for the cadence; a held one sends nothing
    /// until it is released.
    /// Returns the msg_id when it was sent.
    pub fn frontend_update(
        &mut self,
        model_id: &str,
        state: Map<String, Value>,
        paths: Vec<BufPath>,
        buffers: Vec<Bytes>,
        cell_id: Option<String>,
    ) -> Result<(Vec<Effect>, Option<String>)> {
        let empty = is_empty_update(&state, &paths, &buffers);
        let pairs = pair_up(model_id, paths, &buffers);
        let model = self.live_model_mut(model_id)?;
        if empty {
            return Ok((Vec::new(), None));
        }
        merge_update(
            &mut model.state,
            &mut model.buffers,
            state.clone(),
            pairs.clone(),
        );
        // The change goes on along the links it is a source of (see propagate).
        let changed = self.changed_keys(model_id, &state, &pairs);
        // The copies this change makes name no cell: a callback of a copy's target
        // prints in the cell that shows the target, as for a copy the kernel's change
        // makes (see Outgoing::cell_id).
        let (mut effects, msg_id) = self.queue_for_kernel(model_id, state, pairs, cell_id);
        effects.extend(self.follow_change(model_id, changed));
        Ok((effects, msg_id))
    }

    /// A custom message from the frontend (a button click). Never merged. The
    /// captures waiting for the cadence go out first.
    pub fn frontend_custom(
        &mut self,
        model_id: &str,
        content: Value,
        buffers: Vec<Bytes>,
        cell_id: Option<String>,
    ) -> Result<(Vec<Effect>, String)> {
        self.live_model_mut(model_id)?;
        let mut effects = self.flush_before_request();
        let msg_id = new_msg_id();
        let effect = self.outgoing(
            "comm_msg",
            model_id,
            json!({ "method": "custom", "content": content }),
            buffers,
            msg_id.clone(),
            cell_id,
        );
        effects.push(effect);
        Ok((effects, msg_id))
    }

    /// The flush timer of an Output widget fired. The flag is cleared, and the
    /// captures go through `paced_flush`: they are sent when the cadence allows, and
    /// otherwise the rest of the cadence is armed again.
    pub fn flush_outputs(&mut self, model_id: &str) -> Vec<Effect> {
        if let Some(model) = self.models.get_mut(model_id) {
            model.out_flush_scheduled = false;
        }
        self.paced_flush(model_id)
    }

    /// Sends, at once, the captures of every Output widget that still waits for the
    /// cadence and has no flush in flight. It runs right before anything asks the
    /// kernel to run code: an execute request (`rpc/exec.rs` `execute` and
    /// `execute_silent`) and every update or custom message the core sends to a
    /// widget (`send_update`, `frontend_custom`), whose handler runs in the kernel.
    /// That code reads the outputs as they stand: a capture end held back by the
    /// cadence would be missing from them, and a handler that appends to the widget
    /// would drop it for good. A flush in flight is not overtaken (one flush in flight
    /// per widget); its idle then paces what is left.
    pub fn flush_before_request(&mut self) -> Vec<Effect> {
        let waiting: Vec<String> = self.out_waiting.iter().cloned().collect();
        waiting
            .iter()
            .flat_map(|id| self.send_outputs(id))
            .collect()
    }

    /// Sends an Output widget's captured outputs to the kernel if they changed and
    /// no flush is in flight. A busy kernel answers the flush only when the cell is
    /// done, so a second flush now would queue behind the first, each a full copy
    /// of the outputs. The flush in flight is ended by its idle (`on_idle`), which
    /// paces what was captured meanwhile. The flush flag is not touched here: it
    /// belongs to the timer (`flush_outputs`).
    fn send_outputs(&mut self, model_id: &str) -> Vec<Effect> {
        let Some(model) = self.models.get_mut(model_id) else {
            return Vec::new();
        };
        if !self.out_waiting.contains(model_id) || model.out_inflight.is_some() {
            return Vec::new();
        }
        self.out_waiting.remove(model_id);
        let msg_id = new_msg_id();
        let outputs = outputs_for_kernel(&model.state);
        model
            .expected_echo
            .insert("outputs".to_string(), msg_id.clone());
        model.out_inflight = Some(msg_id.clone());
        model.out_sent_at = Some(now());
        self.inflight.insert(msg_id.clone(), model_id.to_string());
        let data =
            json!({ "method": "update", "state": { "outputs": outputs }, "buffer_paths": [] });
        vec![self.outgoing("comm_msg", model_id, data, Vec::new(), msg_id, None)]
    }

    /// The timer of an update in flight fired: the kernel did not report idle in time.
    pub fn inflight_timeout(&mut self, model_id: &str, msg_id: &str) -> Vec<Effect> {
        self.release(model_id, msg_id)
    }

    /// The notebook metadata block for the widgets reachable from `roots`, in
    /// reach order. None when nothing is reachable.
    /// The models reached from `roots`, in reach order: breadth first, each model's
    /// references (IPY_MODEL_ strings in its state, and the views of an Output
    /// widget's outputs) after it.
    fn reach(&self, roots: &[String]) -> Vec<&str> {
        let mut seen: HashSet<&str> = HashSet::new();
        let mut order: Vec<&str> = Vec::new();
        let mut queue: VecDeque<&str> = VecDeque::new();
        for root in roots {
            if let Some((id, _)) = self.models.get_key_value(root.as_str()) {
                if seen.insert(id.as_str()) {
                    queue.push_back(id.as_str());
                }
            }
        }
        while let Some(id) = queue.pop_front() {
            order.push(id);
            let Some(model) = self.models.get(id) else {
                continue;
            };
            let mut refs: Vec<&str> = Vec::new();
            for value in model.state.values() {
                collect_model_refs(value, &mut refs);
            }
            if model.model_name == OUTPUT_MODEL {
                if let Some(Value::Array(outs)) = model.state.get("outputs") {
                    refs.extend(outs.iter().filter_map(view_model_id));
                }
            }
            for r in refs {
                if let Some((rid, _)) = self.models.get_key_value(r) {
                    if seen.insert(rid.as_str()) {
                        queue.push_back(rid.as_str());
                    }
                }
            }
        }
        order
    }

    /// The first cell, in the order given, whose views reach `model_id`: a cell shows a
    /// widget when the widget is one of its views or inside one (a box, a tab, an
    /// Output widget's outputs). `cells` holds each cell's id and the view ids its
    /// outputs show.
    pub fn first_cell_reaching(
        &self,
        cells: &[(String, Vec<String>)],
        model_id: &str,
    ) -> Option<String> {
        cells
            .iter()
            .find(|(_, views)| self.reach(views).contains(&model_id))
            .map(|(cell, _)| cell.clone())
    }

    /// The link models (LinkModel and DirectionalLinkModel) whose source and target
    /// models both have a position in `position` (the models kept, by their order).
    /// Sorted by (source position, target position, id). The saved state and the
    /// reset use this one rule, so the links a save writes are the links a restart keeps.
    fn links_between(&self, position: &HashMap<&str, usize>) -> Vec<(usize, usize, &str)> {
        let mut links: Vec<(usize, usize, &str)> = Vec::new();
        for (id, model) in &self.models {
            if !is_link_model(model) {
                continue;
            }
            let (Some(src), Some(dst)) = (
                link_end(model.state.get("source")),
                link_end(model.state.get("target")),
            ) else {
                continue;
            };
            if let (Some(&si), Some(&ti)) = (position.get(src), position.get(dst)) {
                links.push((si, ti, id.as_str()));
            }
        }
        links.sort();
        links
    }

    /// The widget state block for the models reachable from `roots`, in reach order,
    /// then the links whose two ends are reached. None when nothing is reachable.
    pub fn export_saved(&self, roots: &[String]) -> Option<Value> {
        let order = self.reach(roots);
        if order.is_empty() {
            return None;
        }

        // Links whose two ends are reached, in the order of their ends.
        let position: HashMap<&str, usize> =
            order.iter().enumerate().map(|(i, id)| (*id, i)).collect();
        let links = self.links_between(&position);

        let mut state = Map::new();
        for id in order
            .iter()
            .copied()
            .chain(links.iter().map(|(_, _, id)| *id))
        {
            if let Some(model) = self.models.get(id) {
                state.insert(id.to_string(), saved_entry(model));
            }
        }
        Some(json!({ "version_major": 2, "version_minor": 0, "state": state }))
    }

    /// Every model in the snapshot shape (sorted by model id).
    pub fn models_json(&self) -> Vec<Value> {
        let mut ids: Vec<&String> = self.models.keys().collect();
        ids.sort();
        ids.into_iter()
            .filter_map(|id| {
                self.models.get(id).map(|m| {
                    json!({
                        "model_id": id,
                        "model_name": m.model_name,
                        "model_module": m.model_module,
                        "model_module_version": m.model_module_version,
                        "state": state_without_transient(m),
                        "buffers": encoded_buffers(m),
                        "live": m.live,
                    })
                })
            })
            .collect()
    }

    /// Test access to one model (the Rust tests read the store through it).
    #[cfg(test)]
    pub fn get(&self, id: &str) -> Option<&Model> {
        self.models.get(id)
    }

    /// Test access to the number of models.
    #[cfg(test)]
    pub fn len(&self) -> usize {
        self.models.len()
    }

    /// Test access to the number of our messages in flight: comm updates and outputs
    /// flushes.
    #[cfg(test)]
    pub fn inflight_len(&self) -> usize {
        self.inflight.len()
    }

    pub fn gen(&self) -> u64 {
        self.gen
    }

    pub fn is_ours(&self, msg_id: &str) -> bool {
        self.ours.contains(msg_id)
    }

    fn live_model_mut(&mut self, id: &str) -> Result<&mut Model> {
        match self.models.get_mut(id) {
            None => Err(anyhow!("unknown widget model {id}")),
            Some(model) if !model.live => Err(anyhow!("widget {id} is not connected to a kernel")),
            Some(model) => Ok(model),
        }
    }

    /// A kernel update: applied, notified, and the Output capture moved if its msg_id changed.
    fn kernel_update(&mut self, model_id: &str, data: &Value, buffers: &[Bytes]) -> Vec<Effect> {
        let update = object_or_empty(data.get("state"));
        let pairs = pair_up(model_id, parse_paths(data.get("buffer_paths")), buffers);
        let event = json!({
            "kind": "update",
            "model_id": model_id,
            "state": Value::Object(update.clone()),
            "buffer_paths": paths_json(&pairs),
        });
        let bufs = buffer_bytes(&pairs);
        let changed = self.changed_keys(model_id, &update, &pairs);
        let Some(model) = self.models.get_mut(model_id) else {
            return Vec::new();
        };
        let is_output = model.model_name == OUTPUT_MODEL;
        let old_msg = if is_output {
            str_of(model.state.get("msg_id"))
        } else {
            String::new()
        };
        merge_update(&mut model.state, &mut model.buffers, update, pairs);
        let new_msg = if is_output {
            str_of(model.state.get("msg_id"))
        } else {
            String::new()
        };
        let mut effects = vec![Effect::Notify {
            event,
            buffers: bufs,
        }];
        if is_output && old_msg != new_msg {
            effects.extend(self.capture_changed(model_id, &old_msg, &new_msg));
        }
        effects.extend(self.follow_change(model_id, changed));
        effects
    }

    /// An echo of an update (protocol 2.1). The kernel echoes what it received.
    /// An echo of an older update is dropped. A matching echo (its parent is the
    /// update that last carried the attribute) clears the expectation, and is
    /// applied unless a newer frontend change to the attribute is still held:
    /// the kernel then holds what it echoes, and the store must follow it. An
    /// attribute we never sent (another frontend) is applied. Only what differs
    /// from the store is applied and notified, so a plain confirmation is silent.
    /// The Output widget's outputs flush is the exception: it is applied only
    /// when no frontend outputs change is held, no capture waits to be sent, and
    /// the echo differs from what the store would send, so a kernel-side change
    /// that raced the flush is followed.
    fn kernel_echo(
        &mut self,
        model_id: &str,
        data: &Value,
        buffers: &[Bytes],
        parent: Option<&str>,
    ) -> Vec<Effect> {
        let update = object_or_empty(data.get("state"));
        let pairs = pair_up(model_id, parse_paths(data.get("buffer_paths")), buffers);
        let waiting = self.out_waiting.contains(model_id);
        let Some(model) = self.models.get_mut(model_id) else {
            return Vec::new();
        };
        let is_output = model.model_name == OUTPUT_MODEL;
        let mut applied: Vec<String> = Vec::new();
        for key in touched_keys(&update, &pairs) {
            let apply = match model.expected_echo.get(&key).cloned() {
                None => true,
                Some(expected) if parent == Some(expected.as_str()) => {
                    model.expected_echo.remove(&key);
                    if is_output && key == "outputs" {
                        // Our flush carries the outputs without transient. Captures
                        // not yet sent count as held (out_waiting), and a frontend
                        // outputs change still held keeps the matching echo out
                        // (is_held). An echo equal to what we sent is a
                        // confirmation. One that differs means the kernel changed
                        // its outputs after our flush (an append in the same cell),
                        // and the kernel holds what it echoes.
                        !is_held(model, &key)
                            && !waiting
                            && update
                                .get(&key)
                                .is_some_and(|v| !outputs_match(v, &model.state))
                    } else {
                        !is_held(model, &key)
                    }
                }
                Some(_) => false,
            };
            if apply && echo_changes(model, &key, &update, &pairs) {
                applied.push(key);
            }
        }
        if applied.is_empty() {
            return Vec::new();
        }
        let kept_state: Map<String, Value> = update
            .into_iter()
            .filter(|(key, _)| applied.contains(key))
            .collect();
        let kept_pairs: Vec<(BufPath, Bytes)> = pairs
            .into_iter()
            .filter(|(path, _)| head(path).is_some_and(|h| applied.iter().any(|k| k == h)))
            .collect();
        let event = json!({
            "kind": "update",
            "model_id": model_id,
            "state": Value::Object(kept_state.clone()),
            "buffer_paths": paths_json(&kept_pairs),
        });
        let bufs = buffer_bytes(&kept_pairs);
        merge_update(&mut model.state, &mut model.buffers, kept_state, kept_pairs);
        // An applied echo is a change of the model like any other: its links follow.
        let mut effects = vec![Effect::Notify {
            event,
            buffers: bufs,
        }];
        effects.extend(self.follow_change(model_id, applied));
        effects
    }

    /// An Output widget's msg_id changed: the old capture ends, and its captures go
    /// to the kernel through `paced_flush` (at once when the last flush went out a
    /// cadence ago, otherwise with the cadence timer); the new capture, if any,
    /// starts.
    fn capture_changed(&mut self, model_id: &str, old: &str, new: &str) -> Vec<Effect> {
        let mut effects = Vec::new();
        if !old.is_empty() {
            let empty = match self.capture.get_mut(old) {
                Some(ids) => {
                    ids.retain(|m| m.as_str() != model_id);
                    ids.is_empty()
                }
                None => false,
            };
            if empty {
                self.capture.remove(old);
            }
            effects.extend(self.paced_flush(model_id));
        }
        if !new.is_empty() {
            self.add_capture(new, model_id);
        }
        effects
    }

    fn add_capture(&mut self, parent: &str, model_id: &str) {
        let ids = self.capture.entry(parent.to_string()).or_default();
        ids.retain(|m| m.as_str() != model_id);
        ids.push(model_id.to_string());
    }

    /// Removes a model and every reference to it. Returns the model.
    fn drop_model(&mut self, id: &str) -> Option<Model> {
        let model = self.models.remove(id)?;
        self.out_waiting.remove(id);
        self.capture.retain(|_, ids| {
            ids.retain(|m| m.as_str() != id);
            !ids.is_empty()
        });
        self.inflight.retain(|_, m| m.as_str() != id);
        self.unindex_link(id);
        Some(model)
    }

    /// Our update `msg_id` for `model_id` is done (idle or timed out). If it is
    /// still the model's update in flight, the held changes go out now.
    fn release(&mut self, model_id: &str, msg_id: &str) -> Vec<Effect> {
        self.inflight.remove(msg_id);
        let Some(model) = self.models.get_mut(model_id) else {
            return Vec::new();
        };
        let current = model.inflight.as_ref().is_some_and(|(id, _)| id == msg_id);
        if !current {
            return Vec::new();
        }
        model.inflight = None;
        if model.pending.is_empty() && model.pending_buffers.is_empty() {
            return Vec::new();
        }
        let state = std::mem::take(&mut model.pending);
        let pairs = std::mem::take(&mut model.pending_buffers);
        let cell = model.pending_cell.take();
        let (effects, _) = self.send_update(model_id, state, pairs, cell);
        effects
    }

    /// Sends one update for `model_id`, after the captures waiting for the cadence,
    /// and records its echo expectations and its in-flight entry. Returns the effects
    /// and the msg_id.
    fn send_update(
        &mut self,
        model_id: &str,
        state: Map<String, Value>,
        pairs: Vec<(BufPath, Bytes)>,
        cell_id: Option<String>,
    ) -> (Vec<Effect>, String) {
        let mut effects = self.flush_before_request();
        let msg_id = new_msg_id();
        let touched = touched_keys(&state, &pairs);
        let paths = paths_json(&pairs);
        let bufs = buffer_bytes(&pairs);
        if let Some(model) = self.models.get_mut(model_id) {
            for key in touched {
                model.expected_echo.insert(key, msg_id.clone());
            }
            if let Some((old, _)) = model.inflight.replace((msg_id.clone(), now())) {
                self.inflight.remove(&old);
            }
        }
        self.inflight.insert(msg_id.clone(), model_id.to_string());
        let data =
            json!({ "method": "update", "state": Value::Object(state), "buffer_paths": paths });
        let send = self.outgoing("comm_msg", model_id, data, bufs, msg_id.clone(), cell_id);
        let check = Effect::CheckInflightAfter {
            model_id: model_id.to_string(),
            msg_id: msg_id.clone(),
            delay: INFLIGHT_TIMEOUT,
        };
        effects.push(send);
        effects.push(check);
        (effects, msg_id)
    }

    fn is_connected(&self, model_id: &str) -> bool {
        self.models.get(model_id).is_some_and(|m| m.live)
    }

    /// The keys a change of `model_id` touches, when it is a link model or an end
    /// of one. Any other model costs nothing.
    fn changed_keys(
        &self,
        model_id: &str,
        state: &Map<String, Value>,
        pairs: &[(BufPath, Bytes)],
    ) -> Vec<String> {
        // A link model counts by its class, so one whose ends arrive later is seen
        // when they do (follow_change relinks it).
        let link = self.models.get(model_id).is_some_and(is_link_model);
        if link || self.link_index.contains_key(model_id) {
            touched_keys(state, pairs)
        } else {
            Vec::new()
        }
    }

    /// The attributes `keys` of `model_id` changed (applied, not only sent). A link
    /// model whose ends changed is linked again, and the changes go on along the
    /// links the model is an end of.
    fn follow_change(&mut self, model_id: &str, keys: Vec<String>) -> Vec<Effect> {
        if keys.is_empty() {
            return Vec::new();
        }
        let mut effects = Vec::new();
        let link = self.models.get(model_id).is_some_and(is_link_model);
        if link && keys.iter().any(|k| k == "source" || k == "target") {
            effects.extend(self.relink(model_id));
        }
        if self.link_index.contains_key(model_id) {
            let changed = keys
                .into_iter()
                .map(|k| (model_id.to_string(), k))
                .collect();
            effects.extend(self.propagate(changed));
        }
        effects
    }

    /// Records a link model with its ends (again, when its ends changed), so a
    /// change of either end finds it.
    fn index_link(&mut self, link_id: &str, link: Link) {
        self.unindex_link(link_id);
        for end in [&link.source.model, &link.target.model] {
            let ids = self.link_index.entry(end.clone()).or_default();
            if !ids.iter().any(|id| id.as_str() == link_id) {
                ids.push(link_id.to_string());
            }
        }
        self.links.insert(link_id.to_string(), link);
    }

    /// Forgets a link model: it copies nothing from now on.
    fn unindex_link(&mut self, link_id: &str) {
        let Some(link) = self.links.remove(link_id) else {
            return;
        };
        for end in [link.source.model, link.target.model] {
            let empty = match self.link_index.get_mut(&end) {
                Some(ids) => {
                    ids.retain(|id| id.as_str() != link_id);
                    ids.is_empty()
                }
                None => false,
            };
            if empty {
                self.link_index.remove(&end);
            }
        }
    }

    /// A link model's ends changed: it is indexed again, and applied.
    fn relink(&mut self, link_id: &str) -> Vec<Effect> {
        match self.models.get(link_id).and_then(link_of) {
            Some(link) => {
                self.index_link(link_id, link);
                self.apply_link(link_id)
            }
            None => {
                self.unindex_link(link_id);
                Vec::new()
            }
        }
    }

    /// Copies a link's source to its target once both ends are connected, as the
    /// frontend does when a link opens. The target's change then goes on along its
    /// own links.
    fn apply_link(&mut self, link_id: &str) -> Vec<Effect> {
        let Some(link) = self.links.get(link_id).cloned() else {
            return Vec::new();
        };
        if !self.is_connected(&link.source.model) || !self.is_connected(&link.target.model) {
            return Vec::new();
        }
        let (mut effects, changed) = self.copy_attr(&link.source, &link.target);
        if changed {
            effects.extend(self.propagate(vec![(link.target.model, link.target.attr)]));
        }
        effects
    }

    /// The changes of the (model, attribute) pairs in `changed` go on along the links.
    /// A link whose source is a changed attribute copies it to its target, and the
    /// target's change goes on the same way; a two-way link copies a target change
    /// back to its source. A copy writes only a value that differs, so copying back
    /// the value a model came from is a no-op, and a loop of links ends once the
    /// values agree. That is the updating flag of the frontend's link, by value.
    fn propagate(&mut self, changed: Vec<(String, String)>) -> Vec<Effect> {
        let mut effects = Vec::new();
        let mut queue: VecDeque<(String, String)> = changed.into();
        let mut steps = 0usize;
        while let Some((model_id, attr)) = queue.pop_front() {
            let Some(link_ids) = self.link_index.get(&model_id).cloned() else {
                continue;
            };
            for link_id in link_ids {
                let Some(link) = self.links.get(&link_id).cloned() else {
                    continue;
                };
                let (from, to) = if link.source.model == model_id && link.source.attr == attr {
                    (link.source, link.target)
                } else if link.two_way && link.target.model == model_id && link.target.attr == attr
                {
                    (link.target, link.source)
                } else {
                    continue;
                };
                steps += 1;
                if steps > LINK_STEP_LIMIT {
                    tracing::warn!(
                        "widget links did not settle; the rest of their copies are skipped"
                    );
                    return effects;
                }
                let (sent, changed) = self.copy_attr(&from, &to);
                effects.extend(sent);
                if changed {
                    queue.push_back((to.model, to.attr));
                }
            }
        }
        effects
    }

    /// Copies the attribute `from` names to the one `to` names, when the value or its
    /// buffers differ. The copy is a change of the target: its state and buffers are
    /// applied, Lua is told of the target at once, and the change is queued for the
    /// kernel as a frontend change is, naming no cell (its callback output goes to the
    /// cell that shows the target). Returns the effects and whether the target changed.
    fn copy_attr(&mut self, from: &LinkEnd, to: &LinkEnd) -> (Vec<Effect>, bool) {
        if !self.is_connected(&to.model) {
            return (Vec::new(), false);
        }
        let Some(source) = self.models.get(&from.model) else {
            return (Vec::new(), false);
        };
        let (value, pairs) = attr_of(source, &from.attr);
        if value.is_none() && pairs.is_empty() {
            return (Vec::new(), false);
        }
        // A buffer's path starts with the attribute it sits under: the target's.
        let pairs: Vec<(BufPath, Bytes)> = pairs
            .into_iter()
            .map(|(mut path, bytes)| {
                if let Some(first) = path.first_mut() {
                    *first = Value::String(to.attr.clone());
                }
                (path, bytes)
            })
            .collect();
        let Some(target) = self.models.get(&to.model) else {
            return (Vec::new(), false);
        };
        let (current, current_pairs) = attr_of(target, &to.attr);
        if current == value && same_pairs(&current_pairs, &pairs) {
            return (Vec::new(), false);
        }
        let mut update = Map::new();
        if let Some(v) = &value {
            update.insert(to.attr.clone(), v.clone());
        }
        let Some(target) = self.models.get_mut(&to.model) else {
            return (Vec::new(), false);
        };
        merge_update(
            &mut target.state,
            &mut target.buffers,
            update.clone(),
            pairs.clone(),
        );
        let event = json!({
            "kind": "update",
            "model_id": to.model,
            "state": Value::Object(update.clone()),
            "buffer_paths": paths_json(&pairs),
        });
        let mut effects = vec![Effect::Notify {
            event,
            buffers: buffer_bytes(&pairs),
        }];
        let (sent, _) = self.queue_for_kernel(&to.model, update, pairs, None);
        effects.extend(sent);
        (effects, true)
    }

    /// Queues a change for the kernel the way a frontend change is queued: sent at
    /// once unless an update is in flight, then held until that one is released. The
    /// caller has applied the change to the model's state. Returns the effects and
    /// the msg_id when the change was sent.
    fn queue_for_kernel(
        &mut self,
        model_id: &str,
        state: Map<String, Value>,
        pairs: Vec<(BufPath, Bytes)>,
        cell_id: Option<String>,
    ) -> (Vec<Effect>, Option<String>) {
        let Some(model) = self.models.get_mut(model_id) else {
            return (Vec::new(), None);
        };
        let held = matches!(&model.inflight, Some((_, sent)) if now().saturating_duration_since(*sent) < INFLIGHT_TIMEOUT);
        merge_update(&mut model.pending, &mut model.pending_buffers, state, pairs);
        if held {
            if cell_id.is_some() {
                model.pending_cell = cell_id;
            }
            return (Vec::new(), None);
        }
        // Nothing in flight, or the one in flight is too old to wait for: send
        // everything held, as one update.
        let stale = model.inflight.take().map(|(id, _)| id);
        let state = std::mem::take(&mut model.pending);
        let pairs = std::mem::take(&mut model.pending_buffers);
        let cell = cell_id.or_else(|| model.pending_cell.take());
        model.pending_cell = None;
        if let Some(old) = stale {
            self.inflight.remove(&old);
        }
        let (effects, msg_id) = self.send_update(model_id, state, pairs, cell);
        (effects, Some(msg_id))
    }

    /// A message we send. Its msg_id is ours until the kernel reports idle for it.
    fn outgoing(
        &mut self,
        msg_type: &'static str,
        comm_id: &str,
        data: Value,
        buffers: Vec<Bytes>,
        msg_id: String,
        cell_id: Option<String>,
    ) -> Effect {
        self.ours.insert(msg_id.clone());
        Effect::Send(Outgoing {
            msg_type,
            comm_id: comm_id.to_string(),
            data,
            buffers,
            msg_id,
            cell_id,
        })
    }
}

/// Applies one captured kernel event to an Output widget's `outputs`. Returns
/// the delta for Lua, or None when the event is not an output kind.
fn apply_captured(
    outputs: &mut Vec<Value>,
    clear_pending: &mut bool,
    ev: &KernelEvent,
) -> Option<Value> {
    let is_output = matches!(
        ev,
        KernelEvent::Stream { .. }
            | KernelEvent::DisplayData { .. }
            | KernelEvent::ExecuteResult { .. }
            | KernelEvent::Error { .. }
    );
    let mut clear_first = false;
    if is_output && *clear_pending {
        outputs.clear();
        *clear_pending = false;
        clear_first = true;
    }
    let mut delta = match ev {
        KernelEvent::Stream { name, text, .. } => {
            let coalesced = match outputs.last_mut() {
                Some(last) if last["output_type"] == "stream" && last["name"] == name.as_str() => {
                    match last.get_mut("text") {
                        Some(Value::String(prev)) => prev.push_str(text),
                        _ => last["text"] = Value::String(text.clone()),
                    }
                    true
                }
                _ => false,
            };
            if !coalesced {
                outputs.push(json!({ "output_type": "stream", "name": name, "text": text }));
            }
            json!({ "kind": "stream", "name": name, "text": text })
        }
        KernelEvent::DisplayData {
            data,
            metadata,
            transient,
            ..
        } => {
            let mut out =
                json!({ "output_type": "display_data", "data": data, "metadata": metadata });
            // Kept so update_display_data can find this output; saved notebooks drop it.
            if transient.get("display_id").is_some() {
                out["transient"] = transient.clone();
            }
            outputs.push(out);
            json!({ "kind": "display_data", "data": data, "metadata": metadata, "transient": transient })
        }
        KernelEvent::ExecuteResult {
            execution_count,
            data,
            metadata,
            ..
        } => {
            outputs.push(json!({
                "output_type": "execute_result",
                "execution_count": execution_count,
                "data": data,
                "metadata": metadata,
            }));
            json!({
                "kind": "execute_result",
                "execution_count": execution_count,
                "data": data,
                "metadata": metadata,
            })
        }
        KernelEvent::Error {
            ename,
            evalue,
            traceback,
            ..
        } => {
            outputs.push(json!({
                "output_type": "error",
                "ename": ename,
                "evalue": evalue,
                "traceback": traceback,
            }));
            json!({ "kind": "error", "ename": ename, "evalue": evalue, "traceback": traceback })
        }
        KernelEvent::ClearOutput { wait, .. } => {
            if *wait {
                *clear_pending = true;
            } else {
                outputs.clear();
                *clear_pending = false;
            }
            json!({ "kind": "clear_output", "wait": wait })
        }
        _ => return None,
    };
    if clear_first {
        delta["clear_first"] = json!(true);
    }
    Some(delta)
}

/// Warns once when a widget protocol major version other than 2 shows up.
/// The message is accepted either way.
static PROTOCOL_MAJOR_WARNED: AtomicBool = AtomicBool::new(false);

fn check_protocol_version(metadata: &Value) {
    let version = metadata
        .get("version")
        .and_then(Value::as_str)
        .unwrap_or("");
    let major = version.split('.').next().unwrap_or("");
    if major != "2" && !PROTOCOL_MAJOR_WARNED.swap(true, Ordering::Relaxed) {
        tracing::warn!(
            version,
            "widget protocol major version is not 2; accepted anyway"
        );
    }
}

fn new_msg_id() -> String {
    Uuid::new_v4().to_string()
}

fn str_of(v: Option<&Value>) -> String {
    v.and_then(Value::as_str).unwrap_or("").to_string()
}

/// A state that is not an object (Lua sends an empty table as an array)
/// counts as empty.
fn object_or_empty(v: Option<&Value>) -> Map<String, Value> {
    v.and_then(Value::as_object).cloned().unwrap_or_default()
}

fn head(path: &[Value]) -> Option<&str> {
    path.first()?.as_str()
}

fn valid_path(path: &[Value]) -> bool {
    head(path).is_some() && path.iter().all(|seg| seg.is_string() || seg.is_u64())
}

/// Whether a frontend update has nothing for the store to apply: no state key,
/// and no buffer whose path is valid (the store drops the others, see
/// `pair_up`). Such an update is neither sent nor held.
pub fn is_empty_update(state: &Map<String, Value>, paths: &[BufPath], buffers: &[Bytes]) -> bool {
    state.is_empty() && !paths.iter().zip(buffers).any(|(path, _)| valid_path(path))
}

/// The `buffer_paths` of a message. An entry that is not a list becomes an
/// empty path, which `pair_up` drops together with its buffer.
pub fn parse_paths(v: Option<&Value>) -> Vec<BufPath> {
    v.and_then(Value::as_array)
        .map(|paths| {
            paths
                .iter()
                .map(|p| p.as_array().cloned().unwrap_or_default())
                .collect()
        })
        .unwrap_or_default()
}

/// Pairs each buffer with its path. A path that is not valid drops its buffer
/// too, so the rest stay aligned.
fn pair_up(model_id: &str, paths: Vec<BufPath>, buffers: &[Bytes]) -> Vec<(BufPath, Bytes)> {
    if paths.len() != buffers.len() {
        tracing::warn!(
            model = model_id,
            paths = paths.len(),
            buffers = buffers.len(),
            "widget buffer_paths and buffers differ in length"
        );
    }
    paths
        .into_iter()
        .zip(buffers.iter().cloned())
        .filter_map(|(path, buf)| {
            if valid_path(&path) {
                Some((path, buf))
            } else {
                tracing::warn!(
                    model = model_id,
                    "widget buffer with an invalid path dropped"
                );
                None
            }
        })
        .collect()
}

fn paths_json(pairs: &[(BufPath, Bytes)]) -> Value {
    Value::Array(
        pairs
            .iter()
            .map(|(path, _)| Value::Array(path.clone()))
            .collect(),
    )
}

fn buffer_bytes(pairs: &[(BufPath, Bytes)]) -> Vec<Bytes> {
    pairs.iter().map(|(_, buf)| buf.clone()).collect()
}

/// The top-level keys an update touches: its state keys and the first element
/// of each buffer path.
fn touched_keys(state: &Map<String, Value>, pairs: &[(BufPath, Bytes)]) -> Vec<String> {
    let mut keys: Vec<String> = state.keys().cloned().collect();
    for (path, _) in pairs {
        if let Some(h) = head(path) {
            if !keys.iter().any(|k| k == h) {
                keys.push(h.to_string());
            }
        }
    }
    keys
}

/// Whether a frontend change to `key` is still waiting to be sent.
fn is_held(model: &Model, key: &str) -> bool {
    model.pending.contains_key(key)
        || model
            .pending_buffers
            .iter()
            .any(|(path, _)| head(path) == Some(key))
}

/// Whether an echoed attribute differs from what the store holds: its value,
/// or its buffers.
fn echo_changes(
    model: &Model,
    key: &str,
    update: &Map<String, Value>,
    pairs: &[(BufPath, Bytes)],
) -> bool {
    let value_changes = match update.get(key) {
        Some(value) => model.state.get(key) != Some(value),
        None => model.state.contains_key(key),
    };
    if value_changes {
        return true;
    }
    let echoed: Vec<&(BufPath, Bytes)> = pairs
        .iter()
        .filter(|(path, _)| head(path) == Some(key))
        .collect();
    let held: Vec<&(BufPath, Bytes)> = model
        .buffers
        .iter()
        .filter(|(path, _)| head(path) == Some(key))
        .collect();
    echoed.len() != held.len() || echoed.iter().any(|pair| !held.contains(pair))
}

/// Applies an update to a state and its buffers. A touched key takes the
/// update's value, or is removed when the update has none (a binary value
/// arrives as a buffer, not as a key). Returns the touched keys.
fn merge_update(
    state: &mut Map<String, Value>,
    buffers: &mut Vec<(BufPath, Bytes)>,
    update: Map<String, Value>,
    pairs: Vec<(BufPath, Bytes)>,
) -> Vec<String> {
    let touched = touched_keys(&update, &pairs);
    for key in &touched {
        match update.get(key) {
            Some(value) => {
                state.insert(key.clone(), value.clone());
            }
            None => {
                // shift_remove keeps the order of the other keys (serde_json's
                // preserve_order makes remove a swap_remove).
                state.shift_remove(key);
            }
        }
    }
    // The buffer is the value: its slot is absent (dict key) or null (list slot).
    for (path, _) in &pairs {
        strip_path(state, path);
    }
    buffers.retain(|(path, _)| !head(path).is_some_and(|h| touched.iter().any(|t| t == h)));
    buffers.extend(pairs);
    touched
}

/// Saved buffers: `{encoding, path, data}` with base64 or hex data.
fn decode_saved_buffers(model_id: &str, list: Option<&Value>) -> Vec<(BufPath, Bytes)> {
    let Some(items) = list.and_then(Value::as_array) else {
        return Vec::new();
    };
    let mut out = Vec::with_capacity(items.len());
    for item in items {
        let path = item.get("path").and_then(Value::as_array).cloned();
        let data = item.get("data").and_then(Value::as_str);
        let bytes = match (item.get("encoding").and_then(Value::as_str), data) {
            (Some("base64"), Some(d)) => base64::engine::general_purpose::STANDARD.decode(d).ok(),
            (Some("hex"), Some(d)) => hex::decode(d).ok(),
            _ => None,
        };
        match (path, bytes) {
            (Some(p), Some(b)) if valid_path(&p) => out.push((p, Bytes::from(b))),
            _ => tracing::warn!(
                model = model_id,
                "saved widget buffer skipped (encoding, data or path)"
            ),
        }
    }
    out
}

/// Removes the binary value a path names: a dict key is removed, a list slot is set to null.
fn strip_path(state: &mut Map<String, Value>, path: &[Value]) {
    match path {
        [Value::String(key)] => {
            state.shift_remove(key);
        }
        [Value::String(key), rest @ ..] => {
            if let Some(value) = state.get_mut(key) {
                strip_in(value, rest);
            }
        }
        _ => {}
    }
}

fn strip_in(value: &mut Value, path: &[Value]) {
    let Some((last, parents)) = path.split_last() else {
        return;
    };
    let mut cur = value;
    for seg in parents {
        match child_mut(cur, seg) {
            Some(next) => cur = next,
            None => return,
        }
    }
    match (cur, last) {
        (Value::Object(map), Value::String(key)) => {
            map.shift_remove(key);
        }
        (Value::Array(list), Value::Number(index)) => {
            if let Some(slot) = index
                .as_u64()
                .and_then(|i| usize::try_from(i).ok())
                .and_then(|i| list.get_mut(i))
            {
                *slot = Value::Null;
            }
        }
        _ => {}
    }
}

fn child_mut<'a>(value: &'a mut Value, seg: &Value) -> Option<&'a mut Value> {
    match (value, seg) {
        (Value::Object(map), Value::String(key)) => map.get_mut(key),
        (Value::Array(list), Value::Number(index)) => {
            let i = usize::try_from(index.as_u64()?).ok()?;
            list.get_mut(i)
        }
        _ => None,
    }
}

/// The state without transient, as saved and as sent to the kernel: an
/// Output widget's outputs never carry the display_id bookkeeping.
fn state_without_transient(m: &Model) -> Value {
    let mut state = m.state.clone();
    if m.model_name == OUTPUT_MODEL {
        if let Some(Value::Array(outs)) = state.get_mut("outputs") {
            for out in outs.iter_mut() {
                if let Some(obj) = out.as_object_mut() {
                    obj.shift_remove("transient");
                }
            }
        }
    }
    Value::Object(state)
}

/// Whether an echoed outputs list is the list the store would send: the same
/// outputs in the same order. transient is left out of the comparison, because
/// the store keeps it and the kernel never holds it.
fn outputs_match(echoed: &Value, state: &Map<String, Value>) -> bool {
    let Some(echoed) = echoed.as_array() else {
        return false;
    };
    let stored: &[Value] = match state.get("outputs") {
        Some(Value::Array(outs)) => outs,
        _ => &[],
    };
    echoed.len() == stored.len()
        && echoed
            .iter()
            .zip(stored)
            .all(|(kernel, ours)| same_without_transient(kernel, ours))
}

fn same_without_transient(kernel: &Value, ours: &Value) -> bool {
    match (kernel.as_object(), ours.as_object()) {
        (Some(k), Some(o)) => {
            let count =
                |m: &Map<String, Value>| m.keys().filter(|key| key.as_str() != "transient").count();
            count(k) == count(o)
                && k.iter()
                    .filter(|(key, _)| key.as_str() != "transient")
                    .all(|(key, value)| o.get(key) == Some(value))
        }
        _ => kernel == ours,
    }
}

fn outputs_for_kernel(state: &Map<String, Value>) -> Value {
    match state.get("outputs") {
        Some(Value::Array(outs)) => Value::Array(
            outs.iter()
                .map(|out| {
                    let mut out = out.clone();
                    if let Some(obj) = out.as_object_mut() {
                        obj.shift_remove("transient");
                    }
                    out
                })
                .collect(),
        ),
        _ => json!([]),
    }
}

fn encoded_buffers(m: &Model) -> Vec<Value> {
    m.buffers
        .iter()
        .map(|(path, data)| {
            json!({
                "encoding": "base64",
                "path": path,
                "data": base64::engine::general_purpose::STANDARD.encode(data),
            })
        })
        .collect()
}

/// One model of the saved block.
fn saved_entry(m: &Model) -> Value {
    let mut entry = json!({
        "model_name": m.model_name,
        "model_module": m.model_module,
        "model_module_version": m.model_module_version,
        "state": state_without_transient(m),
    });
    if !m.buffers.is_empty() {
        entry["buffers"] = Value::Array(encoded_buffers(m));
    }
    entry
}

/// Model ids named by `IPY_MODEL_` strings anywhere inside `v`.
fn collect_model_refs<'a>(v: &'a Value, out: &mut Vec<&'a str>) {
    match v {
        Value::String(s) => {
            if let Some(id) = s.strip_prefix(MODEL_REF) {
                out.push(id);
            }
        }
        Value::Array(items) => {
            for item in items {
                collect_model_refs(item, out);
            }
        }
        Value::Object(map) => {
            for item in map.values() {
                collect_model_refs(item, out);
            }
        }
        _ => {}
    }
}

/// The model id of a link end: `["IPY_MODEL_<id>", attr]`.
fn link_end(v: Option<&Value>) -> Option<&str> {
    v?.as_array()?.first()?.as_str()?.strip_prefix(MODEL_REF)
}

/// Whether a model is a link model, by its class: a LinkModel (jslink) or a
/// DirectionalLinkModel (jsdlink). Decided by the name, so a link whose ends have not
/// arrived yet is still one.
fn is_link_model(model: &Model) -> bool {
    matches!(
        model.model_name.as_str(),
        "LinkModel" | "DirectionalLinkModel"
    )
}

/// The link a model is, when it is a link model with two ends.
fn link_of(model: &Model) -> Option<Link> {
    let two_way = match model.model_name.as_str() {
        "LinkModel" => true,
        "DirectionalLinkModel" => false,
        _ => return None,
    };
    Some(Link {
        source: link_end_of(model.state.get("source"))?,
        target: link_end_of(model.state.get("target"))?,
        two_way,
    })
}

/// A link end: `["IPY_MODEL_<id>", attribute]`.
fn link_end_of(v: Option<&Value>) -> Option<LinkEnd> {
    let items = v?.as_array()?;
    let model = items.first()?.as_str()?.strip_prefix(MODEL_REF)?;
    let attr = items.get(1)?.as_str()?;
    Some(LinkEnd {
        model: model.to_string(),
        attr: attr.to_string(),
    })
}

/// A model's attribute as the store holds it: its JSON value (None for a binary
/// one, which has no state key) and the buffers under it.
fn attr_of(model: &Model, attr: &str) -> (Option<Value>, Vec<(BufPath, Bytes)>) {
    let value = model.state.get(attr).cloned();
    let pairs = model
        .buffers
        .iter()
        .filter(|(path, _)| head(path) == Some(attr))
        .cloned()
        .collect();
    (value, pairs)
}

/// Whether two lists of buffers hold the same paths with the same bytes.
fn same_pairs(a: &[(BufPath, Bytes)], b: &[(BufPath, Bytes)]) -> bool {
    a.len() == b.len() && a.iter().all(|pair| b.contains(pair))
}

/// The model id of a display or result whose VIEW_MIME data names a model.
fn view_model_id(out: &Value) -> Option<&str> {
    match out.get("output_type").and_then(Value::as_str) {
        Some("display_data") | Some("execute_result") => {}
        _ => return None,
    }
    out.get("data")?.get(VIEW_MIME)?.get("model_id")?.as_str()
}

/// Model ids of the widget views in a cell's outputs, in order.
pub fn view_ids(outputs: &[Value]) -> Vec<String> {
    outputs
        .iter()
        .filter_map(|out| view_model_id(out))
        .map(str::to_string)
        .collect()
}

/// Model ids of the widget views in every code cell, in cell order.
pub fn view_ids_in_cells(cells: &[Cell]) -> Vec<String> {
    cells
        .iter()
        .filter(|cell| matches!(cell.cell_type, CellType::Code))
        .flat_map(|cell| view_ids(&cell.outputs))
        .collect()
}

/// Sets the state entry of the metadata's `metadata.widgets` from the exported
/// state; the other keys of that object stay as they are. With no reachable
/// state the state entry is removed, unless the saved block could not be parsed
/// (`foreign`): then the block is kept verbatim.
pub fn apply_widget_metadata(md: &mut Value, exported: Option<Value>, foreign: bool) {
    match exported {
        Some(state) => {
            if !md.is_object() {
                *md = json!({});
            }
            if !md["widgets"].is_object() {
                md["widgets"] = json!({});
            }
            md["widgets"][STATE_MIME] = state;
        }
        None => {
            if !foreign {
                remove_state_entry(md);
            }
        }
    }
}

/// Removes the state entry from `metadata.widgets`, and the widgets object with
/// it once no other key is left in it. Other keys are never touched.
pub fn remove_state_entry(md: &mut Value) {
    let Some(obj) = md.as_object_mut() else {
        return;
    };
    let Some(widgets) = obj.get_mut("widgets").and_then(Value::as_object_mut) else {
        return;
    };
    widgets.shift_remove(STATE_MIME);
    if widgets.is_empty() {
        obj.shift_remove("widgets");
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Instant;

    fn md() -> Value {
        json!({ "version": "2.1.0" })
    }

    fn b(bytes: &[u8]) -> Bytes {
        Bytes::copy_from_slice(bytes)
    }

    fn b64(bytes: &[u8]) -> String {
        base64::engine::general_purpose::STANDARD.encode(bytes)
    }

    fn obj(v: Value) -> Map<String, Value> {
        v.as_object().cloned().expect("an object")
    }

    fn slider(value: i64) -> Value {
        json!({
            "_model_name": "IntSliderModel",
            "_model_module": "@jupyter-widgets/controls",
            "_model_module_version": "2.0.0",
            "value": value,
            "min": 0,
            "max": 100,
            "description": "n",
        })
    }

    /// comm_open as the kernel sends it: state, buffer_paths and buffers.
    fn open(
        s: &mut Store,
        id: &str,
        state: Value,
        paths: Value,
        buffers: Vec<Bytes>,
    ) -> Vec<Effect> {
        let data = json!({ "state": state, "buffer_paths": paths });
        s.comm_open(id, TARGET, &data, &md(), &buffers)
    }

    /// A kernel update (comm_msg method "update") without buffers.
    fn kernel_update(s: &mut Store, id: &str, state: Value) -> Vec<Effect> {
        s.comm_msg(
            id,
            &json!({ "method": "update", "state": state, "buffer_paths": [] }),
            &[],
            None,
        )
    }

    /// A kernel echo_update whose parent is our comm_msg `parent`.
    fn echo(s: &mut Store, id: &str, state: Value, parent: &str) -> Vec<Effect> {
        s.comm_msg(
            id,
            &json!({ "method": "echo_update", "state": state, "buffer_paths": [] }),
            &[],
            Some(parent),
        )
    }

    fn notes(fx: &[Effect]) -> Vec<&Value> {
        fx.iter()
            .filter_map(|e| match e {
                Effect::Notify { event, .. } => Some(event),
                _ => None,
            })
            .collect()
    }

    fn first_notify(fx: &[Effect]) -> &Value {
        notes(fx).into_iter().next().expect("a Notify effect")
    }

    fn sends(fx: &[Effect]) -> Vec<&Outgoing> {
        fx.iter()
            .filter_map(|e| match e {
                Effect::Send(o) => Some(o),
                _ => None,
            })
            .collect()
    }

    fn flush_count(fx: &[Effect]) -> usize {
        fx.iter()
            .filter(|e| matches!(e, Effect::FlushOutputsAfter { .. }))
            .count()
    }

    fn flush_delays(fx: &[Effect]) -> Vec<Duration> {
        fx.iter()
            .filter_map(|e| match e {
                Effect::FlushOutputsAfter { delay, .. } => Some(*delay),
                _ => None,
            })
            .collect()
    }

    fn stream(name: &str, text: &str) -> KernelEvent {
        KernelEvent::Stream {
            msg_id: "e1".into(),
            parent_msg_id: Some("X".into()),
            name: name.into(),
            text: text.into(),
        }
    }

    fn outputs(s: &Store, id: &str) -> Value {
        s.get(id).expect("model").state["outputs"].clone()
    }

    #[test]
    fn open_update_close() {
        let mut s = Store::default();
        let fx = open(&mut s, "m1", slider(3), json!([]), vec![]);
        let ev = first_notify(&fx);
        assert_eq!(ev["kind"], "open");
        assert_eq!(ev["model_name"], "IntSliderModel");
        assert_eq!(ev["state"]["value"], 3);
        assert_eq!(ev["live"], true);
        assert!(s.get("m1").expect("the model is stored").live);

        let fx = kernel_update(&mut s, "m1", json!({ "value": 7 }));
        let ev = first_notify(&fx);
        assert_eq!(ev["kind"], "update");
        assert_eq!(ev["state"], json!({ "value": 7 }));
        assert_eq!(s.get("m1").expect("model").state["value"], 7);

        let fx = s.comm_close("m1");
        assert_eq!(first_notify(&fx)["kind"], "close");
        assert!(s.get("m1").is_none());
        assert_eq!(s.len(), 0, "a closed model is freed at once");
    }

    #[test]
    fn unknown_target_is_closed_back() {
        let mut s = Store::default();
        let fx = s.comm_open("x1", "nope", &json!({ "state": {} }), &md(), &[]);
        let out = sends(&fx);
        assert_eq!(out.len(), 1, "exactly one message back");
        assert_eq!(out[0].msg_type, "comm_close");
        assert_eq!(out[0].comm_id, "x1");
        assert!(s.get("x1").is_none());
        assert_eq!(s.len(), 0);
    }

    #[test]
    fn buffers_follow_paths() {
        let mut s = Store::default();
        let png = b(b"\x89PNG1");
        open(
            &mut s,
            "img",
            json!({ "_model_name": "ImageModel", "format": "png" }),
            json!([["value"]]),
            vec![png.clone()],
        );
        {
            let m = s.get("img").expect("model");
            assert!(
                !m.state.contains_key("value"),
                "a binary value has no state key"
            );
            assert_eq!(m.buffers, vec![(vec![json!("value")], png)]);
        }

        // A new buffer at the same path replaces the old one.
        let fx = s.comm_msg(
            "img",
            &json!({ "method": "update", "state": {}, "buffer_paths": [["value"]] }),
            &[b(b"PNG2")],
            None,
        );
        assert_eq!(first_notify(&fx)["buffer_paths"], json!([["value"]]));
        {
            let m = s.get("img").expect("model");
            assert_eq!(m.buffers, vec![(vec![json!("value")], b(b"PNG2"))]);
            assert!(!m.state.contains_key("value"));
        }

        // A plain value drops the buffer and sets the key.
        kernel_update(&mut s, "img", json!({ "value": "x" }));
        {
            let m = s.get("img").expect("model");
            assert!(m.buffers.is_empty(), "the buffer at value is gone");
            assert_eq!(m.state["value"], "x");
        }

        // A buffer under a list survives an update of another key.
        open(
            &mut s,
            "arr",
            json!({ "_model_name": "ArrayModel", "data": [null, null], "n": 1 }),
            json!([["data", 0]]),
            vec![b(b"D0")],
        );
        kernel_update(&mut s, "arr", json!({ "n": 2 }));
        let m = s.get("arr").expect("model");
        assert_eq!(m.state["n"], 2);
        assert_eq!(m.buffers, vec![(vec![json!("data"), json!(0)], b(b"D0"))]);
        assert!(m.state.contains_key("data"));
    }

    #[test]
    fn echo_of_our_update_is_dropped() {
        let mut s = Store::default();
        open(&mut s, "m", slider(3), json!([]), vec![]);
        let (fx, sent) = s
            .frontend_update("m", obj(json!({ "value": 42 })), vec![], vec![], None)
            .expect("live");
        let msg = sent.expect("the first update is sent");
        let out = sends(&fx);
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].msg_id, msg);
        assert_eq!(
            out[0].data,
            json!({ "method": "update", "state": { "value": 42 }, "buffer_paths": [] })
        );
        assert_eq!(
            s.get("m").expect("model").state["value"],
            42,
            "the change is applied at once"
        );

        let fx = s.comm_msg(
            "m",
            &json!({ "method": "echo_update", "state": { "value": 42 }, "buffer_paths": [] }),
            &[],
            Some(&msg),
        );
        assert!(fx.is_empty(), "the echo of our value is not notified");

        // The expectation is cleared: an echo of the same attribute from another
        // frontend (a different parent) is applied.
        let fx = echo(&mut s, "m", json!({ "value": 11 }), "other-frontend");
        assert_eq!(first_notify(&fx)["state"], json!({ "value": 11 }));

        let fx = kernel_update(&mut s, "m", json!({ "value": 10 }));
        assert_eq!(first_notify(&fx)["kind"], "update");
        assert_eq!(s.get("m").expect("model").state["value"], 10);
    }

    #[test]
    fn echo_drops_buffers_of_our_keys() {
        let mut s = Store::default();
        open(
            &mut s,
            "img",
            json!({ "_model_name": "ImageModel" }),
            json!([]),
            vec![],
        );
        let (_, sent) = s
            .frontend_update(
                "img",
                Map::new(),
                vec![vec![json!("value")]],
                vec![b(b"MINE")],
                None,
            )
            .expect("live");
        let msg = sent.expect("sent");
        // A kernel echoes the bytes it received: the matching echo changes nothing.
        let fx = s.comm_msg(
            "img",
            &json!({ "method": "echo_update", "state": {}, "buffer_paths": [["value"]] }),
            &[b(b"MINE")],
            Some(&msg),
        );
        assert!(
            fx.is_empty(),
            "the matching echo of our bytes is not notified"
        );
        assert_eq!(
            s.get("img").expect("model").buffers,
            vec![(vec![json!("value")], b(b"MINE"))]
        );

        // A newer update of ours; an echo of the older one, with other bytes, is dropped.
        s.on_idle(&msg);
        let (_, sent) = s
            .frontend_update(
                "img",
                Map::new(),
                vec![vec![json!("value")]],
                vec![b(b"MINE2")],
                None,
            )
            .expect("live");
        let newer = sent.expect("sent");
        let fx = s.comm_msg(
            "img",
            &json!({ "method": "echo_update", "state": {}, "buffer_paths": [["value"]] }),
            &[b(b"ECHO")],
            Some(&msg),
        );
        assert!(fx.is_empty(), "an older echo is dropped");
        assert_eq!(
            s.get("img").expect("model").buffers,
            vec![(vec![json!("value")], b(b"MINE2"))],
            "the older echo does not roll the bytes back"
        );
        let fx = s.comm_msg(
            "img",
            &json!({ "method": "echo_update", "state": {}, "buffer_paths": [["value"]] }),
            &[b(b"MINE2")],
            Some(&newer),
        );
        assert!(
            fx.is_empty(),
            "the matching echo of the newer bytes is not notified"
        );
    }

    #[test]
    fn matching_echo_with_other_bytes_is_applied() {
        // The kernel changed the bytes before it echoed them: the echo is what it holds.
        let mut s = Store::default();
        open(
            &mut s,
            "img",
            json!({ "_model_name": "ImageModel" }),
            json!([]),
            vec![],
        );
        let (_, sent) = s
            .frontend_update(
                "img",
                Map::new(),
                vec![vec![json!("value")]],
                vec![b(b"MINE")],
                None,
            )
            .expect("live");
        let msg = sent.expect("sent");
        let fx = s.comm_msg(
            "img",
            &json!({ "method": "echo_update", "state": {}, "buffer_paths": [["value"]] }),
            &[b(b"KERNEL")],
            Some(&msg),
        );
        assert_eq!(
            first_notify(&fx)["buffer_paths"],
            json!([["value"]]),
            "a matching echo whose bytes differ is applied"
        );
        assert_eq!(
            s.get("img").expect("model").buffers,
            vec![(vec![json!("value")], b(b"KERNEL"))]
        );
    }

    #[test]
    fn matching_echo_after_a_kernel_change_converges() {
        // The sequence an observer that snaps odd values to even produces in
        // ipywidgets 8.1.8: the frontend sends 5 (M1) and then 6, held behind M1. The
        // kernel echoes 5 (M1), sends update 4 (M1), and later echoes 6 (M2) for the
        // held 6. A matching echo of 5 is dropped while 6 is held, and the store
        // ends on what the kernel holds.
        let mut s = Store::default();
        open(&mut s, "m", slider(3), json!([]), vec![]);
        let (_, m1) = s
            .frontend_update("m", obj(json!({ "value": 5 })), vec![], vec![], None)
            .expect("live");
        let m1 = m1.expect("5 is sent");
        let (fx, queued) = s
            .frontend_update("m", obj(json!({ "value": 6 })), vec![], vec![], None)
            .expect("live");
        assert!(fx.is_empty() && queued.is_none(), "6 waits behind 5");

        let fx = echo(&mut s, "m", json!({ "value": 5 }), &m1);
        assert!(fx.is_empty(), "the echo of 5 is dropped while 6 is held");
        let fx = kernel_update(&mut s, "m", json!({ "value": 4 }));
        assert_eq!(first_notify(&fx)["state"], json!({ "value": 4 }));
        assert_eq!(s.get("m").expect("model").state["value"], 4);

        let fx = s.on_idle(&m1);
        let out = sends(&fx);
        assert_eq!(out.len(), 1, "the held 6 goes out once 5 is idle");
        assert_eq!(out[0].data["state"], json!({ "value": 6 }));
        let m2 = out[0].msg_id.clone();

        // The kernel holds 6 and echoes it. The store must end on 6, not on the
        // snapped 4, or the mirror and the next saved notebook show 4.
        let fx = echo(&mut s, "m", json!({ "value": 6 }), &m2);
        assert_eq!(
            s.get("m").expect("model").state["value"],
            6,
            "the matching echo of 6 converges the store on the kernel's value"
        );
        assert_eq!(first_notify(&fx)["state"], json!({ "value": 6 }));
    }

    #[test]
    fn removing_a_key_keeps_the_others_in_order() {
        // serde_json's preserve_order makes Map::remove a swap_remove: the last key
        // would move into the removed key's slot. Saved files keep the order.
        let mut s = Store::default();
        open(
            &mut s,
            "img",
            json!({ "_model_name": "ImageModel", "value": "old", "format": "png", "width": "10px", "height": "20px" }),
            json!([]),
            vec![],
        );
        let fx = s.comm_msg(
            "img",
            &json!({ "method": "update", "state": {}, "buffer_paths": [["value"]] }),
            &[b(b"PNG")],
            None,
        );
        assert_eq!(first_notify(&fx)["kind"], "update");
        let keys: Vec<&str> = s
            .get("img")
            .expect("model")
            .state
            .keys()
            .map(String::as_str)
            .collect();
        assert_eq!(keys, ["_model_name", "format", "width", "height"]);
    }

    #[test]
    fn strip_keeps_the_order_of_the_rest() {
        let mut state = obj(json!({ "a": { "w": 1, "x": 2, "y": 3, "z": 4 } }));
        strip_path(&mut state, &[json!("a"), json!("x")]);
        let keys: Vec<&str> = state["a"]
            .as_object()
            .expect("the dict")
            .keys()
            .map(String::as_str)
            .collect();
        assert_eq!(keys, ["w", "y", "z"]);
    }

    #[test]
    fn apply_widget_metadata_keeps_the_order() {
        let mut md = json!({
            "widgets": { STATE_MIME: { "version_major": 2, "version_minor": 0, "state": {} } },
            "kernelspec": { "name": "python3" },
            "language_info": { "name": "python" },
        });
        apply_widget_metadata(&mut md, None, false);
        let keys: Vec<&str> = md
            .as_object()
            .expect("metadata")
            .keys()
            .map(String::as_str)
            .collect();
        assert_eq!(keys, ["kernelspec", "language_info"]);
    }

    #[test]
    fn capture_end_keeps_the_flush_timer() {
        // The capture end sends at once, and that flush is then in flight. While
        // it is, a capture arms no timer and a timer sends nothing. The idle of
        // that flush paces the captures made meanwhile: the timer is armed for the
        // rest of the cadence and sends them. A capture with nothing in flight arms
        // a timer again.
        let mut s = Store::default();
        open(
            &mut s,
            "o",
            json!({ "_model_name": "OutputModel", "msg_id": "", "outputs": [] }),
            json!([]),
            vec![],
        );
        kernel_update(&mut s, "o", json!({ "msg_id": "X" }));
        let fx = s
            .route_output("X", &stream("stdout", "a"))
            .expect("captured");
        assert_eq!(flush_count(&fx), 1, "the first output arms the timer");

        let fx = kernel_update(&mut s, "o", json!({ "msg_id": "" }));
        let first = sends(&fx);
        assert_eq!(first.len(), 1, "the capture end sends the outputs at once");
        let flush1 = first[0].msg_id.clone();

        kernel_update(&mut s, "o", json!({ "msg_id": "Y" }));
        let fx = s
            .route_output("Y", &stream("stdout", "b"))
            .expect("captured");
        assert_eq!(
            flush_count(&fx),
            0,
            "a flush is in flight, so the capture arms no timer"
        );
        let fx = s.flush_outputs("o");
        assert!(
            sends(&fx).is_empty(),
            "the timer sends nothing while the capture-end flush is in flight"
        );

        let fx = s.on_idle(&flush1);
        assert!(
            sends(&fx).is_empty() && flush_count(&fx) == 1,
            "the idle of flush 1 arms the timer for the capture made meanwhile"
        );
        advance_clock(OUTPUT_FLUSH);
        let fx = s.flush_outputs("o");
        let second = sends(&fx);
        assert_eq!(
            second.len(),
            1,
            "the timer sends the capture made meanwhile"
        );
        assert_eq!(
            second[0].data["state"]["outputs"],
            json!([{ "output_type": "stream", "name": "stdout", "text": "ab" }])
        );
        let flush2 = second[0].msg_id.clone();

        let fx = s
            .route_output("Y", &stream("stdout", "c"))
            .expect("captured");
        assert_eq!(flush_count(&fx), 0, "flush 2 is in flight: no timer");
        let fx = s.on_idle(&flush2);
        assert!(
            sends(&fx).is_empty() && flush_count(&fx) == 1,
            "the idle of flush 2 arms the timer for 'c'"
        );
        advance_clock(OUTPUT_FLUSH);
        let fx = s.flush_outputs("o");
        let third = sends(&fx);
        assert_eq!(third.len(), 1, "the timer sends 'c'");
        let flush3 = third[0].msg_id.clone();

        let fx = s.on_idle(&flush3);
        assert!(sends(&fx).is_empty(), "nothing was captured after flush 3");
        let fx = s
            .route_output("Y", &stream("stdout", "d"))
            .expect("captured");
        assert_eq!(
            flush_count(&fx),
            1,
            "with nothing in flight, the next output arms a timer"
        );
    }

    #[test]
    fn a_busy_kernel_gets_one_outputs_flush_at_a_time() {
        // A cell that prints inside `with out:` keeps the kernel busy, so the
        // outputs flush it is sent waits behind the cell. Only one flush is in
        // flight per Output widget: the captures made meanwhile wait, and the
        // idle of the flush in flight sends them all at once.
        let mut s = Store::default();
        open(
            &mut s,
            "o",
            json!({ "_model_name": "OutputModel", "msg_id": "X", "outputs": [] }),
            json!([]),
            vec![],
        );
        s.route_output("X", &stream("stdout", "a\n"))
            .expect("captured");
        let fx = s.flush_outputs("o");
        let first = sends(&fx);
        assert_eq!(first.len(), 1, "timer flush 1 sends the first output");
        let m1 = first[0].msg_id.clone();

        for text in ["b\n", "c\n", "d\n"] {
            let fx = s
                .route_output("X", &stream("stdout", text))
                .expect("captured");
            assert_eq!(
                flush_count(&fx),
                0,
                "no timer is armed while flush 1 is in flight"
            );
        }
        let fx = s.flush_outputs("o");
        assert!(
            sends(&fx).is_empty(),
            "a second timer sends nothing while flush 1 is in flight"
        );
        let fx = kernel_update(&mut s, "o", json!({ "msg_id": "" }));
        assert!(
            sends(&fx).is_empty(),
            "the capture end sends nothing while flush 1 is in flight"
        );

        advance_clock(OUTPUT_FLUSH);
        let fx = s.on_idle(&m1);
        let next = sends(&fx);
        assert_eq!(next.len(), 1, "the idle of flush 1 sends exactly one flush");
        assert_eq!(
            next[0].data["state"]["outputs"],
            json!([{ "output_type": "stream", "name": "stdout", "text": "a\nb\nc\nd\n" }]),
            "the flush holds every captured output"
        );
        let m2 = next[0].msg_id.clone();
        assert!(
            s.on_idle(&m2).is_empty(),
            "nothing was captured after flush 2: no third flush"
        );
        assert_eq!(
            s.inflight_len(),
            0,
            "each flush leaves the in-flight map at its idle"
        );
    }

    #[test]
    fn protocol_2_0_kernel_without_echo_follows_the_same_rules() {
        // A protocol 2.0 kernel (ipywidgets 7) sends no echo_update. A kernel
        // update applies while our update is in flight, and a held frontend
        // change goes out once the in-flight update is idle, as with 2.1.
        let mut s = Store::default();
        let data = json!({ "state": slider(3), "buffer_paths": [] });
        s.comm_open("m", TARGET, &data, &json!({ "version": "2.0.0" }), &[]);

        let (fx, m1) = s
            .frontend_update("m", obj(json!({ "value": 7 })), vec![], vec![], None)
            .expect("live");
        assert_eq!(sends(&fx).len(), 1, "7 is sent at once");
        let m1 = m1.expect("7 has a msg_id");
        let (fx, queued) = s
            .frontend_update("m", obj(json!({ "value": 8 })), vec![], vec![], None)
            .expect("live");
        assert!(fx.is_empty() && queued.is_none(), "8 waits behind 7");

        let fx = kernel_update(&mut s, "m", json!({ "value": 9 }));
        assert_eq!(notes(&fx).len(), 1, "the kernel's own update is notified");
        assert_eq!(
            s.get("m").expect("model").state["value"],
            json!(9),
            "the kernel's own update applies while 7 is in flight"
        );

        let fx = s.on_idle(&m1);
        let next = sends(&fx);
        assert_eq!(next.len(), 1, "the held 8 goes out once 7 is idle");
        assert_eq!(next[0].data["state"], json!({ "value": 8 }));
        let m2 = next[0].msg_id.clone();
        assert!(
            s.on_idle(&m2).is_empty(),
            "nothing is held after 8: no further update is sent"
        );
    }

    #[test]
    fn output_flush_echo_keeps_transient() {
        // The kernel echoes the outputs we flush without transient. That echo only
        // confirms them: the store keeps display_id, so update_display still finds it.
        let mut s = Store::default();
        open(
            &mut s,
            "o",
            json!({ "_model_name": "OutputModel", "msg_id": "X", "outputs": [] }),
            json!([]),
            vec![],
        );
        s.route_output(
            "X",
            &KernelEvent::DisplayData {
                msg_id: "d".into(),
                parent_msg_id: Some("X".into()),
                data: json!({ "text/plain": "v1" }),
                metadata: json!({}),
                transient: json!({ "display_id": "d1" }),
            },
        )
        .expect("captured");
        let fx = kernel_update(&mut s, "o", json!({ "msg_id": "" }));
        let flushed = sends(&fx);
        assert_eq!(flushed.len(), 1, "the capture end sends the outputs");
        let sent = flushed[0].data["state"]["outputs"].clone();
        assert!(
            sent[0].get("transient").is_none(),
            "the kernel copy has no transient"
        );

        let fx = echo(&mut s, "o", json!({ "outputs": sent }), &flushed[0].msg_id);
        assert!(
            fx.is_empty(),
            "the echo of our flush is a confirmation, not a change"
        );
        assert_eq!(
            outputs(&s, "o")[0]["transient"]["display_id"],
            "d1",
            "the store keeps transient after the echo"
        );

        let fx = s.update_display("d1", &json!({ "text/plain": "v2" }), &json!({}));
        assert_eq!(first_notify(&fx)["event"]["kind"], "update_display_data");
        assert_eq!(outputs(&s, "o")[0]["data"]["text/plain"], "v2");
    }

    #[test]
    fn outputs_echo_after_a_kernel_outputs_update_converges() {
        // The sequence in ipywidgets 8.1.8: a cell ends `with out:` after
        // print("a") and then calls out.append_stdout("b"). The capture-end flush
        // (outputs [a]) waits on shell behind the cell, so the kernel first sends
        // update outputs [b], then handles the flush: it holds [a] and echoes [a].
        // The store must end where the kernel is, or the mirror and the next saved
        // notebook show b.
        let mut s = Store::default();
        open(
            &mut s,
            "o",
            json!({ "_model_name": "OutputModel", "msg_id": "", "outputs": [] }),
            json!([]),
            vec![],
        );
        kernel_update(&mut s, "o", json!({ "msg_id": "X" }));
        s.route_output("X", &stream("stdout", "a\n"))
            .expect("captured");
        let fx = kernel_update(&mut s, "o", json!({ "msg_id": "" }));
        let flushed = sends(&fx);
        assert_eq!(flushed.len(), 1, "the capture end sends [a]");
        let sent = flushed[0].data["state"]["outputs"].clone();
        let flush = flushed[0].msg_id.clone();

        kernel_update(
            &mut s,
            "o",
            json!({ "outputs": [{ "output_type": "stream", "name": "stdout", "text": "b\n" }] }),
        );
        assert_eq!(
            outputs(&s, "o")[0]["text"],
            "b\n",
            "the kernel's own append is applied"
        );

        let fx = echo(&mut s, "o", json!({ "outputs": sent.clone() }), &flush);
        assert_eq!(
            outputs(&s, "o"),
            sent,
            "the store follows the kernel, which holds [a]"
        );
        assert_eq!(first_notify(&fx)["state"], json!({ "outputs": sent }));
    }

    #[test]
    fn flush_echo_keeps_newer_captures() {
        // Our outputs flush carries [a]; "b" is captured before its echo arrives.
        // The echo of [a] must not roll the store back over the newer capture.
        let mut s = Store::default();
        open(
            &mut s,
            "o",
            json!({ "_model_name": "OutputModel", "msg_id": "X", "outputs": [] }),
            json!([]),
            vec![],
        );
        s.route_output("X", &stream("stdout", "a"))
            .expect("captured");
        let fx = s.flush_outputs("o");
        let flushed = sends(&fx);
        assert_eq!(flushed.len(), 1, "the timer sends [a]");
        let sent = flushed[0].data["state"]["outputs"].clone();
        let flush = flushed[0].msg_id.clone();
        s.route_output("X", &stream("stdout", "b"))
            .expect("captured");

        let fx = echo(&mut s, "o", json!({ "outputs": sent }), &flush);
        assert!(
            fx.is_empty(),
            "the echo of [a] is not applied over the newer capture"
        );
        assert_eq!(
            outputs(&s, "o"),
            json!([{ "output_type": "stream", "name": "stdout", "text": "ab" }]),
            "the newer capture is kept"
        );
    }

    #[test]
    fn held_frontend_outputs_drop_the_matching_echo() {
        // A frontend outputs change [x] is in flight (M1) when a newer one, [y],
        // is held. The kernel echoes [x] for M1. That echo is older than the held
        // [y], so it neither rolls the store back to [x] nor gets applied. Once M1
        // is idle, [y] goes out as M2 and its echo is a confirmation.
        let st = |text: &str| json!({ "output_type": "stream", "name": "stdout", "text": text });
        let mut s = Store::default();
        open(
            &mut s,
            "o",
            json!({ "_model_name": "OutputModel", "msg_id": "", "outputs": [] }),
            json!([]),
            vec![],
        );
        let (_, m1) = s
            .frontend_update(
                "o",
                obj(json!({ "outputs": [st("x")] })),
                vec![],
                vec![],
                None,
            )
            .expect("live");
        let m1 = m1.expect("[x] is sent");
        let (fx, queued) = s
            .frontend_update(
                "o",
                obj(json!({ "outputs": [st("y")] })),
                vec![],
                vec![],
                None,
            )
            .expect("live");
        assert!(fx.is_empty() && queued.is_none(), "[y] waits behind [x]");

        let fx = echo(&mut s, "o", json!({ "outputs": [st("x")] }), &m1);
        assert!(
            fx.is_empty(),
            "the echo of [x] is dropped while [y] is held"
        );
        assert_eq!(outputs(&s, "o"), json!([st("y")]), "the store keeps [y]");

        let fx = s.on_idle(&m1);
        let sent = sends(&fx);
        assert_eq!(sent.len(), 1, "[y] goes out once [x] is idle");
        assert_eq!(sent[0].data["state"]["outputs"], json!([st("y")]));
        let m2 = sent[0].msg_id.clone();
        let fx = echo(&mut s, "o", json!({ "outputs": [st("y")] }), &m2);
        assert!(fx.is_empty(), "the echo of [y] is a confirmation");
        assert_eq!(outputs(&s, "o"), json!([st("y")]), "the store keeps [y]");
    }

    #[test]
    fn held_buffer_drops_the_matching_echo() {
        // Only the buffers of a key are held (pending_buffers). The matching echo
        // of the bytes we sent before must not roll the store back to them.
        let mut s = Store::default();
        open(
            &mut s,
            "img",
            json!({ "_model_name": "ImageModel" }),
            json!([]),
            vec![],
        );
        let (_, first) = s
            .frontend_update(
                "img",
                Map::new(),
                vec![vec![json!("value")]],
                vec![b(b"B1")],
                None,
            )
            .expect("live");
        let first = first.expect("B1 is sent");
        let (fx, queued) = s
            .frontend_update(
                "img",
                Map::new(),
                vec![vec![json!("value")]],
                vec![b(b"B2")],
                None,
            )
            .expect("live");
        assert!(fx.is_empty() && queued.is_none(), "B2 waits behind B1");

        let fx = s.comm_msg(
            "img",
            &json!({ "method": "echo_update", "state": {}, "buffer_paths": [["value"]] }),
            &[b(b"B1")],
            Some(&first),
        );
        assert!(fx.is_empty(), "the echo of B1 is dropped while B2 is held");
        assert_eq!(
            s.get("img").expect("model").buffers,
            vec![(vec![json!("value")], b(b"B2"))],
            "the store keeps the held bytes"
        );

        let fx = s.on_idle(&first);
        let sent = sends(&fx);
        assert_eq!(sent.len(), 1, "B2 goes out once B1 is idle");
        let second = sent[0].msg_id.clone();
        let fx = s.comm_msg(
            "img",
            &json!({ "method": "echo_update", "state": {}, "buffer_paths": [["value"]] }),
            &[b(b"B2")],
            Some(&second),
        );
        assert!(fx.is_empty(), "the echo of B2 is a confirmation");
        assert_eq!(
            s.get("img").expect("model").buffers,
            vec![(vec![json!("value")], b(b"B2"))]
        );
    }

    #[test]
    fn older_key_buffers_stay_out_of_an_applied_echo() {
        // One echo carries an older key (its update is superseded, so the key is
        // dropped with its buffer) and a key we never sent (applied). The notify
        // must not carry the dropped key's bytes, and the store keeps the newer bytes.
        let mut s = Store::default();
        open(
            &mut s,
            "img",
            json!({ "_model_name": "ImageModel", "width": "1" }),
            json!([]),
            vec![],
        );
        let (_, old) = s
            .frontend_update(
                "img",
                Map::new(),
                vec![vec![json!("value")]],
                vec![b(b"OLD")],
                None,
            )
            .expect("live");
        let old = old.expect("OLD is sent");
        s.on_idle(&old);
        let (_, newer) = s
            .frontend_update(
                "img",
                Map::new(),
                vec![vec![json!("value")]],
                vec![b(b"NEW")],
                None,
            )
            .expect("live");
        assert!(newer.is_some(), "NEW is sent");

        let fx = s.comm_msg(
            "img",
            &json!({ "method": "echo_update", "state": { "width": "2" }, "buffer_paths": [["value"]] }),
            &[b(b"OLD")],
            Some(&old),
        );
        assert_eq!(notes(&fx).len(), 1, "the applied key is notified");
        let ev = first_notify(&fx);
        assert_eq!(ev["state"], json!({ "width": "2" }));
        assert_eq!(
            ev["buffer_paths"],
            json!([]),
            "the dropped key's path is not notified"
        );
        let notified: Vec<Bytes> = fx
            .iter()
            .flat_map(|e| match e {
                Effect::Notify { buffers, .. } => buffers.clone(),
                _ => Vec::new(),
            })
            .collect();
        assert!(
            notified.is_empty(),
            "the dropped key's bytes are not notified"
        );
        let m = s.get("img").expect("model");
        assert_eq!(m.state["width"], "2");
        assert_eq!(
            m.buffers,
            vec![(vec![json!("value")], b(b"NEW"))],
            "the store keeps the newer bytes"
        );
    }

    #[test]
    fn held_and_unheld_keys_in_one_echo() {
        // One echo, two keys: `value` is held in pending (its newer optimistic value
        // waits), `description` is not. The held key is dropped and keeps the
        // optimistic value; the unheld key is applied. Only description is notified.
        let mut s = Store::default();
        open(&mut s, "m", slider(0), json!([]), vec![]);
        let (_, first) = s
            .frontend_update(
                "m",
                obj(json!({ "value": 5, "description": "a" })),
                vec![],
                vec![],
                None,
            )
            .expect("live");
        let first = first.expect("5 is sent");
        let (fx, queued) = s
            .frontend_update("m", obj(json!({ "value": 6 })), vec![], vec![], None)
            .expect("live");
        assert!(fx.is_empty() && queued.is_none(), "6 waits behind 5");

        let fx = echo(
            &mut s,
            "m",
            json!({ "value": 5, "description": "z" }),
            &first,
        );
        assert_eq!(notes(&fx).len(), 1);
        assert_eq!(
            first_notify(&fx)["state"],
            json!({ "description": "z" }),
            "only the unheld key is applied"
        );
        let m = s.get("m").expect("model");
        assert_eq!(m.state["value"], 6, "the held optimistic value stays");
        assert_eq!(
            m.state["description"], "z",
            "the kernel holds the description it echoed"
        );
    }

    #[test]
    fn value_and_buffer_at_one_key_keep_the_order() {
        // A plain value and a buffer for the same key in one update: the value is
        // written in place, then the buffer removes it from the middle of the state.
        // The other keys keep their order (a swap_remove would move the last one).
        let mut s = Store::default();
        open(
            &mut s,
            "img",
            json!({ "_model_name": "ImageModel", "value": "v", "format": "png", "width": "1", "height": "2" }),
            json!([]),
            vec![],
        );
        let fx = s.comm_msg(
            "img",
            &json!({ "method": "update", "state": { "value": "x" }, "buffer_paths": [["value"]] }),
            &[b(b"Q")],
            None,
        );
        assert_eq!(first_notify(&fx)["kind"], "update");
        let m = s.get("img").expect("model");
        let keys: Vec<&str> = m.state.keys().map(String::as_str).collect();
        assert_eq!(keys, ["_model_name", "format", "width", "height"]);
        assert!(
            !m.state.contains_key("value"),
            "the binary value has no key"
        );
        assert_eq!(m.buffers, vec![(vec![json!("value")], b(b"Q"))]);
    }

    #[test]
    fn older_echo_never_rolls_back() {
        let mut s = Store::default();
        open(&mut s, "m", slider(0), json!([]), vec![]);
        let (_, m1) = s
            .frontend_update("m", obj(json!({ "value": 3 })), vec![], vec![], None)
            .expect("live");
        let m1 = m1.expect("3 is sent");
        let (fx, queued) = s
            .frontend_update("m", obj(json!({ "value": 4 })), vec![], vec![], None)
            .expect("live");
        assert!(fx.is_empty() && queued.is_none(), "4 waits behind 3");

        let fx = echo(&mut s, "m", json!({ "value": 3 }), &m1);
        assert!(fx.is_empty(), "the echo of 3 is dropped");
        assert_eq!(s.get("m").expect("model").state["value"], 4);

        let fx = s.on_idle(&m1);
        let out = sends(&fx);
        assert_eq!(out.len(), 1, "4 goes out once 3 is idle");
        assert_eq!(out[0].data["state"], json!({ "value": 4 }));
        let m2 = out[0].msg_id.clone();

        let fx = echo(&mut s, "m", json!({ "value": 4 }), &m2);
        assert!(fx.is_empty());
        assert_eq!(s.get("m").expect("model").state["value"], 4);

        let fx = echo(
            &mut s,
            "m",
            json!({ "description": "other" }),
            "someone-else",
        );
        assert_eq!(
            first_notify(&fx)["state"],
            json!({ "description": "other" }),
            "an attribute we never sent is applied"
        );
        assert_eq!(s.get("m").expect("model").state["description"], "other");
    }

    #[test]
    fn one_update_in_flight() {
        let mut s = Store::default();
        open(&mut s, "m", slider(0), json!([]), vec![]);
        let mut first = None;
        for v in 1..=5 {
            let (fx, id) = s
                .frontend_update("m", obj(json!({ "value": v })), vec![], vec![], None)
                .expect("live");
            if v == 1 {
                assert!(
                    fx.iter().any(|e| matches!(e, Effect::Send(_))),
                    "the first update is sent"
                );
                assert!(
                    fx.iter()
                        .any(|e| matches!(e, Effect::CheckInflightAfter { .. })),
                    "and its timeout is armed"
                );
                first = id;
            } else {
                assert!(fx.is_empty(), "update {v} waits");
                assert!(id.is_none());
            }
        }
        let m1 = first.expect("the first update has a msg_id");

        let fx = s.on_idle(&m1);
        let out = sends(&fx);
        assert_eq!(out.len(), 1, "the held updates merge into one");
        assert_eq!(out[0].data["state"], json!({ "value": 5 }));
        let m2 = out[0].msg_id.clone();
        assert!(
            s.on_idle(&m2).is_empty(),
            "nothing is pending after the merged one"
        );

        // A timeout of the current in-flight update sends the held one too.
        let mut t = Store::default();
        open(&mut t, "m", slider(0), json!([]), vec![]);
        let (_, a) = t
            .frontend_update("m", obj(json!({ "value": 1 })), vec![], vec![], None)
            .expect("live");
        let (fx, _) = t
            .frontend_update("m", obj(json!({ "value": 2 })), vec![], vec![], None)
            .expect("live");
        assert!(fx.is_empty());
        let a = a.expect("sent");
        let fx = t.inflight_timeout("m", &a);
        assert_eq!(sends(&fx).len(), 1);
        assert_eq!(sends(&fx)[0].data["state"], json!({ "value": 2 }));
        assert!(
            t.inflight_timeout("m", &a).is_empty(),
            "a stale timeout does nothing"
        );
    }

    #[test]
    fn held_update_keeps_the_newest_cell() {
        // The updates held behind M1 carry their cells. A later held update with
        // no cell does not erase the newest cell given, so the release sends with
        // cell B.
        let mut s = Store::default();
        open(&mut s, "m", slider(0), json!([]), vec![]);
        let (_, m1) = s
            .frontend_update(
                "m",
                obj(json!({ "value": 1 })),
                vec![],
                vec![],
                Some("A".into()),
            )
            .expect("live");
        let m1 = m1.expect("value 1 is sent");
        let (fx, queued) = s
            .frontend_update(
                "m",
                obj(json!({ "value": 2 })),
                vec![],
                vec![],
                Some("B".into()),
            )
            .expect("live");
        assert!(
            fx.is_empty() && queued.is_none(),
            "value 2 waits behind value 1"
        );
        let (fx, queued) = s
            .frontend_update("m", obj(json!({ "value": 3 })), vec![], vec![], None)
            .expect("live");
        assert!(fx.is_empty() && queued.is_none(), "value 3 waits too");

        let fx = s.on_idle(&m1);
        let sent = sends(&fx);
        assert_eq!(sent.len(), 1, "the held updates go out as one");
        assert_eq!(sent[0].data["state"], json!({ "value": 3 }));
        assert_eq!(
            sent[0].cell_id.as_deref(),
            Some("B"),
            "the release keeps the newest cell given"
        );
    }

    #[test]
    fn dead_and_unknown_models_refuse() {
        let mut s = Store::default();
        open(&mut s, "m", slider(3), json!([]), vec![]);
        let fx = s.reset(&["m".to_string()]);
        assert_eq!(first_notify(&fx)["kind"], "reset");
        let m = s.get("m").expect("the model survives a reset");
        assert!(!m.live, "a reset marks every model dead");
        assert_eq!(m.state["value"], 3, "a dead model keeps its last state");

        let err = s
            .frontend_update("m", obj(json!({ "value": 1 })), vec![], vec![], None)
            .unwrap_err();
        assert!(err.to_string().contains("not connected"), "{err}");
        let err = s
            .frontend_custom("m", json!({ "event": "click" }), vec![], None)
            .unwrap_err();
        assert!(err.to_string().contains("not connected"), "{err}");
        let err = s
            .frontend_update("nope", obj(json!({ "value": 1 })), vec![], vec![], None)
            .unwrap_err();
        assert!(err.to_string().contains("unknown widget model"), "{err}");
        assert!(s.frontend_custom("nope", json!({}), vec![], None).is_err());
    }

    #[test]
    fn output_capture() {
        let mut s = Store::default();
        open(
            &mut s,
            "o",
            json!({ "_model_name": "OutputModel", "_model_module": "@jupyter-widgets/output", "msg_id": "", "outputs": [] }),
            json!([]),
            vec![],
        );
        assert!(
            s.route_output("X", &stream("stdout", "a")).is_none(),
            "no capture before msg_id is set"
        );

        kernel_update(&mut s, "o", json!({ "msg_id": "X" }));
        let fx = s
            .route_output("X", &stream("stdout", "a"))
            .expect("captured");
        let ev = first_notify(&fx);
        assert_eq!(ev["kind"], "output");
        assert_eq!(
            ev["event"],
            json!({ "kind": "stream", "name": "stdout", "text": "a" })
        );
        assert_eq!(
            flush_count(&fx),
            1,
            "the first captured output arms the flush"
        );

        let fx = s
            .route_output("X", &stream("stdout", "b"))
            .expect("captured");
        assert_eq!(
            flush_count(&fx),
            0,
            "a second output does not arm another flush"
        );
        assert_eq!(
            outputs(&s, "o"),
            json!([{ "output_type": "stream", "name": "stdout", "text": "ab" }])
        );

        s.route_output(
            "X",
            &KernelEvent::ClearOutput {
                parent_msg_id: Some("X".into()),
                wait: true,
            },
        )
        .expect("captured");
        let fx = s
            .route_output("X", &stream("stdout", "c"))
            .expect("captured");
        assert_eq!(
            first_notify(&fx)["event"]["clear_first"],
            true,
            "the deferred clear is in the delta"
        );
        assert_eq!(
            outputs(&s, "o"),
            json!([{ "output_type": "stream", "name": "stdout", "text": "c" }])
        );

        s.route_output(
            "X",
            &KernelEvent::DisplayData {
                msg_id: "d".into(),
                parent_msg_id: Some("X".into()),
                data: json!({ "text/plain": "v1" }),
                metadata: json!({}),
                transient: json!({ "display_id": "d1" }),
            },
        )
        .expect("captured");
        assert_eq!(
            outputs(&s, "o")[1]["transient"]["display_id"],
            "d1",
            "the store keeps transient"
        );

        let fx = s.update_display("d1", &json!({ "text/plain": "v2" }), &json!({}));
        let ev = first_notify(&fx);
        assert_eq!(ev["kind"], "output");
        assert_eq!(ev["event"]["kind"], "update_display_data");
        assert_eq!(outputs(&s, "o")[1]["data"]["text/plain"], "v2");

        // Ending the capture sends the outputs at once, without transient.
        let fx = kernel_update(&mut s, "o", json!({ "msg_id": "" }));
        let out = sends(&fx);
        assert_eq!(out.len(), 1, "the capture end sends the outputs");
        assert!(out[0].data["state"]["outputs"][1]
            .get("transient")
            .is_none());
        assert_eq!(
            out[0].data["state"]["outputs"][1]["data"]["text/plain"],
            "v2"
        );
        assert!(
            s.route_output("X", &stream("stdout", "z")).is_none(),
            "the capture is over"
        );
    }

    #[test]
    fn latest_output_widget_wins() {
        let mut s = Store::default();
        for id in ["o1", "o2"] {
            open(
                &mut s,
                id,
                json!({ "_model_name": "OutputModel", "msg_id": "X", "outputs": [] }),
                json!([]),
                vec![],
            );
        }
        let fx = s
            .route_output("X", &stream("stdout", "hi"))
            .expect("captured");
        assert_eq!(first_notify(&fx)["model_id"], "o2");
        assert_eq!(
            outputs(&s, "o1"),
            json!([]),
            "the earlier widget gets nothing"
        );
        assert_eq!(
            outputs(&s, "o2"),
            json!([{ "output_type": "stream", "name": "stdout", "text": "hi" }])
        );
    }

    #[test]
    fn reopen_drops_the_old_captures() {
        // A comm_open with the id of an existing Output model replaces it. The old
        // model's capture of X goes with it, so X's output is no longer routed.
        let mut s = Store::default();
        open(
            &mut s,
            "o",
            json!({ "_model_name": "OutputModel", "msg_id": "X", "outputs": [] }),
            json!([]),
            vec![],
        );
        open(
            &mut s,
            "o",
            json!({ "_model_name": "OutputModel", "msg_id": "", "outputs": [] }),
            json!([]),
            vec![],
        );
        assert!(
            s.route_output("X", &stream("stdout", "a")).is_none(),
            "the reopened widget no longer captures X"
        );
        assert_eq!(
            outputs(&s, "o"),
            json!([]),
            "no output reached the new model"
        );
    }

    #[test]
    fn closing_the_newer_output_widget_hands_capture_back() {
        // Two Output widgets capture X, the second one newer. Closing the second
        // hands X back to the first, which takes the next output.
        let mut s = Store::default();
        open(
            &mut s,
            "o1",
            json!({ "_model_name": "OutputModel", "msg_id": "X", "outputs": [] }),
            json!([]),
            vec![],
        );
        open(
            &mut s,
            "o2",
            json!({ "_model_name": "OutputModel", "msg_id": "X", "outputs": [] }),
            json!([]),
            vec![],
        );
        let fx = s.comm_close("o2");
        assert_eq!(first_notify(&fx)["kind"], "close");
        let fx = match s.route_output("X", &stream("stdout", "a")) {
            Some(fx) => fx,
            None => panic!("X is still captured by o1 after o2 closed"),
        };
        assert_eq!(notes(&fx)[0]["model_id"], "o1", "the output goes to o1");
        assert_eq!(
            outputs(&s, "o1"),
            json!([{ "output_type": "stream", "name": "stdout", "text": "a" }])
        );
    }

    #[test]
    fn export_reachable_only() {
        let mut s = Store::default();
        open(
            &mut s,
            "hbox",
            json!({ "_model_name": "HBoxModel", "_model_module": "@jupyter-widgets/controls", "_model_module_version": "2.0.0",
                    "children": ["IPY_MODEL_a", "IPY_MODEL_b"], "layout": "IPY_MODEL_l" }),
            json!([]),
            vec![],
        );
        open(
            &mut s,
            "a",
            json!({ "_model_name": "ImageModel", "format": "png" }),
            json!([["value"]]),
            vec![b(b"PNG")],
        );
        open(
            &mut s,
            "b",
            json!({ "_model_name": "HTMLModel", "value": "<b>x</b>" }),
            json!([]),
            vec![],
        );
        open(
            &mut s,
            "l",
            json!({ "_model_name": "LayoutModel", "width": "100px" }),
            json!([]),
            vec![],
        );
        open(
            &mut s,
            "u",
            json!({ "_model_name": "HTMLModel", "value": "unrelated" }),
            json!([]),
            vec![],
        );
        open(
            &mut s,
            "lk1",
            json!({ "_model_name": "LinkModel", "source": ["IPY_MODEL_a", "value"], "target": ["IPY_MODEL_b", "value"] }),
            json!([]),
            vec![],
        );
        open(
            &mut s,
            "lk2",
            json!({ "_model_name": "LinkModel", "source": ["IPY_MODEL_a", "value"], "target": ["IPY_MODEL_u", "value"] }),
            json!([]),
            vec![],
        );

        let v = s
            .export_saved(&["hbox".to_string()])
            .expect("something is reachable");
        assert_eq!(v["version_major"], 2);
        assert_eq!(v["version_minor"], 0);
        let keys: Vec<&str> = v["state"]
            .as_object()
            .expect("state")
            .keys()
            .map(String::as_str)
            .collect();
        assert_eq!(
            keys,
            ["hbox", "a", "b", "l", "lk1"],
            "reachable models in reach order, then the link whose ends are reached"
        );
        assert_eq!(
            v["state"]["a"]["buffers"][0],
            json!({ "encoding": "base64", "path": ["value"], "data": b64(b"PNG") })
        );
        assert_eq!(v["state"]["a"]["model_name"], "ImageModel");
        assert!(
            v["state"]["a"]["state"].get("value").is_none(),
            "a binary value stays out of the state"
        );

        // An Output widget pulls in the models its outputs show, and loses transient.
        open(
            &mut s,
            "o",
            json!({
                "_model_name": "OutputModel",
                "msg_id": "",
                "outputs": [{
                    "output_type": "display_data",
                    "data": { VIEW_MIME: { "version_major": 2, "version_minor": 0, "model_id": "u" } },
                    "metadata": {},
                    "transient": { "display_id": "x" }
                }]
            }),
            json!([]),
            vec![],
        );
        let v = s.export_saved(&["o".to_string()]).expect("reachable");
        assert!(
            v["state"].get("u").is_some(),
            "the view's model is pulled in"
        );
        assert!(v["state"]["o"]["state"]["outputs"][0]
            .get("transient")
            .is_none());

        assert!(s.export_saved(&[]).is_none(), "no roots gives nothing");
        assert!(s.export_saved(&["nope".to_string()]).is_none());
    }

    #[test]
    fn export_orders_links_by_their_ends() {
        // Six links among three reached models, opened in the reverse of their
        // export order. The export lists the links by (source position, target
        // position, link id). A store's map order is random per instance, so the
        // check runs on several stores.
        let links = [
            ("z1", "a", "b"),
            ("z2", "a", "b"),
            ("y1", "a", "c"),
            ("x1", "b", "a"),
            ("w1", "b", "c"),
            ("v1", "c", "b"),
        ];
        let expected = ["box", "a", "b", "c", "z1", "z2", "y1", "x1", "w1", "v1"];
        for _ in 0..8 {
            let mut s = Store::default();
            open(
                &mut s,
                "box",
                json!({
                    "_model_name": "HBoxModel",
                    "children": ["IPY_MODEL_a", "IPY_MODEL_b", "IPY_MODEL_c"],
                }),
                json!([]),
                vec![],
            );
            for id in ["a", "b", "c"] {
                open(
                    &mut s,
                    id,
                    json!({ "_model_name": "IntSliderModel" }),
                    json!([]),
                    vec![],
                );
            }
            for (id, src, dst) in links.iter().rev() {
                open(
                    &mut s,
                    id,
                    json!({
                        "_model_name": "LinkModel",
                        "source": [format!("IPY_MODEL_{src}"), "value"],
                        "target": [format!("IPY_MODEL_{dst}"), "value"],
                    }),
                    json!([]),
                    vec![],
                );
            }
            let saved = s
                .export_saved(&["box".to_string()])
                .expect("the box is reachable");
            let keys: Vec<&str> = saved["state"]
                .as_object()
                .expect("a state object")
                .keys()
                .map(String::as_str)
                .collect();
            assert_eq!(keys, expected, "links are listed by their ends, then by id");
        }
    }

    #[test]
    fn load_saved_round_trip() {
        let mut s1 = Store::default();
        open(
            &mut s1,
            "a",
            json!({ "_model_name": "ImageModel", "format": "png" }),
            json!([["value"]]),
            vec![b(b"\x89PNG")],
        );
        open(
            &mut s1,
            "hbox",
            json!({ "_model_name": "HBoxModel", "children": ["IPY_MODEL_a"] }),
            json!([]),
            vec![],
        );
        let exported = s1.export_saved(&["hbox".to_string()]).expect("reachable");

        let mut s2 = Store::default();
        let n = s2
            .load_saved(&json!({ STATE_MIME: exported.clone() }))
            .expect("version 2");
        assert_eq!(n, 2);
        for id in ["a", "hbox"] {
            let (x, y) = (s1.get(id).expect("original"), s2.get(id).expect("loaded"));
            assert_eq!(x.state, y.state, "{id} state");
            assert_eq!(x.buffers, y.buffers, "{id} buffers");
            assert_eq!(x.model_name, y.model_name);
            assert!(
                !y.live,
                "loaded models are dead until the kernel opens them"
            );
        }

        let hex_md = json!({ STATE_MIME: {
            "version_major": 2, "version_minor": 0,
            "state": { "h": {
                "model_name": "ImageModel", "model_module": "@jupyter-widgets/controls", "model_module_version": "2.0.0",
                "state": { "format": "png" },
                "buffers": [{ "encoding": "hex", "path": ["value"], "data": "0102ff" }]
            } }
        } });
        let mut s3 = Store::default();
        s3.load_saved(&hex_md).expect("version 2");
        assert_eq!(
            s3.get("h").expect("loaded").buffers,
            vec![(vec![json!("value")], b(&[1, 2, 255]))]
        );

        let bad = json!({ STATE_MIME: { "version_major": 3, "version_minor": 0, "state": {} } });
        assert!(
            Store::default().load_saved(&bad).is_err(),
            "an unknown major version is refused"
        );
    }

    #[test]
    fn apply_widget_metadata_rules() {
        let saved = json!({ "version_major": 2, "version_minor": 0, "state": {} });

        let mut md = json!({ "kernelspec": { "name": "python3" } });
        apply_widget_metadata(&mut md, Some(saved.clone()), false);
        assert_eq!(md["widgets"][STATE_MIME], saved, "Some sets the key");
        assert_eq!(md["kernelspec"]["name"], "python3", "other keys stay");

        let mut md = json!({ "widgets": { STATE_MIME: saved.clone() } });
        apply_widget_metadata(&mut md, None, false);
        assert!(md.get("widgets").is_none(), "None removes the key");

        let foreign = json!({ "widgets": { "application/vnd.jupyter.widget-state+json": { "version_major": 3 } } });
        let mut md = foreign.clone();
        apply_widget_metadata(&mut md, None, true);
        assert_eq!(md, foreign, "None keeps a block we could not parse");
    }

    #[test]
    fn widget_siblings_are_never_touched() {
        // Only the state entry is set or removed; the other keys of the
        // widgets object stay, and the object goes once it is empty.
        let saved = json!({ "version_major": 2, "version_minor": 0, "state": {} });
        let mut md = json!({ "widgets": { "sibling": 1, STATE_MIME: saved.clone() } });
        apply_widget_metadata(&mut md, None, false);
        assert_eq!(
            md["widgets"],
            json!({ "sibling": 1 }),
            "None removed more than the state entry"
        );
        apply_widget_metadata(&mut md, Some(saved.clone()), false);
        assert_eq!(
            md["widgets"],
            json!({ "sibling": 1, STATE_MIME: saved.clone() }),
            "Some changed more than the state entry"
        );
        let mut md = json!({ "widgets": { STATE_MIME: saved } });
        remove_state_entry(&mut md);
        assert!(
            md.get("widgets").is_none(),
            "an empty widgets object stayed"
        );
    }

    #[test]
    fn generation_and_our_messages() {
        let mut s = Store::default();
        assert_eq!(s.gen(), 0);
        open(&mut s, "m", slider(1), json!([]), vec![]);
        open(
            &mut s,
            "o",
            json!({ "_model_name": "OutputModel", "msg_id": "X", "outputs": [] }),
            json!([]),
            vec![],
        );

        let (fx, first) = s
            .frontend_update("m", obj(json!({ "value": 2 })), vec![], vec![], None)
            .expect("live");
        let first = first.expect("the first update is sent");
        assert!(!sends(&fx).is_empty());
        for o in sends(&fx) {
            assert!(s.is_ours(&o.msg_id), "a frontend update is ours");
        }
        let (fx, custom_id) = s
            .frontend_custom("m", json!({ "event": "click" }), vec![], None)
            .expect("live");
        assert_eq!(sends(&fx)[0].msg_id, custom_id);
        assert!(s.is_ours(&custom_id), "a custom message is ours");

        let fx = s.comm_open("zz", "nope", &json!({ "state": {} }), &md(), &[]);
        assert!(
            s.is_ours(&sends(&fx)[0].msg_id),
            "the comm_close back is ours"
        );

        s.route_output("X", &stream("stdout", "a"))
            .expect("captured");
        let fx = s.flush_outputs("o");
        assert_eq!(sends(&fx).len(), 1);
        assert!(
            s.is_ours(&sends(&fx)[0].msg_id),
            "the outputs update is ours"
        );

        assert!(
            s.is_ours(&first),
            "our update stays ours until its status idle"
        );
        s.on_idle(&first);
        assert!(!s.is_ours(&first), "the status idle clears it");
        let (_, id) = s
            .frontend_update("m", obj(json!({ "value": 3 })), vec![], vec![], None)
            .expect("live");
        let id = id.expect("the update after the idle is sent");
        assert!(s.is_ours(&id));

        s.reset(&[]);
        assert_eq!(s.gen(), 1, "gen counts kernels");
        assert!(!s.is_ours(&custom_id), "reset empties the set");
    }

    #[test]
    fn view_ids_read_views_in_order() {
        let view = |id: &str| json!({ "output_type": "display_data", "data": { VIEW_MIME: { "model_id": id } }, "metadata": {} });
        let outs = vec![
            view("first"),
            json!({ "output_type": "stream", "name": "stdout", "text": "x" }),
            json!({ "output_type": "execute_result", "data": { VIEW_MIME: { "model_id": "second" } }, "metadata": {}, "execution_count": 1 }),
        ];
        assert_eq!(
            view_ids(&outs),
            vec!["first".to_string(), "second".to_string()]
        );
    }

    #[test]
    fn models_json_has_the_snapshot_shape() {
        let mut s = Store::default();
        open(&mut s, "m", slider(3), json!([]), vec![]);
        open(
            &mut s,
            "img",
            json!({ "_model_name": "ImageModel" }),
            json!([["value"]]),
            vec![b(b"P")],
        );
        let all = s.models_json();
        assert_eq!(all.len(), 2);
        let img = all.iter().find(|v| v["model_id"] == "img").expect("img");
        assert_eq!(
            img["buffers"],
            json!([{ "encoding": "base64", "path": ["value"], "data": b64(b"P") }])
        );
        assert_eq!(img["live"], true);
        assert_eq!(img["model_name"], "ImageModel");
    }

    #[cfg_attr(debug_assertions, ignore)]
    #[test]
    fn budget_updates() {
        let mut s = Store::default();
        for i in 0..1000 {
            open(&mut s, &format!("m{i}"), slider(0), json!([]), vec![]);
        }
        let mut work = Vec::with_capacity(10_000);
        for n in 0..10_000u64 {
            work.push((
                format!("m{}", n % 1000),
                json!({ "method": "update", "state": { "value": n, "description": "d", "readout": "r" }, "buffer_paths": [] }),
            ));
        }
        let start = Instant::now();
        let mut notified = 0usize;
        for (id, data) in &work {
            notified += s.comm_msg(id, data, &[], None).len();
        }
        let elapsed = start.elapsed();
        eprintln!(
            "budget_updates: {:?} for 10,000 three-key updates ({:.2} us each)",
            elapsed,
            elapsed.as_secs_f64() * 1e6 / 10_000.0
        );
        assert_eq!(notified, 10_000, "every update is notified");
        assert!(
            elapsed.as_millis() < 150,
            "10,000 updates took {elapsed:?}, budget 150 ms"
        );
    }

    #[cfg_attr(debug_assertions, ignore)]
    #[test]
    fn budget_export_load() {
        // One tqdm.notebook bar is 7 models: the HBox, its two HTML widgets,
        // the FloatProgress, and the layouts and style they use.
        let mut s = Store::default();
        let mut roots = Vec::new();
        for i in 0..1000 {
            let p = |name: &str| format!("{name}{i}");
            let model_ref = |name: String| format!("IPY_MODEL_{name}");
            open(
                &mut s,
                &p("hb"),
                json!({
                    "_model_name": "HBoxModel",
                    "children": [model_ref(p("h1")), model_ref(p("fp")), model_ref(p("h2"))],
                    "layout": model_ref(p("lh")),
                }),
                json!([]),
                vec![],
            );
            open(
                &mut s,
                &p("h1"),
                json!({ "_model_name": "HTMLModel", "value": "  0%" }),
                json!([]),
                vec![],
            );
            open(
                &mut s,
                &p("h2"),
                json!({ "_model_name": "HTMLModel", "value": "0/40" }),
                json!([]),
                vec![],
            );
            open(
                &mut s,
                &p("fp"),
                json!({
                    "_model_name": "FloatProgressModel",
                    "value": 0.0,
                    "max": 40.0,
                    "bar_style": "",
                    "style": model_ref(p("st")),
                    "layout": model_ref(p("lf")),
                }),
                json!([]),
                vec![],
            );
            open(
                &mut s,
                &p("lh"),
                json!({ "_model_name": "LayoutModel" }),
                json!([]),
                vec![],
            );
            open(
                &mut s,
                &p("lf"),
                json!({ "_model_name": "LayoutModel" }),
                json!([]),
                vec![],
            );
            open(
                &mut s,
                &p("st"),
                json!({ "_model_name": "ProgressStyleModel" }),
                json!([]),
                vec![],
            );
            roots.push(p("hb"));
        }
        assert_eq!(s.len(), 7000, "7 models per bar");

        let start = Instant::now();
        let saved = s.export_saved(&roots).expect("reachable");
        let export_t = start.elapsed();
        let count = saved["state"].as_object().expect("state").len();
        assert_eq!(count, 7000, "every reachable model is exported once");

        let wrapper = json!({ STATE_MIME: saved });
        let mut s2 = Store::default();
        let start = Instant::now();
        let n = s2.load_saved(&wrapper).expect("version 2");
        let load_t = start.elapsed();
        assert_eq!(n, 7000);

        eprintln!("budget_export_load: export {export_t:?}, load {load_t:?} ({count} models)");
        assert!(
            export_t.as_millis() < 100,
            "export took {export_t:?}, budget 100 ms"
        );
        assert!(
            load_t.as_millis() < 100,
            "load took {load_t:?}, budget 100 ms"
        );
    }

    #[test]
    fn custom_message_forwards_without_buffers() {
        // The mirror does not read a custom message's buffers, so they stay in the
        // core: the content goes to Lua, the buffers do not.
        let mut s = Store::default();
        open(
            &mut s,
            "b",
            json!({ "_model_name": "ButtonModel" }),
            json!([]),
            vec![],
        );
        let data = json!({ "method": "custom", "content": { "event": "draw" } });
        let fx = s.comm_msg("b", &data, &[b(b"pixels")], None);
        let events = notes(&fx);
        assert_eq!(events.len(), 1, "one custom notification");
        assert_eq!(events[0]["content"], json!({ "event": "draw" }));
        let sent: Vec<usize> = fx
            .iter()
            .filter_map(|e| match e {
                Effect::Notify { buffers, .. } => Some(buffers.len()),
                _ => None,
            })
            .collect();
        assert_eq!(sent, vec![0], "the binary buffers are not sent to Lua");
    }

    #[cfg_attr(debug_assertions, ignore)]
    #[test]
    fn budget_stream_coalescing() {
        // A long capture of small prints appends in place: the cost grows with the
        // output, not with the output times the number of messages.
        let mut s = Store::default();
        open(
            &mut s,
            "o",
            json!({ "_model_name": "OutputModel", "msg_id": "X", "outputs": [] }),
            json!([]),
            vec![],
        );
        let line = format!("{}\n", "x".repeat(63));
        let events: Vec<KernelEvent> = (0..100_000).map(|_| stream("stdout", &line)).collect();
        let start = Instant::now();
        for ev in &events {
            s.route_output("X", ev).expect("captured");
        }
        let elapsed = start.elapsed();
        eprintln!("budget_stream_coalescing: 100,000 stream messages in {elapsed:?}");
        let text_len = outputs(&s, "o")[0]["text"]
            .as_str()
            .map(str::len)
            .unwrap_or(0);
        assert_eq!(text_len, 100_000 * 64, "every chunk is in the one output");
        assert!(
            elapsed.as_millis() < 1000,
            "100,000 stream messages took {elapsed:?}, budget 1 s"
        );
    }

    #[test]
    fn update_display_arms_no_timer_while_a_flush_is_in_flight() {
        // The timer flush of a capture is in flight. A display update of the same
        // widget must arm no second timer: the idle of that flush answers it.
        let mut s = Store::default();
        open(
            &mut s,
            "o",
            json!({ "_model_name": "OutputModel", "msg_id": "X", "outputs": [] }),
            json!([]),
            vec![],
        );
        s.route_output(
            "X",
            &KernelEvent::DisplayData {
                msg_id: "d".into(),
                parent_msg_id: Some("X".into()),
                data: json!({ "text/plain": "v1" }),
                metadata: json!({}),
                transient: json!({ "display_id": "d1" }),
            },
        )
        .expect("captured");
        let fx = s.flush_outputs("o");
        assert_eq!(sends(&fx).len(), 1, "the timer sends the first flush");
        let fx = s.update_display("d1", &json!({ "text/plain": "v2" }), &json!({}));
        assert_eq!(first_notify(&fx)["event"]["kind"], "update_display_data");
        assert_eq!(
            flush_count(&fx),
            0,
            "a flush is in flight: update_display arms no timer"
        );
        assert_eq!(outputs(&s, "o")[0]["data"]["text/plain"], "v2");
    }

    #[test]
    fn the_outputs_flush_is_never_released_by_the_update_timeout() {
        // Only the idle of an outputs flush ends it. The 2 s update timeout must not
        // send what was captured meanwhile, or a busy kernel would be sent a full
        // copy of the outputs every 2 s.
        let mut s = Store::default();
        open(
            &mut s,
            "o",
            json!({ "_model_name": "OutputModel", "msg_id": "X", "outputs": [] }),
            json!([]),
            vec![],
        );
        s.route_output("X", &stream("stdout", "a\n"))
            .expect("captured");
        let fx = s.flush_outputs("o");
        let flushed = sends(&fx);
        assert_eq!(flushed.len(), 1, "the timer sends the first flush");
        let m1 = flushed[0].msg_id.clone();
        assert!(
            !fx.iter()
                .any(|e| matches!(e, Effect::CheckInflightAfter { .. })),
            "a flush arms no update timeout"
        );
        s.route_output("X", &stream("stdout", "b\n"))
            .expect("captured");
        let fx = s.inflight_timeout("o", &m1);
        assert!(
            sends(&fx).is_empty(),
            "the update timeout sends nothing while the flush is in flight"
        );
        let fx = s.flush_outputs("o");
        assert!(
            sends(&fx).is_empty(),
            "the timer sends nothing while the flush is still in flight"
        );
    }

    #[test]
    fn an_echo_of_our_flush_after_a_kernel_clear_is_followed() {
        // The kernel clears its outputs after our flush, so the store holds []. The
        // flush's echo then carries [a]: the kernel holds [a], so the store follows
        // it. An echo that differs in length from the store is a change, not a
        // confirmation.
        let mut s = Store::default();
        open(
            &mut s,
            "o",
            json!({ "_model_name": "OutputModel", "msg_id": "X", "outputs": [] }),
            json!([]),
            vec![],
        );
        s.route_output("X", &stream("stdout", "a\n"))
            .expect("captured");
        let fx = kernel_update(&mut s, "o", json!({ "msg_id": "" }));
        let flushed = sends(&fx);
        assert_eq!(flushed.len(), 1, "the capture end sends the outputs");
        let m1 = flushed[0].msg_id.clone();
        kernel_update(&mut s, "o", json!({ "outputs": [] }));
        assert_eq!(
            outputs(&s, "o"),
            json!([]),
            "the kernel cleared its outputs"
        );

        let kept = json!([{ "output_type": "stream", "name": "stdout", "text": "a\n" }]);
        let fx = echo(&mut s, "o", json!({ "outputs": kept.clone() }), &m1);
        assert_eq!(
            first_notify(&fx)["state"]["outputs"],
            kept,
            "the echo is notified"
        );
        assert_eq!(outputs(&s, "o"), kept, "the store follows the kernel's [a]");
    }

    #[test]
    fn a_free_kernel_keeps_the_flush_cadence() {
        // A free kernel answers a flush at once. A capture made during that round
        // trip must wait for the 500 ms cadence, not go out at the idle: otherwise
        // a task printing inside `with out:` gets one full copy per round trip.
        let mut s = Store::default();
        open(
            &mut s,
            "o",
            json!({ "_model_name": "OutputModel", "msg_id": "X", "outputs": [] }),
            json!([]),
            vec![],
        );
        s.route_output("X", &stream("stdout", "a\n"))
            .expect("captured");
        let fx = s.flush_outputs("o");
        let first = sends(&fx);
        assert_eq!(first.len(), 1, "the timer sends the first flush");
        let m1 = first[0].msg_id.clone();
        s.route_output("X", &stream("stdout", "b\n"))
            .expect("captured");
        let fx = s.on_idle(&m1);
        assert!(
            sends(&fx).is_empty(),
            "a free kernel's idle right after the flush sends nothing at once"
        );
        let delays: Vec<Duration> = fx
            .iter()
            .filter_map(|e| match e {
                Effect::FlushOutputsAfter { delay, .. } => Some(*delay),
                _ => None,
            })
            .collect();
        assert_eq!(
            delays.len(),
            1,
            "the idle arms the timer for the rest of the 500 ms"
        );
        assert_eq!(
            delays[0], OUTPUT_FLUSH,
            "the idle right after the flush leaves the whole cadence"
        );
        advance_clock(OUTPUT_FLUSH);
        let fx = s.flush_outputs("o");
        let next = sends(&fx);
        assert_eq!(next.len(), 1, "the timer sends what was captured meanwhile");
        assert_eq!(
            next[0].data["state"]["outputs"],
            json!([{ "output_type": "stream", "name": "stdout", "text": "a\nb\n" }])
        );
    }

    #[test]
    fn capture_end_flush_leaves_the_pending_timer_alone() {
        // A timer armed during a capture is still pending when the capture ends.
        // The capture end sends at once and leaves the flag set, so a capture
        // that starts after that flush is answered arms no second timer: the
        // pending one covers it, and two flushes never land under 500 ms apart.
        let mut s = Store::default();
        open(
            &mut s,
            "o",
            json!({ "_model_name": "OutputModel", "msg_id": "X", "outputs": [] }),
            json!([]),
            vec![],
        );
        let fx = s
            .route_output("X", &stream("stdout", "a"))
            .expect("captured");
        assert_eq!(flush_count(&fx), 1, "the first output arms the timer");
        let fx = kernel_update(&mut s, "o", json!({ "msg_id": "" }));
        let first = sends(&fx);
        assert_eq!(first.len(), 1, "the capture end sends at once");
        let m1 = first[0].msg_id.clone();
        assert!(s.on_idle(&m1).is_empty(), "nothing was captured meanwhile");
        kernel_update(&mut s, "o", json!({ "msg_id": "Y" }));
        let fx = s
            .route_output("Y", &stream("stdout", "b"))
            .expect("captured");
        assert_eq!(
            flush_count(&fx),
            0,
            "the timer still pending covers the new capture: no second timer"
        );
        advance_clock(OUTPUT_FLUSH);
        let fx = s.flush_outputs("o");
        assert_eq!(
            sends(&fx).len(),
            1,
            "the pending timer sends the new output"
        );
    }

    #[test]
    fn a_busy_kernel_sends_the_captures_at_the_idle_after_the_cadence() {
        // A busy kernel answers a flush only after the cadence has passed. Its idle
        // then sends what was captured meanwhile at once: one flush per round trip.
        let mut s = Store::default();
        open(
            &mut s,
            "o",
            json!({ "_model_name": "OutputModel", "msg_id": "X", "outputs": [] }),
            json!([]),
            vec![],
        );
        s.route_output("X", &stream("stdout", "a\n"))
            .expect("captured");
        let fx = s.flush_outputs("o");
        let first = sends(&fx);
        assert_eq!(first.len(), 1, "the timer sends the first flush");
        let m1 = first[0].msg_id.clone();
        s.route_output("X", &stream("stdout", "b\n"))
            .expect("captured");
        advance_clock(OUTPUT_FLUSH);
        let fx = s.on_idle(&m1);
        let next = sends(&fx);
        assert_eq!(
            next.len(),
            1,
            "the idle after the cadence sends the captures at once"
        );
        assert_eq!(
            next[0].data["state"]["outputs"],
            json!([{ "output_type": "stream", "name": "stdout", "text": "a\nb\n" }])
        );
    }

    #[test]
    fn an_idle_with_a_timer_pending_arms_no_second_timer() {
        // The timer armed by the first output is still pending when the capture end
        // sends a flush. A capture made during that flight is covered by the pending
        // timer, so the flush's idle must not arm a second one.
        let mut s = Store::default();
        open(
            &mut s,
            "o",
            json!({ "_model_name": "OutputModel", "msg_id": "X", "outputs": [] }),
            json!([]),
            vec![],
        );
        let fx = s
            .route_output("X", &stream("stdout", "a"))
            .expect("captured");
        assert_eq!(flush_count(&fx), 1, "the first output arms the timer");
        let fx = kernel_update(&mut s, "o", json!({ "msg_id": "" }));
        let first = sends(&fx);
        assert_eq!(first.len(), 1, "the capture end sends at once");
        let m1 = first[0].msg_id.clone();
        kernel_update(&mut s, "o", json!({ "msg_id": "Y" }));
        let fx = s
            .route_output("Y", &stream("stdout", "b"))
            .expect("captured");
        assert_eq!(
            flush_count(&fx),
            0,
            "the timer still pending covers the capture: no timer"
        );
        let fx = s.on_idle(&m1);
        assert!(
            sends(&fx).is_empty() && flush_count(&fx) == 0,
            "the idle leaves the capture to the pending timer"
        );
        advance_clock(OUTPUT_FLUSH);
        let fx = s.flush_outputs("o");
        assert_eq!(sends(&fx).len(), 1, "the pending timer sends the capture");
    }

    #[test]
    fn a_capture_end_soon_after_a_flush_waits_for_the_cadence() {
        // Per-iteration `with out:` blocks on a free kernel end a capture every few
        // milliseconds. A capture end sends at once only when the last flush went out
        // a cadence ago; otherwise the timer that is pending sends the captures.
        let mut s = Store::default();
        open(
            &mut s,
            "o",
            json!({ "_model_name": "OutputModel", "msg_id": "X", "outputs": [] }),
            json!([]),
            vec![],
        );
        s.route_output("X", &stream("stdout", "a\n"))
            .expect("captured");
        let fx = s.flush_outputs("o");
        let first = sends(&fx);
        assert_eq!(first.len(), 1, "the timer sends the first flush");
        let m1 = first[0].msg_id.clone();
        assert!(
            s.on_idle(&m1).is_empty(),
            "nothing was captured after the flush"
        );

        kernel_update(&mut s, "o", json!({ "msg_id": "Y" }));
        let fx = s
            .route_output("Y", &stream("stdout", "b\n"))
            .expect("captured");
        assert_eq!(flush_count(&fx), 1, "the next capture arms the timer");
        let fx = kernel_update(&mut s, "o", json!({ "msg_id": "" }));
        assert!(
            sends(&fx).is_empty(),
            "the capture end waits for the cadence timer"
        );
        advance_clock(OUTPUT_FLUSH);
        let fx = s.flush_outputs("o");
        let next = sends(&fx);
        assert_eq!(next.len(), 1, "the timer sends the captures");
        assert_eq!(
            next[0].data["state"]["outputs"],
            json!([{ "output_type": "stream", "name": "stdout", "text": "a\nb\n" }])
        );
    }

    #[test]
    fn flush_before_request_sends_the_captures_the_cadence_held_back() {
        // The second cell's capture ends inside the cadence, so the store holds it for
        // the timer. Before the kernel is asked to run the next code, the held captures
        // go out at once, because that code reads them. A flush in flight is answered
        // first (one flush in flight per widget), so nothing is sent past it.
        let mut s = Store::default();
        open(
            &mut s,
            "o",
            json!({ "_model_name": "OutputModel", "msg_id": "X", "outputs": [] }),
            json!([]),
            vec![],
        );
        s.route_output("X", &stream("stdout", "a\n"))
            .expect("captured");
        let fx = kernel_update(&mut s, "o", json!({ "msg_id": "" }));
        let first = sends(&fx);
        assert_eq!(first.len(), 1, "the first capture end sends at once");
        let m1 = first[0].msg_id.clone();

        kernel_update(&mut s, "o", json!({ "msg_id": "Y" }));
        s.route_output("Y", &stream("stdout", "b\n"))
            .expect("captured");
        let fx = kernel_update(&mut s, "o", json!({ "msg_id": "" }));
        assert!(
            sends(&fx).is_empty(),
            "the second capture end waits for the cadence"
        );
        assert!(
            s.flush_before_request().is_empty(),
            "a flush is in flight: nothing is sent past it"
        );
        assert!(
            s.on_idle(&m1).is_empty(),
            "the idle leaves the held capture to the cadence"
        );
        let fx = s.flush_before_request();
        let sent = sends(&fx);
        assert_eq!(
            sent.len(),
            1,
            "the held captures go out before the next request"
        );
        assert_eq!(
            sent[0].data["state"]["outputs"],
            json!([{ "output_type": "stream", "name": "stdout", "text": "a\nb\n" }])
        );
        assert!(
            s.flush_before_request().is_empty(),
            "nothing is waiting any more"
        );
    }

    #[test]
    fn a_timer_armed_before_a_capture_end_flush_waits_for_the_cadence() {
        // The first output arms a timer. Its capture ends 100 ms later and sends at
        // once (no flush in the last 500 ms). When the timer fires 400 ms after that
        // flush it sends nothing and arms one timer for the rest of the cadence, so
        // two flushes never land under 500 ms apart.
        let mut s = Store::default();
        open(
            &mut s,
            "o",
            json!({ "_model_name": "OutputModel", "msg_id": "X", "outputs": [] }),
            json!([]),
            vec![],
        );
        let fx = s
            .route_output("X", &stream("stdout", "a\n"))
            .expect("captured");
        assert_eq!(flush_count(&fx), 1, "the first output arms the timer");
        advance_clock(Duration::from_millis(100));
        let fx = kernel_update(&mut s, "o", json!({ "msg_id": "" }));
        let first = sends(&fx);
        assert_eq!(first.len(), 1, "the capture end sends at once");
        let m1 = first[0].msg_id.clone();
        assert!(s.on_idle(&m1).is_empty(), "nothing was captured meanwhile");
        kernel_update(&mut s, "o", json!({ "msg_id": "Y" }));
        s.route_output("Y", &stream("stdout", "b\n"))
            .expect("captured");

        advance_clock(Duration::from_millis(400));
        let fx = s.flush_outputs("o");
        assert!(
            sends(&fx).is_empty(),
            "the timer fired 400 ms after the flush: it sends nothing"
        );
        assert_eq!(
            flush_delays(&fx),
            [Duration::from_millis(100)],
            "one timer is armed for the rest of the cadence"
        );

        advance_clock(Duration::from_millis(100));
        let fx = s.flush_outputs("o");
        let next = sends(&fx);
        assert_eq!(next.len(), 1, "the cadence has passed: the timer sends");
        assert_eq!(
            next[0].data["state"]["outputs"],
            json!([{ "output_type": "stream", "name": "stdout", "text": "a\nb\n" }])
        );
    }

    #[test]
    fn a_flush_idle_300_ms_later_arms_only_the_rest_of_the_cadence() {
        // The timer sends a flush at the 500 ms mark. A capture made meanwhile waits
        // for its idle, which comes 300 ms after the flush: the idle arms the timer for
        // the 200 ms that remain, not for a whole cadence.
        let mut s = Store::default();
        open(
            &mut s,
            "o",
            json!({ "_model_name": "OutputModel", "msg_id": "X", "outputs": [] }),
            json!([]),
            vec![],
        );
        s.route_output("X", &stream("stdout", "a\n"))
            .expect("captured");
        advance_clock(OUTPUT_FLUSH);
        let fx = s.flush_outputs("o");
        let first = sends(&fx);
        assert_eq!(first.len(), 1, "the timer sends the first flush");
        let m1 = first[0].msg_id.clone();
        s.route_output("X", &stream("stdout", "b\n"))
            .expect("captured");

        advance_clock(Duration::from_millis(300));
        let fx = s.on_idle(&m1);
        assert!(
            sends(&fx).is_empty(),
            "the idle sends nothing before the cadence has passed"
        );
        assert_eq!(
            flush_delays(&fx),
            [Duration::from_millis(200)],
            "the idle arms the timer for the 200 ms that remain"
        );

        advance_clock(Duration::from_millis(200));
        let fx = s.flush_outputs("o");
        assert_eq!(
            sends(&fx).len(),
            1,
            "the timer sends the capture made meanwhile"
        );
    }

    #[test]
    fn a_reset_leaves_no_capture_to_sync() {
        // A kernel restart ends the captures of the dead kernel: nothing is sent for
        // them, by the next request or by a timer that was still pending.
        let mut s = Store::default();
        open(
            &mut s,
            "o",
            json!({ "_model_name": "OutputModel", "msg_id": "X", "outputs": [] }),
            json!([]),
            vec![],
        );
        s.route_output("X", &stream("stdout", "a\n"))
            .expect("captured");
        // The Output widget stays, dead, because a cell shows it: its capture is still
        // dropped (out_waiting), and the widget is not pruned.
        let _ = s.reset(&["o".to_string()]);
        assert!(
            !s.get("o").expect("the shown widget stays").live,
            "the shown widget is dead after the reset"
        );
        assert!(
            s.flush_before_request().is_empty(),
            "the reset dropped the capture"
        );
        advance_clock(OUTPUT_FLUSH);
        assert!(
            s.flush_outputs("o").is_empty(),
            "the pending timer of the dead kernel sends nothing"
        );
    }

    #[test]
    fn a_closed_output_widget_leaves_nothing_to_sync() {
        // A capture waiting for the cadence is dropped with its widget. A model that
        // later takes the same comm id gets no outputs update.
        let mut s = Store::default();
        open(
            &mut s,
            "o",
            json!({ "_model_name": "OutputModel", "msg_id": "X", "outputs": [] }),
            json!([]),
            vec![],
        );
        s.route_output("X", &stream("stdout", "a\n"))
            .expect("captured");
        let _ = s.comm_close("o");
        open(&mut s, "o", slider(1), json!([]), vec![]);
        assert!(
            s.flush_before_request().is_empty(),
            "the closed widget's capture is not sent to the model that took its id"
        );
    }

    #[test]
    fn a_click_sends_the_captures_waiting_first() {
        // A click handler runs in the kernel and may append to an Output widget, so the
        // captures still waiting for the cadence go out first. A flush in flight is not
        // overtaken.
        let mut s = Store::default();
        open(
            &mut s,
            "o",
            json!({ "_model_name": "OutputModel", "msg_id": "X", "outputs": [] }),
            json!([]),
            vec![],
        );
        open(
            &mut s,
            "b",
            json!({ "_model_name": "ButtonModel", "description": "go" }),
            json!([]),
            vec![],
        );
        s.route_output("X", &stream("stdout", "a\n"))
            .expect("captured");
        let (fx, m) = s
            .frontend_custom("b", json!({ "event": "click" }), vec![], None)
            .expect("live");
        let sent = sends(&fx);
        assert_eq!(
            sent.len(),
            2,
            "the waiting capture goes out before the click"
        );
        assert_eq!(sent[0].comm_id, "o");
        assert_eq!(sent[0].data["method"], "update");
        assert_eq!(
            sent[0].data["state"]["outputs"],
            json!([{ "output_type": "stream", "name": "stdout", "text": "a\n" }])
        );
        assert_eq!(sent[1].comm_id, "b");
        assert_eq!(sent[1].data["method"], "custom");
        assert_eq!(sent[1].msg_id, m);
        assert!(
            s.flush_before_request().is_empty(),
            "nothing waits any more"
        );

        // The flush is in flight: a capture made now waits for its idle, and the click
        // sends nothing but itself.
        s.route_output("X", &stream("stdout", "b\n"))
            .expect("captured");
        let (fx, _) = s
            .frontend_custom("b", json!({ "event": "click" }), vec![], None)
            .expect("live");
        let sent = sends(&fx);
        assert_eq!(sent.len(), 1, "a flush in flight is not overtaken");
        assert_eq!(sent[0].comm_id, "b");
    }

    #[test]
    fn an_update_sends_the_captures_waiting_first() {
        // An update's observer runs in the kernel. A sent update, and a held update when
        // it is released, is preceded by the captures that wait for the cadence.
        let mut s = Store::default();
        open(
            &mut s,
            "o",
            json!({ "_model_name": "OutputModel", "msg_id": "X", "outputs": [] }),
            json!([]),
            vec![],
        );
        open(&mut s, "s", slider(3), json!([]), vec![]);
        s.route_output("X", &stream("stdout", "a\n"))
            .expect("captured");
        let (fx, m1) = s
            .frontend_update("s", obj(json!({ "value": 5 })), vec![], vec![], None)
            .expect("live");
        let m1 = m1.expect("sent");
        let sent = sends(&fx);
        assert_eq!(
            sent.len(),
            2,
            "the waiting capture goes out before the update"
        );
        assert_eq!(sent[0].comm_id, "o");
        assert_eq!(
            sent[0].data["state"]["outputs"],
            json!([{ "output_type": "stream", "name": "stdout", "text": "a\n" }])
        );
        assert_eq!(sent[1].comm_id, "s");
        assert_eq!(sent[1].data["state"], json!({ "value": 5 }));
        assert_eq!(sent[1].msg_id, m1);
        let f1 = sent[0].msg_id.clone();

        let (fx, held) = s
            .frontend_update("s", obj(json!({ "value": 6 })), vec![], vec![], None)
            .expect("live");
        assert!(
            held.is_none(),
            "the update is held behind the one in flight"
        );
        assert!(fx.is_empty(), "a held update sends nothing");
        s.route_output("X", &stream("stdout", "b\n"))
            .expect("captured");
        assert!(
            sends(&s.on_idle(&f1)).is_empty(),
            "the flush's idle leaves the capture to the cadence"
        );
        let fx = s.on_idle(&m1);
        let sent = sends(&fx);
        assert_eq!(
            sent.len(),
            2,
            "the released update is preceded by the waiting capture"
        );
        assert_eq!(sent[0].comm_id, "o");
        assert_eq!(
            sent[0].data["state"]["outputs"],
            json!([{ "output_type": "stream", "name": "stdout", "text": "a\nb\n" }])
        );
        assert_eq!(sent[1].comm_id, "s");
        assert_eq!(sent[1].data["state"], json!({ "value": 6 }));
    }

    #[test]
    fn a_display_update_alone_is_synced_back() {
        // An update_display_data that changes an Output widget's display is the only
        // change in the widget. It still reaches the kernel: the next flush carries it.
        let mut s = Store::default();
        open(
            &mut s,
            "o",
            json!({ "_model_name": "OutputModel", "msg_id": "X", "outputs": [] }),
            json!([]),
            vec![],
        );
        s.route_output(
            "X",
            &KernelEvent::DisplayData {
                msg_id: "d".into(),
                parent_msg_id: Some("X".into()),
                data: json!({ "text/plain": "v1" }),
                metadata: json!({}),
                transient: json!({ "display_id": "d1" }),
            },
        )
        .expect("captured");
        let fx = s.flush_outputs("o");
        let sent = sends(&fx);
        assert_eq!(sent.len(), 1, "the capture goes out with the timer");
        let f1 = sent[0].msg_id.clone();
        assert!(s.on_idle(&f1).is_empty(), "nothing waits after the flush");

        let fx = s.update_display("d1", &json!({ "text/plain": "v2" }), &json!({}));
        assert_eq!(
            flush_count(&fx),
            1,
            "the display update arms the cadence timer"
        );
        advance_clock(OUTPUT_FLUSH);
        let fx = s.flush_outputs("o");
        let sent = sends(&fx);
        assert_eq!(sent.len(), 1, "the display update is synced back");
        assert_eq!(
            sent[0].data["state"]["outputs"][0]["data"]["text/plain"],
            "v2"
        );
        assert!(sent[0].data["state"]["outputs"][0]
            .get("transient")
            .is_none());
    }

    #[test]
    fn a_timed_out_update_sends_the_captures_waiting_first() {
        // An update held behind one in flight is released when that one times out
        // (`inflight_timeout`). The release is a sent update, so the captures that
        // wait for the cadence go out before it.
        let mut s = Store::default();
        open(
            &mut s,
            "o",
            json!({ "_model_name": "OutputModel", "msg_id": "X", "outputs": [] }),
            json!([]),
            vec![],
        );
        open(&mut s, "s", slider(3), json!([]), vec![]);
        let (fx, m1) = s
            .frontend_update("s", obj(json!({ "value": 5 })), vec![], vec![], None)
            .expect("live");
        let m1 = m1.expect("sent");
        assert_eq!(sends(&fx).len(), 1, "the first update is sent at once");
        let (fx, held) = s
            .frontend_update("s", obj(json!({ "value": 6 })), vec![], vec![], None)
            .expect("live");
        assert!(held.is_none(), "the second update is held");
        assert!(fx.is_empty(), "a held update sends nothing");
        s.route_output("X", &stream("stdout", "a\n"))
            .expect("captured");
        let fx = s.inflight_timeout("s", &m1);
        let sent = sends(&fx);
        assert_eq!(
            sent.len(),
            2,
            "the waiting capture goes out before the released update"
        );
        assert_eq!(sent[0].comm_id, "o");
        assert_eq!(sent[0].data["method"], "update");
        assert_eq!(
            sent[0].data["state"]["outputs"],
            json!([{ "output_type": "stream", "name": "stdout", "text": "a\n" }])
        );
        assert_eq!(sent[1].comm_id, "s");
        assert_eq!(sent[1].data["state"], json!({ "value": 6 }));
    }

    #[test]
    fn a_stale_update_sends_the_captures_waiting_first() {
        // An update in flight for INFLIGHT_TIMEOUT or longer no longer holds the next
        // one back: that one is sent at once, and the captures that wait for the
        // cadence go out before it.
        let mut s = Store::default();
        open(
            &mut s,
            "o",
            json!({ "_model_name": "OutputModel", "msg_id": "X", "outputs": [] }),
            json!([]),
            vec![],
        );
        open(&mut s, "s", slider(3), json!([]), vec![]);
        let (fx, _) = s
            .frontend_update("s", obj(json!({ "value": 5 })), vec![], vec![], None)
            .expect("live");
        assert_eq!(sends(&fx).len(), 1, "the first update is sent at once");
        advance_clock(INFLIGHT_TIMEOUT);
        s.route_output("X", &stream("stdout", "a\n"))
            .expect("captured");
        let (fx, m2) = s
            .frontend_update("s", obj(json!({ "value": 6 })), vec![], vec![], None)
            .expect("live");
        let m2 = m2.expect("sent: the update in flight is stale");
        let sent = sends(&fx);
        assert_eq!(
            sent.len(),
            2,
            "the waiting capture goes out before the stale-path update"
        );
        assert_eq!(sent[0].comm_id, "o");
        assert_eq!(
            sent[0].data["state"]["outputs"],
            json!([{ "output_type": "stream", "name": "stdout", "text": "a\n" }])
        );
        assert_eq!(sent[1].comm_id, "s");
        assert_eq!(sent[1].data["state"], json!({ "value": 6 }));
        assert_eq!(sent[1].msg_id, m2);
    }

    #[test]
    fn a_held_or_empty_update_flushes_nothing() {
        // Only a request that reaches the kernel runs code there. A held update and an
        // update with nothing in it send nothing, so the captures keep waiting for the
        // release or the cadence.
        let mut s = Store::default();
        open(
            &mut s,
            "o",
            json!({ "_model_name": "OutputModel", "msg_id": "X", "outputs": [] }),
            json!([]),
            vec![],
        );
        open(&mut s, "s", slider(3), json!([]), vec![]);
        let (_, m1) = s
            .frontend_update("s", obj(json!({ "value": 5 })), vec![], vec![], None)
            .expect("live");
        let m1 = m1.expect("sent");
        s.route_output("X", &stream("stdout", "a\n"))
            .expect("captured");
        let (fx, held) = s
            .frontend_update("s", obj(json!({ "value": 6 })), vec![], vec![], None)
            .expect("live");
        assert!(
            held.is_none(),
            "the update is held behind the one in flight"
        );
        assert!(fx.is_empty(), "a held update flushes nothing");
        let (fx, none) = s
            .frontend_update("s", Map::new(), vec![], vec![], None)
            .expect("live");
        assert!(none.is_none(), "an empty update is not sent");
        assert!(fx.is_empty(), "an empty update flushes nothing");
        let fx = s.on_idle(&m1);
        let sent = sends(&fx);
        assert_eq!(
            sent.len(),
            2,
            "the release sends the capture, then the update"
        );
        assert_eq!(sent[0].comm_id, "o");
        assert_eq!(sent[1].comm_id, "s");
    }

    #[test]
    fn a_refused_click_leaves_the_captures_waiting() {
        // A click on a model that is gone is refused, and the effects of a refused
        // request are never run. So it must not start a flush: a flush recorded as in
        // flight but never sent would get no idle, and the widget would never sync again.
        let mut s = Store::default();
        open(
            &mut s,
            "o",
            json!({ "_model_name": "OutputModel", "msg_id": "X", "outputs": [] }),
            json!([]),
            vec![],
        );
        s.route_output("X", &stream("stdout", "a\n"))
            .expect("captured");
        assert!(s
            .frontend_custom("gone", json!({ "event": "click" }), vec![], None)
            .is_err());
        let fx = s.flush_before_request();
        assert_eq!(
            sends(&fx).len(),
            1,
            "the capture still waits after the refused click"
        );
    }

    /// A LinkModel (two_way) or DirectionalLinkModel from one (model, attribute)
    /// end to the other, as widgets.jslink and widgets.jsdlink send it.
    fn link(
        s: &mut Store,
        id: &str,
        two_way: bool,
        source: (&str, &str),
        target: (&str, &str),
    ) -> Vec<Effect> {
        let name = if two_way {
            "LinkModel"
        } else {
            "DirectionalLinkModel"
        };
        open(
            s,
            id,
            json!({
                "_model_name": name,
                "_model_module": "@jupyter-widgets/controls",
                "source": [format!("IPY_MODEL_{}", source.0), source.1],
                "target": [format!("IPY_MODEL_{}", target.0), target.1],
            }),
            json!([]),
            vec![],
        )
    }

    /// The states of the update events for `model` in `fx` (what Lua applies).
    fn updates_of(fx: &[Effect], model: &str) -> Vec<Value> {
        notes(fx)
            .into_iter()
            .filter(|ev| ev["kind"] == "update" && ev["model_id"] == model)
            .map(|ev| ev["state"].clone())
            .collect()
    }

    /// The states of the comm updates the core sends to `model` in `fx`.
    fn sent_updates_to(fx: &[Effect], model: &str) -> Vec<Value> {
        sends(fx)
            .into_iter()
            .filter(|o| o.comm_id == model && o.data["method"] == "update")
            .map(|o| o.data["state"].clone())
            .collect()
    }

    /// Runs the kernel's idle for every update sent in `fx`, so nothing is in flight.
    fn settle(s: &mut Store, fx: &[Effect]) {
        for o in sends(fx) {
            if o.data["method"] == "update" {
                let _ = s.on_idle(&o.msg_id);
            }
        }
    }

    /// Two sliders, a = 1 and b = 5, with a link from a.value to b.value that has
    /// finished its first copy (no update in flight).
    fn linked_pair(two_way: bool) -> Store {
        let mut s = Store::default();
        open(&mut s, "a", slider(1), json!([]), vec![]);
        open(&mut s, "b", slider(5), json!([]), vec![]);
        let fx = link(&mut s, "l", two_way, ("a", "value"), ("b", "value"));
        settle(&mut s, &fx);
        s
    }

    #[test]
    fn a_link_copies_the_source_to_the_target_when_it_opens() {
        // jslink((a, 'value'), (b, 'value')) with a = 1 and b = 5: the frontend sets
        // b to 1 when the link opens, and the kernel gets b's new value.
        let mut s = Store::default();
        open(&mut s, "a", slider(1), json!([]), vec![]);
        open(&mut s, "b", slider(5), json!([]), vec![]);
        let fx = link(&mut s, "l", true, ("a", "value"), ("b", "value"));
        assert_eq!(
            s.get("b").expect("b").state["value"],
            1,
            "b takes a's value"
        );
        assert_eq!(
            updates_of(&fx, "b"),
            vec![json!({ "value": 1 })],
            "Lua is told of b's new value"
        );
        assert_eq!(
            sent_updates_to(&fx, "b"),
            vec![json!({ "value": 1 })],
            "the kernel gets b's new value"
        );
        assert!(sent_updates_to(&fx, "a").is_empty(), "a is not written");
    }

    #[test]
    fn a_kernel_change_of_the_source_moves_the_target() {
        // a.value = 7 in Python: b follows on screen and in the kernel.
        let mut s = linked_pair(true);
        let fx = kernel_update(&mut s, "a", json!({ "value": 7 }));
        assert_eq!(updates_of(&fx, "a"), vec![json!({ "value": 7 })]);
        assert_eq!(updates_of(&fx, "b"), vec![json!({ "value": 7 })]);
        assert_eq!(sent_updates_to(&fx, "b"), vec![json!({ "value": 7 })]);
        assert_eq!(s.get("b").expect("b").state["value"], 7);
    }

    #[test]
    fn a_frontend_change_of_the_source_moves_the_target() {
        // A slider drag on a: b follows, Lua is told of b at once (it does not know
        // b changed), and the kernel gets both updates.
        let mut s = linked_pair(true);
        let (fx, _) = s
            .frontend_update("a", obj(json!({ "value": 9 })), vec![], vec![], None)
            .expect("live");
        assert_eq!(sent_updates_to(&fx, "a"), vec![json!({ "value": 9 })]);
        assert_eq!(updates_of(&fx, "b"), vec![json!({ "value": 9 })]);
        assert_eq!(sent_updates_to(&fx, "b"), vec![json!({ "value": 9 })]);
        assert_eq!(s.get("b").expect("b").state["value"], 9);
    }

    #[test]
    fn a_directional_link_does_not_copy_back() {
        // jsdlink: a changes b, b never changes a, from the frontend or the kernel.
        let mut s = Store::default();
        open(&mut s, "a", slider(1), json!([]), vec![]);
        open(&mut s, "b", slider(5), json!([]), vec![]);
        let fx = link(&mut s, "l", false, ("a", "value"), ("b", "value"));
        settle(&mut s, &fx);
        let (fx, _) = s
            .frontend_update("b", obj(json!({ "value": 3 })), vec![], vec![], None)
            .expect("live");
        assert!(sent_updates_to(&fx, "a").is_empty(), "a is not sent");
        assert!(updates_of(&fx, "a").is_empty(), "a is not told");
        let fx = kernel_update(&mut s, "b", json!({ "value": 4 }));
        assert!(updates_of(&fx, "a").is_empty());
        assert_eq!(
            s.get("a").expect("a").state["value"],
            1,
            "a keeps its value"
        );
    }

    #[test]
    fn a_two_way_link_copies_the_target_back() {
        // jslink: a change of b moves a, from the frontend and from the kernel.
        let mut s = linked_pair(true);
        let (fx, _) = s
            .frontend_update("b", obj(json!({ "value": 3 })), vec![], vec![], None)
            .expect("live");
        assert_eq!(updates_of(&fx, "a"), vec![json!({ "value": 3 })]);
        assert_eq!(sent_updates_to(&fx, "a"), vec![json!({ "value": 3 })]);
        settle(&mut s, &fx);
        let fx = kernel_update(&mut s, "b", json!({ "value": 4 }));
        assert_eq!(updates_of(&fx, "a"), vec![json!({ "value": 4 })]);
        assert_eq!(sent_updates_to(&fx, "a"), vec![json!({ "value": 4 })]);
        assert_eq!(s.get("a").expect("a").state["value"], 4);
    }

    #[test]
    fn an_applied_echo_of_the_source_moves_the_target() {
        // The kernel clamps a after our update: the echo carries the clamped value,
        // and b follows it.
        let mut s = linked_pair(false);
        let (fx, sent) = s
            .frontend_update("a", obj(json!({ "value": 9 })), vec![], vec![], None)
            .expect("live");
        let sent = sent.expect("a's update is sent");
        // b's copy of 9 is in flight: the echo's copy of 8 waits behind it.
        let b_in_flight = sends(&fx)
            .into_iter()
            .find(|o| o.comm_id == "b")
            .expect("b's copy of 9 is sent")
            .msg_id
            .clone();
        let fx = echo(&mut s, "a", json!({ "value": 8 }), &sent);
        assert_eq!(updates_of(&fx, "a"), vec![json!({ "value": 8 })]);
        assert_eq!(updates_of(&fx, "b"), vec![json!({ "value": 8 })]);
        assert!(
            sent_updates_to(&fx, "b").is_empty(),
            "b's copy of 8 is held"
        );
        let fx = s.on_idle(&b_in_flight);
        assert_eq!(sent_updates_to(&fx, "b"), vec![json!({ "value": 8 })]);
        assert_eq!(s.get("b").expect("b").state["value"], 8);
    }

    #[test]
    fn two_links_in_a_loop_write_the_target_once() {
        // Two two-way links, a to b and b to a: a change of a reaches b once, and
        // nothing is copied back to a with the same value.
        let mut s = Store::default();
        open(&mut s, "a", slider(1), json!([]), vec![]);
        open(&mut s, "b", slider(5), json!([]), vec![]);
        let fx = link(&mut s, "l1", true, ("a", "value"), ("b", "value"));
        settle(&mut s, &fx);
        let fx = link(&mut s, "l2", true, ("b", "value"), ("a", "value"));
        settle(&mut s, &fx);
        let (fx, _) = s
            .frontend_update("a", obj(json!({ "value": 4 })), vec![], vec![], None)
            .expect("live");
        assert_eq!(
            sent_updates_to(&fx, "b"),
            vec![json!({ "value": 4 })],
            "b is written once"
        );
        assert_eq!(
            sent_updates_to(&fx, "a"),
            vec![json!({ "value": 4 })],
            "a is sent its own change and nothing back"
        );
        assert_eq!(s.get("b").expect("b").state["value"], 4);
    }

    #[test]
    fn a_closed_link_stops_copying() {
        let mut s = linked_pair(true);
        let fx = s.comm_close("l");
        assert_eq!(first_notify(&fx)["kind"], "close");
        let fx = kernel_update(&mut s, "a", json!({ "value": 7 }));
        assert!(updates_of(&fx, "b").is_empty(), "b is not told");
        assert!(sent_updates_to(&fx, "b").is_empty(), "b is not sent");
        let (fx, _) = s
            .frontend_update("a", obj(json!({ "value": 9 })), vec![], vec![], None)
            .expect("live");
        assert!(sent_updates_to(&fx, "b").is_empty());
        assert_eq!(
            s.get("b").expect("b").state["value"],
            1,
            "b keeps its value"
        );
    }

    #[test]
    fn a_closed_end_stops_the_link_until_it_opens_again() {
        let mut s = linked_pair(true);
        let fx = s.comm_close("b");
        assert_eq!(first_notify(&fx)["kind"], "close");
        let fx = kernel_update(&mut s, "a", json!({ "value": 7 }));
        assert!(updates_of(&fx, "b").is_empty() && sent_updates_to(&fx, "b").is_empty());
        // The end comes back: the link copies a's value into it.
        let fx = open(&mut s, "b", slider(5), json!([]), vec![]);
        assert_eq!(updates_of(&fx, "b"), vec![json!({ "value": 7 })]);
        assert_eq!(sent_updates_to(&fx, "b"), vec![json!({ "value": 7 })]);
        assert_eq!(s.get("b").expect("b").state["value"], 7);
    }

    #[test]
    fn a_link_waits_for_its_target_to_open() {
        let mut s = Store::default();
        open(&mut s, "a", slider(1), json!([]), vec![]);
        let fx = link(&mut s, "l", true, ("a", "value"), ("b", "value"));
        assert!(updates_of(&fx, "b").is_empty() && sent_updates_to(&fx, "b").is_empty());
        let fx = open(&mut s, "b", slider(5), json!([]), vec![]);
        assert_eq!(updates_of(&fx, "b"), vec![json!({ "value": 1 })]);
        assert_eq!(sent_updates_to(&fx, "b"), vec![json!({ "value": 1 })]);
    }

    #[test]
    fn a_dead_link_copies_nothing_after_a_reset() {
        // After a kernel restart the models are dead. The link between them stays in the
        // store, dead, and copies nothing until a new link model links the ends again.
        let mut s = linked_pair(true);
        let fx = s.reset(&["a".to_string(), "b".to_string()]);
        assert_eq!(first_notify(&fx)["kind"], "reset");
        let fx = open(&mut s, "a", slider(7), json!([]), vec![]);
        assert!(
            updates_of(&fx, "b").is_empty(),
            "b is dead: nothing is copied"
        );
        assert_eq!(
            s.get("b").expect("b").state["value"],
            1,
            "b keeps its last state"
        );
        // The dead link does not come back: a new link model is needed to link again.
        let fx = open(&mut s, "b", slider(5), json!([]), vec![]);
        assert!(updates_of(&fx, "b").is_empty() && sent_updates_to(&fx, "b").is_empty());
        assert_eq!(s.get("b").expect("b").state["value"], 5);
    }

    #[test]
    fn a_copy_waits_behind_an_update_in_flight() {
        // The link's first copy is in flight to b when a changes: b's copy waits
        // for the kernel's idle, like any frontend change of b.
        let mut s = Store::default();
        open(&mut s, "a", slider(1), json!([]), vec![]);
        open(&mut s, "b", slider(5), json!([]), vec![]);
        let fx = link(&mut s, "l", false, ("a", "value"), ("b", "value"));
        let first = sends(&fx)
            .into_iter()
            .find(|o| o.comm_id == "b")
            .expect("the first copy is sent")
            .msg_id
            .clone();
        let (fx, _) = s
            .frontend_update("a", obj(json!({ "value": 9 })), vec![], vec![], None)
            .expect("live");
        assert!(sent_updates_to(&fx, "b").is_empty(), "b's copy is held");
        assert_eq!(updates_of(&fx, "b"), vec![json!({ "value": 9 })]);
        let fx = s.on_idle(&first);
        assert_eq!(sent_updates_to(&fx, "b"), vec![json!({ "value": 9 })]);
    }

    #[test]
    fn a_binary_attribute_is_copied_with_its_buffer() {
        // An Image's value is a buffer: the link copies the bytes, and b's old bytes go.
        let mut s = Store::default();
        open(
            &mut s,
            "a",
            json!({ "_model_name": "ImageModel", "format": "png" }),
            json!([["value"]]),
            vec![b(b"PNG-A")],
        );
        open(
            &mut s,
            "b",
            json!({ "_model_name": "ImageModel", "format": "png" }),
            json!([["value"]]),
            vec![b(b"PNG-B")],
        );
        let fx = link(&mut s, "l", false, ("a", "value"), ("b", "value"));
        let m = s.get("b").expect("b");
        assert_eq!(m.buffers, vec![(vec![json!("value")], b(b"PNG-A"))]);
        assert!(
            !m.state.contains_key("value"),
            "a binary value has no state key"
        );
        let told = fx
            .iter()
            .find_map(|e| match e {
                Effect::Notify { event, buffers }
                    if event["kind"] == "update" && event["model_id"] == "b" =>
                {
                    Some((event["buffer_paths"].clone(), buffers.clone()))
                }
                _ => None,
            })
            .expect("Lua is told of b's buffer");
        assert_eq!(told, (json!([["value"]]), vec![b(b"PNG-A")]));
        let out = sends(&fx)
            .into_iter()
            .find(|o| o.comm_id == "b")
            .expect("b's buffer is sent");
        assert_eq!(out.data["buffer_paths"], json!([["value"]]));
        assert_eq!(out.buffers, vec![b(b"PNG-A")]);
    }

    #[test]
    fn a_link_between_different_attributes_writes_the_target_attribute() {
        // jslink((a, 'value'), (b, 'max')): b's max follows a's value; b's value stays.
        let mut s = Store::default();
        open(&mut s, "a", slider(1), json!([]), vec![]);
        open(&mut s, "b", slider(5), json!([]), vec![]);
        let fx = link(&mut s, "l", true, ("a", "value"), ("b", "max"));
        assert_eq!(s.get("b").expect("b").state["max"], 1);
        assert_eq!(
            s.get("b").expect("b").state["value"],
            5,
            "b's value is left alone"
        );
        assert_eq!(sent_updates_to(&fx, "b"), vec![json!({ "max": 1 })]);
    }

    #[test]
    fn a_link_whose_ends_change_is_linked_again() {
        // The kernel rewires a link to read c instead of a: b follows c, and a no
        // longer moves b.
        let mut s = linked_pair(false);
        open(&mut s, "c", slider(8), json!([]), vec![]);
        let fx = kernel_update(&mut s, "l", json!({ "source": ["IPY_MODEL_c", "value"] }));
        assert_eq!(sent_updates_to(&fx, "b"), vec![json!({ "value": 8 })]);
        assert_eq!(s.get("b").expect("b").state["value"], 8);
        let fx = kernel_update(&mut s, "a", json!({ "value": 2 }));
        assert!(
            updates_of(&fx, "b").is_empty(),
            "a is no longer linked to b"
        );
        assert_eq!(s.get("b").expect("b").state["value"], 8);
    }

    #[test]
    fn a_reset_prunes_the_dead_models_no_cell_shows() {
        // The roots are the models the cells' views name. Their children stay, and
        // a dead model nothing reaches is dropped, with its id in the reset event.
        let mut s = Store::default();
        open(&mut s, "shown", slider(1), json!([]), vec![]);
        open(
            &mut s,
            "box",
            json!({ "_model_name": "HBoxModel", "children": ["IPY_MODEL_child"] }),
            json!([]),
            vec![],
        );
        open(&mut s, "child", slider(2), json!([]), vec![]);
        open(&mut s, "gone", slider(3), json!([]), vec![]);
        let fx = s.reset(&["shown".to_string(), "box".to_string()]);
        let ev = first_notify(&fx);
        assert_eq!(ev["kind"], "reset");
        assert_eq!(ev["pruned"], json!(["gone"]));
        assert!(
            s.get("gone").is_none(),
            "the unreachable dead model is dropped"
        );
        for id in ["shown", "box", "child"] {
            let m = s.get(id).expect("a reachable model survives");
            assert!(!m.live, "{id} is dead after the reset");
        }
    }

    #[test]
    fn a_reset_keeps_a_link_between_shown_models_dead() {
        // The two sliders a cell shows keep the jslink between them through a restart:
        // the link is dead (it copies nothing), it is not pruned, and the saved state
        // still holds it. Restarts after the first keep it too.
        let mut s = linked_pair(true);
        let roots = ["a".to_string(), "b".to_string()];
        let fx = s.reset(&roots);
        assert_eq!(
            first_notify(&fx)["pruned"],
            json!([]),
            "the link between shown models is not pruned"
        );
        assert!(!s.get("l").expect("the link stays in the store").live);
        let saved = s
            .export_saved(&roots)
            .expect("the shown models are reachable");
        assert!(
            saved["state"].get("l").is_some(),
            "the export after the restart lacks the link"
        );
        let fx = s.reset(&roots);
        assert_eq!(first_notify(&fx)["pruned"], json!([]));
        let saved = s
            .export_saved(&roots)
            .expect("the shown models are reachable");
        assert!(
            saved["state"].get("l").is_some(),
            "a second restart drops the link"
        );
    }

    #[test]
    fn a_reset_prunes_a_link_whose_end_nothing_shows() {
        // The link's target is not shown: the link goes with it, and the reset event
        // names both.
        let mut s = linked_pair(true);
        let fx = s.reset(&["a".to_string()]);
        assert_eq!(first_notify(&fx)["pruned"], json!(["b", "l"]));
        assert!(s.get("l").is_none(), "a link with a dropped end is gone");
    }

    #[test]
    fn a_change_goes_on_along_a_chain_of_links() {
        // jslink a to b and b to c: a change of a reaches c through b, in the store
        // and for the kernel.
        let mut s = Store::default();
        open(&mut s, "a", slider(1), json!([]), vec![]);
        open(&mut s, "b", slider(5), json!([]), vec![]);
        open(&mut s, "c", slider(9), json!([]), vec![]);
        let fx = link(&mut s, "l1", true, ("a", "value"), ("b", "value"));
        settle(&mut s, &fx);
        let fx = link(&mut s, "l2", true, ("b", "value"), ("c", "value"));
        settle(&mut s, &fx);
        assert_eq!(
            s.get("c").expect("c").state["value"],
            1,
            "c takes b's value when its link opens"
        );
        let fx = kernel_update(&mut s, "a", json!({ "value": 7 }));
        assert_eq!(s.get("b").expect("b").state["value"], 7);
        assert_eq!(
            s.get("c").expect("c").state["value"],
            7,
            "c follows a through b"
        );
        assert_eq!(
            sent_updates_to(&fx, "c"),
            vec![json!({ "value": 7 })],
            "the kernel gets c's new value"
        );
    }

    #[test]
    fn a_buffer_is_copied_under_the_target_attribute() {
        // jsdlink((a, 'value'), (b, 'data')): a's bytes go to b under 'data', so the
        // path of the copied buffer names the target attribute, and b's old buffer
        // there is replaced.
        let mut s = Store::default();
        open(
            &mut s,
            "a",
            json!({ "_model_name": "ImageModel", "format": "png" }),
            json!([["value"]]),
            vec![b(b"PNG-A")],
        );
        open(
            &mut s,
            "b",
            json!({ "_model_name": "ImageModel", "format": "png" }),
            json!([["data"]]),
            vec![b(b"PNG-B")],
        );
        let fx = link(&mut s, "l", false, ("a", "value"), ("b", "data"));
        assert_eq!(
            s.get("b").expect("b").buffers,
            vec![(vec![json!("data")], b(b"PNG-A"))],
            "b's buffer sits under 'data' with a's bytes"
        );
        let sent = sends(&fx)
            .into_iter()
            .find(|o| o.comm_id == "b")
            .expect("b's buffer is sent");
        assert_eq!(sent.data["buffer_paths"], json!([["data"]]));
        assert_eq!(sent.buffers, vec![b(b"PNG-A")]);
    }

    #[test]
    fn a_link_whose_end_arrives_later_is_linked_then() {
        // A link opened with its source only copies nothing. Its target arrives in an
        // update: the link is linked then, copies a's value, and follows a from then on.
        let mut s = Store::default();
        open(&mut s, "a", slider(1), json!([]), vec![]);
        open(&mut s, "b", slider(5), json!([]), vec![]);
        let fx = open(
            &mut s,
            "l",
            json!({ "_model_name": "LinkModel", "source": ["IPY_MODEL_a", "value"] }),
            json!([]),
            vec![],
        );
        assert!(
            updates_of(&fx, "b").is_empty(),
            "no target yet: nothing is copied"
        );
        let fx = kernel_update(&mut s, "l", json!({ "target": ["IPY_MODEL_b", "value"] }));
        assert_eq!(updates_of(&fx, "b"), vec![json!({ "value": 1 })]);
        assert_eq!(sent_updates_to(&fx, "b"), vec![json!({ "value": 1 })]);
        assert_eq!(s.get("b").expect("b").state["value"], 1);
        let fx = kernel_update(&mut s, "a", json!({ "value": 7 }));
        assert_eq!(updates_of(&fx, "b"), vec![json!({ "value": 7 })]);
        assert_eq!(s.get("b").expect("b").state["value"], 7);
    }

    #[test]
    fn a_link_copy_of_a_frontend_change_names_no_cell() {
        // A frontend change goes with its own cell, and the copy it makes names none:
        // the RPC layer then sends the target's callback output to the cell that shows
        // the target, wherever the change was made. The copy back of a change of the
        // target names none either.
        let mut s = linked_pair(true);
        let (fx, _) = s
            .frontend_update(
                "a",
                obj(json!({ "value": 9 })),
                vec![],
                vec![],
                Some("cell-a".into()),
            )
            .expect("live");
        let own = sends(&fx)
            .into_iter()
            .find(|o| o.comm_id == "a")
            .expect("a's change is sent");
        assert_eq!(own.cell_id.as_deref(), Some("cell-a"));
        let copy = sends(&fx)
            .into_iter()
            .find(|o| o.comm_id == "b")
            .expect("b's copy is sent");
        assert_eq!(copy.cell_id, None, "the copy names the change's cell");
        settle(&mut s, &fx);
        let (fx, _) = s
            .frontend_update(
                "b",
                obj(json!({ "value": 3 })),
                vec![],
                vec![],
                Some("cell-b".into()),
            )
            .expect("live");
        let back = sends(&fx)
            .into_iter()
            .find(|o| o.comm_id == "a")
            .expect("a's copy back is sent");
        assert_eq!(back.cell_id, None, "the copy back names the change's cell");
    }
}
