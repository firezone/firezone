//! Management commands for a daemon installed from the package: storing the
//! token the service runs with and enabling the service.

#![expect(
    clippy::print_stdout,
    reason = "These commands talk to the user directly."
)]

use anyhow::{Context, Result};
use secrecy::{ExposeSecret as _, SecretString};

/// Where the service's token lives; the unit loads it as a credential.
pub(crate) const TOKEN_PATH: &str = "/etc/firezone/gateway-token";

const SERVICE: &str = "firezone.service";

pub(crate) fn authenticate(replace: bool) -> Result<()> {
    ensure_root()?;

    if let Ok(existing) = std::fs::read_to_string(TOKEN_PATH)
        && !existing.trim().is_empty()
        && !replace
    {
        anyhow::bail!("Found existing token at {TOKEN_PATH}, use --replace to overwrite");
    }

    let token = loop {
        println!("Paste the token from the portal's deploy page:");

        let token = rpassword::read_password().context("Failed to read token from stdin")?;

        if token.trim().is_empty() {
            continue;
        }

        break SecretString::new(token.into_boxed_str());
    };

    write_token(token.expose_secret())
        .with_context(|| format!("Failed to write to `{TOKEN_PATH}`"))?;

    println!("Successfully installed token");
    println!("Tip: You can now start the service with `firezone enable-service`");

    Ok(())
}

pub(crate) fn enable_service() -> Result<()> {
    ensure_root()?;
    systemctl(&format!("enable --now {SERVICE}"))
        .with_context(|| format!("Failed to enable `{SERVICE}`"))?;

    println!("Successfully enabled `{SERVICE}`");

    Ok(())
}

pub(crate) fn disable_service() -> Result<()> {
    ensure_root()?;
    systemctl(&format!("disable {SERVICE}"))
        .with_context(|| format!("Failed to disable `{SERVICE}`"))?;

    println!("Successfully disabled `{SERVICE}`");

    Ok(())
}

fn ensure_root() -> Result<()> {
    anyhow::ensure!(
        cfg!(target_os = "linux"),
        "Only supported on Linux right now"
    );
    anyhow::ensure!(is_root(), "Must be executed as root");

    Ok(())
}

#[cfg(target_os = "linux")]
fn write_token(token: &str) -> Result<()> {
    use std::io::Write as _;
    use std::os::unix::fs::{OpenOptionsExt as _, PermissionsExt as _};

    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o400)
        .open(TOKEN_PATH)?;

    // `mode` only applies when the file is created.
    file.set_permissions(std::fs::Permissions::from_mode(0o400))?;
    file.write_all(token.as_bytes())?;

    Ok(())
}

#[cfg(not(target_os = "linux"))]
fn write_token(token: &str) -> Result<()> {
    std::fs::write(TOKEN_PATH, token)?;

    Ok(())
}

#[cfg(target_os = "linux")]
fn is_root() -> bool {
    nix::unistd::Uid::current().is_root()
}

#[cfg(not(target_os = "linux"))]
fn is_root() -> bool {
    true
}

fn systemctl(args: &str) -> Result<()> {
    let output = std::process::Command::new("systemctl")
        .args(args.split_ascii_whitespace())
        .output()?;

    anyhow::ensure!(
        output.status.success(),
        "`systemctl {args}` exited with {}",
        output.status
    );

    Ok(())
}
