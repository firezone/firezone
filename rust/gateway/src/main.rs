#[cfg(all(target_os = "linux", not(target_arch = "arm")))]
#[global_allocator]
static GLOBAL: jemallocator::Jemalloc = jemallocator::Jemalloc;

use crate::eventloop::{Eventloop, PHOENIX_TOPIC};
use anyhow::{Context, Result};
use backoff::ExponentialBackoffBuilder;
use clap::Parser;
use firezone_bin_shared::{
    TunDeviceManager, http_health_check,
    platform::{tcp_socket_factory, udp_socket_factory},
};

use firezone_telemetry::Telemetry;
use firezone_tunnel::GatewayTunnel;
use opentelemetry_sdk::metrics::{PeriodicReader, SdkMeterProvider};
use phoenix_channel::LoginUrl;
use phoenix_channel::get_user_agent;

use futures::{TryFutureExt, future};
use phoenix_channel::PhoenixChannel;
use secrecy::{Secret, SecretString};
use std::sync::Arc;
use std::{collections::BTreeSet, path::Path};
use std::{fmt, pin::pin};
use std::{process::ExitCode, str::FromStr};
use tokio::io::AsyncWriteExt;
use tokio::signal::ctrl_c;
use tracing_subscriber::layer;
use url::Url;
use uuid::Uuid;

mod eventloop;

const ID_PATH: &str = "/var/lib/firezone/gateway_id";

fn main() -> ExitCode {
    let cli = Cli::parse();

    #[expect(clippy::print_stderr, reason = "No logger has been set up yet")]
    #[cfg(target_os = "linux")]
    if !has_necessary_permissions() && !cli.no_check {
        eprintln!(
            "firezone-gateway needs to be executed as `root` or with the `CAP_NET_ADMIN` capability.\nSee https://www.firezone.dev/kb/deploy/gateways#permissions for details."
        );
        return ExitCode::FAILURE;
    }

    rustls::crypto::ring::default_provider()
        .install_default()
        .expect("Calling `install_default` only once per process should always succeed");

    let mut telemetry = Telemetry::default();
    if cli.is_telemetry_allowed() {
        telemetry.start(
            cli.api_url.as_str(),
            concat!("gateway@", env!("CARGO_PKG_VERSION")),
            firezone_telemetry::GATEWAY_DSN,
        );
    }

    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .expect("Failed to create tokio runtime");

    match runtime
        .block_on(try_main(cli))
        .context("Failed to start Gateway")
    {
        Ok(ExitCode::SUCCESS) => {
            runtime.block_on(telemetry.stop());

            ExitCode::SUCCESS
        }
        Ok(_) => {
            runtime.block_on(telemetry.stop_on_crash());

            ExitCode::FAILURE
        }
        Err(e) => {
            tracing::error!("{e:#}");
            runtime.block_on(telemetry.stop_on_crash());

            ExitCode::FAILURE
        }
    }
}

#[must_use]
#[cfg(target_os = "linux")]
fn has_necessary_permissions() -> bool {
    let is_root = nix::unistd::Uid::current().is_root();
    let has_net_admin = caps::has_cap(
        None,
        caps::CapSet::Effective,
        caps::Capability::CAP_NET_ADMIN,
    )
    .is_ok_and(|b| b);

    is_root || has_net_admin
}

async fn try_main(cli: Cli) -> Result<ExitCode> {
    firezone_logging::setup_global_subscriber(layer::Identity::default())
        .context("Failed to set up logging")?;

    if cli.metrics {
        let exporter = opentelemetry_stdout::MetricsExporter::default();
        let reader = PeriodicReader::builder(exporter, opentelemetry_sdk::runtime::Tokio).build();
        let provider = SdkMeterProvider::builder().with_reader(reader).build();

        opentelemetry::global::set_meter_provider(provider);
    }

    let firezone_id = get_firezone_id(cli.firezone_id).await
        .context("Couldn't read FIREZONE_ID or write it to disk: Please provide it through the env variable or provide rw access to /var/lib/firezone/")?;
    Telemetry::set_firezone_id(firezone_id.clone());

    let login = LoginUrl::gateway(
        cli.api_url,
        &SecretString::new(cli.token),
        firezone_id,
        cli.firezone_name,
    )
    .context("Failed to construct URL for logging into portal")?;

    let resolv_conf = resolv_conf::Config::parse(
        std::fs::read_to_string("/etc/resolv.conf").context("Failed to read /etc/resolv.conf")?,
    )
    .context("Failed to parse /etc/resolv.conf")?;
    let nameservers = resolv_conf
        .nameservers
        .into_iter()
        .map(|ip| ip.into())
        .collect::<BTreeSet<_>>();

    let mut tunnel = GatewayTunnel::new(
        Arc::new(tcp_socket_factory),
        Arc::new(udp_socket_factory),
        nameservers,
    );
    let portal = PhoenixChannel::disconnected(
        Secret::new(login),
        get_user_agent(None, env!("CARGO_PKG_VERSION")),
        PHOENIX_TOPIC,
        (),
        || {
            ExponentialBackoffBuilder::default()
                .with_max_elapsed_time(None)
                .build()
        },
        Arc::new(tcp_socket_factory),
    )
    .context("Failed to resolve portal URL")?;

    let mut tun_device_manager = TunDeviceManager::new(ip_packet::MAX_IP_SIZE, cli.tun_threads.0)
        .context("Failed to create TUN device manager")?;
    let tun = tun_device_manager
        .make_tun()
        .context("Failed to create TUN device")?;
    tunnel.set_tun(tun);

    let task = tokio::spawn(future::poll_fn({
        let mut eventloop = Eventloop::new(tunnel, portal, tun_device_manager);

        move |cx| eventloop.poll(cx)
    }))
    .err_into();
    let ctrl_c = pin!(ctrl_c().map_err(anyhow::Error::new));

    tokio::spawn(http_health_check::serve(
        cli.health_check.health_check_addr,
        || true,
    ));

    match future::try_select(task, ctrl_c)
        .await
        .map_err(|e| e.factor_first().0)?
    {
        future::Either::Left((Err(e), _)) => {
            tracing::info!("{e}");

            Ok(ExitCode::FAILURE)
        }
        future::Either::Right(((), _)) => {
            tracing::info!("Received CTRL+C, goodbye!");

            Ok(ExitCode::SUCCESS)
        }
    }
}

async fn get_firezone_id(env_id: Option<String>) -> Result<String> {
    if let Some(id) = env_id {
        if !id.is_empty() {
            return Ok(id);
        }
    }

    if let Ok(id) = tokio::fs::read_to_string(ID_PATH).await {
        if !id.is_empty() {
            return Ok(id);
        }
    }

    let id_path = Path::new(ID_PATH);
    tokio::fs::create_dir_all(id_path.parent().context("Missing parent")?).await?;
    let mut id_file = tokio::fs::File::create(id_path).await?;
    let id = Uuid::new_v4().to_string();
    id_file.write_all(id.as_bytes()).await?;
    Ok(id)
}

#[derive(Parser)]
#[command(author, version, about, long_about = None)]
struct Cli {
    #[arg(
        short = 'u',
        long,
        hide = true,
        env = "FIREZONE_API_URL",
        default_value = "wss://api.firezone.dev"
    )]
    api_url: Url,
    /// Token generated by the portal to authorize websocket connection.
    #[arg(env = "FIREZONE_TOKEN")]
    token: String,
    /// Friendly name to display in the UI
    #[arg(short = 'n', long, env = "FIREZONE_NAME")]
    firezone_name: Option<String>,

    /// Disable sentry.io crash-reporting agent.
    #[arg(long, env = "FIREZONE_NO_TELEMETRY", default_value_t = false)]
    no_telemetry: bool,

    /// Don't preemtively check permissions.
    #[arg(long, default_value_t = false)]
    no_check: bool,

    #[command(flatten)]
    health_check: http_health_check::HealthCheckArgs,

    /// Identifier generated by the portal to identify and display the device.
    #[arg(short = 'i', long, env = "FIREZONE_ID")]
    pub firezone_id: Option<String>,

    /// How many threads to use for reading and writing to the TUN device.
    #[arg(long, env = "FIREZONE_NUM_TUN_THREADS", default_value_t)]
    tun_threads: NumThreads,

    /// Dump internal metrics to stdout every 60s.
    #[arg(long, env = "FIREZONE_METRICS", default_value_t = false)]
    metrics: bool,
}

impl Cli {
    fn is_telemetry_allowed(&self) -> bool {
        !self.no_telemetry
    }
}

#[derive(Debug, Clone, Copy)]
struct NumThreads(pub usize);

impl Default for NumThreads {
    fn default() -> Self {
        if num_cpus::get() < 4 {
            return Self(1);
        }

        Self(2)
    }
}

impl fmt::Display for NumThreads {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.0)
    }
}

impl FromStr for NumThreads {
    type Err = <usize as FromStr>::Err;

    fn from_str(s: &str) -> std::result::Result<Self, Self::Err> {
        Ok(Self(s.parse()?))
    }
}
