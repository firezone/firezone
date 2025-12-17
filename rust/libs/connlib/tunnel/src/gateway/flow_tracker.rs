use std::{
    cell::RefCell,
    collections::{HashMap, VecDeque, hash_map},
    net::{IpAddr, SocketAddr},
};

use chrono::{DateTime, TimeDelta, Utc};
use connlib_model::{ClientId, ResourceId};
use dns_types::DomainName;
use ip_packet::{IcmpError, IpPacket, Protocol, UnsupportedProtocol};
use std::time::Instant;

thread_local! {
    static CURRENT_FLOW: RefCell<Option<FlowData>> = const { RefCell::new(None) };
}

const FLOW_TIMEOUT: TimeDelta = TimeDelta::minutes(2);

#[derive(Debug)]
pub struct FlowTracker {
    active_tcp_flows: HashMap<TcpFlowKey, TcpFlowValue>,
    active_udp_flows: HashMap<UdpFlowKey, UdpFlowValue>,

    completed_flows: VecDeque<CompletedFlow>,

    enabled: bool,
    created_at: Instant,
    created_at_utc: DateTime<Utc>,
}

/// Additional properties we track for a client.
#[derive(Debug, Clone, Default)]
pub struct ClientProperties {
    pub version: Option<String>,
    pub device_serial: Option<String>,
    pub device_uuid: Option<String>,
    pub device_os_name: Option<String>,
    pub device_os_version: Option<String>,
    pub identifier_for_vendor: Option<String>,
    pub firebase_installation_id: Option<String>,
    pub auth_provider_id: Option<String>,
    pub actor_name: Option<String>,
    pub actor_id: Option<String>,
    pub actor_email: Option<String>,
}

impl FlowTracker {
    pub fn new(enabled: bool, now: Instant) -> Self {
        Self {
            active_tcp_flows: Default::default(),
            active_udp_flows: Default::default(),
            completed_flows: Default::default(),
            enabled,
            created_at: now,
            created_at_utc: Utc::now(),
        }
    }

    pub fn new_inbound_tun<'a>(
        &'a mut self,
        packet: &IpPacket,
        now: Instant,
    ) -> CurrentFlowGuard<'a> {
        if !self.enabled {
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
        if !self.enabled {
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

    pub fn poll_completed_flow(&mut self) -> Option<CompletedFlow> {
        self.completed_flows.pop_front()
    }

    pub fn handle_timeout(&mut self, now: Instant) {
        let now_utc = self.now_utc(now);

        for (key, value) in self
            .active_tcp_flows
            .extract_if(|_, value| now_utc.signed_duration_since(value.last_packet) > FLOW_TIMEOUT)
        {
            let flow = CompletedTcpFlow::new(key, value, now_utc);

            tracing::debug!(?flow, "Terminating TCP flow; timeout");

            self.completed_flows.push_back(flow.into());
        }

        for (key, value) in self
            .active_udp_flows
            .extract_if(|_, value| now_utc.signed_duration_since(value.last_packet) > FLOW_TIMEOUT)
        {
            let flow = CompletedUdpFlow::new(key, value, now_utc);

            tracing::debug!(?flow, "Terminating UDP flow; timeout");

            self.completed_flows.push_back(flow.into());
        }

        for (key, value) in self
            .active_tcp_flows
            .extract_if(|_, value| value.fin_rx && value.fin_tx)
        {
            let end = value.last_packet;
            let flow = CompletedTcpFlow::new(key, value, end);

            tracing::debug!(?flow, "Terminating TCP flow; FIN sent & received");

            self.completed_flows.push_back(flow.into());
        }
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
            domain,
            icmp_error: _, // TODO: What to do with ICMP errors?
        } = flow
        else {
            tracing::trace!(?flow, "Cannot create flow with missing data");

            return;
        };
        let now_utc = self.now_utc(now);
        let context = FlowContext {
            src_ip: outer.remote.ip(),
            dst_ip: outer.local.ip(),
            src_port: outer.remote.port(),
            dst_port: outer.local.port(),
        };

        match (src_proto, dst_proto) {
            (Protocol::Tcp(src_port), Protocol::Tcp(dst_port)) => {
                let key = TcpFlowKey {
                    client: client.id,
                    resource: resource.id,
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

                        vacant.insert(TcpFlowValue {
                            start: now_utc,
                            last_packet: now_utc,
                            stats: FlowStats::default().with_tx(payload_len as u64),
                            context,
                            fin_tx: false,
                            fin_rx: false,
                            domain,
                            resource_name: resource.name,
                            resource_address: resource.address,
                            client_version: client.version,
                            device_os_name: client.device_os_name,
                            device_os_version: client.device_os_version,
                            device_serial: client.device_serial,
                            device_uuid: client.device_uuid,
                            identifier_for_vendor: client.identifier_for_vendor,
                            firebase_installation_id: client.firebase_installation_id,
                            actor_id: client.actor_id,
                            actor_email: client.actor_email,
                            auth_provider_id: client.auth_provider_id,
                            actor_name: client.actor_name,
                        });
                    }
                    hash_map::Entry::Occupied(occupied) if occupied.get().context != context => {
                        let (key, value) = occupied.remove_entry();
                        let context_diff = FlowContextDiff::new(value.context, context);

                        tracing::debug!(
                            ?key,
                            ?context_diff,
                            "Splitting existing TCP flow; context changed"
                        );

                        let flow = CompletedTcpFlow::new(key, value, now_utc);

                        self.completed_flows.push_back(flow.into());

                        self.active_tcp_flows.insert(
                            key,
                            TcpFlowValue {
                                start: now_utc,
                                last_packet: now_utc,
                                stats: FlowStats::default().with_tx(payload_len as u64),
                                context,
                                fin_tx: false,
                                fin_rx: false,
                                domain,
                                resource_name: resource.name,
                                resource_address: resource.address,
                                client_version: client.version,
                                device_os_name: client.device_os_name,
                                device_os_version: client.device_os_version,
                                device_serial: client.device_serial,
                                device_uuid: client.device_uuid,
                                identifier_for_vendor: client.identifier_for_vendor,
                                firebase_installation_id: client.firebase_installation_id,
                                actor_id: client.actor_id,
                                actor_email: client.actor_email,
                                auth_provider_id: client.auth_provider_id,
                                actor_name: client.actor_name,
                            },
                        );
                    }
                    hash_map::Entry::Occupied(occupied) if tcp_syn => {
                        let (key, value) = occupied.remove_entry();

                        tracing::debug!(?key, "Splitting existing TCP flow; new TCP SYN");

                        let flow = CompletedTcpFlow::new(key, value, now_utc);

                        self.completed_flows.push_back(flow.into());

                        self.active_tcp_flows.insert(
                            key,
                            TcpFlowValue {
                                start: now_utc,
                                last_packet: now_utc,
                                stats: FlowStats::default().with_tx(payload_len as u64),
                                context,
                                fin_tx: false,
                                fin_rx: false,
                                domain,
                                resource_name: resource.name,
                                resource_address: resource.address,
                                client_version: client.version,
                                device_os_name: client.device_os_name,
                                device_os_version: client.device_os_version,
                                device_serial: client.device_serial,
                                device_uuid: client.device_uuid,
                                identifier_for_vendor: client.identifier_for_vendor,
                                firebase_installation_id: client.firebase_installation_id,
                                actor_id: client.actor_id,
                                actor_email: client.actor_email,
                                auth_provider_id: client.auth_provider_id,
                                actor_name: client.actor_name,
                            },
                        );
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
                            let flow = CompletedTcpFlow::new(key, value, now_utc);

                            tracing::debug!(?flow, "TCP flow completed on outbound RST");

                            self.completed_flows.push_back(flow.into());
                        }
                    }
                };
            }
            (Protocol::Udp(src_port), Protocol::Udp(dst_port)) => {
                let key = UdpFlowKey {
                    client: client.id,
                    resource: resource.id,
                    src_ip,
                    dst_ip,
                    src_port,
                    dst_port,
                };

                match self.active_udp_flows.entry(key) {
                    hash_map::Entry::Vacant(vacant) => {
                        tracing::debug!(key = ?vacant.key(), "Creating new UDP flow");

                        vacant.insert(UdpFlowValue {
                            start: now_utc,
                            last_packet: now_utc,
                            stats: FlowStats::default().with_tx(payload_len as u64),
                            context,
                            domain,
                            resource_name: resource.name,
                            resource_address: resource.address,
                            client_version: client.version,
                            device_os_name: client.device_os_name,
                            device_os_version: client.device_os_version,
                            device_serial: client.device_serial,
                            device_uuid: client.device_uuid,
                            identifier_for_vendor: client.identifier_for_vendor,
                            firebase_installation_id: client.firebase_installation_id,
                            actor_id: client.actor_id,
                            actor_email: client.actor_email,
                            auth_provider_id: client.auth_provider_id,
                            actor_name: client.actor_name,
                        });
                    }
                    hash_map::Entry::Occupied(occupied) if occupied.get().context != context => {
                        let (key, value) = occupied.remove_entry();
                        let context_diff = FlowContextDiff::new(value.context, context);

                        let flow = CompletedUdpFlow::new(key, value.clone(), now_utc);

                        tracing::debug!(
                            ?key,
                            ?context_diff,
                            "Splitting existing UDP flow; context changed"
                        );

                        self.completed_flows.push_back(flow.into());

                        self.active_udp_flows.insert(
                            key,
                            UdpFlowValue {
                                start: now_utc,
                                last_packet: now_utc,
                                stats: FlowStats::default().with_tx(payload_len as u64),
                                context,
                                domain,
                                resource_name: value.resource_name,
                                resource_address: value.resource_address,
                                client_version: client.version,
                                device_os_name: client.device_os_name,
                                device_os_version: client.device_os_version,
                                device_serial: client.device_serial,
                                device_uuid: client.device_uuid,
                                identifier_for_vendor: client.identifier_for_vendor,
                                firebase_installation_id: client.firebase_installation_id,
                                actor_id: client.actor_id,
                                actor_email: client.actor_email,
                                auth_provider_id: client.auth_provider_id,
                                actor_name: client.actor_name,
                            },
                        );
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

    fn insert_inbound_tun_flow(&mut self, flow: InboundTun, now: Instant) {
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
                    hash_map::Entry::Vacant(vacant) => {
                        if tcp_fin || tcp_rst {
                            // Don't care about FIN/RST packets where the flow no longer exists.
                            return;
                        }

                        tracing::debug!(key = ?vacant.key(), "No existing TCP flow for packet inbound on TUN device");
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
                            let flow = CompletedTcpFlow::new(key, value, now_utc);

                            tracing::debug!(?flow, "TCP flow completed on inbound RST");

                            self.completed_flows.push_back(flow.into());
                        }
                    }
                };
            }
            (Protocol::Udp(src_port), Protocol::Udp(dst_port)) => {
                // For packets inbound from the TUN device, we need to flip src & dst.
                let key = UdpFlowKey {
                    client,
                    resource,
                    src_ip: dst_ip,
                    dst_ip: src_ip,
                    src_port: dst_port,
                    dst_port: src_port,
                };

                match self.active_udp_flows.entry(key) {
                    hash_map::Entry::Vacant(vacant) => {
                        tracing::debug!(key = ?vacant.key(), "No existing UDP flow for packet inbound on TUN device");
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

#[derive(Debug, derive_more::From)]
pub enum CompletedFlow {
    Tcp(CompletedTcpFlow),
    Udp(CompletedUdpFlow),
}

#[derive(Debug)]
pub struct CompletedTcpFlow {
    pub client_id: ClientId,
    pub client_version: Option<String>,

    pub device_os_name: Option<String>,
    pub device_os_version: Option<String>,
    pub device_serial: Option<String>,
    pub device_uuid: Option<String>,
    pub device_identifier_for_vendor: Option<String>,
    pub device_firebase_installation_id: Option<String>,

    pub auth_provider_id: Option<String>,
    pub actor_name: Option<String>,
    pub actor_id: Option<String>,
    pub actor_email: Option<String>,

    pub resource_id: ResourceId,
    pub resource_name: String,
    pub resource_address: String,

    pub start: DateTime<Utc>,
    pub end: DateTime<Utc>,
    pub last_packet: DateTime<Utc>,

    pub inner_src_ip: IpAddr,
    pub inner_dst_ip: IpAddr,
    pub inner_src_port: u16,
    pub inner_dst_port: u16,
    pub inner_domain: Option<DomainName>,

    pub outer_src_ip: IpAddr,
    pub outer_dst_ip: IpAddr,
    pub outer_src_port: u16,
    pub outer_dst_port: u16,

    pub rx_packets: u64,
    pub tx_packets: u64,
    pub rx_bytes: u64,
    pub tx_bytes: u64,
}

#[derive(Debug)]
pub struct CompletedUdpFlow {
    pub client_id: ClientId,
    pub client_version: Option<String>,

    pub device_os_name: Option<String>,
    pub device_os_version: Option<String>,
    pub device_serial: Option<String>,
    pub device_uuid: Option<String>,
    pub device_identifier_for_vendor: Option<String>,
    pub device_firebase_installation_id: Option<String>,

    pub auth_provider_id: Option<String>,
    pub actor_name: Option<String>,
    pub actor_id: Option<String>,
    pub actor_email: Option<String>,

    pub resource_id: ResourceId,
    pub resource_name: String,
    pub resource_address: String,

    pub start: DateTime<Utc>,
    pub end: DateTime<Utc>,
    pub last_packet: DateTime<Utc>,

    pub inner_src_ip: IpAddr,
    pub inner_dst_ip: IpAddr,
    pub inner_src_port: u16,
    pub inner_dst_port: u16,
    pub inner_domain: Option<DomainName>,

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
        Self {
            client_id: key.client,
            client_version: value.client_version,
            device_os_name: value.device_os_name,
            device_os_version: value.device_os_version,
            device_serial: value.device_serial,
            device_uuid: value.device_uuid,
            device_identifier_for_vendor: value.identifier_for_vendor,
            device_firebase_installation_id: value.firebase_installation_id,
            actor_id: value.actor_id,
            actor_email: value.actor_email,
            auth_provider_id: value.auth_provider_id,
            actor_name: value.actor_name,
            resource_id: key.resource,
            resource_name: value.resource_name,
            resource_address: value.resource_address,
            start: value.start,
            end,
            last_packet: value.last_packet,
            inner_src_ip: key.src_ip,
            inner_dst_ip: key.dst_ip,
            inner_src_port: key.src_port,
            inner_dst_port: key.dst_port,
            inner_domain: value.domain,
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

impl CompletedUdpFlow {
    fn new(key: UdpFlowKey, value: UdpFlowValue, end: DateTime<Utc>) -> Self {
        Self {
            client_id: key.client,
            client_version: value.client_version,
            device_os_name: value.device_os_name,
            device_os_version: value.device_os_version,
            device_serial: value.device_serial,
            device_uuid: value.device_uuid,
            device_identifier_for_vendor: value.identifier_for_vendor,
            device_firebase_installation_id: value.firebase_installation_id,
            actor_id: value.actor_id,
            actor_email: value.actor_email,
            auth_provider_id: value.auth_provider_id,
            actor_name: value.actor_name,
            resource_id: key.resource,
            resource_name: value.resource_name,
            resource_address: value.resource_address,
            start: value.start,
            end,
            last_packet: value.last_packet,
            inner_src_ip: key.src_ip,
            inner_dst_ip: key.dst_ip,
            inner_src_port: key.src_port,
            inner_dst_port: key.dst_port,
            inner_domain: value.domain,
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

#[derive(Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Clone, Copy)]
struct TcpFlowKey {
    client: ClientId,
    resource: ResourceId,
    src_ip: IpAddr,
    dst_ip: IpAddr,
    src_port: u16,
    dst_port: u16,
}

#[derive(Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Clone, Copy)]
struct UdpFlowKey {
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
    last_packet: DateTime<Utc>,
    stats: FlowStats,
    context: FlowContext,

    domain: Option<DomainName>,

    resource_name: String,
    resource_address: String,

    client_version: Option<String>,
    device_serial: Option<String>,
    device_uuid: Option<String>,
    device_os_name: Option<String>,
    device_os_version: Option<String>,
    identifier_for_vendor: Option<String>,
    firebase_installation_id: Option<String>,

    auth_provider_id: Option<String>,
    actor_name: Option<String>,
    actor_id: Option<String>,
    actor_email: Option<String>,

    fin_tx: bool,
    fin_rx: bool,
}

#[derive(Debug, Clone)]
struct UdpFlowValue {
    start: DateTime<Utc>,
    last_packet: DateTime<Utc>,
    stats: FlowStats,
    context: FlowContext,

    domain: Option<DomainName>,

    resource_name: String,
    resource_address: String,

    client_version: Option<String>,
    device_serial: Option<String>,
    device_uuid: Option<String>,
    device_os_name: Option<String>,
    device_os_version: Option<String>,
    identifier_for_vendor: Option<String>,
    firebase_installation_id: Option<String>,

    auth_provider_id: Option<String>,
    actor_name: Option<String>,
    actor_id: Option<String>,
    actor_email: Option<String>,
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

#[derive(Debug, PartialEq, Eq, Clone, Copy)]
struct FlowContext {
    src_ip: IpAddr,
    dst_ip: IpAddr,
    src_port: u16,
    dst_port: u16,
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

pub mod inbound_wg {
    use dns_types::DomainName;

    use super::*;

    pub fn record_client(cid: ClientId, props: ClientProperties) {
        update_current_flow_inbound_wireguard(|wg| {
            wg.client.replace(Client {
                id: cid,
                version: props.version,
                device_os_name: props.device_os_name,
                device_os_version: props.device_os_version,
                device_serial: props.device_serial,
                actor_id: props.actor_id,
                actor_email: props.actor_email,
                auth_provider_id: props.auth_provider_id,
                actor_name: props.actor_name,
                device_uuid: props.device_uuid,
                identifier_for_vendor: props.identifier_for_vendor,
                firebase_installation_id: props.firebase_installation_id,
            })
        });
    }

    pub fn record_resource(id: ResourceId, name: String, address: String) {
        update_current_flow_inbound_wireguard(|wg| {
            wg.resource.replace(Resource { id, name, address })
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
    client: Option<Client>,
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
struct Client {
    id: ClientId,

    version: Option<String>,

    device_serial: Option<String>,
    device_uuid: Option<String>,
    device_os_name: Option<String>,
    device_os_version: Option<String>,

    identifier_for_vendor: Option<String>,
    firebase_installation_id: Option<String>,

    auth_provider_id: Option<String>,
    actor_name: Option<String>,
    actor_id: Option<String>,
    actor_email: Option<String>,
}

#[derive(Debug)]
struct Resource {
    id: ResourceId,
    name: String,
    address: String,
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
}
