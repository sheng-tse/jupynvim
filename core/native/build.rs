//! Link flags of the library, chosen by the target's OS (never the host's,
//! so cross builds get the target's flags). They reach the library target
//! only: Cargo passes `rustc-cdylib-link-arg` to this package's cdylib and
//! not to the example fakes, which keep their own names.
//!
//! macOS: the install name is `@rpath/libjupynvim.dylib` instead of the
//! absolute path of the build tree.
//! Linux and the BSDs: the soname is `libjupynvim.so`, and `-z nodelete`
//! keeps the library mapped for the life of the process, so no `dlclose`
//! can unmap code a worker thread is running.

fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    let os = std::env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
    match os.as_str() {
        "macos" => {
            println!("cargo:rustc-cdylib-link-arg=-Wl,-install_name,@rpath/libjupynvim.dylib");
        }
        "linux" | "freebsd" | "netbsd" | "openbsd" | "dragonfly" => {
            println!("cargo:rustc-cdylib-link-arg=-Wl,-soname,libjupynvim.so");
            println!("cargo:rustc-cdylib-link-arg=-Wl,-z,nodelete");
        }
        _ => {}
    }
}
