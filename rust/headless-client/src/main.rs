//! The headless Client, AKA standalone Client

#![cfg_attr(test, allow(clippy::unwrap_used))]

use anyhow::{anyhow, Context as _, Result};
use backoff::ExponentialBackoffBuilder;
use clap::Parser;
use connlib_client_shared::Session;
use firezone_bin_shared::{
    new_dns_notifier, new_network_notifier,
    platform::{tcp_socket_factory, udp_socket_factory},
    TunDeviceManager, TOKEN_ENV_KEY,
};
use firezone_headless_client::{
    device_id, signals, CallbackHandler, CliCommon, ConnlibMsg, DnsController,
};
use firezone_logging::telemetry_span;
use firezone_telemetry::Telemetry;
use futures::StreamExt as _;
use phoenix_channel::get_user_agent;
use phoenix_channel::LoginUrl;
use phoenix_channel::PhoenixChannel;
use secrecy::{Secret, SecretString};
use std::{
    alloc::System,
    path::{Path, PathBuf},
    sync::Arc,
    time::Duration,
};
use tokio::{sync::mpsc, time::Instant};
use tokio_stream::wrappers::ReceiverStream;
use tracking_allocator::TrackingAllocator;

#[cfg(target_os = "linux")]
#[path = "linux.rs"]
mod platform;

#[cfg(target_os = "windows")]
#[path = "windows.rs"]
mod platform;

use platform::default_token_path;

#[global_allocator]
static ALLOCATOR: TrackingAllocator<System> = TrackingAllocator::new(System);

/// Command-line args for the headless Client
#[derive(Parser)]
#[command(author, version, about, long_about = None)]
struct Cli {
    // Needed to preserve CLI arg compatibility
    // TODO: Remove when we can break CLI compatibility for headless Clients
    #[command(subcommand)]
    _command: Option<Cmd>,

    #[command(flatten)]
    common: CliCommon,

    #[arg(
        short = 'u',
        long,
        hide = true,
        env = "FIREZONE_API_URL",
        default_value = "wss://api.firezone.dev/"
    )]
    api_url: url::Url,

    /// Check the configuration and return 0 before connecting to the API
    ///
    /// Returns 1 if the configuration is wrong. Mostly non-destructive but may
    /// write a device ID to disk if one is not found.
    #[arg(long)]
    check: bool,

    /// Connect to the Firezone network and initialize, then exit
    ///
    /// Use this to check how fast you can connect.
    #[arg(long)]
    exit: bool,

    /// Friendly name for this client to display in the UI.
    #[arg(long, env = "FIREZONE_NAME")]
    firezone_name: Option<String>,

    /// Identifier used by the portal to identify and display the device.
    // AKA `device_id` in the Windows and Linux GUI clients
    // Generated automatically if not provided
    #[arg(short = 'i', long, env = "FIREZONE_ID")]
    firezone_id: Option<String>,

    /// Disable sentry.io crash-reporting agent.
    #[arg(long, env = "FIREZONE_NO_TELEMETRY", default_value_t = false)]
    no_telemetry: bool,

    /// A filesystem path where the token can be found
    // Apparently passing secrets through stdin is the most secure method, but
    // until anyone asks for it, env vars are okay and files on disk are slightly better.
    // (Since we run as root and the env var on a headless system is probably stored
    // on disk somewhere anyway.)
    #[arg(default_value = default_token_path().display().to_string(), env = "FIREZONE_TOKEN_PATH", long)]
    token_path: PathBuf,
}

impl Cli {
    fn is_telemetry_allowed(&self) -> bool {
        !self.no_telemetry
    }
}

#[derive(clap::Subcommand, Clone, Copy)]
enum Cmd {
    Standalone,
}

const VERSION: &str = env!("CARGO_PKG_VERSION");

fn main() -> Result<()> {
    rustls::crypto::ring::default_provider()
        .install_default()
        .expect("Calling `install_default` only once per process should always succeed");

    let cli = Cli::try_parse()?;

    // Modifying the environment of a running process is unsafe. If any other
    // thread is reading or writing the environment, something bad can happen.
    // So `run` must take over as early as possible during startup, and
    // read the token env var before any other threads spawn.
    let token_env_var = std::env::var(TOKEN_ENV_KEY).ok().map(SecretString::from);

    // Docs indicate that `remove_var` should actually be marked unsafe
    // SAFETY: We haven't spawned any other threads, this code should be the first
    // thing to run after entering `main` and parsing CLI args.
    // So nobody else is reading the environment.
    unsafe {
        // This removes the token from the environment per <https://security.stackexchange.com/a/271285>. We run as root so it may not do anything besides defense-in-depth.
        std::env::remove_var(TOKEN_ENV_KEY);
    }
    assert!(std::env::var(TOKEN_ENV_KEY).is_err());

    // TODO: This might have the same issue with fatal errors not getting logged
    // as addressed for the IPC service in PR #5216
    let (layer, _handle) = cli
        .common
        .log_dir
        .as_deref()
        .map(|dir| firezone_logging::file::layer(dir, "firezone-headless-client"))
        .unzip();
    firezone_logging::setup_global_subscriber(layer).context("Failed to set up logging")?;

    // Deactivate DNS control before starting telemetry or connecting to the portal,
    // in case a previous run of Firezone left DNS control on and messed anything up.
    let dns_control_method = cli.common.dns_control;
    let mut dns_controller = DnsController { dns_control_method };
    // Deactivate Firezone DNS control in case the system or IPC service crashed
    // and we need to recover. <https://github.com/firezone/firezone/issues/4899>
    dns_controller.deactivate()?;

    let mut telemetry = Telemetry::default();
    if cli.is_telemetry_allowed() {
        telemetry.start(
            cli.api_url.as_ref(),
            &format!("headless-client@{VERSION}"),
            firezone_telemetry::HEADLESS_DSN,
        );
    }

    tracing::info!(arch = std::env::consts::ARCH, version = VERSION);

    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()?;

    let token = get_token(token_env_var, &cli.token_path)?.with_context(|| {
        format!(
            "Can't find the Firezone token in ${TOKEN_ENV_KEY} or in `{}`",
            cli.token_path.display()
        )
    })?;
    // TODO: Should this default to 30 days?
    let max_partition_time = cli.common.max_partition_time.map(|d| d.into());

    // AKA "Device ID", not the Firezone slug
    let firezone_id = match cli.firezone_id {
        Some(id) => id,
        None => device_id::get_or_create().context("Could not get `firezone_id` from CLI, could not read it from disk, could not generate it and save it to disk")?.id,
    };
    telemetry.set_firezone_id(firezone_id.clone());

    let url = LoginUrl::client(
        cli.api_url,
        &token,
        firezone_id,
        cli.firezone_name,
        device_id::device_info(),
    )?;

    if cli.check {
        tracing::info!("Check passed");
        return Ok(());
    }

    let (cb_tx, cb_rx) = mpsc::channel(1_000);
    let callbacks = CallbackHandler { cb_tx };

    // The name matches that in `ipc_service.rs`
    let mut last_connlib_start_instant = Some(Instant::now());

    rt.spawn(async move {
        loop {
            tracing::debug!(current_memory_usage = %ALLOCATOR.get());

            tokio::time::sleep(Duration::from_secs(1)).await;
        }
    });

    rt.block_on(async {
        let connect_span = telemetry_span!("connect_to_firezone").entered();

        // The Headless Client will bail out here if there's no Internet, because `PhoenixChannel` will try to
        // resolve the portal host and fail. This is intentional behavior. The Headless Client should always be running under a manager like `systemd` or Windows' Service Controller,
        // so when it fails it will be restarted with backoff. `systemd` can additionally make us wait
        // for an Internet connection if it launches us at startup.
        // When running interactively, it is useful for the user to see that we can't reach the portal.
        let portal = PhoenixChannel::disconnected(
            Secret::new(url),
            get_user_agent(None, env!("CARGO_PKG_VERSION")),
            "client",
            (),
            move || {
                ExponentialBackoffBuilder::default()
                    .with_max_elapsed_time(max_partition_time)
                    .build()
            },
            Arc::new(tcp_socket_factory),
        )?;
        let session = Session::connect(
            Arc::new(tcp_socket_factory),
            Arc::new(udp_socket_factory),
            callbacks,
            portal,
            rt.handle().clone(),
        );

        let mut terminate = signals::Terminate::new()?;
        let mut hangup = signals::Hangup::new()?;

        let mut tun_device = TunDeviceManager::new(
            ip_packet::MAX_IP_SIZE,
            firezone_headless_client::NUM_TUN_THREADS,
        )?;
        let mut cb_rx = ReceiverStream::new(cb_rx).fuse();

        let tokio_handle = tokio::runtime::Handle::current();

        let mut dns_notifier = new_dns_notifier(tokio_handle.clone(), dns_control_method).await?;

        let mut network_notifier =
            new_network_notifier(tokio_handle.clone(), dns_control_method).await?;
        drop(tokio_handle);

        let tun = {
            let _guard = telemetry_span!("create_tun_device").entered();

            tun_device.make_tun()?
        };
        session.set_tun(Box::new(tun));
        session.set_dns(dns_controller.system_resolvers());

        drop(connect_span);

        let result = loop {
            let cb = tokio::select! {
                () = terminate.recv() => {
                    tracing::info!("Caught SIGINT / SIGTERM / Ctrl+C");
                    break Ok(());
                },
                () = hangup.recv() => {
                    tracing::info!("Caught SIGHUP");
                    session.reset();
                    continue;
                },
                result = dns_notifier.notified() => {
                    result?;
                    // If the DNS control method is not `systemd-resolved`
                    // then we'll use polling here, so no point logging every 5 seconds that we're checking the DNS
                    tracing::trace!("DNS change, notifying Session");
                    session.set_dns(dns_controller.system_resolvers());
                    continue;
                },
                result = network_notifier.notified() => {
                    result?;
                    tracing::info!("Network change, resetting Session");
                    session.reset();
                    continue;
                },
                cb = cb_rx.next() => cb.context("cb_rx unexpectedly ran empty")?,
            };

            match cb {
                // TODO: Headless Client shouldn't be using messages labelled `Ipc`
                ConnlibMsg::OnDisconnect {
                    error_msg,
                    is_authentication_error: _,
                } => break Err(anyhow!(error_msg).context("Firezone disconnected")),
                ConnlibMsg::OnUpdateResources(_) => {
                    // On every Resources update, flush DNS to mitigate <https://github.com/firezone/firezone/issues/5052>
                    dns_controller.flush()?;
                }
                ConnlibMsg::OnSetInterfaceConfig {
                    ipv4,
                    ipv6,
                    dns,
                    ipv4_routes,
                    ipv6_routes,
                } => {
                    tun_device.set_ips(ipv4, ipv6).await?;
                    tun_device.set_routes(ipv4_routes, ipv6_routes).await?;

                    dns_controller.set_dns(dns).await?;

                    // `on_set_interface_config` is guaranteed to be called when the tunnel is completely ready
                    // <https://github.com/firezone/firezone/pull/6026#discussion_r1692297438>
                    if let Some(instant) = last_connlib_start_instant.take() {
                        // `OnUpdateResources` appears to be the latest callback that happens during startup
                        tracing::info!(elapsed = ?instant.elapsed(), "Tunnel ready");
                        platform::notify_service_controller()?;
                    }
                    if cli.exit {
                        tracing::info!("Exiting due to `--exit` CLI flag");
                        break Ok(());
                    }
                }
            }
        };

        telemetry.stop().await; // Stop telemetry before dropping session. `connlib` needs to be active for this, otherwise we won't be able to resolve the DNS name for sentry.

        session.disconnect();

        result
    })
}

/// Read the token from disk if it was not in the environment
///
/// # Returns
/// - `Ok(None)` if there is no token to be found
/// - `Ok(Some(_))` if we found the token
/// - `Err(_)` if we found the token on disk but failed to read it
fn get_token(
    token_env_var: Option<SecretString>,
    token_path: &Path,
) -> Result<Option<SecretString>> {
    // This is very simple but I don't want to write it twice
    if let Some(token) = token_env_var {
        return Ok(Some(token));
    }
    read_token_file(token_path)
}

/// Try to retrieve the token from disk
///
/// Sync because we do blocking file I/O
fn read_token_file(path: &Path) -> Result<Option<SecretString>> {
    if let Ok(token) = std::env::var(TOKEN_ENV_KEY) {
        std::env::remove_var(TOKEN_ENV_KEY);

        let token = SecretString::from(token);
        // Token was provided in env var
        tracing::info!(
            ?path,
            ?TOKEN_ENV_KEY,
            "Found token in env var, ignoring any token that may be on disk."
        );
        return Ok(Some(token));
    }

    if std::fs::metadata(path).is_err() {
        return Ok(None);
    }
    platform::check_token_permissions(path)?;

    let Ok(bytes) = std::fs::read(path) else {
        // We got the metadata a second ago, but can't read the file itself.
        // Pretty strange, would have to be a disk fault or TOCTOU.
        tracing::info!(?path, "Token file existed but now is unreadable");
        return Ok(None);
    };
    let token = String::from_utf8(bytes)?.trim().to_string();
    let token = SecretString::from(token);

    tracing::info!(?path, "Loaded token from disk");
    Ok(Some(token))
}

#[cfg(test)]
mod tests {
    use super::Cli;
    use clap::Parser;
    use std::path::PathBuf;
    use url::Url;

    // Can't remember how Clap works sometimes
    // Also these are examples
    #[test]
    fn cli() {
        let exe_name = "firezone-headless-client";

        let actual = Cli::try_parse_from([exe_name, "--api-url", "wss://api.firez.one/"]).unwrap();
        assert_eq!(
            actual.api_url,
            Url::parse("wss://api.firez.one/").expect("Hard-coded URL should always be parsable")
        );
        assert!(!actual.check);

        let actual =
            Cli::try_parse_from([exe_name, "--check", "--log-dir", "bogus_log_dir"]).unwrap();
        assert!(actual.check);
        assert_eq!(actual.common.log_dir, Some(PathBuf::from("bogus_log_dir")));
    }
}
