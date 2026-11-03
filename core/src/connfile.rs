// Private places for kernel connection files.
//
// Every kernel's connection file is written to a runtime dir only the user
// can access, never to a dir others share:
//
//   R/                                0700  the runtime root (choose_root)
//     core-<host>-<pid>-<12 hex>/     0700  one per backend that started a kernel
//       lock                          0600  locked (flock) while that backend runs
//       kernel-<32 hex>/              0700  one per kernel start
//         connection.json             0600
//
// R is the first of these that is, or can be made, a private dir:
// $JUPYNVIM_RUNTIME_DIR/jupynvim, $XDG_RUNTIME_DIR/jupynvim (only when
// XDG_RUNTIME_DIR is a dir of the user with no group or other access),
// jupynvim inside the Jupyter runtime dir, then jupynvim-<uid> in the system
// temp dir. In a dir that others can write to, which passes only thanks to
// its sticky bit, R is jupynvim-<uid> as well. The dir R is in is never
// changed (missing ones are made 0700; the system temp dir is never made).
// A candidate is used only when the dir R is in and every dir above it,
// symlinks resolved, can be changed only by root and the user
// (check_path_dirs; on macOS their access control lists too): whoever else
// can rename entries in one of them could put another dir in place of what
// is below it. Dirs are made 0700 and files 0600 in one step (O_EXCL), and
// their modes are then set exactly, whatever the umask; on macOS R keeps no
// access control list entry but root's, so nothing below it inherits one.
//
// R stays open from the backend dir's creation on, and everything in it is
// made and removed relative to open dirs (openat, mkdirat, unlinkat,
// renameat, never following a symlink), so a removal never leaves the dir it
// checked. A removal never recurses and keeps a bounded number of dirs open,
// whatever the depth of what it removes.
// Whoever removes a backend dir holds its lock first, so a sweep never
// removes the dir of a backend that is still running or still being made
// (where locks do not work, only a dir whose backend process is gone goes).
// The sweep at start removes what a backend that did not exit cleanly left
// behind, and the connection files older versions wrote to the system temp
// dir. In a root that several hosts can share (any but XDG_RUNTIME_DIR),
// another host's dir goes only once nothing in it changed for 7 days and its
// lock can be taken. A backend dir removed or replaced while its backend
// runs is made again at the same path at the next kernel start.

use anyhow::{anyhow, Context, Result};
use once_cell::sync::{Lazy, OnceCell};
use std::ffi::{CStr, CString, OsStr, OsString};
use std::fs::{self, DirBuilder, File, OpenOptions, TryLockError};
use std::io::{self, ErrorKind, Write};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt, PermissionsExt};
use std::os::unix::io::{AsRawFd, FromRawFd};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, SystemTime};

use crate::kernel::ConnectionInfo;

pub const ROOT_NAME: &str = "jupynvim";
pub const CONN_FILE: &str = "connection.json";
const CONN_C: &CStr = c"connection.json";
const LOCK_C: &CStr = c"lock";
const BACKEND_PREFIX: &str = "core-";
const KERNEL_PREFIX: &str = "kernel-";
/// A backend dir with no lock file is dead once it is this old (a live
/// backend makes its lock right after the dir).
const STALE_NOLOCK_AGE: Duration = Duration::from_secs(60);
/// Old-location files younger than this are kept for a running older
/// version's starting kernel.
pub const LEGACY_MIN_AGE: Duration = Duration::from_secs(60);
/// Another host's backend dir in a root shared by several hosts goes once
/// nothing in it changed for this long (and its lock can be taken).
const FOREIGN_MIN_AGE: Duration = Duration::from_secs(7 * 24 * 3600);
/// Names a backend dir may get before BackendDir::create gives up, and
/// times Runtime::new_kernel_dir makes a backend dir again when a sweep took
/// it each time before its lock was held.
const CREATE_TRIES: usize = 5;
/// The longest host token taken from a hostname.
const TOKEN_MAX: usize = 32;
/// The most symlinks check_path_dirs follows on one path (Linux's limit).
const MAX_SYMLINKS: usize = 40;
const PORT_KEYS: [&str; 5] = ["shell_port", "iopub_port", "stdin_port", "control_port", "hb_port"];

// ── where: the runtime root ─────────────────────────────

/// The environment the root is chosen from (non-empty values only).
#[derive(Clone, Debug, Default)]
pub struct EnvView {
    /// JUPYNVIM_RUNTIME_DIR
    pub override_dir: Option<PathBuf>,
    /// XDG_RUNTIME_DIR
    pub xdg_runtime_dir: Option<PathBuf>,
    /// JUPYTER_RUNTIME_DIR
    pub jupyter_runtime_dir: Option<PathBuf>,
    /// JUPYTER_DATA_DIR
    pub jupyter_data_dir: Option<PathBuf>,
    /// XDG_DATA_HOME
    pub xdg_data_home: Option<PathBuf>,
    /// the home dir
    pub home: Option<PathBuf>,
    /// the system temp dir (std::env::temp_dir: TMPDIR when set)
    pub temp_dir: Option<PathBuf>,
}

impl EnvView {
    pub fn from_process() -> Self {
        fn var(name: &str) -> Option<PathBuf> {
            std::env::var_os(name).filter(|v| !v.is_empty()).map(PathBuf::from)
        }
        EnvView {
            override_dir: var("JUPYNVIM_RUNTIME_DIR"),
            xdg_runtime_dir: var("XDG_RUNTIME_DIR"),
            jupyter_runtime_dir: var("JUPYTER_RUNTIME_DIR"),
            jupyter_data_dir: var("JUPYTER_DATA_DIR"),
            xdg_data_home: var("XDG_DATA_HOME"),
            home: dirs::home_dir().filter(|h| !h.as_os_str().is_empty()),
            temp_dir: Some(std::env::temp_dir()).filter(|t| !t.as_os_str().is_empty()),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Source {
    Override,
    XdgRuntime,
    JupyterRuntime,
    Temp,
}

impl Source {
    pub fn label(self) -> &'static str {
        match self {
            Source::Override => "JUPYNVIM_RUNTIME_DIR",
            Source::XdgRuntime => "XDG_RUNTIME_DIR",
            Source::JupyterRuntime => "Jupyter runtime dir",
            Source::Temp => "system temp dir",
        }
    }

    /// Whether the root is local to this host (the XDG spec says so of
    /// XDG_RUNTIME_DIR), so a sweep may remove every host's dead dirs there.
    pub fn local(self) -> bool {
        matches!(self, Source::XdgRuntime)
    }
}

fn absolute(p: &Option<PathBuf>) -> Option<&Path> {
    p.as_deref().filter(|p| p.is_absolute())
}

/// The candidate roots in order, as (source, R). Relative values are
/// skipped. Each R is a dir inside the dir named, so a dir given as
/// JUPYNVIM_RUNTIME_DIR (or a symlink to one) is never changed: jupynvim, or
/// jupynvim-<euid> in a dir others share (root_in). The last one, in the
/// system temp dir, is always jupynvim-<euid>: a dir of that name made
/// first by someone else is refused (prepare_root), and jupynvim there is
/// where older versions wrote every user's files.
pub fn candidates(env: &EnvView, euid: u32) -> Vec<(Source, PathBuf)> {
    let mut out = Vec::with_capacity(4);
    if let Some(d) = absolute(&env.override_dir) {
        out.push((Source::Override, root_in(d, euid)));
    }
    // XDG_RUNTIME_DIR is used only when it is private (prepare_root)
    if let Some(d) = absolute(&env.xdg_runtime_dir) {
        out.push((Source::XdgRuntime, d.join(ROOT_NAME)));
    }
    if let Some(d) = jupyter_runtime_dir(env) {
        out.push((Source::JupyterRuntime, root_in(&d, euid)));
    }
    if let Some(d) = absolute(&env.temp_dir) {
        out.push((Source::Temp, d.join(user_root_name(euid))));
    }
    out
}

/// jupynvim-<euid>: the root's name in a dir that other users share.
pub fn user_root_name(euid: u32) -> String {
    format!("{ROOT_NAME}-{euid}")
}

/// Whether a dir of `mode` lets others make entries in it and passes
/// shared_dir_reason only thanks to its sticky bit (as the system temp dir
/// does). Pure.
pub fn shared_sticky(mode: u32) -> bool {
    mode & 0o1000 != 0 && mode & 0o022 != 0
}

/// The root R in the dir `dir`: jupynvim-<euid> when `dir` (symlinks
/// followed) is a sticky dir others can write to, so the name is the
/// user's own and nobody else takes it first by accident; else jupynvim.
fn root_in(dir: &Path, euid: u32) -> PathBuf {
    match fs::metadata(dir) {
        Ok(m) if m.is_dir() && shared_sticky(m.mode()) => dir.join(user_root_name(euid)),
        _ => dir.join(ROOT_NAME),
    }
}

/// jupyter_core's order: $JUPYTER_RUNTIME_DIR, else the data dir's runtime.
fn jupyter_runtime_dir(env: &EnvView) -> Option<PathBuf> {
    if let Some(d) = absolute(&env.jupyter_runtime_dir) {
        return Some(d.to_path_buf());
    }
    jupyter_data_dir(env).map(|d| d.join("runtime"))
}

/// jupyter_core's order: $JUPYTER_DATA_DIR, else ~/Library/Jupyter on macOS,
/// else $XDG_DATA_HOME/jupyter or ~/.local/share/jupyter.
fn jupyter_data_dir(env: &EnvView) -> Option<PathBuf> {
    if let Some(d) = absolute(&env.jupyter_data_dir) {
        return Some(d.to_path_buf());
    }
    let home = absolute(&env.home);
    if cfg!(target_os = "macos") {
        return home.map(|h| h.join("Library/Jupyter"));
    }
    if let Some(d) = absolute(&env.xdg_data_home) {
        return Some(d.join("jupyter"));
    }
    home.map(|h| h.join(".local/share/jupyter"))
}

pub fn euid() -> u32 {
    // SAFETY: geteuid has no preconditions and cannot fail.
    unsafe { libc::geteuid() }
}

#[derive(Debug, PartialEq)]
pub enum Verdict {
    /// a real dir of the user with no group or other access
    Ok,
    /// a real dir of the user with group or other bits set
    Repair,
    /// anything else, with the reason
    Reject(String),
}

/// What a dir's metadata (from symlink_metadata) says about it as a private
/// dir. Pure; Ok when mode & 0o077 == 0.
pub fn private_dir_verdict(is_symlink: bool, is_dir: bool, uid: u32, mode: u32, euid: u32) -> Verdict {
    if is_symlink {
        return Verdict::Reject("is a symbolic link".to_string());
    }
    if !is_dir {
        return Verdict::Reject("is not a directory".to_string());
    }
    if uid != euid {
        return Verdict::Reject(format!("is owned by uid {uid}, not {euid}"));
    }
    if mode & 0o077 != 0 {
        return Verdict::Repair;
    }
    Verdict::Ok
}

/// The verdict on `path` itself (a symlink is not followed) and its mode.
fn verdict_at(path: &Path, euid: u32) -> io::Result<(Verdict, u32)> {
    let m = fs::symlink_metadata(path)?;
    let ft = m.file_type();
    Ok((private_dir_verdict(ft.is_symlink(), ft.is_dir(), m.uid(), m.mode(), euid), m.mode() & 0o7777))
}

/// verdict_at for a root R, whose access control list counts too: a dir of
/// ours with an ACL entry but root's (acl_root_reason) needs Repair like one
/// with group or other bits.
fn root_verdict_at(path: &Path, euid: u32) -> io::Result<(Verdict, u32)> {
    let (v, mode) = verdict_at(path, euid)?;
    if v == Verdict::Ok {
        if acl_root_reason(&read_acl(path, None)?).is_some() {
            return Ok((Verdict::Repair, mode));
        }
    }
    Ok((v, mode))
}

/// Why someone other than root and `euid` could rename or remove what is
/// in a dir owned by `uid` with `mode`, or None when nobody else can: it is
/// owned by root or `euid` and has no group or other write bit, or it has
/// the sticky bit (then only an entry's owner, the dir's owner and root can
/// rename or remove that entry). Pure.
pub fn shared_dir_reason(uid: u32, mode: u32, euid: u32) -> Option<String> {
    if uid != 0 && uid != euid {
        return Some(format!("is owned by uid {uid}, neither {euid} nor root"));
    }
    if mode & 0o022 != 0 && mode & 0o1000 == 0 {
        return Some(format!(
            "has mode {:o}: its group or others can write to it, and it has no sticky bit",
            mode & 0o7777
        ));
    }
    None
}

/// Why someone other than root and `euid` could replace a symlink of `uid`
/// on a root's path, or None: in a dir with the sticky bit an entry's owner
/// can remove or rename it, so it must be root's or `euid`'s; elsewhere only
/// whoever can write to the dir can (shared_dir_reason judges the dir). Pure.
pub fn shared_link_reason(uid: u32, in_sticky_dir: bool, euid: u32) -> Option<String> {
    (in_sticky_dir && uid != 0 && uid != euid)
        .then(|| format!("is a symbolic link of uid {uid} in a dir with the sticky bit"))
}

/// An allow entry of an access control list: who it is for (the uuid its
/// qualifier names) and the rights it grants (the ACL_* bits of macOS's
/// acl_perm_t).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AclAllow {
    pub qualifier: [u8; 16],
    pub rights: u64,
}

/// root's uuid (macOS gives uid N the uuid FFFFEEEE-DDDD-CCCC-BBBB-AAAA<N>
/// when its record names none, and root's record names this one).
pub const ROOT_UUID: [u8; 16] = [0xFF, 0xFF, 0xEE, 0xEE, 0xDD, 0xDD, 0xCC, 0xCC, 0xBB, 0xBB, 0xAA, 0xAA, 0, 0, 0, 0];

/// Who a uuid names, for log lines, read from it alone (no directory
/// lookup, see read_acl): "uid N" or "group N" for the forms macOS makes
/// for system groups and for ids with no record, else the uuid (a user's
/// own record names a uuid of its own). Pure.
pub fn uuid_who(q: &[u8; 16]) -> String {
    let id = u32::from_be_bytes([q[12], q[13], q[14], q[15]]);
    let head: &[u8] = &q[..12];
    if head == [0xAB, 0xCD, 0xEF, 0xAB, 0xCD, 0xEF, 0xAB, 0xCD, 0xEF, 0xAB, 0xCD, 0xEF]
        || head == [0xAA, 0xAA, 0xBB, 0xBB, 0xCC, 0xCC, 0xDD, 0xDD, 0xEE, 0xEE, 0xFF, 0xFF]
    {
        return format!("group {id}");
    }
    if head == &ROOT_UUID[..12] {
        return format!("uid {id}");
    }
    let h: Vec<String> = q.iter().map(|b| format!("{b:02X}")).collect();
    format!("the user or group {}-{}-{}-{}-{}", h[..4].concat(), h[4..6].concat(), h[6..8].concat(), h[8..10].concat(), h[10..].concat())
}


/// The rights of macOS's acl_perm_t that the rules below look at, with the
/// names chmod +a gives them.
pub mod acl_right {
    pub const ADD_FILE: u64 = 1 << 2;
    pub const DELETE: u64 = 1 << 4;
    pub const ADD_SUBDIRECTORY: u64 = 1 << 5;
    pub const DELETE_CHILD: u64 = 1 << 6;
    pub const WRITE_SECURITY: u64 = 1 << 12;
    pub const CHANGE_OWNER: u64 = 1 << 13;
    pub const NAMES: [(u64, &str); 6] = [
        (ADD_FILE, "add_file"),
        (ADD_SUBDIRECTORY, "add_subdirectory"),
        (DELETE_CHILD, "delete_child"),
        (DELETE, "delete"),
        (WRITE_SECURITY, "writesecurity"),
        (CHANGE_OWNER, "chown"),
    ];
}

/// Why the allow entries `allows` of a dir (or, `is_dir` false, a
/// symlink) on a root's path let someone other than root put another entry
/// in place of one in it, or of it, or None. Pure. Rights that count:
/// add_file and add_subdirectory (in a dir with no sticky bit: what the
/// write bit gives), delete_child, delete (renaming it away, which in a
/// sticky dir others write to leaves its name to them), writesecurity and
/// chown (taking the rest). Only an entry that names root is trusted: which
/// uuid is the user's own is known only from a directory lookup, which
/// read_acl never makes, and an entry naming the dir's owner adds nothing
/// to what its mode gives (such a dir is skipped, with the reason). On
/// Linux a POSIX access ACL entry that grants writing shows as the group
/// write bit (the mask), which shared_dir_reason judges, so only macOS
/// reads them.
pub fn acl_path_reason(allows: &[AclAllow], is_dir: bool, sticky: bool) -> Option<String> {
    use acl_right::*;
    let mut mask = DELETE | WRITE_SECURITY | CHANGE_OWNER;
    if is_dir {
        mask |= DELETE_CHILD;
        if !sticky {
            mask |= ADD_FILE | ADD_SUBDIRECTORY;
        }
    }
    allows.iter().find(|a| a.rights & mask != 0 && a.qualifier != ROOT_UUID).map(|a| {
        let names: Vec<&str> = NAMES.iter().filter(|(b, _)| a.rights & mask & b != 0).map(|(_, n)| *n).collect();
        format!("has an access control list entry that gives {} {}", uuid_who(&a.qualifier), names.join(","))
    })
}

/// Why the allow entries `allows` of a root R let anyone but root in at
/// all, or None (an entry naming the user, who owns R, adds nothing and is
/// removed with the rest). Pure. Any right counts: what R's entries allow,
/// its files and dirs would inherit.
pub fn acl_root_reason(allows: &[AclAllow]) -> Option<String> {
    allows
        .iter()
        .find(|a| a.qualifier != ROOT_UUID)
        .map(|a| format!("has an access control list entry for {}", uuid_who(&a.qualifier)))
}

/// The allow entries of the extended ACL of `path` (a symlink is not
/// followed), or of the open file `fd` when given. Empty where there are
/// none and on a filesystem without ACLs; on Linux always empty (see
/// acl_path_reason). Only the kernel is asked (the acl_get_*_np calls),
/// never a directory service: looking a uuid up (mbr_uuid_to_id) starts
/// libnotify on its first use, and a fork another thread makes meanwhile (a
/// kernel start) then crashes in its child, in libnotify's fork handler
/// (seen in the unit tests: "os_once_t is corrupt", "crashed on child side
/// of fork pre-exec").
#[cfg(target_os = "macos")]
pub fn read_acl(path: &Path, fd: Option<&File>) -> io::Result<Vec<AclAllow>> {
    macos_acl::allows(path, fd)
}

#[cfg(not(target_os = "macos"))]
pub fn read_acl(_path: &Path, _fd: Option<&File>) -> io::Result<Vec<AclAllow>> {
    Ok(Vec::new())
}

/// Removes every entry of the extended ACL of the open file `fd`. A no-op
/// on Linux.
#[cfg(target_os = "macos")]
fn clear_acl(fd: &File) -> io::Result<()> {
    macos_acl::clear(fd)
}

#[cfg(not(target_os = "macos"))]
fn clear_acl(_fd: &File) -> io::Result<()> {
    Ok(())
}

#[cfg(target_os = "macos")]
mod macos_acl {
    use super::AclAllow;
    use std::ffi::{c_char, c_int, c_void, CString};
    use std::fs::File;
    use std::io;
    use std::os::unix::ffi::OsStrExt;
    use std::os::unix::io::AsRawFd;
    use std::path::Path;

    // <sys/acl.h>
    const ACL_TYPE_EXTENDED: c_int = 0x0000_0100;
    const ACL_FIRST_ENTRY: c_int = 0;
    const ACL_NEXT_ENTRY: c_int = -1;
    const ACL_EXTENDED_ALLOW: c_int = 1;

    extern "C" {
        fn acl_get_link_np(path: *const c_char, ty: c_int) -> *mut c_void;
        fn acl_get_fd_np(fd: c_int, ty: c_int) -> *mut c_void;
        fn acl_get_entry(acl: *mut c_void, entry_id: c_int, entry: *mut *mut c_void) -> c_int;
        fn acl_get_tag_type(entry: *mut c_void, tag: *mut c_int) -> c_int;
        fn acl_get_permset_mask_np(entry: *mut c_void, mask: *mut u64) -> c_int;
        fn acl_get_qualifier(entry: *mut c_void) -> *mut c_void;
        fn acl_free(obj: *mut c_void) -> c_int;
        fn acl_init(count: c_int) -> *mut c_void;
        fn acl_set_fd_np(fd: c_int, acl: *mut c_void, ty: c_int) -> c_int;
    }

    /// An acl_t, or a qualifier from one, freed when dropped.
    struct Acl(*mut c_void);

    impl Drop for Acl {
        fn drop(&mut self) {
            // SAFETY: self.0 came from an acl_get_*/acl_init call and is
            // freed once.
            unsafe { acl_free(self.0) };
        }
    }

    fn c_path(path: &Path) -> io::Result<CString> {
        CString::new(path.as_os_str().as_bytes()).map_err(|_| io::Error::from(io::ErrorKind::InvalidInput))
    }

    pub fn allows(path: &Path, fd: Option<&File>) -> io::Result<Vec<AclAllow>> {
        let acl = match fd {
            // SAFETY: f is an open file.
            Some(f) => unsafe { acl_get_fd_np(f.as_raw_fd(), ACL_TYPE_EXTENDED) },
            None => {
                let c = c_path(path)?;
                // SAFETY: c is a NUL-terminated path that outlives the call.
                unsafe { acl_get_link_np(c.as_ptr(), ACL_TYPE_EXTENDED) }
            }
        };
        if acl.is_null() {
            let e = io::Error::last_os_error();
            // ENOENT: no ACL; ENOTSUP and EOPNOTSUPP: none on this filesystem
            return match e.raw_os_error() {
                Some(libc::ENOENT | libc::ENOTSUP | libc::EOPNOTSUPP) => Ok(Vec::new()),
                _ => Err(e),
            };
        }
        let acl = Acl(acl);
        let mut out = Vec::new();
        let mut id = ACL_FIRST_ENTRY;
        loop {
            let mut entry: *mut c_void = std::ptr::null_mut();
            // SAFETY: acl.0 is a valid acl_t; entry is filled in on success.
            if unsafe { acl_get_entry(acl.0, id, &mut entry) } != 0 {
                break;
            }
            id = ACL_NEXT_ENTRY;
            let mut tag: c_int = 0;
            let mut rights: u64 = 0;
            // SAFETY: entry is an entry of acl, valid while acl lives.
            if unsafe { acl_get_tag_type(entry, &mut tag) } != 0 || tag != ACL_EXTENDED_ALLOW {
                continue;
            }
            // SAFETY: as above; rights is filled in on success.
            if unsafe { acl_get_permset_mask_np(entry, &mut rights) } != 0 {
                return Err(io::Error::last_os_error());
            }
            // SAFETY: as above; the qualifier of an extended entry is a
            // 16-byte uuid, freed with acl_free.
            let q = unsafe { acl_get_qualifier(entry) };
            if q.is_null() {
                return Err(io::Error::last_os_error());
            }
            let q = Acl(q);
            let mut qualifier = [0u8; 16];
            // SAFETY: q.0 points to the 16 bytes of a uuid.
            qualifier.copy_from_slice(unsafe { std::slice::from_raw_parts(q.0 as *const u8, 16) });
            out.push(AclAllow { qualifier, rights });
        }
        Ok(out)
    }

    pub fn clear(fd: &File) -> io::Result<()> {
        // SAFETY: acl_init has no preconditions; the result is freed by Acl.
        let empty = unsafe { acl_init(0) };
        if empty.is_null() {
            return Err(io::Error::last_os_error());
        }
        let empty = Acl(empty);
        // SAFETY: fd is an open file and empty a valid acl_t.
        if unsafe { acl_set_fd_np(fd.as_raw_fd(), empty.0, ACL_TYPE_EXTENDED) } != 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(())
    }
}

/// The parts of a path to walk: names and "..", without "/" and ".".
fn walk_parts(p: &Path) -> Vec<OsString> {
    use std::path::Component;
    p.components()
        .filter_map(|c| match c {
            Component::Normal(s) => Some(s.to_os_string()),
            Component::ParentDir => Some(OsString::from("..")),
            Component::RootDir | Component::CurDir | Component::Prefix(_) => None,
        })
        .collect()
}

/// Checks `dir` and every dir above it, from "/" down, each symlink on the
/// way resolved one step at a time: a link is as fixed as the dir it is in
/// (in a sticky dir only when root or `euid` owns it), and where it points
/// is checked from there on. Every dir must pass shared_dir_reason, and on
/// macOS every part acl_path_reason too, so nobody but root and `euid` can
/// put another dir in place of anything below `dir`. Err names the first part that does not pass and why. With
/// `missing_ok`, a part that does not exist yet ends the walk (what is made
/// there is made 0700); without it, a missing part is an error.
pub fn check_path_dirs(dir: &Path, euid: u32, missing_ok: bool) -> std::result::Result<(), String> {
    if !dir.is_absolute() {
        return Err(format!("{} is not an absolute path", dir.display()));
    }
    let root = Path::new("/");
    let m = fs::symlink_metadata(root).map_err(|e| format!("/: {e}"))?;
    if let Some(why) = shared_dir_reason(m.uid(), m.mode(), euid) {
        return Err(format!("/ {why}"));
    }
    acl_check(root, true, m.mode() & 0o1000 != 0)?;
    // the parts still to walk, the next one last
    let mut todo: Vec<OsString> = walk_parts(dir);
    todo.reverse();
    // where the walk is: checked dirs only, no symlink in it
    let mut cur = root.to_path_buf();
    let mut cur_sticky = m.mode() & 0o1000 != 0;
    let mut links = 0;
    while let Some(part) = todo.pop() {
        if part == ".." {
            // back to a dir checked on the way down ("/" stays "/")
            cur.pop();
            cur_sticky = fs::symlink_metadata(&cur).map(|m| m.mode() & 0o1000 != 0).unwrap_or(false);
            continue;
        }
        let next = cur.join(&part);
        let m = match fs::symlink_metadata(&next) {
            Ok(m) => m,
            Err(e) if e.kind() == ErrorKind::NotFound && missing_ok => return Ok(()),
            Err(e) => return Err(format!("{}: {e}", next.display())),
        };
        if m.file_type().is_symlink() {
            if let Some(why) = shared_link_reason(m.uid(), cur_sticky, euid) {
                return Err(format!("{} {why}", next.display()));
            }
            acl_check(&next, false, false)?;
            links += 1;
            if links > MAX_SYMLINKS {
                return Err(format!("{}: too many symbolic links", dir.display()));
            }
            let target = fs::read_link(&next).map_err(|e| format!("{}: {e}", next.display()))?;
            if target.is_absolute() {
                cur = root.to_path_buf();
                cur_sticky = fs::symlink_metadata(root).map(|m| m.mode() & 0o1000 != 0).unwrap_or(false);
            }
            todo.extend(walk_parts(&target).into_iter().rev());
            continue;
        }
        if !m.file_type().is_dir() {
            return Err(format!("{} is not a directory", next.display()));
        }
        if let Some(why) = shared_dir_reason(m.uid(), m.mode(), euid) {
            return Err(format!("{} {why}", next.display()));
        }
        acl_check(&next, true, m.mode() & 0o1000 != 0)?;
        cur = next;
        cur_sticky = m.mode() & 0o1000 != 0;
    }
    Ok(())
}

/// check_path_dirs' check of the access control list of one part of the
/// path (acl_path_reason); a list that cannot be read fails the check.
fn acl_check(path: &Path, is_dir: bool, sticky: bool) -> std::result::Result<(), String> {
    let allows =
        read_acl(path, None).map_err(|e| format!("{}: cannot read its access control list: {e}", path.display()))?;
    match acl_path_reason(&allows, is_dir, sticky) {
        Some(why) => Err(format!("{} {why}", path.display())),
        None => Ok(()),
    }
}

/// Opens a dir without following a symlink in its last component.
fn open_dir_nofollow(path: &Path) -> io::Result<File> {
    OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW)
        .open(path)
}

/// Sets a dir of ours to exactly `mode` without following a symlink, then
/// checks it. Through a handle when the dir can be opened; when it cannot
/// (a umask or an earlier mode took the owner's read bit), by path with
/// AT_SYMLINK_NOFOLLOW once symlink_metadata shows a dir of ours, and, when
/// that call fails (some C libraries cannot do it: an older glibc, or no
/// /proc on Linux, where the error differs between C libraries), by a plain
/// chmod after one more such check.
fn set_dir_mode(path: &Path, mode: u32, euid: u32) -> io::Result<()> {
    let ours = |m: &fs::Metadata| m.file_type().is_dir() && m.uid() == euid;
    let changed = || io::Error::other("it changed while it was checked");
    match open_dir_nofollow(path) {
        Ok(dir) => {
            if !ours(&dir.metadata()?) {
                return Err(changed());
            }
            dir.set_permissions(fs::Permissions::from_mode(mode))?;
        }
        Err(e) if e.kind() == ErrorKind::PermissionDenied => {
            if !ours(&fs::symlink_metadata(path)?) {
                return Err(changed());
            }
            let c = CString::new(path.as_os_str().as_bytes()).map_err(|_| io::Error::from(ErrorKind::InvalidInput))?;
            // SAFETY: c is a NUL-terminated path that outlives the call.
            let rc = unsafe { libc::fchmodat(libc::AT_FDCWD, c.as_ptr(), mode as libc::mode_t, libc::AT_SYMLINK_NOFOLLOW) };
            if rc != 0 {
                if !ours(&fs::symlink_metadata(path)?) {
                    return Err(changed());
                }
                fs::set_permissions(path, fs::Permissions::from_mode(mode))?;
            }
        }
        Err(e) => return Err(e),
    }
    let m = fs::symlink_metadata(path)?;
    if !ours(&m) {
        return Err(changed());
    }
    if m.mode() & 0o7777 != mode {
        return Err(io::Error::other(format!("its mode is {:o}, not {mode:o}", m.mode() & 0o7777)));
    }
    Ok(())
}

/// Makes `root` usable as the runtime root: the XDG dir must already be
/// private (it is never changed), and the system temp dir must exist; for
/// the others missing ancestors are made 0700 and existing ones are left as
/// they are. The dir R is in and every
/// dir above it must pass check_path_dirs, checked before anything is made
/// and again once it all exists. Then R is made 0700, or, when it exists as
/// a dir of ours with group or other bits (or, on macOS, an access control
/// list entry but root's, which it may have inherited when it was made),
/// set to 0700 with no such entry and checked again. Err carries the
/// reason.
pub fn prepare_root(source: Source, root: &Path, euid: u32) -> Result<()> {
    let parent = root.parent().ok_or_else(|| anyhow!("has no parent dir"))?;
    match source {
        Source::XdgRuntime => {
            match verdict_at(parent, euid) {
                Ok((Verdict::Ok, _)) => {}
                Ok((Verdict::Repair, mode)) => {
                    return Err(anyhow!("{} has mode {:o}, open to group or others", parent.display(), mode))
                }
                Ok((Verdict::Reject(why), _)) => return Err(anyhow!("{} {why}", parent.display())),
                Err(e) if e.kind() == ErrorKind::NotFound => {
                    return Err(anyhow!("{} does not exist", parent.display()))
                }
                Err(e) => return Err(anyhow!("{}: {e}", parent.display())),
            }
            check_path_dirs(parent, euid, false).map_err(|e| anyhow!(e))?;
        }
        Source::Override | Source::JupyterRuntime => {
            check_path_dirs(parent, euid, true).map_err(|e| anyhow!(e))?;
            create_ancestors(parent)?;
            check_path_dirs(parent, euid, false).map_err(|e| anyhow!(e))?;
        }
        // the system temp dir is never made or changed
        Source::Temp => check_path_dirs(parent, euid, false).map_err(|e| anyhow!(e))?,
    }
    match mkdir_private(root) {
        Ok(()) => {}
        Err(e) if e.kind() == ErrorKind::AlreadyExists => {}
        Err(e) => return Err(anyhow!("cannot create it: {e}")),
    }
    match root_verdict_at(root, euid) {
        Ok((Verdict::Ok, _)) => Ok(()),
        Ok((Verdict::Repair, mode)) => repair_root(root, mode, euid),
        Ok((Verdict::Reject(why), _)) => Err(anyhow!(why)),
        Err(e) => Err(anyhow!("{e}")),
    }
}

/// Sets a root of ours to 0700 without following a symlink, and removes
/// its access control list when it has an entry but root's (macOS; the
/// entries inherited when it was made, too), then requires the verdict to
/// be Ok.
fn repair_root(root: &Path, mode: u32, euid: u32) -> Result<()> {
    if mode != 0o700 {
        set_dir_mode(root, 0o700, euid).map_err(|e| anyhow!("has mode {mode:o} and cannot be set to 700: {e}"))?;
        tracing::info!("runtime: set {} from mode {mode:o} to 700", root.display());
    }
    let d = open_dir_nofollow(root).map_err(|e| anyhow!("cannot open it: {e}"))?;
    if !d.metadata().is_ok_and(|m| m.is_dir() && m.uid() == euid) {
        return Err(anyhow!("it changed while it was checked"));
    }
    if let Some(why) = acl_root_reason(&read_acl(root, Some(&d))?) {
        clear_acl(&d).map_err(|e| anyhow!("{why}, and it cannot be removed: {e}"))?;
        tracing::info!("runtime: removed the access control list of {} ({why})", root.display());
    }
    match root_verdict_at(root, euid) {
        Ok((Verdict::Ok, _)) => Ok(()),
        Ok((Verdict::Repair, now)) => Err(anyhow!("is still open to others after setting 700 (mode {now:o})")),
        Ok((Verdict::Reject(why), _)) => Err(anyhow!(why)),
        Err(e) => Err(anyhow!("{e}")),
    }
}

/// Makes every missing dir of `dir` and above, each 0700, from the top down.
fn create_ancestors(dir: &Path) -> Result<()> {
    let mut missing = Vec::new();
    let mut cur = dir;
    loop {
        match fs::symlink_metadata(cur) {
            Ok(_) => break,
            Err(e) if e.kind() == ErrorKind::NotFound => {
                missing.push(cur.to_path_buf());
                match cur.parent() {
                    Some(p) => cur = p,
                    None => break,
                }
            }
            Err(e) => return Err(anyhow!("{}: {e}", cur.display())),
        }
    }
    for d in missing.iter().rev() {
        match mkdir_private(d) {
            Ok(()) => {}
            Err(e) if e.kind() == ErrorKind::AlreadyExists => {}
            Err(e) => return Err(anyhow!("cannot create {}: {e}", d.display())),
        }
    }
    Ok(())
}

/// Whether `root` is already a usable root (no creation, no repair): what a
/// sweep needs before it reads a root.
pub fn verify_root(source: Source, root: &Path, euid: u32) -> bool {
    let Some(parent) = root.parent() else { return false };
    if source == Source::XdgRuntime && !matches!(verdict_at(parent, euid), Ok((Verdict::Ok, _))) {
        return false;
    }
    check_path_dirs(parent, euid, false).is_ok() && matches!(root_verdict_at(root, euid), Ok((Verdict::Ok, _)))
}

/// Opens the root R without following a symlink and checks the handle: a
/// dir of `euid` with no group or other access (on macOS, by its access
/// control list either). What is in R is made and removed through this
/// handle.
fn open_root_dir(root: &Path, euid: u32) -> io::Result<File> {
    let d = open_dir_nofollow(root)?;
    let m = d.metadata()?;
    if !(m.is_dir() && m.uid() == euid && m.mode() & 0o077 == 0) {
        return Err(io::Error::other(format!(
            "it is not a dir of uid {euid} with no group or other access (uid {}, mode {:o})",
            m.uid(),
            m.mode() & 0o7777
        )));
    }
    if let Some(why) = acl_root_reason(&read_acl(root, Some(&d))?) {
        return Err(io::Error::other(why));
    }
    Ok(d)
}

/// The first candidate that is, or can be made, a private dir. Each refused
/// candidate is logged with its reason, and all of them are named in the
/// error when none is left.
pub fn choose_root(env: &EnvView, euid: u32) -> Result<(Source, PathBuf)> {
    let mut tried: Vec<String> = [
        ("JUPYNVIM_RUNTIME_DIR", &env.override_dir),
        ("XDG_RUNTIME_DIR", &env.xdg_runtime_dir),
        ("JUPYTER_RUNTIME_DIR", &env.jupyter_runtime_dir),
        ("JUPYTER_DATA_DIR", &env.jupyter_data_dir),
        ("the system temp dir", &env.temp_dir),
    ]
    .into_iter()
    .filter_map(|(name, v)| {
        v.as_ref()
            .filter(|p| !p.is_absolute())
            .map(|p| format!("{name} {}: not an absolute path, ignored", p.display()))
    })
    .collect();
    for (source, root) in candidates(env, euid) {
        match prepare_root(source, &root, euid) {
            Ok(()) => return Ok((source, root)),
            Err(e) => {
                // the override was asked for; the others are fallbacks
                if source == Source::Override {
                    tracing::warn!("runtime: not using {} {}: {e:#}", source.label(), root.display());
                } else {
                    tracing::info!("runtime: not using {} {}: {e:#}", source.label(), root.display());
                }
                tried.push(format!("{} {}: {e:#}", source.label(), root.display()));
            }
        }
    }
    let tried = if tried.is_empty() { "none, the home dir is unknown".to_string() } else { tried.join("; ") };
    Err(anyhow!(
        "no private runtime directory for kernel connection files (tried: {tried}); \
         set JUPYNVIM_RUNTIME_DIR to a directory only you can write to"
    ))
}

// ── names ───────────────────────────────────────────────

static HOST_TOKEN: Lazy<String> = Lazy::new(|| machine_token().unwrap_or_else(|| sanitize_host(&hostname(), TOKEN_MAX)));

/// This host's token in backend dir names: on macOS the start of
/// gethostuuid; on Linux the start of /etc/machine-id (or
/// /var/lib/dbus/machine-id) and the short hostname; else the sanitized
/// hostname. Stable when a laptop's hostname follows the network, and
/// different per node on a shared home dir.
pub fn host_token() -> String {
    HOST_TOKEN.clone()
}

#[cfg(target_os = "macos")]
fn machine_token() -> Option<String> {
    let mut id = [0u8; 16];
    let wait = libc::timespec { tv_sec: 1, tv_nsec: 0 };
    // SAFETY: id is the 16-byte uuid_t gethostuuid fills; wait outlives the call.
    let rc = unsafe { libc::gethostuuid(id.as_mut_ptr(), &wait) };
    if rc != 0 || id.iter().all(|b| *b == 0) {
        return None;
    }
    Some(hex::encode(&id[..6]))
}

#[cfg(target_os = "linux")]
fn machine_token() -> Option<String> {
    let host = hostname();
    ["/etc/machine-id", "/var/lib/dbus/machine-id"]
        .iter()
        .find_map(|p| machine_host_token(&fs::read_to_string(p).ok()?, &host))
}

/// The Linux token from a machine id file's contents and the hostname: the
/// id's first 8 hex digits, '-', and the short hostname (sanitized, the
/// whole token at most 32 chars). Nodes made from one image often share a
/// machine id; their hostnames tell them apart. None when the id does not
/// start with 8 hex digits.
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
fn machine_host_token(machine_id: &str, host: &str) -> Option<String> {
    let head = machine_id.trim().get(..8)?;
    if !head.bytes().all(|b| b.is_ascii_hexdigit()) {
        return None;
    }
    let short = host.split('.').next().unwrap_or_default();
    Some(format!("{}-{}", head.to_ascii_lowercase(), sanitize_host(short, TOKEN_MAX - 9)))
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn machine_token() -> Option<String> {
    None
}

fn hostname() -> String {
    let mut buf = [0u8; 256];
    // SAFETY: buf is writable for the length passed.
    let rc = unsafe { libc::gethostname(buf.as_mut_ptr() as *mut libc::c_char, buf.len()) };
    if rc != 0 {
        return String::new();
    }
    let end = buf.iter().position(|b| *b == 0).unwrap_or(buf.len());
    String::from_utf8_lossy(&buf[..end]).into_owned()
}

fn token_char(c: char) -> bool {
    c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-')
}

/// At most `max` chars of `raw`, each outside [A-Za-z0-9._-] made '_';
/// empty becomes "localhost".
pub fn sanitize_host(raw: &str, max: usize) -> String {
    let s: String = raw.chars().take(max).map(|c| if token_char(c) { c } else { '_' }).collect();
    if s.is_empty() {
        "localhost".to_string()
    } else {
        s
    }
}

pub fn backend_dir_name(token: &str, pid: u32, rand12: &str) -> String {
    format!("{BACKEND_PREFIX}{token}-{pid}-{rand12}")
}

/// (token, pid) of a backend dir name, read from the right (a token may hold
/// '-'); None for any other name.
pub fn parse_backend_dir_name(name: &str) -> Option<(String, u32)> {
    let rest = name.strip_prefix(BACKEND_PREFIX)?;
    let mut parts = rest.rsplitn(3, '-');
    let rand = parts.next()?;
    let pid = parts.next()?;
    let token = parts.next()?;
    let rand_ok = rand.len() == 12 && rand.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'));
    let pid_ok = !pid.is_empty() && pid.bytes().all(|b| b.is_ascii_digit());
    let token_ok = !token.is_empty() && token.chars().all(token_char);
    if !(rand_ok && pid_ok && token_ok) {
        return None;
    }
    Some((token.to_string(), pid.parse().ok()?))
}

fn rand12() -> String {
    uuid::Uuid::new_v4().simple().to_string()[..12].to_string()
}

// ── private dirs and files ──────────────────────────────

/// Makes one dir with mode 0700 (AlreadyExists is returned as is), then sets
/// the mode exactly: a umask can only remove bits, and this restores owner
/// bits an unusual umask removed.
pub fn mkdir_private(path: &Path) -> io::Result<()> {
    DirBuilder::new().mode(0o700).create(path)?;
    if fs::symlink_metadata(path)?.mode() & 0o7777 != 0o700 {
        set_dir_mode(path, 0o700, euid())?;
    }
    Ok(())
}

/// mkdir_private for the entry `name` of the open dir `dir`.
fn mkdir_private_at(dir: &File, name: &CStr) -> io::Result<()> {
    // SAFETY: name is NUL-terminated and outlives the call; dir is an open
    // dir.
    if unsafe { libc::mkdirat(dir.as_raw_fd(), name.as_ptr(), 0o700) } != 0 {
        return Err(io::Error::last_os_error());
    }
    if mode_bits(&stat_at_err(dir, name)?) != 0o700 {
        set_dir_mode_at(dir, name, 0o700, euid())?;
    }
    Ok(())
}

/// set_dir_mode for the entry `name` of the open dir `dir`: through a
/// handle of that dir when it can be opened; when it cannot (the owner's
/// read bit is gone), with fchmodat(AT_SYMLINK_NOFOLLOW) once fstatat shows
/// a dir of ours, and, where the C library cannot do that, with a plain
/// fchmodat after one more such check. Then the mode is checked.
fn set_dir_mode_at(dir: &File, name: &CStr, mode: u32, euid: u32) -> io::Result<()> {
    let ours = |st: &libc::stat| st_is_dir(st) && st.st_uid == euid;
    let changed = || io::Error::other("it changed while it was checked");
    match open_dir_at(dir, name) {
        Ok(d) => {
            let m = d.metadata()?;
            if !(m.is_dir() && m.uid() == euid) {
                return Err(changed());
            }
            d.set_permissions(fs::Permissions::from_mode(mode))?;
        }
        Err(e) if e.kind() == ErrorKind::PermissionDenied => {
            if !ours(&stat_at_err(dir, name)?) {
                return Err(changed());
            }
            // SAFETY: name is NUL-terminated and outlives the call; dir is
            // an open dir.
            let rc = unsafe {
                libc::fchmodat(dir.as_raw_fd(), name.as_ptr(), mode as libc::mode_t, libc::AT_SYMLINK_NOFOLLOW)
            };
            if rc != 0 {
                if !ours(&stat_at_err(dir, name)?) {
                    return Err(changed());
                }
                // SAFETY: as above.
                if unsafe { libc::fchmodat(dir.as_raw_fd(), name.as_ptr(), mode as libc::mode_t, 0) } != 0 {
                    return Err(io::Error::last_os_error());
                }
            }
        }
        Err(e) => return Err(e),
    }
    let st = stat_at_err(dir, name)?;
    if !ours(&st) {
        return Err(changed());
    }
    if mode_bits(&st) != mode {
        return Err(io::Error::other(format!("its mode is {:o}, not {mode:o}", mode_bits(&st))));
    }
    Ok(())
}

/// Creates the file `name` in the open dir `dir`, open for writing and
/// close-on-exec, with mode 0600; an existing file or symlink (dangling or
/// not) is refused (O_EXCL). The mode is then set exactly.
fn create_file_at(dir: &File, name: &CStr) -> io::Result<File> {
    let flags = libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL | libc::O_NOFOLLOW | libc::O_CLOEXEC;
    // SAFETY: name is NUL-terminated and outlives the call; dir is an open
    // dir.
    let fd = unsafe { libc::openat(dir.as_raw_fd(), name.as_ptr(), flags, 0o600 as libc::c_uint) };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: fd was just opened here and nothing else owns it.
    let f = unsafe { File::from_raw_fd(fd) };
    if f.metadata()?.mode() & 0o7777 != 0o600 {
        f.set_permissions(fs::Permissions::from_mode(0o600))?;
    }
    Ok(f)
}

/// unlinkat on the open dir `dir`: with AT_REMOVEDIR an empty dir only,
/// without it a file or a symlink (never followed).
fn unlink_at(dir: &File, name: &CStr, flags: libc::c_int) -> io::Result<()> {
    // SAFETY: name is NUL-terminated and outlives the call; dir is an open
    // dir.
    if unsafe { libc::unlinkat(dir.as_raw_fd(), name.as_ptr(), flags) } == 0 {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
}

/// What a removal could not remove: how many entries failed, and the
/// first failure (the entry's name and the error). The dirs above a failure
/// stay too and are not counted again.
#[derive(Debug, Default)]
struct Left {
    count: usize,
    first: Option<(CString, io::Error)>,
}

impl Left {
    fn add(&mut self, name: &CStr, e: io::Error) {
        self.count += 1;
        if self.first.is_none() {
            self.first = Some((name.to_owned(), e));
        }
    }

    /// "; <n> entr(y|ies) in it could not be removed, the first (<name>):
    /// <error>", or "" when nothing failed. Bounded: one name, never a path
    /// as deep as the tree.
    fn summary(&self) -> String {
        let Some((name, e)) = &self.first else { return String::new() };
        format!(
            "; {} {} in it could not be removed, the first ({}): {e}",
            self.count,
            if self.count == 1 { "entry" } else { "entries" },
            String::from_utf8_lossy(name.to_bytes())
        )
    }
}

/// The most dirs a removal keeps open below the dir it clears. A dir found
/// deeper is moved up into that dir (move_up) and removed from there, so a
/// tree of any depth takes a bounded number of open files and no
/// recursion, and every operation happens at most this many levels down.
const REMOVE_MAX_OPEN: usize = 32;

/// The most passes clear_tree makes over the dir it clears (each pass after
/// the first only takes what move_up put there).
const REMOVE_MAX_PASSES: usize = 1 << 20;

/// Removes the entry `name` of the open dir `dir` (`dir_shown` is that dir
/// in log lines): a file or a symlink, never followed, is unlinked; a dir is
/// opened without following a symlink, emptied (clear_tree), then removed.
/// Something already gone, anywhere in the tree, is fine. What cannot be
/// removed is logged in one line. True when the entry is gone.
fn remove_entry_at(dir: &File, name: &CStr, dir_shown: &Path) -> bool {
    let mut left = Left::default();
    let r = (|| -> io::Result<()> {
        let st = match stat_at_err(dir, name) {
            Ok(st) => st,
            Err(e) if e.kind() == ErrorKind::NotFound => return Ok(()),
            Err(e) => return Err(e),
        };
        if !st_is_dir(&st) {
            return ignore_not_found(unlink_at(dir, name, 0));
        }
        let sub = match open_dir_at(dir, name) {
            Ok(d) => d,
            Err(e) if e.kind() == ErrorKind::NotFound => return Ok(()),
            Err(e) => return Err(e),
        };
        clear_tree(&sub, None, &mut left)?;
        ignore_not_found(unlink_at(dir, name, libc::AT_REMOVEDIR))
    })();
    match r {
        Ok(()) => true,
        Err(e) => {
            tracing::warn!(
                "runtime: cannot remove {}: {e}{}",
                dir_shown.join(OsStr::from_bytes(name.to_bytes())).display(),
                left.summary()
            );
            false
        }
    }
}

/// Removes everything in the open dir `top` but the entry named `keep`,
/// without recursion: each entry goes with remove_subtree, which moves what
/// lies more than REMOVE_MAX_OPEN levels down into `top`, and `top` is then
/// listed again for those. Entries that cannot be removed are left and
/// counted in `left` once. Err only when `top` cannot be listed at first.
fn clear_tree(top: &File, keep: Option<&CStr>, left: &mut Left) -> io::Result<()> {
    let mut failed: std::collections::HashSet<CString> = std::collections::HashSet::new();
    for pass in 0..REMOVE_MAX_PASSES {
        let names = match dir_names(top) {
            Ok(n) => n,
            Err(e) if pass == 0 => return Err(e),
            Err(e) => {
                left.add(c".", e);
                return Ok(());
            }
        };
        let mut moved = false;
        for name in names {
            if keep == Some(name.as_c_str()) || failed.contains(&name) {
                continue;
            }
            if !remove_subtree(top, &name, top, left, &mut moved) {
                failed.insert(name);
            }
        }
        if !moved {
            return Ok(());
        }
    }
    Ok(())
}

/// One open dir of remove_subtree's stack: its name in the dir above it,
/// the entries still to remove, and whether one of them failed.
struct Frame {
    dir: File,
    name: CString,
    todo: std::vec::IntoIter<CString>,
    failed: bool,
}

impl Frame {
    fn open(parent: &File, name: &CStr) -> io::Result<Frame> {
        let dir = open_dir_at(parent, name)?;
        let todo = dir_names(&dir)?.into_iter();
        Ok(Frame { dir, name: name.to_owned(), todo, failed: false })
    }
}

/// Removes the entry `name` of the open dir `parent` with everything in it,
/// depth first with an explicit stack of open dirs (never followed through
/// a symlink). A dir REMOVE_MAX_OPEN levels down is moved into `top`, the
/// dir being cleared, instead of being opened; `moved` is then set, and
/// `top` must be listed again. Each failure is counted in `left`. True when
/// the entry is gone; false when something in it could not be removed (the
/// rest is gone).
fn remove_subtree(parent: &File, name: &CStr, top: &File, left: &mut Left, moved: &mut bool) -> bool {
    let st = match stat_at_err(parent, name) {
        Ok(st) => st,
        Err(e) if e.kind() == ErrorKind::NotFound => return true,
        Err(e) => {
            left.add(name, e);
            return false;
        }
    };
    if !st_is_dir(&st) {
        return match ignore_not_found(unlink_at(parent, name, 0)) {
            Ok(()) => true,
            Err(e) => {
                left.add(name, e);
                false
            }
        };
    }
    let mut stack = match Frame::open(parent, name) {
        Ok(f) => vec![f],
        Err(e) if e.kind() == ErrorKind::NotFound => return true,
        Err(e) => {
            left.add(name, e);
            return false;
        }
    };
    loop {
        // the dirs open below `parent`; a dir found below the last of
        // REMOVE_MAX_OPEN of them is moved up instead of opened
        let open = stack.len();
        let frame = stack.last_mut().expect("the stack is not empty here");
        if let Some(child) = frame.todo.next() {
            let st = match stat_at_err(&frame.dir, &child) {
                Ok(st) => st,
                Err(e) if e.kind() == ErrorKind::NotFound => continue,
                Err(e) => {
                    left.add(&child, e);
                    frame.failed = true;
                    continue;
                }
            };
            let r = if !st_is_dir(&st) {
                ignore_not_found(unlink_at(&frame.dir, &child, 0))
            } else if open >= REMOVE_MAX_OPEN {
                let r = ignore_not_found(move_up(&frame.dir, &child, top));
                *moved |= r.is_ok();
                r
            } else {
                match Frame::open(&frame.dir, &child) {
                    Ok(f) => {
                        stack.push(f);
                        Ok(())
                    }
                    Err(e) => ignore_not_found(Err(e)),
                }
            };
            if let Err(e) = r {
                let frame = stack.last_mut().expect("the stack is not empty here");
                left.add(&child, e);
                frame.failed = true;
            }
            continue;
        }
        // every entry was handled: remove the dir from the one above it
        let done = stack.pop().expect("the stack is not empty here");
        let above = stack.last().map_or(parent, |f| &f.dir);
        let ok = !done.failed
            && match ignore_not_found(unlink_at(above, &done.name, libc::AT_REMOVEDIR)) {
                Ok(()) => true,
                Err(e) => {
                    left.add(&done.name, e);
                    false
                }
            };
        drop(done);
        match stack.last_mut() {
            Some(f) => f.failed |= !ok,
            None => return ok,
        }
    }
}

/// Moves the dir `name` of the open dir `dir` into the open dir `top` under
/// a new name (renameat, both relative to handles, so nothing leaves the
/// tree being removed); only a name that is taken is tried again.
fn move_up(dir: &File, name: &CStr, top: &File) -> io::Result<()> {
    let mut last = io::Error::from_raw_os_error(libc::EEXIST);
    for _ in 0..3 {
        let to = CString::new(format!(".jnv-rm-{}", rand12())).expect("hex has no NUL");
        // SAFETY: both names are NUL-terminated and outlive the call; dir
        // and top are open dirs.
        if unsafe { libc::renameat(dir.as_raw_fd(), name.as_ptr(), top.as_raw_fd(), to.as_ptr()) } == 0 {
            return Ok(());
        }
        last = io::Error::last_os_error();
        if !matches!(last.raw_os_error(), Some(libc::EEXIST | libc::ENOTEMPTY | libc::ENOTDIR | libc::EISDIR)) {
            break;
        }
    }
    Err(last)
}

fn ignore_not_found(r: io::Result<()>) -> io::Result<()> {
    match r {
        Err(e) if e.kind() == ErrorKind::NotFound => Ok(()),
        r => r,
    }
}

/// Removes a file, a symlink (never followed) or a dir with everything in
/// it, through handles (remove_entry_at on its parent dir). For tests.
#[cfg(test)]
pub fn remove_tree(path: &Path) {
    let (Some(parent), Some(name)) = (path.parent(), path.file_name()) else { return };
    let Ok(dir) = OpenOptions::new().read(true).custom_flags(libc::O_DIRECTORY).open(parent) else { return };
    let Ok(name) = CString::new(name.as_bytes()) else { return };
    remove_entry_at(&dir, &name, parent);
}

// ── backend dirs and their lock ─────────────────────────

/// File::try_lock (flock). A test can make it fail the way it fails on a
/// filesystem without working locks.
fn try_lock(f: &File) -> Result<(), TryLockError> {
    #[cfg(test)]
    if tests::locks_fail() {
        return Err(TryLockError::Error(io::Error::from_raw_os_error(libc::ENOLCK)));
    }
    f.try_lock()
}

/// Why take_lock_at gave no lock.
#[derive(Debug, PartialEq, Eq)]
enum NoLock {
    /// someone holds it: a live backend, one that is exiting or was just
    /// killed (its lock goes a moment after its other fds), or another
    /// remover
    Held,
    /// locking fails on this filesystem and the dir is not known to be dead
    /// (its backend process is still there, perhaps killed but not yet
    /// reaped by its parent)
    NotDead,
    /// the dir has no file named lock and this caller does not claim it:
    /// every remover unlinks the lock file only right before it removes the
    /// dir, so a lock file that is missing where it was expected means a
    /// removal in progress
    Missing,
    /// the dir is gone, or its lock is not a regular file
    Other,
}

/// Takes the lock of the backend dir open as `bd` (`shown` is its path, for
/// its name and log lines) for removal. A dir with no lock file is claimed
/// by creating one only with `claim` (a sweep that judged the dir dead by
/// its age with no lock file in it, or the guard once the wait is over and
/// the backend's pid is gone); without it, it is NoLock::Missing. Where
/// locking fails (a filesystem without working locks) the open file is
/// returned unlocked only when dead_without_lock says the dir is dead;
/// `pid_rule` lets the pid in the dir's name count there (only for this
/// host's dirs).
fn take_lock_at(bd: &File, shown: &Path, pid_rule: bool, claim: bool) -> Result<File, NoLock> {
    for _ in 0..2 {
        // Open for writing: on NFS an exclusive flock is a write lock, which
        // needs a file open for writing. O_NONBLOCK: opening never waits,
        // whatever was made there (POSIX leaves opening a FIFO for reading
        // and writing undefined); the flag does not change how a regular
        // file is locked.
        let flags = libc::O_RDWR | libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC;
        // SAFETY: LOCK_C is NUL-terminated; bd is an open dir.
        let fd = unsafe { libc::openat(bd.as_raw_fd(), LOCK_C.as_ptr(), flags) };
        let opened = if fd >= 0 {
            // SAFETY: fd was just opened here and nothing else owns it.
            Ok(unsafe { File::from_raw_fd(fd) })
        } else {
            Err(io::Error::last_os_error())
        };
        let (file, claimed) = match opened {
            Ok(f) => (f, false),
            Err(e) if e.kind() == ErrorKind::NotFound && !claim => return Err(NoLock::Missing),
            Err(e) if e.kind() == ErrorKind::NotFound => match create_file_at(bd, LOCK_C) {
                Ok(f) => (f, true),
                Err(e) if e.kind() == ErrorKind::AlreadyExists => continue,
                Err(_) => return Err(NoLock::Other),
            },
            Err(_) => return Err(NoLock::Other),
        };
        if !file.metadata().is_ok_and(|m| m.is_file()) {
            return Err(NoLock::Other);
        }
        return match try_lock(&file) {
            Ok(()) => Ok(file),
            Err(TryLockError::WouldBlock) => Err(NoLock::Held),
            Err(TryLockError::Error(e)) => {
                let dead = dead_without_lock(shown, claimed, pid_rule);
                tracing::debug!(
                    "runtime: cannot lock {}: {e}; {}",
                    shown.join("lock").display(),
                    if dead { "its backend is gone, going on" } else { "left alone" }
                );
                if dead {
                    Ok(file)
                } else {
                    Err(NoLock::NotDead)
                }
            }
        };
    }
    Err(NoLock::Other)
}

/// Whether a remover goes on with a dir whose lock could not be taken
/// because locking failed (not because it is held): when this remover made
/// the lock file itself (the dir had none and was old enough to be dead),
/// or, with `pid_rule`, when the backend process named in the dir's name is
/// gone. The pid means something only on this host, so the rule is for this
/// host's dirs (its token) and a root local to this host (XDG_RUNTIME_DIR),
/// never for another host's dirs in a shared root.
fn dead_without_lock(dir: &Path, claimed: bool, pid_rule: bool) -> bool {
    claimed
        || (pid_rule
            && dir
                .file_name()
                .and_then(|n| n.to_str())
                .and_then(parse_backend_dir_name)
                .is_some_and(|(_, pid)| process_gone(pid)))
}

/// True only when no process with this pid exists (kill with signal 0
/// gives ESRCH). A pid out of range counts as running.
fn process_gone(pid: u32) -> bool {
    let Ok(pid) = libc::pid_t::try_from(pid) else { return false };
    if pid <= 0 {
        return false;
    }
    // SAFETY: signal 0 sends nothing; it only checks that the process exists.
    let rc = unsafe { libc::kill(pid, 0) };
    rc == -1 && io::Error::last_os_error().raw_os_error() == Some(libc::ESRCH)
}

/// Whether `lock` is the file named lock in the open backend dir `bd`: the
/// same file, still linked, and a regular file. NFS renames an unlinked
/// file that is open, and another remover may then make a lock file of its
/// own.
fn lock_is_named(bd: &File, lock: &File) -> bool {
    match (lock.metadata(), stat_at_err(bd, LOCK_C)) {
        (Ok(held), Ok(named)) => held.nlink() > 0 && st_is_file(&named) && same_file(&named, &held),
        _ => false,
    }
}

/// The backend dir `name` of the open root `root`, opened without following
/// a symlink, when it is a dir of the user whose file named lock is `lock`.
fn open_held(root: &File, name: &CStr, lock: &File) -> Option<File> {
    let bd = open_dir_at(root, name).ok()?;
    let m = bd.metadata().ok()?;
    (m.is_dir() && m.uid() == euid() && lock_is_named(&bd, lock)).then_some(bd)
}

/// Removes the empty dir `name` from the open dir `parent`, only while that
/// name is still the dir open as `d` (device and inode).
fn rmdir_same(parent: &File, name: &CStr, d: &File) -> io::Result<()> {
    let m = d.metadata()?;
    if !same_file(&stat_at_err(parent, name)?, &m) {
        return Err(io::Error::other("another entry has its name now; left alone"));
    }
    unlink_at(parent, name, libc::AT_REMOVEDIR)
}

/// Removes the backend dir `name` of the open root `root`, open as `bd`,
/// while holding its lock `lock` (`shown` names the dir in log lines).
/// Everything but the lock goes first, then the lock file, then the dir,
/// and the lock is released; a dir that was not empty yet is cleared and
/// removed once more after that. Every step goes through `root` and `bd`
/// without following a symlink, so whatever is renamed meanwhile, nothing
/// outside the dir that was checked is touched. What cannot be removed is
/// logged in one line. True when the dir was removed.
fn remove_locked_at(root: &File, name: &CStr, bd: &File, lock: File, shown: &Path) -> bool {
    let mut left = Left::default();
    let first = (|| -> io::Result<()> {
        clear_tree(bd, Some(LOCK_C), &mut left)?;
        ignore_not_found(unlink_at(bd, LOCK_C, 0))?;
        #[cfg(test)]
        tests::hook(tests::Point::LockUnlinked, shown);
        rmdir_same(root, name, bd)
    })();
    drop(lock);
    #[cfg(test)]
    tests::hook(tests::Point::LockReleased, shown);
    let result = match first {
        // Not empty: something was added meanwhile, or the lock file stayed
        // as a hidden file while it was open (NFS keeps an unlinked open
        // file that way until it is closed). Its lock file is gone, so no
        // backend can use the dir any more: now that the lock is closed,
        // clear it and remove it again.
        Err(e) if matches!(e.raw_os_error(), Some(libc::ENOTEMPTY) | Some(libc::EEXIST) | Some(libc::EBUSY)) => {
            left = Left::default();
            clear_tree(bd, None, &mut left).and_then(|()| rmdir_same(root, name, bd))
        }
        r => r,
    };
    match result {
        Ok(()) => true,
        Err(e) => {
            if e.kind() != ErrorKind::NotFound {
                tracing::warn!("runtime: cannot remove {}: {e}{}", shown.display(), left.summary());
            }
            false
        }
    }
}

/// Takes the lock of a backend dir that looks dead, open as `bd`, and
/// removes it (remove_locked_at); a dir with no lock file only with `claim`
/// (take_lock_at). False when its lock cannot be taken.
fn remove_dead_at(root: &File, name: &CStr, bd: &File, pid_rule: bool, claim: bool, shown: &Path) -> bool {
    match take_lock_at(bd, shown, pid_rule, claim) {
        Ok(lock) => remove_locked_at(root, name, bd, lock, shown),
        Err(_) => false,
    }
}

/// The kernel guard's removal of its backend's dir `dir` once the backend
/// is gone. Only a dir named like a backend dir is removed, in a root that
/// is usable now (the dirs above it pass check_path_dirs, and it is a
/// private dir of the user, kept open), and only through handles. A backend
/// that was killed lets go of its pipe to the guard and of its lock one
/// after the other, the pipe usually first (and where locking fails, its
/// pid stays taken until its parent reaps it), and a backend that exits
/// cleanly holds its lock while it removes the dir itself, unlinking the
/// lock file right before its rmdir; so while the dir is still there (a
/// real dir of the user at that name in the root, never a symlink), a lock
/// someone holds, a dir not yet known to be dead, or a dir with no lock
/// file (a removal in progress) is tried again every `step` until `wait`
/// has passed. The guard is started only after its backend made its lock
/// file, so it never claims a dir with none during the wait; after it, only
/// when the backend's pid is gone (one killed between its unlink and its
/// rmdir). True when this call removed the dir.
pub fn remove_backend_dir_waiting(dir: &Path, wait: Duration, step: Duration) -> bool {
    let (Some(root_path), Some(name)) = (dir.parent(), dir.file_name()) else { return false };
    if !name.to_str().is_some_and(|n| parse_backend_dir_name(n).is_some()) {
        return false;
    }
    let Ok(name) = CString::new(name.as_bytes()) else { return false };
    let me = euid();
    if !root_path.parent().is_some_and(|p| check_path_dirs(p, me, false).is_ok()) {
        return false;
    }
    let Ok(root) = open_root_dir(root_path, me) else { return false };
    #[cfg(test)]
    tests::hook(tests::Point::GuardWaitBegins, dir);
    let deadline = std::time::Instant::now() + wait;
    loop {
        let Ok(bd) = open_dir_at(&root, &name) else { return false };
        if !bd.metadata().is_ok_and(|m| m.is_dir() && m.uid() == me) {
            return false;
        }
        #[cfg(test)]
        tests::hook(tests::Point::GuardLockTry, dir);
        match take_lock_at(&bd, dir, true, false) {
            Ok(lock) => return remove_locked_at(&root, &name, &bd, lock, dir),
            Err(NoLock::Held | NoLock::NotDead | NoLock::Missing) if std::time::Instant::now() < deadline => {
                std::thread::sleep(step)
            }
            Err(NoLock::Missing) if dead_without_lock(dir, false, true) => {
                return match take_lock_at(&bd, dir, true, true) {
                    Ok(lock) => remove_locked_at(&root, &name, &bd, lock, dir),
                    Err(_) => false,
                };
            }
            Err(_) => return false,
        }
    }
}

/// What a live BackendDir holds: the root it was made in, open, and its
/// lock.
struct Held {
    root: File,
    lock: File,
}

/// This backend's dir in the root; its lock is held until remove().
pub struct BackendDir {
    path: PathBuf,
    name: CString,
    held: parking_lot::Mutex<Option<Held>>,
}

impl BackendDir {
    /// Makes core-<token>-<pid>-<rand12> (0700) with its lock (0600) in the
    /// root, opened first (a private dir of the user, never through a
    /// symlink) and kept open, and takes the lock. A sweep can take a new
    /// dir's lock before we do, so the dir counts only when we hold the
    /// lock, the file named lock in the dir at that name is still the one
    /// we hold and still linked (NFS renames an unlinked file that is open,
    /// and another remover may then make a lock file of its own); otherwise
    /// another name is tried.
    pub fn create(root: &Path, token: &str) -> Result<BackendDir> {
        let root_dir =
            open_root_dir(root, euid()).map_err(|e| anyhow!("cannot open the runtime dir {}: {e}", root.display()))?;
        let pid = std::process::id();
        let mut last = String::new();
        for _ in 0..CREATE_TRIES {
            let name = backend_dir_name(token, pid, &rand12());
            let path = root.join(&name);
            let cname = CString::new(name).map_err(|_| anyhow!("{} is not a valid name", path.display()))?;
            match mkdir_private_at(&root_dir, &cname) {
                Ok(()) => {}
                Err(e) if e.kind() == ErrorKind::AlreadyExists => {
                    last = format!("{} exists", path.display());
                    continue;
                }
                Err(e) => return Err(anyhow!("cannot create {}: {e}", path.display())),
            }
            let Ok(bd) = open_dir_at(&root_dir, &cname) else {
                last = format!("{} was removed while it was made", path.display());
                continue;
            };
            let lock = match create_file_at(&bd, LOCK_C) {
                Ok(f) => f,
                Err(e) if matches!(e.kind(), ErrorKind::NotFound | ErrorKind::AlreadyExists) => {
                    last = format!("{} was taken by a sweep", path.display());
                    continue;
                }
                Err(e) => return Err(anyhow!("cannot create the lock in {}: {e}", path.display())),
            };
            #[cfg(test)]
            tests::hook(tests::Point::BeforeLock, &path);
            match try_lock(&lock) {
                Ok(()) => {}
                Err(TryLockError::WouldBlock) => {
                    last = format!("the lock of {} is held by a sweep", path.display());
                    continue;
                }
                Err(TryLockError::Error(e)) => {
                    tracing::warn!("runtime: cannot lock {}: {e}; going on without it", path.display())
                }
            }
            if open_held(&root_dir, &cname, &lock).is_some() {
                return Ok(BackendDir {
                    path,
                    name: cname,
                    held: parking_lot::Mutex::new(Some(Held { root: root_dir, lock })),
                });
            }
            last = format!("{} was removed while it was made", path.display());
        }
        Err(anyhow!("cannot make a backend dir in {} after {CREATE_TRIES} tries: {last}", root.display()))
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    /// A new kernel-<uuid> dir (0700) for one kernel start, made in this
    /// backend's dir through its handle (kernel starts use
    /// Runtime::new_kernel_dir, which makes the backend dir again first when
    /// it was removed). For tests.
    #[cfg(test)]
    pub fn new_kernel_dir(&self) -> Result<Arc<KernelDir>> {
        match self.kernel_dir_if_held() {
            Ok(Some(k)) => Ok(k),
            Ok(None) => Err(anyhow!(
                "cannot create a kernel dir in {}: it is not this backend's dir any more",
                self.path.display()
            )),
            Err(e) => Err(anyhow!("cannot create a kernel dir in {}: {e}", self.path.display())),
        }
    }

    /// A new kernel dir, made through handles, when the root's path still
    /// leads to the root held open (what a kernel is given is a path) and
    /// the dir at this backend dir's name in it is still the one this
    /// backend holds: its file named lock is the lock held, and it is a real
    /// dir. Ok(None) once either was removed or replaced, and after
    /// remove().
    fn kernel_dir_if_held(&self) -> io::Result<Option<Arc<KernelDir>>> {
        let held = self.held.lock();
        let Some(h) = held.as_ref() else { return Ok(None) };
        if !self.root_at_path(&h.root) {
            return Ok(None);
        }
        let Some(bd) = open_held(&h.root, &self.name, &h.lock) else { return Ok(None) };
        let kname = format!("{KERNEL_PREFIX}{}", uuid::Uuid::new_v4().simple());
        let cname = CString::new(kname.as_str()).map_err(|_| io::Error::from(ErrorKind::InvalidInput))?;
        match mkdir_private_at(&bd, &cname) {
            Ok(()) => {}
            // removed since the check
            Err(e) if e.kind() == ErrorKind::NotFound => return Ok(None),
            Err(e) => return Err(e),
        }
        Ok(Some(Arc::new(KernelDir {
            dir: self.path.join(&kname),
            parent: bd,
            name: cname,
            removed: AtomicBool::new(false),
        })))
    }

    /// Whether the root's path leads to the dir `root` (device and inode).
    fn root_at_path(&self, root: &File) -> bool {
        let Some(p) = self.path.parent() else { return false };
        match (fs::symlink_metadata(p), root.metadata()) {
            (Ok(at), Ok(held)) => at.is_dir() && (at.dev(), at.ino()) == (held.dev(), held.ino()),
            _ => false,
        }
    }

    /// Whether remove() ran (the backend is exiting).
    fn is_removed(&self) -> bool {
        self.held.lock().is_none()
    }

    /// Makes the dir again at the same path, with a new lock, after
    /// something removed or replaced it, or the root it is in, while this
    /// backend runs (a person, a cleaner of old files, another host's sweep
    /// where locks are not shared). The root is opened again from its path
    /// (prepare_root made it usable just before). A dir someone else made at
    /// the path is used only when it is a real dir of the user, and is set
    /// to 0700 first. The old lock is closed only once the new one is held.
    /// Ok(true) when it was made, Ok(false) when it is there with our lock
    /// already (another kernel start made it again first). Err after
    /// remove(). An Err that is a Lost when the dir or the root went, or
    /// another backend's sweep took the new lock, before the new lock was
    /// held (Runtime::new_kernel_dir tries again).
    fn recreate(&self) -> Result<bool> {
        let lost = |what: String| -> anyhow::Error { Lost(what).into() };
        let mut held = self.held.lock();
        let Some(h) = held.as_mut() else {
            return Err(anyhow!("{} was removed at exit", self.path.display()));
        };
        let me = euid();
        let root_path = self.path.parent().ok_or_else(|| anyhow!("{} has no parent dir", self.path.display()))?;
        let root = match open_root_dir(root_path, me) {
            Ok(r) => r,
            Err(e) if e.kind() == ErrorKind::NotFound => {
                return Err(lost(format!("the runtime dir {} was removed while it was made again", root_path.display())))
            }
            Err(e) => return Err(anyhow!("cannot open the runtime dir {}: {e}", root_path.display())),
        };
        if open_held(&root, &self.name, &h.lock).is_some() {
            h.root = root;
            return Ok(false);
        }
        match mkdir_private_at(&root, &self.name) {
            Ok(()) => {}
            Err(e) if e.kind() == ErrorKind::NotFound => {
                return Err(lost(format!("the runtime dir {} was removed while it was made again", root_path.display())))
            }
            Err(e) if e.kind() == ErrorKind::AlreadyExists => {
                let st = stat_at_err(&root, &self.name).map_err(|e| anyhow!("{}: {e}", self.path.display()))?;
                let is_link = st.st_mode & libc::S_IFMT == libc::S_IFLNK;
                match private_dir_verdict(is_link, st_is_dir(&st), st.st_uid, mode_bits(&st), me) {
                    Verdict::Ok => {}
                    Verdict::Repair => {
                        let mode = mode_bits(&st);
                        set_dir_mode_at(&root, &self.name, 0o700, me).map_err(|e| {
                            anyhow!("{} has mode {mode:o} and cannot be set to 700: {e}", self.path.display())
                        })?;
                        tracing::info!("runtime: set {} from mode {mode:o} to 700", self.path.display());
                    }
                    Verdict::Reject(why) => return Err(anyhow!("{} {why}", self.path.display())),
                }
            }
            Err(e) => return Err(anyhow!("cannot create {}: {e}", self.path.display())),
        }
        #[cfg(test)]
        tests::hook(tests::Point::RecreateMade, &self.path);
        let bd = match open_dir_at(&root, &self.name) {
            Ok(bd) => bd,
            Err(e) if e.kind() == ErrorKind::NotFound => {
                return Err(lost(format!("{} was removed while it was made again", self.path.display())))
            }
            Err(e) => return Err(anyhow!("cannot open {}: {e}", self.path.display())),
        };
        if !bd.metadata().is_ok_and(|m| m.is_dir() && m.uid() == me) {
            return Err(anyhow!("{} changed while it was made again", self.path.display()));
        }
        #[cfg(test)]
        tests::hook(tests::Point::RecreateOpened, &self.path);
        let lock = match create_file_at(&bd, LOCK_C) {
            Ok(f) => f,
            // removed meanwhile, or a remover's lock file is still in it
            Err(e) if matches!(e.kind(), ErrorKind::NotFound | ErrorKind::AlreadyExists) => {
                return Err(lost(format!("{} was taken by a sweep while it was made again", self.path.display())))
            }
            Err(e) => return Err(anyhow!("cannot create the lock in {}: {e}", self.path.display())),
        };
        #[cfg(test)]
        tests::hook(tests::Point::RecreateBeforeLock, &self.path);
        match try_lock(&lock) {
            Ok(()) => {}
            Err(TryLockError::WouldBlock) => {
                return Err(lost(format!("the lock of {} is held by a sweep", self.path.display())))
            }
            Err(TryLockError::Error(e)) => {
                tracing::warn!("runtime: cannot lock {}: {e}; going on without it", self.path.display())
            }
        }
        if open_held(&root, &self.name, &lock).is_none() {
            return Err(lost(format!("{} was removed while it was made again", self.path.display())));
        }
        *h = Held { root, lock };
        Ok(true)
    }

    /// Removes the dir with everything in it, then releases the lock: only
    /// the dir at this backend dir's name in the root held open whose file
    /// named lock is the lock held, and only through handles, so a dir or a
    /// symlink put at that path instead is left alone. Idempotent.
    pub fn remove(&self) {
        let Some(Held { root, lock }) = self.held.lock().take() else { return };
        let Some(bd) = open_held(&root, &self.name, &lock) else {
            if stat_at_err(&root, &self.name).is_ok() {
                tracing::warn!(
                    "runtime: {} is not this backend's dir any more (its file named lock is not the lock held); \
                     left alone",
                    self.path.display()
                );
            }
            return;
        };
        // what it could not remove is logged there, once
        remove_locked_at(&root, &self.name, &bd, lock, &self.path);
    }
}

/// Why recreate made no backend dir this time, when trying again can make
/// one: the dir or its root went, or another backend's sweep took the new
/// lock, before the new lock was held.
#[derive(Debug)]
struct Lost(String);

impl std::fmt::Display for Lost {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for Lost {}

// ── kernel dirs and connection files ────────────────────

/// One kernel start's dir; removed by remove() or on drop.
pub struct KernelDir {
    dir: PathBuf,
    /// the backend dir it is in, open
    parent: File,
    name: CString,
    removed: AtomicBool,
}

impl KernelDir {
    #[cfg(test)]
    pub fn path(&self) -> &Path {
        &self.dir
    }

    pub fn conn_path(&self) -> PathBuf {
        self.dir.join(CONN_FILE)
    }

    /// Writes the connection file (a new file, 0600, one write), made
    /// through the handles of the backend dir and the kernel dir.
    pub fn write_connection(&self, info: &ConnectionInfo) -> Result<()> {
        let val = serde_json::json!({
            "ip": info.ip,
            "transport": info.transport,
            "shell_port": info.shell_port,
            "iopub_port": info.iopub_port,
            "stdin_port": info.stdin_port,
            "control_port": info.control_port,
            "hb_port": info.hb_port,
            "key": info.key,
            "signature_scheme": info.signature_scheme,
            "kernel_name": info.kernel_name,
        });
        let bytes = serde_json::to_vec_pretty(&val)?;
        let path = self.conn_path();
        let mut f = open_dir_at(&self.parent, &self.name)
            .and_then(|kd| create_file_at(&kd, CONN_C))
            .with_context(|| format!("cannot create {}", path.display()))?;
        f.write_all(&bytes).with_context(|| format!("cannot write {}", path.display()))?;
        Ok(())
    }

    /// The connection file once the kernel has written its bound ports back.
    /// Ok(None): missing, not parsable yet (a write in progress), or a port
    /// still 0 or missing. Err: the key, ip, transport or signature scheme
    /// differ from ours, or a port is not a valid port number. Ok(Some):
    /// ours with the five ports from the file.
    pub fn read_written_back(&self, ours: &ConnectionInfo) -> Result<Option<ConnectionInfo>> {
        let path = self.conn_path();
        let bytes = match fs::read(&path) {
            Ok(b) => b,
            Err(e) if e.kind() == ErrorKind::NotFound => return Ok(None),
            Err(e) => return Err(anyhow!("cannot read {}: {e}", path.display())),
        };
        let Ok(serde_json::Value::Object(obj)) = serde_json::from_slice::<serde_json::Value>(&bytes) else {
            return Ok(None);
        };
        for (field, want) in [
            ("key", &ours.key),
            ("ip", &ours.ip),
            ("transport", &ours.transport),
            ("signature_scheme", &ours.signature_scheme),
        ] {
            if obj.get(field).and_then(|v| v.as_str()) != Some(want.as_str()) {
                return Err(anyhow!("{} has another {field} than the one written", path.display()));
            }
        }
        let mut ports = [0u16; 5];
        let mut pending = false;
        for (i, field) in PORT_KEYS.iter().enumerate() {
            match obj.get(*field) {
                None | Some(serde_json::Value::Null) => pending = true,
                Some(v) => match v.as_u64() {
                    Some(0) => pending = true,
                    Some(p) if p <= u16::MAX as u64 => ports[i] = p as u16,
                    _ => return Err(anyhow!("{} has an invalid {field}: {v}", path.display())),
                },
            }
        }
        if pending {
            return Ok(None);
        }
        Ok(Some(ConnectionInfo {
            shell_port: ports[0],
            iopub_port: ports[1],
            stdin_port: ports[2],
            control_port: ports[3],
            hb_port: ports[4],
            ..ours.clone()
        }))
    }

    /// Removes the dir and the file in it, through the backend dir's handle.
    /// Idempotent.
    pub fn remove(&self) {
        if !self.removed.swap(true, Ordering::AcqRel) {
            let backend = self.dir.parent().unwrap_or(&self.dir);
            // what it could not remove is logged there, once
            remove_entry_at(&self.parent, &self.name, backend);
        }
    }
}

impl Drop for KernelDir {
    fn drop(&mut self) {
        self.remove()
    }
}

// ── the process's runtime ───────────────────────────────

pub struct Runtime {
    pub source: Source,
    pub root: PathBuf,
    pub backend: BackendDir,
}

impl Runtime {
    /// A new kernel dir for one kernel start, in the backend dir this
    /// backend holds the lock of. When the backend dir or the root was
    /// removed or replaced while this backend runs, both are made again at
    /// the same paths first, so the guard's argument and the logs keep
    /// naming the right dir; when another backend's sweep takes the dir
    /// again before its new lock is held (recreate's Lost), it is made again
    /// once more, up to CREATE_TRIES times. After the exit's remove() it is
    /// an error.
    pub fn new_kernel_dir(&self) -> Result<Arc<KernelDir>> {
        let dir = self.backend.path();
        let exiting = || anyhow!("the backend is exiting; {} was removed", dir.display());
        let mut tries = 0;
        loop {
            if self.backend.is_removed() {
                return Err(exiting());
            }
            match self.backend.kernel_dir_if_held() {
                Ok(Some(k)) => return Ok(k),
                // removed or replaced: made again below
                Ok(None) => {}
                Err(e) => return Err(anyhow!("cannot create a kernel dir in {}: {e}", dir.display())),
            }
            if self.backend.is_removed() {
                return Err(exiting());
            }
            if tries == CREATE_TRIES {
                return Err(anyhow!(
                    "cannot create a kernel dir in {}: it was removed each time it was made again ({CREATE_TRIES} \
                     tries)",
                    dir.display()
                ));
            }
            tries += 1;
            prepare_root(self.source, &self.root, euid())
                .with_context(|| format!("cannot make the runtime dir {} again", self.root.display()))?;
            match self.backend.recreate() {
                Ok(true) => tracing::info!("runtime: {} was removed while in use; made it again", dir.display()),
                Ok(false) => {}
                Err(e) if e.is::<Lost>() => {
                    tracing::debug!("runtime: {e:#}; trying again");
                    #[cfg(test)]
                    tests::note_lost(&e, dir);
                    // the remover that took it is done in microseconds
                    std::thread::sleep(Duration::from_millis(tries as u64));
                }
                Err(e) => return Err(e),
            }
        }
    }
}

/// The process's runtime, once the first kernel start made it.
static RUNTIME: OnceCell<Runtime> = OnceCell::new();
/// Lets one kernel start at a time make the runtime.
static MAKING: parking_lot::Mutex<()> = parking_lot::Mutex::new(());
/// Set by shutdown(): from then on no runtime is made.
static EXITING: parking_lot::Mutex<bool> = parking_lot::Mutex::new(false);

/// The runtime root and this backend's dir, made at the first kernel start,
/// and the guard process for it. An error once the exit has begun.
pub fn runtime() -> Result<&'static Runtime> {
    if let Some(rt) = RUNTIME.get() {
        return Ok(rt);
    }
    let _one = MAKING.lock();
    if let Some(rt) = RUNTIME.get() {
        return Ok(rt);
    }
    if *EXITING.lock() {
        return Err(anyhow!("the backend is exiting"));
    }
    let env = EnvView::from_process();
    let (source, root) = choose_root(&env, euid())?;
    let backend = BackendDir::create(&root, &host_token())?;
    let rt = publish(&RUNTIME, &EXITING, Runtime { source, root, backend })?;
    tracing::info!("runtime: kernel files in {} ({})", rt.root.display(), rt.source.label());
    crate::guard::start(rt.backend.path());
    Ok(rt)
}

/// Makes `rt` the process's runtime, unless the exit began while it was
/// made: then its new backend dir is removed and it is an error. Decided
/// under `exiting`'s lock, which exit_runtime takes too, so either the exit
/// finds the runtime and removes its dir, or this finds the exit.
fn publish<'a>(cell: &'a OnceCell<Runtime>, exiting: &parking_lot::Mutex<bool>, rt: Runtime) -> Result<&'a Runtime> {
    let state = exiting.lock();
    if *state {
        drop(state);
        rt.backend.remove();
        return Err(anyhow!("the backend is exiting; {} was removed", rt.backend.path().display()));
    }
    #[cfg(test)]
    tests::hook(tests::Point::BeforePublish, rt.backend.path());
    if let Err(made_twice) = cell.set(rt) {
        // only one start makes the runtime (MAKING); never two dirs
        drop(state);
        made_twice.backend.remove();
    }
    Ok(cell.get().expect("the runtime was set above"))
}

/// The exit's part of publish: from now on no runtime is made, and the one
/// made already has its backend dir removed.
fn exit_runtime(cell: &OnceCell<Runtime>, exiting: &parking_lot::Mutex<bool>) {
    *exiting.lock() = true;
    if let Some(rt) = cell.get() {
        rt.backend.remove();
    }
}

/// Clean exit: stops every kernel group still registered with the guard
/// (from then on a group registered is stopped at once) and lets the guard
/// exit, then removes this backend's dir, also one a kernel start is making
/// at this moment.
pub fn shutdown() {
    crate::guard::finish();
    exit_runtime(&RUNTIME, &EXITING);
}

// ── sweeps at start ─────────────────────────────────────

#[derive(Debug, Default)]
pub struct SweepReport {
    pub stale_removed: usize,
    pub legacy_removed: usize,
    pub legacy_dir_removed: bool,
}

/// Starts sweep_at_start off the RPC path and returns at once; logs what it
/// removed, and one line when it is done. Nothing waits for it, not even the
/// exit: a sweep slowed down by a filesystem never holds up requests or the
/// backend's exit, and one cut short by the exit is finished by the next
/// start (every removal holds the dir's lock, which the exit releases).
pub fn spawn_sweep_at_start() {
    spawn_sweep(|| {
        let r = sweep_at_start();
        if r.stale_removed + r.legacy_removed > 0 {
            tracing::info!(
                "runtime sweep: removed {} stale backend dir(s) and {} old connection file(s)",
                r.stale_removed,
                r.legacy_removed
            );
        }
        tracing::info!("runtime sweep: done");
    });
}

/// Runs `work` on a thread of its own, not tokio's blocking pool: dropping
/// the runtime at exit waits for every task still running in that pool.
fn spawn_sweep<F: FnOnce() + Send + 'static>(work: F) {
    if let Err(e) = std::thread::Builder::new().name("jnv-sweep".into()).spawn(work) {
        tracing::warn!("runtime sweep: cannot start a thread for it: {e}");
    }
}

/// Removes dead backends' dirs from every candidate root that already exists
/// and is usable (verify_root; nothing is made or changed), each read
/// through a handle of its own, then old connection files from the old
/// location in the system temp dir.
pub fn sweep_at_start() -> SweepReport {
    sweep_at_start_in(&EnvView::from_process(), &legacy_dir(), euid(), &host_token(), SystemTime::now())
}

/// sweep_at_start for the environment `env` and the old location `legacy`.
fn sweep_at_start_in(env: &EnvView, legacy: &Path, euid: u32, token: &str, now: SystemTime) -> SweepReport {
    let mut report = SweepReport::default();
    let mut roots = Vec::new();
    let candidates = candidates(env, euid);
    for (source, root) in &candidates {
        if !verify_root(*source, root, euid) {
            continue;
        }
        let Ok(dir) = open_root_dir(root, euid) else { continue };
        let Ok(m) = dir.metadata() else { continue };
        // one dir named by two candidates (JUPYNVIM_RUNTIME_DIR set to the
        // system temp dir) is swept once, by the first
        if roots.contains(&(m.dev(), m.ino())) {
            continue;
        }
        roots.push((m.dev(), m.ino()));
        report.stale_removed += sweep_stale_at(&dir, root, source.local(), token, now);
    }
    // A root can be the old location itself (JUPYNVIM_RUNTIME_DIR set to the
    // system temp dir where others cannot write to it): it is then kept even
    // when empty. Judged by its path, not only by the roots swept above: a
    // root that did not exist yet, or was not usable yet, when they were
    // swept can be made (or repaired) by a kernel start at any moment, which
    // makes its backend dir in it right after.
    let is_root = candidates.iter().any(|(_, r)| same_dir_path(r, legacy));
    let (n, dir_removed) = sweep_legacy(legacy, now, LEGACY_MIN_AGE, euid, &roots, is_root);
    report.legacy_removed = n;
    report.legacy_dir_removed = dir_removed;
    report
}

/// Whether the paths `a` and `b` name the same entry: the same name in the
/// same dir (device and inode, symlinks in the dirs' paths followed), else
/// equal paths. Neither needs to exist.
fn same_dir_path(a: &Path, b: &Path) -> bool {
    if a == b {
        return true;
    }
    let (Some(an), Some(bn)) = (a.file_name(), b.file_name()) else { return false };
    if an != bn {
        return false;
    }
    match (a.parent().map(fs::metadata), b.parent().map(fs::metadata)) {
        (Some(Ok(x)), Some(Ok(y))) => (x.dev(), x.ino()) == (y.dev(), y.ino()),
        _ => false,
    }
}

fn older_than(t: Option<SystemTime>, now: SystemTime, age: Duration) -> bool {
    t.and_then(|t| now.duration_since(t).ok()).is_some_and(|a| a > age)
}

/// sweep_stale_at on the root at `root`, opened without following a
/// symlink (a private dir of the user, else nothing is read). For tests.
#[cfg(test)]
pub fn sweep_stale(root: &Path, local: bool, token: &str, now: SystemTime) -> usize {
    match open_root_dir(root, euid()) {
        Ok(dir) => sweep_stale_at(&dir, root, local, token, now),
        Err(_) => 0,
    }
}

/// Removes the dead backend dirs in the open root `root` (`shown` in log
/// lines): one whose lock can be taken, or one with no lock file older than
/// 60 s (a dir is claimed only when it had no lock file when it was judged,
/// and its age is read after that, so a dir whose remover unlinks its lock
/// file meanwhile is left alone). With `local` (a root only this host uses)
/// every host's dirs follow these rules; else they are this host's
/// (`token`) rules, and another host's dir goes only once nothing in it
/// changed for 7 days and its lock can really be taken (a missing lock file
/// is claimed only when the dir is still old when read again after it was
/// seen missing; that host's pids mean nothing here). Each dir is
/// opened without following a symlink and only a dir of the user is read;
/// what is checked and removed is that open dir (remove_locked_at). Every
/// other entry is left alone. Returns how many dirs were removed.
fn sweep_stale_at(root: &File, shown: &Path, local: bool, token: &str, now: SystemTime) -> usize {
    let me = euid();
    let mut removed = 0;
    for name in dir_names(root).unwrap_or_default() {
        let Some((tok, _pid)) = name.to_str().ok().and_then(parse_backend_dir_name) else { continue };
        let Ok(bd) = open_dir_at(root, &name) else { continue };
        let Ok(m) = bd.metadata() else { continue };
        if !m.is_dir() || m.uid() != me {
            continue;
        }
        let dir = shown.join(OsStr::from_bytes(name.to_bytes()));
        if !local && tok != token {
            let old = newest_mtime_at(&bd)
                .and_then(|t| now.duration_since(t).ok())
                .is_some_and(|age| age > FOREIGN_MIN_AGE);
            if !old {
                continue;
            }
            // A lock file seen now is taken without a claim (gone by then: a
            // removal in progress); a missing one is claimed only when the
            // dir is still old, its mtime read after the lock file was seen
            // missing (a remover's unlink makes it young).
            #[cfg(test)]
            tests::hook(tests::Point::BeforeLockStat, &dir);
            let claim = match stat_at_err(&bd, LOCK_C) {
                Ok(_) => {
                    #[cfg(test)]
                    tests::hook(tests::Point::SweepJudged, &dir);
                    false
                }
                Err(e) if e.kind() == ErrorKind::NotFound => {
                    if !older_than(bd.metadata().ok().and_then(|m| m.modified().ok()), now, FOREIGN_MIN_AGE) {
                        continue;
                    }
                    true
                }
                Err(_) => continue,
            };
            if remove_dead_at(root, &name, &bd, false, claim, &dir) {
                removed += 1;
            }
            continue;
        }
        // Judged by its lock file (dead when that lock can be taken, in
        // remove_dead_at), or, with none, by its age, read after the lock
        // file was seen missing (a remover's unlink makes the dir young).
        // Only a dir that had no lock file when it was judged is claimed: a
        // lock file that is gone by the time remove_dead_at opens it was
        // unlinked by a remover that is removing the dir right now.
        #[cfg(test)]
        tests::hook(tests::Point::BeforeLockStat, &dir);
        let (dead, claim) = match stat_at_err(&bd, LOCK_C) {
            Ok(_) => {
                #[cfg(test)]
                tests::hook(tests::Point::SweepJudged, &dir);
                (true, false)
            }
            Err(e) if e.kind() == ErrorKind::NotFound => {
                (older_than(bd.metadata().ok().and_then(|m| m.modified().ok()), now, STALE_NOLOCK_AGE), true)
            }
            Err(_) => (false, false),
        };
        if dead && remove_dead_at(root, &name, &bd, true, claim, &dir) {
            removed += 1;
        }
    }
    removed
}

/// The newest mtime of the open backend dir `bd`, its entries and the
/// entries of its kernel dirs, read without following a symlink and no
/// deeper. None when anything cannot be read (the dir is then kept).
fn newest_mtime_at(bd: &File) -> Option<SystemTime> {
    let mut newest = bd.metadata().ok()?.modified().ok()?;
    for name in dir_names(bd).ok()? {
        let st = stat_at_err(bd, &name).ok()?;
        newest = newest.max(mtime_of(&st)?);
        if st_is_dir(&st) && name.to_bytes().starts_with(KERNEL_PREFIX.as_bytes()) {
            let k = open_dir_at(bd, &name).ok()?;
            for inner in dir_names(&k).ok()? {
                newest = newest.max(mtime_of(&stat_at_err(&k, &inner).ok()?)?);
            }
        }
    }
    Some(newest)
}

/// The old location of connection files: jupynvim in the system temp dir.
pub fn legacy_dir() -> PathBuf {
    std::env::temp_dir().join(ROOT_NAME)
}

/// kernel-<8-4-4-4-12 lowercase hex>.json, as older versions named them.
fn is_legacy_name(name: &str) -> bool {
    let Some(id) = name.strip_prefix(KERNEL_PREFIX).and_then(|r| r.strip_suffix(".json")) else {
        return false;
    };
    id.len() == 36
        && id.bytes().enumerate().all(|(i, b)| {
            if matches!(i, 8 | 13 | 18 | 23) {
                b == b'-'
            } else {
                matches!(b, b'0'..=b'9' | b'a'..=b'f')
            }
        })
}

/// Removes the old location's connection files: regular files of ours named
/// as older versions named them and older than `min_age`; then the dir
/// itself when it is empty, not one of the roots in `keep` (device and
/// inode) and not a candidate root's path (`is_root`). Only a real dir of the user's own is read, through one handle
/// opened without following a symlink, and every check and removal in it
/// is made relative to that handle: whoever can rename entries next to it
/// cannot swap it for another dir, or a symlink to one, between them. A dir
/// another user made is left alone (older versions wrote each user's files
/// from that user's own process, so none of ours are in it). Returns (files
/// removed, dir removed).
pub fn sweep_legacy(
    dir: &Path,
    now: SystemTime,
    min_age: Duration,
    euid: u32,
    keep: &[(u64, u64)],
    is_root: bool,
) -> (usize, bool) {
    let (Some(parent), Some(name)) = (dir.parent(), dir.file_name()) else { return (0, false) };
    let Ok(name) = CString::new(name.as_bytes()) else { return (0, false) };
    // The system temp dir itself, symlinks in its path followed (on macOS
    // its path goes through one).
    let Ok(parent) = OpenOptions::new().read(true).custom_flags(libc::O_DIRECTORY).open(parent) else {
        return (0, false);
    };
    let Ok(d) = open_dir_at(&parent, &name) else { return (0, false) };
    let Ok(m) = d.metadata() else { return (0, false) };
    if !m.file_type().is_dir() || m.uid() != euid {
        return (0, false);
    }
    #[cfg(test)]
    tests::hook(tests::Point::LegacyOpened, dir);
    let mut removed = 0;
    for entry in dir_names(&d).unwrap_or_default() {
        if !entry.to_str().is_ok_and(is_legacy_name) {
            continue;
        }
        let Ok(st) = stat_at_err(&d, &entry) else { continue };
        let old = mtime_of(&st).and_then(|t| now.duration_since(t).ok()).is_some_and(|age| age > min_age);
        if !st_is_file(&st) || st.st_uid != euid || !old {
            continue;
        }
        // SAFETY: entry is NUL-terminated and outlives the call; d is an
        // open dir. Unlinking an entry never follows it.
        if unsafe { libc::unlinkat(d.as_raw_fd(), entry.as_ptr(), 0) } == 0 {
            removed += 1;
        } else {
            tracing::debug!(
                "runtime sweep: cannot remove {}: {}",
                dir.join(OsStr::from_bytes(entry.to_bytes())).display(),
                io::Error::last_os_error()
            );
        }
    }
    if is_root || keep.contains(&(m.dev(), m.ino())) {
        return (removed, false);
    }
    // the same dir still at that name: removed when empty
    let same = stat_at_err(&parent, &name).is_ok_and(|st| same_file(&st, &m));
    // SAFETY: name is NUL-terminated and outlives the call; parent is an
    // open dir. AT_REMOVEDIR removes an empty dir only.
    let dir_removed = same && unsafe { libc::unlinkat(parent.as_raw_fd(), name.as_ptr(), libc::AT_REMOVEDIR) } == 0;
    (removed, dir_removed)
}

/// Opens the dir `name` in the open dir `parent`, close-on-exec, without
/// following a symlink (a symlink, or anything but a dir, is an error).
fn open_dir_at(parent: &File, name: &CStr) -> io::Result<File> {
    let flags = libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC;
    // SAFETY: name is NUL-terminated and outlives the call; parent is an
    // open dir.
    let fd = unsafe { libc::openat(parent.as_raw_fd(), name.as_ptr(), flags) };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: fd was just opened here and nothing else owns it.
    Ok(unsafe { File::from_raw_fd(fd) })
}

/// What the entry `name` of the open dir `dir` is, without following a
/// symlink.
fn stat_at_err(dir: &File, name: &CStr) -> io::Result<libc::stat> {
    let mut st = std::mem::MaybeUninit::<libc::stat>::uninit();
    // SAFETY: name is NUL-terminated and outlives the call; st is valid
    // for the call to fill in.
    let rc = unsafe { libc::fstatat(dir.as_raw_fd(), name.as_ptr(), st.as_mut_ptr(), libc::AT_SYMLINK_NOFOLLOW) };
    if rc != 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: fstatat filled st in when it returned 0.
    Ok(unsafe { st.assume_init() })
}

fn st_is_dir(st: &libc::stat) -> bool {
    st.st_mode & libc::S_IFMT == libc::S_IFDIR
}

fn st_is_file(st: &libc::stat) -> bool {
    st.st_mode & libc::S_IFMT == libc::S_IFREG
}

/// The permission bits of `st` (with setuid, setgid and sticky).
// st_mode is a u16 on macOS and a u32 on Linux.
#[allow(clippy::unnecessary_cast)]
fn mode_bits(st: &libc::stat) -> u32 {
    st.st_mode as u32 & 0o7777
}

/// The mtime of `st`, nanoseconds kept; None before 1970.
fn mtime_of(st: &libc::stat) -> Option<SystemTime> {
    let secs = u64::try_from(st.st_mtime).ok()?;
    let nanos = u32::try_from(st.st_mtime_nsec).ok()?;
    SystemTime::UNIX_EPOCH.checked_add(Duration::new(secs, nanos))
}

/// Whether `st` and `m` describe the same file (device and inode).
// st_dev is an i32 on macOS and a u64 on Linux; std's dev() casts it the
// same way.
#[allow(clippy::unnecessary_cast)]
fn same_file(st: &libc::stat, m: &fs::Metadata) -> bool {
    st.st_dev as u64 == m.dev() && st.st_ino == m.ino()
}

/// Sets this thread's errno to 0, so that a NULL from readdir tells the end
/// of the dir from an error.
fn clear_errno() {
    // SAFETY: __error returns this thread's errno, always valid to write.
    #[cfg(target_os = "macos")]
    unsafe {
        *libc::__error() = 0
    };
    // SAFETY: __errno_location returns this thread's errno, always valid to
    // write.
    #[cfg(target_os = "linux")]
    unsafe {
        *libc::__errno_location() = 0
    };
}

/// The names in the open dir `dir`, without `.` and `..`, read from its
/// start; Err when it cannot be read to the end.
fn dir_names(dir: &File) -> io::Result<Vec<CString>> {
    // The listing reads a handle of its own, which closedir closes.
    // SAFETY: F_DUPFD_CLOEXEC only makes a new fd for the same open dir.
    let fd = unsafe { libc::fcntl(dir.as_raw_fd(), libc::F_DUPFD_CLOEXEC, 0) };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: fd is an open dir that nothing else uses; from here on the
    // DIR owns it.
    let dirp = unsafe { libc::fdopendir(fd) };
    if dirp.is_null() {
        let e = io::Error::last_os_error();
        // SAFETY: fdopendir failed, so fd is still ours to close.
        unsafe { libc::close(fd) };
        return Err(e);
    }
    // The copy shares its read position with `dir`, which an earlier
    // listing left at the end.
    // SAFETY: dirp is an open DIR used by this thread only.
    unsafe { libc::rewinddir(dirp) };
    let mut names = Vec::new();
    let result = loop {
        clear_errno();
        // SAFETY: dirp is an open DIR used by this thread only.
        let ent = unsafe { libc::readdir(dirp) };
        if ent.is_null() {
            let e = io::Error::last_os_error();
            let failed = cfg!(any(target_os = "macos", target_os = "linux")) && e.raw_os_error().is_some_and(|c| c != 0);
            break if failed { Err(e) } else { Ok(()) };
        }
        // SAFETY: readdir returned an entry whose d_name is NUL-terminated
        // and valid until the next readdir on dirp; it is copied at once.
        let name = unsafe { CStr::from_ptr((*ent).d_name.as_ptr()) };
        if name.to_bytes() != b"." && name.to_bytes() != b".." {
            names.push(name.to_owned());
        }
    };
    // SAFETY: dirp is open and not used after this; it closes fd.
    unsafe { libc::closedir(dirp) };
    result.map(|()| names)
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::kernel::ConnectionInfo;
    use std::fs::{self, File, OpenOptions};
    use std::io::Write;
    use std::os::unix::ffi::OsStrExt;
    use std::os::unix::fs::{symlink, FileTypeExt, MetadataExt, OpenOptionsExt, PermissionsExt};
    use std::os::unix::io::AsRawFd;
    use std::path::{Path, PathBuf};
    use std::time::{Duration, Instant, SystemTime};

    /// A scratch dir of its own per test, removed at the end (also on a
    /// failed assertion). Removal uses std, not the code under test.
    struct TestDir(PathBuf);

    impl TestDir {
        fn new(name: &str) -> TestDir {
            let p = std::env::temp_dir().join(format!("jvtest-connfile-{}-{}", std::process::id(), name));
            let _ = fs::remove_dir_all(&p);
            fs::create_dir_all(&p).unwrap();
            fs::set_permissions(&p, fs::Permissions::from_mode(0o700)).unwrap();
            TestDir(p)
        }

        fn path(&self) -> &Path {
            &self.0
        }

        fn join(&self, rel: &str) -> PathBuf {
            self.0.join(rel)
        }
    }

    impl Drop for TestDir {
        fn drop(&mut self) {
            make_removable(&self.0);
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    /// Gives every real dir under `p` mode 0700 (a failed check can leave
    /// dirs without the owner's read bit), never following a symlink.
    fn make_removable(p: &Path) {
        let Ok(m) = fs::symlink_metadata(p) else { return };
        if !m.file_type().is_dir() {
            return;
        }
        let _ = fs::set_permissions(p, fs::Permissions::from_mode(0o700));
        if let Ok(entries) = fs::read_dir(p) {
            for e in entries.flatten() {
                make_removable(&e.path());
            }
        }
    }

    /// The parent dir of `p`, open (symlinks in its path followed), and the
    /// name of `p` in it.
    fn open_parent(p: &Path) -> (File, CString) {
        let parent = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_DIRECTORY)
            .open(p.parent().unwrap())
            .unwrap();
        (parent, CString::new(p.file_name().unwrap().as_bytes()).unwrap())
    }

    /// create_file_at on the parent dir of `path`.
    fn create_private_file(path: &Path) -> std::io::Result<File> {
        let (dir, name) = open_parent(path);
        create_file_at(&dir, &name)
    }

    /// take_lock_at on the backend dir at `dir`, opened without following a
    /// symlink.
    fn take_lock(dir: &Path, pid_rule: bool) -> Result<File, NoLock> {
        let bd = open_dir_nofollow(dir).map_err(|_| NoLock::Other)?;
        take_lock_at(&bd, dir, pid_rule, true)
    }

    /// Removes the backend dir at `dir` through handles (remove_locked_at)
    /// while holding its lock: `held`, which must be the file named lock in
    /// it, or one taken here (remove_dead_at, with the pid rule).
    fn remove_backend_dir_locked(dir: &Path, held: Option<File>) -> bool {
        let (root, name) = open_parent(dir);
        let Ok(bd) = open_dir_at(&root, &name) else { return false };
        match held {
            Some(lock) => lock_is_named(&bd, &lock) && remove_locked_at(&root, &name, &bd, lock, dir),
            None => remove_dead_at(&root, &name, &bd, true, true, dir),
        }
    }

    /// Places in the code under test where a test can act, on its own
    /// thread only.
    #[derive(Clone, Copy, Debug, PartialEq, Eq)]
    pub(crate) enum Point {
        /// BackendDir::create, between making the lock file and locking it
        BeforeLock,
        /// remove_locked_at, after unlinking the lock file
        LockUnlinked,
        /// remove_locked_at, right after closing the lock
        LockReleased,
        /// publish, after it checked that the exit has not begun and before
        /// it makes the runtime the process's
        BeforePublish,
        /// sweep_legacy, after it checked the old dir and before it lists it
        LegacyOpened,
        /// sweep_stale_at, after it judged a dir by its file named lock and
        /// before it takes that lock (remove_dead_at)
        SweepJudged,
        /// BackendDir::recreate, between making the new lock file and
        /// locking it
        RecreateBeforeLock,
        /// sweep_stale_at, after it opened and checked a dir (and read the
        /// age of another host's dir) and before it looks for the dir's lock
        /// file
        BeforeLockStat,
        /// BackendDir::recreate, after it made the dir (or found one) and
        /// before it opens it
        RecreateMade,
        /// BackendDir::recreate, after it opened the dir and before it makes
        /// the new lock file
        RecreateOpened,
        /// Runtime::new_kernel_dir, after recreate gave a Lost and before it
        /// tries again (note_lost)
        RecreateLost,
        /// remove_backend_dir_waiting, after it opened the root and before
        /// its wait for the lock begins
        GuardWaitBegins,
        /// remove_backend_dir_waiting, before each try to take the lock
        GuardLockTry,
    }

    pub(crate) type Hook = Box<dyn FnMut(Point, &Path)>;

    thread_local! {
        static HOOK: std::cell::RefCell<Option<Hook>> = const { std::cell::RefCell::new(None) };
    }

    /// Runs the test's hook. Calls made from inside the hook (it may call
    /// the code under test) do not run it again.
    pub(super) fn hook(point: Point, dir: &Path) {
        let Some(mut f) = HOOK.with(|h| h.borrow_mut().take()) else { return };
        f(point, dir);
        HOOK.with(|h| {
            let mut h = h.borrow_mut();
            if h.is_none() {
                *h = Some(f);
            }
        });
    }

    pub(crate) fn set_hook(f: Option<Hook>) {
        HOOK.with(|h| *h.borrow_mut() = f);
    }

    thread_local! {
        /// The Lost errors Runtime::new_kernel_dir tried again after, on
        /// this thread.
        static LOST: std::cell::RefCell<Vec<String>> = const { std::cell::RefCell::new(Vec::new()) };
    }

    /// Notes a Lost that Runtime::new_kernel_dir tries again after, then
    /// runs the hook at Point::RecreateLost.
    pub(super) fn note_lost(e: &anyhow::Error, dir: &Path) {
        LOST.with(|l| l.borrow_mut().push(format!("{e:#}")));
        hook(Point::RecreateLost, dir);
    }

    /// The Lost errors noted on this thread since the last call.
    fn take_lost() -> Vec<String> {
        LOST.with(|l| std::mem::take(&mut *l.borrow_mut()))
    }

    thread_local! {
        static LOCKS_FAIL: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
    }

    /// Whether every lock attempt on this thread fails as it does on a
    /// filesystem without working locks (try_lock).
    pub(super) fn locks_fail() -> bool {
        LOCKS_FAIL.with(|c| c.get())
    }

    fn set_locks_fail(on: bool) {
        LOCKS_FAIL.with(|c| c.set(on));
    }

    fn set_before_lock(f: Option<Box<dyn FnMut(&Path)>>) {
        set_hook(f.map(|mut f| -> Hook {
            Box::new(move |point, dir| {
                if point == Point::BeforeLock {
                    f(dir)
                }
            })
        }));
    }

    fn mode(p: &Path) -> u32 {
        fs::symlink_metadata(p).unwrap().mode() & 0o7777
    }

    fn set_mode(p: &Path, m: u32) {
        fs::set_permissions(p, fs::Permissions::from_mode(m)).unwrap();
    }

    /// Makes `p` with mode `m`, and each missing dir above it with mode
    /// 0755, whatever the umask (under 002 create_dir_all alone would leave
    /// them open to the group, which the path rule refuses).
    fn mkdir_mode(p: &Path, m: u32) {
        let mut missing = vec![];
        let mut cur = p;
        while fs::symlink_metadata(cur).is_err() {
            missing.push(cur);
            cur = cur.parent().unwrap();
        }
        for d in missing.iter().rev() {
            fs::create_dir(d).unwrap();
            set_mode(d, 0o755);
        }
        set_mode(p, m);
    }

    fn set_mtime(p: &Path, t: SystemTime) {
        let f = if p.is_dir() {
            File::open(p).unwrap()
        } else {
            File::options().write(true).open(p).unwrap()
        };
        f.set_modified(t).unwrap();
    }

    /// Waits, up to 2 s, until `probe`'s lock can be taken (then releases
    /// it). A process that another test thread is starting holds a copy of
    /// every file this process has open until it runs its program, so a lock
    /// closed here can stay held for that long; a lock this thread still
    /// holds never becomes free.
    fn wait_free(probe: &File) -> bool {
        let deadline = Instant::now() + Duration::from_secs(2);
        loop {
            if probe.try_lock().is_ok() {
                let _ = probe.unlock();
                return true;
            }
            if Instant::now() >= deadline {
                return false;
            }
            std::thread::sleep(Duration::from_millis(1));
        }
    }

    /// wait_free on a new handle of the lock file at `path`.
    fn wait_lock_free(path: &Path) -> bool {
        wait_free(&File::open(path).unwrap())
    }

    /// The CPU time the calling thread has used (CLOCK_THREAD_CPUTIME_ID):
    /// time it spent waiting for a CPU is not in it.
    fn thread_cpu_time() -> Duration {
        let mut ts = libc::timespec { tv_sec: 0, tv_nsec: 0 };
        // SAFETY: ts is a valid timespec for the call to fill in.
        let rc = unsafe { libc::clock_gettime(libc::CLOCK_THREAD_CPUTIME_ID, &mut ts) };
        assert_eq!(rc, 0, "clock_gettime: {}", std::io::Error::last_os_error());
        Duration::new(ts.tv_sec as u64, ts.tv_nsec as u32)
    }

    fn conn(key: &str) -> ConnectionInfo {
        ConnectionInfo {
            ip: "127.0.0.1".to_string(),
            transport: "tcp".to_string(),
            shell_port: 0,
            iopub_port: 0,
            stdin_port: 0,
            control_port: 0,
            hb_port: 0,
            key: key.to_string(),
            signature_scheme: "hmac-sha256".to_string(),
            kernel_name: "python3".to_string(),
        }
    }

    fn ports_of(c: &ConnectionInfo) -> [u16; 5] {
        [c.shell_port, c.iopub_port, c.stdin_port, c.control_port, c.hb_port]
    }

    // U1
    #[test]
    fn u1_candidates_order_and_fallbacks() {
        let p = PathBuf::from;
        let e = 4321;
        let full = EnvView {
            override_dir: Some(p("/o/custom")),
            xdg_runtime_dir: Some(p("/x/run")),
            jupyter_runtime_dir: Some(p("/j/rt")),
            jupyter_data_dir: Some(p("/j/data")),
            xdg_data_home: Some(p("/x/data")),
            home: Some(p("/h")),
            temp_dir: Some(p("/t/mp")),
        };
        // the last one, in the system temp dir, is always the user's own name
        assert_eq!(
            candidates(&full, e),
            vec![
                (Source::Override, p("/o/custom/jupynvim")),
                (Source::XdgRuntime, p("/x/run/jupynvim")),
                (Source::JupyterRuntime, p("/j/rt/jupynvim")),
                (Source::Temp, p("/t/mp/jupynvim-4321")),
            ]
        );
        // a relative or missing temp dir gives no such candidate
        let no_temp = EnvView { temp_dir: Some(p("t/mp")), ..full.clone() };
        assert_eq!(candidates(&no_temp, e).len(), 3);
        assert_eq!(candidates(&EnvView { temp_dir: None, ..full.clone() }, e).len(), 3);

        // relative values are skipped; a relative JUPYTER_RUNTIME_DIR falls
        // back to JUPYTER_DATA_DIR/runtime
        let rel = EnvView {
            override_dir: Some(p("rel/custom")),
            xdg_runtime_dir: Some(p("run")),
            jupyter_runtime_dir: Some(p("j/rt")),
            ..full.clone()
        };
        let rel = EnvView { temp_dir: None, ..rel };
        assert_eq!(candidates(&rel, e), vec![(Source::JupyterRuntime, p("/j/data/runtime/jupynvim"))]);

        // no Jupyter env: the platform default
        let plat = EnvView {
            home: Some(p("/h")),
            xdg_data_home: Some(p("/x/data")),
            ..Default::default()
        };
        let want = if cfg!(target_os = "macos") {
            p("/h/Library/Jupyter/runtime/jupynvim")
        } else {
            p("/x/data/jupyter/runtime/jupynvim")
        };
        assert_eq!(candidates(&plat, e), vec![(Source::JupyterRuntime, want)]);

        // a relative XDG_DATA_HOME and a relative JUPYTER_DATA_DIR are skipped too
        let plat2 = EnvView {
            home: Some(p("/h")),
            xdg_data_home: Some(p("data")),
            jupyter_data_dir: Some(p("jd")),
            ..Default::default()
        };
        let want2 = if cfg!(target_os = "macos") {
            p("/h/Library/Jupyter/runtime/jupynvim")
        } else {
            p("/h/.local/share/jupyter/runtime/jupynvim")
        };
        assert_eq!(candidates(&plat2, e), vec![(Source::JupyterRuntime, want2)]);

        // a relative home gives no Jupyter candidate; nothing at all gives none
        let relhome = EnvView { home: Some(p("h")), ..Default::default() };
        assert!(candidates(&relhome, e).is_empty());
        assert!(candidates(&EnvView::default(), e).is_empty());

        assert_eq!(Source::Override.label(), "JUPYNVIM_RUNTIME_DIR");
        assert_eq!(Source::XdgRuntime.label(), "XDG_RUNTIME_DIR");
        assert_eq!(Source::JupyterRuntime.label(), "Jupyter runtime dir");
        assert_eq!(Source::Temp.label(), "system temp dir");
        assert!(Source::XdgRuntime.local());
        assert!(!Source::Override.local());
        assert!(!Source::JupyterRuntime.local());
        // the system temp dir can be shared by hosts (a TMPDIR on shared
        // storage): another host's dirs go only by the shared-root rules
        assert!(!Source::Temp.local());

        // a dir others can write to that passes only thanks to its sticky
        // bit gets the user's own name; a private one, sticky or not (Jupyter
        // sets the sticky bit on its runtime dir), and a missing one, jupynvim
        for (mode, shared) in [
            (0o41777, true),
            (0o41770, true),
            (0o41707, true),
            (0o41755, false),
            (0o41702, true),
            (0o41700, false),
            (0o40777, false),
            (0o40755, false),
            (0o40700, false),
        ] {
            assert_eq!(shared_sticky(mode), shared, "{mode:o}");
        }
        let t = TestDir::new("u1");
        let me = euid();
        mkdir_mode(&t.join("shared"), 0o1777);
        mkdir_mode(&t.join("jrt"), 0o1700);
        mkdir_mode(&t.join("plain"), 0o755);
        symlink(t.join("shared"), t.join("slink")).unwrap();
        let mine = format!("jupynvim-{me}");
        let env = EnvView {
            override_dir: Some(t.join("shared")),
            xdg_runtime_dir: Some(t.join("shared")),
            jupyter_runtime_dir: Some(t.join("jrt")),
            temp_dir: Some(t.join("plain")),
            ..Default::default()
        };
        assert_eq!(
            candidates(&env, me),
            vec![
                (Source::Override, t.join("shared").join(&mine)),
                // XDG_RUNTIME_DIR must be private to be used at all
                (Source::XdgRuntime, t.join("shared/jupynvim")),
                (Source::JupyterRuntime, t.join("jrt/jupynvim")),
                (Source::Temp, t.join("plain").join(&mine)),
            ]
        );
        // the dir a symlink points to decides; the root stays under the link
        let env = EnvView { override_dir: Some(t.join("slink")), jupyter_runtime_dir: Some(t.join("shared")), ..Default::default() };
        assert_eq!(
            candidates(&env, me),
            vec![(Source::Override, t.join("slink").join(&mine)), (Source::JupyterRuntime, t.join("shared").join(&mine))]
        );
    }

    // U2
    #[test]
    fn u2_private_dir_verdict_table() {
        let me = 501;
        let other = 502;
        let reject = |v: Verdict, want: &str| match v {
            Verdict::Reject(why) => assert!(why.contains(want), "{why:?} lacks {want:?}"),
            v => panic!("{v:?} is not a Reject ({want})"),
        };
        reject(private_dir_verdict(true, false, me, 0o120777, me), "symbolic link");
        reject(private_dir_verdict(false, false, me, 0o100600, me), "not a directory");
        reject(private_dir_verdict(false, true, other, 0o40700, me), "owned by uid 502");
        assert_eq!(private_dir_verdict(false, true, me, 0o40700, me), Verdict::Ok);
        assert_eq!(private_dir_verdict(false, true, me, 0o41700, me), Verdict::Ok);
        assert_eq!(private_dir_verdict(false, true, me, 0o40500, me), Verdict::Ok);
        assert_eq!(private_dir_verdict(false, true, me, 0o40755, me), Verdict::Repair);
        assert_eq!(private_dir_verdict(false, true, me, 0o40750, me), Verdict::Repair);
        assert_eq!(private_dir_verdict(false, true, me, 0o40701, me), Verdict::Repair);
    }

    // U3
    #[test]
    fn u3_prepare_root() {
        let t = TestDir::new("u3");
        let e = euid();

        // Override with missing parents: each made 0700
        let r = t.join("a/b/c");
        prepare_root(Source::Override, &r, e).unwrap();
        for d in ["a", "a/b", "a/b/c"] {
            assert_eq!(mode(&t.join(d)), 0o700, "{d}");
        }

        // the Jupyter root with its runtime dir missing
        let jr = t.join("jrt/jupynvim");
        prepare_root(Source::JupyterRuntime, &jr, e).unwrap();
        assert_eq!(mode(&t.join("jrt")), 0o700);
        assert_eq!(mode(&jr), 0o700);

        // an existing 0755 root of ours becomes 0700
        let open = t.join("open");
        mkdir_mode(&open, 0o755);
        prepare_root(Source::Override, &open, e).unwrap();
        assert_eq!(mode(&open), 0o700);
        let jopen = t.join("jopen/jupynvim");
        mkdir_mode(&jopen, 0o750);
        prepare_root(Source::JupyterRuntime, &jopen, e).unwrap();
        assert_eq!(mode(&jopen), 0o700);

        // a symlink root is refused and its target left alone
        let target = t.join("target");
        mkdir_mode(&target, 0o755);
        let link = t.join("link");
        symlink(&target, &link).unwrap();
        let err = prepare_root(Source::Override, &link, e).unwrap_err().to_string();
        assert!(err.contains("symbolic link"), "{err}");
        assert_eq!(mode(&target), 0o755);
        assert_eq!(fs::read_dir(&target).unwrap().count(), 0);

        // a regular file as the root is refused
        let file = t.join("file");
        fs::write(&file, b"x").unwrap();
        let err = prepare_root(Source::Override, &file, e).unwrap_err().to_string();
        assert!(err.contains("not a directory"), "{err}");

        // XDG: the XDG dir itself must be private; never changed, R not made
        let xdg_open = t.join("xdg-open");
        mkdir_mode(&xdg_open, 0o755);
        let err = prepare_root(Source::XdgRuntime, &xdg_open.join("jupynvim"), e)
            .unwrap_err()
            .to_string();
        assert!(err.contains("755"), "{err}");
        assert_eq!(mode(&xdg_open), 0o755);
        assert!(!xdg_open.join("jupynvim").exists());

        let xdg_missing = t.join("xdg-missing");
        let err = prepare_root(Source::XdgRuntime, &xdg_missing.join("jupynvim"), e)
            .unwrap_err()
            .to_string();
        assert!(err.contains("does not exist"), "{err}");
        assert!(!xdg_missing.exists());

        let xdg_link = t.join("xdg-link");
        symlink(&target, &xdg_link).unwrap();
        assert!(prepare_root(Source::XdgRuntime, &xdg_link.join("jupynvim"), e).is_err());
        assert!(!target.join("jupynvim").exists());

        // XDG 0700: R made 0700; an R of ours with extra bits is repaired
        let xdg = t.join("xdg");
        mkdir_mode(&xdg, 0o700);
        prepare_root(Source::XdgRuntime, &xdg.join("jupynvim"), e).unwrap();
        assert_eq!(mode(&xdg.join("jupynvim")), 0o700);
        set_mode(&xdg.join("jupynvim"), 0o711);
        prepare_root(Source::XdgRuntime, &xdg.join("jupynvim"), e).unwrap();
        assert_eq!(mode(&xdg.join("jupynvim")), 0o700);
        assert_eq!(mode(&xdg), 0o700);

        // verify_root never creates and never repairs
        assert!(verify_root(Source::XdgRuntime, &xdg.join("jupynvim"), e));
        assert!(!verify_root(Source::XdgRuntime, &xdg_open.join("jupynvim"), e));
        assert!(!verify_root(Source::Override, &t.join("nothing"), e));
        assert!(!t.join("nothing").exists());
        let loose = t.join("loose");
        mkdir_mode(&loose, 0o755);
        assert!(!verify_root(Source::JupyterRuntime, &loose, e));
        assert_eq!(mode(&loose), 0o755);
        assert!(!verify_root(Source::Override, &link, e));
        assert!(verify_root(Source::Override, &r, e));

        // an XDG dir open to others rules out its jupynvim even when that
        // is a private dir of ours
        let xdg_open_r = xdg_open.join("jupynvim");
        mkdir_mode(&xdg_open_r, 0o700);
        assert!(verify_root(Source::Override, &xdg_open_r, e));
        assert!(!verify_root(Source::XdgRuntime, &xdg_open_r, e));
        assert_eq!(mode(&xdg_open), 0o755);

        // a root of ours with group or other bits and without the owner's
        // read bit is repaired too
        for m in [0o355, 0o311, 0o055] {
            let noread = t.join(&format!("noread-{m:o}"));
            mkdir_mode(&noread, m);
            prepare_root(Source::Override, &noread, e).unwrap();
            assert_eq!(mode(&noread), 0o700, "{m:o}");
        }
    }

    // U4
    #[test]
    fn u4_choose_root_falls_through_and_names_every_candidate() {
        let t = TestDir::new("u4");
        let e = euid();

        let xdg_open = t.join("xdg");
        mkdir_mode(&xdg_open, 0o755);
        let env = EnvView {
            xdg_runtime_dir: Some(xdg_open.clone()),
            jupyter_runtime_dir: Some(t.join("jrt")),
            ..Default::default()
        };
        let (src, root) = choose_root(&env, e).unwrap();
        assert_eq!(src, Source::JupyterRuntime);
        assert_eq!(root, t.join("jrt/jupynvim"));
        assert_eq!(mode(&root), 0o700);
        assert!(!xdg_open.join("jupynvim").exists());

        // the override wins when it works; its root is jupynvim in it, made
        // with its missing parents
        let env_o = EnvView { override_dir: Some(t.join("custom")), ..env.clone() };
        assert_eq!(choose_root(&env_o, e).unwrap(), (Source::Override, t.join("custom/jupynvim")));
        assert_eq!((mode(&t.join("custom")), mode(&t.join("custom/jupynvim"))), (0o700, 0o700));

        // an existing override dir open to its group (setgid, as a group's
        // shared dir often is) is refused: its group could put another dir
        // in place of the root. The next candidate is used, and the dir is
        // left as it is, with nothing made in it
        let shared = t.join("shared");
        mkdir_mode(&shared, 0o2775);
        let shared_mode = mode(&shared);
        assert_ne!(shared_mode & 0o020, 0, "the test dir did not get the group write bit");
        let env_s = EnvView { override_dir: Some(shared.clone()), ..env.clone() };
        assert_eq!(choose_root(&env_s, e).unwrap(), (Source::JupyterRuntime, t.join("jrt/jupynvim")));
        assert_eq!(mode(&shared), shared_mode, "the dir given as JUPYNVIM_RUNTIME_DIR was changed");
        assert!(!shared.join("jupynvim").exists(), "a root was made in a dir open to its group");

        // an override that is a symlink to a dir works: the root is made in
        // the dir it points to, which is left as it is
        let real = t.join("real");
        mkdir_mode(&real, 0o755);
        symlink(&real, t.join("rlink")).unwrap();
        let env_l = EnvView { override_dir: Some(t.join("rlink")), ..env.clone() };
        assert_eq!(choose_root(&env_l, e).unwrap(), (Source::Override, t.join("rlink/jupynvim")));
        assert_eq!((mode(&real), mode(&real.join("jupynvim"))), (0o755, 0o700));

        // every candidate refused
        let elsewhere = t.join("elsewhere");
        mkdir_mode(&elsewhere, 0o700);
        mkdir_mode(&t.join("obad"), 0o700);
        symlink(&elsewhere, t.join("obad/jupynvim")).unwrap();
        mkdir_mode(&t.join("jbad"), 0o700);
        symlink(&elsewhere, t.join("jbad/jupynvim")).unwrap();
        let bad = EnvView {
            override_dir: Some(t.join("obad")),
            xdg_runtime_dir: Some(t.join("missing")),
            jupyter_runtime_dir: Some(t.join("jbad")),
            ..Default::default()
        };
        let err = format!("{:#}", choose_root(&bad, e).unwrap_err());
        assert!(err.starts_with("no private runtime directory for kernel connection files (tried: "), "{err}");
        assert!(err.ends_with("; set JUPYNVIM_RUNTIME_DIR to a directory only you can write to"), "{err}");
        for want in [
            format!("JUPYNVIM_RUNTIME_DIR {}", t.join("obad/jupynvim").display()),
            format!("XDG_RUNTIME_DIR {}", t.join("missing/jupynvim").display()),
            format!("Jupyter runtime dir {}", t.join("jbad/jupynvim").display()),
        ] {
            assert!(err.contains(&want), "{err} lacks {want}");
        }
        assert_eq!(fs::read_dir(&elsewhere).unwrap().count(), 0);

        // no candidate at all is an error too
        assert!(choose_root(&EnvView::default(), e).is_err());
    }

    // U5
    #[test]
    fn u5_exact_modes_and_create_new() {
        let t = TestDir::new("u5");
        let d = t.join("priv");
        mkdir_private(&d).unwrap();
        assert!(d.is_dir());
        assert_eq!(mode(&d), 0o700);
        assert_eq!(mkdir_private(&d).unwrap_err().kind(), std::io::ErrorKind::AlreadyExists);

        let f = d.join("file");
        drop(create_private_file(&f).unwrap());
        assert_eq!(mode(&f), 0o600);
        fs::write(&f, b"first").unwrap();
        assert_eq!(create_private_file(&f).unwrap_err().kind(), std::io::ErrorKind::AlreadyExists);
        assert_eq!(fs::read(&f).unwrap(), b"first");

        // a dangling symlink is refused and nothing is made at its target
        let nowhere = t.join("nowhere");
        symlink(&nowhere, d.join("dangling")).unwrap();
        assert_eq!(
            create_private_file(&d.join("dangling")).unwrap_err().kind(),
            std::io::ErrorKind::AlreadyExists
        );
        assert!(!nowhere.exists());

        // a symlink to an existing file is refused and the file left alone
        symlink(&f, d.join("tofile")).unwrap();
        assert!(create_private_file(&d.join("tofile")).is_err());
        assert_eq!(fs::read(&f).unwrap(), b"first");
        assert_eq!(mode(&f), 0o600);
    }

    // U6
    #[test]
    fn u6_dir_names_and_host_token() {
        let name = backend_dir_name("feedbeef0001", 42, "0123456789ab");
        assert_eq!(name, "core-feedbeef0001-42-0123456789ab");
        assert_eq!(parse_backend_dir_name(&name), Some(("feedbeef0001".to_string(), 42)));
        let dashed = backend_dir_name("my-host-01.local", 7, "abcdef012345");
        assert_eq!(parse_backend_dir_name(&dashed), Some(("my-host-01.local".to_string(), 7)));
        for bad in [
            "core-x-1-0123456789a",
            "core-x-1-0123456789abc",
            "core-x-1-0123456789aB",
            "core--1-0123456789ab",
            "core-x--0123456789ab",
            "core-x-1a-0123456789ab",
            "core-x-99999999999-0123456789ab",
            "core-x y-1-0123456789ab",
            "core-1-0123456789ab",
            "kernel-x-1-0123456789ab",
            "core-",
            "notes.txt",
        ] {
            assert_eq!(parse_backend_dir_name(bad), None, "{bad}");
        }

        assert_eq!(sanitize_host("My Mac.local", 32), "My_Mac.local");
        assert_eq!(sanitize_host("h\u{e9}llo/w\u{f6}rld", 32), "h_llo_w_rld");
        assert_eq!(sanitize_host("node-01.cluster_x", 32), "node-01.cluster_x");
        assert_eq!(sanitize_host("", 32), "localhost");
        assert_eq!(sanitize_host(&"a".repeat(40), 32), "a".repeat(32));

        let tok = host_token();
        assert!(!tok.is_empty() && tok.len() <= 32, "{tok}");
        assert_eq!(tok, host_token());
        let n = backend_dir_name(&tok, 1, "0123456789ab");
        assert_eq!(parse_backend_dir_name(&n), Some((tok.clone(), 1)));
        // on Linux with a machine id, this host's token is made from it and
        // the short hostname
        #[cfg(target_os = "linux")]
        if let Some(head) = fs::read_to_string("/etc/machine-id")
            .ok()
            .and_then(|s| s.trim().get(..8).filter(|h| h.bytes().all(|b| b.is_ascii_hexdigit())).map(str::to_ascii_lowercase))
        {
            let host = hostname();
            let short = sanitize_host(host.split('.').next().unwrap_or_default(), 23);
            assert_eq!(tok, format!("{head}-{short}"), "hostname {host:?}");
        }

        // Linux: the machine id's start and the short hostname, so nodes
        // made from one image (one machine id) still differ
        let mid = "0123456789abcdef0123456789abcdef\n";
        let a = machine_host_token(mid, "node01.cluster.example").unwrap();
        assert_eq!(a, "01234567-node01");
        let b = machine_host_token(mid, "node02.cluster.example").unwrap();
        assert_ne!(a, b);
        assert_eq!(machine_host_token("0123456789ABCDEF", "n1").unwrap(), "01234567-n1");
        assert_eq!(machine_host_token("01234567", "").unwrap(), "01234567-localhost");
        assert_eq!(machine_host_token(mid, ".hidden").unwrap(), "01234567-localhost");
        assert_eq!(machine_host_token(mid, "my host/x.y").unwrap(), "01234567-my_host_x");
        let long = machine_host_token(mid, &"h".repeat(60)).unwrap();
        assert_eq!(long, format!("01234567-{}", "h".repeat(23)));
        assert_eq!(long.len(), 32);
        for bad in ["", "0123456", "0123456g89abcdef", "uninitialized\n"] {
            assert_eq!(machine_host_token(bad, "n1"), None, "{bad:?}");
        }
        for t in [&a, &long] {
            let n = backend_dir_name(t, 5, "0123456789ab");
            assert_eq!(parse_backend_dir_name(&n), Some((t.to_string(), 5)));
        }
    }

    // U7
    #[test]
    fn u7_backend_dir_create_and_remove() {
        let t = TestDir::new("u7");
        let b = BackendDir::create(t.path(), "tok").unwrap();
        assert_eq!(b.path().parent(), Some(t.path()));
        let name = b.path().file_name().unwrap().to_str().unwrap().to_string();
        assert_eq!(parse_backend_dir_name(&name), Some(("tok".to_string(), std::process::id())));
        assert_eq!(mode(b.path()), 0o700);
        let lock = b.path().join("lock");
        assert_eq!(mode(&lock), 0o600);
        match File::open(&lock).unwrap().try_lock() {
            Err(std::fs::TryLockError::WouldBlock) => {}
            other => panic!("the lock of a live backend dir could be taken: {other:?}"),
        }

        let b2 = BackendDir::create(t.path(), "tok").unwrap();
        assert_ne!(b.path(), b2.path());

        let p = b.path().to_path_buf();
        b.remove();
        assert!(!p.exists());
        b.remove();
        assert!(b2.path().exists());
        b2.remove();
        assert!(t.path().is_dir());
        assert_eq!(fs::read_dir(t.path()).unwrap().count(), 0);
    }

    // U7b: a new dir whose lock is lost before it is locked is given up and
    // another name is made (D9)
    #[test]
    fn u7b_backend_dir_create_retries_when_its_lock_is_lost() {
        use std::cell::RefCell;
        use std::rc::Rc;
        let t = TestDir::new("u7b");

        // what the hook does to the first dir only; the dirs it saw
        let run = |what: fn(&Path, &mut Vec<File>)| -> (BackendDir, Vec<PathBuf>, Vec<File>) {
            let seen: Rc<RefCell<Vec<PathBuf>>> = Rc::default();
            let held: Rc<RefCell<Vec<File>>> = Rc::default();
            let (s, h) = (seen.clone(), held.clone());
            set_before_lock(Some(Box::new(move |dir: &Path| {
                if s.borrow().is_empty() {
                    what(dir, &mut h.borrow_mut());
                }
                s.borrow_mut().push(dir.to_path_buf());
            })));
            let b = BackendDir::create(t.path(), "tok");
            set_before_lock(None);
            let seen = seen.borrow().clone();
            let held = std::mem::take(&mut *held.borrow_mut());
            (b.unwrap(), seen, held)
        };
        let assert_live = |b: &BackendDir| {
            assert!(b.path().join("lock").exists());
            assert!(matches!(
                File::open(b.path().join("lock")).unwrap().try_lock(),
                Err(std::fs::TryLockError::WouldBlock)
            ));
        };

        // a remover stopped after unlinking the lock file: the dir is still
        // there but its lock file is gone (nlink 0 for our handle)
        let (b, seen, _) = run(|dir, _| fs::remove_file(dir.join("lock")).unwrap());
        assert_eq!(seen.len(), 2, "{seen:?}");
        assert_ne!(b.path(), seen[0].as_path());
        assert_eq!(b.path(), seen[1].as_path());
        assert!(seen[0].is_dir() && !seen[0].join("lock").exists());
        assert_live(&b);
        b.remove();
        fs::remove_dir(&seen[0]).unwrap();

        // a sweep holds the new dir's lock
        let (b, seen, held) = run(|dir, held| {
            let f = File::open(dir.join("lock")).unwrap();
            f.try_lock().unwrap();
            held.push(f);
        });
        assert_eq!(seen.len(), 2, "{seen:?}");
        assert_eq!(b.path(), seen[1].as_path());
        assert_live(&b);
        assert!(remove_backend_dir_locked(&seen[0], held.into_iter().next()));
        b.remove();

        // a sweep removed the new dir altogether
        let (b, seen, _) = run(|dir, _| assert!(remove_backend_dir_locked(dir, None)));
        assert_eq!(seen.len(), 2, "{seen:?}");
        assert!(!seen[0].exists());
        assert_eq!(b.path(), seen[1].as_path());
        assert_live(&b);
        b.remove();

        // a remover on NFS unlinked the lock file while it had it open: the
        // client renames the file to a hidden name, so our handle still
        // counts a link but the name lock is gone
        let (b, seen, _) = run(|dir, _| fs::rename(dir.join("lock"), dir.join(".nfs000000000000000a00000001")).unwrap());
        assert_eq!(seen.len(), 2, "{seen:?}");
        assert_eq!(b.path(), seen[1].as_path());
        assert_live(&b);
        b.remove();
        fs::remove_dir_all(&seen[0]).unwrap();

        // the same, and then another remover claimed the dir with a lock file
        // of its own: a regular file is named lock again, but it is not ours
        let (b, seen, held) = run(|dir, held| {
            fs::rename(dir.join("lock"), dir.join(".nfs000000000000000c00000001")).unwrap();
            let f = create_private_file(&dir.join("lock")).unwrap();
            f.try_lock().unwrap();
            held.push(f);
        });
        assert_eq!(seen.len(), 2, "a dir whose lock file is another one's was used: {seen:?}");
        assert_eq!(b.path(), seen[1].as_path());
        assert_live(&b);
        b.remove();
        drop(held);
        fs::remove_dir_all(&seen[0]).unwrap();

        // every try loses its lock: an error naming the root, not a dir
        // without a lock
        set_before_lock(Some(Box::new(|dir: &Path| fs::remove_file(dir.join("lock")).unwrap())));
        let err = BackendDir::create(t.path(), "tok").err().expect("create gave up");
        set_before_lock(None);
        let msg = format!("{err:#}");
        assert!(msg.contains("after 5 tries") && msg.contains(&t.path().display().to_string()), "{msg}");
        for e in fs::read_dir(t.path()).unwrap() {
            let p = e.unwrap().path();
            assert!(!p.join("lock").exists(), "{}", p.display());
            fs::remove_dir(&p).unwrap();
        }
    }

    fn plant(root: &Path, name: &str, lock: bool, kernel: bool) -> PathBuf {
        let d = root.join(name);
        mkdir_mode(&d, 0o700);
        if lock {
            fs::write(d.join("lock"), b"").unwrap();
        }
        if kernel {
            let k = d.join(format!("kernel-{}", "0".repeat(32)));
            mkdir_mode(&k, 0o700);
            fs::write(k.join("connection.json"), b"{}").unwrap();
        }
        d
    }

    // U8
    #[test]
    fn u8_sweep_stale() {
        let t = TestDir::new("u8");
        let root = t.join("root");
        mkdir_mode(&root, 0o700);
        let now = SystemTime::now();
        let old = now - Duration::from_secs(120);

        let free = plant(&root, "core-tok-1-aaaaaaaaaaaa", true, true);
        // a symlink inside a dead dir is unlinked, its target left alone
        let outside = plant(t.path(), "outside", true, true);
        symlink(&outside, free.join("kernel-link")).unwrap();
        let held = plant(&root, "core-tok-2-bbbbbbbbbbbb", true, false);
        let holder = File::open(held.join("lock")).unwrap();
        holder.try_lock().unwrap();
        let old_nolock = plant(&root, "core-tok-3-cccccccccccc", false, true);
        set_mtime(&old_nolock, old);
        // no lock file and younger than 60 s: 30 s, and just under 60 s
        let young_nolock = plant(&root, "core-tok-4-dddddddddddd", false, true);
        set_mtime(&young_nolock, now - Duration::from_secs(30));
        let young59_nolock = plant(&root, "core-tok-8-dddddddddddd", false, true);
        set_mtime(&young59_nolock, now - Duration::from_secs(59));
        let foreign = plant(&root, "core-other-5-eeeeeeeeeeee", true, true);
        let live = BackendDir::create(&root, "tok").unwrap();
        let notes = root.join("notes.txt");
        fs::write(&notes, b"notes").unwrap();
        let odd = plant(&root, "core-odd", true, false);
        let kdir = plant(&root, "kernel-x", true, false);
        let elsewhere = plant(t.path(), "elsewhere", true, true);
        let link = root.join("core-tok-6-ffffffffffff");
        symlink(&elsewhere, &link).unwrap();
        let file_named = root.join("core-tok-7-aaaaaaaaaaaa");
        fs::write(&file_named, b"x").unwrap();
        set_mtime(&file_named, old);

        assert_eq!(sweep_stale(&root, false, "tok", now), 2);
        assert!(!free.exists() && !old_nolock.exists());
        assert!(outside.join("lock").exists());
        assert!(outside.join(format!("kernel-{}/connection.json", "0".repeat(32))).exists());
        assert!(held.join("lock").exists());
        assert!(young_nolock.exists() && young59_nolock.exists() && foreign.join("lock").exists());
        assert!(live.path().join("lock").exists());
        assert!(notes.exists() && odd.join("lock").exists() && kdir.join("lock").exists());
        assert!(fs::symlink_metadata(&link).unwrap().file_type().is_symlink());
        assert!(elsewhere.join("lock").exists());
        assert!(elsewhere.join(format!("kernel-{}/connection.json", "0".repeat(32))).exists());
        assert!(file_named.exists());

        // in a local root every host's dead dirs go
        assert_eq!(sweep_stale(&root, true, "tok", now), 1);
        assert!(!foreign.exists());
        assert!(held.exists() && young_nolock.exists() && young59_nolock.exists() && live.path().exists());

        // a released lock makes the dir dead
        drop(holder);
        assert!(wait_lock_free(&held.join("lock")));
        assert_eq!(sweep_stale(&root, false, "tok", now), 1);
        assert!(!held.exists());

        // the young dirs with no lock go once they are old enough
        assert_eq!(sweep_stale(&root, false, "tok", now + Duration::from_secs(120)), 2);
        assert!(!young_nolock.exists() && !young59_nolock.exists());
        assert!(live.path().join("lock").exists());

        live.remove();
        assert_eq!(sweep_stale(&root, true, "tok", now), 0);
        assert!(notes.exists() && odd.exists() && kdir.exists() && file_named.exists());
    }

    // U9
    #[test]
    fn u9_sweep_legacy() {
        let t = TestDir::new("u9");
        let e = euid();
        let legacy = t.join("jupynvim");
        mkdir_mode(&legacy, 0o755);
        let now = SystemTime::now();
        let old = now - Duration::from_secs(120);
        let min = Duration::from_secs(60);
        let id = || uuid::Uuid::new_v4().to_string();

        let old_file = legacy.join(format!("kernel-{}.json", id()));
        fs::write(&old_file, b"{}").unwrap();
        set_mtime(&old_file, old);
        let young = legacy.join(format!("kernel-{}.json", id()));
        fs::write(&young, b"{}").unwrap();
        let mut kept = vec![young.clone()];
        for name in [
            "kernel-xyz.json".to_string(),
            "notes.txt".to_string(),
            format!("kernel-{}.json", id().to_uppercase()),
            format!("kernel-{}.json.bak", id()),
            format!("kernel-{}", id()),
        ] {
            let p = legacy.join(name);
            fs::write(&p, b"{}").unwrap();
            set_mtime(&p, old);
            kept.push(p);
        }
        let as_dir = legacy.join(format!("kernel-{}.json", id()));
        mkdir_mode(&as_dir, 0o755);
        set_mtime(&as_dir, old);
        kept.push(as_dir);
        let target = t.join("target.json");
        fs::write(&target, b"{}").unwrap();
        set_mtime(&target, old);
        let as_link = legacy.join(format!("kernel-{}.json", id()));
        symlink(&target, &as_link).unwrap();

        assert_eq!(sweep_legacy(&legacy, now, min, e, &[], false), (1, false));
        assert!(!old_file.exists());
        for p in &kept {
            assert!(p.exists(), "{}", p.display());
        }
        assert!(fs::symlink_metadata(&as_link).is_ok() && target.exists());

        // a longer minimum age keeps an old file
        let old2 = legacy.join(format!("kernel-{}.json", id()));
        fs::write(&old2, b"{}").unwrap();
        set_mtime(&old2, old);
        assert_eq!(sweep_legacy(&legacy, now, Duration::from_secs(600), e, &[], false), (0, false));
        assert!(old2.exists());

        // only when the dir is empty after the sweep is it removed
        for p in &kept {
            let _ = fs::remove_file(p);
            let _ = fs::remove_dir(p);
        }
        fs::remove_file(&as_link).unwrap();
        assert_eq!(sweep_legacy(&legacy, now, min, e, &[], false), (1, true));
        assert!(!legacy.exists());
        assert_eq!(sweep_legacy(&legacy, now, min, e, &[], false), (0, false));

        // a symlinked old dir is not read
        let real = t.join("real");
        mkdir_mode(&real, 0o755);
        let inside = real.join(format!("kernel-{}.json", id()));
        fs::write(&inside, b"{}").unwrap();
        set_mtime(&inside, old);
        symlink(&real, &legacy).unwrap();
        assert_eq!(sweep_legacy(&legacy, now, min, e, &[], false), (0, false));
        assert!(inside.exists());

        assert!(legacy_dir().ends_with("jupynvim"));
        assert!(legacy_dir().starts_with(std::env::temp_dir()));

        // a root given in keep (the old location used as a root) is kept
        // even when empty
        fs::remove_file(&legacy).unwrap();
        mkdir_mode(&legacy, 0o700);
        let m = fs::symlink_metadata(&legacy).unwrap();
        assert_eq!(sweep_legacy(&legacy, now, min, e, &[(m.dev(), m.ino())], false), (0, false));
        assert!(legacy.is_dir());
        assert_eq!(sweep_legacy(&legacy, now, min, e, &[], false), (0, true));
    }

    // U19: the old dir is read only when it is the user's own, and through
    // one handle: a dir swapped for a symlink between the check and the
    // listing is not followed, so files named like connection files in the
    // symlink's target stay
    #[test]
    fn u19_sweep_legacy_reads_only_the_dir_it_checked() {
        let t = TestDir::new("u19");
        let e = euid();
        let now = SystemTime::now();
        let old = now - Duration::from_secs(120);
        let min = Duration::from_secs(60);
        let id = || uuid::Uuid::new_v4().to_string();
        let tmp = t.join("tmp");
        mkdir_mode(&tmp, 0o700);
        let legacy = tmp.join("jupynvim");

        // the target of the swapped-in symlink: a dir with an old file named
        // like a connection file (as Jupyter's own runtime dir has)
        let victim = t.join("victim");
        mkdir_mode(&victim, 0o700);
        let theirs = victim.join(format!("kernel-{}.json", id()));
        fs::write(&theirs, b"{}").unwrap();
        set_mtime(&theirs, old);

        // the old dir, with an old file of ours, is swapped for a symlink to
        // victim right after it was checked
        mkdir_mode(&legacy, 0o700);
        let ours = legacy.join(format!("kernel-{}.json", id()));
        fs::write(&ours, b"{}").unwrap();
        set_mtime(&ours, old);
        let moved = tmp.join("moved");
        let (l, v, mv) = (legacy.clone(), victim.clone(), moved.clone());
        let swaps = std::rc::Rc::new(std::cell::Cell::new(0));
        let seen = swaps.clone();
        set_hook(Some(Box::new(move |point, _| {
            if point == Point::LegacyOpened {
                fs::rename(&l, &mv).unwrap();
                symlink(&v, &l).unwrap();
                seen.set(seen.get() + 1);
            }
        })));
        let got = sweep_legacy(&legacy, now, min, e, &[], false);
        set_hook(None);
        assert_eq!(swaps.get(), 1, "the hook did not run");
        assert!(theirs.exists(), "a file in the swapped-in symlink's target was removed");
        assert!(fs::symlink_metadata(&legacy).unwrap().file_type().is_symlink() && victim.is_dir());
        // what was checked is what was swept: the dir moved aside lost its
        // old file and was not removed (another entry has its name now)
        assert_eq!(got, (1, false));
        assert!(!moved.join(ours.file_name().unwrap()).exists() && moved.is_dir());

        // a dir of another user is not read at all (here: the euid given
        // does not own it)
        fs::remove_file(&legacy).unwrap();
        mkdir_mode(&legacy, 0o755);
        let f = legacy.join(format!("kernel-{}.json", id()));
        fs::write(&f, b"{}").unwrap();
        set_mtime(&f, old);
        let read = std::rc::Rc::new(std::cell::Cell::new(false));
        let r = read.clone();
        set_hook(Some(Box::new(move |point, _| {
            if point == Point::LegacyOpened {
                r.set(true);
            }
        })));
        let got = sweep_legacy(&legacy, now, min, e.wrapping_add(1), &[], false);
        set_hook(None);
        assert!(!read.get(), "the dir of another user was read");
        assert_eq!(got, (0, false));
        assert!(f.exists() && legacy.is_dir());
    }

    // U10
    #[test]
    fn u10_kernel_dir_and_connection_file() {
        let t = TestDir::new("u10");
        let b = BackendDir::create(t.path(), "tok").unwrap();
        let k = b.new_kernel_dir().unwrap();
        assert_eq!(k.path().parent(), Some(b.path()));
        let kname = k.path().file_name().unwrap().to_str().unwrap().to_string();
        let hex = kname.strip_prefix("kernel-").unwrap();
        assert!(hex.len() == 32 && hex.bytes().all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase()), "{kname}");
        assert_eq!(mode(k.path()), 0o700);
        assert_eq!(k.conn_path(), k.path().join("connection.json"));

        let key = uuid::Uuid::new_v4().to_string();
        let ours = conn(&key);
        k.write_connection(&ours).unwrap();
        let path = k.conn_path();
        assert_eq!(mode(&path), 0o600);
        let v: serde_json::Value = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
        let keys: Vec<&str> = v.as_object().unwrap().keys().map(|s| s.as_str()).collect();
        assert_eq!(
            keys,
            [
                "ip",
                "transport",
                "shell_port",
                "iopub_port",
                "stdin_port",
                "control_port",
                "hb_port",
                "key",
                "signature_scheme",
                "kernel_name"
            ]
        );
        for p in ["shell_port", "iopub_port", "stdin_port", "control_port", "hb_port"] {
            assert_eq!(v[p], 0, "{p}");
        }
        assert_eq!(v["key"], key.as_str());
        assert_eq!(v["kernel_name"], "python3");
        assert!(k.write_connection(&ours).is_err(), "an existing connection file was overwritten");
        assert!(k.read_written_back(&ours).unwrap().is_none());

        // the kernel writes its bound ports back: unlink, recreate, one write
        let write_back = |obj: serde_json::Value| {
            let _ = fs::remove_file(&path);
            fs::write(&path, serde_json::to_vec_pretty(&obj).unwrap()).unwrap();
        };
        let mut back = v.clone();
        for (i, p) in ["shell_port", "iopub_port", "stdin_port", "control_port", "hb_port"]
            .iter()
            .enumerate()
        {
            back[*p] = serde_json::json!(5001 + i);
        }
        back["jupyter_session"] = serde_json::json!("extra keys are fine");
        write_back(back.clone());
        let got = k.read_written_back(&ours).unwrap().expect("ports written back");
        assert_eq!(ports_of(&got), [5001, 5002, 5003, 5004, 5005]);
        assert_eq!(got.key, key);
        assert_eq!(got.kernel_name, "python3");

        // a write in progress, a missing file, a missing or zero port: not yet
        let full = serde_json::to_vec_pretty(&back).unwrap();
        fs::write(&path, &full[..full.len() / 2]).unwrap();
        assert!(k.read_written_back(&ours).unwrap().is_none());
        fs::remove_file(&path).unwrap();
        assert!(k.read_written_back(&ours).unwrap().is_none());
        let mut missing = back.clone();
        missing.as_object_mut().unwrap().remove("hb_port");
        write_back(missing);
        assert!(k.read_written_back(&ours).unwrap().is_none());
        let mut zero = back.clone();
        zero["control_port"] = serde_json::json!(0);
        write_back(zero);
        assert!(k.read_written_back(&ours).unwrap().is_none());

        // a different key, ip, transport or scheme, or a port out of range: an error
        for (field, val) in [
            ("key", serde_json::json!(uuid::Uuid::new_v4().to_string())),
            ("ip", serde_json::json!("0.0.0.0")),
            ("transport", serde_json::json!("ipc")),
            ("signature_scheme", serde_json::json!("hmac-sha1")),
            ("shell_port", serde_json::json!(70000)),
            ("iopub_port", serde_json::json!(-1)),
        ] {
            let mut changed = back.clone();
            changed[field] = val;
            write_back(changed);
            let err = k.read_written_back(&ours).unwrap_err().to_string();
            assert!(!err.contains(&key), "the key is in an error message: {err}");
        }
        let mut nokey = back.clone();
        nokey.as_object_mut().unwrap().remove("key");
        write_back(nokey);
        assert!(k.read_written_back(&ours).is_err());

        // remove is idempotent; Drop removes
        let kp = k.path().to_path_buf();
        k.remove();
        assert!(!kp.exists());
        k.remove();
        let k2 = b.new_kernel_dir().unwrap();
        let k2p = k2.path().to_path_buf();
        assert!(k2p.is_dir());
        drop(k2);
        assert!(!k2p.exists());
        assert_eq!(fs::read_dir(b.path()).unwrap().count(), 1, "only the lock is left");
        b.remove();
    }

    // U11 (budget B1): per-kernel setup and removal stays at or under 1 ms.
    // The cost is the CPU time this thread spends on it (thread_cpu_time):
    // time spent waiting for a CPU, while the other tests of this binary and
    // every other process on the machine run, is not part of it, and this
    // code does no fsync and no network I/O. Five batches of 200 cycles; the
    // fastest batch counts. Each batch's CPU and wall time is printed.
    #[test]
    fn u11_budget_200_cycles_under_1s() {
        let t = TestDir::new("u11");
        let b = BackendDir::create(t.path(), "tok").unwrap();
        let ours = conn(&uuid::Uuid::new_v4().to_string());
        let mut batches = Vec::new();
        for batch in 1..=5 {
            let (c0, w0) = (thread_cpu_time(), Instant::now());
            for _ in 0..200 {
                let k = b.new_kernel_dir().unwrap();
                k.write_connection(&ours).unwrap();
                k.remove();
            }
            let (cpu, wall) = (thread_cpu_time() - c0, w0.elapsed());
            eprintln!("U11: 200 kernel dir cycles (batch {batch}): CPU {cpu:?}, wall {wall:?}");
            batches.push(cpu);
        }
        let fastest = *batches.iter().min().unwrap();
        eprintln!("U11: fastest batch {fastest:?} of CPU time for 200 cycles (budget 1 s)");
        assert!(
            fastest < Duration::from_secs(1),
            "200 cycles took 1 s of CPU time or more in each of 5 batches: {batches:?}"
        );
        assert_eq!(fs::read_dir(b.path()).unwrap().count(), 1);
        b.remove();
    }

    // U12: dirs and files get their exact modes under a umask that removes
    // the owner's own bits (D3). The umask is the whole process's, so the
    // checks run in a process of their own: this test binary, running only
    // u12_child.
    #[test]
    fn u12_exact_modes_under_a_umask_without_owner_bits() {
        let exe = std::env::current_exe().unwrap();
        for umask in ["477", "700", "277"] {
            let out = std::process::Command::new(&exe)
                .args(["connfile::tests::u12_child", "--exact", "--ignored", "--nocapture", "--test-threads=1"])
                .env("JVTEST_U12_UMASK", umask)
                .output()
                .unwrap();
            let text = format!("{}{}", String::from_utf8_lossy(&out.stdout), String::from_utf8_lossy(&out.stderr));
            assert!(out.status.success(), "under umask {umask}:\n{text}");
            assert!(text.contains(&format!("u12 child: every check ran under umask {umask}")), "{text}");
        }
    }

    #[test]
    #[ignore = "run by u12 in a process of its own, under the umask it names"]
    fn u12_child() {
        // Only meaningful in the process u12 starts (it sets the umask).
        let Ok(m) = std::env::var("JVTEST_U12_UMASK") else { return };
        let mask = u32::from_str_radix(&m, 8).unwrap();
        // SAFETY: umask only sets this process's file creation mask, and this
        // process runs this one test.
        unsafe { libc::umask(mask as libc::mode_t) };
        let t = TestDir::new(&format!("u12-{m}"));
        let e = euid();

        let d = t.join("d");
        mkdir_private(&d).unwrap();
        assert_eq!(mode(&d), 0o700);
        let f = d.join("f");
        let mut fh = create_private_file(&f).unwrap();
        fh.write_all(b"x").unwrap();
        drop(fh);
        assert_eq!(mode(&f), 0o600);
        assert_eq!(fs::read(&f).unwrap(), b"x");

        let r = t.join("a/b/c");
        prepare_root(Source::Override, &r, e).unwrap();
        for x in ["a", "a/b", "a/b/c"] {
            assert_eq!(mode(&t.join(x)), 0o700, "{x}");
        }
        let env = EnvView {
            xdg_runtime_dir: Some(t.join("no-xdg")),
            jupyter_runtime_dir: Some(t.join("jrt")),
            ..Default::default()
        };
        let (src, root) = choose_root(&env, e).unwrap();
        assert_eq!(src, Source::JupyterRuntime);
        assert_eq!(mode(&t.join("jrt")), 0o700);
        assert_eq!(mode(&root), 0o700);

        let b = BackendDir::create(&root, "tok").unwrap();
        assert_eq!(mode(b.path()), 0o700);
        assert_eq!(mode(&b.path().join("lock")), 0o600);
        let k = b.new_kernel_dir().unwrap();
        assert_eq!(mode(k.path()), 0o700);
        let ours = conn(&uuid::Uuid::new_v4().to_string());
        k.write_connection(&ours).unwrap();
        assert_eq!(mode(&k.conn_path()), 0o600);
        assert!(k.read_written_back(&ours).unwrap().is_none());

        // a dead dir is claimed and removed
        let dead = root.join("core-tok-1-aaaaaaaaaaaa");
        mkdir_private(&dead).unwrap();
        assert_eq!(sweep_stale(&root, false, "tok", SystemTime::now() + Duration::from_secs(120)), 1);
        assert!(!dead.exists());

        k.remove();
        b.remove();
        assert!(!b.path().exists());
        println!("u12 child: every check ran under umask {m}");
    }

    fn access_mode(f: &File) -> i32 {
        // SAFETY: F_GETFL only reads the flags of a descriptor f owns.
        let fl = unsafe { libc::fcntl(f.as_raw_fd(), libc::F_GETFL) };
        assert!(fl >= 0, "F_GETFL: {}", std::io::Error::last_os_error());
        fl & libc::O_ACCMODE
    }

    // U13a: a remover's lock is a write lock (on NFS an exclusive flock
    // needs a file open for writing), and only a regular file is a lock
    #[test]
    fn u13a_remover_lock_is_open_for_writing() {
        let t = TestDir::new("u13a");
        let root = t.join("root");
        mkdir_mode(&root, 0o700);

        let d = plant(&root, "core-tok-1-aaaaaaaaaaaa", true, false);
        let f = take_lock(&d, true).expect("a free lock is taken");
        assert_eq!(access_mode(&f), libc::O_RDWR, "the lock of an existing lock file is not open for reading and writing");
        assert!((&f).write(b"").is_ok());
        assert_eq!(take_lock(&d, true).err(), Some(NoLock::Held), "a held lock was taken twice, or not told apart");
        drop(f);

        // a dir with no lock file is claimed with a new one, open for writing
        let d2 = plant(&root, "core-tok-2-bbbbbbbbbbbb", false, false);
        let f2 = take_lock(&d2, true).expect("a dir with no lock file is claimed");
        assert!(matches!(access_mode(&f2), libc::O_WRONLY | libc::O_RDWR));
        assert_eq!(mode(&d2.join("lock")), 0o600);
        drop(f2);

        // a lock that is not a regular file is never used, and opening it
        // never blocks (a FIFO opened for reading would wait for a writer)
        let d3 = plant(&root, "core-tok-3-cccccccccccc", false, false);
        fs::create_dir(d3.join("lock")).unwrap();
        assert_eq!(take_lock(&d3, true).err(), Some(NoLock::Other));
        let d4 = plant(&root, "core-tok-4-dddddddddddd", false, false);
        let fifo = d4.join("lock");
        let c = std::ffi::CString::new(fifo.as_os_str().as_bytes()).unwrap();
        // SAFETY: c is a NUL-terminated path that outlives the call.
        assert_eq!(unsafe { libc::mkfifo(c.as_ptr(), 0o600) }, 0);
        let (tx, rx) = std::sync::mpsc::channel();
        let d4c = d4.clone();
        std::thread::spawn(move || {
            let _ = tx.send(take_lock(&d4c, true).is_ok());
        });
        let got = rx.recv_timeout(Duration::from_secs(2));
        if got.is_err() {
            // unblock the opener so the thread ends, then fail
            let _ = OpenOptions::new().write(true).custom_flags(libc::O_NONBLOCK).open(&fifo);
            panic!("take_lock blocked on a FIFO named lock");
        }
        assert!(!got.unwrap(), "a FIFO was taken as a lock");
        assert!(d3.join("lock").is_dir() && fs::symlink_metadata(&fifo).unwrap().file_type().is_fifo());
    }

    // U13b: where locking fails (a filesystem without working locks), a dir
    // goes only when this remover made its lock file (it had no lock and
    // was old enough) or its backend is gone; a running backend, an unknown
    // pid and an odd name stay
    #[test]
    fn u13b_without_working_locks_only_gone_backends_dirs_go() {
        let root = PathBuf::from("/nonexistent-root");
        let me = std::process::id();
        let gone = 2_000_000_000u32; // above any pid limit: no such process
        let name = |pid: u32| root.join(format!("core-tok-{pid}-aaaaaaaaaaaa"));
        assert!(dead_without_lock(&name(me), true, true));
        assert!(!dead_without_lock(&name(me), false, true), "a dir of a running backend would be removed");
        assert!(!dead_without_lock(&name(1), false, true));
        assert!(dead_without_lock(&name(gone), false, true));
        assert!(!dead_without_lock(&name(3_000_000_000), false, true), "a pid out of range");
        assert!(!dead_without_lock(&root.join("core-tok-0-aaaaaaaaaaaa"), false, true));
        assert!(!dead_without_lock(&root.join("core-odd"), false, true));

        // the same through a sweep, with every lock attempt failing: a
        // backend made there goes on without a lock and keeps its dir, and
        // only the dir of a gone backend and a dir the sweep claimed go
        let t = TestDir::new("u13b");
        let root = t.join("root");
        mkdir_mode(&root, 0o700);
        let now = SystemTime::now();
        set_locks_fail(true);
        let live = BackendDir::create(&root, "tok").expect("a backend dir is made where locks fail");
        let running = plant(&root, &format!("core-tok-{me}-bbbbbbbbbbbb"), true, true);
        let init = plant(&root, "core-tok-1-cccccccccccc", true, true);
        let dead = plant(&root, &format!("core-tok-{gone}-dddddddddddd"), true, true);
        let old_nolock = plant(&root, &format!("core-tok-{me}-eeeeeeeeeeee"), false, true);
        set_mtime(&old_nolock, now - Duration::from_secs(120));
        let young_nolock = plant(&root, &format!("core-tok-{gone}-ffffffffffff"), false, true);
        let removed = sweep_stale(&root, false, "tok", now);
        let live_kept = live.path().join("lock").exists();
        set_locks_fail(false);
        assert!(live_kept, "the dir of a running backend was removed where locks fail");
        assert!(running.join("lock").exists(), "the dir of a running backend was removed where locks fail");
        assert!(init.join("lock").exists(), "the dir of pid 1 was removed where locks fail");
        assert!(!dead.exists(), "the dir of a gone backend is still there");
        assert!(!old_nolock.exists(), "an old dir with no lock file is still there");
        assert!(young_nolock.exists(), "a young dir with no lock file was removed");
        assert_eq!(removed, 2);
        live.remove();
        assert!(!live.path().exists());
    }

    // U20: the guard's waiting removal (remove_backend_dir_waiting) waits for
    // a held lock, and, where locking fails, for the backend process named in
    // the dir to be gone (a killed process keeps its pid until its parent
    // reaps it); it gives up after its wait and never waits for a dir that
    // is gone
    #[test]
    fn u20_waiting_removal_waits_for_the_backend_to_be_gone() {
        let t = TestDir::new("u20");
        let root = t.join("root");
        mkdir_mode(&root, 0o700);
        let step = Duration::from_millis(5);

        // a held lock, released 100 ms later
        let d = plant(&root, "core-tok-1-aaaaaaaaaaaa", true, true);
        let holder = File::options().read(true).write(true).open(d.join("lock")).unwrap();
        holder.try_lock().unwrap();
        let releaser = std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(100));
            drop(holder);
        });
        let removed = remove_backend_dir_waiting(&d, Duration::from_secs(1), step);
        releaser.join().unwrap();
        assert!(removed && !d.exists(), "a lock released 100 ms later was not waited for");

        // where locking fails: the backend process is killed 100 ms later
        // and reaped
        let mut backend = std::process::Command::new("sleep").arg("30").spawn().unwrap();
        let d = plant(&root, &format!("core-tok-{}-bbbbbbbbbbbb", backend.id()), true, true);
        let killer = std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(100));
            let _ = backend.kill();
            let _ = backend.wait();
        });
        set_locks_fail(true);
        let t0 = Instant::now();
        let removed = remove_backend_dir_waiting(&d, Duration::from_secs(1), step);
        let took = t0.elapsed();
        set_locks_fail(false);
        killer.join().unwrap();
        assert!(removed && !d.exists(), "a backend gone 100 ms later was not waited for where locks fail");
        assert!(took >= Duration::from_millis(100), "removed after {took:?}, while the backend still ran");

        // a backend that stays: given up after the wait, the dir kept
        let mut live = std::process::Command::new("sleep").arg("30").spawn().unwrap();
        let d = plant(&root, &format!("core-tok-{}-cccccccccccc", live.id()), true, true);
        set_locks_fail(true);
        let t0 = Instant::now();
        let removed = remove_backend_dir_waiting(&d, Duration::from_millis(200), step);
        let took = t0.elapsed();
        set_locks_fail(false);
        let _ = live.kill();
        let _ = live.wait();
        assert!(!removed && d.join("lock").exists(), "the dir of a running backend was removed");
        assert!(took >= Duration::from_millis(200) && took < Duration::from_secs(2), "gave up after {took:?}");

        // a dir that is gone: no wait
        let t0 = Instant::now();
        let gone = root.join("core-tok-2-dddddddddddd");
        assert!(!remove_backend_dir_waiting(&gone, Duration::from_secs(1), step));
        assert!(t0.elapsed() < Duration::from_millis(100));
    }

    // U14: a removal finishes once the lock is closed: on NFS an open file
    // that is unlinked stays as a hidden file in its dir until it is closed
    // (simulated with an entry that cannot be removed until then)
    #[test]
    fn u14_removal_finishes_once_the_lock_is_closed() {
        use std::cell::Cell;
        use std::rc::Rc;
        let t = TestDir::new("u14");
        let root = t.join("root");
        mkdir_mode(&root, 0o700);
        for (i, held) in [false, true].into_iter().enumerate() {
            let d = plant(&root, &format!("core-tok-{}-aaaaaaaaaaaa", i + 1), true, true);
            // a handle of its own on the lock file (no lock) tells whether
            // the remover still holds the lock
            let probe = File::open(d.join("lock")).unwrap();
            let hidden = d.join(".nfs000000000000000b00000001");
            let released: Rc<Cell<Option<bool>>> = Rc::default();
            let r = released.clone();
            set_hook(Some(Box::new(move |point: Point, dir: &Path| match point {
                Point::LockUnlinked => {
                    assert_eq!(dir, hidden.parent().unwrap());
                    mkdir_mode(&hidden.join("x"), 0o700);
                    set_mode(&hidden, 0o000);
                }
                Point::LockReleased => {
                    let free = wait_free(&probe);
                    r.set(Some(free));
                    if free {
                        set_mode(&hidden, 0o700);
                    }
                }
                Point::BeforeLock
                | Point::BeforePublish
                | Point::LegacyOpened
                | Point::SweepJudged
                | Point::RecreateBeforeLock
                | Point::BeforeLockStat
                | Point::RecreateMade
                | Point::RecreateOpened
                | Point::RecreateLost
                | Point::GuardWaitBegins
                | Point::GuardLockTry => {}
            })));
            let lock = held.then(|| {
                let f = File::options().write(true).open(d.join("lock")).unwrap();
                f.try_lock().unwrap();
                f
            });
            let removed = remove_backend_dir_locked(&d, lock);
            set_hook(None);
            assert_eq!(released.get(), Some(true), "held {held}: the lock was still held after the removal");
            assert!(removed && !d.exists(), "held {held}: the dir is still there once its lock is closed");
        }
        assert_eq!(fs::read_dir(&root).unwrap().count(), 0);
    }

    // U15: the start sweep runs on a thread nothing waits for, so a sweep
    // held up by a slow filesystem never holds up the backend's exit (the
    // tokio runtime's drop waits for its blocking pool)
    #[test]
    fn u15_a_running_sweep_never_holds_up_exit() {
        use std::sync::mpsc::channel;
        let (started_tx, started_rx) = channel::<Option<String>>();
        let (release_tx, release_rx) = channel::<()>();
        let (dropped_tx, dropped_rx) = channel::<Option<String>>();
        std::thread::spawn(move || {
            let rt = tokio::runtime::Builder::new_multi_thread().worker_threads(1).enable_all().build().unwrap();
            rt.block_on(async move {
                spawn_sweep(move || {
                    let _ = started_tx.send(std::thread::current().name().map(String::from));
                    let _ = release_rx.recv();
                });
            });
            let thread = started_rx.recv_timeout(Duration::from_secs(5)).ok().flatten();
            drop(rt); // what main does at exit
            let _ = dropped_tx.send(thread);
        });
        let dropped = dropped_rx.recv_timeout(Duration::from_secs(3));
        let _ = release_tx.send(()); // let the sweep end either way
        let thread = dropped.expect("the runtime's drop waited for a sweep that was still running");
        assert_eq!(thread.as_deref(), Some("jnv-sweep"), "the sweep ran on another thread");
    }

    /// The backend dir is live: 0700, its lock 0600 and held (a second open
    /// cannot take it), and the file named lock is the one held.
    fn assert_live_backend(rt: &Runtime, at: &Path) {
        assert_eq!(rt.backend.path(), at);
        assert_eq!(mode(at), 0o700);
        let lock = at.join("lock");
        assert_eq!(mode(&lock), 0o600);
        let probe = File::options().read(true).write(true).open(&lock).unwrap();
        assert!(
            matches!(probe.try_lock(), Err(std::fs::TryLockError::WouldBlock)),
            "the lock of the backend dir made again is not held"
        );
        let held = rt.backend.held.lock();
        let held = &held.as_ref().expect("the backend holds a lock").lock;
        let (h, n) = (held.metadata().unwrap(), fs::symlink_metadata(&lock).unwrap());
        assert_eq!((h.dev(), h.ino()), (n.dev(), n.ino()), "the file named lock is not the one held");
    }

    // U16 (D15, B11): a backend dir removed while its backend runs is made
    // again at the same path; after the exit's remove() it is an error
    #[test]
    fn u16_backend_dir_made_again_when_removed() {
        let t = TestDir::new("u16");
        let e = euid();
        let root = t.join("root");
        prepare_root(Source::Override, &root, e).unwrap();
        let rt = Runtime {
            source: Source::Override,
            root: root.clone(),
            backend: BackendDir::create(&root, "tok").unwrap(),
        };
        let at = rt.backend.path().to_path_buf();

        // the backend dir removed
        remove_tree(&at);
        let k = rt.new_kernel_dir().expect("a kernel dir after the backend dir was removed");
        assert_eq!(k.path().parent(), Some(at.as_path()));
        assert!(k.path().is_dir());
        assert_eq!(mode(k.path()), 0o700);
        assert_live_backend(&rt, &at);
        // a kernel dir made while the dir is there is made as before
        let k1 = rt.new_kernel_dir().unwrap();
        assert_eq!(k1.path().parent(), Some(at.as_path()));
        drop(k1);

        // the whole root removed, with the kernel dir in it
        remove_tree(&root);
        let k2 = rt.new_kernel_dir().expect("a kernel dir after the root was removed");
        assert_eq!(k2.path().parent(), Some(at.as_path()));
        assert_eq!(mode(&root), 0o700);
        assert_live_backend(&rt, &at);
        drop(k);
        drop(k2);

        // B11: one recreate costs one mkdir, one create and one lock, about
        // 0.3 to 0.6 ms of CPU time alone; an fsync, a scan or any busy work
        // of a few ms more fails. The cost is the CPU time this thread
        // spends on it: time spent waiting for a CPU (the other tests and
        // every other process on the machine run at the same time) is not
        // part of it. Time a filesystem call spends contending in the kernel
        // is (on APFS), and it reached 1.1 to 2.5 ms for the fastest run of a
        // batch under the build's heaviest load, so the budget is 3 ms. The
        // fastest of 21 runs counts; a batch whose fastest run still took
        // 3 ms is measured again after a pause, up to 20 batches, so a burst
        // of load (all of this binary's tests start at once) is outlasted.
        // Every batch stays far under a second of wall time.
        let budget = Duration::from_millis(3);
        let mut fastest = Vec::new();
        for batch in 1..=20 {
            let mut cpu = Vec::new();
            let mut wall = Vec::new();
            for _ in 0..21 {
                remove_tree(&at);
                let (c0, w0) = (thread_cpu_time(), Instant::now());
                let k = rt.new_kernel_dir().unwrap();
                cpu.push(thread_cpu_time() - c0);
                wall.push(w0.elapsed());
                drop(k);
            }
            cpu.sort();
            wall.sort();
            let total: Duration = wall.iter().sum();
            eprintln!(
                "U16: kernel dir with the backend dir made again (batch {batch}): CPU min {:?}, median {:?}, \
                 max {:?}; wall min {:?}, median {:?}, max {:?}",
                cpu[0], cpu[10], cpu[20], wall[0], wall[10], wall[20]
            );
            assert!(total < Duration::from_secs(1), "21 took {total:?}");
            fastest.push(cpu[0]);
            if cpu[0] < budget {
                break;
            }
            std::thread::sleep(Duration::from_millis(25));
        }
        let best = *fastest.iter().min().unwrap();
        eprintln!(
            "U16: fastest recreate {best:?} of CPU time (budget {budget:?}) in {} batch(es)",
            fastest.len()
        );
        assert!(
            best < budget,
            "the fastest of 21 took {budget:?} of CPU time or more in each of {} batches: {fastest:?}",
            fastest.len()
        );
        assert_live_backend(&rt, &at);

        // a dir someone made at that path while the backend runs, open to
        // others: it is used, set to 0700 first
        remove_tree(&at);
        mkdir_mode(&at, 0o755);
        let k3 = rt.new_kernel_dir().expect("a kernel dir after a dir of mode 755 was made at the path");
        assert_eq!(k3.path().parent(), Some(at.as_path()));
        assert_eq!(mode(&at), 0o700, "the backend dir made by someone else kept its mode");
        assert_live_backend(&rt, &at);
        drop(k3);
        // a symlink made at that path is never used
        remove_tree(&at);
        let elsewhere = t.join("elsewhere");
        mkdir_mode(&elsewhere, 0o700);
        symlink(&elsewhere, &at).unwrap();
        assert!(rt.new_kernel_dir().is_err(), "a kernel dir was made through a symlink at the backend dir's path");
        assert_eq!(fs::read_dir(&elsewhere).unwrap().count(), 0, "something was made through the symlink");
        fs::remove_file(&at).unwrap();
        let k4 = rt.new_kernel_dir().expect("a kernel dir once the symlink is gone");
        assert_live_backend(&rt, &at);
        drop(k4);

        // after the exit's remove(): an error, and nothing is made
        rt.backend.remove();
        assert!(!at.exists());
        assert!(rt.new_kernel_dir().is_err(), "a kernel dir was made after the backend dir was removed at exit");
        assert!(!at.exists(), "the backend dir was made again after the exit's remove()");
        assert!(rt.backend.recreate().is_err(), "the backend dir was made again after the exit's remove()");
        assert!(!at.exists(), "the backend dir was made again after the exit's remove()");
        // a dir someone makes at that path after the exit is never used
        mkdir_mode(&at, 0o700);
        assert!(rt.new_kernel_dir().is_err(), "a kernel dir was made in a dir made after the exit");
        assert_eq!(fs::read_dir(&at).unwrap().count(), 0, "something was made in a dir made after the exit");
        fs::remove_dir(&at).unwrap();
        remove_tree(&root);
        assert!(rt.new_kernel_dir().is_err());
        assert!(!root.exists(), "the root was made again after the exit's remove()");

        // a backend dir that was never removed is not made again: a lock file
        // that is not ours there is an error, never a second lock
        let rt2 = Runtime {
            source: Source::Override,
            root: root.clone(),
            backend: {
                prepare_root(Source::Override, &root, e).unwrap();
                BackendDir::create(&root, "tok").unwrap()
            },
        };
        assert!(matches!(rt2.backend.recreate(), Ok(false)), "recreate of a dir that is still there and still ours");
        assert_live_backend(&rt2, rt2.backend.path());
        let at2 = rt2.backend.path().to_path_buf();
        fs::remove_file(at2.join("lock")).unwrap();
        fs::write(at2.join("lock"), b"").unwrap();
        assert!(rt2.backend.recreate().is_err(), "a lock file that is not ours was taken over");
        // and the exit leaves that dir alone: only the dir whose file named
        // lock is the lock held is removed
        rt2.backend.remove();
        assert!(at2.join("lock").exists(), "the exit removed a dir whose lock is not the backend's");
        rt2.backend.remove();
        fs::remove_dir_all(&at2).unwrap();
    }

    /// A runtime with a new backend dir in `root` (made 0700 beforehand).
    fn test_runtime(root: &Path) -> Runtime {
        Runtime {
            source: Source::Override,
            root: root.to_path_buf(),
            backend: BackendDir::create(root, "tok").unwrap(),
        }
    }

    // U18 (D17): an exit while the first kernel start makes the runtime
    // leaves no backend dir behind: either the exit sees the runtime and
    // removes its dir, or the start sees the exit and removes the dir it
    // has just made
    #[test]
    fn u18_an_exit_during_the_first_start_leaves_no_backend_dir() {
        type Cell = OnceCell<Runtime>;
        let t = TestDir::new("u18");
        let root = t.join("root");
        prepare_root(Source::Override, &root, euid()).unwrap();

        // the exit came first: the new dir is removed, nothing is published
        let (cell, exiting) = (Cell::new(), parking_lot::Mutex::new(false));
        exit_runtime(&cell, &exiting);
        let rt = test_runtime(&root);
        let at = rt.backend.path().to_path_buf();
        assert!(publish(&cell, &exiting, rt).is_err(), "a runtime was published after the exit began");
        assert!(!at.exists(), "the backend dir made while the backend exits is still there");
        assert!(cell.get().is_none());

        // published first: the exit removes its dir, and no kernel dir is
        // made in it after that
        let (cell, exiting) = (Cell::new(), parking_lot::Mutex::new(false));
        let rt = publish(&cell, &exiting, test_runtime(&root)).unwrap();
        let at = rt.backend.path().to_path_buf();
        assert!(at.is_dir());
        exit_runtime(&cell, &exiting);
        assert!(!at.exists(), "the exit left the dir of the runtime made before it");
        assert!(rt.new_kernel_dir().is_err(), "a kernel dir was made after the exit");

        // the exit begins between the start's check and its publish: it
        // waits for the publish, then removes the dir
        let cell = Arc::new(Cell::new());
        let exiting = Arc::new(parking_lot::Mutex::new(false));
        let exit_thread = Arc::new(parking_lot::Mutex::new(None));
        {
            let (cell, exiting, exit_thread) = (cell.clone(), exiting.clone(), exit_thread.clone());
            set_hook(Some(Box::new(move |point, _dir| {
                if point != Point::BeforePublish {
                    return;
                }
                let (c, e) = (cell.clone(), exiting.clone());
                let h = std::thread::spawn(move || exit_runtime(&c, &e));
                // time enough for the exit to run through, unless it waits
                let deadline = Instant::now() + Duration::from_millis(200);
                while !h.is_finished() && Instant::now() < deadline {
                    std::thread::sleep(Duration::from_millis(1));
                }
                *exit_thread.lock() = Some(h);
            })));
        }
        let published = publish(&cell, &exiting, test_runtime(&root));
        set_hook(None);
        exit_thread.lock().take().expect("the hook did not run").join().unwrap();
        let rt = published.expect("a start that checked before the exit began was refused");
        assert!(!rt.backend.path().exists(), "an exit that began during the publish left the dir");

        // both at the same time, many times: no dir is ever left
        for _ in 0..200 {
            let cell = Arc::new(Cell::new());
            let exiting = Arc::new(parking_lot::Mutex::new(false));
            let rt = test_runtime(&root);
            let at = rt.backend.path().to_path_buf();
            let both = Arc::new(std::sync::Barrier::new(2));
            let exit = {
                let (c, e, b) = (cell.clone(), exiting.clone(), both.clone());
                std::thread::spawn(move || {
                    b.wait();
                    exit_runtime(&c, &e);
                })
            };
            both.wait();
            let _ = publish(&cell, &exiting, rt);
            exit.join().unwrap();
            assert!(!at.exists(), "an exit at the same time as the publish left {}", at.display());
        }
        assert_eq!(fs::read_dir(&root).unwrap().count(), 0);
    }

    /// Sets the mtime of a planted backend dir and everything in it (two
    /// levels) to `t`: files first, then the dirs.
    fn age_backend_dir(d: &Path, t: SystemTime) {
        for e in fs::read_dir(d).unwrap().flatten() {
            let p = e.path();
            if fs::symlink_metadata(&p).unwrap().is_dir() {
                for k in fs::read_dir(&p).unwrap().flatten() {
                    set_mtime(&k.path(), t);
                }
            }
            set_mtime(&p, t);
        }
        set_mtime(d, t);
    }

    // U17 (D14): in a root that is not local to this host, another host's
    // dir goes once nothing in it changed for 7 days and its lock can really
    // be taken
    #[test]
    fn u17_other_hosts_old_dirs_in_a_shared_root() {
        let t = TestDir::new("u17");
        let root = t.join("root");
        mkdir_mode(&root, 0o700);
        let now = SystemTime::now();
        let day = Duration::from_secs(24 * 3600);
        let old = now - 8 * day;
        let k = format!("kernel-{}", "0".repeat(32));

        let free_old = plant(&root, "core-other-1-aaaaaaaaaaaa", true, true);
        age_backend_dir(&free_old, old);
        let recent_file = plant(&root, "core-other-2-bbbbbbbbbbbb", true, true);
        age_backend_dir(&recent_file, old);
        set_mtime(&recent_file.join(&k).join("connection.json"), now - day);
        let recent_entry = plant(&root, "core-other-3-cccccccccccc", true, true);
        age_backend_dir(&recent_entry, old);
        set_mtime(&recent_entry.join("lock"), now - day);
        let held_old = plant(&root, "core-other-4-dddddddddddd", true, true);
        age_backend_dir(&held_old, old);
        let holder = File::options().read(true).write(true).open(held_old.join("lock")).unwrap();
        holder.try_lock().unwrap();
        let nolock_old = plant(&root, "core-other-5-eeeeeeeeeeee", false, true);
        age_backend_dir(&nolock_old, old);
        // only two levels are read: a newer file deeper down does not count
        let deep = plant(&root, "core-other-6-ffffffffffff", true, true);
        mkdir_mode(&deep.join(&k).join("sub"), 0o700);
        fs::write(deep.join(&k).join("sub/file"), b"x").unwrap();
        age_backend_dir(&deep, old);
        // a time ahead of now (another host's clock) is not old
        let ahead = plant(&root, "core-other-7-aaaaaaaaaaaa", true, true);
        age_backend_dir(&ahead, now + day);
        let fresh = plant(&root, "core-other-8-bbbbbbbbbbbb", true, true);
        // our own token keeps its rules: a free lock is enough
        let mine = plant(&root, "core-mine-9-cccccccccccc", true, true);

        assert_eq!(sweep_stale(&root, false, "mine", now), 4);
        for d in [&free_old, &nolock_old, &deep, &mine] {
            assert!(!d.exists(), "{} is still there", d.display());
        }
        for d in [&recent_file, &recent_entry, &held_old, &ahead, &fresh] {
            assert!(d.join("lock").exists(), "{} was removed", d.display());
        }
        assert!(recent_file.join(&k).join("connection.json").exists());

        // a released lock lets the old dir go
        drop(holder);
        assert!(wait_lock_free(&held_old.join("lock")));
        assert_eq!(sweep_stale(&root, false, "mine", now), 1);
        assert!(!held_old.exists());
        // the recent ones go once they are old enough
        assert_eq!(sweep_stale(&root, false, "mine", now + 6 * day + day / 2), 2);
        assert!(!recent_file.exists() && !recent_entry.exists());
        assert!(ahead.exists() && fresh.exists());

        // the pid rule is for this host's pids only: with it off, a gone pid
        // does not make a dir dead, only a lock file this remover made does
        let gone = 2_000_000_000u32;
        let name = root.join(format!("core-other-{gone}-aaaaaaaaaaaa"));
        assert!(dead_without_lock(&name, false, true));
        assert!(!dead_without_lock(&name, false, false), "the pid rule was applied to another host's dir");
        assert!(dead_without_lock(&name, true, false));

        // where locks fail, another host's old dir goes only when this
        // remover made its lock file; this host's dirs keep the pid rule
        let foreign_gone = plant(&root, &format!("core-other-{gone}-dddddddddddd"), true, true);
        age_backend_dir(&foreign_gone, old);
        let foreign_nolock = plant(&root, "core-other-10-eeeeeeeeeeee", false, true);
        age_backend_dir(&foreign_nolock, old);
        let mine_gone = plant(&root, &format!("core-mine-{gone}-ffffffffffff"), true, true);
        set_locks_fail(true);
        let removed = sweep_stale(&root, false, "mine", now);
        set_locks_fail(false);
        assert!(foreign_gone.join("lock").exists(), "another host's dir went by a pid of this host");
        assert!(!foreign_nolock.exists(), "another host's old dir with no lock file is still there");
        assert!(!mine_gone.exists(), "this host's dir of a gone backend is still there");
        assert_eq!(removed, 2);

        // in a local root every host's dirs follow this host's rules
        assert_eq!(sweep_stale(&root, true, "mine", now), 3);
        assert!(!foreign_gone.exists() && !ahead.exists() && !fresh.exists());
        assert_eq!(fs::read_dir(&root).unwrap().count(), 0);
    }

    // U21: a root is used only where nobody but root and the user can change
    // the dirs on its path: the dir it is in and every dir above it, symlinks
    // resolved, must be owned by root or the user and not writable by group
    // or others, unless it has the sticky bit
    #[test]
    fn u21_roots_only_below_dirs_nobody_else_can_change() {
        let (me, other) = (501, 502);
        assert_eq!(shared_dir_reason(0, 0o40755, me), None);
        assert_eq!(shared_dir_reason(me, 0o40700, me), None);
        assert_eq!(shared_dir_reason(me, 0o40755, me), None);
        assert_eq!(shared_dir_reason(0, 0o41777, me), None, "a root-owned sticky dir, as the system's temp dir is");
        assert_eq!(shared_dir_reason(me, 0o41777, me), None, "a sticky dir of the user");
        for (uid, m, want) in [
            (me, 0o40775, "has mode 775"),
            (me, 0o42770, "has mode 2770"),
            (me, 0o42775, "has mode 2775"),
            (0, 0o40775, "has mode 775"),
            (me, 0o40757, "has mode 757"),
            (me, 0o40777, "has mode 777"),
            (me, 0o40720, "has mode 720"),
            (other, 0o40755, "owned by uid 502"),
            (other, 0o41777, "owned by uid 502"),
            (other, 0o40700, "owned by uid 502"),
        ] {
            let why = shared_dir_reason(uid, m, me).unwrap_or_else(|| panic!("uid {uid}, mode {m:o} passed"));
            assert!(why.contains(want), "{why:?} lacks {want:?}");
        }
        // a symlink: in a sticky dir only root's or the user's
        assert_eq!(shared_link_reason(other, false, me), None);
        assert_eq!(shared_link_reason(0, true, me), None);
        assert_eq!(shared_link_reason(me, true, me), None);
        let why = shared_link_reason(other, true, me).expect("another user's symlink in a sticky dir passed");
        assert!(why.contains("uid 502") && why.contains("sticky"), "{why}");

        let t = TestDir::new("u21");
        let e = euid();
        // the dir named in the reason is where the walk found it, symlinks
        // resolved (the system's temp dir may be reached through one)
        let real = |p: &Path| fs::canonicalize(p).unwrap();
        let refused = |source: Source, root: &Path, culprit: &Path, want: &str| {
            let err = prepare_root(source, root, e).unwrap_err().to_string();
            let head = format!("{} ", real(culprit).display());
            assert!(err.starts_with(&head) && err.contains(want), "{}: {err:?} is not about {head:?} {want:?}", root.display());
            assert!(!verify_root(source, root, e), "verify_root took {}", root.display());
        };

        // the dir given as JUPYNVIM_RUNTIME_DIR open to its group (0775, or
        // 2770 as a group's project dir is) or to others: refused, left as
        // it is, nothing made in it
        for (name, m) in [("g775", 0o775), ("g2770", 0o2770), ("o757", 0o757)] {
            let d = t.join(name);
            mkdir_mode(&d, m);
            refused(Source::Override, &d.join("jupynvim"), &d, &format!("has mode {m:o}"));
            assert_eq!(mode(&d), m);
            assert!(!d.join("jupynvim").exists(), "{name}: a root was made in it");
        }
        // also when a private root of ours is there already
        let g = t.join("g775");
        mkdir_mode(&g.join("jupynvim"), 0o700);
        refused(Source::Override, &g.join("jupynvim"), &g, "has mode 775");
        fs::remove_dir(g.join("jupynvim")).unwrap();

        // below a dir open to its group: a private dir there is not enough,
        // and missing parents are not made there
        let sub = g.join("sub");
        mkdir_mode(&sub, 0o700);
        refused(Source::Override, &sub.join("jupynvim"), &g, "has mode 775");
        assert_eq!(fs::read_dir(&sub).unwrap().count(), 0);
        refused(Source::Override, &g.join("new/deeper/jupynvim"), &g, "has mode 775");
        assert!(!g.join("new").exists(), "missing parents were made below a dir open to its group");
        refused(Source::JupyterRuntime, &g.join("jrt/jupynvim"), &g, "has mode 775");
        assert!(!g.join("jrt").exists());
        // a private XDG dir in a dir open to its group
        let gx = g.join("xdg");
        mkdir_mode(&gx, 0o700);
        refused(Source::XdgRuntime, &gx.join("jupynvim"), &g, "has mode 775");
        assert!(!gx.join("jupynvim").exists());

        // symlinks: one in a fixed dir that points below a dir open to its
        // group, and one in such a dir that points to a fixed dir
        symlink(&sub, t.join("to-sub")).unwrap();
        refused(Source::Override, &t.join("to-sub/jupynvim"), &g, "has mode 775");
        let safe = t.join("safe");
        mkdir_mode(&safe, 0o755);
        symlink(&safe, g.join("to-safe")).unwrap();
        refused(Source::Override, &g.join("to-safe/jupynvim"), &g, "has mode 775");
        assert!(!safe.join("jupynvim").exists());
        // a relative symlink with ".." that ends in a fixed dir is fine, one
        // that climbs into a dir open to its group is not
        let links = t.join("links");
        mkdir_mode(&links, 0o700);
        symlink("../safe", links.join("rel")).unwrap();
        prepare_root(Source::Override, &links.join("rel/jupynvim"), e).unwrap();
        assert_eq!(mode(&safe.join("jupynvim")), 0o700);
        assert!(verify_root(Source::Override, &links.join("rel/jupynvim"), e));
        symlink("../g775/sub", links.join("rel-g")).unwrap();
        refused(Source::Override, &links.join("rel-g/jupynvim"), &g, "has mode 775");
        // a symlink loop
        symlink("loop-b", links.join("loop-a")).unwrap();
        symlink("loop-a", links.join("loop-b")).unwrap();
        let err = prepare_root(Source::Override, &links.join("loop-a/jupynvim"), e).unwrap_err().to_string();
        assert!(err.contains("too many symbolic links"), "{err}");

        // a dir on the way owned by someone else (here: the euid given owns
        // none of the test's dirs)
        let err = check_path_dirs(&safe, e.wrapping_add(1), false).unwrap_err();
        assert!(err.contains(&format!("is owned by uid {e}, neither")), "{err}");

        // a sticky dir open to everyone is fine: one of the user's, with a
        // symlink of the user's in it
        let sticky = t.join("sticky");
        mkdir_mode(&sticky, 0o1777);
        prepare_root(Source::Override, &sticky.join("jupynvim"), e).unwrap();
        assert!(verify_root(Source::Override, &sticky.join("jupynvim"), e));
        symlink(&safe, sticky.join("to-safe")).unwrap();
        check_path_dirs(&sticky.join("to-safe"), e, false).expect("the user's symlink in a sticky dir");
        // and one owned by root and open to everyone, as the system's temp
        // dir is: the first above this test's dirs (on Linux, unless TMPDIR
        // names another dir), else the first in "/" (read only, nothing is
        // made there)
        let is_root_sticky = |p: &Path| fs::metadata(p).is_ok_and(|m| m.is_dir() && m.uid() == 0 && m.mode() & 0o1002 == 0o1002);
        let tmp = real(&std::env::temp_dir());
        let above = tmp.ancestors().find(|a| is_root_sticky(a)).map(Path::to_path_buf);
        let in_slash = || {
            let mut dirs: Vec<PathBuf> =
                fs::read_dir("/").unwrap().flatten().filter_map(|e| fs::canonicalize(e.path()).ok()).collect();
            dirs.sort();
            dirs.into_iter().find(|d| is_root_sticky(d))
        };
        let root_sticky = above.clone().or_else(in_slash).expect("no root-owned sticky dir open to everyone in /");
        check_path_dirs(&root_sticky, e, false).expect("a root directly in a root-owned sticky dir");
        if above.is_some() {
            let env_s = EnvView { override_dir: Some(t.join("below-root-sticky")), ..Default::default() };
            assert_eq!(choose_root(&env_s, e).unwrap(), (Source::Override, t.join("below-root-sticky/jupynvim")));
        }
        eprintln!(
            "U21: a root-owned sticky dir passes: {}{}",
            root_sticky.display(),
            if above.is_some() { " (this test's dirs are below it)" } else { "" }
        );

        // choose_root goes on to the next candidate, and names the reason
        // when none is left
        let env_g = EnvView { override_dir: Some(g.clone()), jupyter_runtime_dir: Some(t.join("jrt")), ..Default::default() };
        assert_eq!(choose_root(&env_g, e).unwrap(), (Source::JupyterRuntime, t.join("jrt/jupynvim")));
        let only = EnvView { override_dir: Some(g.clone()), ..Default::default() };
        let err = format!("{:#}", choose_root(&only, e).unwrap_err());
        let want = format!("JUPYNVIM_RUNTIME_DIR {}: {} has mode 775", g.join("jupynvim").display(), real(&g).display());
        assert!(err.contains(&want), "{err} lacks {want}");
        assert!(err.ends_with("set JUPYNVIM_RUNTIME_DIR to a directory only you can write to"), "{err}");
    }

    // U22: the exit removes its backend dir only through the root it holds
    // open. After the root was moved away and a dir put in its place with a
    // symlink named like the backend dir, BackendDir::remove (and a kernel
    // dir's removal) leave the symlink's target alone, and remove the real
    // backend dir, moved away with its root.
    #[test]
    fn u22_removal_never_follows_a_root_put_in_its_place() {
        let t = TestDir::new("u22");
        let e = euid();
        let p = t.join("p");
        mkdir_mode(&p, 0o700);
        let root = p.join("jupynvim");
        prepare_root(Source::Override, &root, e).unwrap();
        let b = BackendDir::create(&root, "tok").unwrap();
        let name = b.path().file_name().unwrap().to_os_string();
        let k = b.new_kernel_dir().unwrap();
        k.write_connection(&conn("u22")).unwrap();
        let kname = k.path().file_name().unwrap().to_str().unwrap().to_string();

        // a dir of the user's (the home dir, say): files at three levels,
        // a lock, and a dir named like the kernel dir
        let victim = t.join("victim");
        let files: Vec<PathBuf> = ["a", "b/c", "b/d/e", "lock", &format!("{kname}/connection.json")]
            .iter()
            .map(|r| victim.join(r))
            .collect();
        for f in &files {
            fs::create_dir_all(f.parent().unwrap()).unwrap();
            fs::write(f, b"x").unwrap();
        }

        let aside = p.join("aside");
        fs::rename(&root, &aside).unwrap();
        mkdir_mode(&root, 0o700);
        symlink(&victim, root.join(&name)).unwrap();

        k.remove();
        b.remove();
        for f in &files {
            assert!(f.exists(), "{} was removed through the symlink", f.display());
        }
        assert!(fs::symlink_metadata(root.join(&name)).unwrap().file_type().is_symlink());
        assert!(!aside.join(&name).exists(), "the backend dir moved away with its root is still there");
        assert_eq!(fs::read_dir(&aside).unwrap().count(), 0);

        // the dir itself goes only while its name is still that dir: an
        // empty dir put at the name while the removal runs stays
        let q = t.join("q");
        mkdir_mode(&q, 0o700);
        let root2 = q.join("jupynvim");
        prepare_root(Source::Override, &root2, e).unwrap();
        let b2 = BackendDir::create(&root2, "tok").unwrap();
        let at = b2.path().to_path_buf();
        let moved = at.with_extension("moved");
        let (a, mv) = (at.clone(), moved.clone());
        set_hook(Some(Box::new(move |point, _| {
            if point == Point::LockUnlinked {
                fs::rename(&a, &mv).unwrap();
                mkdir_mode(&a, 0o700);
            }
        })));
        b2.remove();
        set_hook(None);
        assert!(at.is_dir(), "the dir put at the backend dir's name was removed");
        assert!(moved.is_dir() && fs::read_dir(&moved).unwrap().count() == 0, "{}", moved.display());
    }

    // U23: a sweep and the guard read a root only through a handle opened
    // without following a symlink, and the guard only a root whose path
    // passes check_path_dirs. A root replaced by a symlink to another dir of
    // the user after it was checked is not read, so the user's dirs in it
    // named like dead backend dirs stay; the same dirs in the real root go.
    #[test]
    fn u23_sweep_and_guard_never_follow_a_root_replaced_by_a_symlink() {
        let t = TestDir::new("u23");
        let e = euid();
        let p = t.join("p");
        mkdir_mode(&p, 0o700);
        let root = p.join("jupynvim");
        prepare_root(Source::Override, &root, e).unwrap();
        assert!(verify_root(Source::Override, &root, e));
        let gone = 2_000_000_000u32;
        let old = SystemTime::now() - Duration::from_secs(120);
        // the user's own dir, with dirs in it named like dead backend dirs of
        // this host: one with no lock file, old, and one whose lock is free
        let mine = p.join("mine");
        mkdir_mode(&mine, 0o700);
        let nolock = plant(&mine, "core-tok-1-aaaaaaaaaaaa", false, true);
        fs::write(nolock.join("precious"), b"x").unwrap();
        set_mtime(&nolock, old);
        let free = plant(&mine, &format!("core-tok-{gone}-bbbbbbbbbbbb"), true, true);
        fs::write(free.join("precious"), b"x").unwrap();

        let aside = p.join("aside");
        fs::rename(&root, &aside).unwrap();
        symlink(&mine, &root).unwrap();
        let step = Duration::from_millis(5);
        assert_eq!(sweep_stale(&root, false, "tok", SystemTime::now()), 0, "a sweep read a root that is a symlink");
        for d in [&nolock, &free] {
            let via = root.join(d.file_name().unwrap());
            assert!(!remove_backend_dir_waiting(&via, Duration::from_millis(50), step), "the guard removed {}", via.display());
        }
        assert!(nolock.join("precious").exists() && free.join("precious").exists());

        // the guard leaves a backend dir in a root whose dir is open to its
        // group alone
        let g = t.join("g");
        mkdir_mode(&g, 0o775);
        let groot = g.join("jupynvim");
        mkdir_mode(&groot, 0o700);
        let in_g = plant(&groot, &format!("core-tok-{gone}-cccccccccccc"), true, true);
        assert!(!remove_backend_dir_waiting(&in_g, Duration::from_millis(50), step));
        assert!(in_g.join("lock").exists());

        // control: the same dirs in the real root are removed
        fs::remove_file(&root).unwrap();
        fs::rename(&aside, &root).unwrap();
        for d in [&nolock, &free] {
            fs::rename(d, root.join(d.file_name().unwrap())).unwrap();
        }
        set_mtime(&root.join(nolock.file_name().unwrap()), old);
        assert!(remove_backend_dir_waiting(&root.join(free.file_name().unwrap()), Duration::from_millis(50), step));
        assert_eq!(sweep_stale(&root, false, "tok", SystemTime::now()), 1);
        assert_eq!(fs::read_dir(&root).unwrap().count(), 0);
    }

    // U24
    #[test]
    fn u24_the_system_temp_dir_when_nothing_else_can_be_used() {
        let t = TestDir::new("u24");
        let e = euid();
        let mine = user_root_name(e);
        assert_eq!(mine, format!("jupynvim-{e}"));
        // umask 002 and `ipykernel install --user`: ~/.local, share and
        // jupyter open to the user's group, and no usable XDG_RUNTIME_DIR
        // (unset, or inherited and missing, as on a compute node)
        let home = t.join("home");
        mkdir_mode(&home, 0o700);
        for d in [".local", ".local/share", ".local/share/jupyter"] {
            mkdir_mode(&home.join(d), 0o775);
        }
        let jdata = home.join(".local/share/jupyter");
        let tmp = t.join("tmp");
        mkdir_mode(&tmp, 0o700);
        for xdg in [None, Some(t.join("run-missing"))] {
            let env = EnvView {
                xdg_runtime_dir: xdg.clone(),
                jupyter_data_dir: Some(jdata.clone()),
                home: Some(home.clone()),
                temp_dir: Some(tmp.clone()),
                ..Default::default()
            };
            let (src, root) = choose_root(&env, e).unwrap();
            assert_eq!((src, root.clone()), (Source::Temp, tmp.join(&mine)), "XDG_RUNTIME_DIR {xdg:?}");
            assert_eq!(mode(&root), 0o700);
            assert_eq!(mode(&tmp), 0o700, "the system temp dir was changed");
            assert!(!jdata.join("runtime").exists(), "made the Jupyter runtime dir below a dir open to its group");
            if let Some(x) = &xdg {
                assert!(!x.exists(), "made the missing XDG_RUNTIME_DIR");
            }
            assert!(verify_root(Source::Temp, &root, e));
            // what goes in it is private, and gone afterwards
            let rt = Runtime { source: src, root: root.clone(), backend: BackendDir::create(&root, "u24").unwrap() };
            let k = rt.new_kernel_dir().unwrap();
            k.write_connection(&conn("k")).unwrap();
            assert_eq!((mode(rt.backend.path()), mode(k.path()), mode(&k.conn_path())), (0o700, 0o700, 0o600));
            k.remove();
            rt.backend.remove();
            assert_eq!(fs::read_dir(&root).unwrap().count(), 0);
            fs::remove_dir(&root).unwrap();
        }

        // a sticky temp dir anyone can write to (as the system's is) works
        // the same; the dir itself is never changed
        let shared = t.join("shared");
        mkdir_mode(&shared, 0o1777);
        let env = EnvView { jupyter_data_dir: Some(jdata.clone()), temp_dir: Some(shared.clone()), ..Default::default() };
        assert_eq!(choose_root(&env, e).unwrap(), (Source::Temp, shared.join(&mine)));
        assert_eq!((mode(&shared), mode(&shared.join(&mine))), (0o1777, 0o700));

        // JUPYNVIM_RUNTIME_DIR set to such a dir uses the user's own name
        // there too: a jupynvim an older version made in it (open to its
        // group, with its files) is left as it is
        let legacy = shared.join("jupynvim");
        mkdir_mode(&legacy, 0o775);
        fs::write(legacy.join("kernel-old.json"), b"{}").unwrap();
        let env_o = EnvView { override_dir: Some(shared.clone()), ..env.clone() };
        assert_eq!(choose_root(&env_o, e).unwrap(), (Source::Override, shared.join(&mine)));
        assert_eq!(mode(&legacy), 0o775, "the jupynvim already there was changed");
        assert_eq!(fs::read_dir(&legacy).unwrap().count(), 1);

        // when it cannot be used either, the error names it: a symlink or a
        // file made there first is refused, never followed or changed
        let elsewhere = t.join("elsewhere");
        mkdir_mode(&elsewhere, 0o700);
        let at = tmp.join(&mine);
        symlink(&elsewhere, &at).unwrap();
        let env = EnvView { jupyter_data_dir: Some(jdata.clone()), temp_dir: Some(tmp.clone()), ..Default::default() };
        let err = format!("{:#}", choose_root(&env, e).unwrap_err());
        assert!(err.contains(&format!("system temp dir {}: is a symbolic link", at.display())), "{err}");
        assert!(err.contains(&format!("Jupyter runtime dir {}", jdata.join("runtime/jupynvim").display())), "{err}");
        assert!(err.contains("has mode 775"), "{err}");
        assert_eq!(fs::read_dir(&elsewhere).unwrap().count(), 0);
        fs::remove_file(&at).unwrap();
        fs::write(&at, b"").unwrap();
        let err = format!("{:#}", choose_root(&env, e).unwrap_err());
        assert!(err.contains(&format!("system temp dir {}: is not a directory", at.display())), "{err}");
        fs::remove_file(&at).unwrap();
        // a dir of that name another user made is refused: its verdict (a
        // test cannot make a dir another uid owns; the Linux run with two
        // users is in the fix report)
        mkdir_mode(&at, 0o700);
        match root_verdict_at(&at, e + 1).unwrap().0 {
            Verdict::Reject(why) => assert!(why.contains(&format!("is owned by uid {e}, not {}", e + 1)), "{why}"),
            v => panic!("{v:?}"),
        }
        fs::remove_dir(&at).unwrap();
        // a temp dir open to its group is refused like any other dir; a
        // missing one is never made
        let gtmp = t.join("gtmp");
        mkdir_mode(&gtmp, 0o775);
        let err = format!("{:#}", choose_root(&EnvView { temp_dir: Some(gtmp.clone()), ..Default::default() }, e).unwrap_err());
        assert!(err.contains(&format!("system temp dir {}", gtmp.join(&mine).display())) && err.contains("has mode 775"), "{err}");
        assert!(!gtmp.join(&mine).exists());
        let gone = t.join("no-tmp");
        let err = format!("{:#}", choose_root(&EnvView { temp_dir: Some(gone.clone()), ..Default::default() }, e).unwrap_err());
        assert!(err.contains(&format!("system temp dir {}", gone.join(&mine).display())), "{err}");
        assert!(!gone.exists(), "made a missing system temp dir");
        // a relative temp dir is named as ignored
        let err = format!("{:#}", choose_root(&EnvView { temp_dir: Some(PathBuf::from("rel")), ..Default::default() }, e).unwrap_err());
        assert!(err.contains("the system temp dir rel: not an absolute path, ignored"), "{err}");
    }

    /// A chain `top/name/c/c/.../c` of `depth` dirs below `top`, made without
    /// ever working more than two levels down: each new dir is made at the
    /// top and the chain is moved into it, so it takes time linear in its
    /// depth on every filesystem. `side(i, dir)` runs on the chain's top dir
    /// when it is `i` levels from the bottom.
    fn deep_chain(top: &Path, name: &str, depth: usize, mut side: impl FnMut(usize, &File)) {
        let t = open_dir_nofollow(top).unwrap();
        let c = CString::new("c").unwrap();
        let p = CString::new("p").unwrap();
        mkdir_private_at(&t, &c).unwrap();
        for i in 1..depth {
            side(i, &open_dir_at(&t, &c).unwrap());
            mkdir_private_at(&t, &p).unwrap();
            let pd = open_dir_at(&t, &p).unwrap();
            // SAFETY: the names are NUL-terminated and outlive the calls; t
            // and pd are open dirs.
            assert_eq!(unsafe { libc::renameat(t.as_raw_fd(), c.as_ptr(), pd.as_raw_fd(), c.as_ptr()) }, 0);
            assert_eq!(unsafe { libc::renameat(t.as_raw_fd(), p.as_ptr(), t.as_raw_fd(), c.as_ptr()) }, 0);
        }
        let to = CString::new(name).unwrap();
        // SAFETY: as above.
        assert_eq!(unsafe { libc::renameat(t.as_raw_fd(), c.as_ptr(), t.as_raw_fd(), to.as_ptr()) }, 0);
    }

    /// How deep the deepest entry under `p` is (0: none), read through
    /// handles (a deep path is longer than a path may be) and without
    /// recursion; a dir's handle is closed once its subdirs are open.
    fn tree_depth(p: &Path) -> usize {
        let mut deepest = 0;
        let mut todo = vec![(open_dir_nofollow(p).unwrap(), 0)];
        while let Some((d, n)) = todo.pop() {
            for name in dir_names(&d).unwrap() {
                deepest = deepest.max(n + 1);
                if st_is_dir(&stat_at_err(&d, &name).unwrap()) {
                    todo.push((open_dir_at(&d, &name).unwrap(), n + 1));
                }
            }
        }
        deepest
    }

    /// Removes a test's dir with whatever a failed check left in it (a tree
    /// too deep for std's removal, a dir without the write bit, on macOS an
    /// ACL entry that denies deleting), with the system's chmod and rm, when
    /// dropped. Declared after the TestDir, so it runs first.
    struct Scrub(PathBuf);

    impl Drop for Scrub {
        fn drop(&mut self) {
            let run = |args: &[&str]| {
                let _ = std::process::Command::new(args[0]).args(&args[1..]).arg(&self.0).output();
            };
            if cfg!(target_os = "macos") {
                run(&["/bin/chmod", "-R", "-N"]);
            }
            run(&["/bin/chmod", "-R", "u+rwx"]);
            run(&["/bin/rm", "-rf"]);
        }
    }

    /// A tracing writer that keeps what was written.
    #[derive(Clone, Default)]
    struct Captured(std::sync::Arc<std::sync::Mutex<Vec<u8>>>);

    impl Write for Captured {
        fn write(&mut self, b: &[u8]) -> std::io::Result<usize> {
            self.0.lock().unwrap().extend_from_slice(b);
            Ok(b.len())
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }

    impl Captured {
        fn lines(&self) -> Vec<String> {
            String::from_utf8_lossy(&self.0.lock().unwrap()).lines().map(str::to_string).collect()
        }
    }

    /// Runs `f` on a thread with a stack of `stack` bytes, with every log
    /// line it writes captured; returns its result and those lines.
    fn on_small_stack<R: Send + 'static>(stack: usize, f: impl FnOnce() -> R + Send + 'static) -> (R, Vec<String>) {
        let cap = Captured::default();
        let w = cap.clone();
        let r = std::thread::Builder::new()
            .stack_size(stack)
            .spawn(move || {
                let sub = tracing_subscriber::fmt().with_writer(move || w.clone()).with_ansi(false).without_time().finish();
                tracing::subscriber::with_default(sub, f)
            })
            .unwrap()
            .join()
            .unwrap();
        (r, cap.lines())
    }

    // U25
    #[test]
    fn u25_removals_of_trees_deeper_than_the_stack_and_the_open_files_limit() {
        // in a process of its own: once with a limit of 128 open files, once
        // with the limit it was given (most often far above the depth, so a
        // removal that recursed would overflow the 64 KiB stack first)
        let exe = std::env::current_exe().unwrap();
        for nofile in ["128", "inherited"] {
            let out = std::process::Command::new(&exe)
                .args(["connfile::tests::u25_child", "--exact", "--ignored", "--nocapture", "--test-threads=1"])
                .env("JVTEST_U25_NOFILE", nofile)
                .output()
                .unwrap();
            let text = format!("{}{}", String::from_utf8_lossy(&out.stdout), String::from_utf8_lossy(&out.stderr));
            assert!(out.status.success(), "open files limit {nofile}: {:?}\n{text}", out.status);
            assert!(text.contains(&format!("u25 child: every check ran (open files limit {nofile})")), "{text}");
        }
    }

    #[test]
    #[ignore = "run by u25 in a process of its own, with the open files limit it names"]
    fn u25_child() {
        let Ok(nofile) = std::env::var("JVTEST_U25_NOFILE") else { return };
        if let Ok(n) = nofile.parse::<u64>() {
            let mut lim = libc::rlimit { rlim_cur: 0, rlim_max: 0 };
            // SAFETY: lim is a valid rlimit for the calls to read and write;
            // this process runs this one test.
            unsafe {
                assert_eq!(libc::getrlimit(libc::RLIMIT_NOFILE, &mut lim), 0);
                lim.rlim_cur = n as libc::rlim_t;
                assert_eq!(libc::setrlimit(libc::RLIMIT_NOFILE, &lim), 0);
            }
        }
        // a removal that recursed would need some hundred bytes of stack and
        // an open file per level: far more than 64 KiB, and more than 128
        // open files
        const DEPTH: usize = 1000;
        const STACK: usize = 64 * 1024;
        let t = TestDir::new("u25");
        let _scrub = Scrub(t.path().to_path_buf());

        // a kernel dir holding its file and a chain 1000 dirs deep, removed
        // as KernelDir::remove removes one: all of it goes, nothing logged
        let bd = t.join("bd");
        mkdir_mode(&bd, 0o700);
        mkdir_mode(&bd.join("kernel-1"), 0o700);
        fs::write(bd.join("kernel-1/connection.json"), b"{}").unwrap();
        deep_chain(&bd.join("kernel-1"), "c", DEPTH, |_, _| {});
        assert_eq!(tree_depth(&bd), DEPTH + 1);
        let at = bd.clone();
        let (gone, logged) = on_small_stack(STACK, move || {
            let dir = open_dir_nofollow(&at).unwrap();
            remove_entry_at(&dir, c"kernel-1", &at)
        });
        assert!(gone, "the removal failed: {logged:?}");
        assert!(logged.is_empty(), "{logged:?}");
        assert_eq!(fs::read_dir(&bd).unwrap().count(), 0);

        // one entry deep down that cannot be removed (in a dir without the
        // write bit, 500 levels down): the rest goes, it and the dirs above
        // it stay (none deeper than the dirs a removal keeps open), and one
        // line says so; once it can be removed, it goes without a line
        mkdir_mode(&bd.join("kernel-2"), 0o700);
        deep_chain(&bd.join("kernel-2"), "c", DEPTH, |i, d| {
            if i == DEPTH / 2 {
                mkdir_private_at(d, c"ro").unwrap();
                let ro = open_dir_at(d, c"ro").unwrap();
                drop(create_file_at(&ro, c"x").unwrap());
                ro.set_permissions(fs::Permissions::from_mode(0o500)).unwrap();
            }
        });
        let at = bd.clone();
        let (gone, logged) = on_small_stack(STACK, move || {
            let dir = open_dir_nofollow(&at).unwrap();
            remove_entry_at(&dir, c"kernel-2", &at)
        });
        assert!(!gone);
        assert_eq!(logged.len(), 1, "{logged:?}");
        let line = &logged[0];
        assert!(line.contains("WARN") && line.contains(&format!("cannot remove {}", bd.join("kernel-2").display())), "{line}");
        // the file in it, or the dir itself when it was due to be moved up
        // (moving a dir needs its write bit)
        let one = |l: &str| {
            ["(x): Permission denied", "(ro): Permission denied"]
                .iter()
                .any(|w| l.contains(&format!("1 entry in it could not be removed, the first {w}")))
        };
        assert!(one(line), "{line}");
        assert!(line.len() < 1000, "{line}");
        let left = tree_depth(&bd.join("kernel-2"));
        assert!(left <= REMOVE_MAX_OPEN + 2, "{left} levels left");
        make_removable(&bd);
        let at = bd.clone();
        let (gone, logged) = on_small_stack(STACK, move || {
            let dir = open_dir_nofollow(&at).unwrap();
            remove_entry_at(&dir, c"kernel-2", &at)
        });
        assert!(gone && logged.is_empty(), "{logged:?}");
        assert_eq!(fs::read_dir(&bd).unwrap().count(), 0);

        // a backend dir at exit, and a dead one in a sweep, with such a tree
        // in a kernel dir: removed, nothing logged
        let root = t.join("root");
        mkdir_mode(&root, 0o700);
        let r = root.clone();
        let (ok, logged) = on_small_stack(STACK, move || {
            let b = BackendDir::create(&r, "tok").unwrap();
            let k = b.new_kernel_dir().unwrap();
            deep_chain(k.path(), "c", DEPTH, |_, _| {});
            std::mem::forget(k);
            b.remove();
            let dead = r.join("core-tok-1-aaaaaaaaaaaa");
            mkdir_private(&dead).unwrap();
            drop(create_private_file(&dead.join("lock")).unwrap());
            mkdir_private(&dead.join("kernel-1")).unwrap();
            deep_chain(&dead.join("kernel-1"), "c", DEPTH, |_, _| {});
            sweep_stale(&r, false, "tok", SystemTime::now()) == 1 && fs::read_dir(&r).unwrap().count() == 0
        });
        assert!(ok && logged.is_empty(), "{logged:?}");

        // the exit's removal with an entry it cannot remove: one line
        let r = root.clone();
        let (ok, logged) = on_small_stack(STACK, move || {
            let b = BackendDir::create(&r, "tok").unwrap();
            let k = b.new_kernel_dir().unwrap();
            deep_chain(k.path(), "c", DEPTH, |i, d| {
                if i == 10 {
                    mkdir_private_at(d, c"ro").unwrap();
                    let ro = open_dir_at(d, c"ro").unwrap();
                    drop(create_file_at(&ro, c"x").unwrap());
                    ro.set_permissions(fs::Permissions::from_mode(0o500)).unwrap();
                }
            });
            std::mem::forget(k);
            b.remove();
            b.path().exists()
        });
        assert!(ok, "the backend dir went with an entry it could not remove");
        assert_eq!(logged.len(), 1, "{logged:?}");
        assert!(one(&logged[0]), "{logged:?}");
        make_removable(&root);
        println!("u25 child: every check ran (open files limit {nofile})");
    }

    // U26
    #[test]
    fn u26_access_control_lists() {
        use acl_right::*;
        let uuid = |s: &str| -> [u8; 16] {
            let h: String = s.chars().filter(|c| *c != '-').collect();
            let mut out = [0u8; 16];
            for (i, b) in out.iter_mut().enumerate() {
                *b = u8::from_str_radix(&h[2 * i..2 * i + 2], 16).unwrap();
            }
            out
        };
        // who a uuid names, read from it alone
        for (u, want) in [
            ("ABCDEFAB-CDEF-ABCD-EFAB-CDEF0000000C", "group 12"),
            ("ABCDEFAB-CDEF-ABCD-EFAB-CDEF00000014", "group 20"),
            ("AAAABBBB-CCCC-DDDD-EEEE-FFFF00001092", "group 4242"),
            ("FFFFEEEE-DDDD-CCCC-BBBB-AAAA00000000", "uid 0"),
            ("FFFFEEEE-DDDD-CCCC-BBBB-AAAA00001092", "uid 4242"),
            ("AD8924FB-10C2-46F1-9E6F-73D43A0A254D", "the user or group AD8924FB-10C2-46F1-9E6F-73D43A0A254D"),
        ] {
            assert_eq!(uuid_who(&uuid(u)), want);
        }
        assert_eq!(uuid("FFFFEEEE-DDDD-CCCC-BBBB-AAAA00000000"), ROOT_UUID);
        let owner = uuid("AD8924FB-10C2-46F1-9E6F-73D43A0A254D");
        let other = uuid("0F8924FB-10C2-46F1-9E6F-73D43A0A2500");
        let everyone = |rights| AclAllow { qualifier: uuid("ABCDEFAB-CDEF-ABCD-EFAB-CDEF0000000C"), rights };
        // a dir on a root's path: what the write bit gives, deleting it or
        // its entries, and taking the list or the dir
        for (rights, is_dir, sticky, want) in [
            (ADD_FILE, true, false, Some("add_file")),
            (ADD_SUBDIRECTORY, true, false, Some("add_subdirectory")),
            (ADD_FILE | ADD_SUBDIRECTORY, true, true, None),
            (DELETE_CHILD, true, true, Some("delete_child")),
            (DELETE, true, true, Some("delete")),
            (WRITE_SECURITY, true, false, Some("writesecurity")),
            (CHANGE_OWNER, true, false, Some("chown")),
            (DELETE, false, false, Some("delete")),
            (ADD_FILE | DELETE_CHILD, false, false, None),
            // read, list, search and the like
            ((1 << 1) | (1 << 3) | (1 << 7) | (1 << 9) | (1 << 11), true, false, None),
        ] {
            let got = acl_path_reason(&[everyone(rights)], is_dir, sticky);
            match want {
                None => assert_eq!(got, None, "{rights:b} dir {is_dir} sticky {sticky}"),
                Some(w) => {
                    let got = got.unwrap_or_else(|| panic!("{rights:b} dir {is_dir} sticky {sticky} passed"));
                    assert!(got.contains("gives group 12") && got.contains(w), "{got}");
                }
            }
        }
        // root's entries are fine; anyone else's are not, a user's own uuid
        // included (it is known only from a directory lookup, never made)
        let all = ADD_FILE | DELETE_CHILD;
        assert_eq!(acl_path_reason(&[AclAllow { qualifier: ROOT_UUID, rights: all }], true, false), None);
        let why = acl_path_reason(&[AclAllow { qualifier: other, rights: ADD_FILE }], true, false).unwrap();
        assert!(why.contains("the user or group 0F8924FB-10C2-46F1-9E6F-73D43A0A2500 add_file"), "{why}");
        assert!(acl_path_reason(&[AclAllow { qualifier: owner, rights: ADD_FILE }], true, false).is_some());
        // a root: any entry but root's
        assert_eq!(acl_root_reason(&[]), None);
        assert_eq!(acl_root_reason(&[AclAllow { qualifier: ROOT_UUID, rights: 1 << 1 }]), None);
        let why = acl_root_reason(&[everyone(1 << 1)]).unwrap();
        assert!(why.contains("access control list entry for group 12"), "{why}");
        assert!(acl_root_reason(&[AclAllow { qualifier: owner, rights: 1 << 1 }]).is_some());
        u26_live();
    }

    /// U26 on a real filesystem: macOS reads ACLs.
    #[cfg(target_os = "macos")]
    fn u26_live() {
        let t = TestDir::new("u26");
        let _scrub = Scrub(t.path().to_path_buf());
        let e = euid();
        let chmod_a = |entry: &str, p: &Path| {
            let out = std::process::Command::new("/bin/chmod").arg("+a").arg(entry).arg(p).output().unwrap();
            assert!(out.status.success(), "chmod +a {entry:?} {}: {}", p.display(), String::from_utf8_lossy(&out.stderr));
        };
        let me_name = String::from_utf8(std::process::Command::new("/usr/bin/id").arg("-un").output().unwrap().stdout).unwrap();
        let me_name = me_name.trim();

        // a dir given as JUPYNVIM_RUNTIME_DIR whose mode is 755 but whose
        // ACL lets everyone add and delete entries: refused, nothing made,
        // the next candidate used
        let d = t.join("acl");
        mkdir_mode(&d, 0o755);
        chmod_a("group:everyone allow add_file,add_subdirectory,delete_child", &d);
        let allows = read_acl(&d, None).unwrap();
        assert_eq!(allows.len(), 1, "{allows:?}");
        assert_eq!(uuid_who(&allows[0].qualifier), "group 12");
        let why = check_path_dirs(&d, e, false).unwrap_err();
        let head = format!("{} has an access control list entry that gives group 12 ", fs::canonicalize(&d).unwrap().display());
        assert!(why.starts_with(&head) && why.contains("add_file,add_subdirectory,delete_child"), "{why}");
        let env = EnvView { override_dir: Some(d.clone()), jupyter_runtime_dir: Some(t.join("jrt")), ..Default::default() };
        assert_eq!(choose_root(&env, e).unwrap(), (Source::JupyterRuntime, t.join("jrt/jupynvim")));
        assert!(!d.join("jupynvim").exists(), "a root was made in it");
        // below it too
        mkdir_mode(&d.join("sub"), 0o700);
        assert!(check_path_dirs(&d.join("sub"), e, false).unwrap_err().starts_with(&head));

        // a sticky dir open to all: adding is what its mode gives anyway,
        // deleting others' entries is not
        let s = t.join("sticky");
        mkdir_mode(&s, 0o1777);
        chmod_a("group:everyone allow add_file,add_subdirectory", &s);
        assert_eq!(check_path_dirs(&s, e, false), Ok(()));
        chmod_a("group:everyone allow delete_child", &s);
        assert!(check_path_dirs(&s, e, false).unwrap_err().contains("delete_child"));

        // root's entries and deny entries pass; one naming the user, who
        // owns the dir, is skipped with its uuid named (adding nothing to
        // the mode, it is not looked up)
        let o = t.join("own");
        mkdir_mode(&o, 0o755);
        chmod_a("user:root allow add_file,delete_child", &o);
        chmod_a("group:everyone deny delete", &o);
        let allows = read_acl(&o, None).unwrap();
        assert_eq!(allows.len(), 1, "{allows:?}");
        assert_eq!(allows[0].qualifier, ROOT_UUID);
        assert_eq!(check_path_dirs(&o, e, false), Ok(()));
        chmod_a(&format!("user:{me_name} allow add_file"), &o);
        let why = check_path_dirs(&o, e, false).unwrap_err();
        assert!(why.contains("has an access control list entry that gives the user or group ") && why.ends_with(" add_file"), "{why}");

        // a root made in a dir with entries its subdirs inherit gets those
        // entries; they are removed, so nothing made in it inherits one
        let p = t.join("inherit");
        mkdir_mode(&p, 0o700);
        chmod_a("group:everyone allow list,search,read,file_inherit,directory_inherit", &p);
        let root = p.join("jupynvim");
        prepare_root(Source::Override, &root, e).unwrap();
        assert_eq!(read_acl(&root, None).unwrap(), vec![], "the root kept an inherited entry");
        assert_eq!(mode(&root), 0o700);
        let b = BackendDir::create(&root, "tok").unwrap();
        let k = b.new_kernel_dir().unwrap();
        k.write_connection(&conn("k")).unwrap();
        for x in [b.path(), k.path(), &k.conn_path(), &b.path().join("lock")] {
            assert_eq!(read_acl(x, None).unwrap(), vec![], "{} has an entry", x.display());
        }
        k.remove();
        b.remove();

        // an entry added to a root later: the handle check refuses it, and
        // prepare_root removes it again
        chmod_a("group:everyone allow list", &root);
        let err = open_root_dir(&root, e).unwrap_err().to_string();
        assert!(err.contains("access control list entry for group 12"), "{err}");
        assert!(!verify_root(Source::Override, &root, e));
        prepare_root(Source::Override, &root, e).unwrap();
        assert_eq!(read_acl(&root, None).unwrap(), vec![]);
        assert!(verify_root(Source::Override, &root, e));
    }

    /// Elsewhere a POSIX ACL entry that grants writing shows as the group
    /// write bit, which the mode rules judge (U21).
    #[cfg(not(target_os = "macos"))]
    fn u26_live() {
        let t = TestDir::new("u26");
        assert_eq!(read_acl(t.path(), None).unwrap(), vec![]);
    }

    // U27 (D7, D9): no remover claims a backend dir whose removal is in
    // progress. Every remover unlinks the file named lock only right before
    // its rmdir, so a dir whose lock file is missing under the guard, or is
    // gone once a sweep that saw it opens it, is being removed by someone
    // else: the guard waits (and past its wait claims the dir only when its
    // backend's pid is gone), the sweep leaves it, and neither makes a lock
    // file in it.
    #[test]
    fn u27_no_remover_claims_a_dir_whose_removal_is_in_progress() {
        use std::cell::{Cell, RefCell};
        use std::rc::Rc;
        let t = TestDir::new("u27");
        let root = t.join("root");
        mkdir_mode(&root, 0o700);
        let me = std::process::id();
        let wait = Duration::from_millis(50);
        let step = Duration::from_millis(5);

        // (a) the guard's wait runs while the live owner removes its dir:
        // the owner has unlinked its lock file and still holds the lock
        let d = plant(&root, &format!("core-tok-{me}-aaaaaaaaaaaa"), true, true);
        let lock = File::options().write(true).open(d.join("lock")).unwrap();
        lock.try_lock().unwrap();
        let seen: Rc<RefCell<Option<(bool, Duration, bool)>>> = Rc::default();
        let s = seen.clone();
        set_hook(Some(Box::new(move |point: Point, dir: &Path| {
            if point == Point::LockUnlinked {
                let t0 = Instant::now();
                let removed = remove_backend_dir_waiting(dir, wait, step);
                *s.borrow_mut() = Some((removed, t0.elapsed(), dir.join("lock").exists()));
            }
        })));
        let owner_removed = remove_backend_dir_locked(&d, Some(lock));
        set_hook(None);
        let got = *seen.borrow();
        let (guard_removed, took, lock_made) = got.expect("(a): the hook did not run inside the owner's removal");
        assert!(!guard_removed, "(a): the guard removed a dir its live owner was removing (after {took:?})");
        assert!(took >= wait, "(a): the guard gave up after {took:?}, before its wait of {wait:?} ended");
        assert!(!lock_made, "(a): the guard made a lock file in a dir its owner was removing");
        assert!(owner_removed && !d.exists(), "(a): the owner's removal did not remove its dir");

        // (b) no lock file, and its backend's pid is gone: claimed once the
        // wait is over
        let mut c = std::process::Command::new("true").spawn().unwrap();
        c.wait().unwrap();
        let d = plant(&root, &format!("core-tok-{}-bbbbbbbbbbbb", c.id()), false, true);
        let t0 = Instant::now();
        let removed = remove_backend_dir_waiting(&d, wait, step);
        let took = t0.elapsed();
        assert!(removed && !d.exists(), "(b): a dir with no lock file whose backend is gone was kept");
        assert!(took >= wait, "(b): claimed after {took:?}, before the wait of {wait:?} ended");

        // (c) no lock file, and its backend runs: kept, also past the wait
        let d = plant(&root, &format!("core-tok-{me}-cccccccccccc"), false, true);
        let t0 = Instant::now();
        let removed = remove_backend_dir_waiting(&d, wait, step);
        let took = t0.elapsed();
        assert!(!removed, "(c): the dir of a running backend with no lock file was removed (after {took:?})");
        assert!(took >= wait, "(c): gave up after {took:?}, before the wait of {wait:?} ended");
        assert!(
            d.join(format!("kernel-{}", "0".repeat(32))).join("connection.json").exists(),
            "(c): the dir of a running backend lost its kernel dir"
        );
        assert!(!d.join("lock").exists(), "(c): the guard made a lock file in a dir it did not claim");
        fs::remove_dir_all(&d).unwrap();

        // (d) a sweep judged a dir by its free lock file, which its remover
        // unlinks before the sweep opens it: left alone
        let local = t.join("local");
        mkdir_mode(&local, 0o700);
        let d = plant(&local, &format!("core-tok-{me}-dddddddddddd"), true, true);
        let judged = Rc::new(Cell::new(false));
        let (j, lock_path) = (judged.clone(), d.join("lock"));
        set_hook(Some(Box::new(move |point: Point, dir: &Path| {
            if point == Point::SweepJudged && dir == lock_path.parent().unwrap() {
                j.set(true);
                fs::remove_file(&lock_path).unwrap();
            }
        })));
        let swept = sweep_stale(&local, true, "tok", SystemTime::now());
        set_hook(None);
        assert!(judged.get(), "(d): the sweep did not judge the dir by its lock file");
        assert_eq!(swept, 0, "(d): the sweep removed a dir whose lock file went after it was judged");
        assert!(
            d.join(format!("kernel-{}", "0".repeat(32))).join("connection.json").exists(),
            "(d): the sweep cleared a dir whose lock file went after it was judged"
        );
        assert!(!d.join("lock").exists(), "(d): the sweep made a lock file in a dir it did not claim");
    }

    // U28 (D8): the old location used as a root (JUPYNVIM_RUNTIME_DIR set to
    // a system temp dir others cannot write to) is never removed by the
    // start sweep, also when it was not usable yet when the roots were swept
    // and a kernel start makes it usable while the old location is read;
    // that start's backend dir is then made in it. An empty old location
    // that is no candidate root is still removed.
    #[test]
    fn u28_the_sweep_never_removes_the_old_location_used_as_a_root() {
        use std::cell::Cell;
        use std::rc::Rc;
        let t = TestDir::new("u28");
        let e = euid();
        let now = SystemTime::now();
        let tmp = t.join("tmp");
        mkdir_mode(&tmp, 0o700);
        let legacy = tmp.join("jupynvim");
        let old = now - Duration::from_secs(LEGACY_MIN_AGE.as_secs() + 60);

        // given directly, and through a symlink to the temp dir
        let link = t.join("link");
        symlink(&tmp, &link).unwrap();
        for given in [tmp.clone(), link.clone()] {
            let env = EnvView { override_dir: Some(given.clone()), ..EnvView::default() };
            // not usable when the roots are swept (open to others), with an
            // old file of an older version in it
            mkdir_mode(&legacy, 0o755);
            let f = legacy.join(format!("kernel-{}.json", uuid::Uuid::new_v4()));
            fs::write(&f, b"{}").unwrap();
            set_mtime(&f, old);
            assert!(!verify_root(Source::Override, &legacy, e));
            // a kernel start makes it usable once the sweep has opened it
            let ran = Rc::new(Cell::new(false));
            let (r, l) = (ran.clone(), legacy.clone());
            set_hook(Some(Box::new(move |point: Point, _: &Path| {
                if point == Point::LegacyOpened {
                    prepare_root(Source::Override, &l, e).unwrap();
                    r.set(true);
                }
            })));
            let rep = sweep_at_start_in(&env, &legacy, e, "tok", now);
            set_hook(None);
            assert!(ran.get(), "{}: the sweep did not read the old location", given.display());
            assert_eq!(rep.legacy_removed, 1, "{}: the old file was not removed", given.display());
            assert!(!rep.legacy_dir_removed && legacy.is_dir(), "{}: the root was removed", given.display());
            let b = BackendDir::create(&legacy, "tok").expect("a backend dir in the root after the sweep");
            b.remove();
            fs::remove_dir(&legacy).unwrap();
        }

        // an empty old location that is no candidate root is removed
        let other = t.join("other");
        mkdir_mode(&other, 0o700);
        mkdir_mode(&legacy, 0o700);
        let env = EnvView { override_dir: Some(other), ..EnvView::default() };
        let rep = sweep_at_start_in(&env, &legacy, e, "tok", now);
        assert!(rep.legacy_dir_removed && !legacy.exists(), "an empty old location that is no root was kept");
    }

    // U29 (D15): another backend's start sweep that runs while the backend
    // dir is made again, between making its new lock file and locking it,
    // sees an unlocked lock and removes the dir; the kernel start then makes
    // it again once more instead of failing. So does each other place where
    // a try finds the dir taken (recreate's Lost): the new lock held by a
    // sweep still removing the dir, the dir removed between its mkdir and
    // its open, or after its open, and a remover's lock file still in it. A
    // sweep that takes it every time ends in an error after CREATE_TRIES
    // tries.
    #[test]
    fn u29_a_sweep_that_takes_the_dir_being_made_again_does_not_fail_the_start() {
        use std::cell::{Cell, RefCell};
        use std::rc::Rc;
        let t = TestDir::new("u29");
        let e = euid();
        let root = t.join("root");
        prepare_root(Source::Override, &root, e).unwrap();
        let rt = test_runtime(&root);
        let at = rt.backend.path().to_path_buf();
        let sweeping = |times: usize| -> (Rc<Cell<usize>>, Rc<Cell<usize>>) {
            let (runs, swept) = (Rc::new(Cell::new(0)), Rc::new(Cell::new(0)));
            let (n, sw, r) = (runs.clone(), swept.clone(), root.clone());
            set_hook(Some(Box::new(move |point: Point, _: &Path| {
                if point == Point::RecreateBeforeLock && n.get() < times {
                    n.set(n.get() + 1);
                    sw.set(sw.get() + sweep_stale(&r, false, "tok", SystemTime::now()));
                }
            })));
            (runs, swept)
        };

        // once
        remove_tree(&at);
        take_lost();
        let (runs, swept) = sweeping(1);
        let k = rt.new_kernel_dir();
        set_hook(None);
        assert_eq!((runs.get(), swept.get()), (1, 1), "the sweep did not take the dir being made again");
        let k = k.expect("the kernel start failed after a sweep took the dir being made again");
        assert_eq!(k.path().parent(), Some(at.as_path()));
        assert_live_backend(&rt, &at);
        drop(k);
        // the sweep was done by the time the new lock was tried (a process
        // another test thread starts can hold a copy of the sweep's lock a
        // moment longer: then the lock is still held)
        let lost = take_lost();
        let site = |l: &String| l.contains("removed while it was made again") || l.contains("held by a sweep");
        assert!(lost.len() == 1 && site(&lost[0]), "{lost:?}");

        // `act` runs when the first try reaches `at`; `done` when a try ended
        // in a Lost (the sweep that took the dir is done with it); counts the
        // tries that reached `at`
        type Act = Box<dyn FnMut(&Path)>;
        let first_try = |at: Point, mut act: Act, mut done: Act| -> Rc<Cell<usize>> {
            let reached = Rc::new(Cell::new(0));
            let n = reached.clone();
            set_hook(Some(Box::new(move |point: Point, dir: &Path| {
                if point == at {
                    n.set(n.get() + 1);
                    if n.get() == 1 {
                        act(dir);
                    }
                } else if point == Point::RecreateLost {
                    done(dir);
                }
            })));
            reached
        };
        let cases: [(&str, Point, Act, Act, &str); 4] = {
            // the new lock taken by a sweep (a second open file) before the
            // backend locks it, held until the sweep removed the dir
            let sweep_lock: Rc<RefCell<Option<File>>> = Rc::default();
            let (l1, l2) = (sweep_lock.clone(), sweep_lock);
            [
                (
                    "the new lock held by a sweep",
                    Point::RecreateBeforeLock,
                    Box::new(move |dir: &Path| {
                        let f = File::options().read(true).write(true).open(dir.join("lock")).unwrap();
                        f.try_lock().expect("the new lock was already held before the backend locked it");
                        *l1.borrow_mut() = Some(f);
                    }),
                    Box::new(move |dir: &Path| {
                        remove_tree(dir);
                        l2.borrow_mut().take();
                    }),
                    "the lock of",
                ),
                (
                    "the dir removed between its mkdir and its open",
                    Point::RecreateMade,
                    Box::new(|dir: &Path| fs::remove_dir(dir).unwrap()),
                    Box::new(|_: &Path| {}),
                    "was removed while it was made again",
                ),
                (
                    "the dir removed after its open",
                    Point::RecreateOpened,
                    Box::new(|dir: &Path| fs::remove_dir(dir).unwrap()),
                    Box::new(|_: &Path| {}),
                    "was taken by a sweep while it was made again",
                ),
                (
                    "a remover's lock file in the dir",
                    Point::RecreateOpened,
                    Box::new(|dir: &Path| fs::write(dir.join("lock"), b"").unwrap()),
                    Box::new(|dir: &Path| remove_tree(dir)),
                    "was taken by a sweep while it was made again",
                ),
            ]
        };
        for (what, point, act, done, says) in cases {
            remove_tree(&at);
            take_lost();
            let reached = first_try(point, act, done);
            let k = rt.new_kernel_dir();
            set_hook(None);
            let lost = take_lost();
            let k = k.unwrap_or_else(|e| panic!("{what}: the kernel start failed: {e:#}"));
            assert_eq!(reached.get(), 2, "{what}: not two tries that reached {point:?}");
            assert!(lost.len() == 1 && lost[0].contains(says), "{what}: not one Lost that says {says:?}: {lost:?}");
            assert_eq!(k.path().parent(), Some(at.as_path()), "{what}");
            assert_live_backend(&rt, &at);
            drop(k);
        }

        // every time
        remove_tree(&at);
        take_lost();
        let (runs, swept) = sweeping(usize::MAX);
        let err = rt.new_kernel_dir().err().expect("a kernel dir although every try was taken");
        set_hook(None);
        assert_eq!((runs.get(), swept.get()), (CREATE_TRIES, CREATE_TRIES));
        assert_eq!(take_lost().len(), CREATE_TRIES, "not a Lost for each try");
        let msg = format!("{err:#}");
        assert!(msg.contains("removed each time it was made again"), "{msg}");
        assert_eq!(fs::read_dir(&root).unwrap().count(), 0, "a try left something in the root");
        // the next start makes it
        let k = rt.new_kernel_dir().expect("a kernel dir once no sweep runs");
        assert_live_backend(&rt, &at);
        drop(k);
        rt.backend.remove();
        assert!(!at.exists());
    }

    // U30 (D9, D14): a sweep claims a dir only when the dir had no lock file
    // when it was judged, and reads the dir's age after it saw the lock file
    // missing: a dir whose owner unlinks its lock file while the sweep
    // judges it (a clean exit's removal, its rmdir next) is left to its
    // owner, in a local root and, for another host's dir, in a shared root.
    // A dir that had no lock file and is old is still claimed and removed.
    #[test]
    fn u30_a_sweep_never_claims_a_dir_whose_lock_file_goes_while_it_is_judged() {
        use std::cell::Cell;
        use std::rc::Rc;
        let t = TestDir::new("u30");
        let k = format!("kernel-{}", "0".repeat(32));
        // the owner unlinks its lock file (remove_locked_at) when the sweep
        // reaches `at` for the dir `d`
        let unlink_at = |at: Point, d: &Path| -> Rc<Cell<bool>> {
            let ran = Rc::new(Cell::new(false));
            let (r, d) = (ran.clone(), d.to_path_buf());
            set_hook(Some(Box::new(move |point: Point, dir: &Path| {
                if point == at && dir == d {
                    r.set(true);
                    fs::remove_file(d.join("lock")).unwrap();
                }
            })));
            ran
        };
        let held = |d: &Path| -> File {
            let f = File::options().read(true).write(true).open(d.join("lock")).unwrap();
            f.try_lock().unwrap();
            f
        };

        // (a) a local root: this host's dir, judged old by an mtime read
        // before its lock file went
        let local = t.join("local");
        mkdir_mode(&local, 0o700);
        let d = plant(&local, &format!("core-tok-{}-aaaaaaaaaaaa", std::process::id()), true, false);
        let lock = held(&d);
        let now = SystemTime::now();
        set_mtime(&d, now - Duration::from_secs(120));
        let ran = unlink_at(Point::BeforeLockStat, &d);
        let swept = sweep_stale(&local, true, "tok", now);
        set_hook(None);
        assert!(ran.get(), "(a): the sweep did not reach the dir before its lock file");
        assert_eq!(swept, 0, "(a): the sweep removed a dir whose owner unlinked its lock file while it was judged");
        assert!(d.exists(), "(a): the dir is gone before its owner's rmdir");
        assert!(!d.join("lock").exists(), "(a): the sweep made a lock file in a dir its owner is removing");
        drop(lock);
        fs::remove_dir(&d).expect("(a): the owner's rmdir");

        // (b) a shared root: another host's dir, unchanged for 8 days, whose
        // owner unlinks its lock file after the sweep read its age
        let shared = t.join("shared");
        mkdir_mode(&shared, 0o700);
        let d = plant(&shared, "core-far-7-bbbbbbbbbbbb", true, true);
        let lock = held(&d);
        let now = SystemTime::now();
        age_backend_dir(&d, now - Duration::from_secs(8 * 24 * 3600));
        let ran = unlink_at(Point::BeforeLockStat, &d);
        let swept = sweep_stale(&shared, false, "tok", now);
        set_hook(None);
        assert!(ran.get(), "(b): the sweep did not reach the dir before its lock file");
        assert_eq!(swept, 0, "(b): the sweep removed another host's dir whose lock file went while it was judged");
        assert!(d.join(&k).join("connection.json").exists(), "(b): the sweep cleared the dir");
        assert!(!d.join("lock").exists(), "(b): the sweep made a lock file in a dir its owner is removing");
        drop(lock);

        // (c) the same, the lock file going after the sweep saw it
        let d = plant(&shared, "core-far-8-cccccccccccc", true, true);
        let lock = held(&d);
        let now = SystemTime::now();
        age_backend_dir(&d, now - Duration::from_secs(8 * 24 * 3600));
        let ran = unlink_at(Point::SweepJudged, &d);
        let swept = sweep_stale(&shared, false, "tok", now);
        set_hook(None);
        assert!(ran.get(), "(c): the sweep did not judge another host's dir by its lock file");
        assert_eq!(swept, 0, "(c): the sweep removed another host's dir whose lock file went after it was seen");
        assert!(d.join(&k).join("connection.json").exists(), "(c): the sweep cleared the dir");
        assert!(!d.join("lock").exists(), "(c): the sweep made a lock file in a dir it did not claim");
        drop(lock);

        // (d) controls, each in a root of its own: a dir with no lock file
        // that is old is claimed and removed
        let shared2 = t.join("shared2");
        mkdir_mode(&shared2, 0o700);
        let d = plant(&shared2, "core-far-9-dddddddddddd", false, true);
        let now = SystemTime::now();
        age_backend_dir(&d, now - Duration::from_secs(8 * 24 * 3600));
        let swept = sweep_stale(&shared2, false, "tok", now);
        assert_eq!(swept, 1, "(d): another host's old dir with no lock file was kept");
        assert!(!d.exists(), "(d): another host's old dir with no lock file is still there");
        let local2 = t.join("local2");
        mkdir_mode(&local2, 0o700);
        let mut c = std::process::Command::new("true").spawn().unwrap();
        c.wait().unwrap();
        let d = plant(&local2, &format!("core-tok-{}-eeeeeeeeeeee", c.id()), false, true);
        let now = SystemTime::now();
        set_mtime(&d, now - Duration::from_secs(120));
        assert_eq!(sweep_stale(&local2, true, "tok", now), 1, "(d): an old dir with no lock file was kept");
        assert!(!d.exists(), "(d): an old dir with no lock file is still there");
    }
}
