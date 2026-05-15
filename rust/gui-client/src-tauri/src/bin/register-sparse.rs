//! WiX deferred custom action that registers (or deregisters) the
//! Firezone sparse MSIX package against the installed binaries.
//!
//! Invoked as `LocalSystem` with one positional argument
//! (`install` / `uninstall`) and one `CustomActionData` environment
//! variable that holds the install directory. WiX wires this up in
//! `win_files/sparse-package.wxs`.
//!
//! Failure mode: registration is best-effort. On older Windows builds
//! (pre-21H2 hardened images, AppX disabled by GP) the call returns
//! an HRESULT and we exit `0` so the MSI install isn't bricked. The
//! runtime SDDL builder in `ipc/windows.rs` falls back to the legacy
//! `BU` ACE in that case (graceful degradation: less secure but
//! functional).

// `register-sparse.exe` is a single-shot WiX deferred custom action;
// it has no tracing infrastructure to plumb logs through, so it
// writes its few status lines directly to stderr (which msiexec
// captures into the install log).
#![allow(clippy::print_stderr)]

use clap::Parser;
use std::{fmt, process::ExitCode};

/// `register-sparse` is a WiX deferred custom action: WiX passes the
/// `INSTALLDIR` property via the `CustomActionData` environment
/// variable (`clap`'s `env` feature reads it directly), and the
/// install/uninstall mode comes in as the first positional arg from
/// the WiX `ExeCommand` attribute.
#[derive(Parser)]
#[command(disable_version_flag = true)]
struct Cli {
    #[arg(default_value = "install")]
    action: Action,
    /// Filled by WiX via `CustomActionData` on deferred CAs.
    #[arg(env = "CustomActionData", default_value = "")]
    install_dir: String,
}

#[derive(clap::ValueEnum, Clone, Copy)]
enum Action {
    Install,
    Uninstall,
}

impl fmt::Display for Action {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Action::Install => "install",
            Action::Uninstall => "uninstall",
        })
    }
}

fn main() -> ExitCode {
    // Watchdog: if anything below hangs (e.g. the AppX Deployment
    // Service wedging on Server SKUs has been observed to turn an MSI
    // install into a multi-hour stall), self-terminate with exit 0
    // so MSI sees the CA complete and proceeds. The runtime SDDL
    // builder in `ipc/windows.rs` falls back to the legacy ACE when
    // package identity isn't attached.
    std::thread::spawn(|| {
        std::thread::sleep(std::time::Duration::from_secs(120));
        eprintln!("register-sparse: watchdog fired after 120s, exiting 0 to let MSI continue");
        std::process::exit(0);
    });

    let Cli {
        action,
        install_dir,
    } = Cli::parse();

    let result = match action {
        Action::Install => imp::register(&install_dir),
        Action::Uninstall => imp::deregister(),
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

#[cfg(windows)]
mod imp {
    use anyhow::{Context, Result, anyhow};
    use std::path::PathBuf;
    use windows::{
        Foundation::Uri,
        Management::Deployment::{AddPackageOptions, PackageManager},
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
        let provision_result = pm
            .ProvisionPackageForAllUsersAsync(&pfn)
            .context("ProvisionPackageForAllUsersAsync call failed")?
            .get()
            .context("ProvisionPackageForAllUsersAsync await failed")?;
        check_deployment_result(&provision_result, "provision")?;

        // Add the package itself, telling Windows where the actual
        // binaries live (the MSI install dir).
        let opts = AddPackageOptions::new().context("Failed to create AddPackageOptions")?;
        opts.SetExternalLocationUri(&file_uri(install_path.as_path())?)
            .context("SetExternalLocationUri failed")?;
        let add_result = pm
            .AddPackageByUriAsync(&file_uri(msix.as_path())?, &opts)
            .context("AddPackageByUriAsync call failed")?
            .get()
            .context("AddPackageByUriAsync await failed")?;
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

        let deprov_result = pm
            .DeprovisionPackageForAllUsersAsync(&pfn)
            .context("DeprovisionPackageForAllUsersAsync call failed")?
            .get()
            .context("DeprovisionPackageForAllUsersAsync await failed")?;
        check_deployment_result(&deprov_result, "deprovision")?;
        Ok(())
    }

    fn check_deployment_result(
        result: &windows::Management::Deployment::DeploymentResult,
        op: &str,
    ) -> Result<()> {
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

#[cfg(not(windows))]
mod imp {
    use anyhow::{Result, bail};

    pub fn register(_install_dir: &str) -> Result<()> {
        bail!("`register-sparse` is only supported on Windows");
    }

    pub fn deregister() -> Result<()> {
        bail!("`register-sparse` is only supported on Windows");
    }
}
