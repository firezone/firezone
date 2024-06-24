use anyhow::{anyhow, bail, Context, Result};
use backoff::ExponentialBackoffBuilder;
use clap::Parser;
use firezone_bin_shared::http_health_check;
use firezone_relay::sockets::Sockets;
use firezone_relay::{
    sockets, AddressFamily, AllocationPort, ChannelData, ClientSocket, Command, IpStack,
    PeerSocket, Server, Sleep,
};
use futures::{future, FutureExt};
use phoenix_channel::{Event, LoginUrl, PhoenixChannel};
use rand::rngs::StdRng;
use rand::{Rng, SeedableRng};
use secrecy::{Secret, SecretString};
use std::net::{Ipv4Addr, Ipv6Addr};
use std::pin::Pin;
use std::sync::{Arc, Mutex};
use std::task::Poll;
use std::time::{Duration, Instant};
use tokio::signal::unix;
use tracing::{level_filters::LevelFilter, Subscriber};
use tracing_core::Dispatch;
use tracing_stackdriver::CloudTraceConfiguration;
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt, EnvFilter, Layer};
use url::Url;

const STATS_LOG_INTERVAL: Duration = Duration::from_secs(10);

const MAX_PARTITION_TIME: Duration = Duration::from_secs(60 * 15);

#[derive(Parser, Debug)]
struct Args {
    /// The public (i.e. internet-reachable) IPv4 address of the relay server.
    #[arg(long, env)]
    public_ip4_addr: Option<Ipv4Addr>,
    /// The public (i.e. internet-reachable) IPv6 address of the relay server.
    #[arg(long, env)]
    public_ip6_addr: Option<Ipv6Addr>,
    /// The port to listen on for STUN messages.
    #[arg(long, env, hide = true, default_value = "3478")]
    listen_port: u16,
    // See https://www.rfc-editor.org/rfc/rfc8656.html#name-allocations
    /// The lowest port used for TURN allocations.
    #[arg(long, env, hide = true, default_value = "49152")]
    lowest_port: u16,
    /// The highest port used for TURN allocations.
    #[arg(long, env, hide = true, default_value = "65535")]
    highest_port: u16,
    #[arg(
        long,
        env = "FIREZONE_API_URL",
        hide = true,
        default_value = "wss://api.firezone.dev"
    )]
    api_url: Url,
    /// Token generated by the portal to authorize websocket connection.
    ///
    /// If omitted, we won't connect to the portal on startup.
    #[arg(env = "FIREZONE_TOKEN")]
    token: Option<SecretString>,
    /// Used as the human name for this Relay to display in the portal. If not provided,
    /// the system hostname is used by default.
    #[arg(env = "FIREZONE_NAME")]
    name: Option<String>,
    /// A seed to use for all randomness operations.
    #[arg(long, env, hide = true)]
    rng_seed: Option<u64>,

    /// How to format the logs.
    #[arg(long, env, default_value = "human", hide = true)]
    log_format: LogFormat,

    /// Which OTLP collector we should connect to.
    ///
    /// If set, we will report traces and metrics to this collector via gRPC.
    #[arg(long, env, hide = true)]
    otlp_grpc_endpoint: Option<String>,

    /// The Google Project ID to embed in spans.
    ///
    /// Set this if you are running on Google Cloud but using the OTLP trace collector.
    /// OTLP is vendor-agnostic but for spans to be correctly recognised by Google Cloud, they need the project ID to be set.
    #[arg(long, env, hide = true)]
    google_cloud_project_id: Option<String>,

    #[command(flatten)]
    health_check: http_health_check::HealthCheckArgs,
}

#[derive(clap::ValueEnum, Debug, Clone, Copy)]
enum LogFormat {
    Human,
    Json,
    GoogleCloud,
}

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<()> {
    let args = Args::parse();

    setup_tracing(&args)?;

    let public_addr = match (args.public_ip4_addr, args.public_ip6_addr) {
        (Some(ip4), Some(ip6)) => IpStack::Dual { ip4, ip6 },
        (Some(ip4), None) => IpStack::Ip4(ip4),
        (None, Some(ip6)) => IpStack::Ip6(ip6),
        (None, None) => {
            bail!("Must listen on at least one of IPv4 or IPv6")
        }
    };

    let server = Server::new(
        public_addr,
        make_rng(args.rng_seed),
        args.listen_port,
        args.lowest_port..=args.highest_port,
    );

    let last_heartbeat_sent = Arc::new(Mutex::new(Option::<Instant>::None));

    tokio::spawn(http_health_check::serve(
        args.health_check.health_check_addr,
        make_is_healthy(last_heartbeat_sent.clone()),
    ));

    rustls::crypto::ring::default_provider()
        .install_default()
        .expect("Calling `install_default` only once per process always succeeds");

    let channel = if let Some(token) = args.token.as_ref() {
        use secrecy::ExposeSecret;

        let login = LoginUrl::relay(
            args.api_url.clone(),
            token,
            args.name.clone(),
            args.listen_port,
            args.public_ip4_addr,
            args.public_ip6_addr,
        )?;

        Some(PhoenixChannel::connect(
            Secret::new(login),
            format!("relay/{}", env!("CARGO_PKG_VERSION")),
            "relay",
            JoinMessage {
                stamp_secret: server.auth_secret().expose_secret().to_string(),
            },
            ExponentialBackoffBuilder::default()
                .with_max_elapsed_time(Some(MAX_PARTITION_TIME))
                .build(),
            Arc::new(socket_factory::tcp),
        )?)
    } else {
        tracing::warn!(target: "relay", "No portal token supplied, starting standalone mode");

        None
    };

    let mut eventloop = Eventloop::new(server, channel, public_addr, last_heartbeat_sent)?;

    tracing::info!(target: "relay", "Listening for incoming traffic on UDP port {0}", args.listen_port);

    future::poll_fn(|cx| eventloop.poll(cx))
        .await
        .context("event loop failed")?;

    tracing::info!("Goodbye!");

    Ok(())
}

/// Sets up our tracing infrastructure.
///
/// See [`log_layer`] for details on the base log layer.
///
/// ## Integration with OTLP
///
/// If the user has specified [`TraceCollector::Otlp`], we will set up an OTLP-exporter that connects to an OTLP collector specified at `Args.otlp_grpc_endpoint`.
fn setup_tracing(args: &Args) -> Result<()> {
    use opentelemetry::{global, trace::TracerProvider as _, KeyValue};
    use opentelemetry_otlp::WithExportConfig;
    use opentelemetry_sdk::{runtime::Tokio, trace::Config, Resource};

    // Use `tracing_core` directly for the temp logger because that one does not initialize a `log` logger.
    // A `log` Logger cannot be unset once set, so we can't use that for our temp logger during the setup.
    let temp_logger_guard = tracing_core::dispatcher::set_default(
        &tracing_subscriber::registry().with(log_layer(args)).into(),
    );

    let dispatch: Dispatch = match args.otlp_grpc_endpoint.clone() {
        None => tracing_subscriber::registry()
            .with(log_layer(args))
            .with(env_filter())
            .into(),
        Some(endpoint) => {
            let default_metadata = Resource::new([
                KeyValue::new("service.name", "relay"),
                KeyValue::new("service.namespace", "firezone"),
            ]);
            let metadata = default_metadata.merge(&Resource::default()); // `Resource::default` fetches from env-variables.

            let grpc_endpoint = format!("http://{endpoint}");

            tracing::trace!(target: "relay", %grpc_endpoint, "Setting up OTLP exporter for collector");

            let exporter = opentelemetry_otlp::new_exporter()
                .tonic()
                .with_endpoint(grpc_endpoint.clone());

            let tracer_provider = opentelemetry_otlp::new_pipeline()
                .tracing()
                .with_exporter(exporter)
                .with_trace_config(Config::default().with_resource(metadata.clone()))
                .install_batch(Tokio)
                .context("Failed to create OTLP trace pipeline")?;
            global::set_tracer_provider(tracer_provider.clone());

            tracing::trace!(target: "relay", "Successfully initialized trace provider on tokio runtime");

            let exporter = opentelemetry_otlp::new_exporter()
                .tonic()
                .with_endpoint(grpc_endpoint);

            let meter_provider = opentelemetry_otlp::new_pipeline()
                .metrics(Tokio)
                .with_resource(metadata)
                .with_exporter(exporter)
                .build()
                .context("Failed to create OTLP metrics pipeline")?;
            global::set_meter_provider(meter_provider);

            tracing::trace!(target: "relay", "Successfully initialized metric provider on tokio runtime");

            tracing_subscriber::registry()
                .with(log_layer(args))
                .with(tracing_opentelemetry::layer().with_tracer(tracer_provider.tracer("relay")))
                .with(env_filter())
                .into()
        }
    };

    drop(temp_logger_guard); // Drop as late as possible

    dispatch
        .try_init()
        .context("Failed to initialize tracing")?;

    Ok(())
}

/// Constructs the base log layer.
///
/// The user has a choice between:
///
/// - human-centered formatting
/// - JSON-formatting
/// - Google Cloud optimised formatting
fn log_layer<T>(args: &Args) -> Box<dyn Layer<T> + Send + Sync>
where
    T: Subscriber + for<'a> tracing_subscriber::registry::LookupSpan<'a>,
{
    match (args.log_format, args.google_cloud_project_id.clone()) {
        (LogFormat::Human, _) => tracing_subscriber::fmt::layer().boxed(),
        (LogFormat::Json, _) => tracing_subscriber::fmt::layer().json().boxed(),
        (LogFormat::GoogleCloud, None) => {
            tracing::warn!(target: "relay", "Emitting logs in Google Cloud format but without the project ID set. Spans will be emitted without IDs!");

            tracing_stackdriver::layer().boxed()
        }
        (LogFormat::GoogleCloud, Some(project_id)) => tracing_stackdriver::layer()
            .with_cloud_trace(CloudTraceConfiguration { project_id })
            .boxed(),
    }
}

fn env_filter() -> EnvFilter {
    EnvFilter::builder()
        .with_default_directive(LevelFilter::INFO.into())
        .from_env_lossy()
}

#[derive(Debug, serde::Deserialize)]
#[serde(rename_all = "snake_case", tag = "event", content = "payload")]
enum IngressMessage {
    Init(Init),
}

#[derive(serde::Deserialize, Debug)]
struct Init {}

#[derive(serde::Serialize, PartialEq, Debug, Clone)]
struct JoinMessage {
    stamp_secret: String,
}

fn make_rng(seed: Option<u64>) -> StdRng {
    let Some(seed) = seed else {
        return StdRng::from_entropy();
    };

    tracing::info!(target: "relay", "Seeding RNG from '{seed}'");

    StdRng::seed_from_u64(seed)
}

const MAX_UDP_SIZE: usize = 65536;

struct Eventloop<R> {
    sockets: Sockets,

    server: Server<R>,
    channel: Option<PhoenixChannel<JoinMessage, IngressMessage, ()>>,
    sleep: Sleep,

    sigterm: unix::Signal,
    shutting_down: bool,

    stats_log_interval: tokio::time::Interval,
    last_num_bytes_relayed: u64,

    last_heartbeat_sent: Arc<Mutex<Option<Instant>>>,

    buffer: [u8; MAX_UDP_SIZE],
}

impl<R> Eventloop<R>
where
    R: Rng,
{
    fn new(
        server: Server<R>,
        channel: Option<PhoenixChannel<JoinMessage, IngressMessage, ()>>,
        public_address: IpStack,
        last_heartbeat_sent: Arc<Mutex<Option<Instant>>>,
    ) -> Result<Self> {
        let mut sockets = Sockets::new();

        if public_address.as_v4().is_some() {
            sockets
                .bind(server.listen_port(), AddressFamily::V4)
                .with_context(|| {
                    format!(
                        "Failed to bind to port {0} on IPv4 interfaces",
                        server.listen_port()
                    )
                })?;
        }
        if public_address.as_v6().is_some() {
            sockets
                .bind(server.listen_port(), AddressFamily::V6)
                .with_context(|| {
                    format!(
                        "Failed to bind to port {0} on IPv6 interfaces",
                        server.listen_port()
                    )
                })?;
        }

        Ok(Self {
            server,
            channel,
            sleep: Sleep::default(),
            stats_log_interval: tokio::time::interval(STATS_LOG_INTERVAL),
            last_num_bytes_relayed: 0,
            sockets,
            buffer: [0u8; MAX_UDP_SIZE],
            last_heartbeat_sent,
            sigterm: unix::signal(unix::SignalKind::terminate())?,
            shutting_down: false,
        })
    }

    fn poll(&mut self, cx: &mut std::task::Context<'_>) -> Poll<Result<()>> {
        loop {
            if self.shutting_down && self.channel.is_none() && self.server.num_allocations() == 0 {
                return Poll::Ready(Ok(()));
            }

            // Priority 1: Execute the pending commands of the server.
            if let Some(next_command) = self.server.next_command() {
                match next_command {
                    Command::SendMessage { payload, recipient } => {
                        if let Err(e) = self.sockets.try_send(
                            self.server.listen_port(),
                            recipient.into_socket(),
                            &payload,
                        ) {
                            tracing::warn!(target: "relay", %recipient, "Failed to send message: {e}");
                        }
                    }
                    Command::CreateAllocation { port, family } => {
                        self.sockets.bind(port.value(), family).with_context(|| {
                            format!(
                                "Failed to bind to port {} on {family} interfaces",
                                port.value()
                            )
                        })?;

                        tracing::info!(target: "relay", %port, %family, "Created allocation");
                    }
                    Command::FreeAllocation { port, family } => {
                        self.sockets.unbind(port.value(), family).with_context(|| {
                            format!(
                                "Failed to unbind to port {} on {family} interfaces",
                                port.value()
                            )
                        })?;

                        tracing::info!(target: "relay", %port, %family, "Freeing allocation");
                    }
                }

                continue; // Attempt to process more commands.
            }

            // Priority 2: Read from our sockets.
            //
            // We read the packet with an offset of 4 bytes so we can encode the channel-data header into that without re-allocating.
            // This only matters for relaying from an allocation to a client because the data coming in on an allocation is "raw" (i.e. unwrapped) application data.
            // To allow clients to correctly associate this data, we need to wrap it in a channel-data message as depicted below.
            //
            // For traffic coming from clients that needs to be forwarded to peers, this doesn't matter because we already a channel data message and only need to forward its payload.
            //
            // However, we don't know which socket we will be reading from when we call `poll_recv_from`, which is why we always offset the read-buffer by 4 bytes like this:
            //
            //  01│23│456789....
            // ┌──┼──┼──────────────────────────┐
            // │CN│LN│PAYLOAD...                │
            // └──┴──┴──────────────────────────┘
            //       ▲
            //       │
            //       Start of read-buffer.
            //
            //  CN: Channel number
            //  LN: Length
            let (header, payload) = self.buffer.split_at_mut(4);

            match self.sockets.poll_recv_from(payload, cx) {
                Poll::Ready(Ok(sockets::Received {
                    port, // Packets coming in on the TURN port are from clients.
                    from,
                    packet,
                })) if port == self.server.listen_port() => {
                    if let Some((port, peer)) = self.server.handle_client_input(
                        packet,
                        ClientSocket::new(from),
                        Instant::now(),
                    ) {
                        // Re-parse as `ChannelData` if we should relay it.
                        let payload = ChannelData::parse(packet)
                            .expect("valid ChannelData if we should relay it")
                            .data(); // When relaying data from a client to peer, we need to forward only the channel-data's payload.

                        if let Err(e) =
                            self.sockets
                                .try_send(port.value(), peer.into_socket(), payload)
                        {
                            tracing::warn!(target: "relay", %peer, "Failed to relay data to peer: {e}");
                        }
                    };
                    continue;
                }
                Poll::Ready(Ok(sockets::Received {
                    port, // Packets coming in on any other port are from peers.
                    from,
                    packet,
                })) => {
                    if let Some((client, channel)) = self.server.handle_peer_traffic(
                        packet,
                        PeerSocket::new(from),
                        AllocationPort::new(port),
                    ) {
                        let total_length = ChannelData::encode_header_to_slice(
                            channel,
                            packet.len() as u16,
                            header,
                        );

                        if let Err(e) = self.sockets.try_send(
                            self.server.listen_port(), // Packets coming in from peers always go out on the TURN port
                            client.into_socket(),
                            &self.buffer[..total_length],
                        ) {
                            tracing::warn!(target: "relay", %client, "Failed to relay data to client: {e}");
                        };
                    };
                    continue;
                }
                Poll::Ready(Err(sockets::Error::Io(e))) => {
                    tracing::warn!(target: "relay", "Error while receiving message: {e}");
                    continue;
                }
                Poll::Ready(Err(sockets::Error::MioTaskCrashed(e))) => return Poll::Ready(Err(e)), // Fail the event-loop. We can't operate without the `mio` worker-task.
                Poll::Pending => {}
            }

            // Priority 3: Check when we need to next be woken. This needs to happen after all state modifications.
            if let Some(timeout) = self.server.poll_timeout() {
                Pin::new(&mut self.sleep).reset(timeout);
                // Purposely no `continue` because we just change the state of `sleep` and we poll it below.
            }

            // Priority 4: Handle time-sensitive tasks:
            if let Poll::Ready(deadline) = self.sleep.poll_unpin(cx) {
                self.server.handle_timeout(deadline);
                continue; // Handle potentially new commands.
            }

            // Priority 5: Handle portal messages
            match self.channel.as_mut().map(|c| c.poll(cx)) {
                Some(Poll::Ready(Err(e))) => {
                    return Poll::Ready(Err(anyhow!("Portal connection failed: {e}")));
                }
                Some(Poll::Ready(Ok(event))) => {
                    self.handle_portal_event(event);
                    continue;
                }
                Some(Poll::Pending) | None => {}
            }

            match self.sigterm.poll_recv(cx) {
                Poll::Ready(Some(())) => {
                    if self.shutting_down {
                        // Received a repeated SIGTERM whilst shutting down

                        return Poll::Ready(Err(anyhow!("Forcing shutdown on repeated SIGTERM")));
                    }

                    tracing::info!(active_allocations = %self.server.num_allocations(), "Received SIGTERM, initiating graceful shutdown");

                    self.shutting_down = true;

                    if let Some(portal) = self.channel.as_mut() {
                        match portal.close() {
                            Ok(()) => {}
                            Err(phoenix_channel::Connecting) => {
                                self.channel = None; // If we are still connecting, just discard the websocket connection.
                            }
                        }
                    }

                    continue;
                }
                Poll::Ready(None) | Poll::Pending => {}
            }

            if self.stats_log_interval.poll_tick(cx).is_ready() {
                let num_allocations = self.server.num_allocations();
                let num_channels = self.server.num_active_channels();

                let bytes_relayed_since_last_tick =
                    self.server.num_relayed_bytes() - self.last_num_bytes_relayed;
                self.last_num_bytes_relayed = self.server.num_relayed_bytes();

                let avg_throughput = bytes_relayed_since_last_tick / STATS_LOG_INTERVAL.as_secs();

                tracing::info!(target: "relay", "Allocations = {num_allocations} Channels = {num_channels} Throughput = {}", fmt_human_throughput(avg_throughput as f64));

                continue;
            }

            return Poll::Pending;
        }
    }

    fn handle_portal_event(&mut self, event: phoenix_channel::Event<IngressMessage, ()>) {
        match event {
            Event::SuccessResponse { res: (), .. } => {}
            Event::JoinedRoom { topic } => {
                tracing::info!(target: "relay", "Successfully joined room '{topic}'");
            }
            Event::ErrorResponse { topic, req_id, res } => {
                tracing::warn!(target: "relay", "Request with ID {req_id} on topic {topic} failed: {res:?}");
            }
            Event::HeartbeatSent => {
                tracing::debug!(target: "relay", "Heartbeat sent to portal");
                *self.last_heartbeat_sent.lock().unwrap() = Some(Instant::now());
            }
            Event::InboundMessage {
                msg: IngressMessage::Init(Init {}),
                ..
            } => {}
            Event::Closed => {
                self.channel = None;
            }
        }
    }
}

fn fmt_human_throughput(mut throughput: f64) -> String {
    let units = ["B/s", "kB/s", "MB/s", "GB/s", "TB/s"];

    for unit in units {
        if throughput < 1000.0 {
            return format!("{throughput:.2} {unit}");
        }

        throughput /= 1000.0;
    }

    format!("{throughput:.2} TB/s")
}

/// Factory fn for [`is_healthy`].
fn make_is_healthy(
    last_heartbeat_sent: Arc<Mutex<Option<Instant>>>,
) -> impl Fn() -> bool + Clone + Send + Sync + 'static {
    move || is_healthy(last_heartbeat_sent.clone())
}

fn is_healthy(last_heartbeat_sent: Arc<Mutex<Option<Instant>>>) -> bool {
    let guard = last_heartbeat_sent.lock().unwrap();

    let Some(last_hearbeat_sent) = *guard else {
        return true; // If we are not connected to the portal, we are always healthy.
    };

    last_hearbeat_sent.elapsed() < MAX_PARTITION_TIME
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn prints_humanfriendly_throughput() {
        assert_eq!(fmt_human_throughput(42.0), "42.00 B/s");
        assert_eq!(fmt_human_throughput(1_234.0), "1.23 kB/s");
        assert_eq!(fmt_human_throughput(955_333_999.0), "955.33 MB/s");
        assert_eq!(fmt_human_throughput(100_000_000_000.0), "100.00 GB/s");
    }

    // If we are running in standalone mode, we are always healthy.
    #[test]
    fn given_no_heartbeat_is_healthy() {
        let is_healthy = is_healthy(Arc::new(Mutex::new(None)));

        assert!(is_healthy)
    }

    #[test]
    fn given_heartbeat_in_last_15_min_is_healthy() {
        let is_healthy = is_healthy(Arc::new(Mutex::new(Some(
            Instant::now() - Duration::from_secs(10),
        ))));

        assert!(is_healthy)
    }

    #[test]
    fn given_last_heartbeat_older_than_15_min_is_not_healthy() {
        let is_healthy = is_healthy(Arc::new(Mutex::new(Some(
            Instant::now() - Duration::from_secs(60 * 15),
        ))));

        assert!(!is_healthy)
    }

    // Regression tests to ensure we can parse sockets as well as domains for the otlp-grpc endpoint.
    #[test]
    fn args_can_parse_otlp_endpoint_from_socket() {
        let args =
            Args::try_parse_from(["relay", "--otlp-grpc-endpoint", "127.0.0.1:4317"]).unwrap();

        assert_eq!(args.otlp_grpc_endpoint.unwrap(), "127.0.0.1:4317");
    }

    #[test]
    fn args_can_parse_otlp_endpoint_from_domain() {
        let args =
            Args::try_parse_from(["relay", "--otlp-grpc-endpoint", "localhost:4317"]).unwrap();

        assert_eq!(args.otlp_grpc_endpoint.unwrap(), "localhost:4317");
    }
}
