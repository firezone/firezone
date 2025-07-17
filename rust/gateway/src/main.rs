use crate::eventloop::{Eventloop, PHOENIX_TOPIC};
use anyhow::{Context, Result};
use backoff::ExponentialBackoffBuilder;
use clap::Parser;
use firezone_bin_shared::{
    TunDeviceManager, device_id, http_health_check,
    platform::{tcp_socket_factory, udp_socket_factory},
};

use firezone_telemetry::{
    MaybePushMetricsExporter, NoopPushMetricsExporter, Telemetry, feature_flags, otel,
};
use firezone_tunnel::GatewayTunnel;
use ip_packet::IpPacket;
use opentelemetry_otlp::WithExportConfig;
use opentelemetry_sdk::metrics::SdkMeterProvider;
use phoenix_channel::LoginUrl;
use phoenix_channel::get_user_agent;

use futures::{TryFutureExt, future};
use phoenix_channel::PhoenixChannel;
use secrecy::Secret;
use std::{collections::BTreeSet, path::Path};
use std::{fmt, pin::pin};
use std::{process::ExitCode, str::FromStr};
use std::{sync::Arc, time::Duration};
use tokio::signal::ctrl_c;
use tracing_subscriber::layer;
use tun::Tun;
use url::Url;

mod eventloop;

const ID_PATH: &str = "/var/lib/firezone/gateway_id";
const RELEASE: &str = concat!("gateway@", env!("CARGO_PKG_VERSION"));

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

    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .expect("Failed to create tokio runtime");

    match runtime
        .block_on(try_main(cli, &mut telemetry))
        .context("Failed to start Gateway")
    {
        Ok(()) => {
            tracing::info!("Received CTRL+C, goodbye!");
            runtime.block_on(telemetry.stop());

            ExitCode::SUCCESS
        }
        Err(e) => {
            tracing::info!("{e:#}");
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

async fn try_main(cli: Cli, telemetry: &mut Telemetry) -> Result<()> {
    firezone_logging::setup_global_subscriber(layer::Identity::default())
        .context("Failed to set up logging")?;

    tracing::info!(
        arch = std::env::consts::ARCH,
        os = std::env::consts::OS,
        version = env!("CARGO_PKG_VERSION"),
        system_uptime = firezone_bin_shared::uptime::get().map(tracing::field::debug),
        "`gateway` started logging"
    );

    tracing::debug!(?cli);

    let firezone_id = get_firezone_id(cli.firezone_id.clone()).await
        .context("Couldn't read FIREZONE_ID or write it to disk: Please provide it through the env variable or provide rw access to /var/lib/firezone/")?;

    if cli.is_telemetry_allowed() {
        telemetry
            .start(
                cli.api_url.as_str(),
                RELEASE,
                firezone_telemetry::GATEWAY_DSN,
                firezone_id.clone(),
            )
            .await;
    }

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

    let login = LoginUrl::gateway(cli.api_url, &cli.token, firezone_id, cli.firezone_name)
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
                .with_max_elapsed_time(Some(Duration::from_secs(60 * 15)))
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

    if cli.validate_checksums {
        tunnel.set_tun(ValidateChecksumAdapter::wrap(tun));
    } else {
        tunnel.set_tun(tun);
    }

    let eventloop = future::poll_fn({
        let mut eventloop = Eventloop::new(tunnel, portal, tun_device_manager);

        move |cx| eventloop.poll(cx)
    });
    let ctrl_c = pin!(ctrl_c().map_err(anyhow::Error::new));

    tokio::spawn(http_health_check::serve(
        cli.health_check.health_check_addr,
        || true,
    ));

    match future::try_select(eventloop, ctrl_c)
        .await
        .map_err(|e| e.factor_first().0)?
    {
        future::Either::Left((never, _)) => match never {},
        future::Either::Right(((), _)) => Ok(()),
    }
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

async fn get_firezone_id(env_id: Option<String>) -> Result<String> {
    if let Some(id) = env_id
        && !id.is_empty()
    {
        return Ok(id);
    }

    if let Ok(id) = tokio::fs::read_to_string(ID_PATH).await
        && !id.is_empty()
    {
        return Ok(id);
    }

    let device_id = device_id::get_or_create_at(Path::new(ID_PATH))?;

    Ok(device_id.id)
}

#[derive(Parser, Debug)]
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
    token: Secret<String>,
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
    firezone_id: Option<String>,

    /// How many threads to use for reading and writing to the TUN device.
    #[arg(long, env = "FIREZONE_NUM_TUN_THREADS", default_value_t)]
    tun_threads: NumThreads,

    /// Where to export metrics to.
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

    /// Validates the checksums of all packets leaving the TUN device.
    #[arg(
        long,
        hide = true,
        env = "FIREZONE_VALIDATE_CHECKSUMS",
        default_value_t = false
    )]
    validate_checksums: bool,
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

/// An adapter struct around [`Tun`] that validates IPv4, UDP and TCP checksums.
struct ValidateChecksumAdapter {
    inner: Box<dyn Tun>,
}

impl Tun for ValidateChecksumAdapter {
    fn poll_send_ready(
        &mut self,
        cx: &mut std::task::Context,
    ) -> std::task::Poll<std::io::Result<()>> {
        self.inner.poll_send_ready(cx)
    }

    fn send(&mut self, packet: IpPacket) -> std::io::Result<()> {
        if let Some(ipv4) = packet.ipv4_header() {
            let expected = ipv4.calc_header_checksum();
            let actual = ipv4.header_checksum;

            if expected != actual {
                tracing::warn!(?packet, %expected, %actual, "IPv4 checksum invalid");
            }
        }

        if let Some(udp) = packet.as_udp() {
            let actual = udp.checksum();

            let expected = match &packet {
                IpPacket::Ipv4(ipv4) => udp
                    .to_header()
                    .calc_checksum_ipv4(&ipv4.header().to_header(), udp.payload()),
                IpPacket::Ipv6(ipv6) => udp
                    .to_header()
                    .calc_checksum_ipv6(&ipv6.header().to_header(), udp.payload()),
            }
            .map_err(std::io::Error::other)?;

            if expected != actual {
                tracing::warn!(?packet, %expected, %actual, "UDP checksum invalid");
            }
        }

        if let Some(tcp) = packet.as_tcp() {
            let actual = tcp.checksum();

            let expected = match &packet {
                IpPacket::Ipv4(ipv4) => tcp
                    .to_header()
                    .calc_checksum_ipv4(&ipv4.header().to_header(), tcp.payload()),
                IpPacket::Ipv6(ipv6) => tcp
                    .to_header()
                    .calc_checksum_ipv6(&ipv6.header().to_header(), tcp.payload()),
            }
            .map_err(std::io::Error::other)?;

            if expected != actual {
                tracing::warn!(?packet, %expected, %actual, "TCP checksum invalid");
            }
        }

        self.inner.send(packet)
    }

    fn poll_recv_many(
        &mut self,
        cx: &mut std::task::Context,
        buf: &mut Vec<IpPacket>,
        max: usize,
    ) -> std::task::Poll<usize> {
        self.inner.poll_recv_many(cx, buf, max)
    }

    fn name(&self) -> &str {
        self.inner.name()
    }
}

impl ValidateChecksumAdapter {
    fn wrap(inner: Box<dyn Tun>) -> Box<dyn Tun> {
        Box::new(Self { inner })
    }
}
