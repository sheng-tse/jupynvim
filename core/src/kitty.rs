// Native Kitty graphics protocol implementation.
//
// All encoding lives here as pure functions. I/O lives in `LocalTty` (used in
// local mode). Remote mode skips I/O: encoded bytes flow back to the Lua
// frontend via RPC and the frontend writes them to its own local /dev/tty.
//
// Two transmit modes:
//   `transmit_virtual` (a=T, U=1, c, r): Unicode-placeholder mode. The
//      frontend renders placeholder chars (U+10EEEE) in the buffer with
//      foreground color encoding the image ID; the terminal draws the image
//      where the placeholders are. Image follows buffer text on scroll.
//   `transmit_only` (a=t): no immediate placement. Used for direct-placement
//      mode (paired with `place` later at specific screen coords) and for
//      GIF animation (retransmit each frame to the same image_id; terminal
//      replaces the image data and the placeholders refresh).
//
// Reference: https://sw.kovidgoyal.net/kitty/graphics-protocol/

use anyhow::{anyhow, Context, Result};
use base64::Engine;
use parking_lot::Mutex;
use std::fmt::Write as _;
use std::fs::OpenOptions;
use std::io::Write;
use std::path::PathBuf;
use std::sync::Arc;

// --- Mode dispatch ---

pub enum KittyMode {
    /// Backend writes directly to a local TTY (tmux-wrapping if needed).
    Local(LocalTty),
    /// Backend encodes but does not write; the frontend writes to its own TTY.
    Remote,
}

// --- Pure encoding (no I/O) ---

const CHUNK: usize = 4096;

fn write_chunks<F: FnMut(&mut String, &str, bool, bool)>(out: &mut String, b64: &str, mut emit: F) {
    let total = b64.len();
    let mut pos = 0;
    let mut first = true;
    while pos < total {
        let end = (pos + CHUNK).min(total);
        let part = &b64[pos..end];
        let more = end < total;
        emit(out, part, first, more);
        first = false;
        pos = end;
    }
}

/// Transmit-only (`a=t`): used for direct-placement renderer mode and for
/// GIF frame retransmission. No placement happens; caller follows up with
/// `encode_place` (or another transmit, for animation).
pub fn encode_transmit_only(id: u32, png: &[u8]) -> Vec<u8> {
    let b64 = base64::engine::general_purpose::STANDARD.encode(png);
    let mut out = String::with_capacity(b64.len() + 256);
    write_chunks(&mut out, &b64, |out, part, first, more| {
        let m = if more { 1 } else { 0 };
        if first {
            let _ = write!(out, "\x1b_Ga=t,f=100,i={},q=2,m={};{}\x1b\\", id, m, part);
        } else {
            let _ = write!(out, "\x1b_Gm={},q=2;{}\x1b\\", m, part);
        }
    });
    out.into_bytes()
}

/// Transmit data + (re)create the EXPLICIT virtual placement: `a=t` chunks
/// followed by `a=p,U=1,p=1,c,r`, one buffer = one atomic tty write.
///
/// NOT `a=T,U=1`: a display without a placement id gets an INTERNAL id and
/// those accumulate one per transmit (Ghostty graphics_storage.zig: "This
/// allows multiple placements"), which double-draws gif frames as ghosts.
/// An external `p=1` is one-per-(image,placement) and replaced in place,
/// so per-frame retransmits keep exactly one placement with authoritative
/// geometry (no shadows, no crop from grid re-derivation).
pub fn encode_transmit_virtual(id: u32, png: &[u8], cols: u32, rows: u32) -> Vec<u8> {
    let b64 = base64::engine::general_purpose::STANDARD.encode(png);
    let mut out = String::with_capacity(b64.len() + 256);
    write_chunks(&mut out, &b64, |out, part, first, more| {
        let m = if more { 1 } else { 0 };
        if first {
            let _ = write!(out, "\x1b_Ga=t,f=100,i={},q=2,m={};{}\x1b\\", id, m, part);
        } else {
            let _ = write!(out, "\x1b_Gm={},q=2;{}\x1b\\", m, part);
        }
    });
    let _ = write!(
        out,
        "\x1b_Ga=p,U=1,i={},p=1,c={},r={},q=2\x1b\\",
        id, cols, rows
    );
    out.into_bytes()
}

/// (Re)assert the explicit virtual placement WITHOUT retransmitting data:
/// first delete every placement of the image (lowercase `d=i` with no `p=`
/// removes placements only, data stays), then create the single external
/// one. Heals images whose placement was lost or left over as anonymous
/// internals, after which the terminal would fall back to native-size
/// placeholder mapping (renders as a random crop).
pub fn encode_place_virtual(id: u32, cols: u32, rows: u32) -> Vec<u8> {
    format!(
        "\x1b_Ga=d,d=i,i={},q=2\x1b\\\x1b_Ga=p,U=1,i={},p=1,c={},r={},q=2\x1b\\",
        id, id, cols, rows
    )
    .into_bytes()
}

/// Place an already-transmitted image (`a=p`) at the cursor's current position.
/// Caller is responsible for positioning the cursor; see `encode_place_at_screen`.
pub fn encode_place(image_id: u32, placement_id: u32, cols: u32, rows: u32) -> Vec<u8> {
    format!(
        "\x1b_Ga=p,i={},p={},c={},r={},q=2\x1b\\",
        image_id, placement_id, cols, rows
    )
    .into_bytes()
}

/// Place at (`screen_row`, `screen_col`) atomically: save cursor, move, place,
/// restore cursor. One terminal write; no interleaving with other output.
pub fn encode_place_at_screen(
    image_id: u32,
    placement_id: u32,
    cols: u32,
    rows: u32,
    screen_row: u32,
    screen_col: u32,
) -> Vec<u8> {
    format!(
        "\x1b[s\x1b[{};{}H\x1b_Ga=p,i={},p={},c={},r={},q=2\x1b\\\x1b[u",
        screen_row, screen_col, image_id, placement_id, cols, rows
    )
    .into_bytes()
}

/// Delete image (and all its placements) (`a=d, d=I`).
pub fn encode_delete_image(id: u32) -> Vec<u8> {
    format!("\x1b_Ga=d,d=I,i={},q=2\x1b\\", id).into_bytes()
}

/// Delete a specific placement only (`a=d, d=I` with `p=`). Image data stays.
pub fn encode_delete_image_placement(image_id: u32, placement_id: u32) -> Vec<u8> {
    format!(
        "\x1b_Ga=d,d=I,i={},p={},q=2\x1b\\",
        image_id, placement_id
    )
    .into_bytes()
}

/// Delete all images and placements (`a=d, d=A`).
pub fn encode_delete_all() -> Vec<u8> {
    b"\x1b_Ga=d,d=A,q=2\x1b\\".to_vec()
}

/// Delete all VISIBLE placements but keep image data (`a=d, d=a`). Virtual
/// placements auto-recreate from buffer placeholder chars on the terminal's
/// next redraw, so this only clears direct placements (e.g. file-explorer
/// preview leftovers) without disturbing notebook cells or gif animation.
pub fn encode_delete_visible() -> Vec<u8> {
    b"\x1b_Ga=d,d=a,q=2\x1b\\".to_vec()
}

// --- Local TTY writer ---

#[derive(Clone)]
pub struct LocalTty {
    inner: Arc<Mutex<LocalTtyInner>>,
}

struct LocalTtyInner {
    path: PathBuf,
    // True when nvim runs inside tmux and escapes need DCS-passthrough wrapping.
    // Cached at open time because TMUX env doesn't change at runtime.
    in_tmux: bool,
}

impl LocalTty {
    pub fn open(path: Option<PathBuf>) -> Result<Self> {
        let p = path.unwrap_or_else(|| PathBuf::from("/dev/tty"));
        OpenOptions::new()
            .write(true)
            .open(&p)
            .with_context(|| format!("cannot open tty {}", p.display()))?;
        let in_tmux = std::env::var_os("TMUX").is_some()
            && std::env::var_os("JUPYNVIM_DISABLE_TMUX_PASSTHROUGH").is_none();
        Ok(Self {
            inner: Arc::new(Mutex::new(LocalTtyInner { path: p, in_tmux })),
        })
    }

    pub fn write(&self, bytes: &[u8]) -> Result<()> {
        let inner = self.inner.lock();
        let mut f = OpenOptions::new()
            .write(true)
            .open(&inner.path)
            .map_err(|e| anyhow!("tty open: {e}"))?;
        if inner.in_tmux {
            // tmux's `allow-passthrough on` only forwards escapes wrapped as
            // `ESC P tmux ; <body with internal ESCs doubled> ESC \`.
            // Without this wrap, tmux drops raw kitty graphics escapes; the
            // placeholder still appears (it goes through nvim's redraw path,
            // not /dev/tty) so the cell allocates space but no image lands.
            let mut wrapped = Vec::with_capacity(bytes.len() * 2 + 16);
            wrapped.extend_from_slice(b"\x1bPtmux;");
            for &b in bytes {
                wrapped.push(b);
                if b == 0x1b {
                    wrapped.push(0x1b);
                }
            }
            wrapped.extend_from_slice(b"\x1b\\");
            f.write_all(&wrapped).map_err(|e| anyhow!("tty write: {e}"))?;
        } else {
            f.write_all(bytes).map_err(|e| anyhow!("tty write: {e}"))?;
        }
        f.flush().ok();
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn s(v: Vec<u8>) -> String {
        String::from_utf8(v).unwrap()
    }

    #[test]
    fn open_nonexistent_tty_fails() {
        let r = LocalTty::open(Some(PathBuf::from("/nonexistent/tty")));
        assert!(r.is_err());
    }

    #[test]
    fn transmit_only_no_u_no_cr() {
        let out = s(encode_transmit_only(42, b"\x89PNG"));
        assert!(out.starts_with("\x1b_Ga=t,f=100,i=42,q=2,m=0;"));
        assert!(!out.contains("U=1"));
        assert!(!out.contains("c="));
        assert!(out.ends_with("\x1b\\"));
    }

    #[test]
    fn transmit_virtual_is_data_plus_explicit_placement() {
        let out = s(encode_transmit_virtual(7, b"\x89PNG", 96, 32));
        // data goes as a plain a=t transmit...
        assert!(out.starts_with("\x1b_Ga=t,f=100,i=7,q=2,m=0;"));
        // ...followed by the explicit virtual placement (fixed p=1)
        assert!(out.ends_with("\x1b_Ga=p,U=1,i=7,p=1,c=96,r=32,q=2\x1b\\"));
        // never the anonymous-placement form (those accumulate per frame)
        assert!(!out.contains("a=T"));
    }

    #[test]
    fn place_virtual_clears_then_creates_one_placement() {
        let out = s(encode_place_virtual(7, 48, 16));
        assert_eq!(
            out,
            "\x1b_Ga=d,d=i,i=7,q=2\x1b\\\x1b_Ga=p,U=1,i=7,p=1,c=48,r=16,q=2\x1b\\"
        );
    }

    #[test]
    fn transmit_chunks_large_payload() {
        // 12 KB of zero bytes -> ~16 KB base64 -> 4 chunks (4096 each).
        let big = vec![0u8; 12_000];
        let out = s(encode_transmit_only(1, &big));
        // First chunk starts with a=t..., continuations start with m=...
        assert!(out.starts_with("\x1b_Ga=t,"));
        let continuations = out.matches("\x1b_Gm=").count();
        assert!(continuations >= 2, "expected multi-chunk, got: {}", continuations);
    }

    #[test]
    fn place_includes_id_and_placement() {
        let out = s(encode_place(3, 99, 56, 14));
        assert_eq!(out, "\x1b_Ga=p,i=3,p=99,c=56,r=14,q=2\x1b\\");
    }

    #[test]
    fn place_at_screen_wraps_with_cursor_save_restore() {
        let out = s(encode_place_at_screen(3, 99, 56, 14, 10, 1));
        assert!(out.starts_with("\x1b[s\x1b[10;1H"));
        assert!(out.contains("a=p,i=3,p=99,c=56,r=14,q=2"));
        assert!(out.ends_with("\x1b[u"));
    }

    #[test]
    fn delete_image_targets_id() {
        assert_eq!(
            s(encode_delete_image(7)),
            "\x1b_Ga=d,d=I,i=7,q=2\x1b\\"
        );
    }

    #[test]
    fn delete_image_placement_targets_both() {
        assert_eq!(
            s(encode_delete_image_placement(7, 99)),
            "\x1b_Ga=d,d=I,i=7,p=99,q=2\x1b\\"
        );
    }

    #[test]
    fn delete_all_uses_uppercase_a() {
        assert_eq!(s(encode_delete_all()), "\x1b_Ga=d,d=A,q=2\x1b\\");
    }

    #[test]
    fn delete_visible_uses_lowercase_a() {
        assert_eq!(s(encode_delete_visible()), "\x1b_Ga=d,d=a,q=2\x1b\\");
    }
}
