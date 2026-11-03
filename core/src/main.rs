// jupynvim-core — Jupyter notebook backend for Neovim
//
// Speaks msgpack-rpc over stdio to the Lua frontend.
// Speaks Jupyter wire protocol (ZMQ + HMAC-SHA256) to kernels.
// Owns .ipynb parsing/writing.

use anyhow::Result;
use std::ffi::OsString;
use std::path::PathBuf;
use std::time::Duration;
use tracing_subscriber::EnvFilter;

mod connfile;
mod guard;
mod kernel;
mod kernelspec;
mod kitty;
mod notebook;
mod protocol;
mod rpc;
mod session;
mod widgets;
mod writes;

fn main() -> Result<()> {
    let args: Vec<OsString> = std::env::args_os().collect();
    // `--version` prints the version and exits (used by the frontend to verify
    // a deployed remote binary). Must short-circuit before the stdio server.
    if args.iter().skip(1).any(|a| a == "--version" || a == "-V") {
        println!("jupynvim-core {}", env!("CARGO_PKG_VERSION"));
        return Ok(());
    }
    // The kernel guard process (guard.rs): no runtime, no logging setup.
    if args.get(1).is_some_and(|a| a == "--guard") {
        return guard::run(&args[2..]);
    }

    let rt = tokio::runtime::Builder::new_multi_thread().enable_all().build()?;
    let result = rt.block_on(serve());
    // A notebook save, file write or file removal still running is finished
    // first, so no file is left cut short; none starts from now on.
    finish_writes(WRITE_WAIT);
    // Every cleanup has run inside run_stdio by now. A thread blocked in a
    // read of stdin (still open after SIGTERM or SIGHUP) can never end by
    // itself, so the exit waits for the runtime's threads only briefly.
    rt.shutdown_timeout(Duration::from_millis(200));
    result
}

/// How long the exit waits for notebook saves and file changes still running.
const WRITE_WAIT: Duration = Duration::from_secs(10);

/// Waits, up to `limit`, for the notebook saves and file changes still
/// running (writes.rs), and logs what it waited for.
fn finish_writes(limit: Duration) {
    let t = std::time::Instant::now();
    let left = writes::close(limit);
    if left > 0 {
        tracing::warn!("exit: {left} file write(s) still running after {} s; exiting anyway", limit.as_secs());
    } else if t.elapsed() >= Duration::from_millis(1) {
        tracing::info!("exit: waited {} ms for a file write to finish", t.elapsed().as_millis());
    }
}

async fn serve() -> Result<()> {
    init_logging()?;
    tracing::info!("jupynvim-core starting (v{})", env!("CARGO_PKG_VERSION"));

    let server = rpc::Server::new();
    server.run_stdio().await?;

    tracing::info!("jupynvim-core exiting cleanly");
    Ok(())
}

/// Directory for core.log: $JUPYNVIM_LOG_DIR when set and not empty, else
/// the platform cache dir plus "jupynvim", else the temp dir plus "jupynvim".
pub(crate) fn log_dir(env_dir: Option<std::ffi::OsString>) -> PathBuf {
    match env_dir {
        Some(d) if !d.is_empty() => PathBuf::from(d),
        _ => dirs::cache_dir().unwrap_or_else(std::env::temp_dir).join("jupynvim"),
    }
}

fn init_logging() -> Result<()> {
    let log_dir = log_dir(std::env::var_os("JUPYNVIM_LOG_DIR"));
    std::fs::create_dir_all(&log_dir)?;

    let file_appender = tracing_appender::rolling::never(&log_dir, "core.log");
    let env = EnvFilter::try_from_env("JUPYNVIM_LOG").unwrap_or_else(|_| EnvFilter::new("info"));

    tracing_subscriber::fmt()
        .with_env_filter(env)
        .with_writer(file_appender)
        .with_ansi(false)
        .with_target(true)
        .with_thread_ids(false)
        .init();

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::{OsStr, OsString};

    #[test]
    fn log_dir_uses_the_env_dir() {
        assert_eq!(log_dir(Some(OsString::from("/x/y"))), PathBuf::from("/x/y"));
    }

    #[test]
    fn log_dir_ignores_an_empty_env_dir() {
        assert_eq!(log_dir(Some(OsString::new())), log_dir(None));
    }

    #[test]
    fn log_dir_default_ends_in_jupynvim() {
        let d = log_dir(None);
        assert_eq!(d.file_name(), Some(OsStr::new("jupynvim")));
        assert!(d.is_absolute(), "default log dir is relative: {}", d.display());
    }
}
