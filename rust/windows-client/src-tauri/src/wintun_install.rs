//! "Installs" wintun.dll at runtime by copying it into whatever folder the exe is in

pub(crate) struct _DllBytes {
    /// Bytes embedded in the client with `include_bytes`
    bytes: &'static [u8],
    /// Expected SHA256 hash
    expected_sha256: &'static str,
}

/// Returns the platform-specific bytes of wintun.dll, or None if we don't support the compiled platform.
pub(crate) fn _get_dll_bytes() -> Option<_DllBytes> {
    _get_platform_dll_bytes()
}

#[cfg(target_arch = "x86_64")]
fn _get_platform_dll_bytes() -> Option<_DllBytes> {
    // SHA256 e5da8447dc2c320edc0fc52fa01885c103de8c118481f683643cacc3220dafce
    Some(_DllBytes {
        bytes: include_bytes!("../../wintun/bin/amd64/wintun.dll"),
        expected_sha256: "e5da8447dc2c320edc0fc52fa01885c103de8c118481f683643cacc3220dafce",
    })
}

#[cfg(target_arch = "aarch64")]
fn _get_platform_dll_bytes() -> Option<&'static [u8]> {
    // wintun supports aarch64 but it's not in the Firezone repo yet
    None
}
