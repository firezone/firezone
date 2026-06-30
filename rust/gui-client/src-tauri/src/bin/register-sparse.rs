//! WiX deferred custom actions that register / deregister the
//! Firezone sparse MSIX package against the installed binaries.
//!
//! Subcommands, each fired from its own MSI custom action; see
//! `win_files/sparse-package.wxs` for the wiring:
//!
//! - [`imp::provision`] — stage + provision for all users
//!   (`LocalSystem`).
//! - [`imp::register_user`] — register for the installing user
//!   (impersonated), so their first launch carries identity.
//! - [`imp::deprovision`] — uninstall counterpart (`LocalSystem`).
//!
//! The all-users provisioning APIs require `LocalSystem`; the
//! per-user registration runs impersonated as the installing user.
//! Exit code policy:
//!
//! - `0` on success.
//! - `0` if the AppX deployment service reports the package as not
//!   supported on this Windows build. The MSI `LaunchCondition` in
//!   `sparse-package.wxs` should make this unreachable, but we
//!   handle it as defence-in-depth (e.g. someone bypasses the
//!   condition via `msiexec /q` flags).
//! - **non-zero** on every other failure. Wrong PFN, AppX service
//!   wedged, missing payload, permissions — these all surface
//!   loudly via the `Return="check"` MSI CA wiring + a Sentry event
//!   (DSN = same as the GUI's, so install failures show up next to
//!   runtime crashes) + the `register-sparse.log` file the install
//!   canary captures.

use anyhow::{Context, ErrorExt, Result};
use clap::Parser;
use firezone_gui_client::PACKAGE_FAMILY_NAME;
use std::{fmt, process::ExitCode};

#[tokio::main(flavor = "current_thread")]
async fn main() -> ExitCode {
    rustls::crypto::ring::default_provider()
        .install_default()
        .expect("Failed to install default crypto provider");

    telemetry::configure(
        std::sync::Arc::new(socket_factory::tcp),
        std::sync::Arc::new(socket_factory::udp),
    );
    telemetry::start(
        "entrypoint",
        firezone_gui_client::RELEASE,
        telemetry::GUI_DSN,
    );

    let exit_code = run();

    telemetry::stop().await;
    exit_code
}

fn run() -> ExitCode {
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
        pfn = %PACKAGE_FAMILY_NAME,
        "register-sparse invoked"
    );

    let started = std::time::Instant::now();
    let result = match action {
        Action::Provision => imp::provision(),
        Action::RegisterUser => imp::register_user(),
        Action::Deprovision => imp::deprovision(),
    };
    let elapsed = started.elapsed();

    match result {
        Ok(()) => {
            tracing::info!(%action, ?elapsed, "completed");
            ExitCode::SUCCESS
        }
        Err(e) if e.any_is::<NotSupported>() => {
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

#[derive(Parser)]
#[command(disable_version_flag = true)]
struct Cli {
    action: Action,
}

#[derive(clap::ValueEnum, Clone, Copy)]
enum Action {
    /// Stage + provision the package for all users.
    Provision,
    /// Register the package for the current (impersonated) user.
    RegisterUser,
    /// Deprovision the package for all users.
    Deprovision,
}

impl fmt::Display for Action {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Action::Provision => "provision",
            Action::RegisterUser => "register-user",
            Action::Deprovision => "deprovision",
        })
    }
}

/// Marker attached (via `anyhow::Error::new`) to a deployment error
/// when the AppX deployment service reports
/// `APPMODEL_ERROR_PACKAGE_NOT_SUPPORTED`. The MSI `LaunchCondition`
/// in `sparse-package.wxs` requires Win10 21H2 / build 19044+, so
/// this shouldn't fire in practice; `main` still downcasts on it for
/// graceful skip rather than failing the install if it somehow does.
#[derive(Debug)]
struct NotSupported;

impl fmt::Display for NotSupported {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("sparse MSIX not supported on this Windows build")
    }
}

impl std::error::Error for NotSupported {}

#[cfg(windows)]
mod imp {
    use super::NotSupported;
    use anyhow::{Context, Result, anyhow};
    use firezone_gui_client::PACKAGE_FAMILY_NAME;
    use std::{path::PathBuf, time::Instant};
    use windows::{
        ApplicationModel::Package,
        Foundation::Uri,
        Management::Deployment::{
            DeploymentResult, PackageManager, RemovalOptions, StagePackageOptions,
        },
        core::HSTRING,
    };

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
    ///
    /// Any pre-existing registration of our PFN is removed first.
    /// An upgrade or repair install puts the binaries at a different
    /// path than the previous install, and AppX refuses to re-stage
    /// the same PFN at a new external location (the kernel returns
    /// `0x80073D0B` / `ERROR_INSTALL_PACKAGE_NOT_SUPPORTED_ON_FILESYSTEM`
    /// in that case). Removing the stale registrations first lets
    /// the new stage/provision succeed.
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
        let pfn = package_family_name();

        remove_existing_packages(&pm, &pfn)?;

        let msix_uri = file_uri(msix.as_path())?;
        let external_uri = dir_uri(install_path.as_path())?;

        let stage_opts = StagePackageOptions::new().context("StagePackageOptions::new failed")?;
        stage_opts
            .SetExternalLocationUri(&external_uri)
            .context("SetExternalLocationUri failed")?;
        run_deployment("stage", || {
            tracing::info!(
                external_uri = %uri_string(&external_uri),
                msix_uri = %uri_string(&msix_uri),
                "calling StagePackageByUriAsync"
            );
            Ok(pm.StagePackageByUriAsync(&msix_uri, &stage_opts)?.get()?)
        })?;

        run_deployment("provision", || {
            tracing::info!(pfn = %pfn.to_string_lossy(), "calling ProvisionPackageForAllUsersAsync");
            Ok(pm.ProvisionPackageForAllUsersAsync(&pfn)?.get()?)
        })
    }

    /// Registers the package for the current (impersonated) user, so
    /// the installing user's first GUI launch already carries package
    /// identity (provisioning alone doesn't register external-location
    /// sparse packages for interactive users). Delegates to the shared
    /// [`firezone_gui_client::package_identity::register_for_current_user`]
    /// that the GUI's launch-time check uses too.
    pub fn register_user() -> Result<()> {
        firezone_gui_client::package_identity::register_for_current_user()
    }

    /// Inverse of [`provision`]. Removes every per-user package
    /// instance (across every user, including ones currently logged
    /// off) and clears the all-users provisioning record so new
    /// logons don't re-register the package.
    pub fn deprovision() -> Result<()> {
        let pm = package_manager()?;
        let pfn = package_family_name();

        remove_existing_packages(&pm, &pfn)?;

        run_deployment("deprovision", || {
            tracing::info!(pfn = %pfn.to_string_lossy(), "calling DeprovisionPackageForAllUsersAsync");
            Ok(pm.DeprovisionPackageForAllUsersAsync(&pfn)?.get()?)
        })
    }

    /// Enumerates every package the kernel has registered under our
    /// PFN and removes each one with `RemoveForAllUsers`. No-op when
    /// nothing's registered.
    ///
    /// `RemoveForAllUsers` (instead of the default `None`) is what
    /// actually clears per-user registrations for users other than
    /// `LocalSystem` (the calling user). Without it, registrations
    /// for already-logged-in users linger in the package store and
    /// trip `0x80073D0B`
    /// (`ERROR_INSTALL_PACKAGE_NOT_SUPPORTED_ON_FILESYSTEM`) the
    /// next time we try to stage at a different external location.
    ///
    /// Used by both [`provision`] (to clear stale registrations
    /// before re-staging at a new path) and [`deprovision`] (as the
    /// actual uninstall step).
    fn remove_existing_packages(pm: &PackageManager, pfn: &HSTRING) -> Result<()> {
        let packages: Vec<Package> = pm
            .FindPackagesByPackageFamilyName(pfn)
            .context("FindPackagesByPackageFamilyName failed")?
            .into_iter()
            .collect();

        tracing::info!(
            pfn = %pfn.to_string_lossy(),
            count = packages.len(),
            "enumerated existing packages"
        );

        for pkg in packages {
            let full_name = pkg
                .Id()
                .context("Package::Id failed")?
                .FullName()
                .context("PackageId::FullName failed")?;
            run_deployment("remove", || {
                tracing::info!(
                    package = %full_name.to_string_lossy(),
                    "calling RemovePackageWithOptionsAsync(RemoveForAllUsers)"
                );
                Ok(pm
                    .RemovePackageWithOptionsAsync(&full_name, RemovalOptions::RemoveForAllUsers)?
                    .get()?)
            })?;
        }

        Ok(())
    }

    /// Calls a `PackageManager::*Async` deployment method, awaits
    /// it, logs the `DeploymentResult` fields (timing + AppX
    /// `ExtendedErrorCode` + `ErrorText` + `ActivityId`), and
    /// propagates either a [`NotSupported`] (graceful skip in
    /// `main`) or a regular error. The closure returns
    /// `Result<DeploymentResult>` so callers use `?` on the
    /// underlying `windows_core::Result`s.
    fn run_deployment(
        op_name: &str,
        do_op: impl FnOnce() -> Result<DeploymentResult>,
    ) -> Result<()> {
        /// `APPMODEL_ERROR_PACKAGE_NOT_SUPPORTED`. Returned by AppX
        /// when the package's `MinVersion` floor isn't met or the OS
        /// image has external-location-sparse-MSIX support disabled.
        const APPMODEL_ERROR_PACKAGE_NOT_SUPPORTED: u32 = 0x80073D54;

        let started = Instant::now();
        let result = do_op().with_context(|| format!("{op_name} failed"))?;
        let elapsed = started.elapsed();

        let hr = result.ExtendedErrorCode().context("ExtendedErrorCode")?;
        let error_text = result
            .ErrorText()
            .ok()
            .map(|s| s.to_string_lossy())
            .unwrap_or_default();
        let activity_id = result.ActivityId().ok().map(|g| format!("{g:?}"));
        tracing::info!(
            op = op_name,
            ?elapsed,
            hr = ?hr,
            error_text,
            activity_id,
            "deployment result"
        );

        if hr.is_ok() {
            return Ok(());
        }
        if hr.0 as u32 == APPMODEL_ERROR_PACKAGE_NOT_SUPPORTED {
            return Err(anyhow::Error::new(NotSupported));
        }
        Err(anyhow!(
            "deployment {op_name} failed: {hr:?} ({error_text})"
        ))
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
        let parent = exe.parent().context("current_exe has no parent")?;
        Ok(parent.to_path_buf())
    }

    /// Builds a `file:///…/` URI for a directory path. Forward-slash
    /// separators because `Windows.Foundation.Uri` would otherwise
    /// interpret backslashes as escape sequences. **Trailing slash
    /// is load-bearing**: the kernel resolves the manifest's
    /// `Executable=` paths against this URI per RFC 3986 relative-
    /// reference rules, and without the trailing `/` the last path
    /// segment is treated as a filename and replaced — so an install
    /// at `C:\Program Files\Firezone` ends up looking for
    /// `file:///C:/Program Files/Firezone.exe` instead of
    /// `file:///C:/Program Files/Firezone/Firezone.exe`, and no
    /// EXE matches the package's identity-attachment table.
    fn dir_uri(path: &std::path::Path) -> Result<Uri> {
        let s = path.to_string_lossy().replace('\\', "/");
        let uri = format!("file:///{}/", s.trim_end_matches('/'));
        Uri::CreateUri(&HSTRING::from(uri.as_str())).context("Uri::CreateUri failed")
    }

    fn file_uri(path: &std::path::Path) -> Result<Uri> {
        let s = path.to_string_lossy().replace('\\', "/");
        let uri = format!("file:///{s}");
        Uri::CreateUri(&HSTRING::from(uri.as_str())).context("Uri::CreateUri failed")
    }

    /// `HSTRING` of the manifest's Package Family Name. `HSTRING` is
    /// heap-allocated (no `const` ctor), so each call builds a new one;
    /// callers grab one and pass it to the AppX deployment APIs which
    /// take `&HSTRING`.
    fn package_family_name() -> HSTRING {
        HSTRING::from(PACKAGE_FAMILY_NAME)
    }

    /// Renders a `Windows.Foundation.Uri` as its raw `file:///…`
    /// string, swallowing the (very unlikely) read error to keep the
    /// `tracing::info!` payloads clean.
    fn uri_string(uri: &Uri) -> String {
        uri.RawUri()
            .map(|s| s.to_string_lossy())
            .unwrap_or_default()
    }
}

#[cfg(not(windows))]
mod imp {
    use anyhow::{Result, bail};

    pub fn provision() -> Result<()> {
        bail!("`register-sparse` is only supported on Windows");
    }

    pub fn register_user() -> Result<()> {
        bail!("`register-sparse` is only supported on Windows");
    }

    pub fn deprovision() -> Result<()> {
        bail!("`register-sparse` is only supported on Windows");
    }
}
