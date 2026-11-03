"""The Kitty graphics protocol core: command parsing, transmission and completion, image
storage, placements, responses and deletes. Ported from Ghostty 1.3.1 and 1.4.0 (paths relative
to their src/):

    terminal/kitty/graphics_command.zig  Parser (feed, complete, decodeData), Response.encode,
                                         the Transmission, Display and Delete views
    terminal/kitty/graphics_exec.zig     execute, query, transmit, display, delete, quiet rules
    terminal/kitty/graphics_image.zig    LoadingImage (init, addData, complete), PNG, zlib
    terminal/kitty/graphics_storage.zig  ImageStorage: eviction, placements, every delete
    terminal/Terminal.zig                setCursorPos after a pin display (C=0)
    simd/base64.cpp                      base64 as the simd build decodes it (simdutf 5.2.8)
    std/png/decode_png.wuffs             PNG chunks, CRCs and the zlib end (wuffs 0.4.0-alpha.9,
                                         the decoder pkg/wuffs pins)

parse() raises ParseError for a command Ghostty's parser rejects: nothing is answered, a
warning is added and no state changes (apc.zig logs and drops it). execute() returns the
answer bytes or None; the caller sends them.

Profiles (Terminal.profile): "ghostty-1.4.0" (DEFAULT_PROFILE, of the relay, the replay tool and
the screen test) and "ghostty-1.3.1" (Terminal's own default) reproduce those two Ghostty
releases; the README's Profiles section lists where 1.4.0 differs (a retransmission
removes the old image and its placements, eviction, deletes, parser rules, placement geometry,
and the animation actions, which run the layer of anim.py). Under "ghostty-1.3.1" animation
actions are not implemented (they answer nothing and warn), d=r removes every placement, and an
unfinished chunked load survives every delete. "kitty" deletes only the placements of the range,
drops an unfinished chunked load on any delete, and runs the animation layer of anim.py (kitty
81535d9).

Pins: a pin is a PinRef(abs_y, x). abs_y is a row of the screen's
absolute row space: Screen.base counts the rows the active area has moved down, so the screen row
of a pin is abs_y - base, negative when the row is in history. vt.py adjusts abs_y with each
operation, as Ghostty's tracked pins move in PageList.
"""
import base64
import binascii
import io
import itertools
import math
import re
import struct
import zlib

from vkitty import faults
from vkitty.media import MediaError


GHOSTTY_131 = "ghostty-1.3.1"       # the oldest Ghostty the plugin supports (1.3 and later)
GHOSTTY_140 = "ghostty-1.4.0"       # the current Ghostty release, the default of the relay
GHOSTTY = GHOSTTY_131               # the name this module used before there were two versions
KITTY = "kitty"
PROFILES = (GHOSTTY_140, GHOSTTY_131, KITTY)
DEFAULT_PROFILE = GHOSTTY_140       # of the relay, the replay tool and the screen tests


def is_ghostty(profile):
    """Either Ghostty profile (not kitty)."""
    return profile in (GHOSTTY_131, GHOSTTY_140)


def is_140(profile):
    """Ghostty 1.4.0 behavior (the profile of the current release)."""
    return profile == GHOSTTY_140


MAX_DIMENSION = 10000              # graphics_image.zig max_dimension (Kitty's limit)
MAX_SIZE = 400 * 1024 * 1024       # graphics_image.zig max_size
MAX_APC_BYTES = 65 * 1024 * 1024   # 1.4.0 apc.zig Protocol.defaultMaxBytes(.kitty): the data of one
                                   # command; a longer one is dropped whole, with no answer
MAX_VALUE_CHARS = 11               # graphics_command.zig kv_temp: a longer value is ignored
PARENT_CHAIN_LIMIT = 8             # 1.4.0 graphics_storage.zig parent_chain_limit
FIRST_IMAGE_ID = 2147483647        # graphics_storage.zig next_image_id (the automatic ids)
DEFAULT_STORAGE_LIMIT = 320000000  # graphics_storage.zig total_limit (320 MB)
_U32 = 0xFFFFFFFF
_I32_MIN, _I32_MAX = -(2 ** 31), 2 ** 31 - 1
_SIGNED_KEYS = ("z", "H", "V")     # stored as i32 (the other numeric keys are u32)
_ACTIONS = {ord(c): c for c in "qtTpdfac"}
_FORMATS = {24: "rgb", 32: "rgba", 100: "png"}
_MEDIUMS = {ord("d"): "d", ord("f"): "f", ord("t"): "t", ord("s"): "s"}
_BPP = {"rgb": 3, "rgba": 4, "gray": 1, "gray_alpha": 2}
_DELETE_KINDS = {"a": "all", "i": "id", "n": "newest", "c": "cursor", "f": "frames",
                 "p": "cell", "q": "cell_z", "r": "range", "x": "column", "y": "row", "z": "z"}

# parser states (graphics_command.zig State)
_CONTROL_KEY, _CONTROL_KEY_IGNORE, _CONTROL_VALUE, _CONTROL_VALUE_IGNORE, _DATA = range(5)
_EQUALS, _SEMI, _COMMA = 0x3D, 0x3B, 0x2C
_EQUALS_RE = re.compile(rb"=")
_SEPARATOR_RE = re.compile(rb"[,;]")
_DIGITS_RE = re.compile(rb"[0-9]+(?:_+[0-9]+)*")   # digits, with '_' only between them
_GRAY16_MODES = ("I;16", "I;16B", "I;16L", "I")     # Pillow's modes of a 16-bit gray PNG


class ParseError(Exception):
    """A command the parser rejects (graphics_command.zig error.InvalidFormat or InvalidData)."""


# ------------------------------------------------------------------ parsing ---

def _parse_int(text, signed):
    """std.fmt.parseInt(T, text, 10) as Zig 0.15.2 has it (lib/std/fmt.zig, parseIntWithSign): an
    optional '+' or '-', then decimal digits, where '_' may separate digits but never starts or
    ends the value. A '-' on an unsigned type parses only when every digit is zero (Zig's first
    digit cast to the unsigned type fails otherwise, so -0 is 0 and -1 is an overflow). The value
    must fit the type: i32 for z, H and V, u32 for the other numeric keys."""
    body = bytes(text)
    negative = False
    if body[:1] == b"+":
        body = body[1:]
    elif body[:1] == b"-":
        negative = True
        body = body[1:]
    if _DIGITS_RE.fullmatch(body) is None:
        raise ParseError("invalid integer")
    value = int(body.replace(b"_", b""))
    if negative:
        if not signed:
            if value != 0:
                raise ParseError("integer out of range")
            return 0
        value = -value
    low, high = (_I32_MIN, _I32_MAX) if signed else (0, _U32)
    if not low <= value <= high:
        raise ParseError("integer out of range")
    return value


def _store(kv, key, text):
    """finishValue: one non-digit character is stored as its code; anything else is an integer."""
    if len(text) == 1 and not 0x30 <= text[0] <= 0x39:
        kv[key] = text[0]
        return
    kv[key] = _parse_int(bytes(text), key in _SIGNED_KEYS)


# the bytes simdutf skips in a base64 payload (not \v); a form feed has the arm64 exception below
_B64_SKIPPED = b" \t\n\f\r"

# The simdutf kernel the model follows: Ghostty 1.3.1 on arm64 (macOS on an M series chip). Its
# arm64 kernel refuses a form feed inside the part it decodes in 64 character blocks; the x86
# kernels (westmere, haswell) skip it anywhere. _decode_data(raw, arch="x86") selects the second.
_B64_ARCH = "arm64"


def _b64_trimmed_length(raw):
    """simdutf's srclen: the length of raw once its end is trimmed in simdutf's order: trailing
    ASCII white space, then one '=', then white space, then a second '=', and nothing after that.
    White space to the left of the second '=' stays in the length."""
    end = len(raw)
    while end and raw[end - 1] in _B64_SKIPPED:
        end -= 1
    if end and raw[end - 1] == 0x3D:
        end -= 1
        while end and raw[end - 1] in _B64_SKIPPED:
            end -= 1
        if end and raw[end - 1] == 0x3D:
            end -= 1
    return end


def _decode_data(raw, arch=None):
    """decodeData, as Ghostty's simd build decodes it: simdutf 5.2.8 base64_to_binary with its
    default options (simd/base64.cpp). ASCII spaces, tabs, line feeds and carriage returns are
    skipped anywhere, and so are form feeds, with one exception: the arm64 kernel refuses a form
    feed at an index p below 64 * (srclen // 64), srclen being the payload length with its end
    trimmed in simdutf's order (_b64_trimmed_length; the x86 kernels skip it anywhere; `arch` is
    "arm64" or "x86", default _B64_ARCH). Up to two '=' may end the input, and when there are
    any, the base64 characters plus the '=' count a multiple of 4. A body of 1 mod 4 characters
    is invalid.
    Trailing bits are not checked. A payload of nothing but skipped bytes decodes to nothing."""
    if not raw:
        return b""
    if (arch or _B64_ARCH) == "arm64":
        ff = raw.find(b"\x0c")
        if ff >= 0 and ff < 64 * (_b64_trimmed_length(raw) // 64):
            raise ParseError("EINVAL: invalid data")
    data = raw.translate(None, _B64_SKIPPED)
    body = data.rstrip(b"=")
    pad = len(data) - len(body)
    if pad > 2 or (pad and (len(body) + pad) % 4) or len(body) % 4 == 1:
        raise ParseError("EINVAL: invalid data")
    try:
        return base64.b64decode(body + b"=" * (-len(body) % 4), validate=True)
    except (binascii.Error, ValueError):
        raise ParseError("EINVAL: invalid data")


def parse(payload, kitty=False, continuing=False, v14=False):
    """Parse one graphics command. payload is the APC payload after its G (the key=value pairs,
    then ';' and the data). Returns a Command, or raises ParseError. `kitty` is the kitty profile:
    its a=c takes any C (a compose mode is a number there), where Ghostty's parser takes 0 or 1.
    `continuing` says an a=f load is in progress on the screen (kitty profile): kitty sends a
    chunk with no action key to that load, which reads only its m (graphics.c grman_handle_command
    and INIT_CHUNKED_LOAD), so the transmission keys of such a chunk are not looked at. `v14` is
    the ghostty-1.4.0 profile: its parser takes any q (above 1 is quiet), any C (only 1 keeps the
    cursor) and any U (non-zero is virtual), reads f=0 as RGBA and defers an unknown format to the
    load (EINVAL: unsupported format), has the N usage hint, takes an inverted or missing delete
    range as one that selects nothing, and drops a command whose data is over 65 MiB."""
    if not isinstance(payload, bytes):
        payload = bytes(payload)
    size = len(payload)
    kv = {}
    temp = bytearray()
    state = _CONTROL_KEY
    current = ""
    data_start = size
    pos = 0
    while pos < size and state != _DATA:
        if state == _CONTROL_KEY:
            c = payload[pos]
            pos += 1
            if c == _EQUALS:
                if len(temp) != 1:
                    state = _CONTROL_VALUE_IGNORE
                    temp = bytearray()
                else:
                    current = chr(temp[0])
                    temp = bytearray()
                    state = _CONTROL_VALUE
            elif c == _SEMI:
                state = _DATA
                data_start = pos
            elif len(temp) >= MAX_VALUE_CHARS:
                state = _CONTROL_KEY_IGNORE
                temp = bytearray()
            else:
                temp.append(c)
        elif state == _CONTROL_KEY_IGNORE:
            match = _EQUALS_RE.search(payload, pos)
            if match is None:
                pos = size
            else:
                pos = match.end()
                state = _CONTROL_VALUE_IGNORE
        elif state == _CONTROL_VALUE:
            c = payload[pos]
            pos += 1
            if c == _COMMA:
                _store(kv, current, temp)
                temp = bytearray()
                state = _CONTROL_KEY
            elif c == _SEMI:
                _store(kv, current, temp)
                temp = bytearray()
                state = _DATA
                data_start = pos
            elif len(temp) >= MAX_VALUE_CHARS:
                state = _CONTROL_VALUE_IGNORE
                temp = bytearray()
            else:
                temp.append(c)
        else:  # _CONTROL_VALUE_IGNORE
            match = _SEPARATOR_RE.search(payload, pos)
            if match is None:
                pos = size
            else:
                pos = match.end()
                if payload[match.start()] == _COMMA:
                    state = _CONTROL_KEY_IGNORE
                else:
                    state = _DATA
                    data_start = pos
    # complete(): a command that ends in a key is invalid; one that ends in a value takes it
    if state == _CONTROL_KEY or state == _CONTROL_KEY_IGNORE:
        raise ParseError("invalid format")
    if state == _CONTROL_VALUE:
        _store(kv, current, temp)
        state = _DATA
        data_start = size
    raw = payload[data_start:] if state == _DATA else b""
    if v14 and len(raw) > MAX_APC_BYTES:
        raise ParseError("OutOfMemory: the data is over %d bytes" % MAX_APC_BYTES)

    action_code = kv.get("a")
    if action_code is None:
        action = "t"
    else:
        if action_code > 255 or action_code not in _ACTIONS:
            raise ParseError("unknown action")
        action = _ACTIONS[action_code]
    quiet = kv.get("q", 0)
    if v14:
        quiet = min(quiet, 2)           # Kitty allows anything above 1 to suppress
    elif quiet not in (0, 1, 2):
        raise ParseError("q outside 0..2")

    transmission = display = delete = animation = None
    if action in ("q", "t"):
        if not (continuing and action_code is None):
            transmission = _transmission(kv, v14)
    elif action == "T":
        transmission = _transmission(kv, v14)
        display = _display_view(kv, v14)
    elif action == "p":
        display = _display_view(kv, v14)
    elif action == "d":
        delete = _delete(kv, v14)
    elif action == "f":
        animation = _animation_frame(kv, v14)
    elif action == "a":
        animation = _animation_control(kv, v14)
    else:
        animation = _animation_compose(kv, kitty or v14)
    return Command(action, quiet, _decode_data(raw), kv, transmission, display, delete,
                   animation, len(raw))


class Command:
    """One parsed command. `data` is the decoded payload (the image bytes, or the path or name
    for a non-direct medium); `wire` is the base64 length of the payload on the wire."""
    __slots__ = ("action", "quiet", "data", "kv", "transmission", "display", "delete",
                 "animation", "wire")

    def __init__(self, action, quiet, data, kv, transmission, display, delete, animation, wire):
        self.action = action
        self.quiet = quiet
        self.data = data
        self.kv = kv
        self.transmission = transmission
        self.display = display
        self.delete = delete
        self.animation = animation
        self.wire = wire


class Transmission:
    """The Transmission view (graphics_command.zig): f, t, s, v, S, O, i, I, p, o and m. The
    m key counts only for the direct medium."""
    __slots__ = ("format", "medium", "width", "height", "size", "offset", "image_id",
                 "image_number", "placement_id", "compression", "more", "format_unknown",
                 "transient")


def _transmission(kv, v14=False):
    t = Transmission()
    t.format = "rgba"
    t.format_unknown = False
    if "f" in kv:
        if v14 and kv["f"] == 0:
            t.format = "rgba"
        else:
            t.format = _FORMATS.get(kv["f"])
        if t.format is None:
            if not v14:
                raise ParseError("unknown format")
            t.format = "rgba"
            t.format_unknown = True      # the load answers EINVAL: unsupported format
    t.transient = bool(v14 and kv.get("N", 0) & 1)
    t.medium = "d"
    if "t" in kv:
        if kv["t"] > 255 or kv["t"] not in _MEDIUMS:
            raise ParseError("unknown medium")
        t.medium = _MEDIUMS[kv["t"]]
    t.width = kv.get("s", 0)
    t.height = kv.get("v", 0)
    t.size = kv.get("S", 0)
    t.offset = kv.get("O", 0)
    t.image_id = kv.get("i", 0)
    t.image_number = kv.get("I", 0)
    t.placement_id = kv.get("p", 0)
    t.compression = "none"
    if "o" in kv:
        if kv["o"] != ord("z"):
            raise ParseError("unknown compression")
        t.compression = "zlib"
    t.more = False
    if t.medium == "d" and "m" in kv:
        t.more = kv["m"] > 0
    return t


class Display:
    """The Display view: i, I, p, x, y, w, h, X, Y, c, r, C, U, P, Q, H, V and z."""
    __slots__ = ("image_id", "image_number", "placement_id", "x", "y", "width", "height",
                 "x_offset", "y_offset", "columns", "rows", "cursor", "virtual", "parent_id",
                 "parent_placement_id", "horizontal_offset", "vertical_offset", "z")


def _display_view(kv, v14=False):
    d = Display()
    d.image_id = kv.get("i", 0)
    d.image_number = kv.get("I", 0)
    d.placement_id = kv.get("p", 0)
    d.x = kv.get("x", 0)
    d.y = kv.get("y", 0)
    d.width = kv.get("w", 0)
    d.height = kv.get("h", 0)
    d.x_offset = kv.get("X", 0)
    d.y_offset = kv.get("Y", 0)
    d.columns = kv.get("c", 0)
    d.rows = kv.get("r", 0)
    cursor = kv.get("C", 0)
    if v14:
        d.cursor = "none" if cursor == 1 else "after"    # Kitty tests only against 1
    elif cursor == 0:
        d.cursor = "after"
    elif cursor == 1:
        d.cursor = "none"
    else:
        raise ParseError("C must be 0 or 1")
    virtual = kv.get("U", 0)
    if v14:
        d.virtual = virtual != 0                          # Kitty stores it in a bool
    else:
        if virtual not in (0, 1):
            raise ParseError("U must be 0 or 1")
        d.virtual = virtual == 1
    d.parent_id = kv.get("P", 0)
    d.parent_placement_id = kv.get("Q", 0)
    d.horizontal_offset = kv.get("H", 0)
    d.vertical_offset = kv.get("V", 0)
    d.z = kv.get("z", 0)
    return d


class Delete:
    """The Delete view: kind is one of the _DELETE_KINDS values; `delete` is the uppercase form
    (which also frees images that nothing uses any more). `frame` is the r key (d=f, d=F)."""
    __slots__ = ("kind", "delete", "image_id", "placement_id", "image_number", "x", "y",
                 "first", "last", "z", "frame")


def _delete(kv, v14=False):
    code = kv.get("d", ord("a"))
    if code > 255:
        raise ParseError("unknown delete")
    letter = chr(code)
    kind = _DELETE_KINDS.get(letter.lower())
    if kind is None:
        raise ParseError("unknown delete")
    d = Delete()
    d.kind = kind
    d.delete = letter.isupper()
    d.image_id = kv.get("i", 0)
    d.placement_id = kv.get("p", 0)
    d.image_number = kv.get("I", 0)
    d.x = kv.get("x", 0)
    d.y = kv.get("y", 0)
    d.z = kv.get("z", 0)
    d.frame = kv.get("r", 0)
    d.first = d.last = 0
    if kind == "range":
        if v14:
            d.first = kv.get("x", 0)
            d.last = kv.get("y", 0)      # no validation: an inverted or zero range selects nothing
        else:
            if "x" not in kv or "y" not in kv or kv["x"] > kv["y"]:
                raise ParseError("range needs x and y with x <= y")
            d.first = kv["x"]
            d.last = kv["y"]
    return d


FRAME_DIRECT = ord("d")      # the t key of a chunk that continues a chunked a=f load


def frame_default_format(kv):
    """kitty reads a missing f and f=0 alike as RGBA (fmt = g->format ? g->format : RGBA): f=0 is
    dropped from kv."""
    if kv.get("f") == 0:
        del kv["f"]


def frame_key_error(kv):
    """The answer text for the keys of an a=f first chunk that the loader rejects, or None. Returns
    (text, given_r): kitty checks an indexed format first, before it works out the frame number, so
    that answer carries the r the command gave; the unknown format and a zero width or height
    (initialize_load_data, in its order), the unknown transmission type (load_image_data) and the
    unknown compression (process_image_data) come after it, and carry the frame number the command
    ended up with. A missing f is RGBA, and so is f=0."""
    fmt = kv.get("f")
    if fmt in (8, 16):
        return "EINVAL:Animation is not supported for indexed color images", True
    if fmt is not None and fmt not in _FORMATS:
        return "EINVAL:Unknown image format: %d" % fmt, False
    if fmt != 100 and not kv.get("s", 0) * kv.get("v", 0):
        return "EINVAL:Zero width/height not allowed", False
    medium = kv.get("t")
    if medium is not None and (medium > 255 or medium not in _MEDIUMS):
        char = chr(medium) if medium <= 255 else "?"
        return "EINVAL:Unknown transmission type: %s" % char, False
    compression = kv.get("o")
    if compression is not None and compression != ord("z"):
        char = chr(compression) if compression <= 255 else "?"
        return "EINVAL:Unknown image compression: %s" % char, False
    return None


class AnimationFrame:
    """a=f: the frame keys, checked only (the animation layer is built later)."""
    __slots__ = ("composition",)


def _animation_frame(kv, v14=False):
    frame = AnimationFrame()
    if not v14 and kv.get("X", 0) not in (0, 1):
        raise ParseError("X must be 0 or 1")
    frame.composition = kv.get("X", 0)
    return frame


def _animation_control(kv, v14=False):
    if not v14 and kv.get("s", 0) not in (0, 1, 2, 3):
        raise ParseError("s must be 0 to 3")      # 1.4.0 keeps the animation state for another s
    return kv.get("s", 0)


def _animation_compose(kv, kitty=False):
    if not kitty and kv.get("C", 0) not in (0, 1):
        raise ParseError("C must be 0 or 1")
    return kv.get("C", 0)


# ----------------------------------------------------------------- responses ---

class Resp:
    """graphics_command.zig Response: an image id, an image number, a placement id, a message, and
    (kitty only) the frame number that kitty's a=f answer carries as r."""
    __slots__ = ("id", "number", "placement", "message", "frame")

    def __init__(self, image_id=0, number=0, placement=0, message="OK", frame=0):
        self.id = image_id
        self.number = number
        self.placement = placement
        self.message = message
        self.frame = frame

    def ok(self):
        return self.message == "OK"


def encode_response(image_id, number, placement, message, frame=0):
    """Response.encode: nothing when neither an image id nor a number is set; otherwise
    ESC _ G i=N,I=N,p=N,r=N ; message ESC backslash, the keys present only (r only with a frame)."""
    if image_id == 0 and number == 0:
        return None
    parts = []
    if image_id > 0:
        parts.append("i=%d" % image_id)
    if number > 0:
        parts.append("I=%d" % number)
    if placement > 0:
        parts.append("p=%d" % placement)
    if frame > 0:
        parts.append("r=%d" % frame)
    return ("\x1b_G%s;%s\x1b\\" % (",".join(parts), message)).encode("ascii")


# ------------------------------------------------------------------- images ---

class Image:
    """A stored image (graphics_image.zig Image). data holds the pixels in `format`, which is
    rgb, rgba, gray or gray_alpha: a PNG is stored as rgba, and rgba_bytes() gives RGBA for any.
    `anim` is the kitty animation state (anim.AnimState), None until an a=f, a=a or a=c names the
    image. `version` is a stamp that changes whenever the pixels the image shows change: it is the
    texture cache key of the renderer (ImageView.seq)."""
    __slots__ = ("id", "number", "width", "height", "format", "compression", "data",
                 "transmit_seq", "implicit_id", "wire_bytes", "transmissions", "medium",
                 "anim", "version", "transient")

    def __init__(self, image_id=0, number=0, width=0, height=0, fmt="rgb", compression="none"):
        self.id = image_id
        self.number = number
        self.width = width
        self.height = height
        self.format = fmt
        self.compression = compression
        self.data = b""
        self.transmit_seq = 0
        self.implicit_id = False
        self.wire_bytes = 0
        self.transmissions = 0
        self.medium = "d"
        self.anim = None
        self.version = 0
        self.transient = False


_SEQ = itertools.count(1)   # the transmit time, as a global counter (Image.transmit_time)


def rgba_bytes(image):
    """The pixels of an image as RGBA bytes (alpha 255 where the format has none)."""
    data = bytes(image.data)
    fmt = image.format
    if fmt == "rgba":
        return data
    count = image.width * image.height
    out = bytearray(4 * count)
    if fmt == "rgb":
        out[0::4] = data[0::3]
        out[1::4] = data[1::3]
        out[2::4] = data[2::3]
        out[3::4] = b"\xff" * count
    elif fmt == "gray":
        out[0::4] = data
        out[1::4] = data
        out[2::4] = data
        out[3::4] = b"\xff" * count
    elif fmt == "gray_alpha":
        out[0::4] = data[0::2]
        out[1::4] = data[0::2]
        out[2::4] = data[0::2]
        out[3::4] = data[1::2]
    else:
        raise ValueError("unknown format %r" % (fmt,))
    return bytes(out)


def _inflate(data, limit=MAX_SIZE):
    """zlib.decompress with Ghostty's limit. A corrupt or truncated stream is an error, and so is
    an output of `limit` bytes or more: decompressZlib reads with .limited(max_size), and
    appendRemaining (lib/std/Io/Reader.zig) fails once that many bytes are read, even at the end
    of the stream."""
    decoder = zlib.decompressobj()
    try:
        out = decoder.decompress(data, limit + 1)
    except zlib.error:
        raise MediaError("EINVAL: decompression failed")
    if len(out) >= limit or not decoder.eof:
        raise MediaError("EINVAL: decompression failed")
    return out


# ------------------------------------------------------------------- PNG ---

_PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
_PNG_DEPTHS = {0: (1, 2, 4, 8, 16), 2: (8, 16), 3: (1, 2, 4, 8), 4: (8, 16), 6: (8, 16)}
_PNG_SAMPLES = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}      # samples per pixel, by colour type
_ADAM7 = ((0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4), (0, 2, 2, 4), (1, 0, 2, 2),
          (0, 1, 1, 2))                              # x0, y0, dx, dy of the seven passes


def _png_invalid():
    return MediaError("EINVAL: invalid data")


def _png_encode(kind, body):
    """A chunk with its CRC-32. The normal file Pillow reads holds only valid chunks."""
    crc = zlib.crc32(body, zlib.crc32(kind)) & 0xFFFFFFFF
    return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", crc)


def _png_read_chunk(data, pos):
    """The chunk at pos: (type, body, its CRC is right, the position after it). A chunk whose
    bytes run past the end of the file is invalid data, as wuffs reads it as a short read."""
    if pos + 12 > len(data):
        raise _png_invalid()
    size = int.from_bytes(data[pos:pos + 4], "big")
    end = pos + 8 + size
    if end + 4 > len(data):
        raise _png_invalid()
    kind = bytes(data[pos + 4:pos + 8])
    body = bytes(data[pos + 8:end])
    want = int.from_bytes(data[end:end + 4], "big")
    crc = zlib.crc32(body, zlib.crc32(kind)) & 0xFFFFFFFF
    return kind, body, crc == want, end + 4


def _png_passes(width, height, depth, colour, interlace):
    """The passes of an image, as (x0, y0, dx, dy, pass width, pass height, bytes per row) for each
    pass that has pixels: one pass when not interlaced, up to seven for Adam7."""
    layout = _ADAM7 if interlace else ((0, 0, 1, 1),)
    bits = _PNG_SAMPLES[colour] * depth
    out = []
    for x0, y0, dx, dy in layout:
        pw = (width - x0 + dx - 1) // dx if width > x0 else 0
        ph = (height - y0 + dy - 1) // dy if height > y0 else 0
        if pw and ph:
            out.append((x0, y0, dx, dy, pw, ph, (pw * bits + 7) // 8))
    return out


class _Png:
    """What the PNG decoder reads from a file (see _png_walk): the size, depth, colour type and
    passes; the tRNS value of colour types 0 and 2 (or None); the decompressed scanlines (raw);
    and `normal`, a valid PNG of the chunks that were read, for Pillow."""
    __slots__ = ("width", "height", "depth", "colour", "passes", "trns", "raw", "normal")


def _zlib_header_ok(cmf, flg):
    """The two header bytes of a zlib stream as wuffs checks them: deflate with a window of at most
    32 KiB, a right check value, and no preset dictionary (wuffs hands back a note that asks for
    one, which the PNG decoder does not supply)."""
    return (cmf & 15) == 8 and (cmf >> 4) <= 7 and ((cmf << 8) | flg) % 31 == 0 and not flg & 32


_LENGTH_EXTRA = (0,) * 8 + (1,) * 4 + (2,) * 4 + (3,) * 4 + (4,) * 4 + (5,) * 4 + (0,)
_DIST_EXTRA = (0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11,
               12, 12, 13, 13)
_CLEN_ORDER = (16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15)


class _DeflateEnd(Exception):
    """The deflate input ended inside a block header or a code (or held a code that does not
    exist, which zlib has refused before this is looked at)."""


class _Bits:
    """A deflate bit reader: bits come least significant first."""
    __slots__ = ("data", "pos", "end")

    def __init__(self, data):
        self.data = data
        self.pos = 0
        self.end = 8 * len(data)

    def get(self, count):
        stop = self.pos + count
        if stop > self.end:
            raise _DeflateEnd()
        word = int.from_bytes(self.data[self.pos >> 3:(stop + 7) >> 3], "little")
        value = (word >> (self.pos & 7)) & ((1 << count) - 1)
        self.pos = stop
        return value


def _huffman_table(lengths):
    """A canonical Huffman code from its code lengths, as zlib's puff builds it: the number of
    codes of each length and the symbols in code order."""
    count = [0] * 16
    for length in lengths:
        count[length] += 1
    count[0] = 0
    offsets = [0] * 17
    for length in range(1, 16):
        offsets[length + 1] = offsets[length] + count[length]
    symbols = [0] * len(lengths)
    for symbol, length in enumerate(lengths):
        if length:
            symbols[offsets[length]] = symbol
            offsets[length] += 1
    return count, symbols


def _huffman_symbol(bits, table):
    count, symbols = table
    code = first = index = 0
    for length in range(1, 16):
        code |= bits.get(1)
        number = count[length]
        if code - number < first:
            return symbols[index + code - first]
        index += number
        first = (first + number) << 1
        code <<= 1
    raise _DeflateEnd()


def _dynamic_tables(bits):
    literals = bits.get(5) + 257
    distances = bits.get(5) + 1
    clen = [0] * 19
    for i in range(bits.get(4) + 4):
        clen[_CLEN_ORDER[i]] = bits.get(3)
    table = _huffman_table(clen)
    lengths = []
    while len(lengths) < literals + distances:
        symbol = _huffman_symbol(bits, table)
        if symbol < 16:
            lengths.append(symbol)
        elif symbol == 16:
            if not lengths:
                raise _DeflateEnd()
            lengths += [lengths[-1]] * (3 + bits.get(2))
        elif symbol == 17:
            lengths += [0] * (3 + bits.get(3))
        else:
            lengths += [0] * (11 + bits.get(7))
    return (_huffman_table(lengths[:literals]),
            _huffman_table(lengths[literals:literals + distances]))


_FIXED_TABLES = (_huffman_table([8] * 144 + [9] * 112 + [7] * 24 + [8] * 8),
                 _huffman_table([5] * 30))


def _skip_codes(bits, literals, distances):
    """Read the codes of one Huffman block up to its end-of-block code."""
    while True:
        symbol = _huffman_symbol(bits, literals)
        if symbol == 256:
            return
        if symbol > 256:
            if symbol - 257 >= len(_LENGTH_EXTRA):
                raise _DeflateEnd()
            bits.get(_LENGTH_EXTRA[symbol - 257])
            distance = _huffman_symbol(bits, distances)
            if distance >= len(_DIST_EXTRA):
                raise _DeflateEnd()
            bits.get(_DIST_EXTRA[distance])


def _deflate_stored_left(data):
    """How many bytes the stored block that the end of the deflate input `data` falls inside still
    owes (its length less the bytes of it in `data`); 0 when the end is anywhere else: in a block
    header, in a Huffman block (its codes are only walked here, nothing is decoded), or past the
    final block. A decoder in a stored block with bytes left has output to give without any more
    input, which wuffs reports as a short write before it asks for input (decode_uncompressed).
    Walking the blocks costs a pure Python loop over the codes, and it is only asked for where a
    chunk of an interlaced one row image ends exactly at the needed bytes."""
    bits = _Bits(data)
    try:
        while True:
            final = bits.get(1)
            kind = bits.get(2)
            if kind == 0:
                bits.pos = (bits.pos + 7) & ~7
                length = bits.get(16)
                bits.get(16)
                have = (bits.end - bits.pos) >> 3
                if have < length:
                    return length - have
                bits.pos += 8 * length
            elif kind == 1:
                _skip_codes(bits, *_FIXED_TABLES)
            elif kind == 2:
                _skip_codes(bits, *_dynamic_tables(bits))
            else:
                return 0
            if final:
                return 0
    except _DeflateEnd:
        return 0


def _png_walk(data):
    """Read a PNG as Ghostty's decoder does (wuffs 0.4.0-alpha.9, std/png/decode_png.wuffs) and
    return a _Png, or raise invalid data. The rules, in the order wuffs applies them:
      - the signature, then IHDR first with a right CRC; width and height 1 to 0xFFFFFF; a depth
        and colour type that go together; compression 0, filter 0 and interlace 0 or 1;
      - before IDAT, every critical chunk (upper-case first letter) is checked by its CRC and must
        be PLTE, once, and not for colour types 0 and 4. PLTE is read for colour type 3 (up to
        768 bytes, a multiple of 3) and ignored for colour types 2 and 6. Any other critical
        chunk, IEND included, is invalid. The CRC of an ancillary chunk is not checked;
      - tRNS is read once: 2 bytes for colour type 0, 6 for colour type 2, at most 256 for colour
        type 3 (after its PLTE), and ignored for colour types 4 and 6;
      - colour type 3 needs its PLTE before IDAT;
      - the IDAT chunks follow each other, each with a right CRC, until the zlib stream ends (its
        header and its Adler-32 checked, wherever the chunks cut them). No byte may follow the
        stream in its own chunk. The stream must give exactly the scanlines of the image, each
        with a filter type of 0 to 4. One exception: an interlaced image one row high stops at
        the needed bytes, so surplus image data after them is not an error, and nothing about
        the surplus is checked: not the Adler-32 (a stream that goes on by one byte is stopped
        before its end is seen), not the end of the stream, and not the CRC of the chunk the
        surplus is first seen in. Where a chunk ends exactly at the needed bytes, wuffs stops at
        once if its decoder owes output without reading on (inside a stored block with bytes
        left, see _deflate_stored_left), and then the chunk's CRC is never checked; any other
        decoder state has to read a code first, so the CRC is checked and the next chunk read;
      - nothing after the end of the zlib stream is read: not IEND, not its CRC, not a chunk after.
    The normal file keeps IHDR, PLTE, tRNS and the IDAT chunks that were read, with correct CRCs,
    and an IEND, so Pillow sees exactly what wuffs decoded."""
    if data[:8] != _PNG_SIGNATURE:
        raise _png_invalid()
    kind, body, ok, pos = _png_read_chunk(data, 8)
    if kind != b"IHDR" or len(body) != 13 or not ok:
        raise _png_invalid()
    width = int.from_bytes(body[0:4], "big")
    height = int.from_bytes(body[4:8], "big")
    depth, colour, compression, filt, interlace = body[8], body[9], body[10], body[11], body[12]
    if not (0 < width <= 0xFFFFFF and 0 < height <= 0xFFFFFF):
        raise _png_invalid()
    if depth not in _PNG_DEPTHS.get(colour, ()) or compression or filt or interlace > 1:
        raise _png_invalid()
    pre = [(b"IHDR", body)]
    palette = seen_trns = False
    trns = None
    while True:
        kind, body, ok, pos = _png_read_chunk(data, pos)
        if kind == b"IDAT":
            break
        if not kind[0] & 0x20:                      # critical
            if not ok or kind != b"PLTE" or palette or colour in (0, 4):
                raise _png_invalid()
            palette = True
            if colour == 3:
                if len(body) > 768 or len(body) % 3:
                    raise _png_invalid()
                pre.append((kind, body))
            continue
        if kind == b"tRNS":
            if seen_trns or (colour == 3 and not palette):
                raise _png_invalid()
            seen_trns = True
            if ((colour == 0 and len(body) != 2) or (colour == 2 and len(body) != 6)
                    or (colour == 3 and len(body) > 256)):
                raise _png_invalid()
            if colour in (0, 2, 3):
                pre.append((kind, body))
            if colour in (0, 2):
                trns = body
    if colour == 3 and not palette:
        raise _png_invalid()
    layout = _png_passes(width, height, depth, colour, interlace)
    needed = sum(ph * (1 + rb) for _x, _y, _dx, _dy, _pw, ph, rb in layout)
    # the zlib stream is inflated raw and its header and trailer are read here, as wuffs reads
    # them, so that the Adler-32 is looked at only when the stream is seen to end at the needed
    # bytes
    inflater = zlib.decompressobj(-15)
    header = bytearray()
    trailer = bytearray()
    fed = bytearray()
    scan = bytearray()
    idat = []
    # An interlaced image one row high has an empty last pass (Adam7 pass 7), and wuffs checks for
    # too much data only in pass 7 or in a pass of a non-interlaced image (decode_pass). So it stops
    # reading once the last non-empty pass is full: data after that point is never looked at.
    stops_at_needed = interlace == 1 and height == 1
    stopped = False
    while True:
        chunk_in = body
        if len(header) < 2:
            take = 2 - len(header)
            header += chunk_in[:take]
            chunk_in = chunk_in[take:]
            if len(header) == 2 and not _zlib_header_ok(header[0], header[1]):
                raise _png_invalid()
        if stops_at_needed:
            fed += chunk_in
        if inflater.eof:
            trailer += chunk_in
        elif chunk_in:
            try:
                scan += inflater.decompress(chunk_in, needed + 1 - len(scan))
            except zlib.error:
                raise _png_invalid()
            if len(scan) > needed:
                if not stops_at_needed:
                    raise _png_invalid()               # more image data than the dimensions need
                stopped = True                         # no CRC check of this chunk
                break
            if inflater.eof:
                trailer += inflater.unused_data
        if inflater.eof:
            if len(trailer) > 4:
                raise _png_invalid()                   # bytes after the zlib stream in its chunk
            if len(trailer) == 4:
                if len(scan) != needed or int.from_bytes(trailer, "big") != zlib.adler32(scan):
                    raise _png_invalid()
                if not ok:
                    raise _png_invalid()
                idat.append(body)
                break
        elif stops_at_needed and len(scan) == needed and _deflate_stored_left(fed):
            stopped = True                             # a short write: stop without the CRC
            break
        if not ok:
            raise _png_invalid()
        idat.append(body)
        kind, body, ok, pos = _png_read_chunk(data, pos)
        if kind != b"IDAT":
            raise _png_invalid()
    if stopped:
        # Pillow gets the needed bytes as a clean zlib stream
        del scan[needed:]
        idat = [zlib.compress(bytes(scan))]
    if len(scan) != needed:
        raise _png_invalid()                       # not enough image data
    scan = bytes(scan)
    offset = 0
    for _x, _y, _dx, _dy, _pw, ph, rb in layout:
        for _row in range(ph):
            if scan[offset] > 4:
                raise _png_invalid()               # a filter type that does not exist
            offset += rb + 1
    png = _Png()
    png.width, png.height, png.depth, png.colour = width, height, depth, colour
    png.passes, png.trns, png.raw = layout, trns, scan
    png.normal = _PNG_SIGNATURE + b"".join(_png_encode(k, b) for k, b in pre) + b"".join(
        _png_encode(b"IDAT", b) for b in idat) + _png_encode(b"IEND", b"")
    return png


def _png_unfilter_row(line, prior, bpp, ftype):
    """One scanline (a list of bytes) with filter Average (3) or Paeth (4) undone (PNG 9.2)."""
    cur = [0] * len(line)
    for i, x in enumerate(line):
        left = cur[i - bpp] if i >= bpp else 0
        up = prior[i]
        if ftype == 3:
            pred = (left + up) >> 1
        else:
            upleft = prior[i - bpp] if i >= bpp else 0
            p = left + up - upleft
            pa, pb, pc = abs(p - left), abs(p - up), abs(p - upleft)
            pred = left if (pa <= pb and pa <= pc) else (up if pb <= pc else upleft)
        cur[i] = (x + pred) & 0xFF
    return cur


def _png_unfilter(raw, offset, rows, rowbytes, bpp):
    """The unfiltered bytes of `rows` scanlines of rowbytes bytes, each with its filter byte, read
    from raw at offset (numpy array of shape (rows, rowbytes)). bpp is the filter distance."""
    import numpy as np
    out = np.zeros((rows, rowbytes), np.uint8)
    prior = np.zeros(rowbytes, np.uint8)
    for j in range(rows):
        start = offset + j * (rowbytes + 1)
        ftype = raw[start]
        line = np.frombuffer(raw, np.uint8, rowbytes, start + 1)
        if ftype == 0:
            cur = line.copy()
        elif ftype == 1:
            cur = np.cumsum(line.reshape(-1, bpp), axis=0, dtype=np.uint8).reshape(-1)
        elif ftype == 2:
            cur = line + prior
        else:
            cur = np.array(_png_unfilter_row(line.tolist(), prior.tolist(), bpp, ftype), np.uint8)
        out[j] = cur
        prior = cur
    return out


def _png_rgb16_matches(png, trns):
    """16-bit RGB with tRNS: which pixels (in image order) equal the tRNS value on all six bytes of
    their unfiltered samples. Pillow keeps only the high byte of each channel, so the low bytes
    come from the scanlines wuffs decodes."""
    import numpy as np
    samples = np.zeros((png.height, png.width, 6), np.uint8)
    offset = 0
    for x0, y0, dx, dy, pw, ph, rb in png.passes:
        block = _png_unfilter(png.raw, offset, ph, rb, 6)
        samples[y0::dy, x0::dx] = block.reshape(ph, pw, 6)
        offset += ph * (rb + 1)
    key = np.frombuffer(trns, np.uint8)
    return np.all(samples.reshape(-1, 6) == key, axis=1)


def _png_gray_rgb(im, png):
    """The RGBA bytes of a gray (colour type 0) or RGB (colour type 2) PNG as wuffs gives them
    (RGBA_NONPREMUL). A 16-bit sample keeps its high byte (swizzle_xxxx__y_16be). A pixel equal to
    the tRNS value becomes transparent black, all four bytes 0 (wuffs remap_transparency), not
    alpha 0 with its colour kept. The value is compared at the depth of the file: 16-bit gray on
    the whole sample, gray of 8 bits or fewer after the scaling Pillow applies, 8-bit RGB on each
    byte, and 16-bit RGB on all six bytes (_png_rgb16_matches)."""
    import numpy as np
    width, height = im.size
    count = width * height
    out = np.zeros((count, 4), np.uint8)
    out[:, 3] = 255
    trns = png.trns
    matches = None
    if png.colour == 0:
        if im.mode in _GRAY16_MODES:
            values = np.frombuffer(im.tobytes("raw", "I;16B"), dtype=">u2")
            gray = (values >> 8).astype(np.uint8)
            if trns is not None:
                matches = values == int.from_bytes(trns, "big")
        else:
            gray = np.frombuffer((im if im.mode == "L" else im.convert("L")).tobytes(), np.uint8)
            if trns is not None:
                mask = (1 << png.depth) - 1
                key = (int.from_bytes(trns, "big") & mask) * (255 // mask)
                matches = gray == key
        out[:, :3] = gray[:, None]
    else:
        rgb = np.frombuffer((im if im.mode == "RGB" else im.convert("RGB")).tobytes(), np.uint8)
        rgb = rgb.reshape(count, 3)
        out[:, :3] = rgb
        if trns is not None:
            if png.depth == 16:
                matches = _png_rgb16_matches(png, trns)
            else:
                key = np.array([trns[1], trns[3], trns[5]], np.uint8)
                matches = np.all(rgb == key, axis=1)
    if matches is not None:
        out[matches] = 0
    return out.tobytes()


def _decode_png(data):
    """A PNG as RGBA bytes with its width and height. _png_walk reads the file as wuffs does and
    builds the normal file; Pillow decodes that file. Gray and RGB take _png_gray_rgb (tRNS on the
    samples), the other colour types Pillow's conversion to RGBA. Anything refused is invalid
    data."""
    from PIL import Image as PILImage
    png = _png_walk(data)
    try:
        im = PILImage.open(io.BytesIO(png.normal))
        if im.format != "PNG":
            raise ValueError("not a PNG")
        im.load()
        if im.size != (png.width, png.height):
            raise ValueError("size differs from the header")
        if png.colour in (0, 2):
            out = _png_gray_rgb(im, png)
        else:
            out = im.convert("RGBA").tobytes()
    except Exception:
        raise MediaError("EINVAL: invalid data")
    if len(out) > MAX_SIZE:
        raise MediaError("EINVAL: invalid data")
    return out, png.width, png.height



class LoadingImage:
    """An image that is still arriving (graphics_image.zig LoadingImage): its metadata from the
    first chunk, the data so far, the display for a T command, and the quiet setting of the first
    chunk, which later chunks inherit. `action` is the first chunk's action letter; an a=f load
    (kitty only) also keeps its frame in `frame` (anim.py)."""
    __slots__ = ("image", "data", "display", "quiet", "wire", "medium", "action", "frame")

    def __init__(self, image, display, quiet, medium, wire):
        self.image = image
        self.data = bytearray()
        self.display = display
        self.quiet = quiet
        self.medium = medium
        self.wire = wire
        self.action = "t"
        self.frame = None

    @classmethod
    def start(cls, term, cmd, key, count_media=True):
        """LoadingImage.init: a direct chunk is added; another medium is read through the media
        layer, with the blob key of this APC. stats.media counts each transmission (a=t or a=T)
        by its medium, once per transmission and not per chunk; a query (a=q) is not counted. An
        a=f command has no transmission view of its own: its frame size is the s and v keys."""
        t = cmd.transmission if cmd.transmission is not None \
            else _transmission(cmd.kv, is_140(term.profile))
        if t.format_unknown:
            raise MediaError("EINVAL: unsupported format")
        image = Image(t.image_id, t.image_number, t.width, t.height, t.format, t.compression)
        image.transient = t.transient
        display = cmd.display if cmd.action == "T" else None
        loading = cls(image, display, cmd.quiet, t.medium, cmd.wire)
        loading.action = cmd.action
        if count_media and cmd.action in ("t", "T"):
            term.stats["media"][t.medium] += 1
        if t.medium == "d":
            loading.add_data(cmd.data)
            return loading
        blob = term.media.load(t.medium, cmd.data, t.offset, t.size, t.format, t.width, t.height,
                               key)
        loading.data = bytearray(blob)
        return loading

    def add_data(self, data):
        """addData: a chunk is appended; more than 400 MB in total is invalid data."""
        if not data:
            return
        if len(self.data) + len(data) > MAX_SIZE:
            raise MediaError("EINVAL: invalid data")
        self.data += data

    def complete(self):
        """complete: decompress, decode a PNG, then check the dimensions and the length (in that
        order, as Ghostty does). Returns the Image."""
        image = self.image
        data = bytes(self.data)
        if image.compression == "zlib":
            data = _inflate(data)
            image.compression = "none"
        if image.format == "png":
            data, image.width, image.height = _decode_png(data)
            image.format = "rgba"
        if image.width == 0 or image.height == 0:
            raise MediaError("EINVAL: dimensions required")
        if image.width > MAX_DIMENSION or image.height > MAX_DIMENSION:
            raise MediaError("EINVAL: dimensions too large")
        if len(data) != image.width * image.height * _BPP[image.format]:
            raise MediaError("EINVAL: invalid data")
        image.data = data
        return image


class PinRef:
    """A pin (Ghostty's tracked pin): abs_y is the row in the screen's absolute row space (the
    screen row plus Screen.base when the pin was made) and x the column. vt.py moves abs_y as the
    rows move (grow, eraseRow, eraseRowBounded, eraseRows, resize); a row swap leaves it alone."""
    __slots__ = ("abs_y", "x")

    def __init__(self, abs_y, x):
        self.abs_y = abs_y
        self.x = x


class Placement:
    """A placement (graphics_storage.zig Placement). location is a PinRef, or None for a virtual
    placement (U=1), which is drawn through placeholder cells and is never matched by position."""
    __slots__ = ("location", "x_offset", "y_offset", "source_x", "source_y", "source_width",
                 "source_height", "columns", "rows", "z", "relative")

    def __init__(self, location, x_offset, y_offset, source_x, source_y, source_width,
                 source_height, columns, rows, z, relative=None):
        # relative (1.4.0 only): (the parent's placement key, H, V) of a placement made with P=;
        # such a placement has no location of its own and the model never draws it
        self.relative = relative
        self.location = location
        self.x_offset = x_offset
        self.y_offset = y_offset
        self.source_x = source_x
        self.source_y = source_y
        self.source_width = source_width
        self.source_height = source_height
        self.columns = columns
        self.rows = rows
        self.z = z

    def clip_top(self, image, term, count, span):
        """Placement.clipTop: permanently clip `count` rows off the top of a placement that spans
        `span` grid rows by shrinking its source rectangle. False when no source pixels would be
        left (the placement is then deleted)."""
        src_x, src_y, src_w, src_h = source_rect(self, image)
        if self.rows > 0:
            crop = src_h * count // span        # a scaled placement shows equal fractions
        else:
            crop = _sat(term.cell[1] * count)   # native size: one cell height of pixels per row
        if crop >= src_h:
            return False
        self.source_x, self.source_y = src_x, src_y + crop
        self.source_width, self.source_height = src_w, src_h - crop
        if self.rows > 0:
            self.rows -= count
        return True

    def clip_bottom(self, image, term, count, span):
        """Placement.clipBottom: clipTop for the bottom rows."""
        src_x, src_y, src_w, src_h = source_rect(self, image)
        if src_h == 0:
            return False       # an explicit zero height would mean the whole image
        if self.rows > 0:
            crop = src_h * count // span
            if crop >= src_h:
                return False
            self.source_height = src_h - crop
            self.rows -= count
        else:
            visible = _sat(term.cell[1] * (span - count))
            offset = cell_offset(self, term)[1]
            if visible <= offset:
                return False
            self.source_height = min(src_h, visible - offset)
        self.source_x, self.source_y, self.source_width = src_x, src_y, src_w
        return True


class _ScrollMargins:
    """The pins to put back once a scroll's row operation is done (ScrollMargins.end)."""
    __slots__ = ("screen", "restores")

    def __init__(self, screen, restores):
        self.screen = screen
        self.restores = restores

    def end(self):
        for pin, final_y in self.restores:
            pin.abs_y = self.screen.base + final_y


def calculated_size(place, image, term):
    """Placement.calculatedSize: the pixel size of the placement, from its source rectangle and
    its columns and rows (a missing dimension follows the aspect ratio)."""
    width = place.source_width if place.source_width > 0 else image.width
    height = place.source_height if place.source_height > 0 else image.height
    if place.columns == 0 and place.rows == 0:
        return width, height
    cell_w, cell_h = term.cell
    if place.columns > 0 and place.rows > 0:
        return cell_w * place.columns, cell_h * place.rows
    if place.columns > 0:
        calc_w = cell_w * place.columns
        return calc_w, int(math.floor(calc_w * (height / width) + 0.5))
    calc_h = cell_h * place.rows
    return int(math.floor(calc_h * (width / height) + 0.5)), calc_h


def _ceil_div(a, b):
    return 0 if b == 0 else -(-a // b)


def _sat(value):
    """A u32 product or sum that saturates instead of wrapping (1.4.0 saturatingMul and +|)."""
    return min(value, _U32)


def source_rect(place, image):
    """1.4.0 Placement.sourceRect: the requested source rectangle intersected with the image. A
    zero width or height asks for the whole dimension before the intersection."""
    x = min(place.source_x, image.width)
    y = min(place.source_y, image.height)
    width = min(place.source_width if place.source_width > 0 else image.width, image.width - x)
    height = min(place.source_height if place.source_height > 0 else image.height,
                 image.height - y)
    return x, y, width, height


def cell_offset(place, term):
    """1.4.0 Placement.cellOffset: the X and Y offsets kept inside the first cell."""
    cell_w, cell_h = term.cell
    return (min(place.x_offset, cell_w - 1) if cell_w > 0 else 0,
            min(place.y_offset, cell_h - 1) if cell_h > 0 else 0)


def _scale_dimension(value, numerator, denominator):
    """1.4.0 scaleDimension: value * numerator / denominator rounded half up, as integers."""
    if denominator == 0:
        return 0
    return min((value * numerator + denominator // 2) // denominator, _U32)


def pixel_size(place, image, term):
    """1.4.0 Placement.pixelSize: the size of the placement in pixels, from the clamped source
    rectangle and the columns and rows (a missing dimension follows the aspect ratio); the pixels
    the offset takes from the first cell are not part of it."""
    _x, _y, width, height = source_rect(place, image)
    if place.columns == 0 and place.rows == 0:
        return width, height
    cell_w, cell_h = term.cell
    off_x, off_y = cell_offset(place, term)
    if place.columns > 0 and place.rows > 0:
        return (max(0, _sat(cell_w * place.columns) - off_x),
                max(0, _sat(cell_h * place.rows) - off_y))
    if place.columns > 0:
        calc_w = max(0, _sat(cell_w * place.columns) - off_x)
        return calc_w, _scale_dimension(calc_w, height, width)
    calc_h = max(0, _sat(cell_h * place.rows) - off_y)
    return _scale_dimension(calc_h, width, height), calc_h


def grid_size(place, image, term):
    """Placement.gridSize: the columns and rows the placement occupies, rounded up."""
    if place.columns > 0 and place.rows > 0:
        return place.columns, place.rows
    cell_w, cell_h = term.cell
    if is_140(term.profile):
        width, height = pixel_size(place, image, term)
        off_x, off_y = cell_offset(place, term)
        return _ceil_div(_sat(width + off_x), cell_w), _ceil_div(_sat(height + off_y), cell_h)
    width, height = calculated_size(place, image, term)
    return (_ceil_div(width + place.x_offset, cell_w),
            _ceil_div(height + place.y_offset, cell_h))


def pin_yx(term, pin):
    """The screen (row, column) of a pin. The row is negative when the pin is in history: it still
    has a rectangle over the visible rows (Placement.rect)."""
    return pin.abs_y - term.active.base, pin.x


def _rect(term, place, image):
    """Placement.rect: the top-left and bottom-right (row, column) cells of a pin placement, or
    None for a virtual one. The bottom row is clamped to the screen (downOverflow)."""
    if place.location is None:
        return None
    y0, x0 = pin_yx(term, place.location)
    cols, rows = grid_size(place, image, term)
    if is_140(term.profile) and (cols == 0 or rows == 0):
        return None      # 1.4.0: a zero grid (no cell size in pixels) occupies no rectangle
    return ((y0, x0), (min(y0 + rows - 1, term.rows - 1), min(x0 + cols - 1, term.cols - 1)))


def _between(target, top, bottom):
    """Pin.isBetween on one page: row-major and inclusive."""
    (ty, tx), (y0, x0), (y1, x1) = target, top, bottom
    if ty < y0 or ty > y1:
        return False
    if ty == y0 and tx < x0:
        return False
    if ty == y1 and tx > x1:
        return False
    return True


class ImageStorage:
    """The images and placements of one screen (graphics_storage.zig ImageStorage).

    placements maps (image_id, pkey) to a Placement; pkey is ("i", n) for an internal placement
    (a placement id of 0) and ("e", p) for placement id p. images maps an id to an Image.
    """

    def __init__(self, limit=DEFAULT_STORAGE_LIMIT, v14=False):
        self.v14 = bool(v14)             # the ghostty-1.4.0 profile's rules for images and deletes
        self.total_limit = int(limit)
        self.images = {}
        self.placements = {}
        self.loading = None
        self.total_bytes = 0
        self.next_image_id = FIRST_IMAGE_ID
        self.next_internal_placement_id = 0
        # the placements with a pin (location not None), kept for O(1) checks
        self.pins = 0

    def enabled(self):
        """The protocol is on for this screen while its limit is not 0 (ImageStorage.enabled)."""
        return self.total_limit != 0

    # --- images ---

    def image_by_id(self, image_id):
        return self.images.get(image_id)

    def image_by_number(self, number):
        """The newest image with this number (by transmit time), or None."""
        newest = None
        for image in self.images.values():
            if image.number == number and (newest is None
                                           or image.transmit_seq > newest.transmit_seq):
                newest = image
        return newest

    def add_image(self, image):
        """addImage: an image bigger than the limit is out of memory; otherwise evict until it
        fits, then store it (an image with the same id is replaced). In the 1.4.0 profile the old
        image's bytes are credited first, nothing evicts the id being replaced, the replacement
        removes the old image's placements (virtual ones included) and the eviction order puts
        transient images (the N usage hint) first."""
        if self.v14:
            return self._add_image_v14(image)
        size = len(image.data)
        if size > self.total_limit:
            raise MediaError("ENOMEM: out of memory")
        total = self.total_bytes + size
        if total > self.total_limit:
            if not self.evict(total - self.total_limit):
                raise MediaError("ENOMEM: out of memory")
        old = self.images.get(image.id)
        if old is not None:
            self.total_bytes -= len(old.data)
        image.transmit_seq = next(_SEQ)
        image.version = image.transmit_seq
        self.images[image.id] = image
        self.total_bytes += size

    def _add_image_v14(self, image):
        size = len(image.data)
        if size > self.total_limit:
            raise MediaError("ENOMEM: out of memory")
        old = self.images.get(image.id)
        total = self.total_bytes - (len(old.data) if old is not None else 0) + size
        if total > self.total_limit and not self._evict_except(total - self.total_limit, image.id):
            raise MediaError("ENOMEM: out of memory")
        if old is not None:
            for key in [key for key in self.placements if key[0] == image.id]:
                self._drop(key)
            self.total_bytes -= len(old.data)
        image.transmit_seq = next(_SEQ)
        image.version = image.transmit_seq
        self.images[image.id] = image
        self.total_bytes += size
        self.reap_orphans()

    def _evict_except(self, required, exclude):
        """evictImageExcept: while fewer than `required` bytes are freed, the image with the
        lowest (priority, generation, id) goes with its placements, never `exclude`. Priority is
        0 transient and unused, 1 unused, 2 transient and used, 3 used. False when the images ran
        out first."""
        evicted = 0
        while evicted < required:
            best = None
            for image in self.images.values():
                if image.id == exclude:
                    continue
                used = any(key[0] == image.id for key in self.placements)
                cand = ((0 if image.transient else 1) + (2 if used else 0), image.transmit_seq,
                        image.id)
                if best is None or cand < best:
                    best = cand
            if best is None:
                return False
            for key in [key for key in self.placements if key[0] == best[2]]:
                self._drop(key)
            image = self.images.pop(best[2])
            evicted += len(image.data)
            self.total_bytes -= len(image.data)
        self.reap_orphans()
        return True

    def next_id(self, explicit):
        """nextImageId: an image given a number takes the lowest free id from 1 (explicit); one
        given neither takes the next free id from the automatic counter (implicit)."""
        image_id = 1 if explicit else self.next_image_id
        for _ in range(len(self.images) + 2):
            if image_id != 0 and image_id not in self.images:
                break
            image_id = (image_id + 1) & _U32
        if image_id == 0:
            image_id = 1
        if not explicit:
            self.next_image_id = (image_id + 1) & _U32
        return image_id

    def remove_image(self, image_id):
        """removeImage: the image goes with every placement of it (d=F on an animated image)."""
        for key in [key for key in self.placements if key[0] == image_id]:
            self._drop(key)
        image = self.images.pop(image_id, None)
        if image is not None:
            self.total_bytes -= len(image.data)

    def evict(self, required):
        """evictImage: unused images first, then the oldest transmit, then the lowest id; stop once
        more than `required` bytes are freed (Ghostty's `evicted > req`)."""
        candidates = []
        for image in self.images.values():
            used = any(key[0] == image.id for key in self.placements)
            candidates.append((used, image.transmit_seq, image.id))
        candidates.sort()
        evicted = 0
        for _used, _seq, image_id in candidates:
            for key in [key for key in self.placements if key[0] == image_id]:
                self._drop(key)
            image = self.images.pop(image_id, None)
            if image is not None:
                evicted += len(image.data)
                self.total_bytes -= len(image.data)
                if evicted > required:
                    return True
        return False

    def delete_if_unused(self, image_id):
        """deleteIfUnused: an image with no placement left (virtual ones count) is freed."""
        for key in self.placements:
            if key[0] == image_id:
                return
        image = self.images.pop(image_id, None)
        if image is not None:
            self.total_bytes -= len(image.data)

    # --- placements ---

    def add_placement(self, image_id, placement_id, place):
        """addPlacement: placement id 0 gets a fresh internal key; any other id is external and
        replaces an earlier placement with the same key."""
        if placement_id == 0:
            pkey = ("i", self.next_internal_placement_id)
            self.next_internal_placement_id = (self.next_internal_placement_id + 1) & _U32
        else:
            pkey = ("e", placement_id)
        key = (image_id, pkey)
        old = self.placements.get(key)
        if old is not None and old.location is not None:
            self.pins -= 1
        self.placements[key] = place
        if place.location is not None:
            self.pins += 1

    def scroll_margins_begin(self, term, delta):
        """scrollMarginsBegin (1.4.0): a scroll of a region that is not the whole screen moves the
        placements that lie entirely inside the region with the content (delta rows, negative is
        up), clips the ones the move pushes over a margin (their source rectangle shrinks) and
        deletes the ones clipped away; every other placement stays where it is on the screen. The
        final rows are fixed before the row operation and restored after it, whichever way that
        operation moves the pins. Returns the state whose end() restores them."""
        sc = term.active
        top, bottom = term.top, term.bottom
        restores = []
        mutated = False
        for key in list(self.placements):
            place = self.placements[key]
            pin = place.location
            if pin is None:
                continue
            y = pin.abs_y - sc.base
            if y < 0 or y >= term.rows:
                continue            # anchored in the scrollback: a scroll within margins keeps it
            final_y = y
            image = self.images.get(key[0])
            if image is not None:
                cols, rows = grid_size(place, image, term)
                if cols > 0 and rows > 0 and top <= y and y + rows - 1 <= bottom:
                    new_y = y + delta
                    top_clip = max(0, top - new_y)
                    bottom_clip = max(0, new_y + rows - 1 - bottom)
                    visible = top_clip < rows and bottom_clip < rows
                    if visible and top_clip > 0:
                        visible = place.clip_top(image, term, top_clip, rows)
                        final_y = top
                        mutated = True
                    elif visible:
                        if bottom_clip > 0:
                            visible = place.clip_bottom(image, term, bottom_clip, rows)
                            mutated = True
                        final_y = new_y
                    if not visible:
                        self._drop(key)
                        mutated = True
                        continue
            restores.append((pin, final_y))
        if mutated:
            self.reap_orphans()
        return _ScrollMargins(sc, restores)

    def reap_orphans(self, delete_unused=False):
        """removeOrphans (1.4.0): a relative placement lives only as long as its parent chain, so
        those whose parent is gone are removed, again until a pass removes none; an uppercase
        delete also frees an image the cascade left without placements."""
        removed = True
        while removed:
            removed = False
            for key in list(self.placements):
                place = self.placements.get(key)
                if place is None or place.relative is None:
                    continue
                if place.relative[0] in self.placements:
                    continue
                self._drop(key)
                removed = True
                if delete_unused:
                    self.delete_if_unused(key[0])

    def resolve_parent(self, child, parent_image_id, parent_placement_id):
        """resolveParent: the key of the parent placement of a new relative placement, or the
        error text of the answer. child is the key the new placement will have (None without an
        explicit placement id)."""
        if parent_image_id not in self.images:
            return None, "ENOPARENT: parent image not found"
        if parent_placement_id > 0:
            parent = (parent_image_id, ("e", parent_placement_id))
            if parent not in self.placements:
                return None, "ENOPARENT: parent placement not found"
        else:
            best = None
            for key in self.placements:
                if key[0] != parent_image_id:
                    continue
                rank = (0 if key[1][0] == "e" else 1, key[1][1])   # preferredOver
                if best is None or rank < best[0]:
                    best = (rank, key)
            if best is None:
                return None, "ENOPARENT: parent placement not found"
            parent = best[1]
        if child is not None and parent == child:
            return None, "EINVAL: placement cannot be its own parent"
        depth = 1
        key = parent
        while True:
            if child is not None and key == child:
                return None, "ECYCLE: parent chain creates a cycle"
            place = self.placements.get(key)
            if place is None:
                return None, "ENOENT: parent chain ancestor not found"
            if place.relative is None:
                break
            if depth >= PARENT_CHAIN_LIMIT:
                return None, "ETOODEEP: parent chain too deep"
            depth += 1
            key = place.relative[0]
        return parent, None

    def _drop(self, key):
        """Remove one placement, keeping the pin count."""
        place = self.placements.pop(key)
        if place.location is not None:
            self.pins -= 1

    def _delete_by_id(self, image_id, placement_id, delete_unused):
        """deleteById: placement id 0 removes every placement of the image (virtual ones too);
        otherwise only the external placement with that id."""
        if placement_id == 0:
            for key in [key for key in self.placements if key[0] == image_id]:
                self._drop(key)
        elif (image_id, ("e", placement_id)) in self.placements:
            self._drop((image_id, ("e", placement_id)))
        if delete_unused:
            self.delete_if_unused(image_id)

    def _delete_intersecting(self, term, target, delete_unused, keep=None):
        """deleteIntersecting: every pin placement whose rectangle holds the target cell (and
        that passes the keep predicate) is removed."""
        for key in list(self.placements):
            image = self.images.get(key[0])
            if image is None:
                continue
            place = self.placements[key]
            rect = _rect(term, place, image)
            if rect is None or not _between(target, rect[0], rect[1]):
                continue
            if keep is not None and not keep(place):
                continue
            self._drop(key)
            if delete_unused:
                self.delete_if_unused(image.id)

    def delete_all(self, delete_images):
        """delete .all (d=a and d=A, and the ED 2 and ED 22 clears with delete_images=True): every
        pin placement goes, virtual placements stay; with delete_images every image left with no
        placement is freed."""
        for key in list(self.placements):
            if self.placements[key].location is None:
                continue
            self._drop(key)
            if delete_images:
                self.delete_if_unused(key[0])
        if delete_images:
            for image_id in list(self.images):
                self.delete_if_unused(image_id)

    # --- the 1.4.0 deletes ---

    def _visible(self, term, place, key):
        """deleteVisiblePlacements: a pin placement is visible when its pin is in the active area
        or, with the pin in history, when its bottom edge reaches the active area."""
        if place.location is None:
            return False
        if place.location.abs_y - term.active.base >= 0:
            return True
        image = self.images.get(key[0])
        rect = None if image is None else _rect(term, place, image)
        return rect is not None and rect[1][0] >= 0

    def _delete_visible(self, term, delete_unused):
        """Delete only the pin placements that intersect the active screen (d=a and d=A): virtual
        placements stay, and an uppercase delete frees only the images those placements held."""
        for key in list(self.placements):
            if self._visible(term, self.placements[key], key):
                self._drop(key)
                if delete_unused:
                    self.delete_if_unused(key[0])

    def clear_screen(self, term):
        """clearScreen (ED 2 and ED 22): the visible placements go, then every image nothing
        uses."""
        self._delete_visible(term, True)
        self.reap_orphans()
        for image_id in list(self.images):
            self.delete_if_unused(image_id)

    def _delete_by_id_v14(self, image_id, placement_id, delete_unused):
        """deleteById: a placement id narrows the delete to that placement, and an id that matches
        none frees nothing (an image only goes when the delete matched)."""
        matched = placement_id == 0
        if placement_id == 0:
            for key in [key for key in self.placements if key[0] == image_id]:
                self._drop(key)
        elif (image_id, ("e", placement_id)) in self.placements:
            self._drop((image_id, ("e", placement_id)))
            matched = True
        if delete_unused and matched:
            self.delete_if_unused(image_id)

    def _delete_intersecting_v14(self, term, target, delete_unused, keep=None):
        """deleteIntersecting: Rect.contains checks the column and the row, so only a placement
        whose rectangle holds the cell goes (1.3.1 compared row-major, so a tall image went for a
        cell to the side of it)."""
        ty, tx = target
        for key in list(self.placements):
            image = self.images.get(key[0])
            if image is None:
                continue
            place = self.placements[key]
            rect = _rect(term, place, image)
            if rect is None:
                continue
            (y0, x0), (y1, x1) = rect
            if not (x0 <= tx <= x1 and y0 <= ty <= y1):
                continue
            if keep is not None and not keep(place):
                continue
            self._drop(key)
            if delete_unused:
                self.delete_if_unused(image.id)

    def _delete_v14(self, term, d):
        self._delete_kind_v14(term, d)
        # deleting placements orphans the relative placements parented to them
        self.reap_orphans(d.delete)

    def _delete_kind_v14(self, term, d):
        kind = d.kind
        if kind == "all":
            self._delete_visible(term, d.delete)
        elif kind == "id":
            self._delete_by_id_v14(d.image_id, d.placement_id, d.delete)
        elif kind == "newest":
            image = self.image_by_number(d.image_number)
            if image is not None:
                self._delete_by_id_v14(image.id, d.placement_id, d.delete)
        elif kind == "cursor":
            sc = term.active
            self._delete_intersecting_v14(term, (sc.y, sc.x), d.delete)
        elif kind in ("cell", "cell_z"):
            if d.x <= 0 or d.y <= 0:
                term.warnings.append("delete intersect cell coords must be at least 1")
                return
            if d.x - 1 >= term.cols or d.y - 1 >= term.rows:
                return
            keep = (lambda place: place.z == d.z) if kind == "cell_z" else None
            self._delete_intersecting_v14(term, (d.y - 1, d.x - 1), d.delete, keep)
        elif kind == "range":
            # an inverted range or a zero upper bound selects nothing (image ids are never 0);
            # the placements of the images in the range go, and an uppercase delete also frees the
            # images of the range that nothing uses, those that never had a placement included
            if d.last == 0 or d.first > d.last:
                return
            for key in list(self.placements):
                if d.first <= key[0] <= d.last:
                    self._drop(key)
            if d.delete:
                for image_id in [i for i in self.images if d.first <= i <= d.last]:
                    self.delete_if_unused(image_id)
        elif kind == "column":
            if d.x <= 0:
                term.warnings.append("delete column must be greater than zero")
                return
            x = d.x - 1
            for key in list(self.placements):
                image = self.images.get(key[0])
                if image is None:
                    continue
                rect = _rect(term, self.placements[key], image)
                if rect is not None and rect[0][1] <= x <= rect[1][1]:
                    self._drop(key)
                    if d.delete:
                        self.delete_if_unused(image.id)
        elif kind == "row":
            if d.y <= 0:
                term.warnings.append("delete row must be greater than zero")
                return
            if d.y - 1 >= term.rows:
                return
            y = d.y - 1
            for key in list(self.placements):
                image = self.images.get(key[0])
                if image is None:
                    continue
                rect = _rect(term, self.placements[key], image)
                if rect is not None and rect[0][0] <= y <= rect[1][0]:
                    self._drop(key)
                    if d.delete:
                        self.delete_if_unused(image.id)
        elif kind == "z":
            for key in list(self.placements):
                place = self.placements.get(key)
                if place is None or (place.location is None and place.relative is None) \
                        or place.z != d.z:
                    continue     # a virtual placement cannot be deleted by z; a relative one can
                self._drop(key)
                if d.delete:
                    self.delete_if_unused(key[0])
        elif kind == "frames":
            from vkitty import anim as _anim
            _anim.delete_frames(term, self, d)

    def delete(self, term, d):
        """graphics_storage.zig ImageStorage.delete for one Delete view."""
        if self.v14:
            return self._delete_v14(term, d)
        kind = d.kind
        if kind == "all":
            self.delete_all(d.delete)
        elif kind == "id":
            self._delete_by_id(d.image_id, d.placement_id, d.delete)
        elif kind == "newest":
            image = self.image_by_number(d.image_number)
            if image is not None:
                self._delete_by_id(image.id, d.placement_id, d.delete)
        elif kind == "cursor":
            sc = term.active
            self._delete_intersecting(term, (sc.y, sc.x), d.delete)
        elif kind == "cell":
            if d.x <= 0 or d.y <= 0:
                term.warnings.append("delete intersect cell coords must be at least 1")
                return
            if d.x - 1 >= term.cols or d.y - 1 >= term.rows:
                return
            self._delete_intersecting(term, (d.y - 1, d.x - 1), d.delete)
        elif kind == "cell_z":
            if d.x <= 0 or d.y <= 0:
                term.warnings.append("delete intersect cell coords must be at least 1")
                return
            if d.x - 1 >= term.cols or d.y - 1 >= term.rows:
                return
            self._delete_intersecting(term, (d.y - 1, d.x - 1), d.delete,
                                      keep=lambda place: place.z == d.z)
        elif kind == "range":
            self._delete_range(term, d)
        elif kind == "column":
            if d.x <= 0:
                term.warnings.append("delete column must be greater than zero")
                return
            x = d.x - 1
            for key in list(self.placements):
                image = self.images.get(key[0])
                if image is None:
                    continue
                rect = _rect(term, self.placements[key], image)
                if rect is not None and rect[0][1] <= x <= rect[1][1]:
                    self._drop(key)
                    if d.delete:
                        self.delete_if_unused(image.id)
        elif kind == "row":
            if d.y <= 0:
                term.warnings.append("delete row must be greater than zero")
                return
            if d.y - 1 >= term.rows:
                return
            y = d.y - 1
            for key in list(self.placements):
                image = self.images.get(key[0])
                if image is None:
                    continue
                rect = _rect(term, self.placements[key], image)
                if rect is not None and _between((y, rect[0][1]), rect[0], rect[1]):
                    self._drop(key)
                    if d.delete:
                        self.delete_if_unused(image.id)
        elif kind == "z":
            for key in list(self.placements):
                place = self.placements[key]
                if place.location is None or place.z != d.z:
                    continue
                self._drop(key)
                if d.delete:
                    self.delete_if_unused(key[0])
        elif kind == "frames":
            # d=f and d=F: kitty's animation frames (anim.py); Ghostty 1.3.1 has none, so nothing
            if term.profile == KITTY:
                from vkitty import anim as _anim
                _anim.delete_frames(term, self, d)

    def _delete_range(self, term, d):
        """d=r and d=R. Ghostty's test (image id >= x or <= y) holds for every placement, so
        Ghostty removes all of them and frees only the images whose placements it removed. Kitty
        removes the placements of the images x to y, whatever their placement id (its range
        filter ignores it), and for R frees the images that lose placements and have none left.
        Kitty's R first frees the images of the range that have no placement, but only without
        p (graphics.c handle_delete_command, the special case before the filter)."""
        if d.first <= 0 or d.last <= 0:
            term.warnings.append("delete range values must be greater than zero")
            return
        ghostty = is_ghostty(term.profile)
        if not ghostty and d.delete and d.placement_id == 0:
            for image_id in [i for i in self.images if d.first <= i <= d.last]:
                self.delete_if_unused(image_id)
        for key in list(self.placements):
            image_id = key[0]
            if not ghostty and not d.first <= image_id <= d.last:
                continue
            self._drop(key)
            if d.delete:
                self.delete_if_unused(image_id)


# --------------------------------------------------------------- execute ---

def _query(term, cmd, key):
    """a=q: load the data as a transmission would (so a file is read and removed) but store
    nothing; no PNG or dimension check."""
    t = cmd.transmission
    if t.image_id == 0:
        # graphics_exec.zig query returns the error with neither id nor number, so nothing is sent
        return Resp(message="EINVAL: image ID required")
    result = Resp(t.image_id, t.image_number, t.placement_id)
    try:
        loading = LoadingImage.start(term, cmd, key)
        if is_140(term.profile):
            loading.complete()      # 1.4.0 completes the load (PNG, size) and discards the image
    except MediaError as exc:
        result.message = exc.message
    return result


def _display_v14(term, storage, d):
    """display in Ghostty 1.4.0: a virtual placement with a parent is refused before the image is
    looked up; a placement made with P= is a relative one (stored, never drawn by the model); the
    X and Y offsets are kept inside the first cell; and with C=0 the cursor moves past the image by
    at most one screen of rows (index), to the column after it or, when that is past the right
    edge, to column 0 of the next row."""
    if d.image_id == 0 and d.image_number == 0:
        return Resp(message="EINVAL: image ID or number required")
    result = Resp(d.image_id, d.image_number, d.placement_id)
    if d.virtual and d.parent_id > 0:
        result.message = "EINVAL: virtual placement cannot refer to a parent"
        return result
    if d.image_id != 0:
        image = storage.image_by_id(d.image_id)
    else:
        image = storage.image_by_number(d.image_number)
    if image is None:
        result.message = "ENOENT: image not found"
        return result
    result.id = image.id
    location = None
    relative = None
    if d.parent_id > 0:
        child = (image.id, ("e", d.placement_id)) if d.placement_id > 0 else None
        parent, error = storage.resolve_parent(child, d.parent_id, d.parent_placement_id)
        if error is not None:
            result.message = error
            return result
        relative = (parent, d.horizontal_offset, d.vertical_offset)
        term.warnings.append("relative placement stored, not drawn (the model does not draw them)")
    elif not d.virtual:
        sc = term.active
        location = PinRef(sc.base + sc.y, sc.x)
    place = Placement(location, d.x_offset, d.y_offset, d.x, d.y, d.width, d.height,
                      d.columns, d.rows, d.z, relative)
    cell_w, cell_h = term.cell
    off_x, off_y = cell_offset(place, term)
    if cell_w > 0:
        place.x_offset = off_x
    if cell_h > 0:
        place.y_offset = off_y
    storage.add_placement(image.id, d.placement_id, place)
    if image.anim is not None:
        image.anim.is_drawn = True
    if location is not None and d.cursor == "after":
        cols, rows = grid_size(place, image, term)
        target_x = location.x + cols
        wraps = target_x >= term.cols
        requested = max(rows - 1, 0) + (1 if wraps else 0)
        sc = term.active
        in_region = term.top <= sc.y <= term.bottom
        before_scroll = term.bottom - sc.y if in_region else 0
        for _ in range(min(requested, before_scroll + term.rows)):
            term._index()
        sc.pending = False
        sc.x = 0 if wraps else target_x
    return result


def _display(term, storage, d):
    """display: the image is looked up by id, else by number; a pin records the cursor's row and
    column; with C=0 the cursor then moves past the image (Terminal.zig, as ported below)."""
    if is_140(term.profile):
        return _display_v14(term, storage, d)
    if d.image_id == 0 and d.image_number == 0:
        return Resp(message="EINVAL: image ID or number required")
    result = Resp(d.image_id, d.image_number, d.placement_id)
    if d.image_id != 0:
        image = storage.image_by_id(d.image_id)
    else:
        image = storage.image_by_number(d.image_number)
    if image is None:
        result.message = "ENOENT: image not found"
        return result
    result.id = image.id
    if d.virtual:
        if d.parent_id > 0:
            result.message = "EINVAL: virtual placement cannot refer to a parent"
            return result
        location = None
    else:
        sc = term.active
        location = PinRef(sc.base + sc.y, sc.x)
    place = Placement(location, d.x_offset, d.y_offset, d.x, d.y, d.width, d.height,
                      d.columns, d.rows, d.z)
    storage.add_placement(image.id, d.placement_id, place)
    if image.anim is not None:
        image.anim.is_drawn = True      # kitty sets is_drawn when the image has a visible placement
    if location is not None and d.cursor == "after":
        cols, rows = grid_size(place, image, term)
        for _ in range(rows):
            term._index()
        # Terminal.zig: setCursorPos(cursor.y, pin.x + cols + 1); the row argument is 1-based, so
        # the cursor's 0-based row lands on the image's last row
        term._set_pos(term.active.y, location.x + cols + 1)
    return result


def _load_and_add(term, storage, cmd, key, t):
    """graphics_exec.zig loadAndAddImage: a chunk continues the loading image (its keys other
    than m and q are ignored); the first chunk creates it. Returns (image, more, display)."""
    loading = storage.loading
    if loading is not None:
        loading.wire += cmd.wire
        loading.add_data(cmd.data)
        if t.more:
            return loading.image, True, None
        storage.loading = None
    else:
        if storage.v14 and t.image_id > 0:
            # reusing an image id removes the old image and all its placements when the new
            # transmission begins, not when it completes
            d = Delete()
            d.kind, d.delete, d.image_id, d.placement_id = "id", True, t.image_id, 0
            storage.delete(term, d)
        loading = LoadingImage.start(term, cmd, key)
    image = loading.image
    if image.id == 0 and storage.v14:
        image.id = storage.next_id(image.number > 0)
        image.implicit_id = image.number == 0
    elif image.id == 0:
        image.id = storage.next_image_id
        storage.next_image_id = (storage.next_image_id + 1) & _U32
        if image.number == 0:
            image.implicit_id = True
    if t.more:
        storage.loading = loading
        return image, True, None
    complete = loading.complete()
    storage.add_image(complete)
    entry = term.stats["by_image"].setdefault(
        str(complete.id), {"transmissions": 0, "wire_bytes": 0, "medium": loading.medium})
    entry["transmissions"] += 1
    entry["wire_bytes"] += loading.wire
    entry["medium"] = loading.medium
    complete.transmissions = entry["transmissions"]
    complete.wire_bytes = loading.wire
    complete.medium = loading.medium
    return complete, False, loading.display


def _transmit(term, storage, cmd, key):
    """graphics_exec.zig transmit: store the image; a T command also displays it."""
    t = cmd.transmission
    result = Resp(t.image_id, t.image_number, t.placement_id)
    if t.image_id > 0 and t.image_number > 0 and not storage.v14:
        # Ghostty builds this error without an id or a number, so nothing is encoded for it
        return Resp(message="EINVAL: image ID and number are mutually exclusive")
    try:
        image, more, display = _load_and_add(term, storage, cmd, key, t)
    except MediaError as exc:
        result.message = exc.message
        return result
    if display is not None:
        target = Display()
        for name in Display.__slots__:
            setattr(target, name, getattr(display, name))
        target.image_id = image.id
        result = _display(term, storage, target)
    if more:
        return Resp()
    if image.implicit_id:
        return Resp()
    result.id = image.id
    return result


def _animation(term, cmd):
    """a=f, a=a and a=c in the ghostty profile. Ghostty 1.3.1 answers an ERROR with no id, so
    nothing is sent; the error is logged. The ghostty_animation fault accepts the action instead
    (answers OK). The kitty profile never reaches here (anim.py runs its layer)."""
    name = "a=%s" % cmd.action
    if faults.active("ghostty_animation"):
        return encode_response(cmd.kv.get("i", 0), cmd.kv.get("I", 0), cmd.kv.get("p", 0),
                               "OK")
    term.warnings.append("unsupported by ghostty-1.3.1: %s" % name)
    term.warnings.append("erroneous kitty graphics response: ERROR: unimplemented action")
    return None


_GHOSTTY_ANIMATION_TEXT = (
    ("ENOENT:Animation command refers to non-existent image", "ENOENT: image not found"),
    ("ENOENT:No source frame number", "ENOENT: source frame not found"),
    ("ENOENT:No destination frame number", "ENOENT: destination frame not found"),
)


def _ghostty_text(resp):
    """The animation layer (anim.py) answers in kitty's words; the failures that Ghostty 1.4.0
    words differently for the same cause are put in its words. The other answers keep kitty's text
    (a known gap: the model follows kitty's layer for the animation, see the README)."""
    if resp is not None:
        for kitty_text, ghostty_text in _GHOSTTY_ANIMATION_TEXT:
            if resp.message.startswith(kitty_text):
                resp.message = ghostty_text
    return resp


def _answer(term, resp, quiet):
    """The quiet rules of execute: q=0 sends every non-empty answer, q=1 only errors, q=2 none.
    Every ENOENT counts, and every non-OK answer is logged, quiet or not. None (no answer due, as
    for a successful a=a or a chunk still loading) passes through."""
    if resp is None:
        return None
    if not resp.ok():
        term.warnings.append("erroneous kitty graphics response: %s" % resp.message)
    if resp.message.startswith("ENOENT"):
        term.stats["enoent"] += 1
    if quiet == 2:
        return None
    if quiet == 1 and resp.ok():
        return None
    return encode_response(resp.id, resp.number, resp.placement, resp.message, resp.frame)


def execute(term, cmd, key):
    """Execute one parsed command on the active screen of `term`. key is (channel, token start,
    token ordinal). Returns the answer bytes, or None when nothing is sent."""
    storage = term._kitty(term.active)
    if not storage.enabled():
        return None                      # the protocol is off on this screen (graphics_exec.zig)
    action = cmd.action
    kitty = term.profile == KITTY
    v14 = storage.v14
    animated = kitty or v14        # the profiles that run the animation layer (anim.py)
    if v14 and cmd.kv.get("i", 0) > 0 and cmd.kv.get("I", 0) > 0:
        # an image id and an image number exclude each other, whatever the action: checked before
        # the action runs and before it can change anything
        refusal = Resp(cmd.kv.get("i", 0), cmd.kv.get("I", 0), cmd.kv.get("p", 0),
                       "EINVAL: image ID and number are mutually exclusive")
        return _answer(term, refusal, cmd.quiet)
    if v14 and storage.loading is not None and action in ("t", "T", "f") \
            and cmd.transmission is not None and cmd.transmission.medium != "d":
        storage.loading = None     # only direct data comes in chunks: any other medium starts anew
    if action in ("t", "T", "q") or (action == "f" and animated):
        # a kitty a=f chunk is image data on the wire like any transmission chunk (a continuation
        # chunk of it has no action key, so it is an action t above); Ghostty runs no a=f at all
        term.stats["transmit_wire_bytes"] += cmd.wire
        term.stats["since_prev_mark"]["transmit_wire_bytes"] += cmd.wire
    if action == "q":
        term.stats["queries"] += 1
        return _answer(term, _query(term, cmd, key), cmd.quiet)
    frame_loading = storage.loading is not None and storage.loading.action == "f"
    if action == "f" or (action == "t" and frame_loading):
        # an a=f load, or a chunk of one (a continuation chunk carries no action key); its quiet
        # setting is the first chunk's unless this chunk names one (graphics.c grman_handle_command)
        quiet = cmd.quiet
        if frame_loading and cmd.quiet == 0:
            quiet = storage.loading.quiet
        if not animated:
            return _animation(term, cmd)
        from vkitty import anim as _anim
        reply = _anim.frame_command(term, storage, cmd, key)
        return _answer(term, _ghostty_text(reply) if v14 else reply, quiet)
    if action in ("t", "T"):
        quiet = cmd.quiet
        if storage.loading is not None:
            if cmd.quiet == 0:
                quiet = storage.loading.quiet
            else:
                storage.loading.quiet = cmd.quiet
        return _answer(term, _transmit(term, storage, cmd, key), quiet)
    if action == "p":
        return _answer(term, _display(term, storage, cmd.display), cmd.quiet)
    if action == "d":
        term.stats["deletes"] += 1
        if animated:
            storage.loading = None      # graphics.c handle_delete_command: free_load_data; 1.4.0:
                                        # every delete aborts an incomplete chunked upload
        storage.delete(term, cmd.delete)
        return None
    if not animated:
        return _animation(term, cmd)
    from vkitty import anim as _anim
    reply = _anim.command(term, storage, cmd, key)
    return _answer(term, _ghostty_text(reply) if v14 else reply, cmd.quiet)
