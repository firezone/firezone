use std::{
    cell::RefCell,
    collections::{BTreeMap, VecDeque, btree_map},
    net::{IpAddr, SocketAddr},
};

use chrono::{DateTime, Utc};
use connlib_model::{ClientId, ResourceId};
use ip_packet::{IpPacket, Protocol, UnsupportedProtocol};
use std::time::Instant;

thread_local! {
    static CURRENT_FLOW: RefCell<Option<FlowData>> = const { RefCell::new(None) };
}

#[derive(Debug)]
pub struct FlowTracker {
    active_tcp_flows: BTreeMap<TcpFlowKey, TcpFlowValue>,

    completed_tcp_flows: VecDeque<CompletedTcpFlow>,

    created_at: Instant,
    created_at_utc: DateTime<Utc>,
}

impl FlowTracker {
    pub fn new(now: Instant) -> Self {
        Self {
            active_tcp_flows: Default::default(),
            completed_tcp_flows: Default::default(),
            created_at: now,
            created_at_utc: Utc::now(),
        }
    }

    pub fn new_inbound_tun<'a>(
        &'a mut self,
        packet: &IpPacket,
        now: Instant,
    ) -> CurrentFlowGuard<'a> {
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
        payload: &[u8],
        now: Instant,
    ) -> CurrentFlowGuard<'a> {
        let current = CURRENT_FLOW.replace(Some(FlowData::InboundWireGuard(InboundWireGuard {
            outer: OuterFlow {
                local,
                remote,
                payload_len: payload.len(),
            },
            inner: None,
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

    pub fn poll_completed_flow(&mut self) -> Option<CompletedFlow> {
        self.completed_tcp_flows.pop_front().map(CompletedFlow::Tcp)
    }

    fn insert_inbound_wireguard_flow(&mut self, flow: InboundWireGuard, now: Instant) {
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
        } = flow
        else {
            tracing::debug!(?flow, "Cannot create flow with missing data");

            return;
        };
        let now_utc = self.now_utc(now);

        match (src_proto, dst_proto) {
            (Protocol::Tcp(src_port), Protocol::Tcp(dst_port)) => {
                let key = TcpFlowKey {
                    client,
                    resource,
                    src_ip,
                    dst_ip,
                    src_port,
                    dst_port,
                };

                match self.active_tcp_flows.entry(key) {
                    btree_map::Entry::Vacant(vacant) => {
                        if !tcp_syn {
                            tracing::debug!("Creating new TCP flow without SYN flag");
                        }

                        vacant.insert(TcpFlowValue {
                            start: now_utc,
                            stats: FlowStats::default().with_tx(payload_len as u64),
                            context: FlowContext {
                                src_ip: outer.remote.ip(),
                                dst_ip: outer.local.ip(),
                                src_port: outer.remote.port(),
                                dst_port: outer.local.port(),
                            },
                        });
                    }
                    btree_map::Entry::Occupied(mut occupied) => {
                        let value = occupied.get_mut();
                        value.stats.inc_tx(payload_len as u64);

                        // TODO: Create new flow if context changes.
                        // TODO: Create new flow if SYN set (handle src port reuse case)

                        if tcp_rst || tcp_fin {
                            let (key, value) = occupied.remove_entry();
                            let flow = CompletedTcpFlow::new(key, value, now_utc);

                            tracing::debug!(?flow, "TCP flow completed on RST/FIN");

                            self.completed_tcp_flows.push_back(flow);
                        }
                    }
                };
            }
            (Protocol::Udp(src_port), Protocol::Udp(dst_port)) => todo!(),
            (Protocol::Icmp(src_id), Protocol::Icmp(dst_id)) => todo!(),
            _ => {
                tracing::error!("src and dst protocol must be the same");
            }
        }
    }

    fn insert_inbound_tun_flow(&mut self, flow: InboundTun, now: Instant) {
        let InboundTun {
            inner:
                InnerFlow {
                    src_ip,
                    dst_ip,
                    src_proto: Ok(src_proto),
                    dst_proto: Ok(dst_proto),
                    tcp_syn,
                    tcp_fin,
                    tcp_rst,
                    payload_len,
                },
            outer: Some(outer),
            client: Some(client),
            resource: Some(resource),
        } = flow
        else {
            tracing::debug!(?flow, "Cannot create flow with missing data");

            return;
        };
        let now_utc = self.now_utc(now);

        match (src_proto, dst_proto) {
            (Protocol::Tcp(src_port), Protocol::Tcp(dst_port)) => {
                // For packets inbound from the TUN device, we need to flip src & dst.
                let key = TcpFlowKey {
                    client,
                    resource,
                    src_ip: dst_ip,
                    dst_ip: src_ip,
                    src_port: dst_port,
                    dst_port: src_port,
                };

                match self.active_tcp_flows.entry(key) {
                    btree_map::Entry::Vacant(_) => {
                        tracing::debug!("No existing TCP flow for packet inbound on TUN device");
                    }
                    btree_map::Entry::Occupied(mut occupied) => {
                        let value = occupied.get_mut();
                        value.stats.inc_rx(payload_len as u64);

                        // TODO: Create new flow if context changes.

                        if tcp_rst || tcp_fin {
                            let (key, value) = occupied.remove_entry();
                            let flow = CompletedTcpFlow::new(key, value, now_utc);

                            tracing::debug!(?flow, "TCP flow completed on RST/FIN");

                            self.completed_tcp_flows.push_back(flow);
                        }
                    }
                };
            }
            (Protocol::Udp(src_port), Protocol::Udp(dst_port)) => todo!(),
            (Protocol::Icmp(src_id), Protocol::Icmp(dst_id)) => todo!(),
            _ => {
                tracing::error!("src and dst protocol must be the same");
            }
        }
    }

    fn now_utc(&self, now: Instant) -> DateTime<Utc> {
        self.created_at_utc + now.duration_since(self.created_at)
    }
}

#[derive(Debug)]
pub enum CompletedFlow {
    Tcp(CompletedTcpFlow),
}

#[derive(Debug)]
pub struct CompletedTcpFlow {
    pub client: ClientId,
    pub resource: ResourceId,
    pub start: DateTime<Utc>,
    pub end: DateTime<Utc>,

    pub inner_src_ip: IpAddr,
    pub inner_dst_ip: IpAddr,
    pub inner_src_port: u16,
    pub inner_dst_port: u16,

    pub outer_src_ip: IpAddr,
    pub outer_dst_ip: IpAddr,
    pub outer_src_port: u16,
    pub outer_dst_port: u16,

    pub rx_packets: u64,
    pub tx_packets: u64,
    pub rx_bytes: u64,
    pub tx_bytes: u64,
}

impl CompletedTcpFlow {
    fn new(key: TcpFlowKey, value: TcpFlowValue, end: DateTime<Utc>) -> Self {
        CompletedTcpFlow {
            client: key.client,
            resource: key.resource,
            start: value.start,
            end,
            inner_src_ip: key.src_ip,
            inner_dst_ip: key.dst_ip,
            inner_src_port: key.src_port,
            inner_dst_port: key.dst_port,
            outer_src_ip: value.context.src_ip,
            outer_dst_ip: value.context.dst_ip,
            outer_src_port: value.context.src_port,
            outer_dst_port: value.context.dst_port,
            rx_packets: value.stats.rx_packets,
            tx_packets: value.stats.tx_packets,
            rx_bytes: value.stats.rx_bytes,
            tx_bytes: value.stats.tx_bytes,
        }
    }
}

#[derive(Debug, PartialEq, Eq, PartialOrd, Ord)]
struct TcpFlowKey {
    client: ClientId,
    resource: ResourceId,
    src_ip: IpAddr,
    dst_ip: IpAddr,
    src_port: u16,
    dst_port: u16,
}

#[derive(Debug)]
struct TcpFlowValue {
    start: DateTime<Utc>,
    stats: FlowStats,
    context: FlowContext,
}

#[derive(Debug, Default)]
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

    fn with_rx(mut self, payload_len: u64) -> Self {
        self.inc_rx(payload_len);

        self
    }

    fn inc_rx(&mut self, payload_len: u64) {
        self.rx_packets += 1;
        self.rx_bytes += payload_len;
    }
}

#[derive(Debug)]
struct FlowContext {
    src_ip: IpAddr,
    dst_ip: IpAddr,
    src_port: u16,
    dst_port: u16,
}

pub mod inbound_wg {
    use super::*;

    pub fn record_client(cid: ClientId) {
        update_current_flow_inbound_wireguard(|wg| wg.client.replace(cid));
    }

    pub fn record_resource(rid: ResourceId) {
        update_current_flow_inbound_wireguard(|wg| wg.resource.replace(rid));
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
        });
    }

    pub fn record_icmp_error(packet: &IpPacket) {}
}

pub mod inbound_tun {
    use super::*;

    pub fn record_client(cid: ClientId) {
        update_current_flow_inbound_tun(|tun| tun.client.replace(cid));
    }

    pub fn record_resource(rid: ResourceId) {
        update_current_flow_inbound_tun(|tun| tun.resource.replace(rid));
    }

    pub fn record_translated_packet(packet: &IpPacket) {
        update_current_flow_inbound_tun(|tun| {
            // We overwrite the original src IP and dst protocol to hide the DNS resource NAT.

            tun.inner.src_ip = packet.source();
            tun.inner.dst_proto = packet.destination_protocol();
        });
    }

    pub fn record_wireguard_packet(local: Option<SocketAddr>, remote: SocketAddr, payload: &[u8]) {
        update_current_flow_inbound_tun(|tun| {
            tun.outer = Some(OuterFlow {
                local,
                remote,
                payload_len: payload.len(),
            })
        });
    }
}

fn update_current_flow_inbound_wireguard<R>(f: impl Fn(&mut InboundWireGuard) -> R) {
    CURRENT_FLOW.with_borrow_mut(|c| {
        let Some(FlowData::InboundWireGuard(wg)) = c else {
            return;
        };

        f(wg);
    });
}

fn update_current_flow_inbound_tun<R>(f: impl Fn(&mut InboundTun) -> R) {
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
            debug_assert!(
                false,
                "Should always have a current flow if an `InboundFlowGuard` is alive"
            );

            return;
        };

        match current_flow {
            FlowData::InboundWireGuard(flow) => self
                .inner
                .insert_inbound_wireguard_flow(flow, self.created_at),
            FlowData::InboundTun(flow) => self.inner.insert_inbound_tun_flow(flow, self.created_at),
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
    resource: Option<ResourceId>,
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
    payload_len: usize,
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
            payload_len: packet.payload().len(), // TODO: Actually use the L4 payload length here (i.e. don't count the headers.)
        }
    }
}
