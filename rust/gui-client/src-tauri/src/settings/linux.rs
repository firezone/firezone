use super::MdmSettings;
use anyhow::Result;

/// The environment variable a root-owned systemd drop-in sets to list the applications that may use the tunnel.
const ALLOWED_APPLICATIONS_ENV: &str = "FIREZONE_ALLOWED_APPLICATIONS";

/// Linux has no MDM channel yet; only the application filter can be set, through the service environment.
#[expect(clippy::unnecessary_wraps, reason = "Signature must match Windows")]
pub fn load_mdm_settings() -> Result<MdmSettings> {
    Ok(MdmSettings {
        allowed_applications: std::env::var(ALLOWED_APPLICATIONS_ENV).ok(),
        ..MdmSettings::default()
    })
}
