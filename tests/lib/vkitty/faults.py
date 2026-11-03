"""Deliberate faults for the harness's own regression tests.

Set ``VKITTY_FAULT`` to a comma separated list of fault names. Each fault
breaks one component so that the spec cases listed in FAULTS must fail; a
run with the fault and a case that still passes means the case does not guard
that component. A fault is read where a component is built, not per byte.
"""
import os

# name -> the group/case names that must fail while the fault is active. A list holds every case
# that fails under its fault, except ten cases of the relay group that start a real relay process:
# they fail too (a relay inherits the fault) but would make the faults group start many processes
# for the same finding. They are, under no_unwrap: relay/checks_interleave_and_stats,
# relay/gfx_fifo, relay/replay_cli and relay/vt_answers_per_hop; under diacritic_shift:
# relay/replay_cli; under keep_temp: relay/hop_auto, relay/shm_unlinked,
# relay/tap_frame_chunks_live, relay/tap_rules and relay/temp_unlinked. The faults group of
# tests/vkitty_spec.py runs each list and asserts that every case in it fails.
FAULTS = {
    # the tokenizer stops recognizing DCS tmux; wrapped bodies stay DCS tokens, so no body is
    # forwarded, limited, timed out or refused. Every case that exercises the tmux hop fails under
    # it. fast_equals_slow fails only on its check that the 48-byte limit drops something, and
    # utf8_tmux_rule on the splice count of its row with a passthrough DCS inside a character (the
    # DCS is an ordinary DCS here, so a second sequence splices it).
    "no_unwrap": (
        "tokens/fast_equals_slow",
        "tokens/probe_cut",
        "tokens/multi_apc_dcs",
        "tokens/utf8_tmux_rule",
        "tokens/tmux_body_controls",
        "tokens/tmux_limit",
        "tokens/tmux_timer",
        "tokens/tmux_nested",
        "tokens/tmux_not_mux",
        "vt/passthrough_body_other",
        "vt/probe_cut_prints_tail",
        "vt/snapshot_stats_are_copies",
        "vt/tmux_dcs_counts_and_unwraps",
        "vt/tmux_discard_counters",
        "vt/tmux_timer_through_feed",
        "vt/utf8_splice_tmux",
        "kgp/apc_wire_bytes",
        "kgp/dcs_wrapped",
        "kgp/hop_rules",
        "kgp/tmux_limit_drop",
        "kgp/vt_answers_per_hop",
        "relay/recording_timer",
    ),
    # every placeholder diacritic index plus one (unicode_place.iterate); the cases that fail under
    # it are the ones that decode a row, column or high byte, and the runs that draw from them
    "diacritic_shift": (
        "place/identity",
        "place/abbreviated",
        "place/high_byte_and_palette",
        "place/placement_id",
        "place/letterbox_wide",
        "place/letterbox_tall",
        "place/partial_view",
        "place/missing_image",
        "place/z_order",
        "place/report",
        "anim/color_swap",
        "render/cursor_over_image",
        "render/image_identity",
        "render/image_letterbox",
        "render/linear_filter",
    ),
    # the renderer filters image pixels in sRGB instead of linear light
    "no_linear": ("render/linear_filter",),
    # the renderer skips every image layer (the cases that compare drawn image pixels)
    "no_images": ("render/image_identity", "render/image_letterbox", "render/linear_filter",
                  "render/alpha_blend", "render/z_layers", "render/layer_boundary",
                  "render/cursor_over_image", "render/pin_history_clip",
                  "render/texture_follows_seq"),
    # DirectMedia does not unlink temporary files and shared memory
    "keep_temp": ("media/temp_ok", "media/shm_ok_and_small", "media/shm_stat_size",
                  "media/shm_png"),
    # the ghostty-1.3.1 profile accepts the animation actions it does not implement
    "ghostty_animation": ("kgp/ghostty_rejects_animation", "anim/frame_bad_keys"),
}


def names():
    """The fault names set in VKITTY_FAULT, in order, without empty entries."""
    raw = os.environ.get("VKITTY_FAULT", "")
    return [part.strip() for part in raw.split(",") if part.strip()]


def active(name):
    """True when fault ``name`` is set in VKITTY_FAULT."""
    if name not in FAULTS:
        raise KeyError("unknown fault: %s" % name)
    return name in names()
