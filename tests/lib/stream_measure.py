"""Measure one recorded run of tests/stream_measure_screen.sh, and check it.

usage (under the harness's python, -I):
  python3 -I tests/lib/stream_measure.py RUN --run N --mode 012|011 [--pre011 CUTS] [--measure] [--decide]
  python3 -I tests/lib/stream_measure.py --table --mode 012|011 RUN...
  python3 -I tests/lib/stream_measure.py --cuts RUN...

RUN is the run's folder: rec/ (the harness's recording of what the program
wrote to its terminal, with a mark for each step of the scenario), meta (the
gif's image id and frame delays), frames.txt (each frame of the gif, base64, a
line each), stats (the program's counters in one `end` line, written after mark
e, so nothing sent after the call can be in the recording at e) and procs.jsonl
(tests/lib/stream_sampler.py: 20 times a second the CPU seconds and the seconds
waiting for a CPU of the processes that carried the run, tagged with the last mark).

The recording is read once into two Ghostty 1.4.0 models (tests/lib/vkitty):
RAW gets the bytes as the terminal got them, STRIP the same bytes with every
Kitty graphics command (ESC _ G up to ESC \\) removed, which is the screen the
editor drew. A cut is an escape sequence or string that another ESC cut off, or
that arrived inside an unfinished UTF-8 character (the model's cuts plus
splices). A screen is damaged at a mark when a cell of RAW differs from STRIP in
its text, width or style (the cursor is not compared). A frame change is one
complete transmission to the gif's image id; each is identified by the pixel
hash of the image the model then holds, against the hash of each frame of the
gif transmitted alone to a new model.

Marks: u0 u1 (untouched), s01..s21 (scrolling), p00..p31 (parked), t00..t21
(typing), b0 b1 (back in view), e (end). Checks M1 to M10 for Neovim 0.12
(mode 012) and N1 to N4 for 0.11 (mode 011); --measure prints the numbers only.

The checks of timing (M1, M7, M8 and 0.11's N1, N4) need the host to have let the
pipeline run. A timed check beyond its limit is UNDECIDED, not failed, when the
processes of the run waited for a CPU, or the host had almost no idle CPU, for more
than BUSY_SHARE of a window's wall time plus BUSY_SLACK (host_window); --decide makes
UNDECIDED a failure. Every other check always decides.
"""
import argparse
import bisect
import json
import os
import re
import statistics
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from vkitty import Recording, Terminal  # noqa: E402
from escape_scan import scan, summary  # noqa: E402

PROFILE = "ghostty-1.4.0"
ST = b"\x1b\\"
ESC = 0x1B

# the thresholds of the checks (the spec's budgets)
MIN_FRAMES_UNTOUCHED = 157      # frame changes in the untouched window
WINDOW_S = 13.0
PARKED_APC_BUDGET = 9216        # bytes of graphics while parked (the budget is 16 KB)
BACK_LATENCY_S = 0.080          # the first frame back after the gif's rows show
BACK_FOLLOWERS = 10             # frame changes in the second after it
BACK_FOLLOW_S = 1.0

# The host rule. A timed check (a count of frames in a window, a latency, the cuts of a
# quiet-window race) only says something about the product when the processes that
# carried the run, tmux, both relays, the shell and Neovim with its server, were not
# held back. The sampler reads, for each, the seconds it was runnable but waiting for a
# CPU. On a quiet 16-core host those waits add up to at most 47 ms in a 1.5 s window,
# 233 ms in 13.5 s and 432 ms in 35 s; a window is busy when the summed wait is more than
# BUSY_SHARE of its wall time plus BUSY_SLACK (50 ms for 1.5 s, 290 ms for 13.5 s, 720 ms
# for 35 s). Time on efficiency cores is not counted: a median 18.5 % of these light
# processes' CPU runs there even on a quiet host, so it does not tell the two apart.
BUSY_SHARE = 0.02
BUSY_SLACK = 0.020
# A saturated host is busy whatever the waits say: with every CPU taken the scheduler
# still runs these light processes first, so their own waits stay small while each hop
# of the pipeline wakes late and the frames slow down. The sampler reads the host's idle
# share every round; saturated is the time in a window whose rounds had under BUSY_IDLE
# of the CPU time idle, and it has the same limit as the wait. It is a time and not a
# mean because a working host goes saturated in bursts: 11 s of a 36 s window that
# averaged 58 % idle.
BUSY_IDLE = 0.10
# the phases whose host numbers the table shows: key, label, first mark, last mark
HOST_SPANS = (("untouched", "untouched", "u0", "u1"), ("parked", "parked", "p00", "p31"),
              ("typing", "typing", "t00", "t21"), ("back", "back in view", "b0", "b1"),
              ("whole", "whole run", "u0", "e"))

SCROLL = ["s%02d" % i for i in range(1, 22)]
PARK = ["p%02d" % i for i in range(0, 32)]
TYPING = ["t%02d" % i for i in range(0, 22)]
MARKS = ["u0", "u1"] + SCROLL + PARK + TYPING + ["b0", "b1", "e"]


class ApcStripper:
    """Removes Kitty graphics commands (ESC _ G up to and including ESC \\) from a
    stream fed in pieces. An ESC (or ESC _) at the end of a piece is held until
    the next byte shows whether a command starts; ESC _ without G passes."""
    GROUND, E1, E2, BODY, BODY_ESC = range(5)

    def __init__(self):
        self.state = self.GROUND
        self.held = b""

    def feed(self, data):
        out = []
        i, n = 0, len(data)
        while i < n:
            s = self.state
            if s == self.GROUND:
                j = data.find(b"\x1b", i)
                if j < 0:
                    out.append(data[i:])
                    break
                out.append(data[i:j])
                self.state, self.held, i = self.E1, b"\x1b", j + 1
            elif s == self.E1:
                b = data[i]
                if b == 0x5F:                      # ESC _
                    self.state, self.held, i = self.E2, b"\x1b_", i + 1
                elif b == ESC:                     # ESC ESC: the first passes
                    out.append(self.held)
                    self.held, i = b"\x1b", i + 1
                else:
                    out.append(self.held)
                    self.state, self.held = self.GROUND, b""
            elif s == self.E2:
                b = data[i]
                if b == 0x47:                      # ESC _ G: a graphics command
                    self.state, self.held, i = self.BODY, b"", i + 1
                elif b == ESC:
                    out.append(self.held)
                    self.state, self.held, i = self.E1, b"\x1b", i + 1
                else:
                    out.append(self.held)
                    self.state, self.held = self.GROUND, b""
            elif s == self.BODY:
                j = data.find(b"\x1b", i)
                if j < 0:
                    break
                self.state, i = self.BODY_ESC, j + 1
            else:                                  # BODY_ESC
                b = data[i]
                if b == 0x5C:
                    self.state = self.GROUND
                elif b != ESC:
                    self.state = self.BODY
                i += 1
        return b"".join(out)


def split_after_st(data):
    """The pieces of data, each ending right after an ESC \\ (the last may not)."""
    out = []
    i = 0
    while True:
        j = data.find(ST, i)
        if j < 0:
            if i < len(data):
                out.append(data[i:])
            return out
        out.append(data[i:j + 2])
        i = j + 2


def frame_hashes(path):
    """The pixel hash of each frame in path (a base64 PNG a line), each sent as one
    transmission to a model of its own."""
    hashes = []
    with open(path) as fh:
        for line in fh:
            b64 = line.strip()
            if not b64:
                continue
            term = Terminal(80, 24, profile=PROFILE, hop="none")
            chunks = [b64[i:i + 4096] for i in range(0, len(b64), 4096)]
            for n, chunk in enumerate(chunks):
                head = "a=t,f=100,i=1,q=2," if n == 0 else ""
                more = 0 if n == len(chunks) - 1 else 1
                term.feed(("\x1b_G%sm=%d;%s\x1b\\" % (head, more, chunk)).encode("ascii"), "tui")
            hashes.append(term.snapshot().images[1].sha256)
    return hashes


def model_pair(cols, rows, cell=(13, 33), pad=4):
    """RAW and STRIP: two models of the terminal (Ghostty 1.4.0, no multiplexer hop)."""
    return tuple(Terminal(cols, rows, cell=cell, pad=pad, profile=PROFILE, hop="none")
                 for _ in range(2))


def parse_kv(path, tag=None):
    """The first line of path (or the first starting with tag) as {key: value}."""
    with open(path) as fh:
        for line in fh:
            parts = line.split()
            if not parts:
                continue
            if tag is not None:
                if parts[0] != tag:
                    continue
                parts = parts[1:]
            return dict(p.split("=", 1) for p in parts if "=" in p)
    return {}


def style_of(snap, sid):
    return snap.styles[sid] if 0 <= sid < len(snap.styles) else sid


def damaged_cells(raw, strip):
    """How many cells differ between two snapshots in text, width or style."""
    if (raw.cols, raw.rows) != (strip.cols, strip.rows):
        return raw.cols * raw.rows
    n = 0
    for y in range(raw.rows):
        rrow, srow = raw.cells[y], strip.cells[y]
        for (rt, rs, rw), (st, ss, sw) in zip(rrow, srow):
            if rt != st or rw != sw or style_of(raw, rs) != style_of(strip, ss):
                n += 1
    return n


def load_procs(run):
    """The readings of run/procs.jsonl, or None when the file is missing, empty or
    unreadable. A last line the sampler did not finish writing is dropped."""
    try:
        with open(os.path.join(run, "procs.jsonl")) as fh:
            lines = [ln for ln in fh.read().split("\n") if ln.strip()]
    except (OSError, ValueError):
        return None
    rows = []
    for k, ln in enumerate(lines):
        try:
            row = json.loads(ln)
            if not isinstance(row, dict) or not isinstance(row.get("t"), (int, float)):
                raise ValueError("not a reading")
        except ValueError:
            if k == len(lines) - 1:
                break
            return None
        rows.append(row)
    return rows or None


def saturated_s(procs, ia, ib):
    """The seconds between readings ia and ib in rounds with under BUSY_IDLE of the host's CPU
    time idle, or None when no reading after ia has an idle share. A reading's share covers the
    time since the reading before it that had one; the sampler's extra mark lines have none."""
    sat, seen, prev = 0.0, False, procs[ia]["t"]
    for r in procs[ia + 1:ib + 1]:
        idle = r.get("idle")
        if idle is None:
            continue
        seen = True
        if idle < BUSY_IDLE:
            sat += r["t"] - prev
        prev = r["t"]
    return sat if seen else None


def host_window(procs, a, b):
    """What the host did to the processes of the run between mark a and mark b: the first
    reading tagged a and the first tagged b (for b == "e" with none, the last reading).
    Returns wall (s), wait (summed growth of the seconds the processes waited for a CPU, over
    the pids read at both ends), saturated (s, saturated_s), limit (s), known (some pid was
    read at both ends) and busy (known, and the wait or the saturated time is above the
    limit; with no idle shares the wait decides alone). A mark with no reading, or a platform
    without counters, gives known False and busy False."""
    if not procs or any(r.get("unknown") for r in procs):
        return {"known": False, "busy": False}
    ia = next((i for i, r in enumerate(procs) if r.get("m") == a), None)
    ib = next((i for i, r in enumerate(procs) if r.get("m") == b), None)
    if ib is None and b == "e":
        ib = len(procs) - 1
    if ia is None or ib is None:
        return {"known": False, "busy": False, "missing": a if ia is None else b}
    ra, rb = procs[ia], procs[ib]
    wall = rb["t"] - ra["t"]
    pa, pb = ra.get("p") or {}, rb.get("p") or {}
    both = [k for k in pa if k in pb]
    wait = sum(pb[k][1] - pa[k][1] for k in both)
    limit = BUSY_SHARE * wall + BUSY_SLACK
    known = bool(both)
    sat = saturated_s(procs, ia, ib)
    return {"wall": wall, "wait": wait, "saturated": sat, "limit": limit, "known": known,
            "busy": known and (wait > limit or (sat is not None and sat > limit))}


def saturated_note(w):
    """", <n> ms saturated" for a window with idle shares, else nothing."""
    return "" if w.get("saturated") is None else ", %.0f ms saturated" % (w["saturated"] * 1000)


def tchk(name, ok, detail, windows):
    """A timed check over windows, a list of (a, b, host_window): ok when it holds; when it
    does not, undecided if the host was busy in any window (it may be the host), else fail."""
    if ok:
        return (name, "ok", detail)
    for a, b, w in windows:
        if w.get("busy"):
            return (name, "undecided", "%s; the host was busy: %s-%s waited %.0f ms for a CPU in %.1f s (limit %.0f ms)%s"
                    % (detail, a, b, w["wait"] * 1000, w["wall"], w["limit"] * 1000, saturated_note(w)))
    seen = ["%s-%s waited %.0f ms (limit %.0f ms)%s" % (a, b, w["wait"] * 1000, w["limit"] * 1000, saturated_note(w))
            for a, b, w in windows if w.get("known")]
    return (name, "fail", "%s; the host was quiet: %s" % (detail, ", ".join(seen)) if seen
            else "%s; no host numbers" % detail)


def result_line(run, name, state, detail, decide):
    """The line printed for a result and whether it counts as a failure."""
    if state == "ok":
        return "  ok run %s: %s" % (run, name), False
    if state == "undecided" and not decide:
        return "UNDECIDED run %s: %s  -- %s" % (run, name, detail), False
    tail = " (undecided, and JNV_STREAM_DECIDE=1 wants a decided result)" if state == "undecided" else ""
    return "FAIL run %s: %s  -- %s%s" % (run, name, detail, tail), True


def analyze(run):
    """One pass over the recording: the readings at each mark, the frame changes of the gif."""
    meta = parse_kv(os.path.join(run, "meta"))
    gid = int(meta["gid"])
    delays = [float(x) for x in meta.get("delays", "").split(",") if x]
    hashes = frame_hashes(os.path.join(run, "frames.txt"))
    index_of = {h: k for k, h in enumerate(hashes)}
    rec = Recording.load(os.path.join(run, "rec"))
    with open(os.path.join(run, "rec", "tui.bin"), "rb") as fh:
        tui = fh.read()
    start = rec.events[0]
    cols, rows = start["cols"], start["rows"]

    from vkitty.media import RecordedMedia
    raw, strip = model_pair(cols, rows, tuple(start.get("cell", (13, 33))), start.get("pad", 4))
    raw.media = RecordedMedia(rec.blobs, warnings=raw.warnings)
    stripper = ApcStripper()
    gid_key = str(gid)
    seen_tx = 0
    txs = []                  # (t, index of the frame, or None)
    readings = {}
    after_b0 = False
    t_vis = None
    n_events = 0

    def gif_tx():
        ent = raw.stats["by_image"].get(gid_key)
        return (ent["transmissions"], ent["wire_bytes"]) if ent else (0, 0)

    for ev in rec.events:
        kind = ev.get("e")
        if kind == "data" and ev.get("ch") == "tui":
            n_events += 1
            chunk = tui[ev["off"]:ev["off"] + ev["n"]]
            t = ev["t"]
            for piece in split_after_st(chunk):
                raw.feed(piece, "tui", t)
                now_tx, _ = gif_tx()
                while now_tx > seen_tx:
                    seen_tx += 1
                    k = None
                    if seen_tx == now_tx:
                        view = raw.snapshot(t).images.get(gid)
                        k = index_of.get(view.sha256) if view is not None else None
                    txs.append((t, k))
            strip.feed(stripper.feed(chunk), "tui", t)
            if after_b0 and t_vis is None:
                snap = raw.snapshot(t)
                if any(v["image_id"] == gid for v in snap.virtual) \
                        or any(m["image_id"] == gid for m in snap.missing):
                    t_vis = t
        elif kind == "mark":
            name = ev["name"]
            if name == "b0":
                after_b0 = True
            rs, ss = raw.snapshot(ev["t"]), strip.snapshot(ev["t"])
            n_tx, wire = gif_tx()
            readings[name] = {
                "t": ev["t"], "cuts": raw.stats["cuts"], "splices": raw.stats["splices"],
                "apc_bytes": raw.stats["apc_bytes"], "gif_tx": n_tx, "gif_wire": wire,
                "damaged": damaged_cells(rs, ss),
            }
        elif kind == "resize":
            raw.resize(ev["cols"], ev["rows"])
            strip.resize(ev["cols"], ev["rows"])
    cut_list, kitty = scan(tui)
    return {
        "gid": gid, "delays": delays, "frames": len(hashes), "unique_frames": len(set(hashes)),
        "txs": txs, "readings": readings, "t_vis": t_vis, "events": n_events,
        "tui_bytes": len(tui), "cuts_total": raw.stats["cuts"] + raw.stats["splices"],
        "scan_cuts": len(cut_list), "scan_summary": summary(tui, cut_list, kitty),
        "stats": parse_kv(os.path.join(run, "stats"), "end"),
    }


def clock(delays):
    """The start of each frame (s) and the cycle (s), a delay missing or not positive
    counting 100 ms as the plugin's clock does."""
    starts, acc = [], 0.0
    for d in delays:
        starts.append(acc / 1000.0)
        acc += d if d and d > 0 else 100.0
    return starts, acc / 1000.0


def circ(x, cycle):
    return ((x + cycle / 2.0) % cycle) - cycle / 2.0


def m7(d, t_b0):
    """The clock's frame back in view. Returns (ok, detail, numbers)."""
    starts, cycle = clock(d["delays"] or [80.0] * d["frames"])
    if len(starts) != d["frames"]:
        return False, "meta has %d delays for %d frames" % (len(starts), d["frames"]), {}
    window = [(t, k) for t, k in d["txs"] if d["win"][0] <= t <= d["win"][1]]
    if not window:
        return False, "no frame change in the untouched window", {}
    if any(k is None for _t, k in window):
        return False, "a frame change in the untouched window is none of the gif's frames", {}
    phases = [(t - starts[k]) % cycle for t, k in window]
    ref = phases[0] + (statistics.median(circ(p - phases[0], cycle) for p in phases[1:])
                       if len(phases) > 1 else 0.0)
    after = [(t, k) for t, k in d["txs"] if t >= t_b0]
    if not after:
        return False, "no frame change after mark b0", {}
    t_first, k_first = after[0]
    if k_first is None:
        return False, "the first frame change after b0 is none of the gif's frames", {}
    pos = (t_first - ref) % cycle
    k_clock = bisect.bisect_right(starts, pos) - 1
    n = len(starts)
    diff = abs(k_first - k_clock)
    diff = min(diff, n - diff)
    nums = {"clock_diff": diff, "k_first": k_first, "k_clock": k_clock, "t_first": t_first}
    return diff <= 1, "frame %d came where the clock is at frame %d (%d frames apart)" % (
        k_first + 1, k_clock + 1, diff), nums


def build(run, mode, pre011):
    d = analyze(run)
    r = d["readings"]
    d["win"] = None
    results = []        # (name, state, detail), state ok, fail or undecided
    rows = []           # (label, value) for the table
    procs = load_procs(run)

    def chk(name, ok, detail=""):
        """A check that always decides."""
        results.append((name, "ok" if ok else "fail", detail))

    def tc(name, ok, detail, *spans):
        """A timed check over the windows (a, b) in spans: it decides only on a host that let
        the processes of the run work."""
        results.append(tchk(name, bool(ok), detail, [(a, b, host_window(procs, a, b)) for a, b in spans]))

    def have(*names):
        missing = [n for n in names if n not in r]
        return missing

    def cut(name):
        return r[name]["cuts"] + r[name]["splices"]

    def dmg(names):
        return sum(1 for n in names if r[n]["damaged"] > 0)

    nums = {}
    # untouched window
    if "u0" in r:
        t0 = r["u0"]["t"]
        d["win"] = (t0, t0 + WINDOW_S)
        nums["frames_untouched"] = sum(1 for t, _k in d["txs"] if d["win"][0] <= t <= d["win"][1])
        rows.append(("gif frame changes in 13 s untouched (min %d)" % MIN_FRAMES_UNTOUCHED, nums["frames_untouched"]))
    # scrolling
    if not have("u1", "s21", *SCROLL):
        nums["scroll_cuts"] = cut("s21") - cut("u1")
        nums["scroll_damaged"] = dmg(SCROLL)
        nums["scroll_frames"] = r["s21"]["gif_tx"] - r["u1"]["gif_tx"]
        rows.append(("scrolling: cuts", nums["scroll_cuts"]))
        rows.append(("scrolling: damaged screens of 21", nums["scroll_damaged"]))
        rows.append(("scrolling: gif frame changes", nums["scroll_frames"]))
    # parked
    if not have(*PARK):
        nums["park_s"] = round(r["p31"]["t"] - r["p00"]["t"], 1)
        nums["park_cuts"] = cut("p31") - cut("p00")
        nums["park_damaged"] = dmg(PARK[1:])
        nums["park_gif_tx"] = r["p31"]["gif_tx"] - r["p00"]["gif_tx"]
        nums["park_gif_wire"] = r["p31"]["gif_wire"] - r["p00"]["gif_wire"]
        nums["park_apc"] = r["p31"]["apc_bytes"] - r["p00"]["apc_bytes"]
        rows.append(("parked: seconds", nums["park_s"]))
        rows.append(("parked: cuts", nums["park_cuts"]))
        rows.append(("parked: damaged screens of 31", nums["park_damaged"]))
        rows.append(("parked: gif frame changes", nums["park_gif_tx"]))
        rows.append(("parked: graphics bytes (budget %d)" % PARKED_APC_BUDGET, nums["park_apc"]))
    # typing
    if not have(*TYPING):
        nums["type_cuts"] = cut("t21") - cut("t00")
        nums["type_damaged"] = dmg(TYPING[1:])
        nums["type_apc"] = r["t21"]["apc_bytes"] - r["t00"]["apc_bytes"]
        rows.append(("typing: cuts", nums["type_cuts"]))
        rows.append(("typing: damaged screens of 21", nums["type_damaged"]))
        rows.append(("typing: graphics bytes", nums["type_apc"]))
    nums["cuts_total"] = d["cuts_total"]
    nums["scan_cuts"] = d["scan_cuts"]
    nums["tui_bytes"] = d["tui_bytes"]
    rows.append(("whole recording: cuts", d["cuts_total"]))
    rows.append(("whole recording: escape_scan cuts", d["scan_cuts"]))
    rows.append(("whole recording: bytes", d["tui_bytes"]))
    # what the host did to the processes of the run in each phase, whole ms
    host = {}
    for key, label, a, b in HOST_SPANS:
        w = host_window(procs, a, b)
        host[key] = w
        rows.append(("host: ms waited for a CPU, %s (limit %s)" % (
            label, "%.0f" % (w["limit"] * 1000) if "limit" in w else "-"),
            "%.0f" % (w["wait"] * 1000) if w.get("known") else "-"))
        rows.append(("host: ms saturated, %s (limit %s)" % (
            label, "%.0f" % (w["limit"] * 1000) if "limit" in w else "-"),
            "%.0f" % (w["saturated"] * 1000) if w.get("known") and w["saturated"] is not None else "-"))
    d["host"] = host

    if mode == "012":
        miss = have("u0")
        tc("M1 the gif played: at least %d frame changes in %.0f s untouched" % (MIN_FRAMES_UNTOUCHED, WINDOW_S),
           not miss and nums["frames_untouched"] >= MIN_FRAMES_UNTOUCHED,
           ("no mark " + ", ".join(miss)) if miss else "%d frame changes" % nums["frames_untouched"],
           ("u0", "u1"))
        miss = have("u1", *SCROLL)
        chk("M2 no escape sequence was cut while the gif was in view and the screen scrolled",
            not miss and nums["scroll_cuts"] == 0,
            ("no mark " + ", ".join(miss)) if miss else "%d cut" % nums["scroll_cuts"])
        chk("M3 no screen was damaged while it scrolled (s01 to s21)",
            not miss and nums["scroll_damaged"] == 0,
            ("no mark " + ", ".join(miss)) if miss else "%d of 21 damaged" % nums["scroll_damaged"])
        miss = have(*PARK)
        chk("M4 no cut and no damaged screen while the gif was parked off screen (p00 to p31)",
            not miss and nums["park_cuts"] == 0 and nums["park_damaged"] == 0,
            ("no mark " + ", ".join(miss)) if miss else "%d cut, %d of 31 damaged" % (nums["park_cuts"], nums["park_damaged"]))
        chk("M5 the parked gif sent nothing and all graphics stayed within %d bytes" % PARKED_APC_BUDGET,
            not miss and nums["park_gif_tx"] == 0 and nums["park_gif_wire"] == 0
            and nums["park_apc"] <= PARKED_APC_BUDGET,
            ("no mark " + ", ".join(miss)) if miss else
            "%d gif frame changes, %d gif bytes, %d graphics bytes in %.1f s"
            % (nums["park_gif_tx"], nums["park_gif_wire"], nums["park_apc"], nums["park_s"]))
        miss = have(*TYPING)
        chk("M6 typing next to the plot cut nothing, damaged nothing and wrote no graphics",
            not miss and nums["type_cuts"] == 0 and nums["type_damaged"] == 0 and nums["type_apc"] == 0,
            ("no mark " + ", ".join(miss)) if miss else "%d cut, %d of 21 damaged, %d graphics bytes"
            % (nums["type_cuts"], nums["type_damaged"], nums["type_apc"]))
        miss = have("u0", "b0")
        if miss:
            tc("M7 back in view the first frame is the one the gif's clock is at", False,
               "no mark " + ", ".join(miss), ("u0", "u1"), ("b0", "b1"))
        else:
            ok, detail, m7n = m7(d, r["b0"]["t"])
            nums.update(m7n)
            if "clock_diff" in m7n:
                rows.append(("back: frames from the clock's frame (max 1)", m7n["clock_diff"]))
            tc("M7 back in view the first frame is the one the gif's clock is at (within one frame)", ok, detail,
               ("u0", "u1"), ("b0", "b1"))
        miss = have("b0")
        m8 = "M8 the first frame came within %d ms of the gif showing, and the gif played on" % (BACK_LATENCY_S * 1000)
        if miss:
            tc(m8, False, "no mark b0", ("b0", "b1"))
        else:
            after = [t for t, _k in d["txs"] if t >= r["b0"]["t"]]
            if d["t_vis"] is None or not after:
                tc(m8, False, "the gif's rows never showed after b0" if d["t_vis"] is None
                   else "no frame change after b0", ("b0", "b1"))
            else:
                lat = max(0.0, after[0] - d["t_vis"])
                follow = sum(1 for t in after[1:] if t <= after[0] + BACK_FOLLOW_S)
                nums["back_latency_ms"] = round(lat * 1000, 1)
                nums["back_followers"] = follow
                rows.append(("back: ms from the gif showing to its first frame (max %d)" % (BACK_LATENCY_S * 1000),
                             nums["back_latency_ms"]))
                rows.append(("back: frame changes in the next second (min %d)" % BACK_FOLLOWERS, follow))
                tc(m8, lat <= BACK_LATENCY_S and follow >= BACK_FOLLOWERS,
                   "%.0f ms after the rows showed, %d frame changes in the next second" % (lat * 1000, follow),
                   ("b0", "b1"))
        st = d["stats"]
        miss = have("e")
        try:
            sent = int(st["ui_send_bytes"])
            tty_n, ui_n, remote = int(st["tty_n"]), int(st["ui_send_n"]), st["remote"]
        except (KeyError, ValueError):
            sent = tty_n = ui_n = remote = None
        if miss or sent is None:
            chk("M9 every graphics byte the terminal got was sent with nvim_ui_send", False,
                ("no mark e" if miss else "no end line in stats: %r" % (st,)))
        else:
            apc = r["e"]["apc_bytes"]
            nums.update({"apc_end": apc, "ui_send_bytes": sent})
            rows.append(("end: graphics bytes the terminal got", apc))
            rows.append(("end: bytes sent with nvim_ui_send", sent))
            chk("M9 every graphics byte the terminal got was sent with nvim_ui_send",
                apc <= sent and tty_n > 0 and tty_n == ui_n and remote == "true",
                "%d graphics bytes arrived, %d sent with nvim_ui_send; tty_n=%d ui_send_n=%d remote=%s"
                % (apc, sent, tty_n, ui_n, remote))
        chk("M10 no escape sequence was cut anywhere in the recording",
            d["cuts_total"] == 0 and d["scan_cuts"] == 0,
            "%d cut by the model, %d by escape_scan; %s" % (d["cuts_total"], d["scan_cuts"],
                                                           d["scan_summary"].splitlines()[0] if d["scan_summary"] else ""))
        if d["unique_frames"] != d["frames"]:
            chk("the gif's frames have distinct pixels", False, "%d of %d" % (d["unique_frames"], d["frames"]))
    else:
        limit = pre011
        tc("N1 the cuts of the whole recording are at most half the tree before the fix's fewest (%d)" % limit,
           2 * d["cuts_total"] <= limit, "%d cut" % d["cuts_total"], ("u0", "e"))
        miss = have("p00", "p31")
        chk("N2 no cut while parked",
            not miss and nums["park_cuts"] == 0,
            ("no mark " + ", ".join(miss)) if miss else "%d cut parked" % nums["park_cuts"])
        chk("N3 the parked gif sent nothing",
            not miss and nums["park_gif_tx"] == 0,
            ("no mark " + ", ".join(miss)) if miss else "%d gif frame changes while parked" % nums["park_gif_tx"])
        miss = have("t00", "t21")
        tc("N4 no cut while typing",
           not miss and nums["type_cuts"] == 0,
           ("no mark " + ", ".join(miss)) if miss else "%d cut typing" % nums["type_cuts"],
           ("t00", "t21"))
    # the host rule's own evidence: the sampler ran and its numbers were read
    log = ""
    try:
        with open(os.path.join(run, "sampler.log")) as fh:
            log = next((ln.strip() for ln in fh if ln.strip()), "")
    except OSError:
        pass
    chk("the host sampler recorded the run", procs is not None and not log,
        log or ("no procs.jsonl" if procs is None else "%d readings" % len(procs)))
    return d, results, rows, nums


def self_test():
    """The stripper and the damage test on streams with known answers. Returns the failures."""
    fails = []

    def check(name, ok, detail=""):
        if not ok:
            fails.append("%s  -- %s" % (name, detail))

    def stripped(pieces):
        st = ApcStripper()
        return b"".join(st.feed(p) for p in pieces)

    apc = b"\x1b_Ga=t,f=100,i=7,q=2,m=0;AAAA\x1b\\"
    stream = b"AB\x1b[31mC" + apc + b"D\x1b_Xfoo\x1b\\E" + apc + b"\x1b[0mF"
    want = b"AB\x1b[31mCD\x1b_Xfoo\x1b\\E\x1b[0mF"
    check("stripper, one piece", stripped([stream]) == want, repr(stripped([stream])))
    bad = [i for i in range(1, len(stream)) if stripped([stream[:i], stream[i:]]) != want]
    check("stripper, every split in two", not bad, "splits at %s" % bad[:5])
    check("stripper, bytes one at a time", stripped([stream[i:i + 1] for i in range(len(stream))]) == want)
    # a command cuts a color sequence: the stripped stream is the sequence whole
    cut = b"x\x1b[38;2;10;" + apc + b"20;30mhello\x1b[0m"
    check("stripper restores a cut color sequence", stripped([cut]) == b"x\x1b[38;2;10;20;30mhello\x1b[0m")

    def pair(data):
        raw, strip = model_pair(40, 5)
        st = ApcStripper()
        for piece in split_after_st(data):
            raw.feed(piece, "tui", 0.0)
        strip.feed(st.feed(data), "tui", 0.0)
        return raw, strip

    raw, strip = pair(b"\x1b[38;2;10;20;30mhello\x1b[0m world" + apc + b" again")
    n = damaged_cells(raw.snapshot(0.0), strip.snapshot(0.0))
    check("a clean stream with commands is not damaged", n == 0, "%d cells differ" % n)
    check("a clean stream has no cut", raw.stats["cuts"] + raw.stats["splices"] == 0)
    raw, strip = pair(cut)
    n = damaged_cells(raw.snapshot(0.0), strip.snapshot(0.0))
    check("a color sequence cut by a command is damaged", n > 0, "%d cells differ" % n)
    check("a color sequence cut by a command is a cut", raw.stats["cuts"] + raw.stats["splices"] >= 1,
          str(raw.stats["cuts"]))
    # a command cut by the editor's own output: text of the command shows
    raw, strip = pair(b"\x1b_Ga=t,f=100,i=7,q=2,m=1;AAAA\x1b[1mbold\x1b[0mBBBB\x1b\\ tail")
    check("a command cut by a sequence is a cut", raw.stats["cuts"] >= 1, str(raw.stats["cuts"]))
    # the same text in other colors, and the same colors with other text
    a, b = model_pair(40, 5)
    a.feed(b"\x1b[31mhello", "tui", 0.0)
    b.feed(b"hello", "tui", 0.0)
    n = damaged_cells(a.snapshot(0.0), b.snapshot(0.0))
    check("a style that differs is damage", n == 5, "%d cells differ" % n)
    b, c = model_pair(40, 5)
    b.feed(b"\x1b[31mhello", "tui", 0.0)
    c.feed(b"\x1b[31mhellp", "tui", 0.0)
    n = damaged_cells(b.snapshot(0.0), c.snapshot(0.0))
    check("a character that differs is damage", n == 1, "%d cells differ" % n)
    b, c = model_pair(40, 5)
    b.feed(b"\x1b[31mhello", "tui", 0.0)
    c.feed(b"\x1b[31mhello", "tui", 0.0)
    n = damaged_cells(b.snapshot(0.0), c.snapshot(0.0))
    check("equal screens are not damage", n == 0, "%d cells differ" % n)

    # the host rule: synthetic readings, marks a then b, pids 1 and 2
    def reading(t, m, w1, w2, extra=None):
        p = {"1": [t, w1], "2": [t, w2]}
        p.update(extra or {})
        return {"t": t, "m": m, "p": p}

    def near(x, y):
        return abs(x - y) < 1e-9

    def procs_with(w_a, w_b):
        """a at t=1, b at t=3 (2.0 s apart); the waits of the two pids grow by w_b - w_a
        in total; a later reading of each mark must change nothing."""
        return [reading(0.0, None, 0.0, 0.0),
                reading(1.0, "a", w_a[0], w_a[1]),
                reading(1.05, "a", w_a[0] + 5.0, w_a[1] + 5.0),
                reading(2.0, "a", w_a[0] + 6.0, w_a[1] + 6.0),
                reading(3.0, "b", w_b[0], w_b[1]),
                reading(3.05, "b", w_b[0] + 7.0, w_b[1] + 7.0)]

    quiet = host_window(procs_with((0.001, 0.002), (0.005, 0.008)), "a", "b")
    check("H1 a quiet window: wall, wait, limit, known, busy",
          near(quiet["wall"], 2.0) and near(quiet["wait"], 0.010) and near(quiet["limit"], 0.060)
          and quiet["known"] is True and quiet["busy"] is False, repr(quiet))
    busy = host_window(procs_with((0.001, 0.002), (0.101, 0.102)), "a", "b")
    check("H2 a busy window: 0.200 s of wait in 2.0 s is busy",
          near(busy["wall"], 2.0) and near(busy["wait"], 0.200) and near(busy["limit"], 0.060)
          and busy["known"] is True and busy["busy"] is True, repr(busy))
    nm = "H3 a timed check: ok when it passes, fail on a quiet window, undecided on a busy one"
    r_ok_q = tchk("T", True, "fine", [("a", "b", quiet)])
    r_ok_b = tchk("T", True, "fine", [("a", "b", busy)])
    r_fail_q = tchk("T", False, "slow", [("a", "b", quiet)])
    r_fail_b = tchk("T", False, "slow", [("a", "b", busy)])
    r_fail_2 = tchk("T", False, "slow", [("a", "b", quiet), ("c", "d", busy)])
    check(nm, r_ok_q[1] == "ok" and r_ok_b[1] == "ok" and r_ok_q[2] == "fine"
          and r_fail_q[1] == "fail" and r_fail_b[1] == "undecided" and r_fail_2[1] == "undecided"
          and r_fail_q[2].startswith("slow; the host was quiet: a-b waited 10 ms (limit 60 ms)")
          and r_fail_b[2] == "slow; the host was busy: a-b waited 200 ms for a CPU in 2.0 s (limit 60 ms)"
          and "c-d waited 200 ms" in r_fail_2[2],
          repr((r_ok_q, r_ok_b, r_fail_q, r_fail_b, r_fail_2)))
    unknown = host_window([{"t": 0.0, "m": None, "p": {}, "unknown": True}], "a", "b")
    r_fail_u = tchk("T", False, "slow", [("a", "b", unknown)])
    check("H4 an unknown line: no window is known or busy, a failing timed check fails",
          unknown["known"] is False and unknown["busy"] is False and r_fail_u[1] == "fail"
          and r_fail_u[2] == "slow; no host numbers", repr((unknown, r_fail_u)))
    late = host_window([reading(1.0, "a", 0.0, 0.0),
                        reading(3.0, "b", 0.001, 0.001, {"3": [3.0, 9.0]})], "a", "b")
    check("H5 a pid that appears only at the end of the window adds nothing",
          near(late["wait"], 0.002) and late["busy"] is False and late["known"] is True, repr(late))
    missing = host_window([reading(1.0, "a", 0.0, 0.0)], "a", "b")
    last = host_window([reading(1.0, "a", 0.0, 0.0), reading(2.0, "x", 0.0, 0.0),
                        reading(4.0, "x", 0.1, 0.1)], "a", "e")
    check("H5b a mark with no reading gives an unknown window; the end mark falls back to the last reading",
          missing["known"] is False and missing["busy"] is False and missing.get("missing") == "b"
          and last["known"] is True and near(last["wall"], 3.0) and near(last["wait"], 0.2)
          and last["busy"] is True, repr((missing, last)))
    def idled(shares):
        """a at t=1, then one reading every 0.05 s with these idle shares, the last one
        tagged b; the two pids' waits grow by 0.010 s in all."""
        rs = [reading(1.0, "a", 0.0, 0.0)]
        for i, share in enumerate(shares):
            done = 0.005 * (i + 1) / len(shares)
            r = reading(1.0 + 0.05 * (i + 1), "x", done, done)
            r["idle"] = share
            rs.append(r)
        rs[-1]["m"] = "b"
        return rs

    full = host_window(idled([0.0] * 40), "a", "b")
    free = host_window(idled([0.5] * 40), "a", "b")
    burst = host_window(idled([0.9] * 32 + [0.0] * 8), "a", "b")
    blip = host_window(idled([0.9] * 39 + [0.0]), "a", "b")
    nomark = idled([0.0] * 20 + [0.9] * 20)
    nomark.insert(21, reading(2.0, "m", 0.0, 0.0))     # an extra mark line, no idle share
    extra = host_window(nomark, "a", "b")
    none = host_window(procs_with((0.001, 0.002), (0.005, 0.008)), "a", "b")
    r_sat = tchk("T", False, "slow", [("a", "b", full)])
    r_free = tchk("T", False, "slow", [("a", "b", free)])
    check("H7 saturated time: a full or bursty window is busy whatever the waits say, a free or blip one is not, "
          "a mark line adds nothing, with no idle shares the waits decide alone",
          near(full["wait"], 0.010) and near(full["saturated"], 2.0) and full["busy"] is True
          and near(free["saturated"], 0.0) and free["busy"] is False
          and near(burst["saturated"], 0.4) and burst["busy"] is True
          and near(blip["saturated"], 0.05) and blip["busy"] is False
          and near(extra["saturated"], 1.0) and extra["busy"] is True
          and none["saturated"] is None and none["busy"] is False
          and r_sat[1] == "undecided" and r_sat[2].endswith(", 2000 ms saturated")
          and r_free[1] == "fail" and r_free[2].endswith(", 0 ms saturated"),
          repr((full, free, burst, blip, extra, none, r_sat, r_free)))
    from stream_sampler import stat_ticks, tree
    ticks = stat_ticks("cpu  10 20 30 40 50 60 70 80 90 100")
    check("H8 the first line of /proc/stat: idle with iowait, the total without guest time",
          ticks == (90, 360) and stat_ticks("cpu 1 2 3 4") == (4, 10), repr(ticks))
    kids = {1: [2], 2: [3, 1], 3: [4]}
    found, kept = tree([1], {1, 2, 9}, kids.get), tree([1], {1, 9}, lambda pid: None)
    check("H9 the process tree: the walk goes through known processes (a loop in it ends), and a "
          "failed look keeps the set",
          found == {1, 2, 3, 4, 9} and kept == {1, 9}, "%r %r" % (found, kept))
    import stream_sampler
    real_ps = stream_sampler.ps_children
    try:
        stream_sampler.ps_children = lambda: None
        ps_failed = tree([1], {1, 9})
        stream_sampler.ps_children = lambda: {1: [2], 2: [3]}
        ps_found = tree([1], {1, 9})
    finally:
        stream_sampler.ps_children = real_ps
    check("H9b the process tree from one ps: a failed ps keeps the set, an answer adds the descendants",
          ps_failed == {1, 9} and ps_found == {1, 2, 3, 9}, "%r %r" % (ps_failed, ps_found))
    # the sampler itself, for a few rounds, following this process: it finds
    # its own process as this one's child (the live look at the tree), and
    # every round has the host's idle share where the platform tells it
    import subprocess
    import tempfile
    import time
    with tempfile.TemporaryDirectory() as run:
        sp = subprocess.Popen([sys.executable, "-I", stream_sampler.__file__, run, str(os.getpid())],
                              stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
        deadline = time.monotonic() + 10
        path = os.path.join(run, "procs.jsonl")
        while time.monotonic() < deadline and sp.poll() is None:
            if os.path.exists(path):
                with open(path) as fh:
                    if sum(1 for _ in fh) >= 6:
                        break
            time.sleep(0.05)
        open(os.path.join(run, "end"), "w").close()
        try:
            err = sp.communicate(timeout=10)[1]
        except subprocess.TimeoutExpired:
            sp.kill()
            err = sp.communicate()[1] + " (still running 10 s after the end file)"
        lines = []
        if os.path.exists(path):
            with open(path) as fh:
                lines = [json.loads(ln) for ln in fh]
    told = stream_sampler.host_ticks() is not None
    unknown = bool(lines) and lines[0].get("unknown") is True
    kids = [ln for ln in lines if str(sp.pid) in ln.get("p", {})]
    no_idle = [i for i, ln in enumerate(lines) if ln.get("idle") is None]
    check("H9c the sampler run live: it follows a child of its root (itself) and every reading has the "
          "host's idle share where the platform tells it",
          sp.returncode == 0 and not err.strip() and len(lines) >= 3
          and (unknown or (len(kids) == len(lines) and (not told or not no_idle))),
          "rc %r, stderr %r, %d readings, %d with the child, readings with no idle share: %r" % (
              sp.returncode, err.strip(), len(lines), len(kids), no_idle))
    forms = [result_line("2", "M1 x", "ok", "d", False), result_line("2", "M1 x", "fail", "d", False),
             result_line("2", "M1 x", "undecided", "d", False), result_line("2", "M1 x", "undecided", "d", True)]
    check("H6 the print forms: ok, FAIL, UNDECIDED, and FAIL when a decided result is wanted",
          forms == [("  ok run 2: M1 x", False), ("FAIL run 2: M1 x  -- d", True),
                    ("UNDECIDED run 2: M1 x  -- d", False),
                    ("FAIL run 2: M1 x  -- d (undecided, and JNV_STREAM_DECIDE=1 wants a decided result)", True)],
          repr(forms))
    return fails


def canon(label):
    """A table row's identity: a host row's label carries its run's limit, which differs by run."""
    return re.sub(r" \(limit \d+\)$", "", label) if label.startswith("host: ") else label


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("runs", nargs="*")
    ap.add_argument("--run", default="?")
    ap.add_argument("--mode", default="012", choices=("012", "011"))
    ap.add_argument("--pre011", type=int, default=0)
    ap.add_argument("--measure", action="store_true")
    ap.add_argument("--decide", action="store_true")
    ap.add_argument("--table", action="store_true")
    ap.add_argument("--cuts", action="store_true")
    ap.add_argument("--self-test", action="store_true")
    a = ap.parse_args()
    if a.self_test:
        fails = self_test()
        for f in fails:
            print("FAIL stream_measure self-test: " + f)
        if not fails:
            print("  ok stream_measure self-test: the stripper, the damage test and the host rule")
        return 1 if fails else 0
    if a.cuts:
        print(" ".join(str(json.load(open(os.path.join(r, "measure.json")))["cuts_total"]) for r in a.runs))
        return 0
    if a.table:
        data = [json.load(open(os.path.join(r, "measure.json"))) for r in a.runs]
        labels = []
        for dd in data:
            for lab, _v in dd["rows"]:
                if canon(lab) not in [canon(x) for x in labels]:
                    labels.append(lab)
        width = max(len(x) for x in labels) if labels else 10
        print("\n%-*s  %s" % (width, "numbers (%s)" % ("Neovim 0.12" if a.mode == "012" else "Neovim 0.11"),
                              "  ".join("%9s" % ("run %d" % (i + 1)) for i in range(len(data)))))
        for lab in labels:
            vals = []
            for dd in data:
                v = dict((canon(k), x) for k, x in dd["rows"]).get(canon(lab))
                vals.append("%9s" % ("-" if v is None else v))
            print("%-*s  %s" % (width, lab, "  ".join(vals)))
        return 0
    run = a.runs[0]
    d, results, rows, nums = build(run, a.mode, a.pre011)
    print("run %s: %d bytes in %d reads, %d gif frame changes, %d cut%s" % (
        a.run, d["tui_bytes"], d["events"], len(d["txs"]), d["cuts_total"], "" if d["cuts_total"] == 1 else "s"))
    for lab, v in rows:
        print("  %-62s %s" % (lab, v))
    print(d["scan_summary"])
    fails = 0
    if not a.measure:
        for name, state, detail in results:
            line, failed = result_line(a.run, name, state, detail, a.decide)
            print(line)
            fails += failed
    with open(os.path.join(run, "measure.json"), "w") as fh:
        json.dump({"rows": rows, "numbers": nums, "cuts_total": d["cuts_total"], "host": d["host"],
                   "checks": [[n, state, det] for n, state, det in results]}, fh)
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
