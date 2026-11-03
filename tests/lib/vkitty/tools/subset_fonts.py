"""Subset the IosevkaCustom faces that the headless renderer draws with.

    python3 -I tests/lib/vkitty/tools/subset_fonts.py [--src-dir DIR] [--out DIR]

Reads IosevkaCustom-{Regular,SemiBold,Italic,SemiBoldItalic}.ttf from --src-dir (default
~/Library/Fonts) and writes four .subset.ttf files into --out (default: the fonts folder
beside this tools folder). Each subset is fontTools.subset over UNICODES with every layout
feature and the hinting kept. The same run writes SOURCE.txt (the source and subset sha256,
the ranges, the fontTools version and the command) and OFL.txt (the SIL Open Font License 1.1
with the copyright line of the font's name table, ID 0). The output is deterministic: a second
run writes the same bytes. render/fonts_sha in tests/vkitty_spec.py checks the subset sha256
values in SOURCE.txt.

Exit status: 0 when every file was written, 2 on a usage error or a missing source font.
"""
import argparse
import hashlib
import os
import sys

sys.dont_write_bytecode = True   # a run of the harness writes no bytecode into the repository tree

FACES = (
    ("IosevkaCustom-Regular.ttf", "IosevkaCustom-Regular.subset.ttf"),
    ("IosevkaCustom-SemiBold.ttf", "IosevkaCustom-SemiBold.subset.ttf"),
    ("IosevkaCustom-Italic.ttf", "IosevkaCustom-Italic.subset.ttf"),
    ("IosevkaCustom-SemiBoldItalic.ttf", "IosevkaCustom-SemiBoldItalic.subset.ttf"),
)

UNICODES = ("U+0020-007E,U+00A0-017F,U+0370-03FF,U+0400-045F,U+2000-206F,U+20A0-20BF,"
            "U+2100-214F,U+2190-21FF,U+2200-22FF,U+2300-23FF,U+2460-24FF,U+2500-259F,"
            "U+25A0-25FF,U+2600-26FF,U+2700-27BF,U+E0A0-E0D7")

OFL_BODY = r"""This Font Software is licensed under the SIL Open Font License, Version 1.1.
This license is copied below, and is also available with a FAQ at:
https://openfontlicense.org


-----------------------------------------------------------
SIL OPEN FONT LICENSE Version 1.1 - 26 February 2007
-----------------------------------------------------------

PREAMBLE
The goals of the Open Font License (OFL) are to stimulate worldwide
development of collaborative font projects, to support the font creation
efforts of academic and linguistic communities, and to provide a free and
open framework in which fonts may be shared and improved in partnership
with others.

The OFL allows the licensed fonts to be used, studied, modified and
redistributed freely as long as they are not sold by themselves. The
fonts, including any derivative works, can be bundled, embedded,
redistributed and/or sold with any software provided that any reserved
names are not used by derivative works. The fonts and derivatives,
however, cannot be released under any other type of license. The
requirement for fonts to remain under this license does not apply
to any document created using the fonts or their derivatives.

DEFINITIONS
"Font Software" refers to the set of files released by the Copyright
Holder(s) under this license and clearly marked as such. This may
include source files, build scripts and documentation.

"Reserved Font Name" refers to any names specified as such after the
copyright statement(s).

"Original Version" refers to the collection of Font Software components as
distributed by the Copyright Holder(s).

"Modified Version" refers to any derivative made by adding to, deleting,
or substituting -- in part or in whole -- any of the components of the
Original Version, by changing formats or by porting the Font Software to a
new environment.

"Author" refers to any designer, engineer, programmer, technical
writer or other person who contributed to the Font Software.

PERMISSION & CONDITIONS
Permission is hereby granted, free of charge, to any person obtaining
a copy of the Font Software, to use, study, copy, merge, embed, modify,
redistribute, and sell modified and unmodified copies of the Font
Software, subject to the following conditions:

1) Neither the Font Software nor any of its individual components,
in Original or Modified Versions, may be sold by itself.

2) Original or Modified Versions of the Font Software may be bundled,
redistributed and/or sold with any software, provided that each copy
contains the above copyright notice and this license. These can be
included either as stand-alone text files, human-readable headers or
in the appropriate machine-readable metadata fields within text or
binary files as long as those fields can be easily viewed by the user.

3) No Modified Version of the Font Software may use the Reserved Font
Name(s) unless explicit written permission is granted by the corresponding
Copyright Holder. This restriction only applies to the primary font name as
presented to the users.

4) The name(s) of the Copyright Holder(s) or the Author(s) of the Font
Software shall not be used to promote, endorse or advertise any
Modified Version, except to acknowledge the contribution(s) of the
Copyright Holder(s) and the Author(s) or with their explicit written
permission.

5) The Font Software, modified or unmodified, in part or in whole,
must be distributed entirely under this license, and must not be
distributed under any other license. The requirement for fonts to
remain under this license does not apply to any document created
using the Font Software.

TERMINATION
This license becomes null and void if any of the above conditions are
not met.

DISCLAIMER
THE FONT SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO ANY WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT
OF COPYRIGHT, PATENT, TRADEMARK, OR OTHER RIGHT. IN NO EVENT SHALL THE
COPYRIGHT HOLDER BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
INCLUDING ANY GENERAL, SPECIAL, INDIRECT, INCIDENTAL, OR CONSEQUENTIAL
DAMAGES, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
FROM, OUT OF THE USE OR INABILITY TO USE THE FONT SOFTWARE OR FROM
OTHER DEALINGS IN THE FONT SOFTWARE.
"""

TOOLS = os.path.dirname(os.path.abspath(__file__))
FONTS = os.path.normpath(os.path.join(TOOLS, "..", "fonts"))


def _sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as fh:
        for block in iter(lambda: fh.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def _subset_args(src, dst):
    return [src, "--unicodes=" + UNICODES, "--layout-features=*", "--name-IDs=0,1,2,3,4,5,6,13,14",
            "--name-languages=*", "--output-file=" + dst]


def _copyright(src):
    from fontTools.ttLib import TTFont
    font = TTFont(src, lazy=True)
    line = font["name"].getDebugName(0)
    font.close()
    if not line or not line.isascii():
        raise ValueError("name ID 0 of %s is missing or not ASCII" % src)
    return line


def source_label(folder):
    """The folder a SOURCE.txt line names for a source font: the one actually read, as an absolute
    path with the home folder shown as ~ (the file is committed, and a home folder differs)."""
    path = os.path.abspath(os.path.expanduser(folder))
    home = os.path.expanduser("~").rstrip(os.sep)
    if home and (path == home or path.startswith(home + os.sep)):
        return "~" + path[len(home):]
    return path


def main(argv):
    parser = argparse.ArgumentParser(prog="subset_fonts.py")
    parser.add_argument("--src-dir", default=os.path.expanduser("~/Library/Fonts"))
    parser.add_argument("--out", default=FONTS)
    try:
        args = parser.parse_args(argv)
    except SystemExit:
        return 2
    sources = [os.path.join(args.src_dir, name) for name, _ in FACES]
    missing = [path for path in sources if not os.path.isfile(path)]
    if missing:
        print("subset_fonts: missing source font(s): %s" % ", ".join(missing), file=sys.stderr)
        return 2
    os.makedirs(args.out, exist_ok=True)
    import fontTools
    from fontTools import subset
    lines = [
        "IosevkaCustom subsets for the headless renderer (tests/lib/vkitty/fonts).",
        "",
        "Upstream: Iosevka by Renzhi Li (aka Belleve Invis), SIL Open Font License 1.1 (OFL.txt).",
        "Copyright line (name ID 0 of the Regular source): " + _copyright(sources[0]),
        "Tool: tests/lib/vkitty/tools/subset_fonts.py",
        "fontTools: " + fontTools.version,
        "Unicode ranges: " + UNICODES,
        "Layout features: all (--layout-features=*); names 0 to 6, 13 and 14 kept; hinting kept.",
        "",
    ]
    for (name, subname), src in zip(FACES, sources):
        dst = os.path.join(args.out, subname)
        if os.path.exists(dst):
            os.remove(dst)
        subset.main(_subset_args(src, dst))
        if not os.path.isfile(dst):
            print("subset_fonts: fontTools wrote no %s" % dst, file=sys.stderr)
            return 2
        lines.append("face: " + subname)
        lines.append("  source: %s/%s sha256 %s bytes %d"
                     % (source_label(args.src_dir), name, _sha256(src), os.path.getsize(src)))
        lines.append("  subset: %s sha256 %s bytes %d"
                     % (subname, _sha256(dst), os.path.getsize(dst)))
        lines.append("  command: fontTools.subset %s %s"
                     % (name, " ".join(_subset_args("SOURCE", "SUBSET")[1:])))
    with open(os.path.join(args.out, "SOURCE.txt"), "w", encoding="ascii", newline="\n") as fh:
        fh.write("\n".join(lines) + "\n")
    with open(os.path.join(args.out, "OFL.txt"), "w", encoding="ascii", newline="\n") as fh:
        fh.write(_copyright(sources[0]) + "\n\n" + OFL_BODY)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
