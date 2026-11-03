//! Widget RPCs. A frontend widget message (update or custom) is handled on the
//! RPC reader itself, in arrival order, before the reader decodes the next
//! message: the store is locked, the effects run, and the signed frames are
//! pushed to the kernel's shell channel, all without an await.

use std::sync::Arc;
use std::time::Duration;

use anyhow::{anyhow, Result};
use bytes::Bytes;
use rmpv::Value as Mp;
use serde_json::{json, Map, Value as Json};

use super::{json_to_mp, Server};
use crate::session::Session;
use crate::widgets::{is_empty_update, parse_paths, Effect, Store};

impl Server {
    /// A widget_event for Lua: the event and the binary buffers that travel with
    /// it (msgpack bin, never base64).
    pub(super) fn notify_widget_event(&self, sid: &str, event: Json, buffers: Vec<Bytes>) {
        let params = Mp::Map(vec![
            (Mp::from("session_id"), Mp::from(sid)),
            (Mp::from("event"), json_to_mp(&event)),
            (
                Mp::from("buffers"),
                Mp::Array(buffers.iter().map(|b| Mp::Binary(b.to_vec())).collect()),
            ),
        ]);
        self.notify_now("widget_event", params);
    }

    /// Runs the effects of the store. Called with the store unlocked. Lua
    /// notifications and kernel frames are sent synchronously; a timer is a task
    /// that locks the store only when it fires.
    pub(super) fn run_widget_effects(
        self: &Arc<Self>,
        session: &Arc<Session>,
        sid: &str,
        effects: Vec<Effect>,
    ) {
        for effect in effects {
            match effect {
                Effect::Notify { event, buffers } => self.notify_widget_event(sid, event, buffers),
                Effect::Send(out) => {
                    // A comm message that names no cell has its callback's output in the
                    // first cell that shows the widget: a copy a link makes (after a
                    // kernel or a frontend change), an Output widget's outputs flush, a
                    // held update released with no cell, an update or a custom message
                    // (a click) sent before the widget's cell was drawn. A comm_close
                    // runs no callback. Read before the connection is taken.
                    let cell = match &out.cell_id {
                        Some(cell) => Some(cell.clone()),
                        None if out.msg_type == "comm_msg" => session.cell_showing(&out.comm_id),
                        None => None,
                    };
                    let guard = session.widgets.comm_tx.read();
                    let Some(sender) = guard.as_ref() else {
                        tracing::warn!("comm message {} dropped: no kernel", out.msg_id);
                        continue;
                    };
                    // The callback's output is routed before the message can be answered.
                    if let Some(cell) = cell {
                        session.widgets.comm_cell.insert(out.msg_id.clone(), cell);
                    }
                    let content = json!({ "comm_id": out.comm_id, "data": out.data });
                    if let Err(e) =
                        sender.send(out.msg_type, content, json!({}), out.buffers, out.msg_id)
                    {
                        tracing::warn!("comm message not sent: {e}");
                    }
                }
                Effect::FlushOutputsAfter { model_id, delay } => {
                    self.spawn_widget_timer(session, sid, delay, move |store: &mut Store| {
                        store.flush_outputs(&model_id)
                    });
                }
                Effect::CheckInflightAfter {
                    model_id,
                    msg_id,
                    delay,
                } => {
                    self.spawn_widget_timer(session, sid, delay, move |store: &mut Store| {
                        store.inflight_timeout(&model_id, &msg_id)
                    });
                }
            }
        }
    }

    /// After `delay`, runs `due` on the store and then the effects it returns.
    fn spawn_widget_timer<F>(
        self: &Arc<Self>,
        session: &Arc<Session>,
        sid: &str,
        delay: Duration,
        due: F,
    ) where
        F: FnOnce(&mut Store) -> Vec<Effect> + Send + 'static,
    {
        let server = self.clone();
        let session = session.clone();
        let sid = sid.to_string();
        tokio::spawn(async move {
            tokio::time::sleep(delay).await;
            let effects = due(&mut session.widgets.store.lock());
            server.run_widget_effects(&session, &sid, effects);
        });
    }

    /// widget_update {session_id, model_id, state, buffer_paths?, cell_id?} with
    /// the binary buffers. Returns {msg_id, queued}. msg_id is set when the update
    /// was sent. queued is set only when the update waits behind the update in
    /// flight; an update with nothing to apply is neither sent nor queued.
    pub(super) fn widget_update(self: &Arc<Self>, p: Json, buffers: Vec<Bytes>) -> Result<Json> {
        let (session, sid) = self.widget_session(&p)?;
        require_kernel(&session)?;
        let model_id = str_field(&p, "model_id")?;
        // Lua encodes an empty table as an array, which counts as no state.
        let state: Map<String, Json> = match p.get("state") {
            Some(Json::Object(m)) => m.clone(),
            _ => Map::new(),
        };
        let paths = parse_paths(p.get("buffer_paths"));
        let nothing = is_empty_update(&state, &paths, &buffers);
        let cell_id = p.get("cell_id").and_then(Json::as_str).map(str::to_string);
        let (effects, msg_id) = session
            .widgets
            .store
            .lock()
            .frontend_update(model_id, state, paths, buffers, cell_id)?;
        self.run_widget_effects(&session, &sid, effects);
        Ok(json!({ "msg_id": msg_id, "queued": msg_id.is_none() && !nothing }))
    }

    /// widget_custom {session_id, model_id, content, cell_id?} with the binary
    /// buffers. Returns {msg_id}.
    pub(super) fn widget_custom(self: &Arc<Self>, p: Json, buffers: Vec<Bytes>) -> Result<Json> {
        let (session, sid) = self.widget_session(&p)?;
        require_kernel(&session)?;
        let model_id = str_field(&p, "model_id")?;
        let content = p.get("content").cloned().unwrap_or(Json::Null);
        let cell_id = p.get("cell_id").and_then(Json::as_str).map(str::to_string);
        let (effects, msg_id) = session
            .widgets
            .store
            .lock()
            .frontend_custom(model_id, content, buffers, cell_id)?;
        self.run_widget_effects(&session, &sid, effects);
        Ok(json!({ "msg_id": msg_id }))
    }

    /// widget_state {session_id}: every model of the session, in the snapshot shape.
    pub(super) fn widget_state(&self, p: Json) -> Result<Json> {
        let (session, _) = self.widget_session(&p)?;
        let models = session.widgets.store.lock().models_json();
        Ok(json!({ "models": models }))
    }

    fn widget_session(&self, p: &Json) -> Result<(Arc<Session>, String)> {
        let sid = str_field(p, "session_id")?;
        let session = self
            .sessions
            .get(sid)
            .ok_or_else(|| anyhow!("no session"))?
            .clone();
        Ok((session, sid.to_string()))
    }
}

fn str_field<'a>(p: &'a Json, key: &str) -> Result<&'a str> {
    p.get(key)
        .and_then(Json::as_str)
        .ok_or_else(|| anyhow!("{key} required"))
}

/// Refuses a widget message while the session has no kernel: a model of a kernel
/// that never started (or has been stopped) has no comm to send to.
fn require_kernel(session: &Session) -> Result<()> {
    if session.widgets.comm_tx.read().is_none() {
        return Err(anyhow!("kernel not started"));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;
    use std::sync::Arc;
    use std::time::{Duration, Instant};

    use rmpv::Value as Mp;
    use serde_json::json;
    use tokio::sync::mpsc;
    use zeromq::ZmqMessage;

    use super::super::Server;
    use crate::kernel::{CommSender, KernelEvent};
    use crate::protocol::Message;
    use crate::session::Session;
    use crate::widgets::{Effect, TARGET, VIEW_MIME};

    const SID: &str = "sess";
    const KEY: &[u8] = b"k";

    /// Adds a code cell `cell_id` whose output is the view of the model `id`.
    fn show(session: &Session, cell_id: &str, id: &str) {
        let mut cell = crate::notebook::Cell::new_code();
        cell.id = cell_id.to_string();
        cell.outputs.push(json!({
            "output_type": "display_data",
            "data": { VIEW_MIME: { "version_major": 2, "version_minor": 0, "model_id": id } },
            "metadata": {},
        }));
        session.notebook.write().cells.push(cell);
    }

    /// A server with one session whose kernel is a test channel. The store
    /// holds a live button "b" and a live slider "s"; the receiver gets every
    /// comm frame the core sends to the kernel.
    fn fixture() -> (Arc<Server>, mpsc::UnboundedReceiver<ZmqMessage>) {
        let server = Server::new();
        let session = Session::open(
            SID.into(),
            PathBuf::from("jupynvim-widget-test-no-such.ipynb"),
        )
        .expect("an empty session opens");
        server.sessions.insert(SID.to_string(), session.clone());
        let (tx, rx) = mpsc::unbounded_channel();
        *session.widgets.comm_tx.write() = Some(CommSender::new(tx, KEY.to_vec(), "kernel".into()));
        {
            let mut store = session.widgets.store.lock();
            store.comm_open(
                "b",
                TARGET,
                &json!({ "state": { "_model_name": "ButtonModel" } }),
                &json!({}),
                &[],
            );
            store.comm_open(
                "s",
                TARGET,
                &json!({ "state": { "_model_name": "IntSliderModel", "value": 3 } }),
                &json!({}),
                &[],
            );
        }
        (server, rx)
    }

    fn map(pairs: Vec<(&str, Mp)>) -> Mp {
        Mp::Map(pairs.into_iter().map(|(k, v)| (Mp::from(k), v)).collect())
    }

    /// A request frame `[0, msgid, method, [params]]`.
    fn request(msgid: u64, method: &str, params: Mp) -> Mp {
        Mp::Array(vec![
            Mp::from(0u32),
            Mp::from(msgid),
            Mp::from(method),
            Mp::Array(vec![params]),
        ])
    }

    /// A widget_custom request to the button, carrying `n`.
    fn custom(n: u64) -> Mp {
        request(
            n,
            "widget_custom",
            map(vec![
                ("session_id", Mp::from(SID)),
                ("model_id", Mp::from("b")),
                ("content", map(vec![("n", Mp::from(n))])),
            ]),
        )
    }

    /// The comm message a frame carries, verified with KEY.
    fn decode(zmsg: ZmqMessage) -> Message {
        Message::from_frames(zmsg.into_vec(), KEY).expect("a signed comm frame")
    }

    #[tokio::test]
    async fn widget_requests_are_handled_in_order_before_returning() {
        let (server, mut rx) = fixture();
        for n in 1..=3 {
            assert!(
                server.try_widget_request(custom(n)).is_ok(),
                "request {n} was not taken by the reader"
            );
        }
        // No await between the calls and these reads: each frame was pushed
        // before its call returned, so the kernel gets them in arrival order.
        let mut order = Vec::new();
        while let Ok(zmsg) = rx.try_recv() {
            let msg = decode(zmsg);
            assert_eq!(msg.header.msg_type, "comm_msg");
            order.push(msg.content["data"]["content"]["n"].as_u64().unwrap_or(0));
        }
        assert_eq!(
            order,
            vec![1, 2, 3],
            "the kernel got the requests out of order"
        );

        // A slider update is in the store as soon as its call returns.
        let update = request(
            4,
            "widget_update",
            map(vec![
                ("session_id", Mp::from(SID)),
                ("model_id", Mp::from("s")),
                ("state", map(vec![("value", Mp::from(9))])),
            ]),
        );
        assert!(server.try_widget_request(update).is_ok());
        let session = server.sessions.get(SID).expect("the session").clone();
        let value = session
            .widgets
            .store
            .lock()
            .get("s")
            .and_then(|m| m.state.get("value").cloned());
        assert_eq!(
            value,
            Some(json!(9)),
            "the update was not applied on the reader"
        );
    }

    #[tokio::test]
    async fn non_widget_requests_come_back_untouched() {
        let (server, _rx) = fixture();
        let ping = Mp::Array(vec![
            Mp::from(0u32),
            Mp::from(7u64),
            Mp::from("ping"),
            Mp::Array(vec![]),
        ]);
        match server.try_widget_request(ping.clone()) {
            Err(back) => assert_eq!(back, ping, "the request was changed on its way back"),
            Ok(()) => panic!("a ping was taken by the widget path"),
        }
        let notify = Mp::Array(vec![
            Mp::from(2u32),
            Mp::from("cell_event"),
            Mp::Array(vec![]),
        ]);
        assert!(
            server.try_widget_request(notify).is_err(),
            "a cell notification was taken by the widget path"
        );
    }

    #[tokio::test]
    async fn empty_update_is_not_queued_and_sends_nothing() {
        let (server, mut rx) = fixture();

        // An update with no state and no buffer is not held and is not sent.
        let empty = server
            .widget_update(
                json!({ "session_id": SID, "model_id": "s", "state": [] }),
                vec![],
            )
            .expect("an empty update is accepted");
        assert_eq!(
            empty,
            json!({ "msg_id": null, "queued": false }),
            "an empty update is neither sent nor queued"
        );
        assert!(
            rx.try_recv().is_err(),
            "an empty update sends nothing to the kernel"
        );

        // A buffer whose path is not valid is dropped by the store, so the update
        // is empty as well.
        let invalid = server
            .widget_update(
                json!({ "session_id": SID, "model_id": "s", "state": {}, "buffer_paths": [[1]] }),
                vec![bytes::Bytes::from_static(b"x")],
            )
            .expect("an update with an invalid path is accepted");
        assert_eq!(invalid, json!({ "msg_id": null, "queued": false }));
        assert!(rx.try_recv().is_err(), "nothing is sent for it either");

        // A real update is sent at once; the next one waits behind it.
        let first = server
            .widget_update(
                json!({ "session_id": SID, "model_id": "s", "state": { "value": 1 } }),
                vec![],
            )
            .expect("the update is accepted");
        assert!(first["msg_id"].is_string(), "value 1 is sent: {first}");
        assert_eq!(first["queued"], json!(false));
        let second = server
            .widget_update(
                json!({ "session_id": SID, "model_id": "s", "state": { "value": 2 } }),
                vec![],
            )
            .expect("the update is accepted");
        assert_eq!(second["msg_id"], json!(null), "value 2 is held: {second}");
        assert_eq!(second["queued"], json!(true));
    }

    #[tokio::test]
    async fn a_buffer_path_that_is_not_a_list_keeps_the_buffers_aligned() {
        // The first entry is not a path, so its buffer is dropped with it. The
        // second buffer belongs to ["value"], and must not shift onto the entry
        // that was dropped.
        let (server, _rx) = fixture();
        server
            .widget_update(
                json!({
                    "session_id": SID,
                    "model_id": "s",
                    "state": {},
                    "buffer_paths": ["bad", ["value"]],
                }),
                vec![
                    bytes::Bytes::from_static(b"one"),
                    bytes::Bytes::from_static(b"two"),
                ],
            )
            .expect("the update is accepted");
        let session = server.sessions.get(SID).expect("the session").clone();
        let store = session.widgets.store.lock();
        let model = store.get("s").expect("the slider");
        assert_eq!(
            model.buffers,
            vec![(vec![json!("value")], bytes::Bytes::from_static(b"two"))],
            "the buffer of ['value'] is the second one"
        );
    }

    #[tokio::test]
    async fn a_callback_of_an_update_with_no_cell_prints_in_the_cell_showing_the_widget() {
        // A change that names no cell (the store's copies and held updates) sends its
        // callback's output to the cell that shows the widget.
        let (server, _rx) = fixture();
        let session = server.sessions.get(SID).expect("the session").clone();
        show(&session, "cs", "s");
        let state = json!({ "value": 9 })
            .as_object()
            .cloned()
            .expect("an object");
        let (effects, msg_id) = session
            .widgets
            .store
            .lock()
            .frontend_update("s", state, vec![], vec![], None)
            .expect("the slider is live");
        let msg_id = msg_id.expect("the update is sent");
        server.run_widget_effects(&session, SID, effects);
        assert_eq!(
            session.widgets.comm_cell.get(&msg_id).map(|c| c.clone()),
            Some("cs".to_string()),
            "the callback's output has no cell"
        );
    }

    #[tokio::test]
    async fn a_copy_the_kernel_makes_prints_in_the_cell_showing_its_target() {
        // The kernel changes s, and the link copies it to t: t's callback output goes to
        // the cell that shows t, which shows it inside a box, as the rule for a callback
        // of a widget says.
        let (server, _rx) = fixture();
        let session = server.sessions.get(SID).expect("the session").clone();
        show(&session, "ct", "box");
        let (effects, copy) = {
            let mut store = session.widgets.store.lock();
            // t starts at the value the link copies, so opening the link sends nothing.
            store.comm_open(
                "t",
                TARGET,
                &json!({ "state": { "_model_name": "IntSliderModel", "value": 3 } }),
                &json!({}),
                &[],
            );
            store.comm_open(
                "box",
                TARGET,
                &json!({ "state": { "_model_name": "HBoxModel", "children": ["IPY_MODEL_t"] } }),
                &json!({}),
                &[],
            );
            store.comm_open(
                "l",
                TARGET,
                &json!({ "state": {
                    "_model_name": "LinkModel",
                    "source": ["IPY_MODEL_s", "value"],
                    "target": ["IPY_MODEL_t", "value"],
                } }),
                &json!({}),
                &[],
            );
            let effects = store.comm_msg(
                "s",
                &json!({ "method": "update", "state": { "value": 7 }, "buffer_paths": [] }),
                &[],
                None,
            );
            let copy = effects.iter().find_map(|e| match e {
                Effect::Send(o) if o.comm_id == "t" => Some(o.msg_id.clone()),
                _ => None,
            });
            (effects, copy)
        };
        let copy = copy.expect("the kernel's change is copied to t");
        server.run_widget_effects(&session, SID, effects);
        assert_eq!(
            session.widgets.comm_cell.get(&copy).map(|c| c.clone()),
            Some("ct".to_string()),
            "the copy's callback output has no cell"
        );
    }

    #[tokio::test]
    async fn a_link_copy_of_a_frontend_change_prints_in_the_cell_showing_its_target() {
        // s shows in one cell and t, inside a box, in another, with a link from s to t.
        // A frontend change of s made in s's cell keeps that cell for s's own callback,
        // and the copy to t goes to the cell that shows t, as a copy the kernel's change
        // makes does: a callback's output goes to the cell that shows its widget.
        let (server, _rx) = fixture();
        let session = server.sessions.get(SID).expect("the session").clone();
        show(&session, "cs", "s");
        show(&session, "ct", "box");
        {
            let mut store = session.widgets.store.lock();
            // t starts at the value the link copies, so opening the link sends nothing.
            store.comm_open(
                "t",
                TARGET,
                &json!({ "state": { "_model_name": "IntSliderModel", "value": 3 } }),
                &json!({}),
                &[],
            );
            store.comm_open(
                "box",
                TARGET,
                &json!({ "state": { "_model_name": "HBoxModel", "children": ["IPY_MODEL_t"] } }),
                &json!({}),
                &[],
            );
            store.comm_open(
                "l",
                TARGET,
                &json!({ "state": {
                    "_model_name": "LinkModel",
                    "source": ["IPY_MODEL_s", "value"],
                    "target": ["IPY_MODEL_t", "value"],
                } }),
                &json!({}),
                &[],
            );
        }
        let state = json!({ "value": 9 })
            .as_object()
            .cloned()
            .expect("an object");
        let (effects, own) = session
            .widgets
            .store
            .lock()
            .frontend_update("s", state, vec![], vec![], Some("cs".to_string()))
            .expect("the slider is live");
        let own = own.expect("the change is sent");
        let copy = effects
            .iter()
            .find_map(|e| match e {
                Effect::Send(o) if o.comm_id == "t" => Some(o.msg_id.clone()),
                _ => None,
            })
            .expect("the change is copied to t");
        server.run_widget_effects(&session, SID, effects);
        assert_eq!(
            session.widgets.comm_cell.get(&own).map(|c| c.clone()),
            Some("cs".to_string()),
            "the change's own callback output left its cell"
        );
        assert_eq!(
            session.widgets.comm_cell.get(&copy).map(|c| c.clone()),
            Some("ct".to_string()),
            "the copy's callback output is not in the cell that shows t"
        );
    }

    #[tokio::test]
    async fn a_custom_message_with_no_cell_prints_in_the_cell_showing_the_widget() {
        // A button click sent before the button's cell was drawn names no cell; the
        // click's callback output goes to the cell that shows the button.
        let (server, _rx) = fixture();
        let session = server.sessions.get(SID).expect("the session").clone();
        show(&session, "cb", "b");
        let (effects, msg_id) = session
            .widgets
            .store
            .lock()
            .frontend_custom("b", json!({ "event": "click" }), vec![], None)
            .expect("the button is live");
        server.run_widget_effects(&session, SID, effects);
        assert_eq!(
            session.widgets.comm_cell.get(&msg_id).map(|c| c.clone()),
            Some("cb".to_string()),
            "the click's callback output has no cell"
        );
    }

    #[tokio::test]
    async fn an_outputs_flush_prints_in_the_cell_showing_the_output_widget() {
        // An Output widget's captures go back to the kernel as an update that names no
        // cell; an observer of its outputs prints in the cell that shows the widget.
        let (server, _rx) = fixture();
        let session = server.sessions.get(SID).expect("the session").clone();
        show(&session, "co", "o");
        let effects = {
            let mut store = session.widgets.store.lock();
            store.comm_open(
                "o",
                TARGET,
                &json!({ "state": { "_model_name": "OutputModel", "msg_id": "X", "outputs": [] } }),
                &json!({}),
                &[],
            );
            let captured = KernelEvent::Stream {
                msg_id: "e1".into(),
                parent_msg_id: Some("X".into()),
                name: "stdout".into(),
                text: "a\n".into(),
            };
            store.route_output("X", &captured).expect("captured");
            store.flush_before_request()
        };
        let flush = effects
            .iter()
            .find_map(|e| match e {
                Effect::Send(o) if o.comm_id == "o" => Some(o.msg_id.clone()),
                _ => None,
            })
            .expect("the capture is flushed");
        server.run_widget_effects(&session, SID, effects);
        assert_eq!(
            session.widgets.comm_cell.get(&flush).map(|c| c.clone()),
            Some("co".to_string()),
            "the flush's callback output has no cell"
        );
    }

    #[cfg_attr(debug_assertions, ignore)]
    #[tokio::test]
    async fn budget_cell_showing() {
        // Budget: the lookup of the cell that shows a widget, made for a comm message
        // that names no cell (a link copy, an outputs flush), over 500 code cells that
        // each show a box of two sliders, for a slider of the last cell: 1 ms on average
        // over 1,000 lookups.
        let (server, _rx) = fixture();
        let session = server.sessions.get(SID).expect("the session").clone();
        {
            let mut store = session.widgets.store.lock();
            for i in 0..500 {
                for name in ["x", "y"] {
                    store.comm_open(
                        &format!("{name}{i}"),
                        TARGET,
                        &json!({ "state": { "_model_name": "IntSliderModel", "value": 1 } }),
                        &json!({}),
                        &[],
                    );
                }
                store.comm_open(
                    &format!("box{i}"),
                    TARGET,
                    &json!({ "state": {
                        "_model_name": "HBoxModel",
                        "children": [format!("IPY_MODEL_x{i}"), format!("IPY_MODEL_y{i}")],
                    } }),
                    &json!({}),
                    &[],
                );
            }
        }
        for i in 0..500 {
            show(&session, &format!("c{i}"), &format!("box{i}"));
        }
        let start = Instant::now();
        for _ in 0..1000 {
            assert_eq!(session.cell_showing("y499").as_deref(), Some("c499"));
        }
        let elapsed = start.elapsed();
        println!("budget: 1,000 lookups of the cell showing a widget, 500 cells, in {elapsed:?}");
        assert!(
            elapsed < Duration::from_secs(1),
            "1,000 lookups took {elapsed:?} (budget 1 s)"
        );
    }

    #[cfg_attr(debug_assertions, ignore)]
    #[tokio::test]
    async fn budget_widget_requests() {
        // Budget: a widget request handled on the reader, signed frames included,
        // in 50 microseconds on average. The requests are built before the clock
        // starts.
        let (server, mut rx) = fixture();
        let requests: Vec<Mp> = (0..10_000u64).map(custom).collect();
        let start = Instant::now();
        for req in requests {
            assert!(server.try_widget_request(req).is_ok());
        }
        let elapsed = start.elapsed();
        let mut frames = 0usize;
        while rx.try_recv().is_ok() {
            frames += 1;
        }
        println!("budget: 10,000 widget_custom requests on the reader in {elapsed:?}");
        assert_eq!(frames, 10_000, "a request sent no frame");
        assert!(
            elapsed < Duration::from_millis(500),
            "10,000 widget requests took {elapsed:?} (budget 500 ms)"
        );
    }
}
