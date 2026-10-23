use super::MdmSettings;
use anyhow::Result;

/// Linux has no MDM channel yet; return defaults so the connection isn't
/// noisy with warn-level "Unimplemented" failures on every Hello.
#[expect(clippy::unnecessary_wraps, reason = "Signature must match Windows")]
pub fn load_mdm_settings() -> Result<MdmSettings> {
    Ok(MdmSettings::default())
}
