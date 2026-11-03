"""Where the bytes of a non-direct Kitty transmission come from: a file (f), a temporary file
(t) or a shared memory object (s). Ported from Ghostty 1.3.1, paths relative to its src/; both
Ghostty profiles use this loader (the README's "Ghostty 1.4.0 profile" gaps list where 1.4.0
differs):

    terminal/kitty/graphics_image.zig   LoadingImage.init (NUL check, realpath), readFile,
                                        readSharedMemory, isPathInTempDir
    os/file.zig                         allocTmpDir (TMPDIR, then TMP, then the literal temp root)

DirectMedia reads the bytes the way Ghostty does, and removes a temporary file or a shared
memory object after reading it. RecordedMedia replays bytes or errors recorded from a live run
(the relay's blob index), so a replay never needs the file or the object again.

The error text is the response text (MediaError.message), as encodeError writes it.
"""
import os

from vkitty import faults

MAX_SIZE = 400 * 1024 * 1024      # graphics_image.zig max_size (the same limit as addData)
_SHM_DIR = os.path.join(os.sep, "dev", "shm")
_TMP_ROOT = os.path.join(os.sep, "tmp")          # Ghostty's fallback in allocTmpDir
_BPP = {"rgb": 3, "rgba": 4, "png": None}

try:
    import _posixshmem        # the POSIX shared memory calls (shm_open, shm_unlink)
except ImportError:           # pragma: no cover - every CPython on macOS and Linux has it
    _posixshmem = None


class MediaError(Exception):
    """A transmission that cannot be loaded; `message` is the text of the answer."""

    def __init__(self, message):
        super().__init__(message)
        self.message = message


class DirectMedia:
    """The file, temporary file and shared memory media, as Ghostty reads them.

    tmpdir stands for the terminal's own temporary directory (what TMPDIR is for Ghostty's
    process); without it TMPDIR, then TMP, then the literal temp root are used, as allocTmpDir
    does.
    fixed_roots are the prefixes a temporary file may always have (Ghostty: the temp root and
    the shared memory directory).
    unlink=False keeps temporary files and shared memory objects, and so does the fault keep_temp.
    """

    def __init__(self, tmpdir=None, fixed_roots=None, unlink=True):
        self.tmpdir = tmpdir
        if fixed_roots is None:
            fixed_roots = (_TMP_ROOT, _SHM_DIR)
        self.fixed_roots = tuple(fixed_roots)
        self.unlink = bool(unlink) and not faults.active("keep_temp")

    # -------------------------------------------------------------- temp dir ---

    def _temp_dir(self):
        """allocTmpDir: the first of TMPDIR, TMP and the temp root that is set (the tmpdir
        argument stands for the terminal's environment and comes first)."""
        if self.tmpdir is not None:
            return self.tmpdir
        for var in ("TMPDIR", "TMP"):
            value = os.environ.get(var)
            if value is not None:
                return value
        return _TMP_ROOT

    def in_temp_dir(self, path):
        """isPathInTempDir for a real (already resolved) path: a plain string prefix of a fixed
        root (so a root also matches a longer name that starts with it, as Ghostty does), then
        the temp directory as given, then its realpath. The realpath is strict, as Ghostty's
        posix.realpath is: a directory that does not exist has no realpath, and the check is
        then false."""
        for root in self.fixed_roots:
            if path.startswith(root):
                return True
        directory = self._temp_dir()
        if path.startswith(directory):
            return True
        try:
            real = os.path.realpath(directory, strict=True)
        except (OSError, ValueError):
            return False
        return path.startswith(real)

    # ------------------------------------------------------------------ load ---

    def load(self, medium, name, offset, size, fmt, width, height, key=None):
        """The raw data of one transmission (LoadingImage.init for a non-direct medium).

        name is the decoded payload: a path for f and t, a shared memory name for s. fmt is
        "rgb", "rgba" or "png" (the expected size of shared memory is the stat size for PNG and
        width * height * bytes-per-pixel otherwise). key identifies the APC for a recording; a
        live medium ignores it. Raises MediaError with the response text.
        """
        if b"\x00" in name or not name:
            # an empty name is refused here: Python's realpath("") is the working directory, while
            # the libc realpath Ghostty calls fails with ENOENT
            raise MediaError("EINVAL: invalid data")
        if medium == "s":
            return self._read_shm(name, offset, size, fmt, width, height)
        if medium not in ("f", "t"):
            raise MediaError("EINVAL: unsupported medium")
        try:
            path = os.path.realpath(os.fsdecode(name), strict=True)
        except (OSError, ValueError):
            raise MediaError("EINVAL: invalid data")
        return self._read_file(medium, path, size)

    def _read_file(self, medium, path, size):
        """readFile: refused prefixes first, then the temporary file checks. The temporary file is
        removed after the checks pass, whatever the read does next (Ghostty's defer). The offset O
        is not used: Ghostty's read ignores it (see _read_regular)."""
        if (path.startswith("/proc/") or path.startswith("/sys/")
                or (path.startswith("/dev/") and not path.startswith(_SHM_DIR + os.sep))):
            raise MediaError("EINVAL: invalid data")
        if medium == "t":
            if not self.in_temp_dir(path):
                raise MediaError("EINVAL: temporary file not in temp dir")
            if "tty-graphics-protocol" not in path:
                raise MediaError("EINVAL: temporary file not named correctly")
        limit = min(size, MAX_SIZE) if size > 0 else MAX_SIZE
        try:
            return _read_regular(path, limit)
        finally:
            if medium == "t" and self.unlink:
                try:
                    os.unlink(path)
                except OSError:
                    pass

    def _read_shm(self, name, offset, size, fmt, width, height):
        """readSharedMemory: shm_open read-only, then shm_unlink on every path after a successful
        open. The stat size must cover the expected size, and the data is the [offset, end) slice
        of the mapped stat size, where end is offset + size (capped at the expected size) or the
        expected size when size is 0."""
        import mmap
        if _posixshmem is None:
            raise MediaError("EINVAL: unsupported medium")
        shm_name = os.fsdecode(name)
        try:
            fd = _posixshmem.shm_open(shm_name, os.O_RDONLY, 0)
        except OSError:
            raise MediaError("EINVAL: invalid data")
        try:
            try:
                stat_size = os.fstat(fd).st_size
            except OSError:
                raise MediaError("EINVAL: invalid data")
            if stat_size <= 0:
                raise MediaError("EINVAL: invalid data")
            if fmt == "png":
                expected = stat_size
            else:
                expected = width * height * _BPP[fmt]
            if stat_size < expected:
                raise MediaError("EINVAL: invalid data")
            try:
                mapped = mmap.mmap(fd, stat_size, access=mmap.ACCESS_READ)
            except (OSError, ValueError):
                raise MediaError("EINVAL: invalid data")
            try:
                end = min(offset + size, expected) if size > 0 else expected
                return bytes(mapped[offset:end])
            finally:
                mapped.close()
        finally:
            os.close(fd)
            if self.unlink:
                try:
                    _posixshmem.shm_unlink(shm_name)
                except OSError:
                    pass


def _read_regular(path, limit):
    """readFile after the path checks: open the path, require a regular file, and return its bytes
    when there are fewer than `limit` of them, else invalid data.

    Ghostty seeks to the transmission's offset O and then reads through File.Reader. In Zig
    0.15.2 (lib/std/fs/File.zig) that reader starts in mode .positional with pos 0 and reads with
    preadv at its own pos, so the seek has no effect: the bytes come from offset 0 whatever O is.
    Its appendRemaining (lib/std/Io/Reader.zig) returns error.StreamTooLong as soon as `limit`
    bytes are read, even at the end of the file, and readFile turns that into invalid data. So a
    file of `limit` bytes or more is invalid data, and a shorter one is returned whole.
    """
    import stat as stat_mod
    try:
        # O_NONBLOCK: a FIFO must be refused, not waited for (the regular file check follows)
        fd = os.open(path, os.O_RDONLY | getattr(os, "O_NONBLOCK", 0))
    except OSError:
        raise MediaError("EINVAL: invalid data")
    try:
        try:
            st = os.fstat(fd)
        except OSError:
            raise MediaError("EINVAL: invalid data")
        if not stat_mod.S_ISREG(st.st_mode):
            raise MediaError("EINVAL: invalid data")
        if st.st_size >= limit:
            raise MediaError("EINVAL: invalid data")
        return _pread_from_zero(fd, st.st_size)
    finally:
        os.close(fd)


def _pread_from_zero(fd, count):
    """The first `count` bytes of fd, read with pread from offset 0 (a short read is repeated)."""
    chunks = []
    got = 0
    while got < count:
        try:
            block = os.pread(fd, count - got, got)
        except OSError:
            raise MediaError("EINVAL: invalid data")
        if not block:
            break
        chunks.append(block)
        got += len(block)
    return b"".join(chunks)


class RecordedMedia:
    """Replays a recording: index maps a blob key to (data bytes or None, error text or None).

    A key that was never recorded is an error ("EINVAL: invalid data") and a warning; the
    recording is then incomplete, which the caller sees in its answers.
    """

    def __init__(self, index, warnings=None):
        self.index = dict(index)
        self.warnings = [] if warnings is None else warnings

    def load(self, medium, name, offset, size, fmt, width, height, key=None):
        if key not in self.index:
            self.warnings.append("no blob for key %r" % (key,))
            raise MediaError("EINVAL: invalid data")
        data, error = self.index[key]
        if error is not None:
            raise MediaError(error)
        return data
