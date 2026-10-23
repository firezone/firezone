use super::MdmSettings;
use anyhow::Result;

#[expect(clippy::unnecessary_wraps, reason = "Signature must match Windows")]
pub fn load_mdm_settings() -> Result<MdmSettings> {
    Ok(MdmSettings::default())
}
