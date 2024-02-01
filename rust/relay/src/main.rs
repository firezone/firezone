use anyhow::{anyhow, bail, Context, Result};
use backoff::ExponentialBackoffBuilder;
use clap::Parser;
use firezone_relay::{
    AddressFamily, Allocation, AllocationId, ClientSocket, Command, IpStack, PeerSocket, Server,
    Sleep, UdpSocket,
};
use futures::channel::mpsc;
use futures::{future, FutureExt, SinkExt, StreamExt};
use opentelemetry::{sdk, KeyValue};
use opentelemetry_otlp::WithExportConfig;
use phoenix_channel::{Error, Event, PhoenixChannel, SecureUrl};
use rand::rngs::StdRng;
use rand::{Rng, SeedableRng};
use secrecy::{Secret, SecretString};
use std::collections::hash_map::Entry;
use std::collections::HashMap;
use std::convert::Infallible;
use std::net::{Ipv4Addr, Ipv6Addr, SocketAddr};
use std::pin::Pin;
use std::task::{ready, Poll};
use std::time::{Duration, SystemTime};
use tracing::{level_filters::LevelFilter, Instrument, Subscriber};
use tracing_core::Dispatch;
use tracing_stackdriver::CloudTraceConfiguration;
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt, EnvFilter, Layer};
use url::Url;

const STATS_LOG_INTERVAL: Duration = Duration::from_secs(10);

#[derive(Parser, Debug)]
struct Args {
    /// The public (i.e. internet-reachable) IPv4 address of the relay server.
    #[arg(long, env)]
    public_ip4_addr: Option<Ipv4Addr>,
    /// The public (i.e. internet-reachable) IPv6 address of the relay server.
    #[arg(long, env)]
    public_ip6_addr: Option<Ipv6Addr>,
    /// The address of the local interface where we should serve our health-check endpoint.
    ///
    /// The actual health-check endpoint will be at `http://<health_check_addr>/healthz`.
    #[arg(long, env, hide = true, default_value = "0.0.0.0:8080")]
    health_check_addr: SocketAddr,
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
    /// A seed to use for all randomness operations.
    ///
    /// Only available in debug builds.
    #[arg(long, env, hide = true)]
    rng_seed: Option<u64>,

    /// How to format the logs.
    #[arg(long, env, default_value = "human", hide = true)]
    log_format: LogFormat,

    /// Which OTLP collector we should connect to.
    ///
    /// If set, we will report traces and metrics to this collector via gRPC.
    #[arg(long, env, hide = true)]
    otlp_grpc_endpoint: Option<SocketAddr>,

    /// The Google Project ID to embed in spans.
    ///
    /// Set this if you are running on Google Cloud but using the OTLP trace collector.
    /// OTLP is vendor-agnostic but for spans to be correctly recognised by Google Cloud, they need the project ID to be set.
    #[arg(long, env, hide = true)]
    google_cloud_project_id: Option<String>,
}

#[derive(clap::ValueEnum, Debug, Clone, Copy)]
enum LogFormat {
    Human,
    Json,
    GoogleCloud,
}

#[tokio::main]
async fn main() -> Result<()> {
    let args = Args::parse();

    setup_tracing(&args).await?;

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
        args.lowest_port,
        args.highest_port,
    );

    let channel = if let Some(token) = args.token.as_ref() {
        let base_url = args.api_url.clone();
        let stamp_secret = server.auth_secret();

        let span = tracing::error_span!("connect_to_portal", config_url = %base_url);

        connect_to_portal(&args, token, base_url, stamp_secret)
            .instrument(span)
            .await?
    } else {
        tracing::warn!(target: "relay", "No portal token supplied, starting standalone mode");

        None
    };

    let mut eventloop = Eventloop::new(server, channel, public_addr)?;

    tokio::spawn(firezone_relay::health_check::serve(args.health_check_addr));

    tracing::info!(target: "relay", "Listening for incoming traffic on UDP port 3478");

    future::poll_fn(|cx| eventloop.poll(cx))
        .await
        .context("event loop failed")?;

    Ok(())
}

/// Sets up our tracing infrastructure.
///
/// See [`log_layer`] for details on the base log layer.
///
/// ## Integration with OTLP
///
/// If the user has specified [`TraceCollector::Otlp`], we will set up an OTLP-exporter that connects to an OTLP collector specified at `Args.otlp_grpc_endpoint`.
async fn setup_tracing(args: &Args) -> Result<()> {
    // Use `tracing_core` directly for the temp logger because that one does not initialize a `log` logger.
    // A `log` Logger cannot be unset once set, so we can't use that for our temp logger during the setup.
    let temp_logger_guard = tracing_core::dispatcher::set_default(
        &tracing_subscriber::registry().with(log_layer(args)).into(),
    );

    let dispatch: Dispatch = match args.otlp_grpc_endpoint {
        None => tracing_subscriber::registry().with(log_layer(args)).into(),
        Some(endpoint) => {
            let grpc_endpoint = format!("http://{endpoint}");

            tracing::trace!(target: "relay", %grpc_endpoint, "Setting up OTLP exporter for collector");

            let exporter = opentelemetry_otlp::new_exporter()
                .tonic()
                .with_endpoint(grpc_endpoint.clone());

            let tracer =
                opentelemetry_otlp::new_pipeline()
                    .tracing()
                    .with_exporter(exporter)
                    .with_trace_config(sdk::trace::Config::default().with_resource(
                        sdk::Resource::new(vec![KeyValue::new("service.name", "relay")]),
                    ))
                    .install_batch(opentelemetry::runtime::Tokio)
                    .context("Failed to create OTLP trace pipeline")?;

            tracing::trace!(target: "relay", "Successfully initialized trace provider on tokio runtime");

            let exporter = opentelemetry_otlp::new_exporter()
                .tonic()
                .with_endpoint(grpc_endpoint);

            opentelemetry_otlp::new_pipeline()
                .metrics(opentelemetry::runtime::Tokio)
                .with_exporter(exporter)
                .build()
                .context("Failed to create OTLP metrics pipeline")?;

            tracing::trace!(target: "relay", "Successfully initialized metric controller on tokio runtime");

            tracing_subscriber::registry()
                .with(log_layer(args))
                .with(
                    tracing_opentelemetry::layer()
                        .with_tracer(tracer)
                        .with_filter(env_filter()),
                )
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
    let log_layer = match (args.log_format, args.google_cloud_project_id.clone()) {
        (LogFormat::Human, _) => tracing_subscriber::fmt::layer().boxed(),
        (LogFormat::Json, _) => tracing_subscriber::fmt::layer().json().boxed(),
        (LogFormat::GoogleCloud, None) => {
            tracing::warn!(target: "relay", "Emitting logs in Google Cloud format but without the project ID set. Spans will be emitted without IDs!");

            tracing_stackdriver::layer().boxed()
        }
        (LogFormat::GoogleCloud, Some(project_id)) => tracing_stackdriver::layer()
            .with_cloud_trace(CloudTraceConfiguration { project_id })
            .boxed(),
    };

    log_layer.with_filter(env_filter()).boxed()
}

fn env_filter() -> EnvFilter {
    EnvFilter::builder()
        .with_default_directive(LevelFilter::INFO.into())
        .from_env_lossy()
}

async fn connect_to_portal(
    args: &Args,
    token: &SecretString,
    mut url: Url,
    stamp_secret: &SecretString,
) -> Result<Option<PhoenixChannel<JoinMessage, (), ()>>> {
    use secrecy::ExposeSecret;

    if !url.path().is_empty() {
        tracing::warn!(target: "relay", "Overwriting path component of portal URL with '/relay/websocket'");
    }

    url.set_path("relay/websocket");
    url.query_pairs_mut()
        .append_pair("token", token.expose_secret().as_str());

    if let Some(public_ip4_addr) = args.public_ip4_addr {
        url.query_pairs_mut()
            .append_pair("ipv4", &public_ip4_addr.to_string());
    }
    if let Some(public_ip6_addr) = args.public_ip6_addr {
        url.query_pairs_mut()
            .append_pair("ipv6", &public_ip6_addr.to_string());
    }

    let (channel, Init {}) = phoenix_channel::init::<_, Init, _, _>(
        Secret::from(SecureUrl::from_url(url)),
        format!("relay/{}", env!("CARGO_PKG_VERSION")),
        "relay",
        JoinMessage {
            stamp_secret: stamp_secret.expose_secret().to_string(),
        },
        ExponentialBackoffBuilder::default()
            .with_max_elapsed_time(None)
            .build(),
    )
    .await??;

    Ok(Some(channel))
}

#[derive(serde::Deserialize, Debug)]
struct Init {}

#[derive(serde::Serialize, PartialEq, Debug, Clone)]
struct JoinMessage {
    stamp_secret: String,
}

#[cfg(debug_assertions)]
fn make_rng(seed: Option<u64>) -> StdRng {
    let Some(seed) = seed else {
        return StdRng::from_entropy();
    };

    tracing::info!(target: "relay", "Seeding RNG from '{seed}'");

    StdRng::seed_from_u64(seed)
}

#[cfg(not(debug_assertions))]
fn make_rng(seed: Option<u64>) -> StdRng {
    if seed.is_some() {
        tracing::debug!(target: "relay", "Ignoring rng-seed because we are running in release mode");
    }

    StdRng::from_entropy()
}

struct Eventloop<R> {
    inbound_data_receiver: mpsc::Receiver<(Vec<u8>, ClientSocket)>,
    outbound_ip4_data_sender: mpsc::Sender<(Vec<u8>, ClientSocket)>,
    outbound_ip6_data_sender: mpsc::Sender<(Vec<u8>, ClientSocket)>,
    server: Server<R>,
    channel: Option<PhoenixChannel<JoinMessage, (), ()>>,
    allocations: HashMap<(AllocationId, AddressFamily), Allocation>,
    relay_data_sender: mpsc::Sender<(Vec<u8>, PeerSocket, AllocationId)>,
    relay_data_receiver: mpsc::Receiver<(Vec<u8>, PeerSocket, AllocationId)>,
    sleep: Sleep,

    stats_log_interval: tokio::time::Interval,
    last_num_bytes_relayed: u64,
}

impl<R> Eventloop<R>
where
    R: Rng,
{
    fn new(
        server: Server<R>,
        channel: Option<PhoenixChannel<JoinMessage, (), ()>>,
        public_address: IpStack,
    ) -> Result<Self> {
        let (relay_data_sender, relay_data_receiver) = mpsc::channel(1);
        let (inbound_data_sender, inbound_data_receiver) = mpsc::channel(1000);
        let (outbound_ip4_data_sender, outbound_ip4_data_receiver) = mpsc::channel(1000);
        let (outbound_ip6_data_sender, outbound_ip6_data_receiver) = mpsc::channel(1000);

        if public_address.as_v4().is_some() {
            tokio::spawn(main_udp_socket_task(
                AddressFamily::V4,
                inbound_data_sender.clone(),
                outbound_ip4_data_receiver,
            ));
        }
        if public_address.as_v6().is_some() {
            tokio::spawn(main_udp_socket_task(
                AddressFamily::V6,
                inbound_data_sender,
                outbound_ip6_data_receiver,
            ));
        }

        Ok(Self {
            inbound_data_receiver,
            outbound_ip4_data_sender,
            outbound_ip6_data_sender,
            server,
            channel,
            allocations: Default::default(),
            relay_data_sender,
            relay_data_receiver,
            sleep: Sleep::default(),
            stats_log_interval: tokio::time::interval(STATS_LOG_INTERVAL),
            last_num_bytes_relayed: 0,
        })
    }

    fn poll(&mut self, cx: &mut std::task::Context<'_>) -> Poll<Result<()>> {
        let span = tracing::error_span!("Eventloop::poll");
        let _guard = span.enter();

        loop {
            // Don't fail these results. One of the senders might not be active because we might not be listening on IP4 / IP6.
            let _ = ready!(self.outbound_ip4_data_sender.poll_ready_unpin(cx));
            let _ = ready!(self.outbound_ip6_data_sender.poll_ready_unpin(cx));

            let now = SystemTime::now();

            // Priority 1: Execute the pending commands of the server.
            if let Some(next_command) = self.server.next_command() {
                match next_command {
                    Command::SendMessage { payload, recipient } => {
                        let span = tracing::error_span!("Command::SendMessage");
                        let _guard = span.enter();

                        let sender = match recipient.family() {
                            AddressFamily::V4 => &mut self.outbound_ip4_data_sender,
                            AddressFamily::V6 => &mut self.outbound_ip6_data_sender,
                        };

                        if let Err(e) = sender.try_send((payload, recipient)) {
                            if e.is_disconnected() {
                                return Poll::Ready(Err(anyhow!(
                                    "Channel to primary UDP socket task has been closed"
                                )));
                            }

                            // Should never happen because we poll for readiness above.
                            if e.is_full() {
                                tracing::warn!(target: "relay", %recipient, "Dropping message because channel to primary UDP socket task is full");
                            }
                        }
                    }
                    Command::CreateAllocation { id, family, port } => {
                        let span =
                            tracing::error_span!("Command::CreateAllocation", %id, %family, %port);
                        let _guard = span.enter();

                        self.allocations.insert(
                            (id, family),
                            Allocation::new(self.relay_data_sender.clone(), id, family, port),
                        );
                    }
                    Command::FreeAllocation { id, family } => {
                        let span = tracing::error_span!("Command::FreeAllocation", %id, %family);
                        let _guard = span.enter();

                        if self.allocations.remove(&(id, family)).is_none() {
                            tracing::debug!(target: "relay", "Unknown allocation {id}");
                            continue;
                        };

                        tracing::info!(target: "relay", "Freeing addresses of allocation {id}");
                    }
                    Command::Wake { deadline } => {
                        let span = tracing::error_span!("Command::Wake", ?deadline);
                        let _guard = span.enter();

                        match deadline.duration_since(now) {
                            Ok(duration) => {
                                tracing::trace!(target: "relay", ?duration, "Suspending event loop")
                            }
                            Err(e) => {
                                let difference = e.duration();

                                tracing::warn!(target: "relay",
                                    ?difference,
                                    "Wake time is already in the past, waking now"
                                )
                            }
                        }

                        Pin::new(&mut self.sleep).reset(deadline);
                    }
                    Command::ForwardData { id, data, receiver } => {
                        let span = tracing::error_span!("Command::ForwardData", %id, %receiver);
                        let _guard = span.enter();

                        let mut allocation = match self.allocations.entry((id, receiver.family())) {
                            Entry::Occupied(entry) => entry,
                            Entry::Vacant(_) => {
                                tracing::debug!(target: "relay", allocation = %id, family = %receiver.family(), "Unknown allocation");
                                continue;
                            }
                        };

                        if allocation.get_mut().send(data, receiver).is_err() {
                            self.server.handle_allocation_failed(id);
                            allocation.remove();
                        }
                    }
                }

                continue; // Attempt to process more commands.
            }

            // Priority 2: Handle time-sensitive tasks:
            if self.sleep.poll_unpin(cx).is_ready() {
                self.server.handle_deadline_reached(now);
                continue; // Handle potentially new commands.
            }

            // Priority 3: Handle relayed data (we prioritize latency for existing allocations over making new ones)
            if let Poll::Ready(Some((data, sender, allocation))) =
                self.relay_data_receiver.poll_next_unpin(cx)
            {
                self.server.handle_peer_traffic(&data, sender, allocation);
                continue; // Handle potentially new commands.
            }

            // Priority 4: Accept new allocations / answer STUN requests etc
            if let Poll::Ready(Some((buffer, sender))) =
                self.inbound_data_receiver.poll_next_unpin(cx)
            {
                self.server.handle_client_input(&buffer, sender, now);
                continue; // Handle potentially new commands.
            }

            // Priority 5: Handle portal messages
            match self.channel.as_mut().map(|c| c.poll(cx)) {
                Some(Poll::Ready(Err(Error::Serde(e)))) => {
                    tracing::warn!(target: "relay", "Failed to deserialize portal message: {e}");
                    continue; // This is not a hard-error, we can continue.
                }
                Some(Poll::Ready(Err(e))) => {
                    return Poll::Ready(Err(anyhow!("Portal connection failed: {e}")));
                }
                Some(Poll::Ready(Ok(Event::SuccessResponse { res: (), .. }))) => {
                    continue;
                }
                Some(Poll::Ready(Ok(Event::JoinedRoom { topic }))) => {
                    tracing::info!(target: "relay", "Successfully joined room '{topic}'");
                    continue;
                }
                Some(Poll::Ready(Ok(Event::ErrorResponse {
                    topic,
                    req_id,
                    reason,
                }))) => {
                    tracing::warn!(target: "relay", "Request with ID {req_id} on topic {topic} failed: {reason}");
                    continue;
                }
                Some(Poll::Ready(Ok(Event::HeartbeatSent))) => {
                    tracing::debug!(target: "relay", "Heartbeat sent to portal");
                    continue;
                }
                Some(Poll::Ready(Ok(
                    Event::InboundMessage { msg: (), .. } | Event::InboundReq { req: (), .. },
                )))
                | Some(Poll::Pending)
                | None => {}
            }

            if self.stats_log_interval.poll_tick(cx).is_ready() {
                let num_allocations = self.server.num_allocations();
                let num_channels = self.server.num_channels();

                let bytes_relayed_since_last_tick =
                    self.server.num_relayed_bytes() - self.last_num_bytes_relayed;
                self.last_num_bytes_relayed = self.server.num_relayed_bytes();

                let avg_throughput = bytes_relayed_since_last_tick / STATS_LOG_INTERVAL.as_secs();

                tracing::info!(target: "relay", "Allocations = {num_allocations} Channels = {num_channels} Throughput = {}", fmt_human_throughput(avg_throughput as f64));
            }

            return Poll::Pending;
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

async fn main_udp_socket_task(
    family: AddressFamily,
    mut inbound_data_sender: mpsc::Sender<(Vec<u8>, ClientSocket)>,
    mut outbound_data_receiver: mpsc::Receiver<(Vec<u8>, ClientSocket)>,
) -> Result<Infallible> {
    let mut socket = UdpSocket::bind(family, 3478)?;

    loop {
        tokio::select! {
            result = socket.recv() => {
                let (data, sender) = result?;
                inbound_data_sender.send((data.to_vec(), ClientSocket::new(sender))).await?;
            }
            maybe_item = outbound_data_receiver.next() => {
                let (data, recipient) = maybe_item.context("Outbound data channel closed")?;
                socket.send_to(data.as_ref(), recipient.into_socket()).await?;
            }
        }
    }
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
}
