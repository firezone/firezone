//! WiX deferred custom action that registers (or deregisters) the
//! Firezone sparse MSIX package against the installed binaries.
//!
//! Invoked as `LocalSystem` with one positional argument
//! (`install` / `uninstall`) and one CustomActionData property that
//! holds the install directory. WiX wires this up in
//! `win_files/sparse-package.wxs`.
//!
//! Failure mode: registration is best-effort. On older Windows builds
//! (pre-21H2 hardened images, AppX disabled by GP) the call returns
//! an HRESULT and we exit `0` so the MSI install isn't bricked. The
//! runtime SDDL builder in `ipc/windows.rs` falls back to the
//! legacy `BU` ACE in that case (graceful degradation: less secure
//! but functional).
//!
//! Non-Windows targets compile this as an empty stub so `cargo build`
//! works in CI.

#![cfg_attr(not(windows), allow(dead_code))]
// `register-sparse.exe` is a single-shot WiX deferred custom action;
// it has no tracing infrastructure to plumb logs through, so it
// writes its few status lines directly to stderr (which msiexec
// captures into the install log).
#![allow(clippy::print_stderr)]

#[cfg(windows)]
fn main() -> std::process::ExitCode {
    use std::process::ExitCode;

    let mut args = std::env::args().skip(1);
    let action = args.next().unwrap_or_else(|| "install".into());

    // WiX deferred custom actions only see properties via CustomActionData;
    // we accept either an explicit second positional arg (for manual
    // testing) or the env var `CustomActionData` itself, which WiX sets.
    let install_dir = args
        .next()
        .unwrap_or_else(|| std::env::var("CustomActionData").unwrap_or_default());

    let result = match action.as_str() {
        "install" => imp::register(&install_dir),
        "uninstall" => imp::deregister(),
        other => {
            eprintln!("register-sparse: unknown action `{other}`");
            return ExitCode::FAILURE;
        }
    };

    match result {
        Ok(()) => {
            eprintln!("register-sparse: {action} OK");
            ExitCode::SUCCESS
        }
        Err(e) => {
            // Don't fail the MSI on legacy / hardened Windows where
            // sparse-package registration isn't available.
            eprintln!("register-sparse: {action} failed (non-fatal): {e:#}");
            ExitCode::SUCCESS
        }
    }
}

#[cfg(not(windows))]
fn main() {}

#[cfg(windows)]
mod imp {
    use anyhow::{Context, Result, anyhow};
    use std::path::PathBuf;
    use windows::{
        Foundation::Uri,
        Management::Deployment::{AddPackageOptions, DeploymentResult, PackageManager},
        core::HSTRING,
    };

    /// Provisions the sparse MSIX for all users (so future logons
    /// inherit the package identity) and registers the in-package
    /// applications against the externally installed binaries.
    pub fn register(install_dir: &str) -> Result<()> {
        if install_dir.is_empty() {
            return Err(anyhow!("INSTALLDIR was empty"));
        }
        let install_path = PathBuf::from(install_dir);
        let msix = install_path.join("firezone.msix");
        if !msix.exists() {
            return Err(anyhow!("firezone.msix missing at `{}`", msix.display()));
        }

        let pm = PackageManager::new().context("Failed to create PackageManager")?;
        let pfn = HSTRING::from(firezone_gui_client::PACKAGE_FAMILY_NAME);

        // Provision so new users get the package on first logon.
        let provision = pm
            .ProvisionPackageForAllUsersAsync(&pfn)
            .context("ProvisionPackageForAllUsersAsync call failed")?;
        let provision_result: DeploymentResult = provision
            .get()
            .context("ProvisionPackageForAllUsersAsync await failed")?;
        check_deployment_result(&provision_result, "provision")?;

        // Add the package itself, telling Windows where the actual
        // binaries live (the MSI install dir).
        let opts = AddPackageOptions::new().context("Failed to create AddPackageOptions")?;
        opts.SetExternalLocationUri(&file_uri(install_path.as_path())?)
            .context("SetExternalLocationUri failed")?;
        let add = pm
            .AddPackageByUriAsync(&file_uri(msix.as_path())?, &opts)
            .context("AddPackageByUriAsync call failed")?;
        let add_result: DeploymentResult =
            add.get().context("AddPackageByUriAsync await failed")?;
        check_deployment_result(&add_result, "add")?;
        Ok(())
    }

    /// Inverse of [`register`]. Deprovisioning the package family is
    /// enough for our purposes: it stops new logons from inheriting
    /// the package and lets the next major Windows servicing cycle
    /// reap the per-user package instances. Enumerating + explicitly
    /// removing each instance would require pulling in the
    /// `Foundation_Collections` (`IIterable<Package>`) feature for one
    /// custom-action helper, which isn't worth the binary-size hit.
    pub fn deregister() -> Result<()> {
        let pm = PackageManager::new().context("Failed to create PackageManager")?;
        let pfn = HSTRING::from(firezone_gui_client::PACKAGE_FAMILY_NAME);

        let deprov = pm
            .DeprovisionPackageForAllUsersAsync(&pfn)
            .context("DeprovisionPackageForAllUsersAsync call failed")?;
        let deprov_result: DeploymentResult = deprov
            .get()
            .context("DeprovisionPackageForAllUsersAsync await failed")?;
        check_deployment_result(&deprov_result, "deprovision")?;
        Ok(())
    }

    fn check_deployment_result(result: &DeploymentResult, op: &str) -> Result<()> {
        let hr = result.ExtendedErrorCode().context("ExtendedErrorCode")?;
        if hr.is_ok() {
            return Ok(());
        }
        let msg = result
            .ErrorText()
            .map(|s| s.to_string_lossy())
            .unwrap_or_default();
        Err(anyhow!("deployment {op} failed: {hr:?} ({msg})"))
    }

    fn file_uri(path: &std::path::Path) -> Result<Uri> {
        // `Windows.Foundation.Uri` accepts forward-slash file URIs; the
        // backslashes in the MSI install dir would otherwise be
        // interpreted as escape sequences.
        let s = path.to_string_lossy().replace('\\', "/");
        let uri = format!("file:///{s}");
        Uri::CreateUri(&HSTRING::from(uri.as_str())).context("Uri::CreateUri failed")
    }
}
