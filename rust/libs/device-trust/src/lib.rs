//! Cross-platform device-trust X.509 challenge signer for Windows and Linux clients.
//!
//! The portal sends a 32-byte nonce and an expected leaf-certificate subject CN. The client
//! locates a matching certificate (subject CN match, clientAuth EKU, current date in validity
//! window) whose chain anchors at one of the account's trust anchors, signs the nonce with the
//! certificate's private key, and returns the signature plus the leaf certificate DER.
//!
//! This crate exposes a single `sign_device_trust_challenge` entry point per supported platform.
//! The macOS/iOS Apple targets have their own Swift implementation that calls Security.framework
//! directly; the Android target has a Kotlin implementation that calls the Android KeyChain.

use anyhow::Result;

pub use tunnel::messages::client::DeviceTrustSignedChallenge;

#[cfg_attr(not(any(target_os = "windows", target_os = "linux")), allow(dead_code))]
mod policy;

#[cfg(target_os = "windows")]
mod windows;

#[cfg(target_os = "linux")]
mod linux;

/// Platform-agnostic configuration provided by the host application.
#[derive(Debug, Clone, Default)]
pub struct Config {
    /// PKCS#11 URI (RFC 7512) identifying the module, token, and object that hold the device
    /// certificate and its private key. Required on Linux; ignored on other platforms.
    pub pkcs11_uri: Option<String>,
}

/// Sign the portal-provided nonce with the device-trust certificate.
///
/// Returns one signed challenge per matching certificate. An empty `Vec` means no usable
/// certificate was found; the call site should send an empty `device_trust_response` so the
/// portal records the result.
#[cfg(target_os = "windows")]
pub fn sign_device_trust_challenge(
    nonce: &[u8],
    subject_cn: &str,
    _config: &Config,
) -> Result<Vec<DeviceTrustSignedChallenge>> {
    windows::sign(nonce, subject_cn)
}

#[cfg(target_os = "linux")]
pub fn sign_device_trust_challenge(
    nonce: &[u8],
    subject_cn: &str,
    config: &Config,
) -> Result<Vec<DeviceTrustSignedChallenge>> {
    linux::sign(nonce, subject_cn, config.pkcs11_uri.as_deref())
}

// Same Result return shape as the platform-specific versions so callers don't have to switch
// on cfg; on platforms with no native signer there's simply nothing to fail.
#[cfg(not(any(target_os = "windows", target_os = "linux")))]
#[allow(clippy::unnecessary_wraps)]
pub fn sign_device_trust_challenge(
    _nonce: &[u8],
    _subject_cn: &str,
    _config: &Config,
) -> Result<Vec<DeviceTrustSignedChallenge>> {
    Ok(Vec::new())
}
