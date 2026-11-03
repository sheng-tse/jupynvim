"""Headless Kitty graphics harness: a byte tokenizer, a Ghostty-faithful
terminal model and pixel renderer, all in Python, with no terminal, no tmux
and no network at test time.

Modules (import them by their full name, for example ``from vkitty import
tokens``; every command-line tool in this package puts tests/lib on sys.path
first, so it runs under ``python -I``):

    tokens       byte stream to tokens (Ghostty parser and tmux passthrough)
    widths       Unicode width and grapheme break tables (Ghostty 1.3.1 rules)
    widths_data  generated tables (tools/gen_widths.py, do not edit)
    style        cell styles and the SGR parser (Ghostty sgr.zig)
    vt           the terminal model: grid, modes, cursor, mode 2027 (Ghostty)
    snapshot     what a terminal shows at one moment (Snapshot)
    charsets_dec the DEC special graphics table
    grid_tmux    tmux capture-pane dumps as snapshots, and their comparison
    battery      the VT streams of the tmux differential test
    faults       VKITTY_FAULT switches that break one component on purpose
    kgp          Kitty graphics commands, storage, transmission, responses, deletes (Ghostty 1.3.1)
    media        file, temporary file and shared memory transmissions (DirectMedia, RecordedMedia)
    unicode_place  Unicode placeholder runs and their placement (Ghostty 1.3.1 graphics_unicode.zig)
    anim         the kitty profile's animation layer: frames, coalescing, blends, a=f, a=a, a=c, d=f
    fonts        face resolution, glyph masks and the fallback chain for the renderer
    render       the renderer: the reference text renderer's drawing with Ghostty's image layers
                 (also save_png, ``from vkitty import save_png``)
    ssim         structural similarity (sigma 1.5, valid region), the renderer's score
    recording    the recording format of the relay, and replay of a recording into a terminal
    relay        the live recorder: a pty relay with FIFOs, a tap for media, a live terminal
    live         the live terminal of the relay (--respond ghostty), in a worker process of its own
    replay       replay and render command line: a recording, a stream or a capture
    testchild    a scripted child program for the relay tests
    perfclock    samples, counters and verdicts that decide a timing limit on undisturbed runs
"""

__all__ = ("tokens", "widths", "faults", "style", "vt", "snapshot", "charsets_dec",
           "grid_tmux", "battery", "kgp", "media", "fonts", "render", "ssim", "Terminal",
           "Snapshot", "parse_capture", "Recording", "save_png")

# The names Terminal, Snapshot, parse_capture, Recording and save_png load on first use (PEP 562).
# An eager import would run vt, and with it the generated width tables, every time any module of
# the package loads, so tools/gen_widths.py (which imports vkitty.widths_rules) could not
# regenerate widths_data.py from scratch.
_LAZY_EXPORTS = {
    "Terminal": "vkitty.vt",
    "Snapshot": "vkitty.snapshot",
    "parse_capture": "vkitty.grid_tmux",
    "Recording": "vkitty.recording",
    "save_png": "vkitty.render",
}


def __getattr__(name):
    module = _LAZY_EXPORTS.get(name)
    if module is None:
        raise AttributeError("module 'vkitty' has no attribute %r" % (name,))
    import importlib
    value = getattr(importlib.import_module(module), name)
    globals()[name] = value
    return value


def __dir__():
    return sorted(set(globals()) | set(_LAZY_EXPORTS))
