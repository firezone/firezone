//! This crates contains shared types and behavior between all the other libraries.
//!
//! This includes types provided by external crates, i.e. [boringtun] to make sure that
//! we are using the same version across our own crates.

use ring::digest::{Context, SHA256};
pub mod error;

mod session;

pub mod control;
pub mod messages;

pub use error::ConnlibError as Error;
pub use error::Result;

pub use session::{CallbackErrorFacade, Callbacks, ControlSession, Session, DNS_SENTINEL};

const VERSION: &str = env!("CARGO_PKG_VERSION");
const LIB_NAME: &str = "connlib";

pub fn get_user_agent() -> String {
    let info = os_info::get();
    let os_type = info.os_type();
    let os_version = info.version();
    let lib_version = VERSION;
    let lib_name = LIB_NAME;
    format!("{os_type}/{os_version} {lib_name}/{lib_version}")
}

/// normalized to a SHA256-hashed
/// string.
pub fn get_external_id() -> String {
    let device_id = device_id();
    tracing::debug!("device_id: {}", device_id);

    let mut ctx = Context::new(&SHA256);
    ctx.update(device_id.as_bytes());
    let digest = ctx.finish();

    let external_id = digest
        .as_ref()
        .iter()
        .map(|b| format!("{:02x}", b))
        .collect();
    tracing::debug!("external_id: {}", external_id);

    external_id
}

/// Returns the SMBios Serial of the device or a random UUIDv4
fn device_id() -> String {
    // smbios fails to build on mobile, but it works for other platforms.
    #[cfg(not(any(target_os = "ios", target_os = "android")))]
    match smbioslib::table_load_from_device() {
        Ok(data) => {
            match data.find_map(|sys_info: smbioslib::SMBiosSystemInformation| sys_info.uuid()) {
                Some(uuid) => uuid.to_string(),
                None => uuid::Uuid::new_v4().to_string(),
            }
        }
        Err(_err) => uuid::Uuid::new_v4().to_string(),
    }

    #[cfg(any(target_os = "ios", target_os = "android"))]
    {
        tracing::debug!("smbios is not supported on iOS and Android, using random UUIDv4");
        uuid::Uuid::new_v4().to_string()
    }
}
