use anyhow::Result;
use sha2::{Digest as _, Sha256};

/// `Name` half of the Package Family Name. Must match
/// `<Identity Name="…"/>` in `win_files/AppxManifest.xml`.
const PACKAGE_NAME: &str = "Firezone.Client.GUI";

/// Publisher cert Subject DN (canonical form, post-XML-entity-decoding).
/// Must match `<Identity Publisher="…"/>` in
/// `win_files/AppxManifest.xml` after `&quot;` -> `"` decoding.
const PUBLISHER_DN: &str = "CN=\"Firezone, Inc.\", \
    O=\"Firezone, Inc.\", \
    STREET=\"2261 Market Street, Suite 4574\", \
    L=San Francisco, S=California, C=US, \
    OID.1.3.6.1.4.1.311.60.2.1.2=Delaware, \
    OID.1.3.6.1.4.1.311.60.2.1.3=US, \
    SERIALNUMBER=6383880, \
    OID.2.5.4.15=Private Organization";

fn main() -> Result<()> {
    // Skip tauri-build's default Common-Controls manifest: we embed
    // our own SXS / fusion manifest below -- only into `Firezone.exe`,
    // not into the tunnel-service or register-sparse binaries (SCM-
    // launched services with an embedded `<msix>` identity claim
    // hang on startup, and the helper has no use for identity).
    let win = tauri_build::WindowsAttributes::new_without_app_manifest();
    let attr = tauri_build::Attributes::new().windows_attributes(win);
    tauri_build::try_build(attr)?;

    #[cfg(target_os = "windows")]
    {
        embed_resource::compile_for(
            "win_files/Firezone.exe.manifest.rc",
            ["firezone-gui-client"],
            embed_resource::NONE,
        )
        .manifest_required()?;

        println!("cargo:rerun-if-changed=win_files/Firezone.exe.manifest");
        println!("cargo:rerun-if-changed=win_files/Firezone.exe.manifest.rc");
    }

    println!("cargo:rerun-if-changed=../policy-templates/windows/firezone.admx");

    let pfn = format!("{PACKAGE_NAME}_{}", publisher_id(PUBLISHER_DN));
    println!("cargo:rustc-env=FIREZONE_PACKAGE_FAMILY_NAME={pfn}");

    Ok(())
}

/// SHA-256 of the input encoded as UTF-16 LE (no null terminator).
/// Both Windows hashes we compute -- publisher ID and package SID --
/// feed bytes in this encoding to SHA-256.
fn sha256_utf16le(s: &str) -> [u8; 32] {
    let bytes: Vec<u8> = s.encode_utf16().flat_map(u16::to_le_bytes).collect();
    Sha256::digest(&bytes).into()
}

/// Crockford base32 alphabet Windows uses for the publisher ID half
/// of a PFN: digits + lowercase letters minus `i`, `l`, `o`, `u`
/// (visually-confusable chars).
const CROCKFORD: &[u8; 32] = b"0123456789abcdefghjkmnpqrstvwxyz";

/// Encodes a 9-byte (72-bit) buffer as a 13-character Crockford
/// string. The MSB of byte 0 lands in the first output char's high
/// bits; the trailing 7 bits of byte 8 fill out the last char (the
/// 13 * 5 = 65 output bits fit the 72 input bits with 7 to spare).
fn crockford13(input: &[u8; 9]) -> String {
    let mut value: u128 = 0;
    for &b in input {
        value = (value << 8) | u128::from(b);
    }
    let mut out = String::with_capacity(13);
    for i in 0..13 {
        let shift = (12 - i) * 5 + 7;
        let idx = ((value >> shift) & 0x1f) as usize;
        out.push(CROCKFORD[idx] as char);
    }
    out
}

/// The publisher ID is the 13-char Crockford-base32 hash of the
/// publisher's cert Subject DN. Windows requires PFNs in the form
/// `Name_publisherId`, so this is half of the PFN derivation.
fn publisher_id(publisher: &str) -> String {
    let h = sha256_utf16le(publisher);
    let mut buf = [0u8; 9];
    buf[..8].copy_from_slice(&h[..8]);
    crockford13(&buf)
}
