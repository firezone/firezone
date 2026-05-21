use anyhow::{Context, Result, anyhow};
use sha2::{Digest, Sha256};

fn main() -> Result<()> {
    let win = tauri_build::WindowsAttributes::new();
    let attr = tauri_build::Attributes::new().windows_attributes(win);
    tauri_build::try_build(attr)?;

    println!("cargo:rerun-if-changed=../website/public/policy-templates/windows/firezone.admx");
    println!("cargo:rerun-if-changed=win_files/AppxManifest.xml");

    emit_package_family_name_env()?;

    Ok(())
}

/// Reads the sparse MSIX manifest, derives the resulting Package
/// Family Name (`{Identity.Name}_{Crockford13(SHA256(Identity.Publisher))}`)
/// and emits it as `cargo:rustc-env` so `PACKAGE_FAMILY_NAME` in
/// `src/lib.rs` is baked into the binary at compile time.
///
/// `register-sparse.exe` needs the PFN at runtime to call
/// `ProvisionPackageForAllUsersAsync` *before* the package is
/// registered (i.e., before `GetCurrentPackageFamilyName` can
/// answer), so the PFN has to come from somewhere static. Post-
/// registration, callers that need the package SID call
/// `windows_security::pipe_dacl::Trustee::current_package()`, which
/// reads the kernel-attached PFN and hashes it the same way Windows
/// does — that's the authoritative path; this is just a bootstrap.
fn emit_package_family_name_env() -> Result<()> {
    let manifest = std::fs::read_to_string("win_files/AppxManifest.xml")
        .context("Failed to read win_files/AppxManifest.xml")?;

    let publisher = extract_attr(&manifest, "Identity", "Publisher")
        .context("Failed to extract Identity.Publisher from AppxManifest.xml")?;
    let name = extract_attr(&manifest, "Identity", "Name")
        .context("Failed to extract Identity.Name from AppxManifest.xml")?;

    let pfn = format!("{name}_{}", publisher_id(&publisher));
    println!("cargo:rustc-env=FIREZONE_PACKAGE_FAMILY_NAME={pfn}");

    Ok(())
}

/// Tiny attribute extractor for our hand-controlled `AppxManifest.xml`.
///
/// Not a general-purpose XML parser — it just locates the named element
/// tag and pulls out the requested attribute value, decoding the four
/// XML entities Microsoft permits in `Identity.Publisher`.
fn extract_attr(xml: &str, element: &str, attr: &str) -> Result<String> {
    let needle = format!("<{element}");
    let elem_start = xml
        .find(&needle)
        .ok_or_else(|| anyhow!("Element `<{element}` not found in manifest"))?;
    let elem_end = xml[elem_start..]
        .find('>')
        .ok_or_else(|| anyhow!("Element `<{element}` is unterminated"))?
        + elem_start;
    let elem = &xml[elem_start..elem_end];

    let attr_needle = format!("{attr}=\"");
    let attr_value_start = elem
        .find(&attr_needle)
        .ok_or_else(|| anyhow!("Attribute `{attr}` not found on `<{element}`"))?
        + attr_needle.len();
    let attr_value_end = elem[attr_value_start..]
        .find('"')
        .ok_or_else(|| anyhow!("Attribute `{attr}` value is unterminated"))?
        + attr_value_start;

    let raw = &elem[attr_value_start..attr_value_end];
    Ok(decode_xml_entities(raw))
}

fn decode_xml_entities(s: &str) -> String {
    s.replace("&quot;", "\"")
        .replace("&apos;", "'")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&amp;", "&")
}

/// SHA-256 of the UTF-16LE encoding of `s`, with no BOM and no NUL terminator.
fn sha256_utf16le(s: &str) -> [u8; 32] {
    let utf16: Vec<u8> = s.encode_utf16().flat_map(u16::to_le_bytes).collect();
    Sha256::digest(&utf16).into()
}

/// Crockford-base32 encodes the high 65 bits of the 9-byte input as 13
/// lowercase ASCII characters. The 9th input byte is a 0x00 pad that
/// shifts the 64-bit hash prefix into a 72-bit field, of which the top
/// 65 bits are emitted across the 13 characters (5 bits each, MSB first).
///
/// Microsoft's package-publisher-id algorithm uses this exact form.
fn crockford13(input: &[u8; 9]) -> String {
    const ALPHABET: &[u8; 32] = b"0123456789abcdefghjkmnpqrstvwxyz";

    let mut bits: u128 = 0;
    for b in input {
        bits = (bits << 8) | (*b as u128);
    }

    let mut out = [0u8; 13];
    for (i, slot) in out.iter_mut().enumerate() {
        let shift = (12 - i) * 5 + 7;
        *slot = ALPHABET[((bits >> shift) & 0x1f) as usize];
    }
    String::from_utf8(out.to_vec()).expect("Crockford alphabet is ASCII")
}

/// Derives the 13-character publisher hash that follows the underscore
/// in a Package Family Name (e.g. `8wekyb3d8bbwe` for Microsoft).
fn publisher_id(publisher: &str) -> String {
    let h = sha256_utf16le(publisher);
    let mut buf = [0u8; 9];
    buf[..8].copy_from_slice(&h[..8]);
    crockford13(&buf)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Microsoft's well-known publisher hash, used as the canonical
    /// test vector. If this regresses, the algorithm is wrong.
    #[test]
    fn microsoft_publisher_id() {
        assert_eq!(
            publisher_id(
                "CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US"
            ),
            "8wekyb3d8bbwe",
        );
    }

    #[test]
    fn extract_attr_decodes_entities() {
        let xml = r#"<Identity Name="X" Publisher="CN=&quot;A, B&quot;"/>"#;
        assert_eq!(
            extract_attr(xml, "Identity", "Publisher").unwrap(),
            "CN=\"A, B\"",
        );
    }
}
