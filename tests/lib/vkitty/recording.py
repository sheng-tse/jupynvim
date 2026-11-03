"""A recording of one terminal session: the bytes a child wrote and read, the media it named and
the answers it got, as the relay (relay.py) saw them. The layout is:

    rec/
      tui.bin       bytes read from the child's terminal (the pty), in order
      gfx.bin       bytes of the graphics FIFO (only with --gfx-fifo), in order
      blobs/NNNNNN.bin  the bytes of a file or shared memory object the tap read
      events.jsonl  one JSON object per line, in arrival order (start, data, resize, reattach,
                    blob, resp, mark, error, end)
      live_final.json  the report of the live terminal at the end (only with --respond ghostty);
                    the live terminal (live.py, its own process) writes it before the relay
                    closes the recording
      done          written last, atomically: the word "done" and a newline

The start event holds the metadata of the run, and with --respond ghostty the pid of the live
terminal's worker as live_pid. It is flushed at once, so it is on disk before the child runs.

With a live terminal the resp events come when its answers reach the relay, so a resp event can
follow later data events than the query it answers (and its t can be later than the end event's
t). A mark is written after every answer that comes before it, and the end after the last one
(the relay waits for the live terminal at a mark and at the end). An answer that arrives after the
child exited is recorded and not delivered; a failure of the live terminal is an error event with
where "live", after which the recording has no live_final.json.

RecordingWriter writes it. Recording reads it back and replays it into a vt.Terminal: a data
event is fed on its channel with its arrival time, a resize calls Terminal.resize, a reattach
calls Terminal.reattach (a new outer terminal: empty graphics storage), a blob is the media the
terminal asks for (RecordedMedia), and a resp event is the answer the child got. A mark
names a point in the events; a mark used more than once resolves to its last occurrence.

Ported behaviour, the reasons are in the modules that use this one: the relay drains the child's
output before it records a mark or a resize, so every byte before the event is before it in the
recording; a mark taken inside a synchronized update (DECSET 2026) shows the screen at the byte
where that update ends (the replay feeds the data that ends it byte by byte, see _run), as the
screen shows the finished update.
"""
import base64
import json
import os
import time

DONE_TEXT = "done\n"
FLUSH_SECONDS = 0.5
_FLUSH_AT_ONCE = ("start", "mark", "resize", "reattach", "error", "end")


class RecordingWriter:
    """Writes one recording folder. Data files are unbuffered, so a reader sees each chunk as
    soon as its write returned. events.jsonl is flushed on the start, a mark, a resize, an error
    and the end, and at most every FLUSH_SECONDS otherwise. close() writes the end event and then
    the done file, atomically."""

    def __init__(self, path, meta, gfx=False):
        if os.path.exists(os.path.join(path, "events.jsonl")):
            raise FileExistsError("%s already holds a recording" % path)
        os.makedirs(os.path.join(path, "blobs"), exist_ok=True)
        self.path = path
        self._t0 = time.monotonic()
        self._files = {"tui": open(os.path.join(path, "tui.bin"), "wb", buffering=0)}
        if gfx:
            self._files["gfx"] = open(os.path.join(path, "gfx.bin"), "wb", buffering=0)
        self.sizes = {ch: 0 for ch in self._files}
        self._events = open(os.path.join(path, "events.jsonl"), "w", encoding="ascii")
        self._last_flush = time.monotonic()
        self._blobs = 0
        self.closed = False
        start = {"e": "start", "v": 1}
        start.update(meta)
        self.event(start)

    def now(self):
        """Seconds since the recording started (the t of every event)."""
        return round(time.monotonic() - self._t0, 6)

    def data(self, channel, chunk, t):
        """Append chunk to the channel's file and write its data event. Returns the offset. The
        event line is formatted directly for the common case (a float time on a channel name of
        plain letters); it is the same JSON that event() writes."""
        fh = self._files.get(channel)
        if fh is None:
            raise ValueError("no %s channel in this recording" % channel)
        off = self.sizes[channel]
        n = fh.write(chunk)
        if n != len(chunk):
            view = memoryview(chunk)[n:]
            while view:
                view = view[fh.write(view):]
        self.sizes[channel] = off + len(chunk)
        if isinstance(t, float) and channel.isalpha() and channel.isascii():
            self._events.write('{"e":"data","ch":"%s","off":%d,"n":%d,"t":%r}\n'
                               % (channel, off, len(chunk), t))
            now = time.monotonic()
            if now - self._last_flush >= FLUSH_SECONDS:
                self._events.flush()
                self._last_flush = now
        else:
            self.event({"e": "data", "ch": channel, "off": off, "n": len(chunk), "t": t})
        return off

    def event(self, obj):
        """Write one event line; flushed now for start, mark, resize, error and end, and otherwise
        at most every FLUSH_SECONDS."""
        self._events.write(json.dumps(obj, separators=(",", ":")) + "\n")
        now = time.monotonic()
        if obj.get("e") in _FLUSH_AT_ONCE or now - self._last_flush >= FLUSH_SECONDS:
            self._events.flush()
            self._last_flush = now

    def blob(self, key, data, err, medium, t):
        """Record what the tap read for one APC: the bytes (a file in blobs/) or the error text.
        key is (channel, token start, token ordinal), the same key the terminal asks for. Returns
        the file name relative to the recording (None when there are no bytes), so that a live
        terminal can read the bytes from the file."""
        name = None
        if data is not None:
            self._blobs += 1
            name = "blobs/%06d.bin" % self._blobs
            with open(os.path.join(self.path, name), "wb") as fh:
                fh.write(data)
        self.event({"e": "blob", "key": list(key), "medium": medium, "file": name,
                    "n": 0 if data is None else len(data), "err": err, "t": t})
        return name

    def close(self, status, t=None):
        """The end event, then the files closed, then the done file written atomically."""
        if self.closed:
            return
        self.closed = True
        if t is None:
            t = self.now()
        self.event({"e": "end", "status": int(status), "t": t})
        self._events.flush()
        self._events.close()
        for fh in self._files.values():
            fh.close()
        tmp = os.path.join(self.path, "done.tmp")
        with open(tmp, "w", encoding="ascii") as fh:
            fh.write(DONE_TEXT)
        os.replace(tmp, os.path.join(self.path, "done"))


def _feed_to_update_end(term, chunk, channel, t):
    """Feed a chunk to the terminal byte by byte, and stop feeding as soon as its synchronized
    update flag is off. The flag changes only while a byte is processed, so this is the first
    byte at which the terminal shows the finished update (a mark inside an update is not shown
    any later than that)."""
    for i in range(len(chunk)):
        term.feed(chunk[i:i + 1], channel, t)
        if not term.sync:
            return


def write_json_atomic(path, value):
    """A JSON file written whole or not at all (a temporary name in the same folder, then
    rename)."""
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="ascii") as fh:
        json.dump(value, fh)
    os.replace(tmp, path)


class Recording:
    """A recording folder loaded into memory: its events, its blobs (key -> (bytes or None,
    error text or None)), its marks (name -> index of the last event with that name), and the
    live report when there is one."""

    def __init__(self, path, events, data, blobs, marks, live, done):
        self.path = path
        self.events = events
        self.meta = events[0]
        self.blobs = blobs
        self.marks = marks
        self.live = live
        self.done = done
        self.errors = [ev for ev in events if ev.get("e") == "error"]
        ends = [ev for ev in events if ev.get("e") == "end"]
        self.end = ends[-1] if ends else None
        self._data = data

    @classmethod
    def load(cls, path):
        """Read a recording folder. A last line cut short (the relay was killed while it wrote) is
        dropped: the recording then has no end event, and done is absent."""
        events = []
        with open(os.path.join(path, "events.jsonl"), encoding="ascii") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    events.append(json.loads(line))
                except ValueError:
                    break
        if not events or events[0].get("e") != "start":
            raise ValueError("%s: no start event, not a recording" % path)
        data = {}
        for ch in ("tui", "gfx"):
            name = os.path.join(path, ch + ".bin")
            if os.path.exists(name):
                with open(name, "rb") as fh:
                    data[ch] = fh.read()
        blobs = {}
        marks = {}
        for index, ev in enumerate(events):
            kind = ev.get("e")
            if kind == "blob":
                file_name = ev.get("file")
                payload = None
                if file_name is not None:
                    with open(os.path.join(path, file_name), "rb") as fh:
                        payload = fh.read()
                blobs[tuple(ev["key"])] = (payload, ev.get("err"))
            elif kind == "mark":
                marks[ev["name"]] = index
        live_path = os.path.join(path, "live_final.json")
        live = None
        if os.path.exists(live_path):
            with open(live_path, encoding="ascii") as fh:
                live = json.load(fh)
        return cls(path, events, data, blobs, marks, live,
                   os.path.exists(os.path.join(path, "done")))

    def _chunk(self, ev):
        start = ev["off"]
        return self._data.get(ev["ch"], b"")[start:start + ev["n"]]

    def _run(self, at=None, profile=None, hop=None):
        """Feed the events in order into a new terminal, up to the mark `at` (or to the end).

        A mark taken inside a synchronized update (DECSET 2026) stops at the byte where that update
        ends: the data event that ends it is fed byte by byte, and the feeding stops as soon as the
        terminal's flag is off (a resize ends an update too). Returns (terminal, time of the stop,
        the answers the child got, the answers the model gave)."""
        from vkitty.media import RecordedMedia
        from vkitty.vt import Terminal
        meta = self.meta
        term = Terminal(meta["cols"], meta["rows"], cell=tuple(meta.get("cell", (13, 33))),
                        pad=meta.get("pad", 4), profile=profile or meta.get("profile"),
                        hop=hop or meta.get("hop", "none"))
        term.media = RecordedMedia(self.blobs, warnings=term.warnings)
        target = None
        if at is not None:
            if at not in self.marks:
                raise KeyError("the recording has no mark %r" % (at,))
            target = self.marks[at]
        answers = []
        t_seen = None
        t_stop = None
        in_update = False
        for index, ev in enumerate(self.events):
            if index == target:
                t_stop = ev.get("t")
                if not term.sync:
                    break
                in_update = True
                term.warnings.append("mark %s taken inside a synchronized update: fed to the end "
                                     "of the update" % at)
                continue
            kind = ev.get("e")
            if kind == "data":
                chunk = self._chunk(ev)
                if in_update:
                    _feed_to_update_end(term, chunk, ev["ch"], ev["t"])
                else:
                    term.feed(chunk, ev["ch"], ev["t"])
                t_seen = ev["t"]
            elif kind == "resize":
                term.resize(ev["cols"], ev["rows"])
            elif kind == "reattach":
                term.reattach()
            elif kind == "mark":
                term.stats["since_prev_mark"] = {"apc_bytes": 0, "transmit_wire_bytes": 0}
            elif kind == "resp":
                answers.append(base64.b64decode(ev["b64"]))
            elif kind == "end":
                t_seen = ev.get("t", t_seen)
            if in_update and not term.sync:
                break
        if in_update and term.sync:
            term.warnings.append("mark %s: the synchronized update is still open at the end of "
                                 "the recording" % at)
        if target is None:
            t_stop = t_seen
        return term, t_stop, answers, list(term.responses)

    def replay(self, at=None, profile=None, hop=None):
        """The terminal after the events up to the mark `at` (all of them when None)."""
        return self._run(at, profile, hop)[0]

    def snapshot(self, at=None, profile=None, hop=None):
        """The screen at a mark (or at the end). Its responses are the answers the child got, as
        recorded; when a live terminal ran, a difference from the answers the model gives for
        the same bytes is a warning."""
        term, t_stop, answers, offline = self._run(at, profile, hop)
        snap = term.snapshot(t=t_stop)
        snap.responses = answers
        if self.live is not None and answers != offline:
            snap.warnings.append("responses differ: recorded %r, replayed %r"
                                 % (answers[-3:], offline[-3:]))
        return snap
