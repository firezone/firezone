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

/// Returned by [`ensure_package_identity`] on Windows when the running
/// image fails its own Authenticode signature with a *bad digest* — it
/// was modified after signing. Package identity attaches only to a
/// binary that validates against the package publisher, so the kernel
/// will never stamp identity onto a tampered image and no restart can
/// help. The caller surfaces a "reinstall" dialog instead of looping on
/// the restart prompt.
#[derive(Debug, thiserror::Error)]
#[error("Firezone.exe failed its Authenticode signature (bad digest); the installation is corrupt")]
pub struct InstallationCorrupt;

/// Ensures the current process carries the Firezone package identity
/// that the pipe DACLs pin access to.
///
/// - `Ok(())` if the process already has identity (or on non-Windows,
///   which has none) — continue startup.
/// - `Err(`[`RestartRequired`]`)` if it didn't, but we registered the
///   package for the current user (no admin needed once provisioned).
///   Identity only attaches on the next launch, so the caller should
///   tell the user to relaunch and exit.
/// - `Err(`[`InstallationCorrupt`]`)` (Windows) if the running image
///   fails its own Authenticode signature with a bad digest, so
///   identity can never attach and a restart wouldn't help.
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

    // No identity yet. Before registering and asking for a restart,
    // rule out the one case a restart can never fix: our own image
    // failing its Authenticode signature with a bad digest (modified
    // after signing). The kernel won't attach identity to a tampered
    // binary, so that would loop on the restart prompt forever.
    verify_self_signature()?;

    register_for_current_user()?;
    Err(RestartRequired.into())
}

/// `Windows.ApplicationModel.Package.Current` succeeds only for a
/// process activated with package identity; on a non-packaged process
/// it errors, which is our signal to register for the current user.
#[cfg(target_os = "windows")]
fn has_package_identity() -> bool {
    windows::ApplicationModel::Package::Current().is_ok()
}

/// Verifies the running image against its own Authenticode signature
/// and maps a *bad digest* — a binary modified after signing — to
/// [`InstallationCorrupt`].
///
/// Package identity attaches at `CreateProcess` only to a binary that
/// validates against the package publisher, so a tampered `Firezone.exe`
/// can never gain it and [`ensure_package_identity`] would loop on the
/// restart prompt forever. Detecting this up front lets the caller tell
/// the user to reinstall instead.
///
/// Only `TRUST_E_BAD_DIGEST` is treated as fatal. Any other status — an
/// unsigned profiling build, an untrusted chain on a locked-down box, a
/// transient verification error — is logged and allowed through to the
/// normal register / restart path, so a genuine first run is never
/// misreported as corrupt.
#[cfg(target_os = "windows")]
fn verify_self_signature() -> Result<()> {
    use anyhow::Context as _;
    use std::{ffi::c_void, os::windows::ffi::OsStrExt as _};
    use windows::{
        Win32::{
            Foundation::{HANDLE, HWND},
            Security::WinTrust::{
                WINTRUST_DATA, WINTRUST_DATA_0, WINTRUST_FILE_INFO, WTD_CHOICE_FILE,
                WTD_REVOKE_NONE, WTD_STATEACTION_CLOSE, WTD_STATEACTION_VERIFY, WTD_UI_NONE,
                WinVerifyTrust,
            },
        },
        core::{GUID, PCWSTR},
    };

    /// Standard Authenticode verification policy for `WinVerifyTrust`
    /// (`WINTRUST_ACTION_GENERIC_VERIFY_V2`).
    const GENERIC_VERIFY_V2: GUID = GUID::from_u128(0x00aac56b_cd44_11d0_8cc2_00c04fc295ee);
    /// `TRUST_E_BAD_DIGEST`: the file's hash doesn't match its
    /// signature, i.e. it was modified after signing.
    const TRUST_E_BAD_DIGEST: i32 = 0x80096010u32 as i32;

    let exe = std::env::current_exe().context("current_exe")?;
    let path: Vec<u16> = exe
        .as_os_str()
        .encode_wide()
        .chain(std::iter::once(0))
        .collect();

    let mut file_info = WINTRUST_FILE_INFO {
        cbStruct: std::mem::size_of::<WINTRUST_FILE_INFO>() as u32,
        pcwszFilePath: PCWSTR(path.as_ptr()),
        hFile: HANDLE::default(),
        pgKnownSubject: std::ptr::null_mut(),
    };

    let mut data = WINTRUST_DATA {
        cbStruct: std::mem::size_of::<WINTRUST_DATA>() as u32,
        dwUIChoice: WTD_UI_NONE,
        fdwRevocationChecks: WTD_REVOKE_NONE,
        dwUnionChoice: WTD_CHOICE_FILE,
        dwStateAction: WTD_STATEACTION_VERIFY,
        Anonymous: WINTRUST_DATA_0 {
            pFile: &mut file_info as *mut _,
        },
        ..Default::default()
    };

    let mut action = GENERIC_VERIFY_V2;

    // SAFETY: `action`, `data` and the `file_info` it points at are
    // valid locals that outlive both calls. `WTD_UI_NONE` keeps the
    // call non-interactive, so the null window handle is fine.
    let status = unsafe {
        WinVerifyTrust(
            HWND::default(),
            &mut action,
            &mut data as *mut _ as *mut c_void,
        )
    };

    // The VERIFY call stashed provider state in `data`; release it.
    data.dwStateAction = WTD_STATEACTION_CLOSE;
    // SAFETY: same invariants; this closes the state we just opened.
    unsafe {
        WinVerifyTrust(
            HWND::default(),
            &mut action,
            &mut data as *mut _ as *mut c_void,
        );
    }

    if status == TRUST_E_BAD_DIGEST {
        return Err(InstallationCorrupt.into());
    }
    if status != 0 {
        tracing::warn!(
            status = %format!("{status:#010x}"),
            "WinVerifyTrust on own image returned non-success; continuing to register"
        );
    }

    Ok(())
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
