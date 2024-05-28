//! Implementation, Linux-specific

use super::{CliCommon, SignalKind, FIREZONE_GROUP, TOKEN_ENV_KEY};
use anyhow::{bail, Context as _, Result};
use connlib_client_shared::file_logger;
use connlib_shared::linux::{etc_resolv_conf, get_dns_control_from_env, DnsControlMethod};
use firezone_cli_utils::setup_global_subscriber;
use futures::future::{select, Either};
use std::{
    net::IpAddr,
    os::unix::fs::PermissionsExt,
    path::{Path, PathBuf},
    pin::pin,
    str::FromStr,
};
use tokio::{
    net::{UnixListener, UnixStream},
    signal::unix::{signal, Signal, SignalKind as TokioSignalKind},
};

// The Client currently must run as root to control DNS
// Root group and user are used to check file ownership on the token
const ROOT_GROUP: u32 = 0;
const ROOT_USER: u32 = 0;

pub(crate) struct Signals {
    sighup: Signal,
    sigint: Signal,
}

impl Signals {
    pub(crate) fn new() -> Result<Self> {
        let sighup = signal(TokioSignalKind::hangup())?;
        let sigint = signal(TokioSignalKind::interrupt())?;

        Ok(Self { sighup, sigint })
    }

    pub(crate) async fn recv(&mut self) -> SignalKind {
        match select(pin!(self.sighup.recv()), pin!(self.sigint.recv())).await {
            Either::Left((_, _)) => SignalKind::Hangup,
            Either::Right((_, _)) => SignalKind::Interrupt,
        }
    }
}

pub fn default_token_path() -> PathBuf {
    PathBuf::from("/etc")
        .join(connlib_shared::BUNDLE_ID)
        .join("token")
}

pub(crate) fn check_token_permissions(path: &Path) -> Result<()> {
    let Ok(stat) = nix::sys::stat::fstatat(None, path, nix::fcntl::AtFlags::empty()) else {
        // File doesn't exist or can't be read
        tracing::info!(
            ?path,
            ?TOKEN_ENV_KEY,
            "No token found in env var or on disk"
        );
        bail!("Token file doesn't exist");
    };
    if stat.st_uid != ROOT_USER {
        bail!(
            "Token file `{}` should be owned by root user",
            path.display()
        );
    }
    if stat.st_gid != ROOT_GROUP {
        bail!(
            "Token file `{}` should be owned by root group",
            path.display()
        );
    }
    if stat.st_mode & 0o177 != 0 {
        bail!(
            "Token file `{}` should have mode 0o400 or 0x600",
            path.display()
        );
    }
    Ok(())
}

pub(crate) fn system_resolvers() -> Result<Vec<IpAddr>> {
    match get_dns_control_from_env() {
        None => get_system_default_resolvers_resolv_conf(),
        Some(DnsControlMethod::EtcResolvConf) => get_system_default_resolvers_resolv_conf(),
        Some(DnsControlMethod::NetworkManager) => get_system_default_resolvers_network_manager(),
        Some(DnsControlMethod::Systemd) => get_system_default_resolvers_systemd_resolved(),
    }
}

fn get_system_default_resolvers_resolv_conf() -> Result<Vec<IpAddr>> {
    // Assume that `configure_resolv_conf` has run in `tun_linux.rs`

    let s = std::fs::read_to_string(etc_resolv_conf::ETC_RESOLV_CONF_BACKUP)
        .or_else(|_| std::fs::read_to_string(etc_resolv_conf::ETC_RESOLV_CONF))
        .context("`resolv.conf` should be readable")?;
    let parsed = resolv_conf::Config::parse(s).context("`resolv.conf` should be parsable")?;

    // Drop the scoping info for IPv6 since connlib doesn't take it
    let nameservers = parsed
        .nameservers
        .into_iter()
        .map(|addr| addr.into())
        .collect();
    Ok(nameservers)
}

#[allow(clippy::unnecessary_wraps)]
fn get_system_default_resolvers_network_manager() -> Result<Vec<IpAddr>> {
    tracing::error!("get_system_default_resolvers_network_manager not implemented yet");
    Ok(vec![])
}

/// Returns the DNS servers listed in `resolvectl dns`
pub fn get_system_default_resolvers_systemd_resolved() -> Result<Vec<IpAddr>> {
    // Unfortunately systemd-resolved does not have a machine-readable
    // text output for this command: <https://github.com/systemd/systemd/issues/29755>
    //
    // The officially supported way is probably to use D-Bus.
    let output = std::process::Command::new("resolvectl")
        .arg("dns")
        .output()
        .context("Failed to run `resolvectl dns` and read output")?;
    if !output.status.success() {
        anyhow::bail!("`resolvectl dns` returned non-zero exit code");
    }
    let output = String::from_utf8(output.stdout).context("`resolvectl` output was not UTF-8")?;
    Ok(parse_resolvectl_output(&output))
}

/// Parses the text output of `resolvectl dns`
///
/// Cannot fail. If the parsing code is wrong, the IP address vec will just be incomplete.
fn parse_resolvectl_output(s: &str) -> Vec<IpAddr> {
    s.lines()
        .flat_map(|line| line.split(' '))
        .filter_map(|word| IpAddr::from_str(word).ok())
        .collect()
}

/// The path for our Unix Domain Socket
///
/// Docker keeps theirs in `/run` and also appears to use filesystem permissions
/// for security, so we're following their lead. `/run` and `/var/run` are symlinked
/// on some systems, `/run` should be the newer version.
///
/// Also systemd can create this dir with the `RuntimeDir=` directive which is nice.
pub fn sock_path() -> PathBuf {
    PathBuf::from("/run")
        .join(connlib_shared::BUNDLE_ID)
        .join("ipc.sock")
}

/// Cross-platform entry point for systemd / Windows services
///
/// Linux uses the CLI args from here, Windows does not
pub(crate) fn run_ipc_service(cli: CliCommon) -> Result<()> {
    tracing::info!("run_ipc_service");
    // systemd supplies this but maybe we should hard-code a better default
    let (layer, _handle) = cli.log_dir.as_deref().map(file_logger::layer).unzip();
    setup_global_subscriber(layer);
    tracing::info!(git_version = crate::GIT_VERSION);

    if !nix::unistd::getuid().is_root() {
        anyhow::bail!("This is the IPC service binary, it's not meant to run interactively.");
    }
    let rt = tokio::runtime::Runtime::new()?;
    rt.block_on(async { crate::ipc_listen().await })
}

pub fn firezone_group() -> Result<nix::unistd::Group> {
    let group = nix::unistd::Group::from_name(FIREZONE_GROUP)
        .context("can't get group by name")?
        .with_context(|| format!("`{FIREZONE_GROUP}` group must exist on the system"))?;
    Ok(group)
}

pub(crate) struct IpcServer {
    listener: UnixListener,
}

/// Opaque wrapper around platform-specific IPC stream
pub(crate) type IpcStream = UnixStream;

impl IpcServer {
    /// Platform-specific setup
    pub(crate) async fn new() -> Result<Self> {
        // Remove the socket if a previous run left it there
        let sock_path = sock_path();
        tokio::fs::remove_file(&sock_path).await.ok();
        let listener = UnixListener::bind(&sock_path).context("Couldn't bind UDS")?;
        let perms = std::fs::Permissions::from_mode(0o660);
        std::fs::set_permissions(sock_path, perms)?;
        sd_notify::notify(true, &[sd_notify::NotifyState::Ready])?;
        Ok(Self { listener })
    }

    pub(crate) async fn next_client(&mut self) -> Result<IpcStream> {
        tracing::info!("Listening for GUI to connect over IPC...");
        let (stream, _) = self.listener.accept().await?;
        let cred = stream.peer_cred()?;
        // I'm not sure if we can enforce group membership here - Docker
        // might just be enforcing it with filesystem permissions.
        // Checking the secondary groups of another user looks complicated.
        tracing::info!(
            uid = cred.uid(),
            gid = cred.gid(),
            pid = cred.pid(),
            "Got an IPC connection"
        );
        Ok(stream)
    }
}

/// Platform-specific setup needed for connlib
///
/// On Linux this does nothing
#[allow(clippy::unnecessary_wraps)]
pub(crate) fn setup_before_connlib() -> Result<()> {
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::net::IpAddr;

    #[test]
    fn parse_resolvectl_output() {
        let cases = [
            // WSL
            (
                r"Global: 172.24.80.1
Link 2 (eth0):
Link 3 (docker0):
Link 24 (br-fc0b71997a3c):
Link 25 (br-0c129dafb204):
Link 26 (br-e67e83b19dce):
",
                [IpAddr::from([172, 24, 80, 1])],
            ),
            // Ubuntu 20.04
            (
                r"Global:
Link 2 (enp0s3): 192.168.1.1",
                [IpAddr::from([192, 168, 1, 1])],
            ),
        ];

        for (i, (input, expected)) in cases.iter().enumerate() {
            let actual = super::parse_resolvectl_output(input);
            assert_eq!(actual, expected, "Case {i} failed");
        }
    }
}
