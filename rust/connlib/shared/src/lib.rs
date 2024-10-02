//! This crates contains shared types and behavior between all the other libraries.
//!
//! This includes types provided by external crates, i.e. [boringtun] to make sure that
//! we are using the same version across our own crates.

mod view;

pub use boringtun::x25519::PublicKey;
pub use boringtun::x25519::StaticSecret;
pub use phoenix_channel::{LoginUrl, LoginUrlError};
pub use view::{
    CidrResourceView, DnsResourceView, InternetResourceView, ResourceStatus, ResourceView,
};

pub type DomainName = domain::base::Name<Vec<u8>>;

use serde::{Deserialize, Serialize};
use std::fmt;
use std::str::FromStr;
use uuid::Uuid;

const LIB_NAME: &str = "connlib";

#[derive(Hash, Deserialize, Serialize, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct GatewayId(Uuid);

#[derive(Hash, Deserialize, Serialize, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct ResourceId(Uuid);

#[derive(Hash, Deserialize, Serialize, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct RelayId(Uuid);

impl RelayId {
    pub fn from_u128(v: u128) -> Self {
        Self(Uuid::from_u128(v))
    }
}

impl FromStr for RelayId {
    type Err = uuid::Error;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        Ok(RelayId(Uuid::parse_str(s)?))
    }
}

impl ResourceId {
    pub fn random() -> ResourceId {
        ResourceId(Uuid::new_v4())
    }

    pub fn from_u128(v: u128) -> Self {
        Self(Uuid::from_u128(v))
    }
}

impl GatewayId {
    pub fn from_u128(v: u128) -> Self {
        Self(Uuid::from_u128(v))
    }
}

#[derive(Hash, Deserialize, Serialize, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct ClientId(Uuid);

impl FromStr for ClientId {
    type Err = uuid::Error;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        Ok(ClientId(Uuid::parse_str(s)?))
    }
}

impl ClientId {
    pub fn from_u128(v: u128) -> Self {
        Self(Uuid::from_u128(v))
    }
}

impl FromStr for ResourceId {
    type Err = uuid::Error;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        Ok(ResourceId(Uuid::parse_str(s)?))
    }
}

impl FromStr for GatewayId {
    type Err = uuid::Error;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        Ok(GatewayId(Uuid::parse_str(s)?))
    }
}

impl fmt::Display for ResourceId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.0)
    }
}

impl fmt::Display for ClientId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.0)
    }
}

impl fmt::Display for GatewayId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.0)
    }
}

impl fmt::Display for RelayId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.0)
    }
}

impl fmt::Debug for ResourceId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        fmt::Display::fmt(&self, f)
    }
}

impl fmt::Debug for ClientId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        fmt::Display::fmt(&self, f)
    }
}

impl fmt::Debug for GatewayId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        fmt::Display::fmt(&self, f)
    }
}

impl fmt::Debug for RelayId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        fmt::Display::fmt(&self, f)
    }
}

#[derive(Debug, Deserialize, Serialize, Clone, Eq, PartialOrd, Ord)]
pub struct Site {
    pub id: SiteId,
    pub name: String,
}

impl std::hash::Hash for Site {
    fn hash<H: std::hash::Hasher>(&self, state: &mut H) {
        self.id.hash(state);
    }
}

impl PartialEq for Site {
    fn eq(&self, other: &Self) -> bool {
        self.id == other.id
    }
}

#[derive(Deserialize, Serialize, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct SiteId(Uuid);

impl FromStr for SiteId {
    type Err = uuid::Error;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        Ok(SiteId(Uuid::parse_str(s)?))
    }
}

impl SiteId {
    pub fn from_u128(v: u128) -> Self {
        Self(Uuid::from_u128(v))
    }
}

impl fmt::Display for SiteId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.0)
    }
}

impl fmt::Debug for SiteId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        fmt::Display::fmt(&self, f)
    }
}

pub fn get_user_agent(os_version_override: Option<String>, app_version: &str) -> String {
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
    let lib_name = LIB_NAME;
    format!("{os_type}/{os_version} {lib_name}/{app_version}{additional_info}")
}

fn additional_info() -> String {
    let info = os_info::get();
    match (info.architecture(), kernel_version()) {
        (None, None) => "".to_string(),
        (None, Some(k)) => format!(" ({k})"),
        (Some(a), None) => format!(" ({a})"),
        (Some(a), Some(k)) => format!(" ({a}; {k})"),
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
