use super::MdmSettings;
use anyhow::Result;

pub fn load_mdm_settings() -> Result<MdmSettings> {
    Ok(MdmSettings::default())
}
