//! This crates contains shared types and behavior between all the other libraries.
//!
//! This includes types provided by external crates, i.e. [boringtun] to make sure that
//! we are using the same version across our own crates.

mod callbacks;
mod callbacks_error_facade;
pub mod control;
pub mod error;
pub mod messages;

/// Module to generate and store a persistent device ID on disk
///
/// Only properly implemented on Linux and Windows (platforms with Tauri and headless client)
pub mod device_id;

// Must be compiled on Mac so the Mac runner can do `version-check` on `linux-client`
pub mod linux;

#[cfg(target_os = "windows")]
pub mod windows;

pub use callbacks::Callbacks;
pub use callbacks_error_facade::CallbackErrorFacade;
pub use error::ConnlibError as Error;
pub use error::Result;

use boringtun::x25519::PublicKey;
use boringtun::x25519::StaticSecret;
use ip_network::Ipv4Network;
use ip_network::Ipv6Network;
use messages::Key;
use ring::digest::{Context, SHA256};
use secrecy::Secret;
use secrecy::{ExposeSecret, SecretString};
use std::net::IpAddr;
use std::net::Ipv4Addr;
use std::net::Ipv6Addr;
use url::Url;
use uuid::Uuid;

pub type Dname = domain::base::Dname<Vec<u8>>;

/// Bundle ID / App ID that the client uses to distinguish itself from other programs on the system
///
/// e.g. In ProgramData and AppData we use this to name our subdirectories for configs and data,
/// and Windows may use it to track things like the MSI installer, notification titles,
/// deep link registration, etc.
///
/// This should be identical to the `tauri.bundle.identifier` over in `tauri.conf.json`,
/// but sometimes I need to use this before Tauri has booted up, or in a place where
/// getting the Tauri app handle would be awkward.
///
/// Luckily this is also the AppUserModelId that Windows uses to label notifications,
/// so if your dev system has Firezone installed by MSI, the notifications will look right.
/// <https://learn.microsoft.com/en-us/windows/configuration/find-the-application-user-model-id-of-an-installed-app>
pub const BUNDLE_ID: &str = "dev.firezone.client";

const VERSION: &str = env!("CARGO_PKG_VERSION");
const LIB_NAME: &str = "connlib";

// From https://man7.org/linux/man-pages/man2/gethostname.2.html
// SUSv2 guarantees that "Host names are limited to 255 bytes".
// POSIX.1 guarantees that "Host names (not including the
// terminating null byte) are limited to HOST_NAME_MAX bytes".  On
// Linux, HOST_NAME_MAX is defined with the value 64, which has been
// the limit since Linux 1.0 (earlier kernels imposed a limit of 8
// bytes)
//
// We are counting the nul-byte
#[cfg(not(target_os = "windows"))]
const HOST_NAME_MAX: usize = 256;

pub struct LoginUrl {
    url: Url,
    private_key: StaticSecret,
}

impl LoginUrl {
    pub fn client<E>(
        url: impl TryInto<Url, Error = E>,
        firezone_token: SecretString,
        device_id: String,
        device_name: Option<String>,
    ) -> std::result::Result<Self, LoginUrlError<E>> {
        let private_key = StaticSecret::random_from_rng(rand::rngs::OsRng);

        let external_id = sha256(device_id);
        let device_name = device_name
            .or(get_host_name())
            .unwrap_or_else(|| Uuid::new_v4().to_string());

        let url = get_websocket_path(
            url.try_into().map_err(LoginUrlError::InvalidUrl)?,
            firezone_token,
            "client",
            &Key(PublicKey::from(&private_key).to_bytes()),
            &external_id,
            &device_name,
        )?;

        Ok(LoginUrl { url, private_key })
    }

    pub fn gateway<E>(
        url: impl TryInto<Url, Error = E>,
        firezone_token: SecretString,
        device_id: String,
        device_name: Option<String>,
    ) -> std::result::Result<Self, LoginUrlError<E>> {
        let private_key = StaticSecret::random_from_rng(rand::rngs::OsRng);

        let external_id = sha256(device_id);
        let device_name = device_name
            .or(get_host_name())
            .unwrap_or_else(|| Uuid::new_v4().to_string());

        let url = get_websocket_path(
            url.try_into().map_err(LoginUrlError::InvalidUrl)?,
            firezone_token,
            "gateway",
            &Key(PublicKey::from(&private_key).to_bytes()),
            &external_id,
            &device_name,
        )?;

        Ok(LoginUrl { url, private_key })
    }

    pub fn url(&self) -> SecretString {
        Secret::new(self.url.to_string())
    }

    pub fn private_key(&self) -> StaticSecret {
        self.private_key.clone()
    }
}

#[derive(Debug, thiserror::Error)]
pub enum LoginUrlError<E> {
    #[error("invalid scheme `{0}`; only http(s) and ws(s) are allowed")]
    InvalidUrlScheme(String),
    #[error("failed to parse URL: {0}")]
    InvalidUrl(E),
}

pub struct IpProvider {
    ipv4: Box<dyn Iterator<Item = Ipv4Addr> + Send + Sync>,
    ipv6: Box<dyn Iterator<Item = Ipv6Addr> + Send + Sync>,
}

impl IpProvider {
    pub fn new(ipv4: Ipv4Network, ipv6: Ipv6Network) -> Self {
        Self {
            ipv4: Box::new(ipv4.hosts()),
            ipv6: Box::new(ipv6.subnets_with_prefix(128).map(|ip| ip.network_address())),
        }
    }

    pub fn get_proxy_ip_for(&mut self, ip: &IpAddr) -> Option<IpAddr> {
        let proxy_ip = match ip {
            IpAddr::V4(_) => self.ipv4.next().map(Into::into),
            IpAddr::V6(_) => self.ipv6.next().map(Into::into),
        };

        if proxy_ip.is_none() {
            // TODO: we might want to make the iterator cyclic or another strategy to prevent ip exhaustion
            // this might happen in ipv4 if tokens are too long lived.
            tracing::error!("IP exhaustion: Please reset your client");
        }

        proxy_ip
    }
}

pub fn get_user_agent(os_version_override: Option<String>) -> String {
    // Note: we could switch to sys-info and get the hostname
    // but we lose the arch
    // and neither of the libraries provide the kernel version.
    // so I rather keep os_info which seems like the most popular
    // and keep implementing things that we are missing on top
    let info = os_info::get();

    // iOS returns "Unknown", but we already know we're on iOS here
    #[cfg(target_os = "ios")]
    let os_type = "iOS";
    #[cfg(not(target_os = "ios"))]
    let os_type = info.os_type();

    let os_version = os_version_override.unwrap_or(info.version().to_string());
    let additional_info = additional_info();
    let lib_version = VERSION;
    let lib_name = LIB_NAME;
    format!("{os_type}/{os_version}{additional_info}{lib_name}/{lib_version}")
}

fn additional_info() -> String {
    let info = os_info::get();
    match (info.architecture(), kernel_version()) {
        (None, None) => " ".to_string(),
        (None, Some(k)) => format!(" {k} "),
        (Some(a), None) => format!(" {a} "),
        (Some(a), Some(k)) => format!(" ({a};{k};) "),
    }
}

#[cfg(not(target_family = "unix"))]
fn kernel_version() -> Option<String> {
    None
}

#[cfg(target_family = "unix")]
fn kernel_version() -> Option<String> {
    #[cfg(any(target_os = "android", target_os = "linux"))]
    let mut utsname = libc::utsname {
        sysname: [0; 65],
        nodename: [0; 65],
        release: [0; 65],
        version: [0; 65],
        machine: [0; 65],
        domainname: [0; 65],
    };

    #[cfg(any(target_os = "macos", target_os = "ios"))]
    let mut utsname = libc::utsname {
        sysname: [0; 256],
        nodename: [0; 256],
        release: [0; 256],
        version: [0; 256],
        machine: [0; 256],
    };

    // SAFETY: we just allocated the pointer
    if unsafe { libc::uname(&mut utsname as *mut _) } != 0 {
        return None;
    }

    #[cfg_attr(
        all(target_os = "linux", target_arch = "aarch64"),
        allow(clippy::unnecessary_cast)
    )]
    let version: Vec<u8> = utsname
        .release
        .split(|c| *c == 0)
        .next()?
        .iter()
        .map(|x| *x as u8)
        .collect();

    String::from_utf8(version).ok()
}

#[cfg(not(target_os = "windows"))]
fn get_host_name() -> Option<String> {
    let mut buf = [0; HOST_NAME_MAX];
    // SAFETY: we just allocated a buffer with that size
    if unsafe { libc::gethostname(buf.as_mut_ptr() as *mut _, HOST_NAME_MAX) } != 0 {
        return None;
    }

    String::from_utf8(buf.split(|c| *c == 0).next()?.to_vec()).ok()
}

/// Returns the hostname, or `None` if it's not valid UTF-8
#[cfg(target_os = "windows")]
fn get_host_name() -> Option<String> {
    hostname::get().ok().and_then(|x| x.into_string().ok())
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

fn get_websocket_path<E>(
    mut api_url: Url,
    secret: SecretString,
    mode: &str,
    public_key: &Key,
    external_id: &str,
    name: &str,
) -> std::result::Result<Url, LoginUrlError<E>> {
    set_ws_scheme(&mut api_url)?;

    {
        let mut paths = api_url
            .path_segments_mut()
            .expect("scheme guarantees valid URL");

        paths.pop_if_empty();
        paths.push(mode);
        paths.push("websocket");
    }

    {
        let mut query_pairs = api_url.query_pairs_mut();
        query_pairs.clear();
        query_pairs.append_pair("token", secret.expose_secret());
        query_pairs.append_pair("public_key", &public_key.to_string());
        query_pairs.append_pair("external_id", external_id);
        query_pairs.append_pair("name", name);
    }

    Ok(api_url)
}

fn set_ws_scheme<E>(url: &mut Url) -> std::result::Result<(), LoginUrlError<E>> {
    let scheme = match url.scheme() {
        "http" | "ws" => "ws",
        "https" | "wss" => "wss",
        other => return Err(LoginUrlError::InvalidUrlScheme(other.to_owned())),
    };

    url.set_scheme(scheme)
        .expect("Developer error: the match before this should make sure we can set this");

    Ok(())
}
