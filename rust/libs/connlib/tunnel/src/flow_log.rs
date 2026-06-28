//! Role-agnostic core of flow-log tracking shared by the Gateway and the Client.
//!
//! A [`Tracker`] turns a stream of packet observations into [`FlowLogRecord`]s. It
//! is generic over a "scope" `S` that identifies which authorization a flow belongs
//! to (e.g. a `(peer, resource)` pair); the scope plus the inner 4-tuple keys a
//! flow. The two reporting sides feed it the same way:
//!
//! - [`Tracker::record_tx`] for packets in the initiator-to-responder direction.
//!   This is where flows are created, split and TCP-closed.
//! - [`Tracker::record_rx`] for packets in the responder-to-initiator direction.
//!   This only updates the counters (and TCP-closes) of an already-open flow.
//!
//! "tx" / "rx" are defined from the *initiator's* perspective regardless of which
//! device observes the packet, so the initiator and responder label the same
//! direction identically. That is what makes the portal's two-sided cross-check of
//! byte / packet counts meaningful.
//!
//! Each device-and-role feeding layer (the Gateway's thread-local packet collector,
//! the Client's call sites) lives next to that device's packet processing and is
//! responsible only for extracting the fields below; the open/close/split/timeout
//! logic lives here once.

use std::{
    collections::{HashMap, VecDeque, hash_map},
    fmt::Debug,
    hash::Hash,
    net::{IpAddr, SocketAddr},
    time::Instant,
};

use base64::Engine as _;
use chrono::{DateTime, TimeDelta, Utc};
use dns_types::DomainName;
use ip_packet::Protocol;

/// A flow is closed if no packet is seen for this long.
const FLOW_TIMEOUT: TimeDelta = TimeDelta::minutes(2);

/// Tracks active flows for one device and turns them into [`FlowLogRecord`]s.
///
/// `S` is the per-authorization scope that, together with the inner 4-tuple,
/// identifies a flow (see the module docs).
#[derive(Debug)]
pub struct Tracker<S> {
    active_tcp_flows: HashMap<TcpFlowKey<S>, TcpFlowValue>,
    active_udp_flows: HashMap<UdpFlowKey<S>, UdpFlowValue>,

    flow_records: VecDeque<FlowLogRecord>,

    enabled: bool,
    created_at: Instant,
    created_at_utc: DateTime<Utc>,
}

/// One packet in the initiator-to-responder direction, already decoded into the
/// fields the tracker needs. Recording this creates / updates / splits a flow.
pub struct TxFlow<S> {
    pub scope: S,
    /// The outer (transport) 4-tuple this flow is tunneled over.
    pub context: FlowContext,
    pub src_ip: IpAddr,
    pub dst_ip: IpAddr,
    pub src_proto: Protocol,
    pub dst_proto: Protocol,
    pub tcp_syn: bool,
    pub tcp_fin: bool,
    pub tcp_rst: bool,
    pub payload_len: usize,
    pub ingest_token: Option<String>,
    pub domain: Option<DomainName>,
}

/// One packet in the responder-to-initiator direction. Recording this only updates
/// the counters of an already-open flow; the `src`/`dst` are in the packet's
/// natural orientation (responder-to-initiator) and are flipped to match the key.
pub struct RxFlow<S> {
    pub scope: S,
    pub src_ip: IpAddr,
    pub dst_ip: IpAddr,
    pub src_proto: Protocol,
    pub dst_proto: Protocol,
    pub tcp_fin: bool,
    pub tcp_rst: bool,
    pub payload_len: usize,
}

impl<S> Tracker<S>
where
    S: Copy + Eq + Hash + Debug,
{
    pub fn new(enabled: bool, now: Instant) -> Self {
        Self {
            active_tcp_flows: Default::default(),
            active_udp_flows: Default::default(),
            flow_records: Default::default(),
            enabled,
            created_at: now,
            created_at_utc: Utc::now(),
        }
    }

    pub fn enabled(&self) -> bool {
        self.enabled
    }

    /// Enables or disables flow tracking at runtime. When disabled, `record_tx` /
    /// `record_rx` are no-ops, so no records (and thus no spooled files) are emitted.
    pub fn set_enabled(&mut self, enabled: bool) {
        self.enabled = enabled;
    }

    pub fn poll_flow_record(&mut self) -> Option<FlowLogRecord> {
        self.flow_records.pop_front()
    }

    /// Pushes a close record for every currently-active flow, e.g. on shutdown.
    pub fn close_all(&mut self, now: Instant) {
        let now_utc = self.now_utc(now);

        for (key, value) in self.active_tcp_flows.drain() {
            self.flow_records
                .push_back(FlowLogRecord::tcp_close(key, value, now_utc));
        }
        for (key, value) in self.active_udp_flows.drain() {
            self.flow_records
                .push_back(FlowLogRecord::udp_close(key, value, now_utc));
        }
    }

    pub fn handle_timeout(&mut self, now: Instant) {
        let now_utc = self.now_utc(now);

        for (key, value) in self
            .active_tcp_flows
            .extract_if(|_, value| now_utc.signed_duration_since(value.last_packet) > FLOW_TIMEOUT)
        {
            tracing::debug!(?key, "Terminating TCP flow; timeout");

            self.flow_records
                .push_back(FlowLogRecord::tcp_close(key, value, now_utc));
        }

        for (key, value) in self
            .active_udp_flows
            .extract_if(|_, value| now_utc.signed_duration_since(value.last_packet) > FLOW_TIMEOUT)
        {
            tracing::debug!(?key, "Terminating UDP flow; timeout");

            self.flow_records
                .push_back(FlowLogRecord::udp_close(key, value, now_utc));
        }

        for (key, value) in self
            .active_tcp_flows
            .extract_if(|_, value| value.fin_rx && value.fin_tx)
        {
            let end = value.last_packet;

            tracing::debug!(?key, "Terminating TCP flow; FIN sent & received");

            self.flow_records
                .push_back(FlowLogRecord::tcp_close(key, value, end));
        }
    }

    /// Records a packet in the initiator-to-responder direction (see module docs).
    pub fn record_tx(&mut self, tx: TxFlow<S>, now: Instant) {
        if !self.enabled {
            return;
        }

        let now_utc = self.now_utc(now);
        let TxFlow {
            scope,
            context,
            src_ip,
            dst_ip,
            src_proto,
            dst_proto,
            tcp_syn,
            tcp_fin,
            tcp_rst,
            payload_len,
            ingest_token,
            domain,
        } = tx;

        match (src_proto, dst_proto) {
            (Protocol::Tcp(src_port), Protocol::Tcp(dst_port)) => {
                let key = TcpFlowKey {
                    scope,
                    src_ip,
                    dst_ip,
                    src_port,
                    dst_port,
                };

                match self.active_tcp_flows.entry(key) {
                    hash_map::Entry::Vacant(vacant) => {
                        if tcp_fin || tcp_rst {
                            // Don't create new flows for FIN/RST packets.
                            return;
                        }

                        tracing::debug!(key = ?vacant.key(), ?context, syn = %tcp_syn, "Creating new TCP flow");

                        let value = TcpFlowValue {
                            start: now_utc,
                            last_packet: now_utc,
                            stats: FlowStats::default().with_tx(payload_len as u64),
                            context,
                            fin_tx: false,
                            fin_rx: false,
                            domain,
                            ingest_token,
                        };

                        self.flow_records
                            .push_back(FlowLogRecord::tcp_open(&key, &value));

                        vacant.insert(value);
                    }
                    hash_map::Entry::Occupied(occupied) if occupied.get().context != context => {
                        let (key, value) = occupied.remove_entry();
                        let context_diff = FlowContextDiff::new(value.context, context);

                        tracing::debug!(
                            ?key,
                            ?context_diff,
                            "Splitting existing TCP flow; context changed"
                        );

                        self.flow_records
                            .push_back(FlowLogRecord::tcp_close(key, value, now_utc));

                        let value = TcpFlowValue {
                            start: now_utc,
                            last_packet: now_utc,
                            stats: FlowStats::default().with_tx(payload_len as u64),
                            context,
                            fin_tx: false,
                            fin_rx: false,
                            domain,
                            ingest_token,
                        };

                        self.flow_records
                            .push_back(FlowLogRecord::tcp_open(&key, &value));

                        self.active_tcp_flows.insert(key, value);
                    }
                    hash_map::Entry::Occupied(occupied) if tcp_syn => {
                        let (key, value) = occupied.remove_entry();

                        tracing::debug!(?key, "Splitting existing TCP flow; new TCP SYN");

                        self.flow_records
                            .push_back(FlowLogRecord::tcp_close(key, value, now_utc));

                        let value = TcpFlowValue {
                            start: now_utc,
                            last_packet: now_utc,
                            stats: FlowStats::default().with_tx(payload_len as u64),
                            context,
                            fin_tx: false,
                            fin_rx: false,
                            domain,
                            ingest_token,
                        };

                        self.flow_records
                            .push_back(FlowLogRecord::tcp_open(&key, &value));

                        self.active_tcp_flows.insert(key, value);
                    }
                    hash_map::Entry::Occupied(mut occupied) => {
                        let value = occupied.get_mut();

                        value.stats.inc_tx(payload_len as u64);
                        value.last_packet = now_utc;
                        if tcp_fin {
                            value.fin_tx = true;
                        }

                        if tcp_rst {
                            let (key, value) = occupied.remove_entry();

                            tracing::debug!(?key, "TCP flow completed on outbound RST");

                            self.flow_records
                                .push_back(FlowLogRecord::tcp_close(key, value, now_utc));
                        }
                    }
                };
            }
            (Protocol::Udp(src_port), Protocol::Udp(dst_port)) => {
                let key = UdpFlowKey {
                    scope,
                    src_ip,
                    dst_ip,
                    src_port,
                    dst_port,
                };

                match self.active_udp_flows.entry(key) {
                    hash_map::Entry::Vacant(vacant) => {
                        tracing::debug!(key = ?vacant.key(), "Creating new UDP flow");

                        let value = UdpFlowValue {
                            start: now_utc,
                            last_packet: now_utc,
                            stats: FlowStats::default().with_tx(payload_len as u64),
                            context,
                            domain,
                            ingest_token,
                        };

                        self.flow_records
                            .push_back(FlowLogRecord::udp_open(&key, &value));

                        vacant.insert(value);
                    }
                    hash_map::Entry::Occupied(occupied) if occupied.get().context != context => {
                        let (key, value) = occupied.remove_entry();
                        let context_diff = FlowContextDiff::new(value.context, context);

                        tracing::debug!(
                            ?key,
                            ?context_diff,
                            "Splitting existing UDP flow; context changed"
                        );

                        let ingest_token = value.ingest_token.clone();

                        self.flow_records
                            .push_back(FlowLogRecord::udp_close(key, value, now_utc));

                        let value = UdpFlowValue {
                            start: now_utc,
                            last_packet: now_utc,
                            stats: FlowStats::default().with_tx(payload_len as u64),
                            context,
                            domain,
                            ingest_token,
                        };

                        self.flow_records
                            .push_back(FlowLogRecord::udp_open(&key, &value));

                        self.active_udp_flows.insert(key, value);
                    }
                    hash_map::Entry::Occupied(mut occupied) => {
                        let value = occupied.get_mut();

                        value.stats.inc_tx(payload_len as u64);
                        value.last_packet = now_utc;
                    }
                };
            }
            (Protocol::IcmpEcho(_), Protocol::IcmpEcho(_)) => {}
            _ => {
                tracing::error!("src and dst protocol must be the same");
            }
        }
    }

    /// Records a packet in the responder-to-initiator direction (see module docs).
    pub fn record_rx(&mut self, rx: RxFlow<S>, now: Instant) {
        if !self.enabled {
            return;
        }

        let now_utc = self.now_utc(now);
        let RxFlow {
            scope,
            src_ip,
            dst_ip,
            src_proto,
            dst_proto,
            tcp_fin,
            tcp_rst,
            payload_len,
        } = rx;

        match (src_proto, dst_proto) {
            (Protocol::Tcp(src_port), Protocol::Tcp(dst_port)) => {
                // The packet is responder-to-initiator, so flip it to the key's
                // (initiator-src, responder-dst) orientation.
                let key = TcpFlowKey {
                    scope,
                    src_ip: dst_ip,
                    dst_ip: src_ip,
                    src_port: dst_port,
                    dst_port: src_port,
                };

                match self.active_tcp_flows.entry(key) {
                    hash_map::Entry::Vacant(vacant) => {
                        tracing::debug!(key = ?vacant.key(), "No existing TCP flow for inbound packet");
                    }
                    hash_map::Entry::Occupied(mut occupied) => {
                        let value = occupied.get_mut();
                        value.stats.inc_rx(payload_len as u64);
                        value.last_packet = now_utc;

                        if tcp_fin {
                            value.fin_rx = true;
                        }

                        if tcp_rst {
                            let (key, value) = occupied.remove_entry();

                            tracing::debug!(?key, "TCP flow completed on inbound RST");

                            self.flow_records
                                .push_back(FlowLogRecord::tcp_close(key, value, now_utc));
                        }
                    }
                };
            }
            (Protocol::Udp(src_port), Protocol::Udp(dst_port)) => {
                let key = UdpFlowKey {
                    scope,
                    src_ip: dst_ip,
                    dst_ip: src_ip,
                    src_port: dst_port,
                    dst_port: src_port,
                };

                match self.active_udp_flows.entry(key) {
                    hash_map::Entry::Vacant(vacant) => {
                        tracing::debug!(key = ?vacant.key(), "No existing UDP flow for inbound packet");
                    }
                    hash_map::Entry::Occupied(mut occupied) => {
                        let value = occupied.get_mut();
                        value.stats.inc_rx(payload_len as u64);
                        value.last_packet = now_utc;
                    }
                };
            }
            (Protocol::IcmpEcho(_), Protocol::IcmpEcho(_)) => {}
            _ => {
                tracing::error!("src and dst protocol must be the same");
            }
        }
    }

    fn now_utc(&self, now: Instant) -> DateTime<Utc> {
        self.created_at_utc + now.duration_since(self.created_at)
    }
}

/// The transport protocol of a flow, as reported to the ingest API.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FlowProtocol {
    Tcp,
    Udp,
}

impl FlowProtocol {
    pub fn as_str(self) -> &'static str {
        match self {
            FlowProtocol::Tcp => "tcp",
            FlowProtocol::Udp => "udp",
        }
    }
}

/// The closing half of a flow log, present only once the flow has ended.
///
/// Mirrors the portal's "close complete" invariant: either all of these are
/// reported together (a "completed" record) or none are (an "open" record).
#[derive(Debug)]
pub struct FlowClose {
    pub flow_end: DateTime<Utc>,
    pub last_packet: DateTime<Utc>,
    pub rx_packets: u64,
    pub tx_packets: u64,
    pub rx_bytes: u64,
    pub tx_bytes: u64,
}

/// A single flow log record, shaped like the portal's `/ingestion/flow_logs` body.
///
/// `ingest_token` is the portal's per-authorization attribution token (echoed to
/// the API and decodable for local observability via [`decode_attribution`]). The
/// remaining fields are the network data the data plane observes. `close` is `None`
/// for an "open" (started) record and `Some` once the flow has ended ("completed").
#[derive(Debug)]
pub struct FlowLogRecord {
    pub ingest_token: Option<String>,
    pub protocol: FlowProtocol,

    pub inner_src_ip: IpAddr,
    pub inner_src_port: u16,
    pub inner_dst_ip: IpAddr,
    pub inner_dst_port: u16,
    pub domain: Option<DomainName>,

    pub outer_src_ip: IpAddr,
    pub outer_src_port: u16,
    pub outer_dst_ip: IpAddr,
    pub outer_dst_port: u16,

    pub flow_start: DateTime<Utc>,
    pub close: Option<FlowClose>,
}

impl FlowLogRecord {
    fn tcp_open<S>(key: &TcpFlowKey<S>, value: &TcpFlowValue) -> Self {
        Self::new(
            FlowProtocol::Tcp,
            key.src_ip,
            key.src_port,
            key.dst_ip,
            key.dst_port,
            value.ingest_token.clone(),
            value.domain.clone(),
            value.context,
            value.start,
            None,
        )
    }

    fn tcp_close<S>(key: TcpFlowKey<S>, value: TcpFlowValue, end: DateTime<Utc>) -> Self {
        let close = FlowClose::from_stats(&value.stats, end, value.last_packet);

        Self::new(
            FlowProtocol::Tcp,
            key.src_ip,
            key.src_port,
            key.dst_ip,
            key.dst_port,
            value.ingest_token,
            value.domain,
            value.context,
            value.start,
            Some(close),
        )
    }

    fn udp_open<S>(key: &UdpFlowKey<S>, value: &UdpFlowValue) -> Self {
        Self::new(
            FlowProtocol::Udp,
            key.src_ip,
            key.src_port,
            key.dst_ip,
            key.dst_port,
            value.ingest_token.clone(),
            value.domain.clone(),
            value.context,
            value.start,
            None,
        )
    }

    fn udp_close<S>(key: UdpFlowKey<S>, value: UdpFlowValue, end: DateTime<Utc>) -> Self {
        let close = FlowClose::from_stats(&value.stats, end, value.last_packet);

        Self::new(
            FlowProtocol::Udp,
            key.src_ip,
            key.src_port,
            key.dst_ip,
            key.dst_port,
            value.ingest_token,
            value.domain,
            value.context,
            value.start,
            Some(close),
        )
    }

    #[allow(clippy::too_many_arguments)]
    fn new(
        protocol: FlowProtocol,
        inner_src_ip: IpAddr,
        inner_src_port: u16,
        inner_dst_ip: IpAddr,
        inner_dst_port: u16,
        ingest_token: Option<String>,
        domain: Option<DomainName>,
        context: FlowContext,
        flow_start: DateTime<Utc>,
        close: Option<FlowClose>,
    ) -> Self {
        Self {
            ingest_token,
            protocol,
            inner_src_ip,
            inner_src_port,
            inner_dst_ip,
            inner_dst_port,
            domain,
            outer_src_ip: context.src_ip,
            outer_src_port: context.src_port,
            outer_dst_ip: context.dst_ip,
            outer_dst_port: context.dst_port,
            flow_start,
            close,
        }
    }
}

impl FlowClose {
    fn from_stats(stats: &FlowStats, end: DateTime<Utc>, last_packet: DateTime<Utc>) -> Self {
        Self {
            flow_end: end,
            last_packet,
            rx_packets: stats.rx_packets,
            tx_packets: stats.tx_packets,
            rx_bytes: stats.rx_bytes,
            tx_bytes: stats.tx_bytes,
        }
    }
}

/// The attribution claims carried inside an ingest token's base64url JSON payload.
///
/// The token signature is not verified here (the data plane lacks the account
/// signing key); the JWT payload is decoded purely to enrich local flow-log
/// observability. The token bookkeeping claims (`account_id`, `iat`, `exp`) are
/// intentionally omitted.
#[derive(Debug, Default, serde::Deserialize)]
pub struct Attribution {
    pub role: Option<String>,
    pub device_id: Option<String>,
    pub policy_authorization_id: Option<String>,
    pub policy_id: Option<String>,
    pub resource_id: Option<String>,
    pub resource_name: Option<String>,
    pub resource_address: Option<String>,
    pub actor_id: Option<String>,
    pub actor_email: Option<String>,
    pub actor_name: Option<String>,
    pub auth_provider_id: Option<String>,
    pub authorized_at: Option<String>,
    pub authorization_expires_at: Option<String>,
    pub client_version: Option<String>,
    pub device_os_name: Option<String>,
    pub device_os_version: Option<String>,
    pub device_serial: Option<String>,
    pub device_uuid: Option<String>,
    pub device_identifier_for_vendor: Option<String>,
    pub device_firebase_installation_id: Option<String>,
}

/// Emits a flow log record as a structured tracing event for local observability.
///
/// The record's `ingest_token` is base64url-decoded (without signature verification)
/// to recover the attribution. Open vs. completed is conveyed by the `state` field
/// and the presence of the close fields.
pub fn emit(record: &FlowLogRecord) {
    let attr = record
        .ingest_token
        .as_deref()
        .and_then(decode_attribution)
        .unwrap_or_default();

    let close = record.close.as_ref();
    let state = if close.is_some() {
        "completed"
    } else {
        "started"
    };

    macro_rules! emit {
        ($target:literal) => {
            tracing::trace!(
                target: $target,
                state,
                protocol = record.protocol.as_str(),

                role = attr.role.as_deref(),
                device_id = attr.device_id.as_deref(),
                policy_authorization_id = attr.policy_authorization_id.as_deref(),
                policy_id = attr.policy_id.as_deref(),

                resource_id = attr.resource_id.as_deref(),
                resource_name = attr.resource_name.as_deref(),
                resource_address = attr.resource_address.as_deref(),

                actor_id = attr.actor_id.as_deref(),
                actor_email = attr.actor_email.as_deref(),
                actor_name = attr.actor_name.as_deref(),
                auth_provider_id = attr.auth_provider_id.as_deref(),

                authorized_at = attr.authorized_at.as_deref(),
                authorization_expires_at = attr.authorization_expires_at.as_deref(),

                client_version = attr.client_version.as_deref(),
                device_os_name = attr.device_os_name.as_deref(),
                device_os_version = attr.device_os_version.as_deref(),
                device_serial = attr.device_serial.as_deref(),
                device_uuid = attr.device_uuid.as_deref(),
                device_identifier_for_vendor = attr.device_identifier_for_vendor.as_deref(),
                device_firebase_installation_id = attr.device_firebase_installation_id.as_deref(),

                inner_src_ip = %record.inner_src_ip,
                inner_src_port = %record.inner_src_port,
                inner_dst_ip = %record.inner_dst_ip,
                inner_dst_port = %record.inner_dst_port,
                inner_domain = record.domain.as_ref().map(tracing::field::display),

                outer_src_ip = %record.outer_src_ip,
                outer_src_port = %record.outer_src_port,
                outer_dst_ip = %record.outer_dst_ip,
                outer_dst_port = %record.outer_dst_port,

                flow_start = ?record.flow_start,
                flow_end = close.map(|c| tracing::field::debug(c.flow_end)),
                last_packet = close.map(|c| tracing::field::debug(c.last_packet)),
                rx_packets = close.map(|c| c.rx_packets),
                tx_packets = close.map(|c| c.tx_packets),
                rx_bytes = close.map(|c| c.rx_bytes),
                tx_bytes = close.map(|c| c.tx_bytes),
                "Flow log"
            )
        };
    }

    match record.protocol {
        FlowProtocol::Tcp => emit!("flow_logs::tcp"),
        FlowProtocol::Udp => emit!("flow_logs::udp"),
    }
}

/// Decodes the attribution claims of an ingest token without verifying its signature.
///
/// The token is an HS256 JWT (`base64url(header).base64url(payload).base64url(sig)`);
/// only the (portal-trusted) payload segment is read.
pub fn decode_attribution(token: &str) -> Option<Attribution> {
    let payload = token.split('.').nth(1)?;
    let json = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(payload)
        .ok()?;

    serde_json::from_slice(&json).ok()
}

#[derive(Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Clone, Copy)]
struct TcpFlowKey<S> {
    scope: S,
    src_ip: IpAddr,
    dst_ip: IpAddr,
    src_port: u16,
    dst_port: u16,
}

#[derive(Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Clone, Copy)]
struct UdpFlowKey<S> {
    scope: S,
    src_ip: IpAddr,
    dst_ip: IpAddr,
    src_port: u16,
    dst_port: u16,
}

#[derive(Debug)]
struct TcpFlowValue {
    start: DateTime<Utc>,
    last_packet: DateTime<Utc>,
    stats: FlowStats,
    context: FlowContext,

    domain: Option<DomainName>,

    /// The portal's per-authorization ingest token (carries the attribution).
    ingest_token: Option<String>,

    fin_tx: bool,
    fin_rx: bool,
}

#[derive(Debug)]
struct UdpFlowValue {
    start: DateTime<Utc>,
    last_packet: DateTime<Utc>,
    stats: FlowStats,
    context: FlowContext,

    domain: Option<DomainName>,

    /// The portal's per-authorization ingest token (carries the attribution).
    ingest_token: Option<String>,
}

#[derive(Debug, Default, Clone, Copy)]
struct FlowStats {
    rx_packets: u64,
    tx_packets: u64,
    rx_bytes: u64,
    tx_bytes: u64,
}

impl FlowStats {
    fn with_tx(mut self, payload_len: u64) -> Self {
        self.inc_tx(payload_len);

        self
    }

    fn inc_tx(&mut self, payload_len: u64) {
        self.tx_packets += 1;
        self.tx_bytes += payload_len;
    }

    fn inc_rx(&mut self, payload_len: u64) {
        self.rx_packets += 1;
        self.rx_bytes += payload_len;
    }
}

/// The outer (transport) 4-tuple a flow is tunneled over.
#[derive(Debug, PartialEq, Eq, Clone, Copy)]
pub struct FlowContext {
    pub src_ip: IpAddr,
    pub dst_ip: IpAddr,
    pub src_port: u16,
    pub dst_port: u16,
}

impl FlowContext {
    /// Builds a context from the outer addresses as seen by the initiator: the
    /// initiator side is the source, the responder side the destination.
    pub fn new(initiator: SocketAddr, responder: SocketAddr) -> Self {
        Self {
            src_ip: initiator.ip(),
            dst_ip: responder.ip(),
            src_port: initiator.port(),
            dst_port: responder.port(),
        }
    }
}

#[derive(PartialEq, Eq)]
struct FlowContextDiff {
    src_ip: Option<(IpAddr, IpAddr)>,
    dst_ip: Option<(IpAddr, IpAddr)>,
    src_port: Option<(u16, u16)>,
    dst_port: Option<(u16, u16)>,
}

impl FlowContextDiff {
    fn new(old: FlowContext, new: FlowContext) -> Self {
        let src_ip_diff = (old.src_ip != new.src_ip).then_some((old.src_ip, new.src_ip));
        let dst_ip_diff = (old.dst_ip != new.dst_ip).then_some((old.dst_ip, new.dst_ip));
        let src_port_diff = (old.src_port != new.src_port).then_some((old.src_port, new.src_port));
        let dst_port_diff = (old.dst_port != new.dst_port).then_some((old.dst_port, new.dst_port));

        Self {
            src_ip: src_ip_diff,
            dst_ip: dst_ip_diff,
            src_port: src_port_diff,
            dst_port: dst_port_diff,
        }
    }
}

impl std::fmt::Debug for FlowContextDiff {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let mut debug_struct = f.debug_struct("FlowContextDiff");

        if let Some((old, new)) = self.src_ip {
            debug_struct
                .field("old_src_ip", &old)
                .field("new_src_ip", &new);
        }
        if let Some((old, new)) = self.dst_ip {
            debug_struct
                .field("old_dst_ip", &old)
                .field("new_dst_ip", &new);
        }
        if let Some((old, new)) = self.src_port {
            debug_struct
                .field("old_src_port", &old)
                .field("new_src_port", &new);
        }
        if let Some((old, new)) = self.dst_port {
            debug_struct
                .field("old_dst_port", &old)
                .field("new_dst_port", &new);
        }

        debug_struct.finish()
    }
}

#[cfg(test)]
mod tests {
    use std::net::Ipv4Addr;

    use super::*;

    #[test]
    fn flow_context_diff_rendering() {
        let old = FlowContext {
            src_ip: IpAddr::V4(Ipv4Addr::new(10, 0, 0, 1)),
            dst_ip: IpAddr::V4(Ipv4Addr::new(192, 168, 0, 1)),
            src_port: 8080,
            dst_port: 443,
        };
        let new = FlowContext {
            src_ip: IpAddr::V4(Ipv4Addr::new(1, 1, 1, 1)),
            dst_ip: IpAddr::V4(Ipv4Addr::new(192, 168, 0, 1)),
            src_port: 50000,
            dst_port: 443,
        };

        let diff = FlowContextDiff::new(old, new);

        assert_eq!(
            "FlowContextDiff { old_src_ip: 10.0.0.1, new_src_ip: 1.1.1.1, old_src_port: 8080, new_src_port: 50000 }",
            format!("{diff:?}")
        );
    }

    #[test]
    fn decode_attribution_reads_jwt_payload_segment() {
        // An HS256 JWT is `header.payload.signature`; attribution is the middle
        // segment, and the (untrusted) signature is never inspected.
        let payload = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(
            r#"{"policy_authorization_id":"pa-1","actor_email":"a@b.c","role":"responder"}"#,
        );
        let token = format!("ignored-header.{payload}.ignored-signature");

        let attr = decode_attribution(&token).expect("decodes attribution");

        assert_eq!(attr.policy_authorization_id.as_deref(), Some("pa-1"));
        assert_eq!(attr.actor_email.as_deref(), Some("a@b.c"));
        assert_eq!(attr.role.as_deref(), Some("responder"));
        assert!(attr.resource_id.is_none());
    }
}
