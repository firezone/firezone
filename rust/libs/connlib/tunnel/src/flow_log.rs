//! Flow-log tracking shared by the Gateway and the Client.
//!
//! A [`Tracker`] turns a stream of packet observations into [`Record`]s, each of
//! which is emitted as a structured tracing event (target `flow_logs`). The tracker is generic over a [`Scope`] `S` that identifies
//! which authorization a flow belongs to; the scope plus the inner 4-tuple keys a
//! flow. Packets are recorded in one of two directions:
//!
//! - "tx" for packets in the initiator-to-responder direction.
//!   This is where flows are created, split and TCP-closed.
//! - "rx" for packets in the responder-to-initiator direction.
//!   This only updates the counters (and TCP-closes) of an already-open flow.
//!
//! "tx" / "rx" are defined from the *initiator's* perspective regardless of which
//! device observes the packet, so the initiator and responder label the same
//! direction identically.
//!
//! Processing a packet begins with [`Tracker::begin_tun_packet`] /
//! [`Tracker::begin_network_packet`], which stores a [`FlowData`] in a
//! thread-local that the call sites processing the packet fill in via the
//! `record_*` functions. Dropping the returned [`CurrentFlowGuard`] commits the
//! gathered data, no matter which exit path the processing takes.

use std::{
    cell::RefCell,
    collections::{HashMap, hash_map},
    fmt::Debug,
    hash::Hash,
    net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr},
    time::{Duration, Instant},
};

use base64::Engine as _;
use chrono::{DateTime, TimeDelta, Utc};
use connlib_model::{ClientId, ClientOrGatewayId, ResourceId};
use dns_types::DomainName;
use ip_packet::{IcmpError, IpPacket, Protocol, UnsupportedProtocol};

/// A flow is closed if no packet is seen for this long.
const FLOW_TIMEOUT: TimeDelta = TimeDelta::minutes(2);

pub use crate::messages::IngestToken;

impl IngestToken {
    /// Decodes the attribution claims of the token without verifying its
    /// signature, purely for local observability.
    pub fn attribution(&self) -> Option<Attribution> {
        let payload = self.as_str().split('.').nth(1)?;
        let json = base64::engine::general_purpose::URL_SAFE_NO_PAD
            .decode(payload)
            .ok()?;

        serde_json::from_slice(&json).ok()
    }
}

thread_local! {
    /// The [`FlowData`] for the packet currently being processed on this thread.
    static CURRENT_FLOW: RefCell<Option<FlowData>> = const { RefCell::new(None) };
}

/// Identifies which authorization a flow belongs to on one device.
///
/// A scope is assembled from the facts gathered while processing a packet; the
/// scope plus the inner 4-tuple keys a flow.
pub trait Scope: Copy + Eq + Hash + Debug {
    fn from_flow(peer: ClientOrGatewayId, resource: Option<ResourceId>) -> Option<Self>;
}

/// The Client scopes its flows by the peer they are tunneled through.
impl Scope for ClientOrGatewayId {
    fn from_flow(peer: ClientOrGatewayId, _: Option<ResourceId>) -> Option<Self> {
        Some(peer)
    }
}

/// The Gateway scopes its flows by the client and the resource it accesses.
impl Scope for (ClientId, ResourceId) {
    fn from_flow(peer: ClientOrGatewayId, resource: Option<ResourceId>) -> Option<Self> {
        match peer {
            ClientOrGatewayId::Client(cid) => Some((cid, resource?)),
            ClientOrGatewayId::Gateway(_) => None,
        }
    }
}

/// Tracks active flows for one device and turns them into [`Record`]s.
///
/// `S` is the per-authorization scope that, together with the inner 4-tuple,
/// identifies a flow (see the module docs).
#[derive(Debug)]
pub struct Tracker<S> {
    active_tcp_flows: HashMap<TcpFlowKey<S>, TcpFlowValue>,
    active_udp_flows: HashMap<UdpFlowKey<S>, UdpFlowValue>,

    enabled: bool,
    created_at: Instant,
    created_at_utc: DateTime<Utc>,
}

/// One packet in the initiator-to-responder direction.
///
/// Recording this creates, updates or splits a flow.
struct TxFlow<S> {
    scope: S,
    /// The outer (transport) 4-tuple this flow is tunneled over.
    context: FlowContext,
    src_ip: IpAddr,
    dst_ip: IpAddr,
    src_proto: Protocol,
    dst_proto: Protocol,
    tcp_syn: bool,
    tcp_fin: bool,
    tcp_rst: bool,
    payload_len: usize,
    ingest_token: Option<IngestToken>,
    domain: Option<DomainName>,
}

/// One packet in the responder-to-initiator direction.
///
/// Recording this only updates the counters of an already-open flow; `src` /
/// `dst` are in the packet's natural orientation and are flipped to match the key.
struct RxFlow<S> {
    scope: S,
    src_ip: IpAddr,
    dst_ip: IpAddr,
    src_proto: Protocol,
    dst_proto: Protocol,
    tcp_fin: bool,
    tcp_rst: bool,
    payload_len: usize,
}

impl<S> Tracker<S> {
    /// Creates a new tracker; it starts disabled.
    pub fn new(now: Instant, unix_ts: Duration) -> Self {
        let created_at_utc = i64::try_from(unix_ts.as_secs())
            .ok()
            .and_then(|secs| DateTime::from_timestamp(secs, unix_ts.subsec_nanos()))
            .unwrap_or(DateTime::UNIX_EPOCH);

        Self {
            active_tcp_flows: Default::default(),
            active_udp_flows: Default::default(),
            enabled: false,
            created_at: now,
            created_at_utc,
        }
    }

    /// Enables or disables flow tracking at runtime.
    ///
    /// When disabled, no flow data is gathered and no records are emitted.
    pub fn set_enabled(&mut self, enabled: bool) {
        self.enabled = enabled;
    }
}

impl<S> Tracker<S>
where
    S: Scope,
{
    /// Begins gathering flow data for one packet read from the TUN device.
    pub fn begin_tun_packet(&mut self, packet: &IpPacket, now: Instant) -> CurrentFlowGuard<'_, S> {
        if self.enabled {
            set_current_flow(FlowData::new(Entry::Tun, Some(InnerFlow::from(packet))));
        }

        CurrentFlowGuard { tracker: self, now }
    }

    /// Begins gathering flow data for one packet received on the network interface.
    pub fn begin_network_packet(
        &mut self,
        local: SocketAddr,
        remote: SocketAddr,
        now: Instant,
    ) -> CurrentFlowGuard<'_, S> {
        if self.enabled {
            set_current_flow(FlowData::new(Entry::Network { local, remote }, None));
        }

        CurrentFlowGuard { tracker: self, now }
    }

    fn commit(&mut self, data: FlowData, now: Instant) {
        let FlowData {
            entry,
            inner:
                Some(InnerFlow {
                    src_ip,
                    dst_ip,
                    src_proto: Ok(src_proto),
                    dst_proto: Ok(dst_proto),
                    tcp_syn,
                    tcp_fin,
                    tcp_rst,
                    payload_len,
                }),
            outer_tx,
            peer: Some((peer, role)),
            resource,
            ingest_token,
            domain,
            icmp_error: _, // TODO: What to do with ICMP errors?
        } = data
        else {
            tracing::trace!(?data, "Cannot create flow with missing data");

            return;
        };

        let Some(scope) = S::from_flow(peer, resource) else {
            tracing::trace!(%peer, ?resource, "Cannot assemble flow scope");

            return;
        };

        match (entry, role) {
            // The initiator observes the tx direction on its TUN device; count the
            // packet only once it was actually encapsulated and handed to the
            // network (packets buffered during connection setup are recorded by
            // the responder once they arrive).
            (Entry::Tun, Role::Initiator) => {
                let Some(context) = outer_tx else {
                    tracing::trace!("Not recording flow for packet that was never sent");

                    return;
                };

                self.record_tx(
                    TxFlow {
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
                    },
                    now,
                );
            }
            // The responder observes the tx direction arriving over the network.
            (Entry::Network { local, remote }, Role::Responder) => {
                self.record_tx(
                    TxFlow {
                        scope,
                        context: FlowContext::new(remote, local),
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
                    },
                    now,
                );
            }
            // The responder observes the rx direction on its TUN device; same
            // send-gate as above.
            (Entry::Tun, Role::Responder) => {
                if outer_tx.is_none() {
                    tracing::trace!("Not recording flow for packet that was never sent");

                    return;
                }

                self.record_rx(
                    RxFlow {
                        scope,
                        src_ip,
                        dst_ip,
                        src_proto,
                        dst_proto,
                        tcp_fin,
                        tcp_rst,
                        payload_len,
                    },
                    now,
                );
            }
            // The initiator observes the rx direction arriving over the network.
            (Entry::Network { .. }, Role::Initiator) => {
                self.record_rx(
                    RxFlow {
                        scope,
                        src_ip,
                        dst_ip,
                        src_proto,
                        dst_proto,
                        tcp_fin,
                        tcp_rst,
                        payload_len,
                    },
                    now,
                );
            }
        }
    }

    /// Pushes a close record for every currently-active flow, e.g. on shutdown.
    pub fn close_all(&mut self, now: Instant) {
        let now_utc = self.now_utc(now);

        for (key, value) in self.active_tcp_flows.drain() {
            emit(&Record::tcp_close(key, value, now_utc));
        }
        for (key, value) in self.active_udp_flows.drain() {
            emit(&Record::udp_close(key, value, now_utc));
        }
    }

    pub fn handle_timeout(&mut self, now: Instant) {
        let now_utc = self.now_utc(now);

        for (key, value) in self
            .active_tcp_flows
            .extract_if(|_, value| now_utc.signed_duration_since(value.last_packet) > FLOW_TIMEOUT)
        {
            tracing::debug!(?key, "Terminating TCP flow; timeout");

            emit(&Record::tcp_close(key, value, now_utc));
        }

        for (key, value) in self
            .active_udp_flows
            .extract_if(|_, value| now_utc.signed_duration_since(value.last_packet) > FLOW_TIMEOUT)
        {
            tracing::debug!(?key, "Terminating UDP flow; timeout");

            emit(&Record::udp_close(key, value, now_utc));
        }

        for (key, value) in self
            .active_tcp_flows
            .extract_if(|_, value| value.fin_rx && value.fin_tx)
        {
            let end = value.last_packet;

            tracing::debug!(?key, "Terminating TCP flow; FIN sent & received");

            emit(&Record::tcp_close(key, value, end));
        }
    }

    /// Records a packet in the initiator-to-responder direction (see module docs).
    fn record_tx(&mut self, tx: TxFlow<S>, now: Instant) {
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

        // The portal mints an ingest token only for authorizations it wants
        // flow logs for: without one, the flow is neither logged nor spooled.
        // The rx direction only updates flows created here, so it is gated too.
        if ingest_token.is_none() {
            tracing::trace!("Authorization has no ingest token; not tracking flow");

            return;
        }

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

                        emit(&Record::tcp_open(&key, &value));

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

                        emit(&Record::tcp_close(key, value, now_utc));

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

                        emit(&Record::tcp_open(&key, &value));

                        self.active_tcp_flows.insert(key, value);
                    }
                    hash_map::Entry::Occupied(occupied) if tcp_syn => {
                        let (key, value) = occupied.remove_entry();

                        tracing::debug!(?key, "Splitting existing TCP flow; new TCP SYN");

                        emit(&Record::tcp_close(key, value, now_utc));

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

                        emit(&Record::tcp_open(&key, &value));

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

                            emit(&Record::tcp_close(key, value, now_utc));
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

                        emit(&Record::udp_open(&key, &value));

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

                        emit(&Record::udp_close(key, value, now_utc));

                        let value = UdpFlowValue {
                            start: now_utc,
                            last_packet: now_utc,
                            stats: FlowStats::default().with_tx(payload_len as u64),
                            context,
                            domain,
                            ingest_token,
                        };

                        emit(&Record::udp_open(&key, &value));

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
    fn record_rx(&mut self, rx: RxFlow<S>, now: Instant) {
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

                            emit(&Record::tcp_close(key, value, now_utc));
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

/// Guards the [`FlowData`] of the packet currently being processed.
///
/// Dropping the guard commits the gathered data to the tracker; data that is
/// still incomplete (e.g. because packet processing bailed early or the packet
/// was internal traffic) is discarded. Holding a mutable borrow of the tracker
/// also ensures at most one flow can be gathered at a time.
#[must_use]
pub struct CurrentFlowGuard<'a, S: Scope> {
    tracker: &'a mut Tracker<S>,
    now: Instant,
}

impl<S: Scope> Drop for CurrentFlowGuard<'_, S> {
    fn drop(&mut self) {
        let Some(data) = CURRENT_FLOW.take() else {
            return;
        };

        self.tracker.commit(data, self.now);
    }
}

/// This device's role in the flow a packet belongs to.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Role {
    /// We initiated the flow, i.e. we requested access to the peer / resource.
    Initiator,
    /// The remote peer initiated the flow towards us.
    Responder,
}

/// How the packet currently being processed entered this device.
#[derive(Debug, Clone, Copy)]
enum Entry {
    /// Read from the TUN device; it will leave via the network if routable.
    Tun,
    /// Received on the network interface `local` from `remote`.
    Network {
        local: SocketAddr,
        remote: SocketAddr,
    },
}

/// The facts gathered about one packet while it is being processed.
///
/// Which of these can be filled in depends on the entry point and this device's
/// role; [`Tracker::commit`] interprets them (see the module docs).
#[derive(Debug)]
struct FlowData {
    entry: Entry,
    /// The inner (application) packet's flow fields.
    inner: Option<InnerFlow>,
    /// The outer (transport) 4-tuple a TUN-entry packet was encapsulated to,
    /// oriented initiator-to-responder. Absence means the packet was never sent.
    outer_tx: Option<FlowContext>,
    /// The peer the packet is tunneled through and our role in the flow.
    peer: Option<(ClientOrGatewayId, Role)>,
    resource: Option<ResourceId>,
    /// The portal's per-authorization ingest token (carries the attribution).
    ingest_token: Option<IngestToken>,
    /// The domain name in case this packet is for a DNS resource.
    domain: Option<DomainName>,
    icmp_error: Option<IcmpError>,
}

impl FlowData {
    fn new(entry: Entry, inner: Option<InnerFlow>) -> Self {
        Self {
            entry,
            inner,
            outer_tx: None,
            peer: None,
            resource: None,
            ingest_token: None,
            domain: None,
            icmp_error: None,
        }
    }
}

fn set_current_flow(data: FlowData) {
    let current = CURRENT_FLOW.replace(Some(data));

    debug_assert!(
        current.is_none(),
        "at most 1 flow should be active at any time"
    );
}

fn update_current_flow(f: impl FnOnce(&mut FlowData)) {
    CURRENT_FLOW.with_borrow_mut(|c| {
        let Some(data) = c else {
            return;
        };

        f(data);
    });
}

/// Records the peer the current packet is tunneled through and our role in the
/// flow it belongs to.
pub fn record_peer(peer: impl Into<ClientOrGatewayId>, role: Role) {
    let peer = peer.into();

    update_current_flow(|data| {
        data.peer = Some((peer, role));
    });
}

/// Records the resource the current packet accesses.
pub fn record_resource(resource: ResourceId) {
    update_current_flow(|data| {
        data.resource = Some(resource);
    });
}

/// Records the ingest token attributing the current packet's flow.
pub fn record_ingest_token(token: Option<IngestToken>) {
    update_current_flow(|data| {
        data.ingest_token = token;
    });
}

/// Records the domain name in case the current packet is for a DNS resource.
pub fn record_domain(domain: DomainName) {
    update_current_flow(|data| {
        data.domain = Some(domain);
    });
}

/// Records the inner packet decrypted from a network-entry packet.
pub fn record_decrypted_packet(packet: &IpPacket) {
    update_current_flow(|data| {
        data.inner = Some(InnerFlow::from(packet));
    });
}

/// Records the current packet's fields again after NAT rewrote it.
pub fn record_translated_packet(packet: &IpPacket) {
    update_current_flow(|data| {
        let Some(inner) = data.inner.as_mut() else {
            return;
        };

        inner.dst_ip = packet.destination();
        inner.src_proto = packet.source_protocol();
    });
}

/// Records that the current packet was encapsulated and sent from `src` to `dst`.
pub fn record_transmit(src: Option<SocketAddr>, dst: SocketAddr) {
    update_current_flow(|data| {
        let src = src.unwrap_or_else(|| unspecified_socket_like(dst));

        data.outer_tx = Some(FlowContext::new(src, dst));
    });
}

/// Records the ICMP error contained in the current packet, if any.
pub fn record_icmp_error(packet: &IpPacket) {
    let Ok(Some((_, icmp_error))) = packet.icmp_error() else {
        return;
    };

    update_current_flow(|data| {
        data.icmp_error = Some(icmp_error);
    });
}

/// The local address is unknown when the socket layer has not bound one yet
/// (e.g. a relayed transmit).
fn unspecified_socket_like(addr: SocketAddr) -> SocketAddr {
    match addr {
        SocketAddr::V4(_) => SocketAddr::new(Ipv4Addr::UNSPECIFIED.into(), 0),
        SocketAddr::V6(_) => SocketAddr::new(Ipv6Addr::UNSPECIFIED.into(), 0),
    }
}

/// The flow-relevant fields of one inner (application) IP packet, in the packet's
/// natural orientation.
#[derive(Debug)]
struct InnerFlow {
    src_ip: IpAddr,
    dst_ip: IpAddr,
    src_proto: Result<Protocol, UnsupportedProtocol>,
    dst_proto: Result<Protocol, UnsupportedProtocol>,

    tcp_syn: bool,
    tcp_fin: bool,
    tcp_rst: bool,

    payload_len: usize,
}

impl From<&IpPacket> for InnerFlow {
    fn from(packet: &IpPacket) -> Self {
        InnerFlow {
            src_ip: packet.source(),
            dst_ip: packet.destination(),
            src_proto: packet.source_protocol(),
            dst_proto: packet.destination_protocol(),
            tcp_syn: packet.as_tcp().map(|tcp| tcp.syn()).unwrap_or(false),
            tcp_fin: packet.as_tcp().map(|tcp| tcp.fin()).unwrap_or(false),
            tcp_rst: packet.as_tcp().map(|tcp| tcp.rst()).unwrap_or(false),
            payload_len: packet.layer4_payload_len(),
        }
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
/// Attribution lives in the per-authorization `ingest_token`; `close` is `None`
/// for an open record and `Some` once the flow has ended.
#[derive(Debug)]
pub struct Record {
    pub ingest_token: Option<IngestToken>,
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

impl Record {
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
        ingest_token: Option<IngestToken>,
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

/// The attribution claims carried in an ingest token's JWT payload.
///
/// Decoded without signature verification, purely for local observability.
/// The portal guarantees the non-optional claims on every token it mints; a
/// token missing any of them fails to decode and attributes nothing.
#[derive(Debug, serde::Deserialize)]
pub struct Attribution {
    pub role: String,
    pub device_id: String,
    pub policy_authorization_id: String,
    pub policy_id: String,
    pub resource_id: String,
    pub resource_name: String,
    pub resource_address: Option<String>,
    pub actor_id: String,
    pub actor_email: Option<String>,
    pub actor_name: String,
    pub auth_provider_id: Option<String>,
    pub authorized_at: String,
    pub authorization_expires_at: String,
    pub client_version: String,
    pub device_os_name: Option<String>,
    pub device_os_version: Option<String>,
    pub device_serial: Option<String>,
    pub device_uuid: Option<String>,
    pub device_identifier_for_vendor: Option<String>,
    pub device_firebase_installation_id: Option<String>,
}

/// Emits a flow log record as a structured tracing event.
///
/// The token's attribution claims are included; the token itself is not.
pub fn emit(record: &Record) {
    let attr = record
        .ingest_token
        .as_ref()
        .and_then(IngestToken::attribution);
    let attr = attr.as_ref();

    let close = record.close.as_ref();

    macro_rules! emit {
        ($message:literal) => {
            tracing::trace!(
                target: "flow_logs",
                protocol = record.protocol.as_str(),

                role = attr.map(|a| a.role.as_str()),
                device_id = attr.map(|a| a.device_id.as_str()),
                policy_authorization_id = attr.map(|a| a.policy_authorization_id.as_str()),
                policy_id = attr.map(|a| a.policy_id.as_str()),

                resource_id = attr.map(|a| a.resource_id.as_str()),
                resource_name = attr.map(|a| a.resource_name.as_str()),
                resource_address = attr.and_then(|a| a.resource_address.as_deref()),

                actor_id = attr.map(|a| a.actor_id.as_str()),
                actor_email = attr.and_then(|a| a.actor_email.as_deref()),
                actor_name = attr.map(|a| a.actor_name.as_str()),
                auth_provider_id = attr.and_then(|a| a.auth_provider_id.as_deref()),

                authorized_at = attr.map(|a| a.authorized_at.as_str()),
                authorization_expires_at = attr.map(|a| a.authorization_expires_at.as_str()),

                client_version = attr.map(|a| a.client_version.as_str()),
                device_os_name = attr.and_then(|a| a.device_os_name.as_deref()),
                device_os_version = attr.and_then(|a| a.device_os_version.as_deref()),
                device_serial = attr.and_then(|a| a.device_serial.as_deref()),
                device_uuid = attr.and_then(|a| a.device_uuid.as_deref()),
                device_identifier_for_vendor = attr.and_then(|a| a.device_identifier_for_vendor.as_deref()),
                device_firebase_installation_id = attr.and_then(|a| a.device_firebase_installation_id.as_deref()),

                inner_src_ip = %record.inner_src_ip,
                inner_src_port = record.inner_src_port,
                inner_dst_ip = %record.inner_dst_ip,
                inner_dst_port = record.inner_dst_port,
                domain = record.domain.as_ref().map(tracing::field::display),

                outer_src_ip = %record.outer_src_ip,
                outer_src_port = record.outer_src_port,
                outer_dst_ip = %record.outer_dst_ip,
                outer_dst_port = record.outer_dst_port,

                flow_start = ?record.flow_start,
                flow_end = close.map(|c| tracing::field::debug(c.flow_end)),
                last_packet = close.map(|c| tracing::field::debug(c.last_packet)),
                rx_packets = close.map(|c| c.rx_packets),
                tx_packets = close.map(|c| c.tx_packets),
                rx_bytes = close.map(|c| c.rx_bytes),
                tx_bytes = close.map(|c| c.tx_bytes),
                $message
            )
        };
    }

    match (record.protocol, close.is_some()) {
        (FlowProtocol::Tcp, false) => emit!("TCP flow started"),
        (FlowProtocol::Tcp, true) => emit!("TCP flow completed"),
        (FlowProtocol::Udp, false) => emit!("UDP flow started"),
        (FlowProtocol::Udp, true) => emit!("UDP flow completed"),
    }
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
    ingest_token: Option<IngestToken>,

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
    ingest_token: Option<IngestToken>,
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
    use chrono::TimeZone as _;
    use tracing_subscriber::layer::SubscriberExt as _;

    /// Guards the field contract between [`emit`] and `flow-log-writer`'s layer:
    /// an emitted record must round-trip losslessly into a spooled report.
    /// A JWT payload carrying every claim the portal guarantees on a token.
    fn required_claims(policy_authorization_id: &str, role: &str) -> String {
        format!(
            r#"{{"role":"{role}","device_id":"d-1","policy_authorization_id":"{policy_authorization_id}","policy_id":"p-1","resource_id":"r-1","resource_name":"web","actor_id":"a-1","actor_name":"Alice","authorized_at":"2026-07-01T00:00:00Z","authorization_expires_at":"2026-07-02T00:00:00Z","client_version":"1.5.0"}}"#
        )
    }

    #[test]
    fn emitted_records_spool_via_flow_log_writer_layer() {
        let authz_id = "11111111-1111-1111-1111-111111111111";
        let claims = base64::engine::general_purpose::URL_SAFE_NO_PAD
            .encode(required_claims(authz_id, "responder"));
        let record = Record {
            ingest_token: Some(format!("header.{claims}.signature").into()),
            protocol: FlowProtocol::Tcp,
            inner_src_ip: "100.64.0.1".parse().unwrap(),
            inner_src_port: 1234,
            inner_dst_ip: "10.0.0.5".parse().unwrap(),
            inner_dst_port: 443,
            domain: Some("download.httpbin".parse().unwrap()),
            outer_src_ip: "198.51.100.1".parse().unwrap(),
            outer_src_port: 51820,
            outer_dst_ip: "203.0.113.7".parse().unwrap(),
            outer_dst_port: 51820,
            flow_start: chrono::Utc.timestamp_opt(1_700_000_000, 500).unwrap(),
            close: Some(FlowClose {
                flow_end: chrono::Utc.timestamp_opt(1_700_000_060, 0).unwrap(),
                last_packet: chrono::Utc.timestamp_opt(1_700_000_059, 0).unwrap(),
                rx_packets: 10,
                tx_packets: 12,
                rx_bytes: 1024,
                tx_bytes: 2048,
            }),
        };

        let dir = tempfile::tempdir().unwrap();
        let (layer, guard) = flow_log_writer::layer(dir.path().to_owned());
        let subscriber = tracing_subscriber::registry().with(layer);
        tracing::subscriber::with_default(subscriber, || emit(&record));
        drop(guard); // joins the writer thread, so the report is on disk

        let authz_dir = dir.path().join("responder").join(authz_id);
        let report = std::fs::read_dir(&authz_dir)
            .expect("spooled report dir exists")
            .map(|entry| entry.unwrap().path())
            .find(|path| path.to_string_lossy().ends_with(".end.json"))
            .expect("completed report exists");
        let payload = flow_log_spool::deserialize(&std::fs::read(report).unwrap()).unwrap();

        assert_eq!(payload["protocol"], "tcp");
        assert_eq!(payload["inner_src_ip"], record.inner_src_ip.to_string());
        assert_eq!(payload["inner_src_port"], record.inner_src_port);
        assert_eq!(payload["inner_dst_ip"], record.inner_dst_ip.to_string());
        assert_eq!(payload["inner_dst_port"], record.inner_dst_port);
        assert_eq!(payload["domain"], "download.httpbin");
        assert_eq!(payload["outer_src_ip"], record.outer_src_ip.to_string());
        assert_eq!(payload["outer_src_port"], record.outer_src_port);
        assert_eq!(payload["outer_dst_ip"], record.outer_dst_ip.to_string());
        assert_eq!(payload["outer_dst_port"], record.outer_dst_port);
        assert_eq!(payload["flow_start"], format!("{:?}", record.flow_start));
        // Attribution rides the token, not the spooled record.
        assert!(payload.get("actor_id").is_none());

        let close = record.close.as_ref().unwrap();
        assert_eq!(payload["flow_end"], format!("{:?}", close.flow_end));
        assert_eq!(payload["last_packet"], format!("{:?}", close.last_packet));
        assert_eq!(payload["rx_packets"], close.rx_packets);
        assert_eq!(payload["tx_packets"], close.tx_packets);
        assert_eq!(payload["rx_bytes"], close.rx_bytes);
        assert_eq!(payload["tx_bytes"], close.tx_bytes);
    }

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
        let claims = required_claims("pa-1", "responder")
            .replace(r#""actor_name""#, r#""actor_email":"a@b.c","actor_name""#);
        let payload = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(claims);
        let token = IngestToken::from(format!("ignored-header.{payload}.ignored-signature"));

        let attr = token.attribution().expect("decodes attribution");

        assert_eq!(attr.policy_authorization_id, "pa-1");
        assert_eq!(attr.actor_email.as_deref(), Some("a@b.c"));
        assert_eq!(attr.role, "responder");
        assert!(attr.resource_address.is_none());
    }

    #[test]
    fn rejects_token_missing_a_guaranteed_claim() {
        let payload = base64::engine::general_purpose::URL_SAFE_NO_PAD
            .encode(r#"{"policy_authorization_id":"pa-1","role":"responder"}"#);
        let token = IngestToken::from(format!("h.{payload}.s"));

        assert!(token.attribution().is_none());
    }
}
