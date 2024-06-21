//! This crates contains shared types and behavior between all the other libraries.
//!
//! This includes types provided by external crates, i.e. [boringtun] to make sure that
//! we are using the same version across our own crates.

pub mod callbacks;
pub mod error;
pub mod messages;
pub mod tun_device_manager;

#[cfg(target_os = "windows")]
pub mod windows;

#[cfg(feature = "proptest")]
pub mod proptest;

pub use boringtun::x25519::PublicKey;
pub use boringtun::x25519::StaticSecret;
pub use callbacks::{Callbacks, Cidrv4, Cidrv6};
pub use error::ConnlibError as Error;
pub use error::Result;
pub use phoenix_channel::{LoginUrl, LoginUrlError};

use rand_core::OsRng;

pub type DomainName = domain::base::Name<Vec<u8>>;

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

pub const DEFAULT_MTU: u32 = 1280;

const LIB_NAME: &str = "connlib";

pub fn keypair() -> (StaticSecret, PublicKey) {
    let private_key = StaticSecret::random_from_rng(OsRng);
    let public_key = PublicKey::from(&private_key);

    (private_key, public_key)
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
    format!("{os_type}/{os_version}{additional_info}{lib_name}/{firezone_package_version}")
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
