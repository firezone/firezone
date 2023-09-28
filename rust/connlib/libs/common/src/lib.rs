//! This crates contains shared types and behavior between all the other libraries.
//!
//! This includes types provided by external crates, i.e. [boringtun] to make sure that
//! we are using the same version across our own crates.

mod callbacks;
mod callbacks_error_facade;
pub mod control;
pub mod error;
pub mod messages;

pub use callbacks::Callbacks;
pub use callbacks_error_facade::CallbackErrorFacade;
pub use error::ConnlibError as Error;
pub use error::Result;

use messages::Key;
use ring::digest::{Context, SHA256};
use secrecy::{ExposeSecret, SecretString};
use std::net::Ipv4Addr;
use url::Url;

pub const DNS_SENTINEL: Ipv4Addr = Ipv4Addr::new(100, 100, 111, 1);

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

/// Returns the SMBios Serial of the device or a random UUIDv4 if the SMBios is not available.
pub fn get_device_id() -> String {
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

pub fn set_ws_scheme(url: &mut Url) -> Result<()> {
    let scheme = match url.scheme() {
        "http" | "ws" => "ws",
        "https" | "wss" => "wss",
        _ => return Err(Error::UriScheme),
    };
    url.set_scheme(scheme)
        .expect("Developer error: the match before this should make sure we can set this");
    Ok(())
}

pub fn sha256(input: String) -> String {
    let mut ctx = Context::new(&SHA256);
    ctx.update(input.as_bytes());
    let digest = ctx.finish();

    digest
        .as_ref()
        .iter()
        .map(|b| format!("{:02x}", b))
        .collect()
}

pub fn get_websocket_path(
    mut url: Url,
    secret: SecretString,
    mode: &str,
    public_key: &Key,
    external_id: &str,
    name_suffix: &str,
) -> Result<Url> {
    set_ws_scheme(&mut url)?;

    {
        let mut paths = url.path_segments_mut().map_err(|_| Error::UriError)?;
        paths.pop_if_empty();
        paths.push(mode);
        paths.push("websocket");
    }

    {
        let mut query_pairs = url.query_pairs_mut();
        query_pairs.clear();
        query_pairs.append_pair("token", secret.expose_secret());
        query_pairs.append_pair("public_key", &public_key.to_string());
        query_pairs.append_pair("external_id", external_id);
        query_pairs.append_pair("name_suffix", name_suffix);
    }

    Ok(url)
}
