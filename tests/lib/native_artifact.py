#!/usr/bin/env python3
"""Check a built libjupynvim file: what Neovim will load, before it ships.

    python3 -I tests/lib/native_artifact.py LIB (--target TRIPLE | --host)
                                            [--header H] [--max-glibc X.Y]
    python3 -I tests/lib/native_artifact.py --self-test

Checks, each printed as `ok ...` or `FAIL ...`:
  format        ELF64 little endian ET_DYN with e_machine 62 (x86_64) or 183
                (aarch64), or a 64-bit Mach-O dylib with cputype 0x01000007
                (x86_64) or 0x0100000c (arm64), matching the target
                (--target TRIPLE, a Rust triple such as
                x86_64-unknown-linux-gnu.2.17, or --host for this machine)
  exports       the library's defined jnv_ exports equal the jnv_ functions
                declared between the JNV-CDEF markers of the header (default
                core/native/include/jupynvim.h of this repo). ELF: .dynsym,
                defined GLOBAL FUNC symbols; Mach-O: the external defined
                symbols of the symbol table (what nm -gU lists), without the
                leading underscore
  dependencies  ELF DT_NEEDED and Mach-O load commands name only system
                libraries (the lists below)
  identity      ELF DT_SONAME libjupynvim.so; Mach-O install name
                @rpath/libjupynvim.dylib
  nodelete      ELF only: DT_FLAGS_1 has DF_1_NODELETE, so no dlclose can
                unmap code a worker thread may still run
  glibc         with --max-glibc X.Y (ELF only): the highest GLIBC_x.y
                version the library needs (.gnu.version_r) is at most X.Y
It also prints the file size (no budget: the library grows on purpose). The
last line is `ALL ARTIFACT CHECKS PASSED` (exit 0) or `<n> ARTIFACT CHECKS
FAILED` (exit 1); a usage error exits 2.

--self-test runs the checks that need no library on synthetic input: the
nodelete check on raw .dynamic entries (DT_FLAGS_1 = 0x9 must pass, 0x1 must
fail), and the target, version and header parsers. It exits non-zero when a
verdict is wrong.

The file is read directly (no nm, otool or readelf), so any host can check
any target's file and no tool on PATH can change the answer. Stdlib only.
"""
import os
import platform
import re
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_HEADER = os.path.join(HERE, "..", "..", "core", "native", "include", "jupynvim.h")

ELF_MACHINE = {"x86_64": 62, "aarch64": 183}
MACHO_CPU = {"x86_64": 0x01000007, "aarch64": 0x0100000C}
ELF_DEPS = {"libc.so.6", "libm.so.6", "libpthread.so.0", "libdl.so.2", "librt.so.1",
            "libgcc_s.so.1", "ld-linux-x86-64.so.2", "ld-linux-aarch64.so.1"}
MACHO_DEPS = {"/usr/lib/libSystem.B.dylib", "/usr/lib/libiconv.2.dylib",
              "/usr/lib/libresolv.9.dylib"}
ELF_SONAME = "libjupynvim.so"
MACHO_ID = "@rpath/libjupynvim.dylib"

# ELF constants
ET_DYN = 3
SHT_DYNAMIC, SHT_DYNSYM, SHT_GNU_VERNEED = 6, 11, 0x6FFFFFFE
DT_NULL, DT_NEEDED, DT_SONAME, DT_FLAGS_1 = 0, 1, 14, 0x6FFFFFFB
DF_1_NODELETE = 0x8
STB_GLOBAL, STT_FUNC, SHN_UNDEF = 1, 2, 0

# Mach-O constants
MH_MAGIC_64, FAT_MAGIC, MH_DYLIB = 0xFEEDFACF, 0xCAFEBABE, 6
LC_SYMTAB, LC_DYSYMTAB, LC_ID_DYLIB = 0x2, 0xB, 0xD
LC_DEP = {0xC: "LC_LOAD_DYLIB", 0x80000018: "LC_LOAD_WEAK_DYLIB",
          0x8000001F: "LC_REEXPORT_DYLIB", 0x20: "LC_LAZY_LOAD_DYLIB",
          0x80000023: "LC_LOAD_UPWARD_DYLIB"}
N_STAB, N_TYPE, N_EXT, N_UNDF = 0xE0, 0x0E, 0x01, 0x0


class Report:
    def __init__(self):
        self.failed = 0

    def check(self, ok, what):
        print(("ok " if ok else "FAIL ") + what)
        if not ok:
            self.failed += 1
        return ok


# ── pure helpers (the self-test covers these) ──────────────────────────────

def parse_target(triple):
    """(os, arch) of a Rust target triple: os is 'linux' or 'macos', arch
    'x86_64' or 'aarch64'. A cargo-zigbuild glibc suffix (.2.17) is ignored.
    Anything else raises ValueError."""
    t = re.sub(r"\.\d+(\.\d+)*$", "", triple)
    arch = t.split("-", 1)[0]
    arch = {"arm64": "aarch64"}.get(arch, arch)
    if arch not in ELF_MACHINE:
        raise ValueError("no library is built for the architecture of " + triple)
    if t.endswith("-apple-darwin"):
        return "macos", arch
    if "-linux-gnu" in t:
        return "linux", arch
    raise ValueError("no library is built for " + triple + " (only glibc Linux and macOS)")


def host_target():
    system = platform.system()
    machine = platform.machine().lower()
    arch = {"arm64": "aarch64", "aarch64": "aarch64", "x86_64": "x86_64", "amd64": "x86_64"}.get(machine)
    osname = {"Darwin": "macos", "Linux": "linux"}.get(system)
    if not arch or not osname:
        raise ValueError("this host (%s %s) has no library target" % (system, machine))
    return osname, arch


def header_functions(text):
    """The jnv_ function names declared between the CDEF markers."""
    m = re.search(r"/\* JNV-CDEF-BEGIN \*/(.*?)/\* JNV-CDEF-END \*/", text, re.S)
    if not m:
        raise ValueError("no JNV-CDEF-BEGIN ... JNV-CDEF-END block")
    return set(re.findall(r"\b(jnv_\w+)\s*\(", m.group(1)))


def nodelete_verdict(dynamic):
    """The nodelete check over the raw bytes of an ELF64 LE .dynamic section:
    (ok, detail). Entries are (d_tag int64, d_val uint64) up to DT_NULL."""
    flags = None
    for off in range(0, len(dynamic) - 15, 16):
        tag, val = struct.unpack_from("<qQ", dynamic, off)
        if tag == DT_NULL:
            break
        if tag == DT_FLAGS_1:
            flags = val
    if flags is None:
        return False, "no DT_FLAGS_1 entry, so DF_1_NODELETE is not set"
    if flags & DF_1_NODELETE:
        return True, "DT_FLAGS_1 0x%x has DF_1_NODELETE" % flags
    return False, "DT_FLAGS_1 0x%x lacks DF_1_NODELETE (0x8)" % flags


def glibc_max(names):
    """The highest GLIBC_x.y[.z] among version names as a tuple (or None),
    and the GLIBC_ names that carry no number."""
    best, odd = None, []
    for n in names:
        if not n.startswith("GLIBC_"):
            continue
        m = re.fullmatch(r"GLIBC_(\d+(?:\.\d+)*)", n)
        if not m:
            odd.append(n)
            continue
        v = tuple(int(x) for x in m.group(1).split("."))
        if best is None or v > best:
            best = v
    return best, odd


def cstr(data, off):
    end = data.find(b"\0", off)
    if end < 0:
        raise ValueError("unterminated string at %d" % off)
    return data[off:end].decode("utf-8", "replace")


def verneed_names(data, off, count, strtab_off):
    """Version names of the Vernaux records of a .gnu.version_r section."""
    names = []
    for _ in range(count):
        _ver, cnt, _file, aux, nxt = struct.unpack_from("<HHIII", data, off)
        a = off + aux
        for _ in range(cnt):
            _hash, _flags, _other, name, anext = struct.unpack_from("<IHHII", data, a)
            names.append(cstr(data, strtab_off + name))
            if not anext:
                break
            a += anext
        if not nxt:
            break
        off += nxt
    return names


def vstr(v):
    return ".".join(str(x) for x in v)


# ── ELF ────────────────────────────────────────────────────────────────────

def elf_sections(data):
    (_ident, e_type, e_machine, _ver, _entry, _phoff, e_shoff, _flags, _ehsize, _phentsize,
     _phnum, e_shentsize, e_shnum, e_shstrndx) = struct.unpack_from("<16sHHIQQQIHHHHHH", data, 0)
    secs = []
    if e_shoff:
        first = struct.unpack_from("<IIQQQQIIQQ", data, e_shoff)
        n = e_shnum or first[5]  # extended numbering keeps the count in section 0
        for i in range(n):
            secs.append(struct.unpack_from("<IIQQQQIIQQ", data, e_shoff + i * e_shentsize))
    return e_type, e_machine, secs


def check_elf(data, rep, osname, arch, want_funcs, max_glibc):
    if data[4] != 2 or data[5] != 1:
        rep.check(False, "format: ELF but not 64-bit little endian (class %d, data %d)" % (data[4], data[5]))
        return
    e_type, e_machine, secs = elf_sections(data)
    rev = {v: k for k, v in ELF_MACHINE.items()}
    rep.check(e_type == ET_DYN and osname == "linux" and e_machine == ELF_MACHINE[arch],
              "format: ELF64 LE %s, machine %d (%s); the target wants a %s %s shared object" % (
                  "ET_DYN" if e_type == ET_DYN else "e_type %d (not ET_DYN)" % e_type,
                  e_machine, rev.get(e_machine, "unknown"), osname, arch))

    def find(kind):
        return [s for s in secs if s[1] == kind]

    # exports
    dynsym = find(SHT_DYNSYM)
    if not dynsym:
        rep.check(False, "exports: no .dynsym section")
    else:
        s = dynsym[0]
        stroff = secs[s[6]][4]
        got = set()
        for off in range(s[4], s[4] + s[5], 24):
            st_name, st_info, _other, st_shndx, _value, _size = struct.unpack_from("<IBBHQQ", data, off)
            if st_shndx == SHN_UNDEF or st_info >> 4 != STB_GLOBAL or st_info & 0xF != STT_FUNC:
                continue
            name = cstr(data, stroff + st_name)
            if name.startswith("jnv_"):
                got.add(name)
        exports_verdict(rep, got, want_funcs)

    # the dynamic section: dependencies, soname, flags
    dyn = find(SHT_DYNAMIC)
    if not dyn:
        rep.check(False, "dependencies: no .dynamic section")
        rep.check(False, "identity: no .dynamic section")
        rep.check(False, "nodelete: no .dynamic section")
    else:
        d = dyn[0]
        raw = data[d[4]:d[4] + d[5]]
        stroff = secs[d[6]][4]
        needed, soname = [], None
        for off in range(0, len(raw) - 15, 16):
            tag, val = struct.unpack_from("<qQ", raw, off)
            if tag == DT_NULL:
                break
            if tag == DT_NEEDED:
                needed.append(cstr(data, stroff + val))
            elif tag == DT_SONAME:
                soname = cstr(data, stroff + val)
        extra = [n for n in needed if n not in ELF_DEPS]
        rep.check(not extra, "dependencies: DT_NEEDED %s%s" % (
            ", ".join(needed) or "(none)", "; not allowed: " + ", ".join(extra) if extra else ""))
        rep.check(soname == ELF_SONAME, "identity: DT_SONAME %s (want %s)" % (soname, ELF_SONAME))
        ok, detail = nodelete_verdict(raw)
        rep.check(ok, "nodelete: " + detail)

    if max_glibc is not None:
        vr = find(SHT_GNU_VERNEED)
        names = []
        if vr:
            s = vr[0]
            names = verneed_names(data, s[4], s[7], secs[s[6]][4])
        best, odd = glibc_max(names)
        ok = (best is None or best <= max_glibc) and not odd
        rep.check(ok, "glibc: highest version needed %s, at most %s allowed%s" % (
            "GLIBC_" + vstr(best) if best else "(none)", vstr(max_glibc),
            "; unversioned: " + ", ".join(odd) if odd else ""))


# ── Mach-O ─────────────────────────────────────────────────────────────────

def check_macho(data, rep, osname, arch, want_funcs, max_glibc):
    _magic, cputype, _sub, filetype, ncmds, _sizeofcmds, _flags, _res = struct.unpack_from("<IiiIIIII", data, 0)
    cputype &= 0xFFFFFFFF
    rev = {v: k for k, v in MACHO_CPU.items()}
    rep.check(filetype == MH_DYLIB and osname == "macos" and cputype == MACHO_CPU[arch],
              "format: Mach-O 64 %s, cputype 0x%08x (%s); the target wants a %s %s dylib" % (
                  "dylib" if filetype == MH_DYLIB else "filetype %d (not a dylib)" % filetype,
                  cputype, rev.get(cputype, "unknown"), osname, arch))
    off = 32
    ident, deps, symtab, dysymtab = None, [], None, None
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", data, off)
        if cmd == LC_ID_DYLIB or cmd in LC_DEP:
            name = cstr(data, off + struct.unpack_from("<I", data, off + 8)[0])
            if cmd == LC_ID_DYLIB:
                ident = name
            else:
                deps.append(name)
        elif cmd == LC_SYMTAB:
            symtab = struct.unpack_from("<IIII", data, off + 8)
        elif cmd == LC_DYSYMTAB:
            dysymtab = struct.unpack_from("<IIIIII", data, off + 8)
        if size < 8:
            raise ValueError("load command of size %d" % size)
        off += size

    if symtab is None:
        rep.check(False, "exports: no LC_SYMTAB")
    else:
        symoff, nsyms, stroff, _strsize = symtab
        first, count = 0, nsyms
        if dysymtab is not None:
            first, count = dysymtab[2], dysymtab[3]  # iextdefsym, nextdefsym
        got = set()
        for i in range(first, first + count):
            n_strx, n_type, _sect, _desc, _value = struct.unpack_from("<IBBHQ", data, symoff + 16 * i)
            if n_type & N_STAB or not n_type & N_EXT or n_type & N_TYPE == N_UNDF:
                continue
            name = cstr(data, stroff + n_strx)
            if name.startswith("_jnv_"):
                got.add(name[1:])
        exports_verdict(rep, got, want_funcs)

    extra = [d for d in deps if d not in MACHO_DEPS]
    rep.check(not extra, "dependencies: %s%s" % (", ".join(deps) or "(none)",
                                                 "; not allowed: " + ", ".join(extra) if extra else ""))
    rep.check(ident == MACHO_ID, "identity: install name %s (want %s)" % (ident, MACHO_ID))
    if max_glibc is not None:
        rep.check(False, "glibc: --max-glibc is for ELF (glibc) files, not Mach-O")


def exports_verdict(rep, got, want):
    missing, extra = sorted(want - got), sorted(got - want)
    detail = "%d jnv_ exports, %d jnv_ functions in the header" % (len(got), len(want))
    if missing:
        detail += "; missing: " + ", ".join(missing)
    if extra:
        detail += "; not in the header: " + ", ".join(extra)
    rep.check(not missing and not extra and bool(want), "exports: " + detail)


# ── main ───────────────────────────────────────────────────────────────────

def check_file(path, target, header, max_glibc):
    rep = Report()
    print("native artifact: %s (target %s %s)" % (path, target[0], target[1]))
    try:
        with open(header, "r", encoding="utf-8") as f:
            want = header_functions(f.read())
    except (OSError, ValueError) as e:
        rep.check(False, "header %s: %s" % (header, e))
        want = set()
    try:
        with open(path, "rb") as f:
            data = f.read()
    except OSError as e:
        rep.check(False, "read %s: %s" % (path, e))
        return finish(rep)
    print("size %d bytes (%.1f KiB)" % (len(data), len(data) / 1024.0))
    try:
        if data[:4] == b"\x7fELF":
            check_elf(data, rep, target[0], target[1], want, max_glibc)
        elif len(data) >= 32 and struct.unpack_from("<I", data, 0)[0] == MH_MAGIC_64:
            check_macho(data, rep, target[0], target[1], want, max_glibc)
        elif len(data) >= 4 and struct.unpack_from(">I", data, 0)[0] == FAT_MAGIC:
            rep.check(False, "format: a universal (fat) Mach-O; each target ships its own file")
        else:
            rep.check(False, "format: neither ELF nor 64-bit little-endian Mach-O (starts %r)" % data[:8])
    except (struct.error, ValueError, IndexError, UnicodeDecodeError) as e:
        rep.check(False, "the file is truncated or malformed: %s" % e)
    return finish(rep)


def finish(rep):
    if rep.failed:
        print("%d ARTIFACT CHECKS FAILED" % rep.failed)
        return 1
    print("ALL ARTIFACT CHECKS PASSED")
    return 0


def self_test():
    rep = Report()

    def dyn(*entries):
        return b"".join(struct.pack("<qQ", t, v) for t, v in entries) + struct.pack("<qQ", DT_NULL, 0)

    cases = [
        ("DT_FLAGS_1 = 0x9 (NOW | NODELETE) passes", dyn((DT_SONAME, 1), (DT_FLAGS_1, 0x9)), True),
        ("DT_FLAGS_1 = 0x1 (NOW only) fails", dyn((DT_SONAME, 1), (DT_FLAGS_1, 0x1)), False),
        ("no DT_FLAGS_1 fails", dyn((DT_SONAME, 1)), False),
        ("a DT_FLAGS_1 after DT_NULL is not read", dyn((DT_SONAME, 1)) + struct.pack("<qQ", DT_FLAGS_1, 0x9),
         False),
    ]
    for name, raw, want in cases:
        got, detail = nodelete_verdict(raw)
        rep.check(got == want, "self-test nodelete: %s (verdict %s: %s)" % (name, "ok" if got else "FAIL", detail))

    targets = [("x86_64-unknown-linux-gnu.2.17", ("linux", "x86_64")),
               ("aarch64-unknown-linux-gnu", ("linux", "aarch64")),
               ("aarch64-apple-darwin", ("macos", "aarch64")),
               ("x86_64-apple-darwin", ("macos", "x86_64"))]
    for triple, want in targets:
        rep.check(parse_target(triple) == want, "self-test target: %s is %s %s" % (triple, want[0], want[1]))
    for bad in ("x86_64-unknown-linux-musl", "riscv64gc-unknown-linux-gnu", "x86_64-pc-windows-msvc"):
        try:
            parse_target(bad)
            rep.check(False, "self-test target: %s is refused" % bad)
        except ValueError:
            rep.check(True, "self-test target: %s is refused" % bad)

    best, odd = glibc_max(["GLIBC_2.2.5", "GLIBC_2.17", "GLIBC_2.9", "GCC_3.0"])
    rep.check(best == (2, 17) and not odd, "self-test glibc: 2.17 is above 2.9 and 2.2.5 (got %s)" % (best,))
    best, odd = glibc_max(["GLIBC_2.17", "GLIBC_PRIVATE"])
    rep.check(odd == ["GLIBC_PRIVATE"], "self-test glibc: GLIBC_PRIVATE is reported")

    # a .gnu.version_r with two files, read through its string table
    strtab = b"\0libc.so.6\0GLIBC_2.17\0GLIBC_2.2.5\0libdl.so.2\0GLIBC_2.3\0"
    s = lambda w: strtab.index(w.encode() + b"\0")
    vn1 = struct.pack("<HHIII", 1, 2, s("libc.so.6"), 16, 48)
    a11 = struct.pack("<IHHII", 0, 0, 3, s("GLIBC_2.17"), 16)
    a12 = struct.pack("<IHHII", 0, 0, 2, s("GLIBC_2.2.5"), 0)
    vn2 = struct.pack("<HHIII", 1, 1, s("libdl.so.2"), 16, 0)
    a21 = struct.pack("<IHHII", 0, 0, 4, s("GLIBC_2.3"), 0)
    blob = vn1 + a11 + a12 + vn2 + a21
    names = verneed_names(blob + strtab, 0, 2, len(blob))
    rep.check(names == ["GLIBC_2.17", "GLIBC_2.2.5", "GLIBC_2.3"],
              "self-test glibc: version needs are read from .gnu.version_r (%s)" % names)

    hdr = "x /* JNV-CDEF-BEGIN */ typedef struct jnv_buf { int a; } jnv_buf;\n" \
          "uint32_t jnv_abi_version(void);\nvoid jnv_buf_free(jnv_buf *buf);\n/* JNV-CDEF-END */ jnv_out(void);"
    rep.check(header_functions(hdr) == {"jnv_abi_version", "jnv_buf_free"},
              "self-test header: only the functions inside the CDEF markers")
    if rep.failed:
        print("%d SELF-TEST VERDICTS WRONG" % rep.failed)
        return 1
    print("ALL SELF-TESTS PASSED")
    return 0


USAGE = ("usage: native_artifact.py LIB (--target TRIPLE | --host) [--header H] [--max-glibc X.Y]\n"
         "       native_artifact.py --self-test")


def main(argv):
    if argv == ["--self-test"]:
        return self_test()
    path, target, header, max_glibc = None, None, DEFAULT_HEADER, None
    i = 0
    try:
        while i < len(argv):
            a = argv[i]
            if a == "--target":
                target = parse_target(argv[i + 1])
                i += 2
            elif a == "--host":
                target = host_target()
                i += 1
            elif a == "--header":
                header = argv[i + 1]
                i += 2
            elif a == "--max-glibc":
                m = re.fullmatch(r"(\d+)\.(\d+)", argv[i + 1])
                if not m:
                    raise ValueError("--max-glibc wants X.Y, got " + argv[i + 1])
                max_glibc = (int(m.group(1)), int(m.group(2)))
                i += 2
            elif a.startswith("-") or path is not None:
                raise ValueError("unexpected argument " + a)
            else:
                path = a
                i += 1
    except IndexError:
        print(USAGE, file=sys.stderr)
        return 2
    except ValueError as e:
        print("native_artifact.py: %s\n%s" % (e, USAGE), file=sys.stderr)
        return 2
    if path is None or target is None:
        print(USAGE, file=sys.stderr)
        return 2
    return check_file(path, target, header, max_glibc)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
