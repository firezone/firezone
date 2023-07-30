use anyhow::{anyhow, bail, Context, Result};
use clap::Parser;
use futures::channel::mpsc;
use futures::{future, FutureExt, StreamExt};
use phoenix_channel::{Error, Event, PhoenixChannel};
use rand::rngs::StdRng;
use rand::{Rng, SeedableRng};
use relay::{
    AddressFamily, Allocation, AllocationId, Command, Server, Sleep, SocketAddrExt, UdpSocket,
};
use std::collections::hash_map::Entry;
use std::collections::{HashMap, VecDeque};
use std::net::{Ipv4Addr, SocketAddr};
use std::pin::Pin;
use std::task::Poll;
use std::time::SystemTime;
use tracing::level_filters::LevelFilter;
use tracing_subscriber::layer::SubscriberExt;
use tracing_subscriber::util::SubscriberInitExt;
use tracing_subscriber::{EnvFilter, Layer};
use url::Url;

#[derive(Parser, Debug)]
struct Args {
    /// The public (i.e. internet-reachable) IPv4 address of the relay server.
    ///
    /// Must route to the local interface we listen on.
    #[arg(long, env)]
    public_ip4_addr: Ipv4Addr,
    /// The address of the local interface we should listen on.
    ///
    /// Must not be a wildcard-address.
    #[arg(long, env)]
    listen_ip4_addr: Ipv4Addr,
    /// The websocket URL of the portal server to connect to.
    #[arg(long, env, default_value = "wss://api.firezone.dev")]
    portal_ws_url: Url,
    /// Token generated by the portal to authorize websocket connection.
    ///
    /// If omitted, we won't connect to the portal on startup.
    #[arg(long, env)]
    portal_token: Option<String>,
    /// Whether to allow connecting to the portal over an insecure connection.
    #[arg(long)]
    allow_insecure_ws: bool,
    /// A seed to use for all randomness operations.
    ///
    /// Only available in debug builds.
    #[arg(long, env)]
    rng_seed: Option<u64>,
    /// Whether to log in JSON format.
    #[arg(long, env = "JSON_LOG")]
    json: bool,
}

#[tokio::main]
async fn main() -> Result<()> {
    let args = Args::parse();

    let env_filter = EnvFilter::builder()
        .with_default_directive(LevelFilter::INFO.into())
        .from_env_lossy();

    if args.json {
        tracing_subscriber::registry()
            .with(tracing_stackdriver::layer().with_filter(env_filter))
            .init()
    } else {
        tracing_subscriber::fmt().with_env_filter(env_filter).init()
    }

    let server = Server::new(args.public_ip4_addr, make_rng(args.rng_seed));

    let channel = if let Some(token) = args.portal_token {
        let mut url = args.portal_ws_url.clone();
        if url.scheme() == "ws" && !args.allow_insecure_ws {
            bail!("Refusing to connect to portal over insecure connection, pass --allow-insecure-ws to override")
        }
        if !url.path().is_empty() {
            tracing::warn!("Overwriting path component of portal URL with '/relay/websocket'");
        }

        url.set_path("relay/websocket");
        url.query_pairs_mut()
            .append_pair("token", &token)
            .append_pair("ipv4", &args.listen_ip4_addr.to_string());

        let mut channel = PhoenixChannel::<InboundPortalMessage, ()>::connect(
            url,
            format!("relay/{}", env!("CARGO_PKG_VERSION")),
        )
        .await
        .context("Failed to connect to the portal")?;

        tracing::info!("Connected to portal, waiting for init message",);

        loop {
            channel.join(
                "relay",
                JoinMessage {
                    stamp_secret: server.auth_secret().to_string(),
                },
            );

            let event = future::poll_fn(|cx| channel.poll(cx))
                .await
                .context("portal connection failed")?;

            match event {
                Event::JoinedRoom { topic } if topic == "relay" => {
                    tracing::info!("Joined relay room on portal")
                }
                Event::InboundMessage {
                    topic,
                    msg: InboundPortalMessage::Init {},
                } => {
                    tracing::info!("Received init message from portal on topic {topic}, starting relay activities");
                    break Some(channel);
                }
                other => {
                    tracing::debug!("Unhandled message from portal: {other:?}");
                }
            }
        }
    } else {
        None
    };

    let mut eventloop = Eventloop::new(server, channel, args.listen_ip4_addr).await?;

    tracing::info!("Listening for incoming traffic on UDP port 3478");

    future::poll_fn(|cx| eventloop.poll(cx))
        .await
        .context("event loop failed")?;

    Ok(())
}

#[derive(serde::Serialize, PartialEq, Debug)]
struct JoinMessage {
    stamp_secret: String,
}

#[derive(serde::Deserialize, PartialEq, Debug)]
#[serde(rename_all = "snake_case", tag = "event", content = "payload")]
enum InboundPortalMessage {
    Init {},
}

#[cfg(debug_assertions)]
fn make_rng(seed: Option<u64>) -> StdRng {
    let Some(seed) = seed else {
        return StdRng::from_entropy();
    };

    tracing::info!("Seeding RNG from '{seed}'");

    StdRng::seed_from_u64(seed)
}

#[cfg(not(debug_assertions))]
fn make_rng(seed: Option<u64>) -> StdRng {
    if seed.is_some() {
        tracing::debug!("Ignoring rng-seed because we are running in release mode");
    }

    StdRng::from_entropy()
}

struct Eventloop<R> {
    ip4_socket: UdpSocket,
    listen_ip4_address: Ipv4Addr,
    server: Server<R>,
    channel: Option<PhoenixChannel<InboundPortalMessage, ()>>,
    allocations: HashMap<(AllocationId, AddressFamily), Allocation>,
    relay_data_sender: mpsc::Sender<(Vec<u8>, SocketAddr, AllocationId)>,
    relay_data_receiver: mpsc::Receiver<(Vec<u8>, SocketAddr, AllocationId)>,
    sleep: Sleep,

    client_send_buffer: VecDeque<(Vec<u8>, SocketAddr)>,
}

impl<R> Eventloop<R>
where
    R: Rng,
{
    async fn new(
        server: Server<R>,
        channel: Option<PhoenixChannel<InboundPortalMessage, ()>>,
        listen_ip4_address: Ipv4Addr,
    ) -> Result<Self> {
        let (sender, receiver) = mpsc::channel(1);

        Ok(Self {
            ip4_socket: UdpSocket::bind((listen_ip4_address, 3478)).await?,
            listen_ip4_address,
            server,
            channel,
            allocations: Default::default(),
            relay_data_sender: sender,
            relay_data_receiver: receiver,
            sleep: Sleep::default(),
            client_send_buffer: Default::default(),
        })
    }

    fn poll(&mut self, cx: &mut std::task::Context<'_>) -> Poll<Result<()>> {
        loop {
            // Priority 1: Execute the pending commands of the server.
            if let Some(next_command) = self.server.next_command() {
                match next_command {
                    Command::SendMessage { payload, recipient } => {
                        self.client_send_buffer.push_back((payload, recipient));
                    }
                    Command::CreateAllocation {
                        id,
                        family: AddressFamily::V4,
                        port,
                    } => {
                        self.allocations.insert(
                            (id, AddressFamily::V4),
                            Allocation::new_ip4(
                                self.relay_data_sender.clone(),
                                id,
                                self.listen_ip4_address,
                                port,
                            ),
                        );
                    }
                    Command::CreateAllocation {
                        id: _,
                        family: AddressFamily::V6,
                        port: _,
                    } => {
                        todo!("Creating IPv6 allocations is not supported yet")
                    }
                    Command::FreeAllocation { id, family } => {
                        if self.allocations.remove(&(id, family)).is_none() {
                            tracing::debug!("Unknown allocation {id}");
                            continue;
                        };

                        tracing::info!("Freeing addresses of allocation {id}");
                    }
                    Command::Wake { deadline } => {
                        Pin::new(&mut self.sleep).reset(deadline);
                    }
                    Command::ForwardData { id, data, receiver } => {
                        let mut allocation = match self.allocations.entry(id) {
                            Entry::Occupied(entry) => entry,
                            Entry::Vacant(_) => {
                                tracing::debug!(allocation = %id, "Unknown allocation");
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

            // Priority 2: Flush data to the socket.
            if let Some((payload, recipient)) = self.client_send_buffer.pop_front() {
                match self.ip4_socket.try_send_to(&payload, recipient, cx)? {
                    Poll::Ready(()) => {
                        continue;
                    }
                    Poll::Pending => {
                        // Yield early if we cannot send data.
                        // Continuing the event loop here would cause `client_send_buffer` to potentially grow faster than we can send data.

                        self.client_send_buffer.push_front((payload, recipient));
                        return Poll::Pending;
                    }
                }
            }

            // Priority 3: Handle time-sensitive tasks:
            if self.sleep.poll_unpin(cx).is_ready() {
                self.server.handle_deadline_reached(SystemTime::now());
                continue; // Handle potentially new commands.
            }

            // Priority 4: Handle relayed data (we prioritize latency for existing allocations over making new ones)
            if let Poll::Ready(Some((data, sender, allocation))) =
                self.relay_data_receiver.poll_next_unpin(cx)
            {
                self.server.handle_relay_input(&data, sender, allocation);
                continue; // Handle potentially new commands.
            }

            // Priority 5: Accept new allocations / answer STUN requests etc
            if let Poll::Ready((buffer, sender)) = self.ip4_socket.poll_recv(cx)? {
                self.server
                    .handle_client_input(buffer.filled(), sender, SystemTime::now());
                continue; // Handle potentially new commands.
            }

            // Priority 6: Handle portal messages
            match self.channel.as_mut().map(|c| c.poll(cx)) {
                Some(Poll::Ready(Ok(Event::InboundMessage {
                    msg: InboundPortalMessage::Init {},
                    ..
                }))) => {
                    tracing::warn!("Received init message during operation");
                    continue;
                }
                Some(Poll::Ready(Err(Error::Serde(e)))) => {
                    tracing::warn!("Failed to deserialize portal message: {e}");
                    continue; // This is not a hard-error, we can continue.
                }
                Some(Poll::Ready(Err(e))) => {
                    return Poll::Ready(Err(anyhow!("Portal connection failed: {e}")));
                }
                Some(Poll::Ready(Ok(Event::SuccessResponse { res: (), .. }))) => {
                    continue;
                }
                Some(Poll::Ready(Ok(Event::JoinedRoom { topic }))) => {
                    tracing::info!("Successfully joined room '{topic}'");
                    continue;
                }
                Some(Poll::Ready(Ok(Event::ErrorResponse {
                    topic,
                    req_id,
                    reason,
                }))) => {
                    tracing::warn!("Request with ID {req_id} on topic {topic} failed: {reason}");
                    continue;
                }
                Some(Poll::Ready(Ok(Event::InboundReq {
                    req: InboundPortalMessage::Init {},
                    ..
                }))) => {
                    return Poll::Ready(Err(anyhow!("Init message is not a request")));
                }
                Some(Poll::Ready(Ok(Event::HeartbeatSent))) => {
                    tracing::debug!("Heartbeat sent to relay");
                    continue;
                }
                Some(Poll::Pending) | None => {}
            }

            return Poll::Pending;
        }
    }
}
