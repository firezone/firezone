//! Ensures the GUI process carries the Firezone sparse-MSIX package
//! identity before it does anything that needs it (notably opening the
//! identity-pinned tunnel pipe).
//!
//! The MSI provisions the package and registers it for the *installing*
//! user (see `register-sparse`). External-location sparse packages
//! aren't auto-registered for other interactive users at logon, so for
//! a user the installer didn't cover we register the package for the
//! current user here. Package identity is stamped by the kernel at
//! `CreateProcess`, so the current process can't gain it after the
//! fact — the caller surfaces a "please restart" dialog and exits; the
//! user's next launch is created with identity attached.

use anyhow::Result;

/// Returned by [`ensure_package_identity`] when it registered the
/// package for the current user. Package identity only attaches at
/// process creation, so the caller must tell the user to relaunch and
/// exit; the next launch carries it.
#[derive(Debug, thiserror::Error)]
#[error("Registered package identity for the current user; a restart is required")]
pub struct RestartRequired;

/// Ensures the current process carries the Firezone package identity
/// that the pipe DACLs pin access to.
///
/// - `Ok(())` if the process already has identity (or on non-Windows,
///   which has none) — continue startup.
/// - `Err(`[`RestartRequired`]`)` if it didn't, but we registered the
///   package for the current user (no admin needed once provisioned).
///   Identity only attaches on the next launch, so the caller should
///   tell the user to relaunch and exit.
/// - `Err(_)` on any other failure.
#[cfg(not(target_os = "windows"))]
#[expect(clippy::unnecessary_wraps, reason = "Windows impl is fallible")]
pub fn ensure_package_identity() -> Result<()> {
    Ok(())
}

#[cfg(target_os = "windows")]
pub fn ensure_package_identity() -> Result<()> {
    if has_package_identity() {
        return Ok(());
    }

    register_for_current_user()?;
    Err(RestartRequired.into())
}

/// `Windows.ApplicationModel.Package.Current` succeeds only for a
/// process activated with package identity; on a non-packaged process
/// it errors, which is our signal to register for the current user.
#[cfg(target_os = "windows")]
pub fn has_package_identity() -> bool {
    windows::ApplicationModel::Package::Current().is_ok()
}

/// Registers the Firezone sparse MSIX for the current user via
/// `AddPackageByUriAsync` + `ExternalLocationUri` (which both stages
/// and registers; no admin needed once the package is provisioned).
///
/// Shared by the GUI's launch-time [`ensure_package_identity`] check
/// and `register-sparse`'s `register-user` install custom action.
#[cfg(target_os = "windows")]
pub fn register_for_current_user() -> Result<()> {
    use anyhow::{Context as _, bail};
    use windows::{
        Foundation::Uri,
        Management::Deployment::{AddPackageOptions, PackageManager},
        core::HSTRING,
    };

    let install_dir = std::env::current_exe()
        .context("current_exe")?
        .parent()
        .context("exe has no parent dir")?
        .to_path_buf();
    let msix = install_dir.join("firezone.msix");

    // Forward-slash `file:///` URIs, with a trailing slash on the
    // external-location directory so AppX resolves the manifest's
    // `Executable=` paths relative to it.
    let msix_uri = {
        let s = msix.to_string_lossy().replace('\\', "/");
        Uri::CreateUri(&HSTRING::from(format!("file:///{s}").as_str()))
            .context("Uri::CreateUri (msix) failed")?
    };
    let external_uri = {
        let s = install_dir.to_string_lossy().replace('\\', "/");
        Uri::CreateUri(&HSTRING::from(
            format!("file:///{}/", s.trim_end_matches('/')).as_str(),
        ))
        .context("Uri::CreateUri (external location) failed")?
    };

    let pm = PackageManager::new().context("PackageManager::new failed")?;
    let opts = AddPackageOptions::new().context("AddPackageOptions::new failed")?;
    opts.SetExternalLocationUri(&external_uri)
        .context("SetExternalLocationUri failed")?;

    tracing::info!(msix = %msix.display(), "Registering Firezone package for current user");
    let result = pm
        .AddPackageByUriAsync(&msix_uri, &opts)
        .context("AddPackageByUriAsync failed")?
        .get()
        .context("AddPackageByUriAsync await failed")?;

    let hr = result.ExtendedErrorCode().context("ExtendedErrorCode")?;
    if !hr.is_ok() {
        let error_text = result
            .ErrorText()
            .ok()
            .map(|s| s.to_string_lossy())
            .unwrap_or_default();
        bail!("Package registration failed: {hr:?} ({error_text})");
    }

    Ok(())
}
