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
        /// Auth base URL
        #[arg(
            long,
            env = "FIREZONE_AUTH_BASE_URL",
            default_value = "https://app.firezone.dev"
        )]
        auth_base_url: url::Url,

        /// Account slug
        #[arg(long, env = "FIREZONE_ACCOUNT_SLUG")]
        account_slug: Option<String>,
    },

    /// Sign out by removing the stored token
    SignOut {
        /// Skip confirmation prompt
        #[arg(long, short)]
        force: bool,
    },
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

    match &cli._command {
        Some(Cmd::SignIn {
            auth_base_url,
            account_slug,
        }) => {
            handle_sign_in(auth_base_url, account_slug.as_deref(), &cli.token_path)?;

            return Ok(());
        }
        Some(Cmd::SignOut { force }) => {
            handle_sign_out(&cli.token_path, *force)?;

            return Ok(());
        }
        Some(Cmd::Standalone) | None => {
            // Continue with normal operation
        }
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

    // Start background log cleanup if file logging is enabled
    let _cleanup_handle = cli
        .log_dir
        .as_ref()
        .map(|log_dir| {
            logging::start_log_cleanup_thread(
                vec![log_dir.clone()],
                logging::DEFAULT_MAX_SIZE_MB,
                logging::DEFAULT_CLEANUP_INTERVAL,
            )
        })
        .transpose()
        .context("Failed to start log cleanup thread")?;

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
                client_shared::Event::GatewayVersionMismatch { .. } | client_shared::Event::AllGatewaysOffline { .. } => {},
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

/// Constructs the authentication URL for browser-based sign-in.
fn build_auth_url(auth_base_url: &url::Url, account_slug: Option<&str>) -> url::Url {
    let mut auth_url = auth_base_url.clone();
    if let Some(slug) = account_slug {
        auth_url.set_path(slug);
    }
    auth_url
        .query_pairs_mut()
        .append_pair("as", "headless-client");
    auth_url
}

/// Removes the token file at the given path.
/// Returns Ok(true) if the file was removed, Ok(false) if it didn't exist.
fn remove_token_file(token_path: &Path) -> Result<bool> {
    match std::fs::remove_file(token_path) {
        Ok(()) => Ok(true),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(e) => {
            Err(e).with_context(|| format!("Failed to remove token file: {}", token_path.display()))
        }
    }
}

#[expect(
    clippy::print_stdout,
    reason = "This command is designed to print to stdout for user interaction"
)]
fn handle_sign_in(
    auth_base_url: &url::Url,
    account_slug: Option<&str>,
    token_path: &Path,
) -> Result<()> {
    use std::io::{self, Write};

    let auth_url = build_auth_url(auth_base_url, account_slug);

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

    platform::write_token(token_path, token)?;

    println!("\n✓ Token saved successfully to: {}", token_path.display());
    println!("\nYou can now start the Firezone client. It will automatically use this token.");

    Ok(())
}

#[expect(
    clippy::print_stdout,
    reason = "This command is designed to print to stdout for user interaction"
)]
fn handle_sign_out(token_path: &Path, force: bool) -> Result<()> {
    use std::io::{self, BufRead, Write};

    // Check if token file exists first
    if !token_path.exists() {
        println!("No token file found at: {}", token_path.display());
        return Ok(());
    }

    let token_path_display = token_path.display();

    // Ask for confirmation unless --force is specified
    if !force {
        println!(
            "Warning: This will permanently remove the token file at:\n  {}\n",
            token_path_display
        );
        println!("The token cannot be recovered after deletion.");
        print!("Are you sure you want to sign out? [y/N]: ");
        io::stdout().flush()?;

        let mut input = String::new();
        io::stdin()
            .lock()
            .read_line(&mut input)
            .context("Failed to read user input")?;

        let input = input.trim().to_lowercase();
        if input != "y" && input != "yes" {
            println!("Sign out cancelled.");
            return Ok(());
        }
    }

    remove_token_file(token_path)?;

    println!(
        "\n✓ Token removed successfully from: {}",
        token_path_display
    );
    Ok(())
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
        match actual._command {
            Some(Cmd::SignIn {
                auth_base_url,
                account_slug,
            }) => {
                assert_eq!(auth_base_url.as_str(), "https://app.firezone.dev/");
                assert_eq!(account_slug, None);
            }
            _ => panic!("Expected SignIn command"),
        }
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
                assert_eq!(auth_base_url.as_str(), "https://auth.example.com/");
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
        assert!(matches!(
            actual._command,
            Some(Cmd::SignOut { force: false })
        ));
    }

    #[test]
    fn sign_out_with_force() {
        let actual =
            Cli::try_parse_from(["firezone-headless-client", "sign-out", "--force"]).unwrap();
        assert!(matches!(
            actual._command,
            Some(Cmd::SignOut { force: true })
        ));
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
        assert!(matches!(actual._command, Some(Cmd::SignOut { .. })));
    }

    /// Verifies that `set_token_permissions` produces a file that passes `check_token_permissions`.
    /// On Linux, this requires running as root (CI runs in Docker as root).
    /// On macOS/Windows, both functions are no-ops so this always passes.
    #[test]
    fn set_token_permissions_satisfies_check() {
        use std::io::Write;

        let token_path = std::env::temp_dir().join("firezone_test_token");

        // Create a token file
        let mut file = std::fs::File::create(&token_path).unwrap();
        file.write_all(b"test_token").unwrap();
        drop(file);

        // Set permissions
        super::platform::set_token_permissions(&token_path)
            .expect("set_token_permissions should succeed");

        // Verify that check_token_permissions is satisfied
        super::platform::check_token_permissions(&token_path)
            .expect("check_token_permissions should succeed after set_token_permissions");

        // Cleanup
        let _ = std::fs::remove_file(&token_path);
    }

    // =========================================================================
    // Tests for sign-in/sign-out core logic
    // =========================================================================

    #[test]
    fn build_auth_url_without_slug() {
        let base_url = Url::parse("https://app.firezone.dev").unwrap();
        let auth_url = super::build_auth_url(&base_url, None);

        assert_eq!(auth_url.host_str(), Some("app.firezone.dev"));
        assert_eq!(auth_url.path(), "/");
        assert_eq!(auth_url.query(), Some("as=headless-client"));
    }

    #[test]
    fn build_auth_url_with_slug() {
        let base_url = Url::parse("https://app.firezone.dev").unwrap();
        let auth_url = super::build_auth_url(&base_url, Some("my-team"));

        assert_eq!(auth_url.host_str(), Some("app.firezone.dev"));
        assert_eq!(auth_url.path(), "/my-team");
        assert_eq!(auth_url.query(), Some("as=headless-client"));
    }

    #[test]
    fn build_auth_url_with_custom_base() {
        let base_url = Url::parse("https://auth.example.com").unwrap();
        let auth_url = super::build_auth_url(&base_url, Some("acme-corp"));

        assert_eq!(auth_url.host_str(), Some("auth.example.com"));
        assert_eq!(auth_url.path(), "/acme-corp");
        assert_eq!(auth_url.query(), Some("as=headless-client"));
    }

    #[test]
    fn write_token_creates_file_with_content() {
        let token_path = std::env::temp_dir().join("firezone_test_write_token");
        let _ = std::fs::remove_file(&token_path); // Clean up any previous test run

        let test_token = "test_token_content_12345";
        super::platform::write_token(&token_path, test_token).expect("write_token should succeed");

        // Verify the file exists and has correct content
        let content = std::fs::read_to_string(&token_path).expect("Should be able to read token");
        assert_eq!(content, test_token);

        // Cleanup
        let _ = std::fs::remove_file(&token_path);
    }

    #[test]
    fn write_token_creates_parent_directories() {
        let token_path = std::env::temp_dir()
            .join("firezone_test_nested")
            .join("subdir")
            .join("token");
        let parent = token_path.parent().unwrap();

        // Ensure the directory doesn't exist
        let _ = std::fs::remove_dir_all(parent);

        let test_token = "nested_token";
        super::platform::write_token(&token_path, test_token)
            .expect("write_token should create parent directories");

        assert!(token_path.exists());
        let content = std::fs::read_to_string(&token_path).unwrap();
        assert_eq!(content, test_token);

        // Cleanup
        let _ = std::fs::remove_dir_all(std::env::temp_dir().join("firezone_test_nested"));
    }

    #[test]
    fn write_token_overwrites_existing() {
        let token_path = std::env::temp_dir().join("firezone_test_overwrite");

        // Write initial token
        super::platform::write_token(&token_path, "first_token").unwrap();

        // Overwrite with new token
        super::platform::write_token(&token_path, "second_token").unwrap();

        let content = std::fs::read_to_string(&token_path).unwrap();
        assert_eq!(content, "second_token");

        // Cleanup
        let _ = std::fs::remove_file(&token_path);
    }

    #[test]
    fn remove_token_file_removes_existing() {
        let token_path = std::env::temp_dir().join("firezone_test_remove");

        // Create a token file
        std::fs::write(&token_path, "token_to_remove").unwrap();
        assert!(token_path.exists());

        // Remove it
        let removed = super::remove_token_file(&token_path).unwrap();
        assert!(removed);
        assert!(!token_path.exists());
    }

    #[test]
    fn remove_token_file_returns_false_for_nonexistent() {
        let token_path = std::env::temp_dir().join("firezone_test_nonexistent_token");
        let _ = std::fs::remove_file(&token_path); // Ensure it doesn't exist

        let removed = super::remove_token_file(&token_path).unwrap();
        assert!(!removed);
    }

    #[test]
    fn token_roundtrip_write_and_read() {
        let token_path = std::env::temp_dir().join("firezone_test_roundtrip");
        let _ = std::fs::remove_file(&token_path);

        let test_token = "roundtrip_test_token_abc123";

        // Write token
        super::platform::write_token(&token_path, test_token).unwrap();

        // Read it back using the same function used by the client
        let read_token = super::read_token_file(&token_path)
            .expect("read_token_file should succeed")
            .expect("Token should exist");

        use secrecy::ExposeSecret;
        assert_eq!(read_token.expose_secret(), test_token);

        // Cleanup
        let _ = std::fs::remove_file(&token_path);
    }
}
