//! WiX deferred custom actions that register / deregister the
//! Firezone sparse MSIX package against the installed binaries.
//!
//! Invoked as one of three subcommands, each from a different MSI
//! custom action with a different security context. Listed in the
//! order they fire during MSI execution:
//!
//! - `provision` — runs as **`LocalSystem`**, calls
//!   `StagePackageByUriAsync` to put the package into the all-users
//!   staged state in `C:\Program Files\WindowsApps`, then
//!   `ProvisionPackageForAllUsersAsync` so every account (including
//!   `LocalSystem`, so the tunnel service inherits the package SID)
//!   auto-registers on next logon. Must run before `add` —
//!   per-user `AddPackageByUriAsync` does NOT produce the all-users
//!   staged state Provision needs, so calling Provision after Add
//!   returns `ERROR_NOT_FOUND` / `0x80070490`.
//! - `add` — runs **impersonated** as the user invoking `msiexec`,
//!   calls `AddPackageByUriAsync` to register the package for that
//!   user immediately (Provision would otherwise defer their
//!   registration until next logon). Must run as a real user, not
//!   `LocalSystem`: the AppX deployment service rejects per-user
//!   adds from `S-1-5-18` (`0x80073CF9` / "Local System account is
//!   not allowed to perform this operation").
//! - `deprovision` — runs as **`LocalSystem`** on uninstall, the
//!   inverse of `provision`. We deliberately do NOT enumerate and
//!   remove per-user package instances: that would require pulling
//!   in `Foundation_Collections` (`IIterable<Package>`) for one
//!   custom-action helper. Per-user instances are reaped by the next
//!   major Windows servicing cycle.
//!
//! WiX wires this up in `win_files/sparse-package.wxs`. The install
//! directory (needed by `provision` and `add`) is derived from the
//! exe's own location (`current_exe().parent()`) rather than piped
//! in via `CustomActionData`: MSI only exposes that property to
//! DLL/script deferred CAs, not to direct EXE CAs.
//!
//! Failure mode: registration is best-effort. On older Windows builds
//! (pre-21H2 hardened images, AppX disabled by GP) the call returns
//! an HRESULT and we exit `0` so the MSI install isn't bricked. The
//! runtime SDDL builder in `ipc/windows.rs` falls back to the legacy
//! `BU` ACE in that case (graceful degradation: less secure but
//! functional).

use clap::Parser;
use std::{fmt, process::ExitCode};

#[derive(Parser)]
#[command(disable_version_flag = true)]
struct Cli {
    action: Action,
}

#[derive(clap::ValueEnum, Clone, Copy)]
enum Action {
    /// Stage + provision the package for all users. Run as `LocalSystem`.
    Provision,
    /// Register the package for the current user. Run impersonated.
    Add,
    /// Deprovision the package for all users. Run as `LocalSystem`.
    Deprovision,
}

impl fmt::Display for Action {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Action::Provision => "provision",
            Action::Add => "add",
            Action::Deprovision => "deprovision",
        })
    }
}

fn main() -> ExitCode {
    init_tracing();

    let Cli { action } = Cli::parse();

    tracing::info!(
        %action,
        pfn = %firezone_gui_client::PACKAGE_FAMILY_NAME,
        sid = %firezone_gui_client::PACKAGE_SID,
        "register-sparse invoked"
    );

    let started = std::time::Instant::now();
    let result = match action {
        Action::Provision => imp::provision(),
        Action::Add => imp::add(),
        Action::Deprovision => imp::deprovision(),
    };
    let elapsed = started.elapsed();

    match result {
        Ok(()) => {
            tracing::info!(%action, ?elapsed, "completed");
            ExitCode::SUCCESS
        }
        Err(e) => {
            // Don't fail the MSI on legacy / hardened Windows where
            // sparse-package registration isn't available.
            tracing::warn!(
                %action,
                ?elapsed,
                error = format!("{e:#}"),
                "completed with error (non-fatal); MSI will proceed"
            );
            ExitCode::SUCCESS
        }
    }
}

/// `tracing_subscriber` configured to write to stderr in a compact,
/// no-ANSI format. `msiexec /l*v install.log` captures stderr so each
/// event lands in the MSI install log; setting `RUST_LOG` in the WiX
/// CA environment lets an operator widen or narrow the filter.
fn init_tracing() {
    use tracing_subscriber::{EnvFilter, fmt};

    let filter = EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| EnvFilter::new("register_sparse=debug"));
    fmt()
        .with_env_filter(filter)
        .with_writer(std::io::stderr)
        .with_target(false)
        .with_ansi(false)
        .compact()
        .init();
}

#[cfg(windows)]
mod imp {
    use anyhow::{Context, Result, anyhow};
    use std::{path::PathBuf, time::Instant};
    use windows::{
        Foundation::Uri,
        Management::Deployment::{
            AddPackageOptions, DeploymentResult, PackageManager, StagePackageOptions,
        },
        core::HSTRING,
    };

    /// Stages the sparse MSIX in the system store and provisions it
    /// for all users, so every account (including `LocalSystem` and
    /// future logons) gets package identity attached when launching
    /// `Firezone.exe` / `firezone-client-tunnel.exe`.
    ///
    /// Both steps must run as `LocalSystem`. Staging first is
    /// required: `ProvisionPackageForAllUsersAsync` only sees packages
    /// in the "staged for all users" state, which per-user
    /// `AddPackageByUriAsync` does not produce (despite copying files
    /// into `C:\Program Files\WindowsApps`). Skipping the explicit
    /// stage call returns `ERROR_NOT_FOUND` / `0x80070490`.
    pub fn provision() -> Result<()> {
        let install_path = install_dir()?;
        let msix = install_path.join("firezone.msix");

        let msix_meta = std::fs::metadata(&msix)
            .with_context(|| format!("firezone.msix missing at `{}`", msix.display()))?;
        tracing::info!(
            install_dir = %install_path.display(),
            msix_path = %msix.display(),
            msix_size_bytes = msix_meta.len(),
            "found MSIX payload"
        );

        let pm = package_manager()?;
        let msix_uri = file_uri(msix.as_path())?;
        let external_uri = file_uri(install_path.as_path())?;

        let stage_opts = StagePackageOptions::new().context("StagePackageOptions::new failed")?;
        stage_opts
            .SetExternalLocationUri(&external_uri)
            .context("SetExternalLocationUri failed")?;
        tracing::info!(
            external_uri = %external_uri.RawUri().map(|s| s.to_string_lossy()).unwrap_or_default(),
            msix_uri = %msix_uri.RawUri().map(|s| s.to_string_lossy()).unwrap_or_default(),
            "calling StagePackageByUriAsync"
        );
        let started = Instant::now();
        let stage_result = pm
            .StagePackageByUriAsync(&msix_uri, &stage_opts)
            .context("StagePackageByUriAsync call failed")?
            .get()
            .context("StagePackageByUriAsync await failed")?;
        log_deployment_result("stage", &stage_result, started);
        check_deployment_result(&stage_result, "stage")?;

        let pfn = HSTRING::from(firezone_gui_client::PACKAGE_FAMILY_NAME);
        tracing::info!(pfn = %pfn.to_string_lossy(), "calling ProvisionPackageForAllUsersAsync");
        let started = Instant::now();
        let result = pm
            .ProvisionPackageForAllUsersAsync(&pfn)
            .context("ProvisionPackageForAllUsersAsync call failed")?
            .get()
            .context("ProvisionPackageForAllUsersAsync await failed")?;
        log_deployment_result("provision", &result, started);
        check_deployment_result(&result, "provision")
    }

    /// Registers the sparse MSIX for the current user, telling Windows
    /// where the external binaries live (the MSI install dir). Must
    /// run impersonated: `AddPackageByUriAsync` is per-user and the
    /// AppX deployment service rejects it under `LocalSystem`.
    /// Sequenced after [`provision`] so the package is already in the
    /// all-users staged state by the time this runs.
    pub fn add() -> Result<()> {
        let install_path = install_dir()?;
        let msix = install_path.join("firezone.msix");

        let msix_meta = std::fs::metadata(&msix)
            .with_context(|| format!("firezone.msix missing at `{}`", msix.display()))?;
        tracing::info!(
            install_dir = %install_path.display(),
            msix_path = %msix.display(),
            msix_size_bytes = msix_meta.len(),
            "found MSIX payload"
        );

        let pm = package_manager()?;
        let opts = AddPackageOptions::new().context("AddPackageOptions::new failed")?;
        let external_uri = file_uri(install_path.as_path())?;
        opts.SetExternalLocationUri(&external_uri)
            .context("SetExternalLocationUri failed")?;
        let msix_uri = file_uri(msix.as_path())?;
        tracing::info!(
            external_uri = %external_uri.RawUri().map(|s| s.to_string_lossy()).unwrap_or_default(),
            msix_uri = %msix_uri.RawUri().map(|s| s.to_string_lossy()).unwrap_or_default(),
            "calling AddPackageByUriAsync"
        );
        let started = Instant::now();
        let result = pm
            .AddPackageByUriAsync(&msix_uri, &opts)
            .context("AddPackageByUriAsync call failed")?
            .get()
            .context("AddPackageByUriAsync await failed")?;
        log_deployment_result("add", &result, started);
        check_deployment_result(&result, "add")
    }

    /// Inverse of [`provision`]. Stops new logons from inheriting the
    /// package and lets the next major Windows servicing cycle reap
    /// the per-user package instances.
    pub fn deprovision() -> Result<()> {
        let pm = package_manager()?;
        let pfn = HSTRING::from(firezone_gui_client::PACKAGE_FAMILY_NAME);

        tracing::info!(pfn = %pfn.to_string_lossy(), "calling DeprovisionPackageForAllUsersAsync");
        let started = Instant::now();
        let result = pm
            .DeprovisionPackageForAllUsersAsync(&pfn)
            .context("DeprovisionPackageForAllUsersAsync call failed")?
            .get()
            .context("DeprovisionPackageForAllUsersAsync await failed")?;
        log_deployment_result("deprovision", &result, started);
        check_deployment_result(&result, "deprovision")
    }

    fn package_manager() -> Result<PackageManager> {
        let started = Instant::now();
        let pm = PackageManager::new().context("PackageManager::new failed")?;
        tracing::debug!(elapsed = ?started.elapsed(), "PackageManager created");
        Ok(pm)
    }

    /// Derives INSTALLDIR from the exe's own location: WiX installs
    /// `register-sparse.exe` next to `firezone.msix` in INSTALLDIR, so
    /// the parent directory of our binary is the value MSI would have
    /// otherwise piped in via `CustomActionData`.
    fn install_dir() -> Result<PathBuf> {
        let exe = std::env::current_exe().context("current_exe")?;
        exe.parent()
            .map(PathBuf::from)
            .ok_or_else(|| anyhow!("current_exe `{}` has no parent", exe.display()))
    }

    /// Logs the fields of a `DeploymentResult` after an AppX async op
    /// returns. `ExtendedErrorCode` is the HRESULT the deployment
    /// service captured (0 means success); `ErrorText` is the
    /// human-readable companion (often empty on success); `ActivityId`
    /// helps correlate with the AppX trace channel.
    fn log_deployment_result(op: &str, result: &DeploymentResult, started: Instant) {
        let elapsed = started.elapsed();
        let hr = result.ExtendedErrorCode().ok();
        let error_text = result
            .ErrorText()
            .ok()
            .map(|s| s.to_string_lossy())
            .unwrap_or_default();
        let activity_id = result.ActivityId().ok().map(|g| format!("{g:?}"));
        tracing::info!(
            op,
            ?elapsed,
            hr = ?hr,
            error_text,
            activity_id,
            "deployment result"
        );
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

#[cfg(not(windows))]
mod imp {
    use anyhow::{Result, bail};

    pub fn provision() -> Result<()> {
        bail!("`register-sparse` is only supported on Windows");
    }

    pub fn add() -> Result<()> {
        bail!("`register-sparse` is only supported on Windows");
    }

    pub fn deprovision() -> Result<()> {
        bail!("`register-sparse` is only supported on Windows");
    }
}
