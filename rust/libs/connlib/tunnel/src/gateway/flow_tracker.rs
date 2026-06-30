//! Gateway-side feeding layer for flow logging.
//!
//! The Gateway is always the *responder*, so packets it receives over WireGuard
//! (from a client) are the initiator-to-responder ("tx") direction and packets it
//! reads from the TUN device (replies from the resource) are the
//! responder-to-initiator ("rx") direction. The actual open/close/split/timeout
//! logic lives in [`crate::flow_log`]; this module only gathers the fields for one
//! packet (across the several functions that process it) via a thread-local and,
//! on guard drop, hands them to the shared [`Tracker`].

use std::{
    cell::RefCell,
    net::{IpAddr, SocketAddr},
    time::Instant,
};

use connlib_model::{ClientId, ResourceId};
use dns_types::DomainName;
use ip_packet::{IcmpError, IpPacket, Protocol, UnsupportedProtocol};

use crate::flow_log::{FlowContext, RxFlow, Tracker, TxFlow};

pub use crate::flow_log::FlowLogRecord;

/// Identifies which authorization a flow belongs to on the Gateway.
type Scope = (ClientId, ResourceId);

thread_local! {
    static CURRENT_FLOW: RefCell<Option<FlowData>> = const { RefCell::new(None) };
}

/// Gateway flow tracker: the shared [`Tracker`] keyed by `(client, resource)` plus
/// the thread-local feeding used while a packet is processed.
#[derive(Debug)]
pub struct FlowTracker {
    inner: Tracker<Scope>,
}

impl FlowTracker {
    pub fn new(enabled: bool, now: Instant) -> Self {
        Self {
            inner: Tracker::new(enabled, now),
        }
    }

    pub fn new_inbound_tun<'a>(
        &'a mut self,
        packet: &IpPacket,
        now: Instant,
    ) -> CurrentFlowGuard<'a> {
        if !self.inner.enabled() {
            return CurrentFlowGuard {
                inner: self,
                created_at: now,
            };
        }

        let current = CURRENT_FLOW.replace(Some(FlowData::InboundTun(InboundTun {
            inner: InnerFlow::from(packet),
            outer: None,
            client: None,
            resource: None,
        })));
        debug_assert!(
            current.is_none(),
            "at most 1 flow should be active at any time"
        );

        CurrentFlowGuard {
            inner: self,
            created_at: now,
        }
    }

    pub fn new_inbound_wireguard<'a>(
        &'a mut self,
        local: SocketAddr,
        remote: SocketAddr,
        now: Instant,
    ) -> CurrentFlowGuard<'a> {
        if !self.inner.enabled() {
            return CurrentFlowGuard {
                inner: self,
                created_at: now,
            };
        }

        let current = CURRENT_FLOW.replace(Some(FlowData::InboundWireGuard(InboundWireGuard {
            outer: OuterFlow { local, remote },
            inner: None,
            client: None,
            resource: None,
            icmp_error: None,
            domain: None,
        })));
        debug_assert!(
            current.is_none(),
            "at most 1 flow should be active at any time"
        );

        CurrentFlowGuard {
            inner: self,
            created_at: now,
        }
    }

    pub fn set_enabled(&mut self, enabled: bool) {
        self.inner.set_enabled(enabled);
    }

    pub fn handle_timeout(&mut self, now: Instant) {
        self.inner.handle_timeout(now);
    }

    pub fn poll_flow_record(&mut self) -> Option<FlowLogRecord> {
        self.inner.poll_flow_record()
    }

    /// Records a fully-gathered inbound-WireGuard packet (the tx direction).
    fn record_inbound_wireguard(&mut self, flow: InboundWireGuard, now: Instant) {
        let InboundWireGuard {
            outer,
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
            client: Some(client),
            resource: Some(resource),
            domain,
            icmp_error: _, // TODO: What to do with ICMP errors?
        } = flow
        else {
            tracing::trace!(?flow, "Cannot create flow with missing data");

            return;
        };

        self.inner.record_tx(
            TxFlow {
                scope: (client, resource.id),
                context: FlowContext::new(outer.remote, outer.local),
                src_ip,
                dst_ip,
                src_proto,
                dst_proto,
                tcp_syn,
                tcp_fin,
                tcp_rst,
                payload_len,
                ingest_token: resource.ingest_token,
                domain,
            },
            now,
        );
    }

    /// Records a fully-gathered inbound-TUN packet (the rx direction).
    fn record_inbound_tun(&mut self, flow: InboundTun, now: Instant) {
        let InboundTun {
            inner:
                InnerFlow {
                    src_ip,
                    dst_ip,
                    src_proto: Ok(src_proto),
                    dst_proto: Ok(dst_proto),
                    tcp_syn: _,
                    tcp_fin,
                    tcp_rst,
                    payload_len,
                },
            outer: Some(_),
            client: Some(client),
            resource: Some(resource),
        } = flow
        else {
            tracing::trace!(?flow, "Cannot create flow with missing data");

            return;
        };

        self.inner.record_rx(
            RxFlow {
                scope: (client, resource),
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

pub mod inbound_wg {
    use dns_types::DomainName;

    use super::*;

    pub fn record_client(cid: ClientId) {
        update_current_flow_inbound_wireguard(|wg| wg.client.replace(cid));
    }

    pub fn record_resource(id: ResourceId, ingest_token: Option<String>) {
        update_current_flow_inbound_wireguard(|wg| {
            wg.resource.replace(Resource { id, ingest_token })
        });
    }

    pub fn record_domain(name: DomainName) {
        update_current_flow_inbound_wireguard(|wg| wg.domain.replace(name));
    }

    pub fn record_decrypted_packet(packet: &IpPacket) {
        update_current_flow_inbound_wireguard(|wg| {
            wg.inner = Some(InnerFlow::from(packet));
        });
    }

    pub fn record_translated_packet(packet: &IpPacket) {
        update_current_flow_inbound_wireguard(|wg| {
            let Some(inner) = wg.inner.as_mut() else {
                return;
            };

            inner.dst_ip = packet.destination();
            inner.src_proto = packet.source_protocol();
        });
    }

    pub fn record_icmp_error(packet: &IpPacket) {
        let Ok(Some((_, icmp_error))) = packet.icmp_error() else {
            return;
        };

        update_current_flow_inbound_wireguard(|wg| wg.icmp_error.replace(icmp_error));
    }
}

pub mod inbound_tun {
    use super::*;

    pub fn record_client(cid: ClientId) {
        update_current_flow_inbound_tun(|tun| tun.client.replace(cid));
    }

    pub fn record_resource(id: ResourceId) {
        update_current_flow_inbound_tun(|wg| wg.resource.replace(id));
    }

    pub fn record_wireguard_packet(local: Option<SocketAddr>, remote: SocketAddr) {
        update_current_flow_inbound_tun(|tun| tun.outer = Some(OuterFlow { local, remote }));
    }
}

fn update_current_flow_inbound_wireguard<R>(f: impl FnOnce(&mut InboundWireGuard) -> R) {
    CURRENT_FLOW.with_borrow_mut(|c| {
        let Some(FlowData::InboundWireGuard(wg)) = c else {
            return;
        };

        f(wg);
    });
}

fn update_current_flow_inbound_tun<R>(f: impl FnOnce(&mut InboundTun) -> R) {
    CURRENT_FLOW.with_borrow_mut(|c| {
        let Some(FlowData::InboundTun(tun)) = c else {
            return;
        };

        f(tun);
    });
}

pub struct CurrentFlowGuard<'a> {
    inner: &'a mut FlowTracker,
    created_at: Instant,
}

impl<'a> Drop for CurrentFlowGuard<'a> {
    fn drop(&mut self) {
        let Some(current_flow) = CURRENT_FLOW.replace(None) else {
            return;
        };

        match current_flow {
            FlowData::InboundWireGuard(flow) => {
                self.inner.record_inbound_wireguard(flow, self.created_at)
            }
            FlowData::InboundTun(flow) => self.inner.record_inbound_tun(flow, self.created_at),
        }
    }
}

enum FlowData {
    InboundWireGuard(InboundWireGuard),
    InboundTun(InboundTun),
}

#[derive(Debug)]
struct InboundWireGuard {
    outer: OuterFlow<SocketAddr>,
    inner: Option<InnerFlow>,
    client: Option<ClientId>,
    resource: Option<Resource>,
    /// The domain name in case this packet is for a DNS resource.
    domain: Option<DomainName>,
    icmp_error: Option<IcmpError>,
}

#[derive(Debug)]
struct InboundTun {
    inner: InnerFlow,
    outer: Option<OuterFlow<Option<SocketAddr>>>,
    client: Option<ClientId>,
    resource: Option<ResourceId>,
}

#[derive(Debug)]
struct OuterFlow<L> {
    local: L,
    remote: SocketAddr,
}

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

#[derive(Debug)]
struct Resource {
    id: ResourceId,
    ingest_token: Option<String>,
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
