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
//!
//! Logging: `tracing` events go to stderr. `msiexec /l*v install.log`
//! captures stderr from deferred custom actions, so each event lands
//! in the MSI install log. Set `RUST_LOG=trace` to widen the filter
//! (default is `debug`).

use clap::Parser;
use std::{fmt, process::ExitCode, time::Duration};

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

/// Hard ceiling on total run-time, regardless of which AppX call is
/// stuck. The MSI install will see the CA complete and proceed.
const WATCHDOG_TIMEOUT: Duration = Duration::from_secs(120);

fn main() -> ExitCode {
    init_tracing();

    // Watchdog: if anything below hangs (e.g. the AppX Deployment
    // Service wedging on Server SKUs has been observed to turn an MSI
    // install into a multi-hour stall), self-terminate with exit 0
    // so MSI sees the CA complete and proceeds. The runtime SDDL
    // builder in `ipc/windows.rs` falls back to the legacy ACE when
    // package identity isn't attached.
    std::thread::spawn(|| {
        std::thread::sleep(WATCHDOG_TIMEOUT);
        tracing::error!(
            timeout_secs = WATCHDOG_TIMEOUT.as_secs(),
            "watchdog fired, exiting 0 to let MSI continue"
        );
        std::process::exit(0);
    });

    let Cli {
        action,
        install_dir,
    } = Cli::parse();

    tracing::info!(
        %action,
        install_dir = %install_dir,
        pfn = %firezone_gui_client::PACKAGE_FAMILY_NAME,
        sid = %firezone_gui_client::PACKAGE_SID,
        "register-sparse invoked"
    );

    let started = std::time::Instant::now();
    let result = match action {
        Action::Install => imp::register(&install_dir),
        Action::Uninstall => imp::deregister(),
    };
    let elapsed_ms = started.elapsed().as_millis();

    match result {
        Ok(()) => {
            tracing::info!(%action, elapsed_ms, "completed");
            ExitCode::SUCCESS
        }
        Err(e) => {
            // Don't fail the MSI on legacy / hardened Windows where
            // sparse-package registration isn't available.
            tracing::warn!(
                %action,
                elapsed_ms,
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

        let msix_meta = std::fs::metadata(&msix)
            .with_context(|| format!("firezone.msix missing at `{}`", msix.display()))?;
        tracing::info!(
            msix_path = %msix.display(),
            msix_size_bytes = msix_meta.len(),
            "found MSIX payload"
        );

        let pm_started = Instant::now();
        let pm = PackageManager::new().context("PackageManager::new failed")?;
        let pfn = HSTRING::from(firezone_gui_client::PACKAGE_FAMILY_NAME);
        tracing::debug!(
            elapsed_ms = pm_started.elapsed().as_millis(),
            "PackageManager created"
        );

        // Provision so new users get the package on first logon.
        tracing::info!(pfn = %pfn.to_string_lossy(), "calling ProvisionPackageForAllUsersAsync");
        let started = Instant::now();
        let provision_result = pm
            .ProvisionPackageForAllUsersAsync(&pfn)
            .context("ProvisionPackageForAllUsersAsync call failed")?
            .get()
            .context("ProvisionPackageForAllUsersAsync await failed")?;
        log_deployment_result("provision", &provision_result, started);
        check_deployment_result(&provision_result, "provision")?;

        // Add the package itself, telling Windows where the actual
        // binaries live (the MSI install dir).
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
        let add_result = pm
            .AddPackageByUriAsync(&msix_uri, &opts)
            .context("AddPackageByUriAsync call failed")?
            .get()
            .context("AddPackageByUriAsync await failed")?;
        log_deployment_result("add", &add_result, started);
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
        let pm = PackageManager::new().context("PackageManager::new failed")?;
        let pfn = HSTRING::from(firezone_gui_client::PACKAGE_FAMILY_NAME);

        tracing::info!(pfn = %pfn.to_string_lossy(), "calling DeprovisionPackageForAllUsersAsync");
        let started = Instant::now();
        let deprov_result = pm
            .DeprovisionPackageForAllUsersAsync(&pfn)
            .context("DeprovisionPackageForAllUsersAsync call failed")?
            .get()
            .context("DeprovisionPackageForAllUsersAsync await failed")?;
        log_deployment_result("deprovision", &deprov_result, started);
        check_deployment_result(&deprov_result, "deprovision")?;
        Ok(())
    }

    /// Logs the fields of a `DeploymentResult` after an AppX async op
    /// returns. `ExtendedErrorCode` is the HRESULT the deployment
    /// service captured (0 means success); `ErrorText` is the
    /// human-readable companion (often empty on success); `ActivityId`
    /// helps correlate with the AppX trace channel.
    fn log_deployment_result(op: &str, result: &DeploymentResult, started: Instant) {
        let elapsed_ms = started.elapsed().as_millis();
        let hr = result.ExtendedErrorCode().ok();
        let error_text = result
            .ErrorText()
            .ok()
            .map(|s| s.to_string_lossy())
            .unwrap_or_default();
        let activity_id = result.ActivityId().ok().map(|g| format!("{g:?}"));
        tracing::info!(
            op,
            elapsed_ms,
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

    pub fn register(_install_dir: &str) -> Result<()> {
        bail!("`register-sparse` is only supported on Windows");
    }

    pub fn deregister() -> Result<()> {
        bail!("`register-sparse` is only supported on Windows");
    }
}
