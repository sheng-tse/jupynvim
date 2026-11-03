"""Font faces for the headless renderer (render.py): which files draw which text, the glyph masks,
and the fallback chain for a code point the face does not carry.

faces() gives the four Iosevka Custom faces by style (regular, bold, italic, bold_italic). It is
$JNV_VKITTY_FONT_DIR when that folder holds the four full faces (IosevkaCustom-Regular.ttf,
-SemiBold.ttf, -Italic.ttf, -SemiBoldItalic.ttf), else the bundled subsets in tests/lib/vkitty/fonts
(fonts/SOURCE.txt says how they were made). Glyphs are rasterized by Pillow with RAQM shaping at 26
px (13 pt at content scale 2, the reference size); advances and the cmap come from fontTools.

A code point the face does not carry falls back, in order, to the full face of the same style when
it is installed (in $JNV_VKITTY_FONT_DIR, ~/Library/Fonts or ~/.local/share/fonts; the reference
renders used those files), then on macOS to Menlo, Apple Symbols, Apple Color Emoji (colour glyphs
keep their own colours) and Arial Unicode (CJK), on Linux to fc-match's DejaVu Sans Mono, Noto Sans
CJK SC and Noto Color Emoji (Ubuntu packages fonts-dejavu-core, fonts-noto-cjk and
fonts-noto-color-emoji; fontconfig must be installed). A code point that nothing carries has no
face: the renderer draws nothing and warns.
"""
import os
import subprocess
import sys
from collections import namedtuple

import numpy as np
from PIL import Image, ImageFont

PX = 26
BITMAP_STRIKE = 109   # the pixel size of the one strike of Noto Color Emoji
# Coverage gamma of the glyph masks (calibration, not a Ghostty rule): the reference renders are
# Chrome text on macOS, whose anti-aliased edges are heavier than FreeType's. Over the 41 reference
# shots (the calibration sweep) the mean SSIM is 0.9896 at gamma 1.0, 0.9928
# at 0.7, 0.9938 at 0.6 and 0.9945 at 0.5, and the gain holds on every shot. 0.6 is used: most of
# the gain, without the extra weight of 0.5 or less.
COVERAGE_GAMMA = 0.6
_COVERAGE_LUT = ((np.arange(256, dtype=np.float64) / 255.0) ** COVERAGE_GAMMA).astype(np.float32)
STYLES = ("regular", "bold", "italic", "bold_italic")
FULL_NAMES = {
    "regular": "IosevkaCustom-Regular.ttf",
    "bold": "IosevkaCustom-SemiBold.ttf",
    "italic": "IosevkaCustom-Italic.ttf",
    "bold_italic": "IosevkaCustom-SemiBoldItalic.ttf",
}
SUBSET_NAMES = {style: name.replace(".ttf", ".subset.ttf") for style, name in FULL_NAMES.items()}
BUNDLED_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fonts")

_MAC_FALLBACKS = (
    ("/System/Library/Fonts/Menlo.ttc", 0, False),
    ("/System/Library/Fonts/Apple Symbols.ttf", 0, False),
    ("/System/Library/Fonts/Apple Color Emoji.ttc", 0, True),
    # last: the CJK faces (the Supplemental folder has Arial Unicode on current macOS); the
    # reference renders of CJK text draw from a system font, and nothing above carries these code
    # points
    ("/System/Library/Fonts/Supplemental/Arial Unicode.ttf", 0, False),
)
_LINUX_FALLBACKS = (
    ("DejaVu Sans Mono", False),
    ("Noto Sans CJK SC", False),     # CJK; fc-match answers the default face when it is not there
    ("Noto Color Emoji", True),
)

Glyph = namedtuple("Glyph", "alpha ox oy rgb")
# alpha: float32 (h, w) in [0, 1]; ox, oy: the top left corner of alpha relative to the origin
# (the baseline, left); rgb: float32 (h, w, 3) for a colour glyph, else None


def faces():
    """{style: path} for the four Iosevka Custom faces, the full files or the bundled subsets."""
    folder = os.environ.get("JNV_VKITTY_FONT_DIR", "")
    if folder and all(os.path.isfile(os.path.join(folder, name)) for name in FULL_NAMES.values()):
        return {style: os.path.join(folder, FULL_NAMES[style]) for style in STYLES}
    return {style: os.path.join(BUNDLED_DIR, SUBSET_NAMES[style]) for style in STYLES}


def _full_face_path(style):
    """The installed full face of a style (the reference renders' GRegular and friends), if any."""
    folders = []
    env = os.environ.get("JNV_VKITTY_FONT_DIR", "")
    if env:
        folders.append(env)
    folders.append(os.path.expanduser("~/Library/Fonts"))
    folders.append(os.path.expanduser("~/.local/share/fonts"))
    for folder in folders:
        path = os.path.join(folder, FULL_NAMES[style])
        if os.path.isfile(path):
            return path
    return None


def _fc_match(family):
    """The file fontconfig picks for a family, or None."""
    try:
        out = subprocess.run(["fc-match", "-f", "%{file}", family], capture_output=True,
                             text=True, timeout=10, check=False).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return None
    return out if out and os.path.isfile(out) else None


class Face:
    """One font file at PX pixels: the Pillow font, and the cmap and advances from fontTools."""

    def __init__(self, path, index=0, color=False):
        self.path = path
        self.index = index
        self.color = color
        self.scale = 1.0
        try:
            self.font = ImageFont.truetype(path, PX, index=index,
                                           layout_engine=ImageFont.Layout.RAQM)
        except OSError:
            if not color:
                raise
            # a color bitmap font (Noto Color Emoji, CBDT) has one strike and no other size
            # ("invalid pixel size"): the glyphs are drawn at the strike and scaled to PX
            self.font = ImageFont.truetype(path, BITMAP_STRIKE, index=index,
                                           layout_engine=ImageFont.Layout.RAQM)
            self.scale = PX / BITMAP_STRIKE
        self._cmap = None
        self._hmtx = None
        self._upm = 1000

    def _load(self):
        from fontTools.ttLib import TTFont
        font = TTFont(self.path, fontNumber=self.index, lazy=True)
        self._cmap = font.getBestCmap() or {}
        self._hmtx = font["hmtx"].metrics
        self._upm = font["head"].unitsPerEm
        font.close()

    def covers(self, cp):
        if self._cmap is None:
            self._load()
        return cp in self._cmap

    def advance(self, cp):
        """The advance of cp in font units (1000 per em), or None when the face lacks it."""
        if self._cmap is None:
            self._load()
        name = self._cmap.get(cp)
        if name is None:
            return None
        return self._hmtx[name][0]

    def mask(self, text):
        """The rasterized text at the origin (left, baseline), or None when it draws nothing."""
        if self.color:
            raw = self.font.getmask2(text, mode="RGBA", embedded_color=True, anchor="ls")
            img = np.asarray(Image.Image()._new(raw[0]))
            if img.size == 0:
                return None
            origin = (raw[1][0], raw[1][1])
            if self.scale != 1.0:
                small = Image.fromarray(img, "RGBA").resize(
                    (max(1, round(img.shape[1] * self.scale)),
                     max(1, round(img.shape[0] * self.scale))), Image.Resampling.LANCZOS)
                img = np.asarray(small)
                origin = (round(origin[0] * self.scale), round(origin[1] * self.scale))
            rgb = img[..., :3].astype(np.float32)
            alpha = img[..., 3].astype(np.float32) / 255.0
            return Glyph(alpha, origin[0], origin[1], rgb)
        raw = self.font.getmask2(text, mode="L", anchor="ls")
        img = np.asarray(Image.Image()._new(raw[0]))
        if img.size == 0:
            return None
        return Glyph(_COVERAGE_LUT[img], raw[1][0], raw[1][1], None)


class _Store:
    """The faces in use: the primary face of each style, the fallbacks of each style, and the glyph
    masks, all loaded on first use and kept until drop()."""

    def __init__(self):
        self.primary = {}
        self.by_path = {}
        self.fallbacks = {}
        self.glyphs = {}

    def face(self, path, index=0, color=False):
        key = (path, index)
        got = self.by_path.get(key)
        if got is None:
            got = Face(path, index, color)
            self.by_path[key] = got
        return got

    def primary_face(self, style):
        got = self.primary.get(style)
        if got is None:
            got = self.face(faces()[style])
            self.primary[style] = got
        return got

    def fallback_faces(self, style):
        got = self.fallbacks.get(style)
        if got is not None:
            return got
        out = []
        full = _full_face_path(style)
        if full is not None:
            out.append(self.face(full))
        if sys.platform == "darwin":
            for path, index, color in _MAC_FALLBACKS:
                if os.path.isfile(path):
                    out.append(self.face(path, index, color))
        elif sys.platform.startswith("linux"):
            for family, color in _LINUX_FALLBACKS:
                path = _fc_match(family)
                if path is None:
                    continue
                try:
                    out.append(self.face(path, 0, color))
                except OSError:
                    pass     # a file Pillow cannot load is not a fallback; its code points warn
        self.fallbacks[style] = out
        return out


_STORE = None


def _store():
    global _STORE
    if _STORE is None:
        _STORE = _Store()
    return _STORE


def drop():
    """Forget every loaded face and glyph (the next use loads them again)."""
    global _STORE
    _STORE = None


def primary(style):
    """The primary face of a style (the subset or the installed full face)."""
    return _store().primary_face(style)


def coverage(style, cp):
    """True when the primary face of the style carries cp (the reference's cov flag)."""
    return _store().primary_face(style).covers(cp)


def advance(style, cp):
    """The primary face's advance of cp in font units, or None."""
    return _store().primary_face(style).advance(cp)


def face_for(style, cp):
    """The face that draws cp in a style: the primary face when it carries cp, else the first
    fallback that does, else None."""
    store = _store()
    primary = store.primary_face(style)
    if primary.covers(cp):
        return primary
    for face in store.fallback_faces(style):
        if face.covers(cp):
            return face
    return None


def glyph(face, text):
    """The glyph mask of text drawn with face (cached on the face and the text), or None."""
    store = _store()
    key = (face.path, face.index, text)
    if key in store.glyphs:
        return store.glyphs[key]
    got = face.mask(text)
    store.glyphs[key] = got
    return got
