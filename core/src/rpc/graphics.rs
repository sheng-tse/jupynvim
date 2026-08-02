//! Kitty graphics RPCs.

use anyhow::{anyhow, Result};
use base64::Engine as _;
use serde_json::{json, Value as Json};
use std::path::PathBuf;

use super::Server;
use crate::kitty::{self, KittyMode, LocalTty};

impl Server {
    /// Tell the backend how kitty escapes should reach the user's terminal.
    /// `{ tty: "/dev/tty" }` (or no params) = local mode: backend writes
    /// directly to that TTY. `{ remote: true }` = remote mode: backend
    /// encodes escapes but returns them via RPC for the frontend to write
    /// to its own local /dev/tty. Frontend calls this once at startup.
    pub(super) async fn kitty_attach(&self, p: Json) -> Result<Json> {
        let remote = p.get("remote").and_then(|v| v.as_bool()).unwrap_or(false);
        let mode = if remote {
            KittyMode::Remote
        } else {
            let path = p.get("tty").and_then(|v| v.as_str()).map(PathBuf::from);
            KittyMode::Local(LocalTty::open(path)?)
        };
        *self.kitty.lock().await = Some(mode);
        Ok(json!({ "ok": true, "remote": remote }))
    }

    /// Emit encoded kitty bytes: write to TTY in local mode, or return as
    /// `escape_b64` in remote mode. `base_response` is merged with the result.
    pub(super) async fn emit_kitty(&self, bytes: Vec<u8>, mut base_response: serde_json::Map<String, Json>) -> Result<Json> {
        let kitty_lock = self.kitty.lock().await;
        match kitty_lock.as_ref() {
            None => Err(anyhow!("kitty_attach not called")),
            Some(KittyMode::Local(t)) => {
                t.write(&bytes)?;
                Ok(Json::Object(base_response))
            }
            Some(KittyMode::Remote) => {
                let escape_b64 = base64::engine::general_purpose::STANDARD.encode(&bytes);
                base_response.insert("escape_b64".into(), Json::String(escape_b64));
                Ok(Json::Object(base_response))
            }
        }
    }

    /// `a=t`: transmit only, no placement. Used for direct-placement
    /// renderer + GIF frame retransmits. Requires `image_id` (frontend-owned).
    pub(super) async fn kitty_transmit_only(&self, p: Json) -> Result<Json> {
        let b64 = p.get("png_b64").and_then(|v| v.as_str())
            .ok_or_else(|| anyhow!("png_b64 required"))?;
        let id = p.get("image_id").and_then(|v| v.as_u64())
            .ok_or_else(|| anyhow!("image_id required"))? as u32;
        let png = base64::engine::general_purpose::STANDARD.decode(b64)
            .map_err(|e| anyhow!("base64 decode: {e}"))?;
        let bytes = kitty::encode_transmit_only(id, &png);
        let mut base = serde_json::Map::new();
        base.insert("image_id".into(), json!(id));
        self.emit_kitty(bytes, base).await
    }

    /// `a=T, U=1`: transmit + register for Unicode-placeholder placement.
    /// Requires `image_id`, `cols`, `rows`.
    pub(super) async fn kitty_transmit_virtual(&self, p: Json) -> Result<Json> {
        let b64 = p.get("png_b64").and_then(|v| v.as_str())
            .ok_or_else(|| anyhow!("png_b64 required"))?;
        let id = p.get("image_id").and_then(|v| v.as_u64())
            .ok_or_else(|| anyhow!("image_id required"))? as u32;
        let cols = p.get("cols").and_then(|v| v.as_u64())
            .ok_or_else(|| anyhow!("cols required"))? as u32;
        let rows = p.get("rows").and_then(|v| v.as_u64())
            .ok_or_else(|| anyhow!("rows required"))? as u32;
        let png = base64::engine::general_purpose::STANDARD.decode(b64)
            .map_err(|e| anyhow!("base64 decode: {e}"))?;
        let bytes = kitty::encode_transmit_virtual(id, &png, cols, rows);
        let mut base = serde_json::Map::new();
        base.insert("image_id".into(), json!(id));
        self.emit_kitty(bytes, base).await
    }

    /// Re-assert the explicit virtual placement for an already-transmitted
    /// image (`a=d,d=i` then `a=p,U=1,p=1`). No image data moves; heals
    /// placements lost to deletes or left accumulated as anonymous internals.
    pub(super) async fn kitty_place_virtual(&self, p: Json) -> Result<Json> {
        let image_id = p.get("image_id").and_then(|v| v.as_u64())
            .ok_or_else(|| anyhow!("image_id required"))? as u32;
        let cols = p.get("cols").and_then(|v| v.as_u64())
            .ok_or_else(|| anyhow!("cols required"))? as u32;
        let rows = p.get("rows").and_then(|v| v.as_u64())
            .ok_or_else(|| anyhow!("rows required"))? as u32;
        let bytes = kitty::encode_place_virtual(image_id, cols, rows);
        self.emit_kitty(bytes, serde_json::Map::new()).await
    }

    /// `a=p`: place an already-transmitted image. If `screen_row` and
    /// `screen_col` are provided, wraps with cursor save/move/restore so the
    /// place is atomic (no interleave with other terminal output).
    pub(super) async fn kitty_place(&self, p: Json) -> Result<Json> {
        let image_id = p.get("image_id").and_then(|v| v.as_u64())
            .ok_or_else(|| anyhow!("image_id required"))? as u32;
        let placement_id = p.get("placement_id").and_then(|v| v.as_u64())
            .ok_or_else(|| anyhow!("placement_id required"))? as u32;
        let cols = p.get("cols").and_then(|v| v.as_u64())
            .ok_or_else(|| anyhow!("cols required"))? as u32;
        let rows = p.get("rows").and_then(|v| v.as_u64())
            .ok_or_else(|| anyhow!("rows required"))? as u32;
        let screen_row = p.get("screen_row").and_then(|v| v.as_u64()).map(|n| n as u32);
        let screen_col = p.get("screen_col").and_then(|v| v.as_u64()).map(|n| n as u32);
        let bytes = match (screen_row, screen_col) {
            (Some(r), Some(c)) => kitty::encode_place_at_screen(image_id, placement_id, cols, rows, r, c),
            _ => kitty::encode_place(image_id, placement_id, cols, rows),
        };
        self.emit_kitty(bytes, serde_json::Map::new()).await
    }

    /// `a=d, d=I`: delete image (and its placements). If `placement_id` is
    /// also given, delete only that placement (image data stays).
    pub(super) async fn kitty_clear_image(&self, p: Json) -> Result<Json> {
        let image_id = p.get("image_id").and_then(|v| v.as_u64())
            .ok_or_else(|| anyhow!("image_id required"))? as u32;
        let bytes = match p.get("placement_id").and_then(|v| v.as_u64()) {
            Some(pid) => kitty::encode_delete_image_placement(image_id, pid as u32),
            None => kitty::encode_delete_image(image_id),
        };
        self.emit_kitty(bytes, serde_json::Map::new()).await
    }

    /// `a=d, d=a` (lowercase): clear visible placements only; image data stays.
    pub(super) async fn kitty_clear_visible(&self, _p: Json) -> Result<Json> {
        let bytes = kitty::encode_delete_visible();
        self.emit_kitty(bytes, serde_json::Map::new()).await
    }

    /// `a=d, d=A` (uppercase): nuke all images and placements.
    pub(super) async fn kitty_clear_all(&self, _p: Json) -> Result<Json> {
        let bytes = kitty::encode_delete_all();
        self.emit_kitty(bytes, serde_json::Map::new()).await
    }

    // ===========================================================
    // Filesystem RPCs (Phase 1 of v0.3 remote-workspace effort).
    //
    // All paths are absolute on the remote filesystem; the leading `~/` is
    // expanded to the server-process's $HOME. File contents are base64
    // (msgpack-safe binary transport — same trick we use for PNGs).
    // ===========================================================
}
