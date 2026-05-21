//! WiX deferred custom actions that register / deregister the
//! Firezone sparse MSIX package against the installed binaries.
//!
//! Two subcommands, each fired from its own MSI custom action; see
//! `win_files/sparse-package.wxs` for the wiring:
//!
//! - [`imp::provision`] — stage + provision for all users.
//! - [`imp::deprovision`] — uninstall counterpart.
//!
//! Both run as `LocalSystem` (the AppX provisioning APIs require it).
//! Exit code policy:
//!
//! - `0` on success.
//! - `0` if the AppX deployment service reports the package as not
//!   supported on this Windows build (pre-21H2 / hardened images).
//!   The MSI install proceeds; the runtime SDDL builder in
//!   `ipc/windows.rs` falls back to the legacy `BU` ACE.
//! - **non-zero** on every other failure. Wrong PFN, AppX service
//!   wedged, missing payload, permissions — these all surface
//!   loudly via the `Return="check"` MSI CA wiring + a Sentry event
//!   (DSN = same as the GUI's, so install failures show up next to
//!   runtime crashes) + the `register-sparse.log` file the install
//!   canary captures.

use anyhow::{Context, Result};
use clap::Parser;
use std::{fmt, process::ExitCode};
use telemetry::Telemetry;

/// `{Identity.Name}_{publisher_id(Identity.Publisher)}` from
/// `win_files/AppxManifest.xml`, hard-coded because `register-sparse`
/// needs to pass it to `ProvisionPackageForAllUsersAsync` *before*
/// the package is registered — at which point Windows' own
/// `GetCurrentPackageFamilyName` would answer "no package identity".
///
/// If the manifest's `Identity.Publisher` or `Name` ever changes, this
/// string has to be updated to match. The install canary catches drift:
/// `ProvisionPackageForAllUsersAsync` fails with "package not found"
/// when the PFN doesn't match the package the kernel staged.
const PACKAGE_FAMILY_NAME: &str = "Firezone.Client.GUI_r4567a5vks0bt";

#[derive(Parser)]
#[command(disable_version_flag = true)]
struct Cli {
    action: Action,
}

#[derive(clap::ValueEnum, Clone, Copy)]
enum Action {
    /// Stage + provision the package for all users.
    Provision,
    /// Deprovision the package for all users.
    Deprovision,
}

impl fmt::Display for Action {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Action::Provision => "provision",
            Action::Deprovision => "deprovision",
        })
    }
}

/// Marker attached (via `anyhow::Error::new`) to a deployment error
/// when the AppX deployment service reports
/// `APPMODEL_ERROR_PACKAGE_NOT_SUPPORTED` — pre-21H2 / hardened
/// images that don't support external-location sparse MSIX. `main`
/// downcasts on this to choose between graceful skip (exit 0) and
/// loud failure (exit 1, Sentry event).
#[derive(Debug)]
struct NotSupported;

impl fmt::Display for NotSupported {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("sparse MSIX not supported on this Windows build")
    }
}

impl std::error::Error for NotSupported {}

fn main() -> ExitCode {
    // Sentry first, so any tracing::error event from `init_tracing` or
    // the deployment code below is captured. `Telemetry` drops at end
    // of `main` and `sentry::ClientInitGuard::Drop` flushes events
    // synchronously (2s default timeout), so we don't need an async
    // `stop()` here.
    let mut telemetry = Telemetry::new();
    telemetry.start(
        "entrypoint",
        firezone_gui_client::RELEASE,
        telemetry::GUI_DSN,
    );

    let _log_handle = match init_tracing() {
        Ok(h) => h,
        #[expect(
            clippy::print_stderr,
            reason = "Without `tracing`, we need to manually print to stderr."
        )]
        Err(e) => {
            eprintln!("register-sparse: failed to init tracing: {e:#}");
            return ExitCode::FAILURE;
        }
    };

    let Cli { action } = Cli::parse();

    tracing::info!(
        %action,
        pfn = %crate::PACKAGE_FAMILY_NAME,
        "register-sparse invoked"
    );

    let started = std::time::Instant::now();
    let result = match action {
        Action::Provision => imp::provision(),
        Action::Deprovision => imp::deprovision(),
    };
    let elapsed = started.elapsed();

    match result {
        Ok(()) => {
            tracing::info!(%action, ?elapsed, "completed");
            ExitCode::SUCCESS
        }
        Err(e) if e.is::<NotSupported>() => {
            tracing::info!(
                %action,
                ?elapsed,
                "sparse MSIX not supported on this Windows build; MSI will proceed without it"
            );
            ExitCode::SUCCESS
        }
        Err(e) => {
            tracing::error!(
                %action,
                ?elapsed,
                error = format!("{e:#}"),
                "register-sparse failed"
            );
            // `telemetry` drops as we return from `main`, flushing the
            // `tracing::error!` above to Sentry.
            ExitCode::FAILURE
        }
    }
}

/// Sets up tracing for `register-sparse`:
///
/// - File: `<tunnel_service_logs>/register-sparse.<timestamp>.log`
///   (and a `latest` link). This is the authoritative source during
///   MSI installs, because MSI discards stdout/stderr from deferred
///   EXE custom actions — they don't land in `install.log`.
/// - Stdout: useful only when invoking `register-sparse.exe`
///   manually for diagnosis.
/// - Sentry: `tracing::error!` events propagate to Sentry via the
///   `sentry-tracing` layer that `setup_global_subscriber` installs.
///
/// Returns the file-appender handle; the caller must keep it alive
/// until exit so the background writer can flush.
fn init_tracing() -> Result<logging::file::Handle> {
    let log_dir =
        known_dirs::tunnel_service_logs().context("`tunnel_service_logs` not configured")?;
    std::fs::create_dir_all(&log_dir)
        .with_context(|| format!("creating log dir `{}`", log_dir.display()))?;

    let (file_layer, file_handle) = logging::file::layer(&log_dir, "register-sparse");
    let directives = std::env::var("RUST_LOG").unwrap_or_else(|_| "debug".to_string());
    logging::setup_global_subscriber(directives, file_layer, false)
        .context("setup_global_subscriber")?;

    tracing::info!(log_dir = %log_dir.display(), "logging initialized");

    Ok(file_handle)
}

#[cfg(windows)]
mod imp {
    use super::NotSupported;
    use anyhow::{Context, Result, anyhow};
    use std::{path::PathBuf, time::Instant};
    use windows::{
        Foundation::Uri,
        Management::Deployment::{DeploymentResult, PackageManager, StagePackageOptions},
        core::HSTRING,
    };

    /// `APPMODEL_ERROR_PACKAGE_NOT_SUPPORTED`. Returned by AppX deployment
    /// when the package's `MinVersion` floor isn't met or the OS image
    /// has external-location-sparse-MSIX support disabled.
    const APPMODEL_ERROR_PACKAGE_NOT_SUPPORTED: u32 = 0x80073D54;

    /// Stages the sparse MSIX in the system store and provisions it
    /// for all users, so every account (including `LocalSystem` and
    /// future logons) gets package identity attached when launching
    /// `Firezone.exe` / `firezone-client-tunnel.exe`. The invoking
    /// admin is auto-registered by AppX as part of provision via
    /// `OnDemandRegisterOperation`, so no separate per-user
    /// registration call is needed.
    ///
    /// `StagePackageByUriAsync` must run before
    /// `ProvisionPackageForAllUsersAsync`: the latter only acts on
    /// packages already in the all-users staged state and returns
    /// `ERROR_NOT_FOUND` / `0x80070490` otherwise.
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

        let pfn = HSTRING::from(crate::PACKAGE_FAMILY_NAME);
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

    /// Inverse of [`provision`]. Stops new logons from inheriting the
    /// package and lets the next major Windows servicing cycle reap
    /// the per-user package instances. Enumerating + explicitly
    /// removing each instance would require pulling in the
    /// `Foundation_Collections` (`IIterable<Package>`) feature for
    /// one custom-action helper, which isn't worth the binary-size
    /// hit.
    pub fn deprovision() -> Result<()> {
        let pm = package_manager()?;
        let pfn = HSTRING::from(crate::PACKAGE_FAMILY_NAME);

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
        if hr.0 as u32 == APPMODEL_ERROR_PACKAGE_NOT_SUPPORTED {
            return Err(anyhow::Error::new(NotSupported));
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

    pub fn deprovision() -> Result<()> {
        bail!("`register-sparse` is only supported on Windows");
    }
}
