//! A fake libjupynvim that misses symbols, for the loader tests. Standalone:
//! it never links the real library. It exports only `jnv_abi_version`
//! (ABI 1.1) and `jnv_version` (the package version), so a loader that
//! checks the version first and resolves the other functions second must
//! still refuse it.

use std::ffi::c_char;

#[no_mangle]
pub extern "C" fn jnv_abi_version() -> u32 {
    (1 << 16) | 1
}

#[no_mangle]
pub extern "C" fn jnv_version() -> *const c_char {
    concat!(env!("CARGO_PKG_VERSION"), "\0").as_ptr() as *const c_char
}
