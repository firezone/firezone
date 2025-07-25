//! The headless Client, AKA standalone Client

#![cfg_attr(test, allow(clippy::unwrap_used))]

use anyhow::{Context as _, Result, anyhow};
use backoff::ExponentialBackoffBuilder;
use clap::Parser;
use firezone_bin_shared::{
    DnsControlMethod, DnsController, TOKEN_ENV_KEY, TunDeviceManager, device_id, device_info,
    new_dns_notifier, new_network_notifier,
    platform::{UdpSocketFactory, tcp_socket_factory},
    signals,
};
use firezone_telemetry::{Telemetry, analytics, otel};
use opentelemetry_sdk::metrics::{PeriodicReader, SdkMeterProvider};
use phoenix_channel::PhoenixChannel;
use phoenix_channel::get_user_agent;
use phoenix_channel::{DeviceInfo, LoginUrl};
use secrecy::{Secret, SecretString};
use std::{
    path::{Path, PathBuf},
    sync::Arc,
};
use tokio::time::Instant;

#[cfg(target_os = "linux")]
#[path = "linux.rs"]
mod platform;

#[cfg(target_os = "windows")]
#[path = "windows.rs"]
mod platform;

#[cfg(target_os = "macos")]
#[path = "macos.rs"]
mod platform;

/// Command-line args for the headless Client
#[derive(Parser)]
#[command(author, version, about, long_about = None)]
struct Cli {
    // Needed to preserve CLI arg compatibility
    // TODO: Remove when we can break CLI compatibility for headless Clients
    #[command(subcommand)]
    _command: Option<Cmd>,

    #[cfg(target_os = "linux")]
    #[arg(long, env = "FIREZONE_DNS_CONTROL", default_value = "systemd-resolved")]
    dns_control: DnsControlMethod,

    #[cfg(target_os = "windows")]
    #[arg(long, env = "FIREZONE_DNS_CONTROL", default_value = "nrpt")]
    dns_control: DnsControlMethod,

    #[cfg(target_os = "macos")]
    #[arg(long, env = "FIREZONE_DNS_CONTROL", default_value = "none")]
    dns_control: DnsControlMethod,

    /// File logging directory. Should be a path that's writeable by the current user.
    #[arg(short, long, env = "LOG_DIR")]
    log_dir: Option<PathBuf>,

    /// Maximum length of time to retry connecting to the portal if we're having internet issues or
    /// it's down. Accepts human times. e.g. "5m" or "1h" or "30d".
    #[arg(short, long, env = "MAX_PARTITION_TIME")]
    max_partition_time: Option<humantime::Duration>,

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
    #[arg(long, hide = true)]
    check: bool,

    /// Connect to the Firezone network and initialize, then exit
    ///
    /// Use this to check how fast you can connect.
    #[arg(long, hide = true)]
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

    /// Dump internal metrics to stdout every 60s.
    ///
    /// This configuration option is private API and has no stability guarantees.
    /// It may be removed / changed anytime.
    #[arg(long, hide = true, env = "FIREZONE_METRICS")]
    metrics: Option<MetricsExporter>,

    /// A filesystem path where the token can be found
    // Apparently passing secrets through stdin is the most secure method, but
    // until anyone asks for it, env vars are okay and files on disk are slightly better.
    // (Since we run as root and the env var on a headless system is probably stored
    // on disk somewhere anyway.)
    #[arg(default_value = platform::default_token_path().display().to_string(), env = "FIREZONE_TOKEN_PATH", long)]
    token_path: PathBuf,
}

#[derive(Debug, Clone, Copy, clap::ValueEnum)]
enum MetricsExporter {
    Stdout,
}

impl Cli {
    fn is_telemetry_allowed(&self) -> bool {
        !self.no_telemetry
    }
}

#[derive(clap::Subcommand, Clone, Copy)]
#[clap(hide = true)]
enum Cmd {
    Standalone,
}

const VERSION: &str = env!("CARGO_PKG_VERSION");
const RELEASE: &str = concat!("headless-client@", env!("CARGO_PKG_VERSION"));

fn main() -> Result<()> {
    rustls::crypto::ring::default_provider()
        .install_default()
        .expect("Calling `install_default` only once per process should always succeed");

    let cli = Cli::parse();

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
    // as addressed for the Tunnel service in PR #5216
    let (layer, _handle) = cli
        .log_dir
        .as_deref()
        .map(|dir| firezone_logging::file::layer(dir, "firezone-headless-client"))
        .unzip();
    firezone_logging::setup_global_subscriber(layer).context("Failed to set up logging")?;

    // Deactivate DNS control before starting telemetry or connecting to the portal,
    // in case a previous run of Firezone left DNS control on and messed anything up.
    let dns_control_method = cli.dns_control;
    let mut dns_controller = DnsController { dns_control_method };
    // Deactivate Firezone DNS control in case the system or Tunnel service crashed
    // and we need to recover. <https://github.com/firezone/firezone/issues/4899>
    dns_controller.deactivate()?;

    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()?;

    // AKA "Device ID", not the Firezone slug
    let firezone_id = match cli.firezone_id.clone() {
        Some(id) => id,
        None => device_id::get_or_create().context("Could not get `firezone_id` from CLI, could not read it from disk, could not generate it and save it to disk")?.id,
    };

    let mut telemetry = Telemetry::default();
    if cli.is_telemetry_allowed() {
        rt.block_on(telemetry.start(
            cli.api_url.as_ref(),
            RELEASE,
            firezone_telemetry::HEADLESS_DSN,
            firezone_id.clone(),
        ));

        analytics::identify(RELEASE.to_owned(), None);
    }

    tracing::info!(arch = std::env::consts::ARCH, version = VERSION);

    let token = get_token(token_env_var, &cli.token_path)?.with_context(|| {
        format!(
            "Can't find the Firezone token in ${TOKEN_ENV_KEY} or in `{}`",
            cli.token_path.display()
        )
    })?;
    // TODO: Should this default to 30 days?
    let max_partition_time = cli.max_partition_time.map(|d| d.into());

    let url = LoginUrl::client(
        cli.api_url.clone(),
        &token,
        firezone_id.clone(),
        cli.firezone_name,
        DeviceInfo {
            device_serial: device_info::serial(),
            device_uuid: device_info::uuid(),
            ..Default::default()
        },
    )?;

    if cli.check {
        tracing::info!("Check passed");
        return Ok(());
    }

    // The name matches that in `ipc_service.rs`
    let mut last_connlib_start_instant = Some(Instant::now());

    rt.block_on(async {
        if let Some(MetricsExporter::Stdout) = cli.metrics {
            let exporter = opentelemetry_stdout::MetricExporter::default();
            let reader = PeriodicReader::builder(exporter).build();
            let provider = SdkMeterProvider::builder()
                .with_reader(reader)
                .with_resource(otel::default_resource_with([
                    otel::attr::service_name!(),
                    otel::attr::service_version!(),
                    otel::attr::service_instance_id(firezone_id.clone()),
                ]))
                .build();

            opentelemetry::global::set_meter_provider(provider);
        }

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
        let (session, mut event_stream) = client_shared::Session::connect(
            Arc::new(tcp_socket_factory),
            Arc::new(UdpSocketFactory::default()),
            portal,
            rt.handle().clone(),
        );

        analytics::new_session(firezone_id.clone(), cli.api_url.to_string());

        let mut terminate = signals::Terminate::new()?;
        let mut hangup = signals::Hangup::new()?;

        let mut tun_device = TunDeviceManager::new(ip_packet::MAX_IP_SIZE, 1)?;

        let tokio_handle = tokio::runtime::Handle::current();

        let mut dns_notifier = new_dns_notifier(tokio_handle.clone(), dns_control_method).await?;

        let mut network_notifier =
            new_network_notifier(tokio_handle.clone(), dns_control_method).await?;
        drop(tokio_handle);

        let tun = tun_device.make_tun()?;
        session.set_tun(tun);
        session.set_dns(dns_controller.system_resolvers());

        let result = loop {
            let event = tokio::select! {
                () = terminate.recv() => {
                    tracing::info!("Caught SIGINT / SIGTERM / Ctrl+C");
                    break Ok(());
                },
                () = hangup.recv() => {
                    session.reset("SIGHUP".to_owned());
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
                    session.reset("network changed".to_owned());
                    continue;
                },
                event = event_stream.next() => event.context("event stream unexpectedly ran empty")?,
            };

            match event {
                // TODO: Headless Client shouldn't be using messages labelled `Ipc`
                client_shared::Event::Disconnected(error) => break Err(anyhow!(error).context("Firezone disconnected")),
                client_shared::Event::ResourcesUpdated(_) => {
                    // On every Resources update, flush DNS to mitigate <https://github.com/firezone/firezone/issues/5052>
                    dns_controller.flush()?;
                }
                client_shared::Event::TunInterfaceUpdated {
                    ipv4,
                    ipv6,
                    dns,
                    search_domain,
                    ipv4_routes,
                    ipv6_routes,
                } => {
                    tun_device.set_ips(ipv4, ipv6).await?;
                    tun_device.set_routes(ipv4_routes, ipv6_routes).await?;

                    dns_controller.set_dns(dns, search_domain).await?;

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

        drop(session);

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
        assert_eq!(actual.log_dir, Some(PathBuf::from("bogus_log_dir")));
    }
}
