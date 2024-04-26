//! Implementation, Linux-specific

use super::{Cli, IpcClientMsg, IpcServerMsg, TOKEN_ENV_KEY};
use anyhow::{bail, Context as _, Result};
use connlib_client_shared::{Callbacks, ResourceDescription, Sockets};
use connlib_shared::{
    keypair,
    linux::{etc_resolv_conf, get_dns_control_from_env, DnsControlMethod},
    LoginUrl,
};
use futures::{SinkExt, StreamExt};
use std::{
    net::{IpAddr, Ipv4Addr, Ipv6Addr},
    os::unix::fs::PermissionsExt,
    path::{Path, PathBuf},
    str::FromStr,
    task::{Context, Poll},
};
use tokio::{
    net::{UnixListener, UnixStream},
    signal::unix::SignalKind as TokioSignalKind,
    sync::mpsc,
};
use tokio_util::codec::{FramedRead, FramedWrite, LengthDelimitedCodec};
use url::Url;

// The Client currently must run as root to control DNS
// Root group and user are used to check file ownership on the token
const ROOT_GROUP: u32 = 0;
const ROOT_USER: u32 = 0;

pub(crate) struct Signals {
    sighup: tokio::signal::unix::Signal,
    sigint: tokio::signal::unix::Signal,
}

impl Signals {
    pub(crate) fn new() -> Result<Self> {
        let sighup = tokio::signal::unix::signal(TokioSignalKind::hangup())?;
        let sigint = tokio::signal::unix::signal(TokioSignalKind::interrupt())?;

        Ok(Self { sighup, sigint })
    }

    pub(crate) fn poll(&mut self, cx: &mut Context) -> Poll<super::SignalKind> {
        if self.sigint.poll_recv(cx).is_ready() {
            return Poll::Ready(super::SignalKind::Interrupt);
        }

        if self.sighup.poll_recv(cx).is_ready() {
            return Poll::Ready(super::SignalKind::Hangup);
        }

        Poll::Pending
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
fn get_system_default_resolvers_systemd_resolved() -> Result<Vec<IpAddr>> {
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

pub(crate) fn run_ipc_service(cli: Cli) -> Result<()> {
    let rt = tokio::runtime::Runtime::new()?;
    tracing::info!("run_daemon");
    rt.block_on(async { ipc_listen(cli).await })
}

async fn ipc_listen(cli: Cli) -> Result<()> {
    // Find the `firezone` group
    let fz_gid = nix::unistd::Group::from_name("firezone")
        .context("can't get group by name")?
        .context("firezone group must exist on the system")?
        .gid;

    // Remove the socket if a previous run left it there
    let sock_path = sock_path();
    tokio::fs::remove_file(&sock_path).await.ok();
    let listener = UnixListener::bind(&sock_path).context("Couldn't bind UDS")?;
    std::os::unix::fs::chown(&sock_path, Some(ROOT_USER), Some(fz_gid.into()))
        .context("can't set firezone as the group for the UDS")?;
    let perms = std::fs::Permissions::from_mode(0o660);
    std::fs::set_permissions(sock_path, perms)?;
    sd_notify::notify(true, &[sd_notify::NotifyState::Ready])?;

    loop {
        tracing::info!("Listening for GUI to connect over IPC...");
        let (stream, _) = listener.accept().await?;
        let cred = stream.peer_cred()?;
        tracing::info!(
            uid = cred.uid(),
            gid = cred.gid(),
            pid = cred.pid(),
            "Got an IPC connection"
        );

        // I'm not sure if we can enforce group membership here - Docker
        // might just be enforcing it with filesystem permissions.
        // Checking the secondary groups of another user looks complicated.
        if let Err(error) = handle_ipc_client(&cli, stream).await {
            tracing::error!(?error, "Error while handling IPC client");
        }
    }
}

#[derive(Clone)]
struct CallbackHandlerIpc {
    cb_tx: mpsc::Sender<IpcServerMsg>,
}

impl Callbacks for CallbackHandlerIpc {
    fn on_disconnect(&self, _error: &connlib_client_shared::Error) {
        self.cb_tx
            .try_send(IpcServerMsg::OnDisconnect)
            .expect("should be able to send OnDisconnect");
    }

    fn on_set_interface_config(&self, _: Ipv4Addr, _: Ipv6Addr, _: Vec<IpAddr>) -> Option<i32> {
        tracing::info!("TunnelReady");
        self.cb_tx
            .try_send(IpcServerMsg::TunnelReady)
            .expect("Should be able to send TunnelReady");
        None
    }

    fn on_update_resources(&self, resources: Vec<ResourceDescription>) {
        tracing::info!(len = resources.len(), "New resource list");
        self.cb_tx
            .try_send(IpcServerMsg::OnUpdateResources(resources))
            .expect("Should be able to send OnUpdateResources");
    }
}

async fn handle_ipc_client(cli: &Cli, stream: UnixStream) -> Result<()> {
    connlib_shared::deactivate_dns_control()?;
    let (rx, tx) = stream.into_split();
    let mut rx = FramedRead::new(rx, LengthDelimitedCodec::new());
    let mut tx = FramedWrite::new(tx, LengthDelimitedCodec::new());
    let (cb_tx, mut cb_rx) = mpsc::channel(100);

    let send_task = tokio::spawn(async move {
        while let Some(msg) = cb_rx.recv().await {
            tx.send(serde_json::to_string(&msg)?.into()).await?;
        }
        Ok::<_, anyhow::Error>(())
    });

    let mut connlib = None;
    let callback_handler = CallbackHandlerIpc { cb_tx };
    while let Some(msg) = rx.next().await {
        let msg = msg?;
        let msg: super::IpcClientMsg = serde_json::from_slice(&msg)?;

        match msg {
            IpcClientMsg::Connect { api_url, token } => {
                let token = secrecy::SecretString::from(token);
                assert!(connlib.is_none());
                let device_id = connlib_shared::device_id::get()
                    .context("Failed to read / create device ID")?;
                let (private_key, public_key) = keypair();

                let login = LoginUrl::client(
                    Url::parse(&api_url)?,
                    &token,
                    device_id.id,
                    None,
                    public_key.to_bytes(),
                )?;

                connlib = Some(connlib_client_shared::Session::connect(
                    login,
                    Sockets::new(),
                    private_key,
                    None,
                    callback_handler.clone(),
                    cli.max_partition_time.map(|t| t.into()),
                    tokio::runtime::Handle::try_current()?,
                ));
            }
            IpcClientMsg::Disconnect => {
                if let Some(connlib) = connlib.take() {
                    connlib.disconnect();
                }
            }
            IpcClientMsg::Reconnect => connlib.as_mut().context("No connlib session")?.reconnect(),
            IpcClientMsg::SetDns(v) => connlib.as_mut().context("No connlib session")?.set_dns(v),
        }
    }

    send_task.abort();

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
