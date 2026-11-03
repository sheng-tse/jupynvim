#!/usr/bin/env python3
"""
Widget protocol tests: the ipywidgets 8 comm protocol on a real kernel, driven
through jupynvim-core's RPC. Each case opens its own notebook and kernel.

  W1  comm_open reaches the frontend before the cell's result
  W2  frontend updates: the kernel clamps, the echo is silent, and no kernel
      event names our messages
  W3  one update in flight per model: the kernel sees [1, 5]
  W3b a burst of 200 updates reaches the kernel in order and ends on 200
  W4  a click's print lands in the widget's cell, with no busy or idle there
  W5  tqdm.notebook and tqdm.auto bars run live to 100% in success
  W6  an Output widget captures its outputs and syncs them back
  W7  binary buffers travel both ways
  W8  a comm for an unknown target is closed back
  W9  a kernel restart leaves the models dead
  W10 saved widget state holds only what the cells show, and reopens dead
  W11 the gallery round trip: every cell runs, the saved state is what the
      views reach (with links), it matches the live state, and it reopens dead
  W12 a callback's display update (dh.update) reaches the display's cell
  W13 a saved block this version cannot read is written back once nothing
      shows, after the first save replaced it (version 3 and Colab shapes)
  W14 a busy kernel gets one Output flush at a time: a cell printing inside
      `with out:` for 3 s makes the observer of 'outputs' run at most twice
  W15 interact's callback prints go to its Output widget, not to the cell
  W16 a free kernel's `with out:` per loop iteration flushes at most every 500 ms
  W17 a cell run after two `with out:` cells reads both captures (the sync back)
  W18 an append after a captured output keeps every output, in the kernel and the store
  W19 the flushes of two cells are at least 0.45 s apart (the cadence across cells)
  W20 a click whose handler appends, right after a `with out:` cell, keeps every output
  W21 a slider update whose observer appends, right after a `with out:` cell, keeps every output
  W22 a kernel-side buffer update and a kernel-side close reach the frontend and never a kernel event
  W23 jslink: b takes a's value when the link opens, follows a in the kernel, and a follows b back
  W23b jsdlink: b follows a, and neither a frontend nor a kernel change of b reaches a
  W23c the observer of b prints in the cell that shows b, when a kernel change of a
      reaches it through the link
  W23d a frontend change of a, made in a's cell: a's observer prints there, and b's
      observer, run by the link's copy, prints in the cell that shows b
  W4b a click sent with no cell (before the button's cell is drawn) prints in the
      button's cell
  W11b a saved gallery with two link models keeps them through a kernel start and a save
  W2, W3 again with JUPYTER_WIDGETS_ECHO=0 (no echo_update from the kernel)

Run by tests/run_all.sh, or alone inside tests/lib/test_env.sh:
  bash -c 'source tests/lib/test_env.sh; python tests/widget_protocol.py'
"""
import base64
import json
import os
import shutil
import sys
import time
from collections import deque

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from backend_integration import Client, tmp_nb  # noqa: E402

PASS, FAIL = 0, 0
HERE = os.path.dirname(os.path.abspath(__file__))
GALLERY = os.path.join(HERE, "fixtures", "widgets_gallery.ipynb")
VIEW_MIME = "application/vnd.jupyter.widget-view+json"
STATE_MIME = "application/vnd.jupyter.widget-state+json"
REF = "IPY_MODEL_"
LINK_MODELS = ("LinkModel", "DirectionalLinkModel")
KERNELSPEC = {"name": "python3", "display_name": "Python 3", "language": "python"}
SLIDER = "import ipywidgets as w\ns = w.IntSlider(value=3, max=10, description='n')\ns"


PREFIX = ""


def report(name, ok, detail=""):
    global PASS, FAIL
    PASS += int(ok)
    FAIL += int(not ok)
    sym = "[PASS]" if ok else "[FAIL]"
    print(f"  {sym} {PREFIX}{name}{(' -- ' + detail) if detail and not ok else ''}")


class echo_off:
    """The kernel is started with JUPYTER_WIDGETS_ECHO=0 (ipywidgets then sends
    no echo_update, as protocol 2.0 kernels do). The core passes its environment
    to the kernel it starts, so the variable is set while the case's Nb starts."""

    def __enter__(self):
        self.old = os.environ.get("JUPYTER_WIDGETS_ECHO")
        os.environ["JUPYTER_WIDGETS_ECHO"] = "0"

    def __exit__(self, *exc):
        if self.old is None:
            os.environ.pop("JUPYTER_WIDGETS_ECHO", None)
        else:
            os.environ["JUPYTER_WIDGETS_ECHO"] = self.old


# ── event helpers ───────────────────────────────────────────────────────
def is_note(ev, method):
    """True for a notification of `method`: the core sends [2, method, [params]]."""
    return isinstance(ev, list) and len(ev) == 3 and ev[0] == 2 and ev[1] == method


def note(ev):
    return ev[2][0]


def cell_status(ev, cell_id, state):
    if not is_note(ev, "cell_event"):
        return False
    p = note(ev)
    return (p["cell_id"] == cell_id and p["event"].get("kind") == "status"
            and p["event"].get("state") == state)


def find(cl, pred, since=0, timeout=10):
    """Index of the first event at or after `since` that pred accepts, or None.
    With timeout 0 it looks once, at the events that already arrived."""
    start = since
    deadline = time.time() + timeout
    while True:
        end = len(cl.events)
        for i in range(start, end):
            if pred(cl.events[i]):
                return i
        start = end
        if time.time() >= deadline:
            return None
        time.sleep(0.02)


def send(cl, method, params):
    """Send a request without waiting for its reply; returns its msg id."""
    msgid = cl.next_id
    cl.next_id += 1
    cl._send(method, params, msgid)
    return msgid


def reply(cl, msgid, timeout=10):
    """(err, result) of a request sent with send(), or ("timeout", None)."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        for ev in cl.events:
            if isinstance(ev, list) and ev[0] == 1 and ev[1] == msgid:
                return ev[2], ev[3]
        time.sleep(0.005)
    return "timeout", None


class Nb:
    """One notebook with its own kernel: a Client, an open session, code cells.
    With copy_of, the notebook is a copy of that file instead of `cells`."""

    def __init__(self, cells=None, copy_of=None):
        self.cl = Client()
        self.sid = None
        self.path = tmp_nb()
        try:
            if copy_of is not None:
                shutil.copyfile(copy_of, self.path)
            else:
                nb = {
                    "cells": [
                        {"cell_type": "code", "id": cid, "metadata": {}, "source": src,
                         "execution_count": None, "outputs": []}
                        for cid, src in cells
                    ],
                    "metadata": {"kernelspec": KERNELSPEC},
                    "nbformat": 4,
                    "nbformat_minor": 5,
                }
                with open(self.path, "w") as f:
                    json.dump(nb, f)
            err, res = self.cl.call("open", {"path": self.path})
            if err is not None or not res:
                raise RuntimeError(f"open: {err}")
            self.sid = res["session_id"]
            err, _ = self.cl.call("start_kernel", {"session_id": self.sid}, timeout=60)
            if err is not None:
                raise RuntimeError(f"start_kernel: {err}")
        except Exception:
            self.close()
            raise

    def close(self):
        if self.sid is not None:
            self.cl.call("stop_kernel", {"session_id": self.sid}, timeout=15)
        self.cl.stop()
        if os.path.exists(self.path):
            os.unlink(self.path)

    def mark(self):
        return len(self.cl.events)

    def run(self, cell_id, timeout=30):
        """Execute a cell and wait for its idle status."""
        since = self.mark()
        err, _ = self.cl.call("execute", {"session_id": self.sid, "cell_id": cell_id})
        if err is not None:
            raise RuntimeError(f"execute {cell_id}: {err}")
        if find(self.cl, lambda e: cell_status(e, cell_id, "idle"), since, timeout) is None:
            raise RuntimeError(f"cell {cell_id} did not go idle")

    def cell_events(self, cell_id, since=0):
        return [note(ev) for ev in self.cl.events[since:]
                if is_note(ev, "cell_event") and note(ev)["cell_id"] == cell_id]

    def text(self, cell_id, since=0):
        return "".join(p["event"]["text"] for p in self.cell_events(cell_id, since)
                       if p["event"].get("kind") == "stream")

    def widget_events(self, since=0, kind=None, model_id=None):
        out = []
        for ev in self.cl.events[since:]:
            if not is_note(ev, "widget_event"):
                continue
            p = note(ev)
            e = p["event"]
            if kind is not None and e.get("kind") != kind:
                continue
            if model_id is not None and e.get("model_id") != model_id:
                continue
            out.append(p)
        return out

    def view_id(self, cell_id, since=0):
        for p in self.cell_events(cell_id, since):
            e = p["event"]
            if e.get("kind") in ("execute_result", "display_data"):
                view = (e.get("data") or {}).get(VIEW_MIME)
                if view:
                    return view["model_id"]
        return None

    def view_ids(self, cell_id, since=0):
        ids = []
        for p in self.cell_events(cell_id, since):
            e = p["event"]
            if e.get("kind") in ("execute_result", "display_data"):
                view = (e.get("data") or {}).get(VIEW_MIME)
                if view:
                    ids.append(view["model_id"])
        return ids

    def kernel_raws(self, since=0):
        return [note(ev)["event"].get("raw", "") for ev in self.cl.events[since:]
                if is_note(ev, "kernel_event")]

    def models(self):
        err, res = self.cl.call("widget_state", {"session_id": self.sid})
        if err is not None:
            raise RuntimeError(f"widget_state: {err}")
        return res["models"]

    def model(self, model_id):
        for m in self.models():
            if m["model_id"] == model_id:
                return m
        return None

    def update(self, model_id, state, cell_id=None, **extra):
        """A frontend update, sent and waited for: (err, result)."""
        params = {"session_id": self.sid, "model_id": model_id, "state": state}
        if cell_id is not None:
            params["cell_id"] = cell_id
        params.update(extra)
        return self.cl.call("widget_update", params)


def poll(nb, cell_id, expected, timeout=15):
    """Run a cell until its output is `expected`; returns the last output.
    Each run is queued behind the kernel's work, so later runs see later state."""
    deadline = time.time() + timeout
    last = ""
    while True:
        since = nb.mark()
        nb.run(cell_id)
        last = nb.text(cell_id, since).strip()
        if last == expected or time.time() >= deadline:
            return last
        time.sleep(0.2)


# ── cases ───────────────────────────────────────────────────────────────
def w1():
    nb = Nb([("w1", SLIDER)])
    try:
        nb.run("w1")
        opened = nb.widget_events(kind="open")
        slider = next((p for p in opened
                       if p["event"].get("model_name") == "IntSliderModel"), None)
        ok = slider is not None and slider["event"]["state"].get("value") == 3
        report("W1 comm_open reaches the frontend with the slider's state", ok,
               f"open events: {[p['event'].get('model_name') for p in opened]}")
        # the slider's own open: the Layout and Style models open before it
        i_open = find(nb.cl, lambda e: is_note(e, "widget_event")
                      and note(e)["event"].get("kind") == "open"
                      and note(e)["event"].get("model_name") == "IntSliderModel", timeout=0)
        i_res = find(nb.cl, lambda e: is_note(e, "cell_event") and note(e)["cell_id"] == "w1"
                     and note(e)["event"].get("kind") == "execute_result", timeout=0)
        report("W1 the open comes before the cell's execute_result",
               i_open is not None and i_res is not None and i_open < i_res,
               f"open at {i_open}, execute_result at {i_res}")
        mid = nb.view_id("w1")
        report("W1 the cell's view is the opened model",
               slider is not None and mid == slider["event"]["model_id"], f"view {mid}")
        report("W1 no kernel event names a comm",
               not any("Comm" in r for r in nb.kernel_raws()))
    finally:
        nb.close()


def w2():
    nb = Nb([("w2a", SLIDER), ("w2b", "print(s.value)"), ("w2c", "print(s.value)")])
    try:
        nb.run("w2a")
        mid = nb.view_id("w2a")
        err1, r1 = nb.update(mid, {"value": 7}, cell_id="w2a")
        m1 = (r1 or {}).get("msg_id")
        report("W2 widget_update 7 is sent at once (msg id, not queued)",
               err1 is None and bool(m1) and (r1 or {}).get("queued") is False,
               f"reply {err1} {r1}")
        nb.run("w2b")
        report("W2 the kernel holds 7 after the update",
               nb.text("w2b").strip() == "7", f"printed {nb.text('w2b')!r}")
        since = nb.mark()
        err2, r2 = nb.update(mid, {"value": 42}, cell_id="w2a")
        m2 = (r2 or {}).get("msg_id")
        report("W2 widget_update 42 is sent at once (msg id, not queued)",
               err2 is None and bool(m2) and (r2 or {}).get("queued") is False,
               f"reply {err2} {r2}")
        nb.run("w2c")
        report("W2 the kernel clamps 42 to 10",
               nb.text("w2c").strip() == "10", f"printed {nb.text('w2c')!r}")
        updates = nb.widget_events(since, kind="update", model_id=mid)
        values = [p["event"]["state"].get("value") for p in updates]
        report("W2 the frontend sees 10 and never 42", 10 in values and 42 not in values,
               f"values {values}")
        raws = nb.kernel_raws()
        named = [m for m in (m1, m2) if m and any(m in r for r in raws)]
        report("W2 no kernel event names our msg ids", bool(m1) and bool(m2) and not named,
               f"msg ids {m1} {m2}, kernel events name {named}")
    finally:
        nb.close()


W3_SRC = ("import time\nimport ipywidgets as w\ns = w.IntSlider(value=0, max=100)\n"
          "seen = []\ns.observe(lambda c: (seen.append(c['new']), time.sleep(0.4)), 'value')\ns")


def w3():
    nb = Nb([("w3a", W3_SRC), ("w3b", "print(seen)")])
    try:
        nb.run("w3a")
        mid = nb.view_id("w3a")
        msgids = [send(nb.cl, "widget_update",
                       {"session_id": nb.sid, "model_id": mid, "state": {"value": v}})
                  for v in range(1, 6)]
        replies = [reply(nb.cl, m) for m in msgids]
        errs = [e for e, _ in replies if e is not None]
        queued = [(r or {}).get("queued") for _, r in replies]
        report("W3 the five updates are all accepted", not errs, f"errors {errs}")
        report("W3 the first update is sent, the rest wait (queued)",
               queued == [False, True, True, True, True], f"queued {queued}")
        last = poll(nb, "w3b", "[1, 5]")
        report("W3 the kernel sees [1, 5]: the held values merge into one update",
               last == "[1, 5]", f"printed {last!r}")
    finally:
        nb.close()


W3B_SRC = ("import ipywidgets as w\nt = w.IntSlider(max=1000)\ngot = []\n"
           "t.observe(lambda c: got.append(c['new']), 'value')\nt")


def w3b():
    nb = Nb([("t", W3B_SRC), ("tc", "print(got == sorted(got), got[-1], t.value)")])
    try:
        nb.run("t")
        mid = nb.view_id("t")
        msgids = [send(nb.cl, "widget_update",
                       {"session_id": nb.sid, "model_id": mid, "state": {"value": v}})
                  for v in range(1, 201)]
        replies = [reply(nb.cl, m, timeout=20) for m in msgids]
        errs = [e for e, _ in replies if e is not None]
        report("W3b all 200 updates are accepted", not errs, f"{len(errs)} errors, e.g. {errs[:1]}")
        last = poll(nb, "tc", "True 200 200", timeout=20)
        report("W3b the 200 updates reach the kernel in order and end at 200",
               last == "True 200 200", f"printed {last!r}")
        m = nb.model(mid)
        report("W3b widget_state shows value 200",
               m is not None and m["state"].get("value") == 200,
               f"state {m and m['state'].get('value')}")
    finally:
        nb.close()


W4_SRC = ("import ipywidgets as w\nb = w.Button(description='go')\n"
          "b.on_click(lambda _: print('clicked'))\nb")


def w4():
    nb = Nb([("btn", W4_SRC), ("w4f", "1")])
    try:
        nb.run("btn")
        mid = nb.view_id("btn")
        since = nb.mark()
        err, r = nb.cl.call("widget_custom", {"session_id": nb.sid, "model_id": mid,
                                              "content": {"event": "click"}, "cell_id": "btn"})
        report("W4 widget_custom returns a msg id",
               err is None and bool((r or {}).get("msg_id")), f"reply {err} {r}")
        hit = find(nb.cl, lambda e: is_note(e, "cell_event") and note(e)["cell_id"] == "btn"
                   and note(e)["event"].get("kind") == "stream"
                   and note(e)["event"].get("text") == "clicked\n", since, timeout=10)
        report("W4 the click's print lands in the button's cell", hit is not None,
               "no stream 'clicked' for cell btn")
        # A barrier, not a fixed sleep: the kernel runs its requests in order and its
        # iopub is ordered, so the idle of this cell comes after any busy or idle the
        # click's handler sent.
        nb.run("w4f")
        statuses = [p["event"].get("state") for p in nb.cell_events("btn", since)
                    if p["event"].get("kind") == "status"]
        report("W4 no busy or idle reaches the button's cell for the click",
               hit is not None and statuses == [], f"status events {statuses}")
    finally:
        nb.close()


W5_TQDM = ("from tqdm.notebook import tqdm\nimport time\n"
           "for i in tqdm(range(40), desc='work'):\n    time.sleep(0.05)")
W5_AUTO = ("from tqdm.auto import tqdm as ta\nimport time\n"
           "for i in ta(range(20), desc='auto'):\n    time.sleep(0.05)")


def _bars_opened(nb, since):
    return [p["event"]["model_id"] for p in nb.widget_events(since, kind="open")
            if p["event"].get("model_name") == "FloatProgressModel"]


def w5():
    nb = Nb([("tq", W5_TQDM), ("ta", W5_AUTO)])
    try:
        since = nb.mark()
        nb.run("tq", timeout=60)
        bars = _bars_opened(nb, since)
        report("W5 tqdm.notebook opens one FloatProgress", len(bars) == 1, f"bars {bars}")
        if bars:
            fp = bars[0]
            values = {p["event"]["state"].get("value")
                      for p in nb.widget_events(since, kind="update", model_id=fp)
                      if "value" in p["event"]["state"]}
            report("W5 the bar runs live: at least 5 distinct values", len(values) >= 5,
                   f"values {sorted(v for v in values if v is not None)}")
            m = nb.model(fp)
            ok = (m is not None and m["state"].get("value") == 40
                  and m["state"].get("bar_style") == "success")
            report("W5 the bar ends at 40 with bar_style success", ok,
                   f"state {m and {k: m['state'].get(k) for k in ('value', 'bar_style')}}")
        labels = [m for m in nb.models() if m["model_name"] == "HTMLModel"
                  and "40/40" in str(m["state"].get("value", ""))]
        report("W5 a label reads 40/40", bool(labels), "no HTML model with 40/40")

        since = nb.mark()
        nb.run("ta", timeout=60)
        bars = _bars_opened(nb, since)
        report("W5 tqdm.auto opens the notebook bar", len(bars) == 1, f"bars {bars}")
        if bars:
            m = nb.model(bars[0])
            ok = (m is not None and m["state"].get("value") == 20
                  and m["state"].get("bar_style") == "success")
            report("W5 the tqdm.auto bar ends at 20 with bar_style success", ok,
                   f"state {m and {k: m['state'].get(k) for k in ('value', 'bar_style')}}")
    finally:
        nb.close()


def w6():
    nb = Nb([
        ("w6a", "import ipywidgets as w\nfrom IPython.display import display\n"
                "out = w.Output()\ndisplay(out)"),
        ("w6b", "with out:\n    print('inside')\n    display(w.HTML('<b>x</b>'))\nprint('outside')"),
        ("w6c", "print(len(out.outputs))"),
    ])
    try:
        nb.run("w6a")
        oid = nb.view_id("w6a")
        since = nb.mark()
        nb.run("w6b")
        caps = [p["event"]["event"] for p in nb.widget_events(since, kind="output", model_id=oid)]
        has_inside = any(c.get("kind") == "stream" and c.get("text") == "inside\n" for c in caps)
        has_html = any(c.get("kind") == "display_data" for c in caps)
        report("W6 the captured stream and display reach the Output widget",
               has_inside and has_html, f"captured kinds {[c.get('kind') for c in caps]}")
        own = nb.text("w6b", since)
        report("W6 the cell gets only what is outside the with block",
               own == "outside\n" and "inside" not in own, f"cell text {own!r}")
        nb.run("w6c")
        report("W6 the next cell sees the two outputs (the sync back)",
               nb.text("w6c").strip() == "2", f"printed {nb.text('w6c')!r}")
        m = nb.model(oid)
        outs = (m or {}).get("state", {}).get("outputs", [])
        report("W6 widget_state shows the outputs without transient",
               len(outs) == 2 and not any("transient" in o for o in outs),
               f"outputs {len(outs)}, transient in {[o for o in outs if 'transient' in o][:1]}")
    finally:
        nb.close()


def w7():
    # A buffer that arrives over the wire is held by ipywidgets as a memoryview,
    # so the cell reads it through bytes() to compare the content itself.
    nb = Nb([("w7a", "import ipywidgets as w\nim = w.Image(value=b'\\x89PNG-one', format='png')\nim"),
             ("w7b", "print(len(im.value), bytes(im.value))")])
    try:
        since = nb.mark()
        nb.run("w7a")
        mid = nb.view_id("w7a")
        opened = [p for p in nb.widget_events(since, kind="open") if p["event"]["model_id"] == mid]
        got = opened[0] if opened else {}
        ok = (bool(opened) and got["event"].get("buffer_paths") == [["value"]]
              and got.get("buffers") == [b"\x89PNG-one"])
        report("W7 the image bytes arrive as a binary buffer at [value]", ok,
               f"paths {got.get('event', {}).get('buffer_paths')}, buffers {got.get('buffers')}")
        err, _ = nb.update(mid, {}, buffer_paths=[["value"]], buffers=[b"\x89PNG-two!"])
        report("W7 widget_update accepts a binary buffer", err is None, f"error {err}")
        nb.run("w7b")
        want = "9 b'\\x89PNG-two!'"
        report("W7 the kernel reads the new bytes", nb.text("w7b").strip() == want,
               f"printed {nb.text('w7b')!r}")
    finally:
        nb.close()


def w8():
    nb = Nb([
        ("w8a", "from comm import create_comm\nclosed = []\n"
                "c = create_comm(target_name='nope')\nc.on_close(lambda m: closed.append(1))"),
        ("w8b", "print(len(closed))"),
    ])
    try:
        nb.run("w8a")
        nb.run("w8b")
        report("W8 the kernel ran the close callback of the comm it opened",
               nb.text("w8b").strip() == "1", f"printed {nb.text('w8b')!r}")
        report("W8 the unknown comm is not kept as a model", nb.models() == [],
               f"models {[m['model_id'] for m in nb.models()]}")
    finally:
        nb.close()


def w9():
    nb = Nb([("w9a", SLIDER)])
    try:
        nb.run("w9a")
        mid = nb.view_id("w9a")
        since = nb.mark()
        err, _ = nb.cl.call("restart_kernel", {"session_id": nb.sid}, timeout=60)
        report("W9 restart_kernel returns", err is None, f"error {err}")
        resets = find(nb.cl, lambda e: is_note(e, "widget_event")
                      and note(e)["event"].get("kind") == "reset", since, timeout=0)
        report("W9 the frontend hears a reset", resets is not None, "no widget_event reset")
        m = nb.model(mid)
        report("W9 the slider stays in widget_state, no longer live",
               m is not None and m.get("live") is False, f"model {m and m.get('live')}")
        err, _ = nb.update(mid, {"value": 4})
        report("W9 an update to the dead model is refused",
               err is not None and "not connected" in err, f"error {err}")
    finally:
        nb.close()


# ── saved state oracle ──────────────────────────────────────────────────
# Written from the rule, not from widgets.rs: the models a saved notebook
# holds are those reached from the cells' views through IPY_MODEL_ references
# (an Output widget's outputs count), then the links whose two ends are reached.
def model_refs(v, out):
    """Model ids named by IPY_MODEL_ strings anywhere in v."""
    if isinstance(v, str):
        if v.startswith(REF):
            out.append(v[len(REF):])
    elif isinstance(v, list):
        for x in v:
            model_refs(x, out)
    elif isinstance(v, dict):
        for x in v.values():
            model_refs(x, out)
    return out


def view_model(output):
    """The model id of a widget view output, or None."""
    if output.get("output_type") not in ("display_data", "execute_result"):
        return None
    view = (output.get("data") or {}).get(VIEW_MIME)
    return view.get("model_id") if view else None


def link_end(v):
    """The model id of a link end, ["IPY_MODEL_<id>", attr], or None."""
    if isinstance(v, list) and v and isinstance(v[0], str) and v[0].startswith(REF):
        return v[0][len(REF):]
    return None


def reach(models, roots):
    """(model ids reached in reach order, link ids, references naming no model)."""
    by_id = {m["model_id"]: m for m in models}
    seen, order, missing = set(), [], []
    queue = deque()

    def push(mid):
        if mid not in seen:
            seen.add(mid)
            queue.append(mid)

    for r in roots:
        push(r)
    while queue:
        mid = queue.popleft()
        if mid not in by_id:
            missing.append(mid)
            continue
        order.append(mid)
        m = by_id[mid]
        refs = []
        for v in m["state"].values():
            model_refs(v, refs)
        if m["model_name"] == "OutputModel":
            for o in m["state"].get("outputs") or []:
                vm = view_model(o)
                if vm:
                    refs.append(vm)
        for r in refs:
            push(r)
    reached = set(order)
    links = []
    for m in models:
        if m["model_name"] not in LINK_MODELS:
            continue
        src = link_end(m["state"].get("source"))
        dst = link_end(m["state"].get("target"))
        if src in reached and dst in reached:
            links.append(m["model_id"])
    return order, links, missing


def gallery_cells(path):
    """(id, source) of every code cell of a notebook file, in order."""
    with open(path) as f:
        nb = json.load(f)
    out = []
    for c in nb["cells"]:
        if c.get("cell_type") != "code":
            continue
        src = c["source"]
        out.append((c["id"], "".join(src) if isinstance(src, list) else src))
    return out


def gallery_tag(src):
    """The W tag of a gallery cell (the word after '# W:' on its first line), or None."""
    first = src.split("\n", 1)[0]
    return first[len("# W:"):].strip() if first.startswith("# W:") else None


def decoded_buffers(entry):
    """(path, bytes) of every buffer of a saved or live model entry."""
    return [(json.dumps(b["path"]), base64.b64decode(b["data"]))
            for b in entry.get("buffers") or []]


def w10():
    # The slider b is shown; a is only assigned. Saved state holds b, its Layout
    # and its Style, and not a. Reopened with no kernel, the same models are
    # there, all dead, and the notebook metadata carries no widgets block.
    nb = Nb([("w10", "import ipywidgets as w\na = w.IntSlider()\nb = w.IntSlider(value=4)\nb")])
    try:
        nb.run("w10")
        shown = nb.view_id("w10")
        models = nb.models()
        expected = set()
        if shown is not None:
            order, links, _ = reach(models, [shown])
            expected = set(order) | set(links)
        others = {m["model_id"] for m in models} - expected
        report("W10 the shown slider reaches its layout and style",
               shown is not None and len(expected) == 3, f"reached {sorted(expected)}")

        err, _ = nb.cl.call("save", {"session_id": nb.sid})
        report("W10 save returns ok", err is None, f"error {err}")
        with open(nb.path) as f:
            saved = json.load(f)
        block = ((saved.get("metadata") or {}).get("widgets") or {}).get(STATE_MIME) or {}
        state = block.get("state") or {}
        report("W10 the saved state is the shown slider and what it reaches",
               set(state) == expected, f"saved {sorted(state)}, expected {sorted(expected)}")
        report("W10 the slider nothing shows is not saved", not (set(state) & others),
               f"saved unshown models {sorted(set(state) & others)}")
        report("W10 the saved slider keeps its value",
               state.get(shown, {}).get("state", {}).get("value") == 4,
               f"value {state.get(shown, {}).get('state', {}).get('value')}")

        nb.cl.call("stop_kernel", {"session_id": nb.sid}, timeout=15)
        reopen = Client()
        try:
            err, res = reopen.call("open", {"path": nb.path}, timeout=30)
            snap = (res or {}).get("snapshot") or {}
            widgets = snap.get("widgets") or []
            got = {m["model_id"] for m in widgets}
            report("W10 reopened with no kernel: the saved models are listed",
                   err is None and bool(expected) and got == expected,
                   f"error {err}, listed {sorted(got)}, expected {sorted(expected)}")
            report("W10 reopened with no kernel: every model is dead",
                   bool(widgets) and all(m["live"] is False for m in widgets),
                   f"live {[m['live'] for m in widgets]}")
            report("W10 reopened: the snapshot metadata has no widgets block",
                   "widgets" not in (snap.get("metadata") or {}),
                   f"metadata keys {sorted((snap.get('metadata') or {}).keys())}")
        finally:
            reopen.stop()
    finally:
        nb.close()


def w11():
    # The gallery, run cell by cell (except the ipympl cell, which needs ipympl).
    # Every tagged cell shows a view. Saved state is what the views reach, with
    # the links between them; each saved model equals its live state (buffers
    # compared as bytes); reopened with no kernel the same ids are all dead.
    nb = Nb(copy_of=GALLERY)
    try:
        cells = gallery_cells(GALLERY)
        errors, no_view, views = [], [], []
        for cid, src in cells:
            tag = gallery_tag(src)
            if tag == "ipympl":
                continue
            since = nb.mark()
            try:
                nb.run(cid, timeout=120)
            except RuntimeError as e:
                errors.append(str(e))
                continue
            failed = [p["event"].get("ename") for p in nb.cell_events(cid, since)
                      if p["event"].get("kind") == "error"]
            if failed:
                errors.append(f"{cid} raised {failed}")
            view = nb.view_id(cid, since)
            if view is not None:
                views.append(view)
            if tag not in (None, "setup", "end") and view is None:
                no_view.append(cid)
        report("W11 every gallery cell except ipympl runs without an error",
               not errors, "; ".join(errors[:5]))
        report("W11 every tagged cell made a view", not no_view, f"no view in {no_view}")

        live = nb.models()
        live_ids = {m["model_id"] for m in live}
        report("W11 every view names a live model", all(v in live_ids for v in views),
               f"views without a model {[v for v in views if v not in live_ids][:5]}")

        err, _ = nb.cl.call("save", {"session_id": nb.sid}, timeout=30)
        report("W11 save returns ok", err is None, f"error {err}")
        with open(nb.path) as f:
            saved = json.load(f)
        block = ((saved.get("metadata") or {}).get("widgets") or {}).get(STATE_MIME) or {}
        state = block.get("state") or {}
        roots = [view_model(o) for c in saved["cells"] for o in c.get("outputs") or []]
        roots = [r for r in roots if r]
        order, links, missing = reach(live, roots)
        expected = set(order) | set(links)
        report("W11 every reference of a view exists in widget_state", not missing,
               f"missing {missing[:5]}")
        report("W11 the saved state is the reachable models plus their links",
               bool(expected) and set(state) == expected,
               f"only saved {sorted(set(state) - expected)[:5]}, "
               f"only reachable {sorted(expected - set(state))[:5]}")

        live_by_id = {m["model_id"]: m for m in live}
        differ = []
        for mid in sorted(expected):
            entry, want = state.get(mid), live_by_id.get(mid)
            if entry is None:
                differ.append(f"{mid} is not saved")
                continue
            if want is None:
                differ.append(f"{mid} has no live model")
                continue
            if entry.get("model_name") != want["model_name"]:
                differ.append(f"{mid} model_name")
            if entry.get("state") != want["state"]:
                differ.append(f"{mid} state")
            if decoded_buffers(entry) != decoded_buffers(want):
                differ.append(f"{mid} buffers")
        report("W11 each saved state equals its live state (buffers as bytes)",
               bool(expected) and not differ, "; ".join(differ[:5]))

        err, _ = nb.cl.call("stop_kernel", {"session_id": nb.sid}, timeout=60)
        reopen = Client()
        try:
            err, res = reopen.call("open", {"path": nb.path}, timeout=30)
            widgets = ((res or {}).get("snapshot") or {}).get("widgets") or []
            got = {m["model_id"] for m in widgets}
            report("W11 reopened with no kernel: the same ids",
                   err is None and bool(expected) and got == expected,
                   f"error {err}, only listed {sorted(got - expected)[:5]}, "
                   f"only reachable {sorted(expected - got)[:5]}")
            report("W11 reopened with no kernel: every model is dead",
                   bool(widgets) and all(m["live"] is False for m in widgets),
                   f"live {sum(1 for m in widgets if m['live'])} of {len(widgets)}")
        finally:
            reopen.stop()
    finally:
        nb.close()


def w12():
    # A callback updates a display handle (dh.update). The update goes to the
    # cell that holds the display, as in the classic notebook: the callback's
    # cell is the one that shows the widget, and the display is in its own cell.
    nb = Nb([
        ("dh", "from IPython.display import display\ndh = display('initial', display_id=True)"),
        ("btn", "import ipywidgets as w\nb = w.Button(description='go')\n"
                "b.on_click(lambda _: (print('clicked'), dh.update('updated by click')))\nb"),
    ])
    try:
        nb.run("dh")
        nb.run("btn")
        mid = nb.view_id("btn")
        since = nb.mark()
        err, _ = nb.cl.call("widget_custom", {"session_id": nb.sid, "model_id": mid,
                                              "content": {"event": "click"}, "cell_id": "btn"})
        report("W12 the click is sent", err is None, f"error {err}")
        find(nb.cl, lambda e: is_note(e, "cell_event") and note(e)["cell_id"] == "btn"
             and note(e)["event"].get("kind") == "stream", since, timeout=10)
        updates = [note(e)["event"] for e in nb.cl.events[since:]
                   if is_note(e, "cell_event")
                   and note(e)["event"].get("kind") == "update_display_data"]
        report("W12 the display update reaches the frontend for the dh cell",
               any("dh" in u.get("cells", []) for u in updates),
               f"update events {[u.get('cells') for u in updates]}")
        err, snap = nb.cl.call("snapshot", {"session_id": nb.sid})
        dh = next((c for c in (snap or {}).get("cells", []) if c["id"] == "dh"), {})
        shown = [o.get("data", {}).get("text/plain") for o in dh.get("outputs", [])]
        # text/plain is the repr of the value (quotes included), so match the text
        report("W12 the dh cell shows the updated text",
               len(shown) == 1 and "updated by click" in (shown[0] or ""),
               f"error {err}, shows {shown}")
    finally:
        nb.close()


def w13():
    # A saved block this version cannot read (a version 3 block, and the Colab
    # shape, which has no version_major) is replaced by the state the views
    # reach on the first save. Once the outputs are cleared nothing is reachable,
    # so the next save writes the block the file had, never the earlier export.
    shapes = {
        "version 3": {STATE_MIME: {"version_major": 3, "version_minor": 0,
                                   "state": {"old": {"future": True}}}},
        "colab": {STATE_MIME: {"old": {"model_name": "IntSliderModel",
                                       "model_module": "@jupyter-widgets/controls",
                                       "state": {"value": 1}}}},
    }
    for label, widgets in shapes.items():
        src = tmp_nb()
        try:
            with open(src, "w") as f:
                json.dump({
                    "cells": [{"cell_type": "code", "id": "w", "metadata": {},
                               "source": SLIDER, "execution_count": None, "outputs": []}],
                    "metadata": {"kernelspec": KERNELSPEC, "widgets": widgets},
                    "nbformat": 4, "nbformat_minor": 5,
                }, f)
            nb = Nb(copy_of=src)
            try:
                nb.run("w")
                shown = nb.view_id("w")
                err, _ = nb.cl.call("save", {"session_id": nb.sid}, timeout=30)
                with open(nb.path) as f:
                    first = (json.load(f).get("metadata") or {}).get("widgets") or {}
                block = first.get(STATE_MIME) or {}
                report(f"W13 {label}: the first save writes the shown slider",
                       err is None and shown is not None and block.get("version_major") == 2
                       and shown in (block.get("state") or {}),
                       f"error {err}, shown {shown}, block {sorted(block)}")

                err, _ = nb.cl.call("clear_outputs", {"session_id": nb.sid})
                err2, _ = nb.cl.call("save", {"session_id": nb.sid}, timeout=30)
                with open(nb.path) as f:
                    after = (json.load(f).get("metadata") or {}).get("widgets")
                report(f"W13 {label}: with no view left the original block is written back",
                       err is None and err2 is None and after == widgets,
                       f"errors {err}, {err2}; written {json.dumps(after)[:200]}")
            finally:
                nb.close()
        finally:
            if os.path.exists(src):
                os.unlink(src)


W14_SETUP = ("import ipywidgets as w\nfrom IPython.display import display\n"
             "out = w.Output()\nn = []\nout.observe(lambda c: n.append(1), 'outputs')\n"
             "display(out)")
W14_PRINT = ("import time\nwith out:\n    t0 = time.time()\n    while time.time() - t0 < 3:\n"
             "        print('tick')\n        time.sleep(0.05)")


def w14():
    # A cell that prints inside `with out:` for 3 s keeps the kernel busy, so the
    # outputs the core flushes to it wait behind the cell. Only one flush is in
    # flight per Output widget: the observer runs for the first flush and for the
    # captures made meanwhile, not once per flush interval.
    nb = Nb([("w14a", W14_SETUP), ("w14b", W14_PRINT), ("w14c", "print(len(n))")])
    try:
        nb.run("w14a")
        nb.run("w14b")
        nb.run("w14c")
        text = nb.text("w14c").strip()
        count = int(text) if text.isdigit() else -1
        report("W14 the outputs reach the kernel in one or two updates while the cell runs",
               1 <= count <= 2, f"the observer ran {text!r} times")
    finally:
        nb.close()


W15_SRC = ("import ipywidgets as w\nfrom ipywidgets import interact\n"
           "def show(x):\n    print('value', x)\n"
           "interact(show, x=w.IntSlider(value=5, min=0, max=10))")


def w15():
    # interact runs its callback inside `with out:` on the update's msg_id, so the
    # callback's print belongs to interact's Output widget, not to the cell that
    # shows the widget.
    nb = Nb([("w15a", W15_SRC)])
    try:
        nb.run("w15a")
        models = nb.models()
        sliders = [m for m in models if m["model_name"] == "IntSliderModel"
                   and m["state"].get("value") == 5]
        outs = [m for m in models if m["model_name"] == "OutputModel"
                and "value 5" in json.dumps(m["state"].get("outputs", []))]
        ready = len(sliders) == 1 and len(outs) == 1
        report("W15 interact shows its slider and an Output widget holding 'value 5'",
               ready, f"sliders {len(sliders)}, outputs {len(outs)}")
        if not ready:
            return
        sid, oid = sliders[0]["model_id"], outs[0]["model_id"]
        since = nb.mark()
        err, r = nb.update(sid, {"value": 7}, cell_id="w15a")
        report("W15 the slider update is accepted", err is None and bool(r), f"reply {err} {r}")
        deadline = time.time() + 10
        seen = False
        while time.time() < deadline and not seen:
            seen = any(p["event"]["event"].get("kind") == "stream"
                       and p["event"]["event"].get("text") == "value 7\n"
                       for p in nb.widget_events(since, kind="output", model_id=oid))
            if not seen:
                time.sleep(0.1)
        report("W15 the callback's print reaches interact's Output widget", seen)
        report("W15 the callback's print does not reach the cell",
               "value 7" not in nb.text("w15a", since), f"cell text {nb.text('w15a', since)!r}")
        out_model = nb.model(oid) or {}
        texts = json.dumps(out_model.get("state", {}).get("outputs", []))
        report("W15 the Output widget's state holds only the new print",
               "value 7" in texts and "value 5" not in texts, f"outputs {texts[:200]}")
    finally:
        nb.close()


# The task sets a Label to 'done' at its end. The test reads that from the widget state
# (a kernel-side update, and a read that is no request): a poll that ran a cell would be
# an execute request, which sends the waiting captures first and so adds flushes.
W16_TASK = ("import asyncio, time\nimport ipywidgets as w\nstatus = w.Label(value='running')\n"
            "async def work():\n"
            "    t0 = time.time()\n"
            "    while time.time() - t0 < 3:\n"
            "        with out:\n"
            "            print('x' * 1000)\n"
            "        await asyncio.sleep(0.002)\n"
            "    status.value = 'done'\n"
            "task = asyncio.ensure_future(work())")


def w16():
    # A task started by a cell opens `with out:` once per loop iteration. The kernel is
    # free between the awaits, so every capture end would be a flush: the cadence (one
    # flush per 500 ms while the kernel is free) holds, so the observer of 'outputs'
    # runs about six times for the 3 s of printing, not once per block.
    nb = Nb([("w16a", W14_SETUP), ("w16b", W16_TASK), ("w16c", "print(len(n))")])
    try:
        nb.run("w16a")
        nb.run("w16b")
        # The task prints for 3 s and then sets its Label to 'done'. The state is polled,
        # with a deadline, rather than waited for by a fixed sleep.
        lid = next((m["model_id"] for m in nb.models()
                    if m["model_name"] == "LabelModel" and m["state"].get("value") == "running"), None)
        deadline = time.time() + 20
        done = None
        while time.time() < deadline:
            done = ((nb.model(lid) or {}).get("state", {}) or {}).get("value") if lid else None
            if done == "done":
                break
            time.sleep(0.1)
        nb.run("w16c")
        text = nb.text("w16c").strip()
        count = int(text) if text.isdigit() else -1
        report("W16 a free kernel's per-iteration captures flush at most every 500 ms",
               2 <= count <= 8, f"the observer ran {text!r} times, the task done {done!r}")
    finally:
        nb.close()


W6_SETUP = ("import ipywidgets as w\nfrom IPython.display import display\n"
            "out = w.Output()\ndisplay(out)")
READ_OUT = "print(repr(''.join(o.get('text', '') for o in out.outputs)))"


def w17():
    # Two `with out:` cells run one after the other, and a cell then reads the Output
    # widget's outputs. The second capture ends within 500 ms of the first flush, so
    # the core holds it for the cadence; the reading cell must still see both, because
    # the core sends the captures still waiting before it asks the kernel to run it.
    nb = Nb([("w17a", W6_SETUP), ("w17b", "with out:\n    print('a')"),
             ("w17c", "with out:\n    print('b')"), ("w17d", READ_OUT)])
    try:
        for cid in ("w17a", "w17b", "w17c", "w17d"):
            nb.run(cid)
        got = nb.text("w17d").strip()
        report("W17 a cell run after two `with out:` cells reads both captures",
               got == repr("a\nb\n"), f"printed {got!r}")
    finally:
        nb.close()


def w18():
    # A capture still waiting for the cadence must not be lost when a later cell
    # appends to the same widget: the append builds the new outputs from the kernel's
    # copy, so the captured 'a' has to reach the kernel before that cell runs.
    nb = Nb([("w18a", W6_SETUP), ("w18b", "with out:\n    print('z')"),
             ("w18c", "with out:\n    print('a')"), ("w18d", "out.append_stdout('b\\n')"),
             ("w18e", READ_OUT)])
    try:
        nb.run("w18a")
        oid = nb.view_id("w18a")
        for cid in ("w18b", "w18c", "w18d", "w18e"):
            nb.run(cid)
        got = nb.text("w18e").strip()
        report("W18 an append after a captured output keeps every output in the kernel",
               got == repr("z\na\nb\n"), f"printed {got!r}")
        store = wait_store(nb, oid, "z\na\nb\n")
        report("W18 the store keeps every output once the kernel is quiet",
               store == "z\na\nb\n", f"store {store!r}")
    finally:
        nb.close()


W19_SETUP = ("import ipywidgets as w\nfrom IPython.display import display\nimport time\n"
             "out = w.Output()\nts = []\nout.observe(lambda c: ts.append(time.time()), 'outputs')\n"
             "display(out)")
W19_A = "import time\nwith out:\n    print('a')\n    time.sleep(0.45)"
W19_B = "with out:\n    print('b')"
W19_GAPS = "print(len(ts), min([q - p for p, q in zip(ts, ts[1:])] or [0]))"


def w19():
    # A cell prints inside `with out:` and keeps the capture open for 0.45 s; the next
    # cell prints inside `with out:` right after it. Every outputs flush the kernel
    # receives runs the observer once. The flushes of the two cells keep the cadence:
    # the smallest gap between two of them is at least 0.45 s.
    nb = Nb([("w19a", W19_SETUP), ("w19b", W19_A), ("w19c", W19_B), ("w19d", W19_GAPS)])
    try:
        for cid in ("w19a", "w19b", "w19c"):
            nb.run(cid)
        time.sleep(1.5)  # the kernel is free: the cadence timer has fired by now
        nb.run("w19d")
        parts = nb.text("w19d").split()
        count = int(parts[0]) if parts and parts[0].isdigit() else -1
        gap = float(parts[1]) if len(parts) > 1 else 0.0
        report("W19 the flushes of two cells are at least 0.45 s apart",
               count >= 2 and gap >= 0.45, f"observer runs {count}, smallest gap {gap:.3f} s")
    finally:
        nb.close()


W20_SETUP = ("import ipywidgets as w\nfrom IPython.display import display\nout = w.Output()\n"
             "btn = w.Button(description='go')\n"
             "btn.on_click(lambda b: out.append_stdout('b\\n'))\n"
             "display(out)\ndisplay(btn)")
W21_SETUP = ("import ipywidgets as w\nfrom IPython.display import display\nout = w.Output()\n"
             "s = w.IntSlider(max=100)\n"
             "s.observe(lambda c: out.append_stdout('v%d\\n' % c['new']), 'value')\n"
             "display(out)\ndisplay(s)")


def store_text(nb, model_id):
    m = nb.model(model_id) or {}
    return "".join(o.get("text", "") for o in m.get("state", {}).get("outputs", []))


def wait_store(nb, model_id, expected, timeout=5):
    """The store's text of an Output widget, once it is `expected` or the deadline
    has passed. The captures the core still holds for the cadence reach the store on
    their timer, so the store is polled with a deadline, not read after a sleep."""
    deadline = time.time() + timeout
    text = store_text(nb, model_id)
    while text != expected and time.time() < deadline:
        time.sleep(0.1)
        text = store_text(nb, model_id)
    return text


def w20():
    # A `with out:` cell ends inside the cadence, so its capture still waits in the
    # core. A click then runs a handler that appends to the same widget: the append
    # builds on the kernel's copy, so the waiting capture has to reach the kernel
    # before the click does, or it is lost for good.
    nb = Nb([("w20a", W20_SETUP), ("w20b", "with out:\n    print('z')"),
             ("w20c", "with out:\n    print('a')"), ("w20d", READ_OUT)])
    try:
        nb.run("w20a")
        oid, bid = nb.view_ids("w20a")[:2]
        nb.run("w20b")
        nb.run("w20c")
        err, _ = nb.cl.call("widget_custom", {"session_id": nb.sid, "model_id": bid,
                                              "content": {"event": "click"}, "cell_id": "w20a"})
        nb.run("w20d")
        got = nb.text("w20d").strip()
        report("W20 a click right after a `with out:` cell keeps every output in the kernel",
               err is None and got == repr("z\na\nb\n"), f"error {err}, printed {got!r}")
        store = wait_store(nb, oid, "z\na\nb\n")
        report("W20 the store keeps every output after the click", store == "z\na\nb\n",
               f"store {store!r}")
    finally:
        nb.close()


def w21():
    # The same with a slider update whose observer appends to the Output widget.
    nb = Nb([("w21a", W21_SETUP), ("w21b", "with out:\n    print('z')"),
             ("w21c", "with out:\n    print('a')"), ("w21d", READ_OUT)])
    try:
        nb.run("w21a")
        oid, sid = nb.view_ids("w21a")[:2]
        nb.run("w21b")
        nb.run("w21c")
        err, _ = nb.update(sid, {"value": 5}, cell_id="w21a")
        nb.run("w21d")
        got = nb.text("w21d").strip()
        report("W21 a slider update right after a `with out:` cell keeps every output in the kernel",
               err is None and got == repr("z\na\nv5\n"), f"error {err}, printed {got!r}")
        store = wait_store(nb, oid, "z\na\nv5\n")
        report("W21 the store keeps every output after the update", store == "z\na\nv5\n",
               f"store {store!r}")
    finally:
        nb.close()


W22_SETUP = ("import ipywidgets as w\nfrom IPython.display import display\n"
             "im = w.Image(value=b'\\x89PNG-one', format='png')\ns = w.IntSlider()\n"
             "display(im)\ndisplay(s)")


def w22():
    # A comm message or close from the kernel ends in the widget step: the frontend
    # hears it as a widget_event, and no kernel_event carries its Debug text (with
    # the buffer's bytes for an update).
    nb = Nb([("w22a", W22_SETUP), ("w22b", "im.value = b'\\x89PNG-two!'"), ("w22c", "s.close()")])
    try:
        nb.run("w22a")
        iid, sid = nb.view_ids("w22a")[:2]
        since = nb.mark()
        nb.run("w22b")
        ups = [p for p in nb.widget_events(since, kind="update", model_id=iid)
               if p["event"].get("buffer_paths") == [["value"]]]
        report("W22 a kernel-side buffer update reaches the frontend with its bytes",
               bool(ups) and ups[-1].get("buffers") == [b"\x89PNG-two!"],
               f"updates {[(p['event'].get('buffer_paths'), p.get('buffers')) for p in ups]}")
        nb.run("w22c")
        closed = nb.widget_events(since, kind="close", model_id=sid)
        report("W22 a kernel-side close reaches the frontend and leaves the store",
               bool(closed) and nb.model(sid) is None,
               f"close events {len(closed)}, still stored {nb.model(sid) is not None}")
        leaked = [r for r in nb.kernel_raws(since) if "Comm" in r]
        report("W22 no kernel event names a comm after a kernel-side update and close",
               not leaked, f"leaked {leaked[:2]}")
    finally:
        nb.close()


def slider_id(nb, description):
    """The model id of the IntSlider with this description, from the store."""
    for m in nb.models():
        if m["model_name"] == "IntSliderModel" and m["state"].get("description") == description:
            return m["model_id"]
    return None


# Two sliders, a = 1 and b = 5, and a link between their values; the link's class is
# the kind: jslink (LinkModel, both ways) or jsdlink (DirectionalLinkModel).
LINK_SETUP = ("import ipywidgets as w\nfrom IPython.display import display\n"
              "a = w.IntSlider(value=1, max=10, description='a')\n"
              "b = w.IntSlider(value=5, max=10, description='b')\n"
              "link = w.LINKKIND((a, 'value'), (b, 'value'))\n"
              "display(w.HBox([a, b]))")


def link_setup(kind):
    return LINK_SETUP.replace("LINKKIND", kind)


def w23():
    # jslink((a, 'value'), (b, 'value')): the link sets b to a's value when it opens
    # (the kernel's b.value is 1), a change of a in the kernel moves b in the kernel and
    # in the store, and a change of b from the frontend moves a back.
    nb = Nb([("l23a", link_setup("jslink")), ("l23b", "print(b.value)"),
             ("l23c", "a.value = 7"), ("l23d", "print(b.value)"), ("l23e", "print(a.value)")])
    try:
        nb.run("l23a")
        bid = slider_id(nb, "b")
        nb.run("l23b")
        got = nb.text("l23b").strip()
        report("W23 jslink sets b to a's value when it opens: b.value prints 1",
               got == "1", f"printed {got!r}")
        since = nb.mark()
        nb.run("l23c")
        nb.run("l23d")
        got = nb.text("l23d").strip()
        report("W23 a change of a in the kernel moves b in the kernel: b.value prints 7",
               got == "7", f"printed {got!r}")
        told = nb.widget_events(since, kind="update", model_id=bid)
        report("W23 the frontend is told of b's new value 7",
               any(p["event"].get("state", {}).get("value") == 7 for p in told),
               f"updates of b {[p['event'].get('state') for p in told]}")
        b_store = (nb.model(bid) or {}).get("state", {}).get("value")
        report("W23 the store holds b at 7", b_store == 7, f"store b {b_store!r}")
        err, _ = nb.update(bid, {"value": 4})
        nb.run("l23e")
        got = nb.text("l23e").strip()
        report("W23 a change of b from the frontend moves a back (jslink copies both ways)",
               err is None and got == "4", f"error {err}, a prints {got!r}")
    finally:
        nb.close()


def w11b():
    # The saved gallery with two link models, opened and given a kernel with no cell run.
    # A kernel start keeps the links between shown widgets (dead), so a save writes the
    # same link models with the same ends as the file holds.
    fixture = os.path.join(HERE, "fixtures", "widgets_gallery_saved.ipynb")
    with open(fixture) as f:
        file_state = json.load(f)["metadata"]["widgets"][STATE_MIME]["state"]
    file_links = {mid: e for mid, e in file_state.items() if e.get("model_name") in LINK_MODELS}
    nb = Nb(copy_of=fixture)
    try:
        report("W11b the fixture holds two link models", len(file_links) == 2,
               f"links {sorted(file_links)}")
        err, _ = nb.cl.call("save", {"session_id": nb.sid}, timeout=30)
        report("W11b save returns ok", err is None, f"error {err}")
        with open(nb.path) as f:
            saved = json.load(f)
        state = ((saved.get("metadata") or {}).get("widgets") or {}).get(STATE_MIME, {}).get("state") or {}
        saved_links = {mid: e for mid, e in state.items() if e.get("model_name") in LINK_MODELS}
        report("W11b the save keeps the file's two link models",
               set(saved_links) == set(file_links),
               f"saved links {sorted(saved_links)}, file links {sorted(file_links)}")
        differ = [mid for mid in file_links
                  if saved_links.get(mid, {}).get("state") != file_links[mid].get("state")]
        report("W11b each saved link keeps its state and ends", not differ,
               f"differ {differ[:3]}")
    finally:
        nb.close()


# jslink with b's observer added after the link opened: the copy of a's change is what
# runs the observer, so its print comes from the copy's message.
W23C_SETUP = ("import ipywidgets as w\nfrom IPython.display import display\n"
              "a = w.IntSlider(value=1, max=10, description='a')\n"
              "b = w.IntSlider(value=5, max=10, description='b')\n"
              "link = w.jslink((a, 'value'), (b, 'value'))\n"
              "display(w.HBox([a, b]))")


def w23c():
    # A change of a in a cell reaches b through the link, and b's observer prints. The
    # print belongs to the cell that shows b (the rule for a callback's output), not to
    # the cell that made the change, and not to nowhere.
    nb = Nb([("c23a", W23C_SETUP),
             ("c23b", "b.observe(lambda c: print('b is', c.new), 'value')"),
             ("c23c", "a.value = 7")])
    try:
        nb.run("c23a")
        nb.run("c23b")
        since = nb.mark()
        nb.run("c23c")
        hit = find(nb.cl, lambda e: is_note(e, "cell_event") and note(e)["cell_id"] == "c23a"
                   and note(e)["event"].get("kind") == "stream"
                   and note(e)["event"].get("text") == "b is 7\n", since, timeout=10)
        report("W23c the observer of b prints in the cell that shows b", hit is not None,
               f"cell c23a text {nb.text('c23a', since)!r}")
        report("W23c the print is not in the cell that made the change",
               "b is" not in nb.text("c23c", since), f"cell c23c text {nb.text('c23c', since)!r}")
    finally:
        nb.close()


# a shown alone in one cell, b inside a box in another, and a jslink between them.
W23D_SETUP = ("import ipywidgets as w\nfrom IPython.display import display\n"
              "a = w.IntSlider(value=1, max=10, description='a')\n"
              "b = w.IntSlider(value=5, max=10, description='b')\n"
              "link = w.jslink((a, 'value'), (b, 'value'))\n"
              "display(a)")


def w23d():
    # A frontend change of a, sent with a's cell: a's own observer prints in that cell,
    # and the link's copy to b runs b's observer, whose print belongs to the cell that
    # shows b, as for a copy the kernel's change makes (W23c), not to a's cell.
    nb = Nb([("d23a", W23D_SETUP), ("d23b", "display(w.HBox([b]))"),
             ("d23c", "a.observe(lambda c: print('a is', c.new), 'value')\n"
                      "b.observe(lambda c: print('b is', c.new), 'value')")])
    try:
        nb.run("d23a")
        nb.run("d23b")
        nb.run("d23c")
        aid = slider_id(nb, "a")
        since = nb.mark()
        err, _ = nb.update(aid, {"value": 7}, cell_id="d23a")
        report("W23d the frontend change of a is sent", err is None, f"error {err}")

        def printed(cell, text):
            return find(nb.cl, lambda e: is_note(e, "cell_event") and note(e)["cell_id"] == cell
                        and note(e)["event"].get("kind") == "stream"
                        and note(e)["event"].get("text") == text, since, timeout=10)
        report("W23d a's observer prints in a's cell", printed("d23a", "a is 7\n") is not None,
               f"cell d23a text {nb.text('d23a', since)!r}")
        report("W23d b's observer prints in the cell that shows b",
               printed("d23b", "b is 7\n") is not None, f"cell d23b text {nb.text('d23b', since)!r}")
        report("W23d b's print is not in a's cell", "b is" not in nb.text("d23a", since),
               f"cell d23a text {nb.text('d23a', since)!r}")
    finally:
        nb.close()


def w4b():
    # widget_custom with no cell_id, as W.custom sends before the button's cell has been
    # drawn: the click's print still lands in the cell that shows the button.
    nb = Nb([("btn", W4_SRC)])
    try:
        nb.run("btn")
        mid = nb.view_id("btn")
        since = nb.mark()
        err, r = nb.cl.call("widget_custom", {"session_id": nb.sid, "model_id": mid,
                                              "content": {"event": "click"}})
        report("W4b widget_custom with no cell returns a msg id",
               err is None and bool((r or {}).get("msg_id")), f"reply {err} {r}")
        hit = find(nb.cl, lambda e: is_note(e, "cell_event") and note(e)["cell_id"] == "btn"
                   and note(e)["event"].get("kind") == "stream"
                   and note(e)["event"].get("text") == "clicked\n", since, timeout=10)
        report("W4b the click's print lands in the button's cell", hit is not None,
               f"cell btn text {nb.text('btn', since)!r}")
    finally:
        nb.close()


def w23b():
    # jsdlink (DirectionalLinkModel): b follows a, and b never moves a. A change of b
    # from the frontend or in the kernel stays on b.
    nb = Nb([("l23a", link_setup("jsdlink")), ("l23b", "print(b.value)"),
             ("l23c", "a.value = 7"), ("l23d", "print(b.value)"), ("l23e", "print(a.value)"),
             ("l23f", "print(b.value)"), ("l23g", "b.value = 3"), ("l23h", "print(a.value)")])
    try:
        nb.run("l23a")
        bid = slider_id(nb, "b")
        nb.run("l23b")
        got = nb.text("l23b").strip()
        report("W23b jsdlink sets b to a's value when it opens: b.value prints 1",
               got == "1", f"printed {got!r}")
        nb.run("l23c")
        nb.run("l23d")
        got = nb.text("l23d").strip()
        report("W23b a change of a moves b: b.value prints 7", got == "7", f"printed {got!r}")
        err, _ = nb.update(bid, {"value": 4})
        nb.run("l23e")
        got = nb.text("l23e").strip()
        report("W23b a frontend change of b does not reach a: a.value prints 7",
               err is None and got == "7", f"error {err}, a prints {got!r}")
        nb.run("l23f")
        got = nb.text("l23f").strip()
        report("W23b the frontend change of b reaches b in the kernel: b.value prints 4",
               got == "4", f"b prints {got!r}")
        nb.run("l23g")
        nb.run("l23h")
        got = nb.text("l23h").strip()
        report("W23b a kernel change of b does not reach a: a.value prints 7",
               got == "7", f"a prints {got!r}")
    finally:
        nb.close()


CASES = [("W1", w1), ("W2", w2), ("W3", w3), ("W3b", w3b), ("W4", w4), ("W5", w5),
         ("W6", w6), ("W7", w7), ("W8", w8), ("W9", w9), ("W10", w10), ("W11", w11),
         ("W12", w12), ("W13", w13), ("W14", w14), ("W15", w15), ("W16", w16),
         ("W17", w17), ("W18", w18), ("W19", w19), ("W20", w20), ("W21", w21),
         ("W22", w22), ("W23", w23), ("W23b", w23b), ("W23c", w23c), ("W23d", w23d),
         ("W4b", w4b), ("W11b", w11b)]

def w_echo_off():
    # The kernel must really run with echo off, or the cases below prove nothing.
    nb = Nb([("eo", "import ipywidgets.widgets.widget as wj\nprint(wj.JUPYTER_WIDGETS_ECHO)")])
    try:
        nb.run("eo")
        got = nb.text("eo").strip()
        report("the kernel runs with JUPYTER_WIDGETS_ECHO=0", got == "False", f"printed {got!r}")
    finally:
        nb.close()


# The same cases with JUPYTER_WIDGETS_ECHO=0 (no echo_update from the kernel):
# the clamp and the one-in-flight throttle must hold without echoes too.
ECHO_OFF_CASES = [("kernel echo flag", w_echo_off), ("W2", w2), ("W3", w3)]


def run_case(label, case):
    try:
        case()
    except Exception as e:
        report(f"{label} crashed", False, f"crash: {e!r}")


if __name__ == "__main__":
    print(f"widget protocol tests ({len(CASES)} cases, plus {len(ECHO_OFF_CASES)} with echo off)")
    for label, case in CASES:
        run_case(label, case)
    PREFIX = "echo off: "
    with echo_off():
        for label, case in ECHO_OFF_CASES:
            run_case(label, case)
    print(f"\nwidget protocol: {PASS}/{PASS+FAIL} passed")
    sys.exit(0 if FAIL == 0 else 1)
