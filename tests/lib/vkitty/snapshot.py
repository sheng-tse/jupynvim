"""What a terminal shows at one moment: the cell grid, styles, cursor, and the Kitty graphics
(images, draws, missing and virtual placements), with its JSON report (to_report).

Cells are tuples (text, style_id, width): width 1 for a narrow cell (text may be
" " for a blank), 2 for a wide head (text is the cluster), 0 for the spacer tail
after a wide head (text ""). A spacer head (the wide character that did not fit
at the right edge, which wrapped) reads as a blank of width 1.

The graphics follow Ghostty 1.3.1's renderer (src/renderer/image.zig): prepKittyPlacement draws a
pin whose rectangle meets the screen at its row (negative when its top rows are in history, the
renderer clips them), prepKittyVirtualPlacement draws each placeholder run at z -1, and the draws
are sorted by z, then by image id (zLessThan). A placeholder run with nothing to draw is reported
in `missing` with its reason; the runs are listed in `virtual` whatever they show.
"""
import hashlib
from dataclasses import dataclass, field

from vkitty import kgp as _kgp
from vkitty import unicode_place as _unicode_place


@dataclass
class Snapshot:
    cols: int
    rows: int
    cell_w: int
    cell_h: int
    pad: int
    cells: list                       # cells[y][x] = (text, style_id, width)
    styles: list                      # styles[style_id] = style tuple (style.py)
    # (x, y, visible, shape); shape block|underline|bar|block_hollow
    cursor: tuple
    images: dict = field(default_factory=dict)     # image id -> ImageView
    draws: list = field(default_factory=list)      # Draw, in draw order
    missing: list = field(default_factory=list)    # dicts: x, y, w, image_id, placement_id, reason
    # dicts: x, y, w, image_id, placement_id, col, row
    virtual: list = field(default_factory=list)
    warnings: list = field(default_factory=list)
    stats: dict = field(default_factory=dict)
    responses: list = field(default_factory=list)
    profile: str = "ghostty-1.4.0"
    t: object = None

    def row_text(self, y):
        """The characters of row y, spacer tails skipped (what a plain text copy gives)."""
        return "".join(text for text, _sid, width in self.cells[y] if width != 0)

    def text(self):
        return [self.row_text(y) for y in range(self.rows)]


@dataclass
class ImageView:
    """An image as the snapshot shows it: its pixels as RGBA (the displayed frame of an animated
    image), seq (the image's version stamp: the renderer's texture key), sha256 of the RGBA bytes,
    the transmission counts, and frame (the displayed frame, 1 for the root or without
    animation)."""
    id: int
    width: int
    height: int
    rgba: bytes
    seq: int
    sha256: str
    wire_bytes: int
    transmissions: int
    frame: int = 1


@dataclass
class Draw:
    """One image draw. kind is "virtual" (a placeholder run, at z -1) or "pin" (a placement at a
    cell). col and row are the cell (row negative for a pin in history); offset_x and offset_y
    are device pixels; src is (x, y, w, h) in image pixels; dest is (w, h) in device pixels."""
    image_id: int
    placement_id: int
    kind: str
    z: int
    col: int
    row: int
    offset_x: int
    offset_y: int
    src: tuple
    dest: tuple


class Graphics:
    """The graphics part of a snapshot."""

    def __init__(self):
        self.images = {}
        self.draws = []
        self.missing = []
        self.virtual = []


def _rgba_of_image(image):
    return _kgp.rgba_bytes(image)


def _view(term, image, cache):
    """The ImageView of a stored image. Its sha256 is computed once per (id, version)."""
    anim = image.anim
    if anim is not None:
        rgba = anim.shown
        frame = _anim_view_frame(image)
    else:
        rgba = None
        frame = 1
    seq = image.version
    entry = cache.get(image.id)
    if entry is None or entry[0] != seq:
        if rgba is None:
            rgba = _rgba_of_image(image)
        entry = (seq, rgba, hashlib.sha256(rgba).hexdigest())
        cache[image.id] = entry
    return ImageView(id=image.id, width=image.width, height=image.height, rgba=entry[1],
                     seq=seq, sha256=entry[2], wire_bytes=image.wire_bytes,
                     transmissions=image.transmissions, frame=frame)


def _anim_view_frame(image):
    from vkitty import anim as _anim
    return _anim.view_frame(image)


def _advance_animation(image, t):
    """Run the animation of an image up to time t. The module is imported here, so a terminal
    with no animated image (every ghostty profile one) never loads it."""
    from vkitty import anim as _anim
    _anim.advance(image, t)


def _pin_draw(term, storage, place, image, placement_id):
    """prepKittyPlacement for one pin: nothing when its rectangle lies wholly above or below the
    screen; else the draw at its screen row (negative when it starts in history), with the image's
    source rectangle and the placement's calculated size."""
    y0 = place.location.abs_y - term.active.base
    cols, rows = _kgp.grid_size(place, image, term)
    if y0 + rows - 1 < 0 or y0 > term.rows - 1:
        return None
    if _kgp.is_140(term.profile):
        # the 1.4.0 render state (Terminal render.zig template): nothing for an empty grid or an
        # empty size, the clamped source rectangle, the pixel size without the offset, and the
        # offset kept inside the first cell
        dest_w, dest_h = _kgp.pixel_size(place, image, term)
        if cols == 0 or rows == 0 or dest_w == 0 or dest_h == 0:
            return None
        off_x, off_y = _kgp.cell_offset(place, term)
        return Draw(image.id, placement_id, "pin", place.z, place.location.x, y0, off_x, off_y,
                    _kgp.source_rect(place, image), (dest_w, dest_h))
    src_x = min(image.width, place.source_x)
    src_y = min(image.height, place.source_y)
    src_w = min(image.width - src_x, place.source_width) if place.source_width > 0 else image.width
    src_h = min(image.height - src_y, place.source_height) if place.source_height > 0 \
        else image.height
    dest_w, dest_h = _kgp.calculated_size(place, image, term)
    if dest_w <= 0 or dest_h <= 0:
        return None
    return Draw(image.id, placement_id, "pin", place.z, place.location.x, y0, place.x_offset,
                place.y_offset, (src_x, src_y, src_w, src_h), (dest_w, dest_h))


def graphics(term, t):
    """The Kitty graphics of the active screen at time t (None: no animation advance). A screen
    with no image storage has no placement, so its placeholder runs (if any) are all missing."""
    out = Graphics()
    sc = term.active
    storage = sc.kitty
    pins = []
    has_virtual = False
    if storage is not None and (storage.images or storage.placements):
        if t is not None:
            for image in storage.images.values():
                if image.anim is not None:
                    _advance_animation(image, t)
        cache = term.__dict__.setdefault("_view_cache", {})
        for stale in [key for key in cache if key not in storage.images]:
            del cache[stale]
        for image_id, image in storage.images.items():
            out.images[image_id] = _view(term, image, cache)
        for (image_id, pkey), place in storage.placements.items():
            image = storage.images.get(image_id)
            if place.relative is not None:
                continue            # a relative placement (1.4.0): stored, never drawn here
            if place.location is None:
                has_virtual = True
                continue
            if image is None:
                continue
            placement_id = pkey[1] if pkey[0] == "e" else 0
            draw = _pin_draw(term, storage, place, image, placement_id)
            if draw is not None:
                pins.append(draw)
    draws = pins
    if has_virtual or _has_placeholders(sc):
        _virtual_runs(term, storage, has_virtual, draws, out)
    draws.sort(key=lambda d: (d.z, d.image_id))
    out.draws = draws
    return out


def _has_placeholders(sc):
    """True when some row of the screen holds a placeholder cell."""
    for row in sc.grid:
        for text in row.text:
            if text and text[0] == _unicode_place.PLACEHOLDER_CHAR:
                return True
    return False


def _virtual_runs(term, storage, has_virtual, draws, out):
    """Every placeholder run of the screen. Without a virtual placement in the storage Ghostty
    looks for no runs at all, so each run is reported missing for that reason."""
    for vp in _unicode_place.iterate(term.active, term.styles.styles):
        out.virtual.append({"x": vp.x, "y": vp.y, "w": vp.width, "image_id": vp.image_id,
                            "placement_id": vp.placement_id, "col": vp.col, "row": vp.row})
        if not has_virtual:
            _missing(out, vp, "no virtual placement")
            continue
        image = storage.images.get(vp.image_id)
        if image is None:
            _missing(out, vp, "image not found")
            continue
        try:
            rp = _unicode_place.render_placement(vp, storage, image, term.cell[0], term.cell[1])
        except _unicode_place.Missing as exc:
            _missing(out, vp, exc.reason)
            continue
        if rp is None or rp.dest_width == 0 or rp.dest_height == 0:
            continue
        draws.append(Draw(image.id, vp.placement_id, "virtual", -1, vp.x, vp.y, rp.offset_x,
                          rp.offset_y, (rp.source_x, rp.source_y, rp.source_width,
                                        rp.source_height),
                          (rp.dest_width, rp.dest_height)))


def _missing(out, vp, reason):
    out.missing.append({"x": vp.x, "y": vp.y, "w": vp.width, "image_id": vp.image_id,
                        "placement_id": vp.placement_id, "reason": reason})


def to_report(snap):
    """The JSON report of a snapshot: JSON-safe, with the cell, text, images, virtual and pin draws,
    missing runs, warnings, stats and responses (the bytes as text, backslash escapes for the
    rest)."""
    cx, cy, visible, shape = snap.cursor
    images = []
    for image_id in sorted(snap.images):
        view = snap.images[image_id]
        images.append({"id": view.id, "w": view.width, "h": view.height, "sha256": view.sha256,
                       "seq": view.seq, "frame": view.frame, "transmissions": view.transmissions,
                       "wire_bytes": view.wire_bytes})
    return {
        "cols": snap.cols,
        "rows": snap.rows,
        "cell": [snap.cell_w, snap.cell_h],
        "pad": snap.pad,
        "profile": snap.profile,
        "cursor": {"x": cx, "y": cy, "visible": bool(visible), "shape": shape},
        "text": snap.text(),
        "images": images,
        "virtual": [dict(entry) for entry in snap.virtual],
        "draws": [{"image_id": d.image_id, "placement_id": d.placement_id, "kind": d.kind,
                   "z": d.z, "col": d.col, "row": d.row, "offset": [d.offset_x, d.offset_y],
                   "src": list(d.src), "dest": list(d.dest)} for d in snap.draws],
        "missing": [dict(entry) for entry in snap.missing],
        "warnings": list(snap.warnings),
        "stats": snap.stats,
        "responses": [r.decode("ascii", "backslashreplace") for r in snap.responses],
    }
