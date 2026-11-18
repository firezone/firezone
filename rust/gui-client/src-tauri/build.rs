use anyhow::{Context as _, Result};
use std::{fs, path::PathBuf};
use windows_package_identity::PACKAGE_FAMILY_NAME;

/// Must match `<Application Id="…"/>` in `win_files/AppxManifest.xml`.
const PACKAGE_APPLICATION_ID: &str = "Firezone";

const WIX_PACKAGE_IDENTITY: &str = "firezone-package-identity.wxi";

fn main() -> Result<()> {
    // Release builds embed our own SXS / fusion manifest below -- only
    // into `Firezone.exe`, not into the tunnel-service or
    // register-sparse binaries (SCM-launched services with an embedded
    // `<msix>` identity claim hang on startup, and the helper has no
    // use for identity).
    //
    // Non-release profiles (dev, profiling, …) embed no manifest:
    // a non-release binary run from `target\<profile>` typically has
    // no registered sparse package on the dev box, and an embedded
    // MSIX identity claim makes the kernel fail `CreateProcess` with
    // `APPMODEL_ERROR_NO_PACKAGE` (15700) before `main` even runs. The
    // runtime's debug-only `test_pipe_dacl` path (gated on
    // `SKIP_PEER_VERIFICATION`) covers IPC without needing
    // identity.
    //
    // We gate on Cargo's `PROFILE` env var rather than
    // `cfg!(debug_assertions)` so the `profiling` profile (inherits
    // from `release` in `.cargo/config.toml`, but still runs
    // un-packaged from `target\profiling`) does not embed the
    // manifest. Only an actual `--profile release` build does.
    println!("cargo:rerun-if-env-changed=PROFILE");

    #[cfg(target_os = "windows")]
    embed_icon_and_version()?;

    #[cfg(target_os = "windows")]
    if std::env::var("PROFILE").as_deref() == Ok("release") {
        embed_resource::compile_for(
            "win_files/Firezone.exe.manifest.rc",
            ["firezone-gui-client"],
            embed_resource::NONE,
        )
        .manifest_required()?;

        println!("cargo:rerun-if-changed=win_files/Firezone.exe.manifest");
        println!("cargo:rerun-if-changed=win_files/Firezone.exe.manifest.rc");
    }

    println!("cargo:rerun-if-changed=../policy-templates/windows/firezone.admx");

    // `FIREZONE_NO_TELEMETRY` is also a run-time flag, but the MSI runs
    // `register-sparse.exe` with an environment we do not control, so CI stamps the
    // build-time value in as well.
    println!("cargo:rerun-if-env-changed=FIREZONE_NO_TELEMETRY");
    println!("cargo:rustc-check-cfg=cfg(no_telemetry)");
    if std::env::var("FIREZONE_NO_TELEMETRY").as_deref() == Ok("true") {
        println!("cargo:rustc-cfg=no_telemetry");
    }

    write_wix_package_identity(PACKAGE_FAMILY_NAME)?;

    Ok(())
}

/// Gives every binary the app icon and the version the MSI compares on upgrades.
#[cfg(target_os = "windows")]
fn embed_icon_and_version() -> Result<()> {
    let version = std::env::var("CARGO_PKG_VERSION")?;
    let numeric = version.replace('.', ",");
    let icon = PathBuf::from(std::env::var("CARGO_MANIFEST_DIR")?).join("icons/icon.ico");
    let rc = PathBuf::from(std::env::var("OUT_DIR")?).join("resources.rc");

    fs::write(
        &rc,
        format!(
            r#"1 ICON "{icon}"
1 VERSIONINFO
FILEVERSION {numeric},0
PRODUCTVERSION {numeric},0
BEGIN
  BLOCK "StringFileInfo"
  BEGIN
    BLOCK "040904b0"
    BEGIN
      VALUE "CompanyName", "Firezone"
      VALUE "FileDescription", "Firezone"
      VALUE "FileVersion", "{version}"
      VALUE "ProductName", "Firezone"
      VALUE "ProductVersion", "{version}"
    END
  END
  BLOCK "VarFileInfo"
  BEGIN
    VALUE "Translation", 0x409, 1200
  END
END
"#,
            icon = icon.display().to_string().replace('\\', "\\\\"),
        ),
    )
    .context("write resource script")?;

    embed_resource::compile(&rc, embed_resource::NONE).manifest_required()?;
    println!("cargo:rerun-if-changed=icons/icon.ico");

    Ok(())
}

fn write_wix_package_identity(package_family_name: &str) -> Result<()> {
    let out_dir = PathBuf::from(std::env::var("OUT_DIR").context("OUT_DIR not set")?);
    let profile_dir = out_dir
        .ancestors()
        .nth(3)
        .context("OUT_DIR is not under target/<profile>/build/<package>/out")?;
    let wix_include = profile_dir.join(WIX_PACKAGE_IDENTITY);

    fs::write(
        wix_include,
        format!(
            r#"<?xml version="1.0" encoding="utf-8"?>
<Include>
  <?define FirezonePackageAppUserModelId = "{package_family_name}!{PACKAGE_APPLICATION_ID}" ?>
</Include>
"#
        ),
    )
    .context("write WiX package identity include")
}
