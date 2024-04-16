use super::{Cli, Cmd};
use anyhow::{Context, Result};
use clap::Parser;
use connlib_client_shared::{file_logger, Callbacks, Session, Sockets};
use connlib_shared::{
    keypair,
    linux::{etc_resolv_conf, get_dns_control_from_env, DnsControlMethod},
    LoginUrl,
};
use firezone_cli_utils::setup_global_subscriber;
use futures::{SinkExt, StreamExt};
use secrecy::SecretString;
use std::{
    future,
    net::IpAddr,
    path::{Path, PathBuf},
    str::FromStr,
    task::Poll,
};
use tokio::{
    net::{UnixListener, UnixStream},
    signal::unix::SignalKind,
};
use tokio_util::codec::LengthDelimitedCodec;

pub async fn run() -> Result<()> {
    let cli = Cli::parse();
    let (layer, _handle) = cli.log_dir.as_deref().map(file_logger::layer).unzip();
    setup_global_subscriber(layer);

    match cli.command() {
        Cmd::Auto => {
            if let Some(token) = token(&cli).await? {
                run_standalone(cli, &token).await
            } else {
                run_daemon(cli).await
            }
        }
        Cmd::Daemon => run_daemon(cli).await,
        Cmd::DebugIpcClient => run_debug_ipc_client(cli).await,
        Cmd::Standalone => {
            let token = token(&cli)
                .await?
                .context("Need a token to run as standalone Client")?;
            run_standalone(cli, &token).await
        }
    }
}

async fn token(cli: &Cli) -> Result<Option<SecretString>> {
    if let Some(token) = &cli.token {
        // Token was provided in CLI args or env var
        // Not very secure, but we do get the token
        return Ok(Some(token.clone().into()));
    }

    let path = PathBuf::from("/etc")
        .join(connlib_shared::BUNDLE_ID)
        .join("token.txt");
    let Ok(bytes) = tokio::fs::read(path).await else {
        // Can't read the file for some reason, so there's no token on disk
        return Ok(None);
    };
    let s = String::from_utf8(bytes)?;
    let token = s.trim().to_string();

    // Token loaded from disk
    Ok(Some(token.into()))
}

async fn run_standalone(cli: Cli, token: &SecretString) -> Result<()> {
    tracing::info!("run_standalone");
    let max_partition_time = cli.max_partition_time.map(|d| d.into());

    let callbacks = CallbackHandler;

    // AKA "Device ID", not the Firezone slug
    let firezone_id = match cli.firezone_id {
        Some(id) => id,
        None => connlib_shared::device_id::get().context("Could not get `firezone_id` from CLI, could not read it from disk, could not generate it and save it to disk")?.id,
    };

    let (private_key, public_key) = keypair();
    let login = LoginUrl::client(cli.api_url, token, firezone_id, None, public_key.to_bytes())?;

    let session = Session::connect(
        login,
        Sockets::new(),
        private_key,
        None,
        callbacks.clone(),
        max_partition_time,
        tokio::runtime::Handle::current(),
    );
    // TODO: this should be added dynamically
    session.set_dns(system_resolvers(get_dns_control_from_env()).unwrap_or_default());

    let mut sigint = tokio::signal::unix::signal(SignalKind::interrupt())?;
    let mut sighup = tokio::signal::unix::signal(SignalKind::hangup())?;

    future::poll_fn(|cx| loop {
        if sigint.poll_recv(cx).is_ready() {
            tracing::debug!("Received SIGINT");

            return Poll::Ready(std::io::Result::Ok(()));
        }

        if sighup.poll_recv(cx).is_ready() {
            tracing::debug!("Received SIGHUP");

            session.reconnect();
            continue;
        }

        return Poll::Pending;
    })
    .await?;

    session.disconnect();

    Ok(())
}

fn system_resolvers(dns_control_method: Option<DnsControlMethod>) -> Result<Vec<IpAddr>> {
    match dns_control_method {
        None => get_system_default_resolvers_resolv_conf(),
        Some(DnsControlMethod::EtcResolvConf) => get_system_default_resolvers_resolv_conf(),
        Some(DnsControlMethod::NetworkManager) => get_system_default_resolvers_network_manager(),
        Some(DnsControlMethod::Systemd) => get_system_default_resolvers_systemd_resolved(),
    }
}

#[derive(Clone)]
struct CallbackHandler;

impl Callbacks for CallbackHandler {
    fn on_disconnect(&self, error: &connlib_client_shared::Error) {
        tracing::error!("Disconnected: {error}");

        std::process::exit(1);
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

fn sock_path() -> Result<PathBuf> {
    let path = dirs::runtime_dir()
        .context("Failed to get `runtime_dir`")?
        .join("dev.firezone.client_ipc");
    Ok(path)
}

async fn run_debug_ipc_client(_cli: Cli) -> Result<()> {
    tracing::info!(pid = std::process::id(), "run_debug_ipc_client");
    let stream = UnixStream::connect(&sock_path()?)
        .await
        .context("couldn't connect to UDS")?;
    let mut stream = IpcStream::new(stream, LengthDelimitedCodec::new());

    stream.send(serde_json::to_string("Hello")?.into()).await?;
    Ok(())
}

async fn run_daemon(_cli: Cli) -> Result<()> {
    tracing::info!("run_daemon");
    ipc_listen(&sock_path()?).await
}

async fn ipc_listen(sock_path: &Path) -> Result<()> {
    // Remove the socket if a previous run left it there
    tokio::fs::remove_file(sock_path).await.ok();
    let listener = UnixListener::bind(sock_path)?;
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
        // TODO: Check that the user is in the `firezone` group
        // For now, to make it work well in CI where that group isn't created,
        // just check if it matches our own UID.
        let actual_peer_uid = cred.uid();
        let expected_peer_uid = nix::unistd::Uid::current().as_raw();
        if actual_peer_uid != expected_peer_uid {
            tracing::warn!("Connection from un-authorized user, ignoring");
            continue;
        }

        let stream = IpcStream::new(stream, LengthDelimitedCodec::new());
        if let Err(error) = handle_ipc_client(stream).await {
            tracing::error!(?error, "Error while handling IPC client");
        }
    }
}

type IpcStream = tokio_util::codec::Framed<UnixStream, LengthDelimitedCodec>;

async fn handle_ipc_client(mut stream: IpcStream) -> Result<()> {
    tracing::info!("Waiting for an IPC message from the GUI...");

    let v = stream
        .next()
        .await
        .context("Error while reading IPC message")?
        .context("IPC stream empty")?;
    let decoded: String = serde_json::from_slice(&v)?;

    tracing::debug!(?decoded, "Received message");
    stream.send("OK".to_string().into()).await?;
    tracing::info!("Replied. Connection will close");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::IpcStream;
    use futures::{SinkExt, StreamExt};
    use std::net::IpAddr;
    use tokio::net::{UnixListener, UnixStream};
    use tokio_util::codec::LengthDelimitedCodec;

    const MESSAGE_ONE: &str = "message one";
    const MESSAGE_TWO: &str = "message two";

    #[tokio::test]
    async fn ipc() {
        let sock_path = dirs::runtime_dir()
            .unwrap()
            .join("dev.firezone.client_ipc_test");

        // Remove the socket if a previous run left it there
        tokio::fs::remove_file(&sock_path).await.ok();
        let listener = UnixListener::bind(&sock_path).unwrap();

        let ipc_server_task = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let cred = stream.peer_cred().unwrap();
            // TODO: Check that the user is in the `firezone` group
            // For now, to make it work well in CI where that group isn't created,
            // just check if it matches our own UID.
            let actual_peer_uid = cred.uid();
            let expected_peer_uid = nix::unistd::Uid::current().as_raw();
            assert_eq!(actual_peer_uid, expected_peer_uid);

            let mut stream = IpcStream::new(stream, LengthDelimitedCodec::new());

            let v = stream
                .next()
                .await
                .expect("Error while reading IPC message")
                .expect("IPC stream empty");
            let decoded: String = serde_json::from_slice(&v).unwrap();
            assert_eq!(MESSAGE_ONE, decoded);

            let v = stream
                .next()
                .await
                .expect("Error while reading IPC message")
                .expect("IPC stream empty");
            let decoded: String = serde_json::from_slice(&v).unwrap();
            assert_eq!(MESSAGE_TWO, decoded);
        });

        tracing::info!(pid = std::process::id(), "Connecting to IPC server");
        let stream = UnixStream::connect(&sock_path).await.unwrap();
        let mut stream = IpcStream::new(stream, LengthDelimitedCodec::new());

        stream
            .send(serde_json::to_string(MESSAGE_ONE).unwrap().into())
            .await
            .unwrap();
        stream
            .send(serde_json::to_string(MESSAGE_TWO).unwrap().into())
            .await
            .unwrap();

        tokio::time::timeout(std::time::Duration::from_millis(2_000), ipc_server_task)
            .await
            .unwrap()
            .unwrap();
    }

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
