"""The animation layer of the kitty profile (kitty's graphics.c at commit 81535d9).

Ghostty 1.3.1 implements none of it: the ghostty profile answers nothing for a=f, a=a and a=c
(kgp._animation). Under the kitty profile an image has frames: the root frame (the image's own
pixels) and extra frames, each a full image or a rectangle over another frame (a delta). Frames are
stored as kitty stores them (3-byte pixels when opaque, else 4) and are composed when they are
shown: a delta is coalesced lazily over its base chain, so an edit of a base frame shows through
the frames built on it. The blends are kitty's integer and float32 formulas (simd-string.h).

The state of an image is AnimState (Image.anim). `current` is the index of the current frame (0 is
the root); `displayed` is the id of the frame last uploaded, with its pixels in `shown`, which the
snapshot shows (update_current_frame): an edit of a frame that is not displayed changes nothing on
screen until that frame is shown again. Frames are found by id, so a removed frame leaves no stale
reference. Time is simulated: advance(image, t) runs the frame changes of scan_active_animations at
every due time up to t.

Commands (grman_handle_command): a=f (frame_command), a=a and a=c (command), d=f and d=F
(delete_frames). Errors are answered with kitty's texts (CODE:message), through kgp._answer.
"""
import numpy as np

from vkitty import kgp as _kgp

DEFAULT_GAP = 40                  # graphics.c DEFAULT_GAP, in milliseconds
MAX_CHAIN = 32                    # get_coalesced_frame_data_impl: deeper chains give nothing
_STOPPED, _LOADING, _RUNNING = "stopped", "loading", "running"
_STATE_BY_KEY = {1: _STOPPED, 2: _LOADING, 3: _RUNNING}


class Frame:
    """A frame (graphics.c Frame). data holds width * height pixels of 3 bytes when opaque, else 4.
    base_frame_id is 0 for a standalone frame, else the id of the frame it is a delta on."""

    __slots__ = ("id", "width", "height", "x", "y", "opaque", "alpha_blend", "gap", "bgcolor",
                 "base_frame_id", "data")

    def __init__(self, frame_id, width, height, x, y, opaque, alpha_blend, gap, bgcolor,
                 base_frame_id, data):
        self.id = frame_id
        self.width = width
        self.height = height
        self.x = x
        self.y = y
        self.opaque = opaque
        self.alpha_blend = alpha_blend
        self.gap = gap
        self.bgcolor = bgcolor
        self.base_frame_id = base_frame_id
        self.data = data


class AnimState:
    """The animation state of an image (the frame fields of graphics.c Image). root is frame 1,
    extra the others in order; current is the index of the current frame (0 is the root);
    displayed is the id of the frame shown; shown_at is the time (seconds) the displayed frame
    started; duration is the sum of the gaps (milliseconds); shown is the displayed RGBA pixels."""

    __slots__ = ("root", "extra", "frame_id_counter", "current", "displayed", "state", "max_loops",
                 "current_loop", "shown_at", "duration", "is_drawn", "shown")

    def __init__(self, root):
        self.root = root
        self.extra = []
        self.frame_id_counter = root.id
        self.current = 0
        self.displayed = root.id
        self.state = _STOPPED
        self.max_loops = 0
        self.current_loop = 0
        self.shown_at = None
        self.duration = 0
        self.is_drawn = False
        self.shown = b""


class _Abort(Exception):
    """A command that fails with kitty's code and text (ABRT): the answer is CODE:text."""

    def __init__(self, code, text):
        Exception.__init__(self, text)
        self.code = code
        self.text = text


def _bpp(opaque):
    return 3 if opaque else 4


def _array(data, width, height, bpp):
    """A writable (height, width, bpp) array of a frame's bytes."""
    return np.frombuffer(bytes(data), dtype=np.uint8).reshape(height, width, bpp).copy()


def _to_rgba(opaque, data):
    """The RGBA bytes of a frame's pixels (3 bytes each when opaque, else 4)."""
    if not opaque:
        return bytes(data)
    rgb = np.frombuffer(bytes(data), dtype=np.uint8).reshape(-1, 3)
    out = np.empty((rgb.shape[0], 4), dtype=np.uint8)
    out[:, :3] = rgb
    out[:, 3] = 255
    return out.tobytes()


def _kitty_text(message):
    """A Ghostty-style MediaError message ("EINVAL: text") as kitty answers it ("EINVAL:text")."""
    code, sep, rest = message.partition(": ")
    return "%s:%s" % (code, rest) if sep else message


# ------------------------------------------------------------------ blends ---

def _div255(x):
    """simd-string.h div255_round on uint32 arrays: exact for x <= 65407."""
    y = x + 128
    return (y + (y >> 8)) >> 8


def blend_over_opaque(dst, dst_bpp, src):
    """blend_over_opaque: each colour byte of src (RGBA) over dst, in place. A 4-byte dst gets
    alpha 255. Each channel is div255_round(src * a + dst * (255 - a))."""
    a = src[..., 3].astype(np.uint32)
    ia = 255 - a
    for c in range(3):
        value = src[..., c].astype(np.uint32) * a + dst[..., c].astype(np.uint32) * ia
        dst[..., c] = _div255(value).astype(np.uint8)
    if dst_bpp == 4:
        dst[..., 3] = 255


def blend_over_straight(dst, src):
    """blend_over_straight on RGBA arrays, in place: denom = a * 255 + dst_a * (255 - a), and a zero
    denom leaves dst unchanged; a colour is lrintf((float)num / (float)denom), the float32 division
    rounded to the nearest even integer; the alpha is div255_round(denom)."""
    a = src[..., 3].astype(np.uint32)
    da = dst[..., 3].astype(np.uint32)
    ia = 255 - a
    denom = a * 255 + da * ia
    live = denom != 0
    fden = np.where(live, denom, 1).astype(np.float32)
    for c in range(3):
        num = src[..., c].astype(np.uint32) * a * 255 + dst[..., c].astype(np.uint32) * da * ia
        quotient = np.rint(num.astype(np.float32) / fden)
        dst[..., c] = np.where(live, quotient, dst[..., c].astype(np.float32)).astype(np.uint8)
    dst[..., 3] = np.where(live, _div255(denom), da).astype(np.uint8)


def copy_or_blend(dst, src, under_bpp, over_bpp, needs_blending):
    """copy_or_blend_row on blocks of pixels, in place on dst: a straight over blend for an RGBA
    source when blending, an opaque over blend onto 3-byte pixels, else a copy of the colours (the
    alpha is 255 when a 3-byte source is copied onto 4-byte pixels)."""
    if needs_blending and over_bpp == 4:
        if under_bpp == 4:
            blend_over_straight(dst, src)
        else:
            blend_over_opaque(dst, 3, src)
        return
    dst[..., 0:3] = src[..., 0:3]
    if under_bpp == 4:
        dst[..., 3] = src[..., 3] if over_bpp == 4 else 255


def compose(under, over, offset_x, offset_y, needs_blending):
    """compose: the over frame placed at (offset_x, offset_y) of the under frame, clipped to
    both."""
    uh, uw = under.shape[0], under.shape[1]
    oh, ow = over.shape[0], over.shape[1]
    if offset_x >= uw or offset_y >= uh:
        return
    rows = min(oh, uh - offset_y)
    cols = min(ow, uw - offset_x)
    if rows <= 0 or cols <= 0:
        return
    copy_or_blend(under[offset_y:offset_y + rows, offset_x:offset_x + cols],
                  over[:rows, :cols], under.shape[2], over.shape[2], needs_blending)


def compose_rectangles(under, over, width, height, src_x, src_y, dst_x, dst_y, needs_blending):
    """compose_rectangles: a width x height rectangle of over (at src) composed onto under (at dst),
    both full images. The source is copied first, so the rectangles may share a frame (a=c refuses
    overlapping rectangles of one frame)."""
    block = over[src_y:src_y + height, src_x:src_x + width].copy()
    copy_or_blend(under[dst_y:dst_y + height, dst_x:dst_x + width], block, under.shape[2],
                  over.shape[2], needs_blending)


# ----------------------------------------------------------- coalescing ---

def frame_for_id(anim, frame_id):
    if anim.root.id == frame_id:
        return anim.root
    for frame in anim.extra:
        if frame.id == frame_id:
            return frame
    return None


def frame_for_number(anim, number):
    """frame_for_number: 1 is the root, 2 and up the extra frames; 0 and the missing ones are
    None."""
    if number == 1:
        return anim.root
    if number == 0:
        return None
    if number - 2 < len(anim.extra):
        return anim.extra[number - 2]
    return None


def _frame_at(anim, index):
    return anim.root if index == 0 else anim.extra[index - 1]


def _index_of_id(anim, frame_id):
    """0 for the root, else the position of the extra frame plus one; None when it is not there."""
    if anim.root.id == frame_id:
        return 0
    for i, frame in enumerate(anim.extra):
        if frame.id == frame_id:
            return i + 1
    return None


def _standalone(width, height, frame):
    """get_coalesced_frame_data_standalone: a full frame is its own pixels; any other frame is
    composed onto its background colour (transparent black when it has none)."""
    if frame.width == width and frame.height == height and frame.x == 0 and frame.y == 0:
        return frame.opaque, frame.data
    bpp = _bpp(frame.opaque)
    base = np.zeros((height, width, bpp), dtype=np.uint8)
    if frame.bgcolor:
        bg = frame.bgcolor
        base[..., 0] = (bg >> 24) & 0xFF
        base[..., 1] = (bg >> 16) & 0xFF
        base[..., 2] = (bg >> 8) & 0xFF
        if bpp == 4:
            base[..., 3] = bg & 0xFF
    over = _array(frame.data, frame.width, frame.height, bpp)
    compose(base, over, frame.x, frame.y, frame.alpha_blend and not frame.opaque)
    return frame.opaque, base.tobytes()


def coalesce(anim, width, height, frame, count=0):
    """get_coalesced_frame_data_impl: the full pixels of a frame as (opaque, bytes), composed
    lazily over its base chain. None when the chain is broken or deeper than MAX_CHAIN."""
    if count > MAX_CHAIN:
        return None
    if not frame.base_frame_id:
        return _standalone(width, height, frame)
    base = frame_for_id(anim, frame.base_frame_id)
    if base is None:
        return None
    got = coalesce(anim, width, height, base, count + 1)
    if got is None:
        return None
    base_opaque, base_bytes = got
    under = _array(base_bytes, width, height, _bpp(base_opaque))
    over = _array(frame.data, frame.width, frame.height, _bpp(frame.opaque))
    compose(under, over, frame.x, frame.y, frame.alpha_blend and not frame.opaque)
    return base_opaque, under.tobytes()


def _reference_chain_too_large(anim, width, height, frame):
    """reference_chain_too_large: the chain from the frame draws less than twice the image's area,
    in fewer than five frames (kitty then makes the new frame a key frame)."""
    limit = width * height * 2
    drawn = frame.width * frame.height
    num = 1
    while drawn < limit and num < 5:
        if not frame.base_frame_id:
            break
        nxt = frame_for_id(anim, frame.base_frame_id)
        if nxt is None:
            break
        frame = nxt
        drawn += frame.width * frame.height
        num += 1
    return num >= 5 or drawn >= limit


# ------------------------------------------------------------- state ---

def _anim_for(image, has_placement):
    """The animation state of an image, made on first use. Its root frame is the image's pixels:
    opaque for 3-byte RGB data (f=24), not for RGBA or PNG (stored as RGBA). is_drawn starts as
    whether the image has a placement (kitty sets it when the image is rendered)."""
    if image.anim is None:
        root = Frame(1, image.width, image.height, 0, 0, image.format == "rgb", False, 0, 0, 0,
                     bytes(image.data))
        state = AnimState(root)
        state.shown = _to_rgba(root.opaque, root.data)
        state.is_drawn = bool(has_placement)
        image.anim = state
    return image.anim


def _current_frame(anim):
    return _frame_at(anim, anim.current)


def _update_current(anim, image, now):
    """update_current_frame: the current frame becomes the displayed one, its pixels are uploaded
    (the shown bytes and a new version stamp for the renderer) and its timer starts at now."""
    frame = _current_frame(anim)
    anim.displayed = frame.id
    got = coalesce(anim, image.width, image.height, frame)
    if got is not None:
        anim.shown = _to_rgba(*got)
    if now is not None:
        anim.shown_at = now
    image.version = next(_kgp._SEQ)


def _show_timer_frame(anim, image):
    """A frame change by the timer: the displayed frame changes only when the id does. A due frame
    that is the one already shown needs no upload, so its version stamp stays."""
    if _current_frame(anim).id == anim.displayed:
        return
    _update_current(anim, image, None)


def change_gap(anim, frame, gap):
    """change_gap: the frame's gap (never negative), and the animation's duration with it."""
    anim.duration = _less_gap(frame.gap, anim.duration)
    frame.gap = max(0, gap)
    anim.duration += frame.gap


def _less_gap(prev, duration):
    return duration - prev if prev < duration else 0


def _animatable(anim):
    """image_is_animatable: not stopped, with extra frames, drawn, a duration, and loops left."""
    return (anim.state != _STOPPED and bool(anim.extra) and anim.is_drawn
            and anim.duration > 0 and (not anim.max_loops or anim.current_loop < anim.max_loops))


def advance(image, t):
    """scan_active_animations for one image, as if kitty's render loop ran at every due time up to
    t. A frame is due at shown_at plus its gap; then the animation moves to the next frame, past
    frames with no gap, and a loop ends the run (while loading, it stops at the last frame). The new
    frame starts at its due time, which is when kitty's scan would show it. Without a time nothing
    moves; the first time given starts the clock."""
    anim = image.anim
    if anim is None or t is None:
        return False
    if anim.shown_at is None:
        anim.shown_at = t
        return False
    if not _animatable(anim):
        return False
    changed = False
    while _animatable(anim):
        frame = _current_frame(anim)
        due = anim.shown_at + frame.gap / 1000.0
        if t < due:
            break
        n = len(anim.extra)
        stop = False
        while True:
            nxt = (anim.current + 1) % (n + 1)
            if nxt == 0:
                if anim.state == _LOADING:
                    stop = True
                    break
                anim.current_loop += 1
                if anim.current_loop >= anim.max_loops and anim.max_loops:
                    stop = True
                    break
            anim.current = nxt
            if _frame_at(anim, nxt).gap:
                break
        if stop:
            break
        anim.shown_at = due
        _show_timer_frame(anim, image)
        changed = True
    return changed


def view_frame(image):
    """The frame number the snapshot shows (1 is the root): the displayed frame's position."""
    anim = image.anim
    if anim is None:
        return 1
    index = _index_of_id(anim, anim.displayed)
    if index is None:
        index = anim.current
    return index + 1


# -------------------------------------------------------------- commands ---

def _find_image(storage, image_id, number):
    """The image an animation command names: by id (i), else by number (I)."""
    if image_id:
        return storage.images.get(image_id)
    if number:
        return storage.image_by_number(number)
    return None


def _missing_image(kv, frame=True):
    """The answer for a command that names no stored image. kitty's finish_command_response
    prints r only for a=f and a=a, so an a=c answer passes frame=False."""
    text = ("ENOENT:Animation command refers to non-existent image with id: %d and number: %d"
            % (kv.get("i", 0), kv.get("I", 0)))
    return _kgp.Resp(kv.get("i", 0), kv.get("I", 0), 0, text, kv.get("r", 0) if frame else 0)


def _has_placement(storage, image):
    return any(key[0] == image.id for key in storage.placements)


def _answer_ids(kv, start):
    """The i and I an answer carries: the command's own, or, for a chunk that names neither, those
    of the chunk that started the load (grman_handle_command copies them for a continuation)."""
    if kv.get("i", 0) or kv.get("I", 0):
        return kv.get("i", 0), kv.get("I", 0)
    return start.get("i", 0), start.get("I", 0)


def frame_command(term, storage, cmd, key):
    """a=f (handle_animation_frame_load_command, with its chunks). The first chunk names the image
    and the frame: r is the frame number (0 or past the last one means a new frame). Its data is
    loaded through the media layer like a transmission. Complete data becomes a new frame (base c,
    gap z with a default of 40 ms, blend mode X, background Y, offsets x and y) or replaces frame r
    composed over its old pixels. Returns the answer, or None while chunks are still expected.

    While a load is in progress, a chunk with no t or t=d continues it (is_chunked_continuation):
    f, o, s, v and every other key are the first chunk's (INIT_CHUNKED_LOAD), so only m is read
    and none of its own keys can be refused. A chunk with another t starts a new load for the
    image of the one in progress, which is dropped, and is checked like a first chunk."""
    pending = storage.loading if storage.loading is not None and storage.loading.action == "f" \
        else None
    if pending is not None and cmd.kv.get("t", _kgp.FRAME_DIRECT) == _kgp.FRAME_DIRECT:
        loading = pending
        info = loading.frame
        try:
            loading.wire += cmd.wire
            loading.add_data(cmd.data)
        except _kgp.MediaError as exc:
            storage.loading = None
            rid, rnum = _answer_ids(cmd.kv, info["kv"])
            return _kgp.Resp(rid, rnum, 0, _kitty_text(exc.message), info["number"])
        if cmd.kv.get("m", 0) > 0:
            return None
        storage.loading = None
        reply = _answer_ids(cmd.kv, info["kv"])
    else:
        start = {}
        if pending is not None:
            storage.loading = None
            image = pending.frame["image"]
            start = pending.frame["kv"]
        else:
            image = _find_image(storage, cmd.kv.get("i", 0), cmd.kv.get("I", 0))
            if image is None:
                return _missing_image(cmd.kv)
        rid, rnum = reply = _answer_ids(cmd.kv, start)
        anim = _anim_for(image, _has_placement(storage, image))
        advance(image, term._now)
        number = cmd.kv.get("r", 0)
        if not number or number > len(anim.extra) + 2:
            number = len(anim.extra) + 2
        _kgp.frame_default_format(cmd.kv)
        bad = _kgp.frame_key_error(cmd.kv)
        if bad is not None:
            text, with_given_r = bad
            return _kgp.Resp(rid, rnum, 0, text, cmd.kv.get("r", 0) if with_given_r else number)
        try:
            loading = _kgp.LoadingImage.start(term, cmd, key, count_media=False)
        except _kgp.MediaError as exc:
            return _kgp.Resp(rid, rnum, 0, _kitty_text(exc.message), number)
        loading.action = "f"
        info = {"kv": dict(cmd.kv), "image": image, "number": number,
                "new": number == len(anim.extra) + 2}
        loading.frame = info
        if loading.medium == "d" and cmd.kv.get("m", 0) > 0:
            storage.loading = loading
            return None
    kv = info["kv"]
    image = info["image"]
    anim = _anim_for(image, _has_placement(storage, image))
    advance(image, term._now)
    # the frame's chunks are image data on the wire: they add to the image's own wire bytes (the
    # total and the count since a mark were counted chunk by chunk, in kgp.execute)
    entry = term.stats["by_image"].setdefault(
        str(image.id), {"transmissions": 0, "wire_bytes": 0, "medium": loading.medium})
    entry["wire_bytes"] += loading.wire
    try:
        _finish_frame(term, anim, image, loading.complete(), kv, info["number"], info["new"],
                      term._now)
    except _Abort as exc:
        return _kgp.Resp(reply[0], reply[1], 0, "%s:%s" % (exc.code, exc.text), info["number"])
    except _kgp.MediaError as exc:
        return _kgp.Resp(reply[0], reply[1], 0, _kitty_text(exc.message), info["number"])
    return _kgp.Resp(reply[0], reply[1], 0, "OK", info["number"])


def _finish_frame(term, anim, image, data, kv, number, is_new, now):
    """Store complete a=f data (data is a LoadingImage's Image): a new frame or the edit of frame
    number. Raises _Abort with kitty's text for the failures handle_animation_frame_load_command
    names."""
    if data.width > image.width:
        raise _Abort("EINVAL", "Frame width %d larger than image width: %d"
                     % (data.width, image.width))
    if data.height > image.height:
        raise _Abort("EINVAL", "Frame height %d larger than image height: %d"
                     % (data.height, image.height))
    opaque = data.format == "rgb"
    blend = kv.get("X", 0) != 1 and not opaque
    gap_key = kv.get("z", 0)
    gap = gap_key if gap_key > 0 else (0 if gap_key < 0 else DEFAULT_GAP)
    x = kv.get("x", 0)
    y = kv.get("y", 0)
    if is_new:
        anim.frame_id_counter += 1
        frame = Frame(anim.frame_id_counter, data.width, data.height, x, y, opaque, blend, gap,
                      kv.get("Y", 0), 0, data.data)
        other = kv.get("c", 0)
        if other:
            base = frame_for_number(anim, other)
            if base is None:
                raise _Abort("EINVAL", "No frame with number: %d found" % other)
            if base.base_frame_id and _reference_chain_too_large(anim, image.width, image.height,
                                                                 base):
                # a long chain is cut here: the new frame is stored as a full key frame
                got = coalesce(anim, image.width, image.height, base)
                if got is None:
                    raise _Abort("EINVAL", "Failed to get data from frame referenced by frame: %d"
                                 % number)
                base_opaque, base_bytes = got
                under = _array(base_bytes, image.width, image.height, _bpp(base_opaque))
                over = _array(frame.data, frame.width, frame.height, _bpp(frame.opaque))
                compose(under, over, frame.x, frame.y, frame.alpha_blend and not frame.opaque)
                frame.data = under.tobytes()
                frame.width = image.width
                frame.height = image.height
                frame.x = 0
                frame.y = 0
                frame.opaque = base_opaque
            else:
                frame.base_frame_id = base.id
        anim.extra.append(frame)
        anim.duration += frame.gap
        return
    frame = frame_for_number(anim, number)
    if frame is None:
        raise _Abort("EINVAL", "No frame with number: %d found" % number)
    if kv.get("z", 0) != 0:
        change_gap(anim, frame, gap)
    got = coalesce(anim, image.width, image.height, frame)
    if got is None:
        raise _Abort("EINVAL", "No data associated with frame number: %d" % number)
    base_opaque, base_bytes = got
    under = _array(base_bytes, image.width, image.height, _bpp(base_opaque))
    over = _array(data.data, data.width, data.height, _bpp(opaque))
    compose(under, over, x, y, blend)
    frame.data = under.tobytes()
    frame.alpha_blend = False
    frame.base_frame_id = 0
    frame.bgcolor = 0
    frame.opaque = base_opaque
    frame.x = 0
    frame.y = 0
    frame.width = image.width
    frame.height = image.height
    if frame.id == _current_frame(anim).id:
        _update_current(anim, image, now)


def _control(term, storage, cmd):
    """a=a (handle_animation_control_command): a gap (r with z), the current frame (c), the state
    (s: 1 stopped, 2 loading, 3 running; a start sets the clock) and the loop count (v, which is one
    more than the loops). It has no answer unless the image is missing."""
    kv = cmd.kv
    image = _find_image(storage, kv.get("i", 0), kv.get("I", 0))
    if image is None:
        return _missing_image(kv)
    anim = _anim_for(image, _has_placement(storage, image))
    advance(image, term._now)
    r = kv.get("r", 0)
    if r:
        index = r - 1
        if index <= len(anim.extra) and kv.get("z", 0):
            change_gap(anim, _frame_at(anim, index), kv.get("z", 0))
    c = kv.get("c", 0)
    if c:
        index = c - 1
        if index != anim.current and index <= len(anim.extra):
            anim.current = index
            _update_current(anim, image, term._now)
    s = kv.get("s", 0)
    if s:
        old = anim.state
        anim.state = _STATE_BY_KEY[s]
        if anim.state == _STOPPED:
            anim.current_loop = 0
        elif old == _STOPPED:
            # kitty also sets is_drawn here (graphics.c), but the next render pass derives it from
            # the image's placements again, so an image with none stops at once: only a placement
            # sets it here
            if term._now is not None:
                anim.shown_at = term._now
        anim.current_loop = 0
    v = kv.get("v", 0)
    if v:
        anim.max_loops = v - 1
    return None


def _compose(term, storage, cmd):
    """a=c (handle_compose_command): the rectangle of frame r (source; X, Y in it) is copied (C
    other than 0) or blended (C=0, when the source is not opaque) onto frame c at x, y. The
    destination becomes a full frame holding the result. Answers OK, or kitty's error text."""
    kv = cmd.kv
    image = _find_image(storage, kv.get("i", 0), kv.get("I", 0))
    if image is None:
        return _missing_image(kv, frame=False)
    anim = _anim_for(image, _has_placement(storage, image))
    advance(image, term._now)
    rid = kv.get("r", 0)
    cid = kv.get("c", 0)
    image_id = kv.get("i", 0)
    number = kv.get("I", 0)
    src = frame_for_number(anim, rid)
    if src is None:
        return _kgp.Resp(image_id, number, 0,
                         "ENOENT:No source frame number %d exists in image id: "
                         "%d\n" % (rid, image.id))
    dest = frame_for_number(anim, cid)
    if dest is None:
        return _kgp.Resp(image_id, number, 0,
                         "ENOENT:No destination frame number %d exists in image "
                         "id: %d\n" % (cid, image.id))
    width = kv.get("w", 0) or image.width
    height = kv.get("h", 0) or image.height
    dest_x = kv.get("x", 0)
    dest_y = kv.get("y", 0)
    src_x = kv.get("X", 0)
    src_y = kv.get("Y", 0)
    W, H = image.width, image.height
    try:
        if dest_x + width > W or dest_y + height > H:
            raise _Abort("EINVAL", "The destination rectangle is out of bounds")
        if src_x + width > W or src_y + height > H:
            raise _Abort("EINVAL", "The source rectangle is out of bounds")
        if src is dest:
            x_overlaps = max(src_x, dest_x) < min(src_x, dest_x) + width
            y_overlaps = max(src_y, dest_y) < min(src_y, dest_y) + height
            if x_overlaps and y_overlaps:
                raise _Abort("EINVAL", "The source and destination rectangles overlap and the src "
                             "and destination frames are the same")
        got_src = coalesce(anim, W, H, src)
        if got_src is None:
            raise _Abort("EINVAL", "Failed to get data for src frame: %d" % (rid - 1))
        got_dst = coalesce(anim, W, H, dest)
        if got_dst is None:
            raise _Abort("EINVAL", "Failed to get data for destination frame: %d" % (cid - 1))
    except _Abort as exc:
        return _kgp.Resp(image_id, number, 0, "%s:%s" % (exc.code, exc.text))
    src_opaque, src_bytes = got_src
    dst_opaque, dst_bytes = got_dst
    copy_mode = kv.get("C", 0) != 0         # compose_mode: any C other than 0 copies
    under = _array(dst_bytes, W, H, _bpp(dst_opaque))
    over = _array(src_bytes, W, H, _bpp(src_opaque))
    compose_rectangles(under, over, width, height, src_x, src_y, dest_x, dest_y,
                       not copy_mode and not src_opaque)
    dest.x = 0
    dest.y = 0
    dest.width = W
    dest.height = H
    dest.base_frame_id = 0
    dest.bgcolor = 0
    dest.opaque = dst_opaque
    dest.alpha_blend = False
    dest.data = under.tobytes()
    if dest.id == _current_frame(anim).id:
        _update_current(anim, image, term._now)
    return _kgp.Resp(image_id, number, 0, "OK")


def command(term, storage, cmd, key):
    """a=a and a=c."""
    if cmd.action == "a":
        return _control(term, storage, cmd)
    return _compose(term, storage, cmd)


def delete_frames(term, storage, d):
    """d=f and d=F (handle_delete_frame_command). Without extra frames d=F frees the image and d=f
    does nothing. Otherwise one frame goes: frame r (1 is the root; a missing or zero r means 1,
    and past the last one means the last one). The frames built on it become key frames first;
    the duration drops by its gap; the current index follows the frames that move."""
    image = _find_image(storage, d.image_id, d.image_number)
    if image is None:
        return
    anim = image.anim
    if anim is None or not anim.extra:
        if d.delete:
            storage.remove_image(image.id)
        return
    advance(image, term._now)
    W, H = image.width, image.height
    number = min(len(anim.extra) + 1, d.frame)
    if not number:
        number = 1
    remove_root = number == 1
    position = 0 if remove_root else number - 1     # the removed frame's index
    victim_id = _frame_at(anim, position).id
    for frame in anim.extra:
        if frame.base_frame_id != victim_id:
            continue
        got = coalesce(anim, W, H, frame)
        if got is None:
            continue
        frame.opaque, frame.data = got
        frame.alpha_blend = False
        frame.base_frame_id = 0
        frame.bgcolor = 0
        frame.x = 0
        frame.y = 0
        frame.width = W
        frame.height = H
    if remove_root:
        removed_gap = anim.root.gap
        anim.root = anim.extra.pop(0)
    else:
        removed_gap = anim.extra.pop(position - 1).gap
    anim.duration = _less_gap(removed_gap, anim.duration)
    # update_current_frame restarts the shown time: a new current frame starts now
    if anim.current > len(anim.extra):
        anim.current = len(anim.extra)
        _update_current(anim, image, term._now)
        return
    if anim.current > position:
        anim.current -= 1
    elif anim.current == position:
        _update_current(anim, image, term._now)
