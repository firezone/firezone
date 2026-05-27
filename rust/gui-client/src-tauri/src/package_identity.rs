//! Ensures the GUI process carries the Firezone sparse-MSIX package
//! identity before it does anything that needs the kernel-assigned
//! package SID (notably opening the SID-pinned tunnel pipe).
//!
//! The MSI provisions the package and registers it for the
//! *installing* user (see `register-sparse`). External-location
//! sparse packages aren't auto-registered for other interactive
//! users at logon, so for a user the installer didn't cover we
//! register the package for the current user here. Package identity
//! is stamped by the kernel at `CreateProcess`, so the current
//! process can't gain it after the fact — the caller surfaces a
//! "please restart" dialog and exits; the user's next launch is
//! created with the package SID.

use anyhow::Result;

/// Result of [`ensure_package_identity`].
pub enum Outcome {
    /// The process already has package identity (or this platform has
    /// none); continue startup normally.
    Proceed,
    /// Registered the package for the current user. Identity only
    /// attaches to a freshly-created process, so the caller should
    /// tell the user to relaunch and exit.
    RegisteredRestartRequired,
}

#[cfg(not(target_os = "windows"))]
#[expect(clippy::unnecessary_wraps, reason = "Windows impl is fallible")]
pub fn ensure_package_identity() -> Result<Outcome> {
    Ok(Outcome::Proceed)
}

#[cfg(target_os = "windows")]
pub fn ensure_package_identity() -> Result<Outcome> {
    use anyhow::Context as _;

    if has_package_identity() {
        return Ok(Outcome::Proceed);
    }

    register_for_current_user().context("Failed to register package for current user")?;
    Ok(Outcome::RegisteredRestartRequired)
}

/// `Windows.ApplicationModel.Package.Current` succeeds only for a
/// process activated with package identity; on a non-packaged process
/// it errors, which is our signal to register for the current user.
#[cfg(target_os = "windows")]
fn has_package_identity() -> bool {
    windows::ApplicationModel::Package::Current().is_ok()
}

#[cfg(target_os = "windows")]
fn register_for_current_user() -> Result<()> {
    use anyhow::Context as _;
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
    // `Executable=` paths relative to it (matches `register-sparse`).
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
    result
        .ExtendedErrorCode()
        .context("ExtendedErrorCode")?
        .ok()
        .context("Package registration reported an error")?;

    Ok(())
}
