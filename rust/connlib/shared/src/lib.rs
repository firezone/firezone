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

use boringtun::x25519::{PublicKey, StaticSecret};
use messages::Key;
use rand::distributions::Alphanumeric;
use rand::{thread_rng, Rng};
use ring::digest::{Context, SHA256};
use secrecy::{ExposeSecret, SecretString};
use std::net::Ipv4Addr;
use url::Url;

pub const DNS_SENTINEL: Ipv4Addr = Ipv4Addr::new(100, 100, 111, 1);

const VERSION: &str = env!("CARGO_PKG_VERSION");
const LIB_NAME: &str = "connlib";

/// Creates a new login URL to use with the portal.
pub fn login_url(
    mode: Mode,
    portal_url: Url,
    portal_token: SecretString,
    device_id: String,
) -> Result<(Url, StaticSecret)> {
    let private_key = StaticSecret::random_from_rng(rand::rngs::OsRng);
    let name_suffix: String = thread_rng()
        .sample_iter(&Alphanumeric)
        .take(8)
        .map(char::from)
        .collect();
    let external_id = sha256(device_id);

    let url = get_websocket_path(
        portal_url,
        portal_token,
        match mode {
            Mode::Client => "client",
            Mode::Gateway => "gateway",
        },
        &Key(PublicKey::from(&private_key).to_bytes()),
        &external_id,
        &name_suffix,
    )?;

    Ok((url, private_key))
}

// FIXME: This is a terrible name :(
pub enum Mode {
    Client,
    Gateway,
}

pub fn get_user_agent() -> String {
    let info = os_info::get();
    let os_type = info.os_type();
    let os_version = info.version();
    let lib_version = VERSION;
    let lib_name = LIB_NAME;
    format!("{os_type}/{os_version} {lib_name}/{lib_version}")
}

/// Returns the SMBios Serial of the device or a random UUIDv4 if the SMBios is not available.
#[cfg(not(any(target_os = "ios", target_os = "android")))]
pub fn get_device_id() -> String {
    match smbioslib::table_load_from_device() {
        Ok(data) => {
            if let Some(uuid) =
                data.find_map(|sys_info: smbioslib::SMBiosSystemInformation| sys_info.uuid())
            {
                tracing::debug!("get_device_id() found SMBios Serial: {}", uuid);
                return uuid.to_string();
            }
        }
        Err(e) => {
            tracing::warn!("get_device_id() couldn't load SMBios. Error: {}", e);
        }
    }

    tracing::warn!("get_device_id() couldn't find a SMBios Serial. Using random UUIDv4 instead.");
    uuid::Uuid::new_v4().to_string()
}

#[cfg(any(target_os = "ios", target_os = "android"))]
pub fn get_device_id() -> String {
    tracing::warn!(
        "get_device_id() is not implemented for this platform. Using random UUIDv4 instead."
    );

    uuid::Uuid::new_v4().to_string()
}

fn set_ws_scheme(url: &mut Url) -> Result<()> {
    let scheme = match url.scheme() {
        "http" | "ws" => "ws",
        "https" | "wss" => "wss",
        _ => return Err(Error::UriScheme),
    };
    url.set_scheme(scheme)
        .expect("Developer error: the match before this should make sure we can set this");
    Ok(())
}

fn sha256(input: String) -> String {
    let mut ctx = Context::new(&SHA256);
    ctx.update(input.as_bytes());
    let digest = ctx.finish();

    digest.as_ref().iter().fold(String::new(), |mut output, b| {
        use std::fmt::Write;

        let _ = write!(output, "{b:02x}");
        output
    })
}

fn get_websocket_path(
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
