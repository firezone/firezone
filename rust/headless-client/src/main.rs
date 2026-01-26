//! The headless Client, AKA standalone Client

#![cfg_attr(test, allow(clippy::unwrap_used))]

use anyhow::{Context as _, Result, anyhow};
use backoff::ExponentialBackoffBuilder;
use bin_shared::{
    DnsControlMethod, DnsController, TOKEN_ENV_KEY, TunDeviceManager, device_id, device_info,
    new_dns_notifier, new_network_notifier,
    platform::{UdpSocketFactory, tcp_socket_factory},
    signals,
};
use clap::Parser;
use ip_network::IpNetwork;
use opentelemetry_otlp::WithExportConfig as _;
use opentelemetry_sdk::metrics::SdkMeterProvider;
use phoenix_channel::PhoenixChannel;
use phoenix_channel::get_user_agent;
use phoenix_channel::{DeviceInfo, LoginUrl};
use secrecy::SecretString;
use std::{
    path::{Path, PathBuf},
    sync::Arc,
    time::Duration,
};
use telemetry::{
    MaybePushMetricsExporter, NoopPushMetricsExporter, Telemetry, analytics, feature_flags, otel,
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

    /// Activate the Internet Resource.
    ///
    /// To actually use the Internet Resource, the user must also have a policy granting access to the Internet Resource.
    #[arg(
        long,
        env = "FIREZONE_ACTIVATE_INTERNET_RESOURCE",
        default_value_t = false
    )]
    activate_internet_resource: bool,

    /// Disable sentry.io crash-reporting agent.
    #[arg(long, env = "FIREZONE_NO_TELEMETRY", default_value_t = false)]
    no_telemetry: bool,

    /// Dump internal metrics to stdout every 60s.
    ///
    /// This configuration option is private API and has no stability guarantees.
    /// It may be removed / changed anytime.
    #[arg(long, hide = true, env = "FIREZONE_METRICS")]
    metrics: Option<MetricsExporter>,

    /// Send metrics to a custom OTLP collector.
    ///
    /// By default, Firezone's hosted OTLP collector is used.
    ///
    /// This configuration option is private API and has no stability guarantees.
    /// It may be removed / changed anytime.
    #[arg(long, env, hide = true)]
    otlp_grpc_endpoint: Option<String>,

    /// A filesystem path where the token can be found
    // Apparently passing secrets through stdin is the most secure method, but
    // until anyone asks for it, env vars are okay and files on disk are slightly better.
    // (Since we run as root and the env var on a headless system is probably stored
    // on disk somewhere anyway.)
    #[arg(default_value = platform::default_token_path().display().to_string(), env = "FIREZONE_TOKEN_PATH", long)]
    token_path: PathBuf,

    /// Increase the `core.rmem_max` and `core.wmem_max` kernel parameters.
    #[arg(long, env = "FIREZONE_INC_BUF", hide = true, default_value_t = false)]
    inc_buf: bool,
}

#[derive(Debug, Clone, Copy, clap::ValueEnum)]
enum MetricsExporter {
    Stdout,
    OtelCollector,
}

impl Cli {
    fn is_telemetry_allowed(&self) -> bool {
        !self.no_telemetry
    }

    fn is_inc_buf_allowed(&self) -> bool {
        self.inc_buf
    }
}

#[derive(clap::Subcommand, Clone)]
enum Cmd {
    #[clap(hide = true)]
    Standalone,

    /// Sign in via browser-based authentication
    SignIn {
        /// Auth base URL (e.g., https://app.firezone.dev)
        #[arg(long, env = "FIREZONE_AUTH_BASE_URL")]
        auth_base_url: Option<url::Url>,

        /// Account slug
        #[arg(long, env = "FIREZONE_ACCOUNT_SLUG")]
        account_slug: Option<String>,
    },

    /// Sign out by removing the stored token
    SignOut,
}

const VERSION: &str = env!("CARGO_PKG_VERSION");
const RELEASE: &str = concat!("headless-client@", env!("CARGO_PKG_VERSION"));

#[expect(
    clippy::print_stderr,
    reason = "No logger is active when we are printing this error."
)]
fn main() {
    match try_main() {
        Ok(()) => {}
        Err(e) => {
            // Print chain of errors manually to avoid it looking like a crash with stacktrace.
            eprintln!("{e:#}");

            std::process::exit(1);
        }
    }
}

fn try_main() -> Result<()> {
    rustls::crypto::ring::default_provider()
        .install_default()
        .map_err(|_| anyhow!("Failed to install default crypto provider"))?;

    let cli = Cli::parse();

    if let Some(Cmd::SignIn {
        auth_base_url,
        account_slug,
    }) = &cli._command
    {
        return handle_sign_in(auth_base_url.clone(), account_slug.clone(), &cli.token_path);
    }

    if let Some(Cmd::SignOut) = &cli._command {
        return handle_sign_out(&cli.token_path);
    }

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
        .map(|dir| logging::file::layer(dir, "firezone-headless-client"))
        .unzip();
    logging::setup_global_subscriber(
        std::env::var("RUST_LOG").unwrap_or_else(|_| "info".to_string()),
        layer,
        false,
    )
    .context("Failed to set up logging")?;

    // Deactivate DNS control before starting telemetry or connecting to the portal,
    // in case a previous run of Firezone left DNS control on and messed anything up.
    let dns_control_method = cli.dns_control;
    let mut dns_controller = DnsController { dns_control_method };
    // Deactivate Firezone DNS control in case the system or Tunnel service crashed
    // and we need to recover. <https://github.com/firezone/firezone/issues/4899>
    dns_controller.deactivate()?;

    let rt = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(1)
        .thread_name("connlib")
        .enable_all()
        .build()
        .context("Failed to create tokio runtime")?;

    if cfg!(target_os = "linux") && cli.is_inc_buf_allowed() {
        let recv_buf_size = socket_factory::RECV_BUFFER_SIZE;
        let send_buf_size = socket_factory::SEND_BUFFER_SIZE;

        match std::fs::write("/proc/sys/net/core/rmem_max", recv_buf_size.to_string()) {
            Ok(()) => tracing::info!("Set `core.rmem_max` to {recv_buf_size}",),
            Err(e) => tracing::info!("Failed to increase `core.rmem_max`: {e}"),
        };
        match std::fs::write("/proc/sys/net/core/wmem_max", send_buf_size.to_string()) {
            Ok(()) => tracing::info!("Set `core.wmem_max` to {send_buf_size}",),
            Err(e) => tracing::info!("Failed to increase `core.wmem_max`: {e}"),
        };
    }

    // AKA "Device ID", not the Firezone slug
    let firezone_id = match cli.firezone_id.clone() {
        Some(id) => id,
        None => device_id::get_or_create_client().context("Could not get `firezone_id` from CLI, could not read it from disk, could not generate it and save it to disk")?.id,
    };

    let mut telemetry = if cli.is_telemetry_allowed() {
        let mut telemetry = Telemetry::new();

        rt.block_on(telemetry.start(
            cli.api_url.as_ref(),
            RELEASE,
            telemetry::HEADLESS_DSN,
            firezone_id.clone(),
        ));

        analytics::identify(RELEASE.to_owned(), None);

        telemetry
    } else {
        Telemetry::disabled()
    };

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
        if let Some(backend) = cli.metrics {
            let resource = otel::default_resource_with([
                otel::attr::service_name!(),
                otel::attr::service_version!(),
                otel::attr::service_instance_id(firezone_id.clone()),
            ]);

            let provider = match (backend, cli.otlp_grpc_endpoint) {
                (MetricsExporter::Stdout, _) => SdkMeterProvider::builder()
                    .with_periodic_exporter(opentelemetry_stdout::MetricExporter::default())
                    .with_resource(resource)
                    .build(),
                (MetricsExporter::OtelCollector, Some(endpoint)) => SdkMeterProvider::builder()
                    .with_periodic_exporter(tonic_otlp_exporter(endpoint)?)
                    .with_resource(resource)
                    .build(),
                (MetricsExporter::OtelCollector, None) => SdkMeterProvider::builder()
                    .with_periodic_exporter(MaybePushMetricsExporter {
                        inner: {
                            // TODO: Once Firezone has a hosted OTLP exporter, it will go here.

                            NoopPushMetricsExporter
                        },
                        should_export: feature_flags::export_metrics,
                    })
                    .with_resource(resource)
                    .build(),
            };

            opentelemetry::global::set_meter_provider(provider);
        }

        // The Headless Client will bail out here if there's no Internet, because `PhoenixChannel` will try to
        // resolve the portal host and fail. This is intentional behavior. The Headless Client should always be running under a manager like `systemd` or Windows' Service Controller,
        // so when it fails it will be restarted with backoff. `systemd` can additionally make us wait
        // for an Internet connection if it launches us at startup.
        // When running interactively, it is useful for the user to see that we can't reach the portal.
        let portal = PhoenixChannel::disconnected(
            url,
            token,
            get_user_agent("headless-client", env!("CARGO_PKG_VERSION")),
            "client",
            (),
            move || {
                ExponentialBackoffBuilder::default()
                    .with_max_elapsed_time(max_partition_time)
                    .build()
            },
            Arc::new(tcp_socket_factory),
        );
        let (session, mut event_stream) = client_shared::Session::connect(
            Arc::new(tcp_socket_factory),
            Arc::new(UdpSocketFactory::default()),
            portal,
            cli.activate_internet_resource,
            dns_controller.system_resolvers(),
            rt.handle().clone(),
        );

        analytics::new_session(firezone_id.clone(), cli.api_url.to_string());

        let mut terminate = signals::Terminate::new()?;
        let mut hangup = signals::Hangup::new()?;

        let mut tun_device = TunDeviceManager::new(ip_packet::MAX_IP_SIZE)?;

        let tokio_handle = tokio::runtime::Handle::current();

        let mut dns_notifier = new_dns_notifier(tokio_handle.clone(), dns_control_method).await?;

        let mut network_notifier =
            new_network_notifier(tokio_handle.clone(), dns_control_method).await?;
        drop(tokio_handle);

        let tun = tun_device.make_tun()?;
        session.set_tun(tun);

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
                client_shared::Event::TunInterfaceUpdated(config) => {
                    let tun_ip_stack = tun_device.set_ips(config.ip.v4, config.ip.v6).await?;
                    dns_controller.set_dns(config.dns_by_sentinel.sentinel_ips(), config.search_domain).await?;
                    tun_device.set_routes(config.routes.into_iter().filter(|r| match r {
                        IpNetwork::V4(_) => tun_ip_stack.supports_ipv4(),
                        IpNetwork::V6(_) => tun_ip_stack.supports_ipv6(),
                    })).await?;

                    // `on_set_interface_config` is guaranteed to be called when the tunnel is completely ready
                    // <https://github.com/firezone/firezone/pull/6026#discussion_r1692297438>
                    if let Some(instant) = last_connlib_start_instant.take() {
                        // `OnUpdateResources` appears to be the latest callback that happens during startup
                        tracing::debug!(elapsed = ?instant.elapsed(), "Tunnel ready");
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

        // Drain the event-stream to allow the event-loop to gracefully shutdown.
        let _ = tokio::time::timeout(Duration::from_secs(1), event_stream.drain()).await;

        result
    })?;

    rt.shutdown_timeout(Duration::from_secs(1));

    Ok(())
}

#[expect(
    clippy::print_stdout,
    reason = "This command is designed to print to stdout for user interaction"
)]
fn handle_sign_in(
    auth_base_url: Option<url::Url>,
    account_slug: Option<String>,
    token_path: &Path,
) -> Result<()> {
    use std::io::{self, Write};

    const MIN_TOKEN_LENGTH: usize = 64;

    let base_url = auth_base_url.unwrap_or_else(|| {
        url::Url::parse("https://app.firezone.dev")
            .expect("Default auth base URL should always be valid")
    });

    let mut auth_url = base_url;
    if let Some(slug) = account_slug.as_deref() {
        auth_url.set_path(slug);
    }

    auth_url
        .query_pairs_mut()
        .append_pair("as", "headless-client");

    println!("\n==========================================================================");
    println!("Firezone Headless Client - Browser Authentication");
    println!("==========================================================================\n");
    println!("To sign in to Firezone, please follow these steps:\n");
    println!("1. Open the following URL in your web browser:\n");
    println!("   {}\n", auth_url);
    println!("2. Complete the sign-in process in your browser");
    println!("3. Copy the token displayed in the browser");
    println!("4. Return to this terminal and paste the token below\n");
    println!("==========================================================================\n");

    print!("Enter the token from your browser: ");
    io::stdout().flush()?;

    let input = rpassword::read_password().context("Failed to read token from stdin")?;
    println!();
    let token = input.trim();

    if token.is_empty() {
        anyhow::bail!("No token provided");
    }

    if token.len() < MIN_TOKEN_LENGTH {
        anyhow::bail!(
            "Token appears to be too short (expected at least {} characters, got {}). Please ensure you copied the complete token.",
            MIN_TOKEN_LENGTH,
            token.len()
        );
    }

    if let Some(parent) = token_path.parent() {
        std::fs::create_dir_all(parent).context("Failed to create token directory")?;
    }

    // Write token with restrictive permissions from the start to avoid
    // a window where the file may be world-readable via umask-derived permissions.
    {
        let mut options = std::fs::OpenOptions::new();
        options.write(true).create(true).truncate(true);

        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }

        let mut file = options
            .open(token_path)
            .context("Failed to create token file")?;
        file.write_all(token.as_bytes())
            .context("Failed to write token to file")?;
    }

    platform::set_token_permissions(token_path)?;

    println!("\n✓ Token saved successfully to: {}", token_path.display());
    println!("\nYou can now start the Firezone client. It will automatically use this token.");

    Ok(())
}

#[expect(
    clippy::print_stdout,
    reason = "This command is designed to print to stdout for user interaction"
)]
fn handle_sign_out(token_path: &Path) -> Result<()> {
    match std::fs::remove_file(token_path) {
        Ok(()) => {
            println!(
                "✓ Token removed successfully from: {}",
                token_path.display()
            );
            Ok(())
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            println!("No token file found at: {}", token_path.display());
            Ok(())
        }
        Err(e) => Err(anyhow::anyhow!(e).context(format!(
            "Failed to remove token file: {}",
            token_path.display()
        ))),
    }
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

fn tonic_otlp_exporter(
    endpoint: String,
) -> Result<opentelemetry_otlp::MetricExporter, anyhow::Error> {
    let metric_exporter = opentelemetry_otlp::MetricExporter::builder()
        .with_tonic()
        .with_endpoint(format!("http://{endpoint}"))
        .build()
        .context("Failed to build OTLP metric exporter")?;

    Ok(metric_exporter)
}

#[cfg(test)]
mod tests {
    use super::{Cli, Cmd};
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

    #[test]
    fn sign_in_bare() {
        let actual = Cli::try_parse_from(["firezone-headless-client", "sign-in"]).unwrap();
        assert!(matches!(
            actual._command,
            Some(Cmd::SignIn {
                auth_base_url: None,
                account_slug: None,
            })
        ));
    }

    #[test]
    fn sign_in_with_options() {
        let actual = Cli::try_parse_from([
            "firezone-headless-client",
            "sign-in",
            "--auth-base-url",
            "https://auth.example.com",
            "--account-slug",
            "my-team",
        ])
        .unwrap();

        match actual._command {
            Some(Cmd::SignIn {
                auth_base_url,
                account_slug,
            }) => {
                assert_eq!(auth_base_url.unwrap().as_str(), "https://auth.example.com/");
                assert_eq!(account_slug.unwrap(), "my-team");
            }
            _ => panic!("Expected SignIn command"),
        }
    }

    #[test]
    fn sign_in_respects_token_path() {
        let actual = Cli::try_parse_from([
            "firezone-headless-client",
            "--token-path",
            "/custom/token/path",
            "sign-in",
        ])
        .unwrap();

        assert_eq!(actual.token_path, PathBuf::from("/custom/token/path"));
        assert!(matches!(actual._command, Some(Cmd::SignIn { .. })));
    }

    #[test]
    fn sign_in_uses_default_token_path() {
        let actual = Cli::try_parse_from(["firezone-headless-client", "sign-in"]).unwrap();

        assert_eq!(actual.token_path, super::platform::default_token_path());
    }

    #[test]
    fn sign_out_bare() {
        let actual = Cli::try_parse_from(["firezone-headless-client", "sign-out"]).unwrap();
        assert!(matches!(actual._command, Some(Cmd::SignOut)));
    }

    #[test]
    fn sign_out_respects_token_path() {
        let actual = Cli::try_parse_from([
            "firezone-headless-client",
            "--token-path",
            "/custom/token/path",
            "sign-out",
        ])
        .unwrap();

        assert_eq!(actual.token_path, PathBuf::from("/custom/token/path"));
        assert!(matches!(actual._command, Some(Cmd::SignOut)));
    }
}
