//! TURN relay load testing.
//!
//! Stresses a TURN relay (specifically Firezone's eBPF relay) by streaming UDP
//! datagrams through a channel binding and observing packet loss at the peer.
//!
//! The topology uses two UDP sockets:
//!
//! - the *client* socket creates an allocation and binds a channel to the *peer*,
//! - the *peer* socket receives the relayed datagrams.
//!
//! Each datagram carries a sequence number and a send timestamp, so the peer can
//! detect loss, reordering and one-way latency (both sockets share this process'
//! clock).
//!
//! The TURN protocol handling is sans-IO (pure [`stun_codec`] message building and
//! parsing); all IO goes through [`socket_factory`]'s GSO-enabled [`PerfUdpSocket`].

use crate::config::MAX_TURN_PAYLOAD_SIZE;
use crate::util::StreamingStats;
use crate::{WithSeed, cli};
use anyhow::{Context as _, ErrorExt as _, Result, anyhow, bail};
use bufferpool::BufferPool;
use bytecodec::{DecodeExt as _, EncodeExt as _};
use bytes::BytesMut;
use clap::Parser;
use gat_lending_iterator::LendingIterator as _;
use ip_packet::Ecn;
use rand::random;
use serde::Serialize;
use socket_factory::{DatagramOut, PerfUdpSocket};
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use stun_codec::rfc5389::attributes::{
    ErrorCode, MessageIntegrity, Nonce, Realm, Software, Username, XorMappedAddress,
};
use stun_codec::rfc5389::methods::BINDING;
use stun_codec::rfc5766::attributes::{
    ChannelNumber, Lifetime, RequestedTransport, XorPeerAddress, XorRelayAddress,
};
use stun_codec::rfc5766::methods::{ALLOCATE, CHANNEL_BIND, REFRESH};
use stun_codec::{Message, MessageClass, MessageDecoder, MessageEncoder, TransactionId};
use tokio::time::Instant;
use url::Url;

/// Size of the per-datagram header: an 8-byte sequence number + 8-byte send timestamp.
pub const TURN_HEADER_SIZE: usize = 16;

/// Size of a `ChannelData` header (channel number + length), prepended to every datagram.
const CHANNEL_DATA_HEADER_SIZE: usize = 4;

/// First valid channel number per RFC 5766.
const FIRST_CHANNEL: u16 = 0x4000;

/// UDP transport number used in `REQUESTED-TRANSPORT`.
const UDP_TRANSPORT: u8 = 17;

/// `ERROR-CODE` returned when the supplied nonce is stale.
const STALE_NONCE: u16 = 438;

/// `ERROR-CODE` returned when an allocation already exists for the client's 5-tuple.
const ALLOCATION_MISMATCH: u16 = 437;

/// How long to wait for a response to a control request before retrying.
const REQUEST_TIMEOUT: Duration = Duration::from_secs(2);

/// How many times to (re-)send a control request before giving up.
const MAX_REQUEST_ATTEMPTS: usize = 5;

/// Maximum number of datagrams coalesced into a single GSO send.
const MAX_BATCH: usize = 64;

/// How many probes the peer sends to open its NAT mapping toward the relayed address.
const PUNCH_COUNT: usize = 5;

/// Extra time the receiver keeps listening after the sender stops, to drain in-flight datagrams.
const DRAIN_GRACE: Duration = Duration::from_secs(2);

/// Below this remaining wait the sender busy-spins instead of sleeping, so pacing is
/// not limited by the timer granularity (~1ms, and ~15ms on Windows).
#[cfg(windows)]
const SPIN_THRESHOLD: Duration = Duration::from_millis(16);
#[cfg(not(windows))]
const SPIN_THRESHOLD: Duration = Duration::from_millis(2);

/// Spin iterations between cooperative yields while busy-waiting.
const SPIN_ITERS: usize = 64;

/// How often to emit a live progress line during the data phase.
const PROGRESS_INTERVAL: Duration = Duration::from_secs(1);

/// Default UDP payload size (a typical media MTU).
const DEFAULT_PAYLOAD_SIZE: usize = 1280;

/// Default time to stream datagrams.
const DEFAULT_DURATION: Duration = Duration::from_secs(30);

#[derive(Parser)]
pub struct Args {
    /// Relay socket address (`ip:port`)
    #[arg(long, value_name = "ADDR")]
    server: Option<SocketAddr>,

    /// TURN username (long-term credential)
    #[arg(long)]
    username: Option<String>,

    /// TURN password (long-term credential)
    #[arg(long)]
    password: Option<String>,

    /// UDP payload size in bytes (default 1280)
    #[arg(long, value_parser = parse_payload_size)]
    payload_size: Option<usize>,

    /// Target send bitrate (e.g. 2mbps, 500kbps)
    #[arg(long, value_parser = cli::parse_bitrate)]
    bitrate: Option<u64>,

    /// How long to stream datagrams (e.g. 30s, 5m); default 30s
    #[arg(long, value_parser = cli::parse_duration)]
    duration: Option<Duration>,

    /// Fail the invocation if packet loss exceeds this percentage.
    #[arg(long, value_name = "PERCENT")]
    max_loss: Option<f64>,

    /// Fetch the relay address and credentials from the Firezone portal instead
    /// of using --server/--username/--password.
    #[arg(long)]
    fetch_credentials: bool,

    /// Prefer an IPv4 relay address when fetching from the portal.
    #[arg(long, conflicts_with = "ipv6")]
    ipv4: bool,

    /// Prefer an IPv6 relay address when fetching from the portal.
    #[arg(long, conflicts_with = "ipv4")]
    ipv6: bool,

    /// Firezone portal URL (used with --fetch-credentials).
    #[arg(long, default_value = "wss://api.firezone.dev")]
    portal_url: Url,

    /// Path to the Firezone token file (used with --fetch-credentials).
    #[arg(long, default_value_os_t = known_dirs::default_token_path())]
    token_path: PathBuf,
}

/// Resolved TURN test parameters (ready to execute).
#[derive(Debug, Clone)]
pub struct TestConfig {
    pub server: SocketAddr,
    pub username: String,
    pub password: String,
    pub payload_size: usize,
    pub bitrate_bps: u64,
    pub duration: Duration,
    pub max_loss_percent: Option<f64>,
}

/// Build a [`TestConfig`] from CLI args, the config `base`, and optional
/// portal-fetched `credentials`.
///
/// Precedence for the relay address and credentials is: portal credentials >
/// CLI flags > config; the remaining parameters are CLI > config > default.
fn build_config(
    args: Args,
    base: Option<TestConfig>,
    credentials: Option<crate::portal::RelayCredentials>,
) -> Result<TestConfig> {
    let base = base.as_ref();
    let credentials = credentials.as_ref();

    let server = credentials
        .map(|c| c.server)
        .or(args.server)
        .or_else(|| base.map(|b| b.server))
        .context("--server is required (use --fetch-credentials, or add [turn] to the config)")?;
    let username = credentials
        .map(|c| c.username.clone())
        .or(args.username)
        .or_else(|| base.map(|b| b.username.clone()))
        .context("--username is required (use --fetch-credentials, or add [turn] to the config)")?;
    let password = credentials
        .map(|c| c.password.clone())
        .or(args.password)
        .or_else(|| base.map(|b| b.password.clone()))
        .context("--password is required (use --fetch-credentials, or add [turn] to the config)")?;
    let payload_size = args
        .payload_size
        .or_else(|| base.map(|b| b.payload_size))
        .unwrap_or(DEFAULT_PAYLOAD_SIZE);
    let bitrate_bps = args
        .bitrate
        .or_else(|| base.map(|b| b.bitrate_bps))
        .context("--bitrate is required (or add [turn] to the config)")?;
    let duration = args
        .duration
        .or_else(|| base.map(|b| b.duration))
        .unwrap_or(DEFAULT_DURATION);
    let max_loss_percent = args
        .max_loss
        .or_else(|| base.and_then(|b| b.max_loss_percent));

    Ok(TestConfig {
        server,
        username,
        password,
        payload_size,
        bitrate_bps,
        duration,
        max_loss_percent,
    })
}

/// Run TURN test from CLI args merged over an optional config base.
///
/// With `--fetch-credentials`, the relay address and credentials are fetched
/// from the portal first and take precedence over `--server`/`--username`/`--password`.
pub async fn run_with_args(args: Args, base: Option<TestConfig>, seed: u64) -> Result<()> {
    let credentials = if args.fetch_credentials {
        let prefer = relay_preference(&args);
        Some(
            crate::portal::fetch_relay(&args.portal_url, &args.token_path, prefer)
                .await
                .context("Failed to fetch relay credentials from the portal")?,
        )
    } else {
        None
    };

    let config = build_config(args, base, credentials)?;

    run_with_config(config, seed).await
}

/// The relay IP-family preference from `--ipv4` / `--ipv6` (mutually exclusive).
fn relay_preference(args: &Args) -> Option<crate::portal::IpFamily> {
    if args.ipv4 {
        Some(crate::portal::IpFamily::V4)
    } else if args.ipv6 {
        Some(crate::portal::IpFamily::V6)
    } else {
        None
    }
}

/// Run TURN test from resolved config.
pub async fn run_with_config(config: TestConfig, seed: u64) -> Result<()> {
    let max_loss_percent = config.max_loss_percent;
    let summary = run(config, seed).await?;

    print_summary(&summary);
    let loss_percent = summary.loss_percent;

    println!(
        "{}",
        serde_json::to_string(&WithSeed::new(seed, summary)).expect("Failed to serialize metrics")
    );

    if let Some(threshold) = max_loss_percent {
        anyhow::ensure!(
            loss_percent <= threshold,
            "packet loss {loss_percent:.2}% exceeds the configured threshold of {threshold:.2}%"
        );
    }

    Ok(())
}

async fn run(config: TestConfig, seed: u64) -> Result<TurnTestSummary> {
    tracing::info!(
        server = %config.server,
        payload_size = config.payload_size,
        bitrate_bps = config.bitrate_bps,
        duration = ?config.duration,
        %seed,
        "Starting TURN relay load test"
    );

    let bind_addr = unspecified_addr(config.server);
    let client = bind_socket(bind_addr).context("Failed to bind client socket")?;
    let peer = bind_socket(bind_addr).context("Failed to bind peer socket")?;

    let frame_size = CHANNEL_DATA_HEADER_SIZE + config.payload_size;
    let pool = BufferPool::<BytesMut>::new(MAX_BATCH * frame_size, "turn-loadtest");

    // 1. Learn the peer socket's relay-visible (reflexive) address.
    let peer_address = stun_binding(&peer, config.server, &pool)
        .await
        .context("STUN binding for peer socket failed")?;
    tracing::info!(%peer_address, "Resolved peer reflexive address");

    // 2. Create an authenticated allocation on the client socket.
    let allocation = allocate(&client, config.server, &config, &pool)
        .await
        .context("TURN allocation failed")?;
    tracing::info!(relayed = %allocation.relayed_address, "Created TURN allocation");

    // 3. Bind a channel from the client to the peer.
    let channel = FIRST_CHANNEL;
    channel_bind(
        &client,
        config.server,
        &allocation.credentials,
        channel,
        peer_address,
        &pool,
    )
    .await
    .context("TURN channel bind failed")?;
    tracing::info!(channel, %peer_address, "Bound channel to peer");

    // 4. Open the peer's NAT mapping toward the relayed address so the relay can reach it.
    punch(&peer, allocation.relayed_address, &pool)
        .await
        .context("Failed to open peer NAT mapping")?;

    // 5. Stream datagrams and observe loss at the peer, reporting progress live.
    let counters = Arc::new(Counters::default());
    let data_start = Instant::now();
    let recv_deadline = data_start + config.duration + DRAIN_GRACE;
    let payload_size = config.payload_size;

    let reporter = tokio::spawn(report_progress(
        Arc::clone(&counters),
        data_start,
        recv_deadline,
    ));
    let receiver = {
        let counters = Arc::clone(&counters);
        tokio::spawn(async move { receive(peer, payload_size, recv_deadline, counters).await })
    };

    let send_stats = send(&client, &pool, channel, &config, data_start, &counters)
        .await
        .context("Failed while sending datagrams")?;
    let recv_stats = receiver.await.context("Receiver task panicked")?;
    reporter.abort();

    // Clean exit: delete the allocation. Best-effort, as it would otherwise expire
    // on its own and the test has already produced its results.
    match delete_allocation(&client, config.server, &allocation.credentials, &pool).await {
        Ok(()) => tracing::info!("Deleted TURN allocation"),
        Err(error) => tracing::warn!(error = %error, "Failed to delete TURN allocation on exit"),
    }

    Ok(build_summary(
        &config,
        channel,
        peer_address,
        allocation.relayed_address,
        send_stats,
        recv_stats,
    ))
}

/// A successfully created allocation along with the credentials used to authenticate it.
struct Allocation {
    credentials: Credentials,
    relayed_address: SocketAddr,
}

/// Resolve the peer socket's reflexive address via an unauthenticated STUN binding.
async fn stun_binding(
    socket: &PerfUdpSocket,
    server: SocketAddr,
    pool: &BufferPool<BytesMut>,
) -> Result<SocketAddr> {
    let request = Message::new(MessageClass::Request, BINDING, TransactionId::new(random()));
    let response = request_response(socket, server, request, pool, "Binding").await?;

    let mapped = response
        .get_attribute::<XorMappedAddress>()
        .context("Binding response is missing XOR-MAPPED-ADDRESS")?;

    Ok(mapped.address())
}

/// Create an authenticated allocation, performing the 401-challenge handshake.
async fn allocate(
    socket: &PerfUdpSocket,
    server: SocketAddr,
    config: &TestConfig,
    pool: &BufferPool<BytesMut>,
) -> Result<Allocation> {
    // The initial, unauthenticated request is expected to be rejected with a 401
    // carrying the realm and nonce we then authenticate with.
    let challenge = request_response(socket, server, allocate_request(), pool, "Allocate").await?;

    if challenge.class() == MessageClass::SuccessResponse {
        bail!("relay accepted an unauthenticated allocation; expected a 401 challenge");
    }

    let mut credentials =
        Credentials::from_challenge(&challenge, &config.username, &config.password)?;

    let response = match authenticated_request(
        socket,
        server,
        &mut credentials,
        authenticated_allocate,
        pool,
        "Allocate",
    )
    .await
    {
        Ok(response) => response,
        // An allocation is already bound to our 5-tuple: delete it and retry once.
        Err(error) if is_allocation_mismatch(&error) => {
            tracing::info!(
                "Allocation mismatch (437); deleting the existing allocation and retrying"
            );

            delete_allocation(socket, server, &credentials, pool)
                .await
                .context("Failed to delete the existing allocation after a 437")?;

            authenticated_request(
                socket,
                server,
                &mut credentials,
                authenticated_allocate,
                pool,
                "Allocate",
            )
            .await
            .context("Allocate retry after deleting the existing allocation failed")?
        }
        Err(error) => return Err(error),
    };

    let relayed_address = response
        .get_attribute::<XorRelayAddress>()
        .context("Allocate response is missing XOR-RELAYED-ADDRESS")?
        .address();

    Ok(Allocation {
        credentials,
        relayed_address,
    })
}

/// Bind `channel` to `peer` so `ChannelData` from the client is relayed to the peer.
async fn channel_bind(
    socket: &PerfUdpSocket,
    server: SocketAddr,
    credentials: &Credentials,
    channel: u16,
    peer: SocketAddr,
    pool: &BufferPool<BytesMut>,
) -> Result<()> {
    let mut credentials = credentials.clone();
    let build = |credentials: &Credentials| authenticated_channel_bind(credentials, channel, peer);

    authenticated_request(socket, server, &mut credentials, build, pool, "ChannelBind").await?;

    Ok(())
}

/// Delete the allocation by sending an authenticated `Refresh` with a zero
/// lifetime (RFC 5766 §7); the nonce is refreshed once if the relay reports it stale.
async fn delete_allocation(
    socket: &PerfUdpSocket,
    server: SocketAddr,
    credentials: &Credentials,
    pool: &BufferPool<BytesMut>,
) -> Result<()> {
    let mut credentials = credentials.clone();

    authenticated_request(
        socket,
        server,
        &mut credentials,
        authenticated_refresh,
        pool,
        "Refresh",
    )
    .await?;

    Ok(())
}

/// Send a few probes from the peer to the relayed address to open its NAT mapping.
async fn punch(
    socket: &PerfUdpSocket,
    relayed: SocketAddr,
    pool: &BufferPool<BytesMut>,
) -> Result<()> {
    let probe = [0u8; 8];

    for _ in 0..PUNCH_COUNT {
        send_datagram(socket, relayed, &probe, probe.len(), pool).await?;
    }

    Ok(())
}

/// Live counters shared between the sender, receiver and progress reporter.
#[derive(Default)]
struct Counters {
    packets_sent: AtomicU64,
    bytes_sent: AtomicU64,
    packets_received: AtomicU64,
    bytes_received: AtomicU64,
    /// Highest sequence number received so far, used to measure loss without
    /// counting still-in-flight packets (whose sequence is higher than any seen).
    highest_sequence: AtomicU64,
}

/// Statistics gathered by the sender.
struct SendStats {
    packets_sent: u64,
    bytes_sent: u64,
}

/// Stream `ChannelData` datagrams to the relay at the configured bitrate.
///
/// Datagrams are coalesced into GSO batches and paced against wall-clock time so
/// the long-term average matches the target bitrate even across timer jitter.
async fn send(
    socket: &PerfUdpSocket,
    pool: &BufferPool<BytesMut>,
    channel: u16,
    config: &TestConfig,
    data_start: Instant,
    counters: &Counters,
) -> Result<SendStats> {
    let frame_size = CHANNEL_DATA_HEADER_SIZE + config.payload_size;
    let frame_bits = (frame_size * 8) as f64;
    let packets_per_second = config.bitrate_bps as f64 / frame_bits;
    let send_end = data_start + config.duration;

    let mut sequence = 0u64;
    let mut batch = Vec::with_capacity(MAX_BATCH * frame_size);

    loop {
        let now = Instant::now();
        if now >= send_end {
            break;
        }

        let elapsed = now.duration_since(data_start).as_secs_f64();
        let target = (packets_per_second * elapsed) as u64;

        // Already ahead of schedule: sleep until the next datagram is due.
        if target <= sequence {
            let next_due =
                data_start + Duration::from_secs_f64((sequence as f64 + 1.0) / packets_per_second);
            pace_until(next_due.min(send_end)).await;
            continue;
        }

        let count = ((target - sequence) as usize).min(MAX_BATCH);
        batch.clear();
        for _ in 0..count {
            write_frame(&mut batch, channel, sequence, config.payload_size);
            sequence += 1;
        }

        let packet = pool.pull_initialised(&batch);
        socket
            .send(DatagramOut {
                src: None,
                dst: config.server,
                packet,
                segment_size: frame_size,
                ecn: Ecn::NonEct,
            })
            .await?;

        counters
            .packets_sent
            .fetch_add(count as u64, Ordering::Relaxed);
        counters
            .bytes_sent
            .fetch_add(batch.len() as u64, Ordering::Relaxed);
    }

    Ok(SendStats {
        packets_sent: sequence,
        bytes_sent: counters.bytes_sent.load(Ordering::Relaxed),
    })
}

/// Wait until `deadline`, sleeping for the bulk of the wait but busy-spinning the
/// final sub-[`SPIN_THRESHOLD`] tail so pacing is not limited by timer granularity.
async fn pace_until(deadline: Instant) {
    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return;
        }

        if remaining > SPIN_THRESHOLD {
            tokio::time::sleep(remaining - SPIN_THRESHOLD).await;
            continue;
        }

        for _ in 0..SPIN_ITERS {
            std::hint::spin_loop();
        }
        tokio::task::yield_now().await;
    }
}

/// Statistics gathered by the receiver.
struct RecvStats {
    packets_received: u64,
    bytes_received: u64,
    highest_sequence: Option<u64>,
    reordered: u64,
    latency: StreamingStats,
}

/// Receive relayed datagrams until `deadline`, recording loss / reorder / latency.
async fn receive(
    socket: PerfUdpSocket,
    payload_size: usize,
    deadline: Instant,
    counters: Arc<Counters>,
) -> RecvStats {
    let mut stats = RecvStats {
        packets_received: 0,
        bytes_received: 0,
        highest_sequence: None,
        reordered: 0,
        latency: StreamingStats::new(),
    };

    loop {
        tokio::select! {
            biased;

            () = tokio::time::sleep_until(deadline) => break,
            result = socket.recv_from() => {
                let mut datagrams = match result {
                    Ok(datagrams) => datagrams,
                    Err(e) => {
                        tracing::warn!(error = %e, "Failed to receive on peer socket");
                        break;
                    }
                };

                while let Some(datagram) = datagrams.next() {
                    record_datagram(&mut stats, &counters, datagram.packet, payload_size);
                }
            }
        }
    }

    stats
}

/// Record a single received datagram, ignoring anything that isn't one of ours.
fn record_datagram(stats: &mut RecvStats, counters: &Counters, packet: &[u8], payload_size: usize) {
    if packet.len() != payload_size {
        return;
    }
    let Some((sequence, sent_nanos)) = parse_payload(packet) else {
        return;
    };

    stats.packets_received += 1;
    stats.bytes_received += packet.len() as u64;
    counters.packets_received.fetch_add(1, Ordering::Relaxed);
    counters
        .bytes_received
        .fetch_add(packet.len() as u64, Ordering::Relaxed);
    counters
        .highest_sequence
        .fetch_max(sequence, Ordering::Relaxed);

    if stats
        .highest_sequence
        .is_some_and(|highest| sequence < highest)
    {
        stats.reordered += 1;
    }
    stats.highest_sequence = Some(stats.highest_sequence.map_or(sequence, |h| h.max(sequence)));

    if let Some(latency) = latency_since(sent_nanos) {
        stats.latency.record(latency);
    }
}

/// Append a `ChannelData` frame (header + sequenced payload) to `batch`.
fn write_frame(batch: &mut Vec<u8>, channel: u16, sequence: u64, payload_size: usize) {
    batch.extend_from_slice(&channel.to_be_bytes());
    batch.extend_from_slice(&(payload_size as u16).to_be_bytes());

    let payload_start = batch.len();
    batch.extend_from_slice(&sequence.to_be_bytes());
    batch.extend_from_slice(&unix_nanos().to_be_bytes());
    batch.resize(payload_start + payload_size, 0); // Pad to the configured payload size.
}

/// Parse the sequence number and send timestamp from a received payload.
fn parse_payload(packet: &[u8]) -> Option<(u64, u64)> {
    let sequence = u64::from_be_bytes(packet.get(0..8)?.try_into().ok()?);
    let sent_nanos = u64::from_be_bytes(packet.get(8..16)?.try_into().ok()?);

    Some((sequence, sent_nanos))
}

/// Emit a live progress line every [`PROGRESS_INTERVAL`] until `deadline`.
async fn report_progress(counters: Arc<Counters>, data_start: Instant, deadline: Instant) {
    let mut ticker = tokio::time::interval(PROGRESS_INTERVAL);
    ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    ticker.tick().await; // The first tick completes immediately.

    tracing::info!("[ ID]  Interval          Transfer      Bitrate          Loss");

    let mut prev_bytes_received = 0u64;
    let mut prev_elapsed = 0.0f64;

    loop {
        let now = ticker.tick().await;
        if now >= deadline {
            break;
        }

        let elapsed = now.duration_since(data_start).as_secs_f64();
        let interval = elapsed - prev_elapsed;

        let received = counters.packets_received.load(Ordering::Relaxed);
        let bytes_received = counters.bytes_received.load(Ordering::Relaxed);
        let highest_sequence = counters.highest_sequence.load(Ordering::Relaxed);

        let interval_bytes = bytes_received.saturating_sub(prev_bytes_received);
        let bitrate = if interval > 0.0 {
            interval_bytes as f64 * 8.0 / interval
        } else {
            0.0
        };

        // Transfer/bitrate are for the receiver this interval; loss is cumulative
        // and measured against the highest sequence received, not what was sent.
        tracing::info!(
            "[RCV]  {prev_elapsed:5.2}-{elapsed:5.2} sec  {:>11}  {:>14}  {:.2}%",
            format_bytes(interval_bytes),
            format_bitrate(bitrate),
            live_loss_percent(highest_sequence, received),
        );

        prev_bytes_received = bytes_received;
        prev_elapsed = elapsed;
    }
}

/// Print an iperf3-style summary for the sender and receiver.
fn print_summary(summary: &TurnTestSummary) {
    let secs = summary.duration_secs.max(1) as f64;

    tracing::info!("- - - - - - - - - - - - - - - - - - - - - - - - -");
    tracing::info!(
        "[SND]   0.00-{secs:5.2} sec  {:>11}  {:>14}  {} sent  sender",
        format_bytes(summary.bytes_sent),
        format_bitrate(summary.send_bitrate_bps as f64),
        summary.packets_sent,
    );
    tracing::info!(
        "[RCV]   0.00-{secs:5.2} sec  {:>11}  {:>14}  {}/{} ({:.2}%)  receiver",
        format_bytes(summary.bytes_received),
        format_bitrate(summary.recv_bitrate_bps as f64),
        summary.packets_lost,
        summary.packets_sent,
        summary.loss_percent,
    );
}

/// Format a byte count like iperf3 (KBytes/MBytes/GBytes, base 1024).
fn format_bytes(bytes: u64) -> String {
    const KIB: f64 = 1024.0;
    const MIB: f64 = KIB * 1024.0;
    const GIB: f64 = MIB * 1024.0;

    let bytes = bytes as f64;

    if bytes >= GIB {
        format!("{:.2} GBytes", bytes / GIB)
    } else if bytes >= MIB {
        format!("{:.2} MBytes", bytes / MIB)
    } else if bytes >= KIB {
        format!("{:.1} KBytes", bytes / KIB)
    } else {
        format!("{bytes:.0} Bytes")
    }
}

/// Format a bitrate like iperf3 (Kbits/Mbits/Gbits per sec, base 1000).
fn format_bitrate(bits_per_sec: f64) -> String {
    if bits_per_sec >= 1e9 {
        format!("{:.2} Gbits/sec", bits_per_sec / 1e9)
    } else if bits_per_sec >= 1e6 {
        format!("{:.2} Mbits/sec", bits_per_sec / 1e6)
    } else if bits_per_sec >= 1e3 {
        format!("{:.1} Kbits/sec", bits_per_sec / 1e3)
    } else {
        format!("{bits_per_sec:.0} bits/sec")
    }
}

/// Cumulative packet loss as a percentage, measured against the highest sequence
/// received so far so that still-in-flight packets aren't counted as lost.
fn live_loss_percent(highest_sequence: u64, received: u64) -> f64 {
    if received == 0 {
        return 0.0;
    }

    let expected = highest_sequence + 1;
    expected.saturating_sub(received) as f64 / expected as f64 * 100.0
}

// --- Sans-IO TURN protocol ---------------------------------------------------

/// Long-term credentials plus the realm and nonce offered by the relay.
#[derive(Clone)]
struct Credentials {
    username: Username,
    realm: Realm,
    nonce: Nonce,
    password: String,
}

impl Credentials {
    fn from_challenge(
        challenge: &Message<Attribute>,
        username: &str,
        password: &str,
    ) -> Result<Self> {
        let realm = challenge
            .get_attribute::<Realm>()
            .context("401 challenge is missing REALM")?
            .clone();
        let nonce = challenge
            .get_attribute::<Nonce>()
            .context("401 challenge is missing NONCE")?
            .clone();
        let username = Username::new(username.to_owned())
            .map_err(|e| anyhow!("invalid TURN username: {e}"))?;

        Ok(Self {
            username,
            realm,
            nonce,
            password: password.to_owned(),
        })
    }
}

/// The result of a control request, distinguishing the stale-nonce case for a retry.
enum Outcome {
    Success,
    StaleNonce(Nonce),
    Error { code: u16, reason: String },
}

/// Send an authenticated request, refreshing the nonce once if the relay reports it stale.
async fn authenticated_request(
    socket: &PerfUdpSocket,
    server: SocketAddr,
    credentials: &mut Credentials,
    build: impl Fn(&Credentials) -> Message<Attribute>,
    pool: &BufferPool<BytesMut>,
    label: &str,
) -> Result<Message<Attribute>> {
    let mut refreshed_nonce = false;

    loop {
        let response = request_response(socket, server, build(credentials), pool, label).await?;

        match outcome(&response)? {
            Outcome::Success => return Ok(response),
            Outcome::StaleNonce(nonce) if !refreshed_nonce => {
                tracing::debug!(%label, "Stale nonce; retrying with a fresh one");
                credentials.nonce = nonce;
                refreshed_nonce = true;
            }
            Outcome::StaleNonce(_) => bail!("{label} failed: stale nonce after retry"),
            Outcome::Error { code, reason } => {
                return Err(RelayError {
                    label: label.to_owned(),
                    code,
                    reason,
                }
                .into());
            }
        }
    }
}

/// A terminal error response from the relay, carried as a typed error so callers
/// can match on the `ERROR-CODE` (e.g. to recover from a 437).
#[derive(Debug)]
struct RelayError {
    label: String,
    code: u16,
    reason: String,
}

impl std::fmt::Display for RelayError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{} failed: {} {}", self.label, self.code, self.reason)
    }
}

impl std::error::Error for RelayError {}

/// Whether `error` carries a relay 437 (Allocation Mismatch) response.
fn is_allocation_mismatch(error: &anyhow::Error) -> bool {
    error
        .any_downcast_ref::<RelayError>()
        .is_some_and(|e| e.code == ALLOCATION_MISMATCH)
}

/// Classify a response as success, a stale-nonce retry, or a terminal error.
fn outcome(response: &Message<Attribute>) -> Result<Outcome> {
    if response.class() == MessageClass::SuccessResponse {
        return Ok(Outcome::Success);
    }

    let error = response
        .get_attribute::<ErrorCode>()
        .context("error response is missing ERROR-CODE")?;

    if error.code() == STALE_NONCE {
        let nonce = response
            .get_attribute::<Nonce>()
            .context("stale-nonce response is missing NONCE")?
            .clone();

        return Ok(Outcome::StaleNonce(nonce));
    }

    Ok(Outcome::Error {
        code: error.code(),
        reason: error.reason_phrase().to_owned(),
    })
}

fn allocate_request() -> Message<Attribute> {
    let mut message = Message::new(
        MessageClass::Request,
        ALLOCATE,
        TransactionId::new(random()),
    );
    message.add_attribute(RequestedTransport::new(UDP_TRANSPORT));

    message
}

fn authenticated_allocate(credentials: &Credentials) -> Message<Attribute> {
    let mut message = Message::new(
        MessageClass::Request,
        ALLOCATE,
        TransactionId::new(random()),
    );
    message.add_attribute(RequestedTransport::new(UDP_TRANSPORT));

    sign(message, credentials)
}

fn authenticated_channel_bind(
    credentials: &Credentials,
    channel: u16,
    peer: SocketAddr,
) -> Message<Attribute> {
    let mut message = Message::new(
        MessageClass::Request,
        CHANNEL_BIND,
        TransactionId::new(random()),
    );
    message.add_attribute(
        ChannelNumber::new(channel).expect("channel number is within the valid range"),
    );
    message.add_attribute(XorPeerAddress::new(peer));

    sign(message, credentials)
}

/// Build a signed `Refresh` request with a zero lifetime, which deletes the allocation.
fn authenticated_refresh(credentials: &Credentials) -> Message<Attribute> {
    let mut message = Message::new(MessageClass::Request, REFRESH, TransactionId::new(random()));
    message.add_attribute(Lifetime::from_u32(0));

    sign(message, credentials)
}

/// Add the long-term credential attributes and `MESSAGE-INTEGRITY` to a request.
fn sign(mut message: Message<Attribute>, credentials: &Credentials) -> Message<Attribute> {
    message.add_attribute(credentials.username.clone());
    message.add_attribute(credentials.realm.clone());
    message.add_attribute(credentials.nonce.clone());

    let integrity = MessageIntegrity::new_long_term_credential(
        &message,
        &credentials.username,
        &credentials.realm,
        &credentials.password,
    )
    .expect("message integrity computation never fails");

    message.add_attribute(integrity);

    message
}

fn encode(message: Message<Attribute>) -> Vec<u8> {
    MessageEncoder::<Attribute>::default()
        .encode_into_bytes(message)
        .expect("STUN encoding never fails")
}

fn decode(bytes: &[u8]) -> Result<Message<Attribute>> {
    MessageDecoder::<Attribute>::default()
        .decode_from_bytes(bytes)
        .map_err(|e| anyhow!("malformed STUN message: {e}"))?
        .map_err(|_broken| anyhow!("received a broken STUN message"))
}

stun_codec::define_attribute_enums!(
    Attribute,
    AttributeDecoder,
    AttributeEncoder,
    [
        RequestedTransport,
        ErrorCode,
        Nonce,
        Realm,
        Username,
        MessageIntegrity,
        XorMappedAddress,
        XorRelayAddress,
        XorPeerAddress,
        ChannelNumber,
        Lifetime,
        Software
    ]
);

// --- IO helpers --------------------------------------------------------------

/// Send a single STUN request and wait for the relay's response, retrying on timeout.
async fn request_response(
    socket: &PerfUdpSocket,
    server: SocketAddr,
    request: Message<Attribute>,
    pool: &BufferPool<BytesMut>,
    label: &str,
) -> Result<Message<Attribute>> {
    let bytes = encode(request);

    for attempt in 1..=MAX_REQUEST_ATTEMPTS {
        send_datagram(socket, server, &bytes, bytes.len(), pool)
            .await
            .with_context(|| format!("Failed to send {label} request"))?;

        match tokio::time::timeout(REQUEST_TIMEOUT, recv_response(socket, server)).await {
            Ok(result) => {
                let response = result?;
                return decode(&response)
                    .with_context(|| format!("Failed to decode {label} response"));
            }
            Err(_) => tracing::debug!(attempt, %label, "Request timed out; retrying"),
        }
    }

    bail!("{label} timed out after {MAX_REQUEST_ATTEMPTS} attempts")
}

/// Receive the next datagram originating from `server`, copied out of the socket buffer.
async fn recv_response(socket: &PerfUdpSocket, server: SocketAddr) -> Result<Vec<u8>> {
    loop {
        let mut datagrams = socket.recv_from().await?;

        while let Some(datagram) = datagrams.next() {
            if datagram.from == server {
                return Ok(datagram.packet.to_vec());
            }

            tracing::trace!(from = %datagram.from, "Ignoring datagram from unexpected source");
        }
    }
}

/// Send a single datagram (`segment_size == bytes.len()` for an unbatched send).
async fn send_datagram(
    socket: &PerfUdpSocket,
    dst: SocketAddr,
    bytes: &[u8],
    segment_size: usize,
    pool: &BufferPool<BytesMut>,
) -> Result<()> {
    let packet = pool.pull_initialised(bytes);

    socket
        .send(DatagramOut {
            src: None,
            dst,
            packet,
            segment_size,
            ecn: Ecn::NonEct,
        })
        .await
}

/// Bind a GSO-enabled UDP socket, enlarging its buffers on a best-effort basis.
fn bind_socket(addr: SocketAddr) -> Result<PerfUdpSocket> {
    let mut socket = socket_factory::udp(addr)?.into_perf()?;

    socket.set_buffer_sizes(
        socket_factory::SEND_BUFFER_SIZE,
        socket_factory::RECV_BUFFER_SIZE,
    );

    Ok(socket)
}

fn unspecified_addr(server: SocketAddr) -> SocketAddr {
    match server {
        SocketAddr::V4(_) => SocketAddr::new(IpAddr::V4(Ipv4Addr::UNSPECIFIED), 0),
        SocketAddr::V6(_) => SocketAddr::new(IpAddr::V6(Ipv6Addr::UNSPECIFIED), 0),
    }
}

fn latency_since(sent_nanos: u64) -> Option<Duration> {
    unix_nanos()
        .checked_sub(sent_nanos)
        .map(Duration::from_nanos)
}

fn unix_nanos() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos() as u64)
        .unwrap_or(0)
}

fn parse_payload_size(s: &str) -> Result<usize, String> {
    let size: usize = s
        .parse()
        .map_err(|e| format!("invalid payload size: {e}"))?;

    if size < TURN_HEADER_SIZE {
        return Err(format!(
            "payload size must be at least {TURN_HEADER_SIZE} bytes (sequence header)"
        ));
    }
    if size > MAX_TURN_PAYLOAD_SIZE {
        return Err(format!(
            "payload size exceeds the maximum of {MAX_TURN_PAYLOAD_SIZE} bytes"
        ));
    }

    Ok(size)
}

/// Summary of TURN relay load test results.
#[derive(Debug, Serialize)]
pub struct TurnTestSummary {
    pub test_type: &'static str,
    pub server: String,
    pub relayed_address: String,
    pub peer_address: String,
    pub channel: u16,
    pub payload_size: usize,
    pub target_bitrate_bps: u64,
    pub duration_secs: u64,
    pub packets_sent: u64,
    pub packets_received: u64,
    pub packets_lost: u64,
    pub loss_percent: f64,
    pub reordered: u64,
    pub bytes_sent: u64,
    pub bytes_received: u64,
    pub send_bitrate_bps: u64,
    pub recv_bitrate_bps: u64,
    pub min_latency_ms: Option<f64>,
    pub max_latency_ms: Option<f64>,
    pub avg_latency_ms: Option<f64>,
}

fn build_summary(
    config: &TestConfig,
    channel: u16,
    peer: SocketAddr,
    relayed: SocketAddr,
    send: SendStats,
    recv: RecvStats,
) -> TurnTestSummary {
    let packets_lost = send.packets_sent.saturating_sub(recv.packets_received);
    let loss_percent = if send.packets_sent > 0 {
        packets_lost as f64 / send.packets_sent as f64 * 100.0
    } else {
        0.0
    };

    let duration_secs = config.duration.as_secs();
    let elapsed = duration_secs.max(1); // Avoid dividing by zero for sub-second tests.
    let send_bitrate_bps = send.bytes_sent * 8 / elapsed;
    let recv_bitrate_bps = recv.bytes_received * 8 / elapsed;

    let has_errors = packets_lost > 0;
    crate::log_test_result!(
        has_errors,
        packets_sent = send.packets_sent,
        packets_received = recv.packets_received,
        packets_lost,
        loss_percent,
        "TURN relay load test complete"
    );

    TurnTestSummary {
        test_type: "turn",
        server: config.server.to_string(),
        relayed_address: relayed.to_string(),
        peer_address: peer.to_string(),
        channel,
        payload_size: config.payload_size,
        target_bitrate_bps: config.bitrate_bps,
        duration_secs,
        packets_sent: send.packets_sent,
        packets_received: recv.packets_received,
        packets_lost,
        loss_percent,
        reordered: recv.reordered,
        bytes_sent: send.bytes_sent,
        bytes_received: recv.bytes_received,
        send_bitrate_bps,
        recv_bitrate_bps,
        min_latency_ms: recv.latency.min().map(|d| d.as_secs_f64() * 1000.0),
        max_latency_ms: recv.latency.max().map(|d| d.as_secs_f64() * 1000.0),
        avg_latency_ms: recv.latency.avg().map(|d| d.as_secs_f64() * 1000.0),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn frame_round_trips_sequence_and_size() {
        let mut batch = Vec::new();
        write_frame(&mut batch, FIRST_CHANNEL, 42, 1280);

        // ChannelData header: channel number + payload length.
        assert_eq!(batch.len(), CHANNEL_DATA_HEADER_SIZE + 1280);
        assert_eq!(u16::from_be_bytes([batch[0], batch[1]]), FIRST_CHANNEL);
        assert_eq!(u16::from_be_bytes([batch[2], batch[3]]), 1280);

        // The peer sees only the payload; the relay strips the channel header.
        let payload = &batch[CHANNEL_DATA_HEADER_SIZE..];
        let (sequence, _sent_nanos) = parse_payload(payload).unwrap();
        assert_eq!(sequence, 42);
        assert_eq!(payload.len(), 1280);
    }

    #[test]
    fn parse_payload_rejects_short_input() {
        assert!(parse_payload(&[0u8; 8]).is_none());
    }

    fn test_base() -> TestConfig {
        TestConfig {
            server: "1.1.1.1:3478".parse().unwrap(),
            username: "config-user".to_owned(),
            password: "config-pass".to_owned(),
            payload_size: 1280,
            bitrate_bps: 1_000_000,
            duration: Duration::from_secs(30),
            max_loss_percent: None,
        }
    }

    fn empty_args() -> Args {
        Args {
            server: None,
            username: None,
            password: None,
            payload_size: None,
            bitrate: None,
            duration: None,
            max_loss: None,
            fetch_credentials: false,
            ipv4: false,
            ipv6: false,
            portal_url: "wss://api.firezone.dev".parse().unwrap(),
            token_path: PathBuf::from("token"),
        }
    }

    #[test]
    fn merge_fills_from_config_and_cli_overrides() {
        let args = Args {
            server: Some("2.2.2.2:3478".parse().unwrap()),
            bitrate: Some(5_000_000),
            ..empty_args()
        };

        let merged = build_config(args, Some(test_base()), None).unwrap();

        assert_eq!(merged.server, "2.2.2.2:3478".parse().unwrap()); // overridden by CLI
        assert_eq!(merged.bitrate_bps, 5_000_000); // overridden by CLI
        assert_eq!(merged.username, "config-user"); // filled from config
        assert_eq!(merged.payload_size, 1280); // filled from config
    }

    #[test]
    fn merge_requires_server_when_absent_everywhere() {
        let args = Args {
            username: Some("u".to_owned()),
            password: Some("p".to_owned()),
            bitrate: Some(1_000_000),
            ..empty_args()
        };

        assert!(build_config(args, None, None).is_err());
    }

    #[test]
    fn formats_transfer_and_bitrate_like_iperf3() {
        assert_eq!(format_bytes(1024 * 1024), "1.00 MBytes");
        assert_eq!(format_bytes(1536), "1.5 KBytes");
        assert_eq!(format_bitrate(2_000_000.0), "2.00 Mbits/sec");
        assert_eq!(format_bitrate(500_000.0), "500.0 Kbits/sec");
    }

    #[test]
    fn live_loss_does_not_count_in_flight_packets() {
        // Everything up to the highest received seq arrived: no loss, even though
        // higher-numbered packets are still in flight.
        assert_eq!(live_loss_percent(189, 190), 0.0);
        // 5 of the 200 sequences up to the highest are missing.
        assert_eq!(live_loss_percent(199, 195), 2.5);
        // Nothing received yet.
        assert_eq!(live_loss_percent(0, 0), 0.0);
    }

    fn test_credentials() -> Credentials {
        Credentials {
            username: Username::new("user".to_owned()).unwrap(),
            realm: Realm::new("firezone".to_owned()).unwrap(),
            nonce: Nonce::new("nonce".to_owned()).unwrap(),
            password: "pass".to_owned(),
        }
    }

    #[test]
    fn refresh_request_deletes_allocation_with_zero_lifetime() {
        let message = authenticated_refresh(&test_credentials());

        assert_eq!(message.method(), REFRESH);
        assert_eq!(message.class(), MessageClass::Request);
        assert!(
            message
                .get_attribute::<Lifetime>()
                .expect("refresh carries a LIFETIME")
                .lifetime()
                .is_zero()
        );
        // Signed with the long-term credential.
        assert!(message.get_attribute::<MessageIntegrity>().is_some());
    }

    #[test]
    fn detects_allocation_mismatch_error() {
        let relay_error = |code| {
            anyhow::Error::new(RelayError {
                label: "Allocate".to_owned(),
                code,
                reason: "reason".to_owned(),
            })
        };

        assert!(is_allocation_mismatch(&relay_error(ALLOCATION_MISMATCH)));
        assert!(!is_allocation_mismatch(&relay_error(STALE_NONCE)));
        // An unrelated error doesn't carry a `RelayError`.
        assert!(!is_allocation_mismatch(&anyhow!("connection reset")));
    }
}
