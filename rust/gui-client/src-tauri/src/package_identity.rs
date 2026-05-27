//! Ensures the GUI process carries the Firezone sparse-MSIX package
//! identity before it does anything that needs the kernel-assigned
//! package SID (notably opening the SID-pinned tunnel pipe).
//!
//! The MSI only *provisions* the package (as `LocalSystem`, via
//! `register-sparse.exe`). External-location sparse packages are not
//! auto-registered for interactive users at logon, so on a fresh
//! install no GUI process carries identity. We bridge the gap here:
//! on launch, if the process has no package identity, register the
//! package for the current user and re-exec — identity is stamped by
//! the kernel at `CreateProcess`, so the *current* process can't gain
//! it, but the child we spawn will.

use anyhow::Result;

/// Whether [`ensure_package_identity`] re-launched the process.
pub enum Outcome {
    /// The process already has identity (or this platform has no
    /// package identity); continue startup normally.
    Proceed,
    /// Registered the package and spawned a child that will carry
    /// identity; the caller must exit immediately.
    ReExeced,
}

/// Marks the re-exec'd child so a registration that somehow fails to
/// attach identity can't spawn children forever.
#[cfg(target_os = "windows")]
const REEXEC_MARKER: &str = "FIREZONE_PACKAGE_REREGISTERED";

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

    if std::env::var_os(REEXEC_MARKER).is_some() {
        tracing::warn!("No package identity after re-registration; continuing without it");
        return Ok(Outcome::Proceed);
    }

    register_for_current_user().context("Failed to register package for current user")?;
    reexec().context("Failed to re-launch with package identity")?;

    Ok(Outcome::ReExeced)
}

/// `Windows.ApplicationModel.Package.Current` succeeds only for a
/// process activated with package identity; on a non-packaged process
/// it errors, which is our signal to register + re-exec.
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

/// Re-launch ourselves with the same arguments so the new process is
/// created *after* registration and thus inherits the package SID.
#[cfg(target_os = "windows")]
fn reexec() -> Result<()> {
    use anyhow::Context as _;

    let exe = std::env::current_exe().context("current_exe")?;
    let args: Vec<_> = std::env::args_os().skip(1).collect();
    std::process::Command::new(exe)
        .args(args)
        .env(REEXEC_MARKER, "1")
        .spawn()
        .context("Failed to spawn re-registered child process")?;
    Ok(())
}
