use super::{
    dns_records::DnsRecords,
    dns_server_resource::{TcpDnsServerResource, UdpDnsServerResource},
    icmp_error_hosts::{IcmpError, IcmpErrorHosts},
    reference::{PrivateKey, private_key},
    sim_net::{Host, dual_ip_stack, host},
    sim_relay::{SimRelay, map_explode},
    strategies::latency,
};
use crate::{GatewayState, IpConfig};
use anyhow::{Result, bail};
use chrono::{DateTime, Utc};
use connlib_model::{GatewayId, RelayId};
use dns_types::DomainName;
use ip_packet::{IcmpEchoHeader, Icmpv4Type, Icmpv6Type, IpPacket};
use proptest::prelude::*;
use snownet::Transmit;
use std::{
    collections::{BTreeMap, BTreeSet},
    iter,
    net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr},
    time::Instant,
};

/// Simulation state for a particular client.
pub(crate) struct SimGateway {
    id: GatewayId,
    pub(crate) sut: GatewayState,

    /// The received ICMP packets, indexed by our custom ICMP payload.
    pub(crate) received_icmp_requests: BTreeMap<u64, (Instant, IpPacket)>,

    /// The received UDP packets, indexed by our custom UDP payload.
    pub(crate) received_udp_requests: BTreeMap<u64, (Instant, IpPacket)>,

    /// The times we resolved DNS records for a domain.
    pub(crate) dns_query_timestamps: BTreeMap<DomainName, Vec<Instant>>,

    site_specific_dns_records: DnsRecords,
    udp_dns_server_resources: BTreeMap<SocketAddr, UdpDnsServerResource>,
    tcp_dns_server_resources: BTreeMap<SocketAddr, TcpDnsServerResource>,

    tcp_resources: BTreeMap<SocketAddr, crate::tests::tcp::Server>,
}

impl SimGateway {
    pub(crate) fn new(
        id: GatewayId,
        sut: GatewayState,
        tcp_resources: BTreeSet<SocketAddr>,
        site_specific_dns_records: DnsRecords,
        now: Instant,
    ) -> Self {
        Self {
            id,
            sut,
            site_specific_dns_records,
            received_icmp_requests: Default::default(),
            udp_dns_server_resources: Default::default(),
            tcp_dns_server_resources: Default::default(),
            received_udp_requests: Default::default(),
            dns_query_timestamps: Default::default(),
            tcp_resources: tcp_resources
                .into_iter()
                .map(|address| {
                    let mut server = crate::tests::tcp::Server::new(now);
                    if let Err(e) = server.listen(address) {
                        tracing::error!(%address, "Failed to listen on address: {e}")
                    }

                    (address, server)
                })
                .collect(),
        }
    }

    pub(crate) fn receive(
        &mut self,
        transmit: Transmit,
        icmp_error_hosts: &IcmpErrorHosts,
        now: Instant,
        utc_now: DateTime<Utc>,
    ) -> Option<Transmit> {
        let Some(packet) = self
            .sut
            .handle_network_input(transmit.dst, transmit.src.unwrap(), &transmit.payload, now)
            .inspect_err(|e| tracing::warn!("{e:#}"))
            .ok()
            .flatten()
        else {
            self.sut.handle_timeout(now, utc_now);
            return None;
        };

        self.on_received_packet(packet, icmp_error_hosts, now)
    }

    pub(crate) fn advance_resources(
        &mut self,
        global_dns_records: &DnsRecords,
        now: Instant,
    ) -> Vec<Transmit> {
        let Some(ip_config) = self.sut.tunnel_ip_config() else {
            tracing::error!("Tunnel IP configuration not set");
            return Vec::new();
        };

        let udp_server_packets =
            self.udp_dns_server_resources
                .iter_mut()
                .flat_map(|(socket, server)| {
                    if ip_config.is_ip(socket.ip()) {
                        server.handle_timeout(&self.site_specific_dns_records, now);
                    } else {
                        server.handle_timeout(global_dns_records, now);
                    }

                    std::iter::from_fn(|| server.poll_outbound())
                });
        let tcp_server_packets =
            self.tcp_dns_server_resources
                .iter_mut()
                .flat_map(|(socket, server)| {
                    if ip_config.is_ip(socket.ip()) {
                        server.handle_timeout(&self.site_specific_dns_records, now);
                    } else {
                        server.handle_timeout(global_dns_records, now);
                    }

                    std::iter::from_fn(|| server.poll_outbound())
                });
        let tcp_resource_packets = self.tcp_resources.values_mut().flat_map(|server| {
            server.handle_timeout(now);

            std::iter::from_fn(|| server.poll_outbound())
        });

        udp_server_packets
            .chain(tcp_server_packets)
            .chain(tcp_resource_packets)
            .filter_map(|packet| self.sut.handle_tun_input(packet, now).unwrap())
            .collect()
    }

    pub(crate) fn deploy_new_dns_servers(
        &mut self,
        dns_servers: impl IntoIterator<Item = SocketAddr>,
        now: Instant,
    ) {
        self.udp_dns_server_resources.clear();
        self.tcp_dns_server_resources.clear();

        let tun_dns_server_port = 53535; // Hardcoded here so we think about backwards-compatibility when changing it.
        let Some(ip_config) = self.sut.tunnel_ip_config() else {
            tracing::error!("Tunnel IP configuration not set");
            return;
        };

        for server in iter::empty()
            .chain(dns_servers)
            .chain(iter::once(SocketAddr::from((
                ip_config.v4,
                tun_dns_server_port,
            ))))
            .chain(iter::once(SocketAddr::from((
                ip_config.v6,
                tun_dns_server_port,
            ))))
        {
            self.udp_dns_server_resources
                .insert(server, UdpDnsServerResource::default());
            self.tcp_dns_server_resources
                .insert(server, TcpDnsServerResource::new(server, now));
        }
    }

    /// Process an IP packet received on the gateway.
    fn on_received_packet(
        &mut self,
        packet: IpPacket,
        icmp_error_hosts: &IcmpErrorHosts,
        now: Instant,
    ) -> Option<Transmit> {
        // TODO: Instead of handling these things inline, here, should we dispatch them via `RoutingTable`?

        let dst_ip = packet.destination();

        // Check if the destination host is unreachable.
        // If so, generate the error reply.
        // We still want to do all the book-keeping in terms of tracking which requests we received.
        // Therefore, pass the generated `icmp_error` to resulting `handle_` functions instead of sending it right away.
        let icmp_error = icmp_error_hosts
            .icmp_error_for_ip(dst_ip)
            .map(|icmp_error| icmp_error_reply(&packet, icmp_error).unwrap());

        if let Some(icmp) = packet.as_icmpv4()
            && let Icmpv4Type::EchoRequest(echo) = icmp.icmp_type()
        {
            let packet_id = u64::from_be_bytes(*icmp.payload().first_chunk().unwrap());
            tracing::debug!(%packet_id, "Received ICMP request");
            self.received_icmp_requests
                .insert(packet_id, (now, packet.clone()));
            return self.handle_icmp_request(&packet, echo, icmp.payload(), icmp_error, now);
        }

        if let Some(icmp) = packet.as_icmpv6()
            && let Icmpv6Type::EchoRequest(echo) = icmp.icmp_type()
        {
            let packet_id = u64::from_be_bytes(*icmp.payload().first_chunk().unwrap());
            tracing::debug!(%packet_id, "Received ICMP request");
            self.received_icmp_requests
                .insert(packet_id, (now, packet.clone()));
            return self.handle_icmp_request(&packet, echo, icmp.payload(), icmp_error, now);
        }

        if let Some(udp) = packet.as_udp() {
            let socket = SocketAddr::new(dst_ip, udp.destination_port());

            // NOTE: we can make this assumption because port 53 is excluded from non-dns query packets
            if let Some(server) = self.udp_dns_server_resources.get_mut(&socket) {
                server.handle_input(packet);
                return None;
            }
        }

        if let Some(tcp) = packet.as_tcp() {
            let socket = SocketAddr::new(dst_ip, tcp.destination_port());

            if let Some(server) = self.tcp_resources.get_mut(&socket) {
                server.handle_inbound(packet);
                return None;
            }

            // NOTE: we can make this assumption because port 53 is excluded from non-dns query packets
            if let Some(server) = self.tcp_dns_server_resources.get_mut(&socket) {
                server.handle_input(packet);
                return None;
            }
        }

        if let Some(reply) = icmp_error.or_else(|| echo_reply(packet.clone())) {
            self.request_received(&packet, now);
            let transmit = self.sut.handle_tun_input(reply, now).unwrap()?;

            return Some(transmit);
        }

        tracing::error!(?packet, "Unhandled packet");
        None
    }

    pub(crate) fn update_relays<'a>(
        &mut self,
        to_remove: impl Iterator<Item = RelayId>,
        to_add: impl Iterator<Item = (&'a RelayId, &'a Host<SimRelay>)> + 'a,
        now: Instant,
    ) {
        self.sut.update_relays(
            to_remove.collect(),
            map_explode(to_add, format!("gateway_{}", self.id)).collect(),
            now,
        )
    }

    fn request_received(&mut self, packet: &IpPacket, now: Instant) {
        if let Some(udp) = packet.as_udp() {
            let packet_id = u64::from_be_bytes(*udp.payload().first_chunk().unwrap());
            tracing::debug!(%packet_id, "Received UDP request");
            self.received_udp_requests
                .insert(packet_id, (now, packet.clone()));
        }
    }

    fn handle_icmp_request(
        &mut self,
        packet: &IpPacket,
        echo: IcmpEchoHeader,
        payload: &[u8],
        icmp_error: Option<IpPacket>,
        now: Instant,
    ) -> Option<Transmit> {
        let reply = icmp_error.unwrap_or_else(|| {
            ip_packet::make::icmp_reply_packet(
                packet.destination(),
                packet.source(),
                echo.seq,
                echo.id,
                payload,
            )
            .expect("src and dst are taken from incoming packet")
        });

        let transmit = self.sut.handle_tun_input(reply, now).unwrap()?;

        Some(transmit)
    }
}

/// Reference state for a particular gateway.
#[derive(Debug, Clone)]
pub struct RefGateway {
    pub(crate) key: PrivateKey,
    pub(crate) tunnel_ip4: Ipv4Addr,
    pub(crate) tunnel_ip6: Ipv6Addr,

    site_specific_dns_records: DnsRecords,
}

impl RefGateway {
    /// Initialize the [`GatewayState`].
    ///
    /// This simulates receiving the `init` message from the portal.
    pub(crate) fn init(
        self,
        id: GatewayId,
        tcp_resources: BTreeSet<SocketAddr>,
        now: Instant,
        utc_now: DateTime<Utc>,
    ) -> SimGateway {
        let mut sut = GatewayState::new(
            false,
            self.key.0,
            now,
            utc_now
                .signed_duration_since(DateTime::UNIX_EPOCH)
                .to_std()
                .unwrap(),
        ); // Cheating a bit here by reusing the key as seed.
        sut.update_tun_device(IpConfig {
            v4: self.tunnel_ip4,
            v6: self.tunnel_ip6,
        });

        SimGateway::new(id, sut, tcp_resources, self.site_specific_dns_records, now)
    }

    pub fn dns_records(&self) -> &DnsRecords {
        &self.site_specific_dns_records
    }
}

pub(crate) fn ref_gateway_host(
    tunnel_ip4s: impl Strategy<Value = Ipv4Addr>,
    tunnel_ip6s: impl Strategy<Value = Ipv6Addr>,
    site_specific_dns_records: impl Strategy<Value = DnsRecords>,
) -> impl Strategy<Value = Host<RefGateway>> {
    host(
        dual_ip_stack(),
        Just(52625),
        ref_gateway(tunnel_ip4s, tunnel_ip6s, site_specific_dns_records),
        latency(200), // We assume gateways have a somewhat decent Internet connection.
    )
}

fn ref_gateway(
    tunnel_ip4s: impl Strategy<Value = Ipv4Addr>,
    tunnel_ip6s: impl Strategy<Value = Ipv6Addr>,
    site_specific_dns_records: impl Strategy<Value = DnsRecords>,
) -> impl Strategy<Value = RefGateway> {
    (
        private_key(),
        tunnel_ip4s,
        tunnel_ip6s,
        site_specific_dns_records,
    )
        .prop_map(
            move |(key, tunnel_ip4, tunnel_ip6, site_specific_dns_records)| RefGateway {
                key,
                tunnel_ip4,
                tunnel_ip6,
                site_specific_dns_records,
            },
        )
}

fn icmp_error_reply(packet: &IpPacket, error: IcmpError) -> Result<IpPacket> {
    use ip_packet::{icmpv4, icmpv6};

    // We are sending a reply, so flip `src` and `dst`.
    let src = packet.destination();
    let dst = packet.source();
    let payload = packet.packet(); // The original packet goes in the ICMP error payload.

    match (src, dst) {
        (IpAddr::V4(src), IpAddr::V4(dst)) => {
            let icmpv4 = ip_packet::PacketBuilder::ipv4(src.octets(), dst.octets(), 20).icmpv4(
                match error {
                    IcmpError::Network => {
                        Icmpv4Type::DestinationUnreachable(icmpv4::DestUnreachableHeader::Network)
                    }
                    IcmpError::Host => {
                        Icmpv4Type::DestinationUnreachable(icmpv4::DestUnreachableHeader::Host)
                    }
                    IcmpError::Port => {
                        Icmpv4Type::DestinationUnreachable(icmpv4::DestUnreachableHeader::Port)
                    }
                    IcmpError::PacketTooBig { mtu } => Icmpv4Type::DestinationUnreachable(
                        icmpv4::DestUnreachableHeader::FragmentationNeeded {
                            next_hop_mtu: u16::try_from(mtu).unwrap_or(u16::MAX),
                        },
                    ),
                    IcmpError::TimeExceeded { code } => {
                        Icmpv4Type::TimeExceeded(icmpv4::TimeExceededCode::from_u8(code).unwrap())
                    }
                },
            );

            ip_packet::build!(icmpv4, payload)
        }
        (IpAddr::V6(src), IpAddr::V6(dst)) => {
            let icmpv6 = ip_packet::PacketBuilder::ipv6(src.octets(), dst.octets(), 20).icmpv6(
                match error {
                    IcmpError::Network => {
                        Icmpv6Type::DestinationUnreachable(icmpv6::DestUnreachableCode::NoRoute)
                    }
                    IcmpError::Host => {
                        Icmpv6Type::DestinationUnreachable(icmpv6::DestUnreachableCode::NoRoute)
                    }
                    IcmpError::Port => {
                        Icmpv6Type::DestinationUnreachable(icmpv6::DestUnreachableCode::Port)
                    }
                    IcmpError::PacketTooBig { mtu } => Icmpv6Type::PacketTooBig { mtu },
                    IcmpError::TimeExceeded { code } => {
                        Icmpv6Type::TimeExceeded(icmpv6::TimeExceededCode::from_u8(code).unwrap())
                    }
                },
            );

            ip_packet::build!(icmpv6, payload)
        }
        (IpAddr::V6(_), IpAddr::V4(_)) | (IpAddr::V4(_), IpAddr::V6(_)) => {
            bail!("Invalid IP combination")
        }
    }
}

fn echo_reply(mut req: IpPacket) -> Option<IpPacket> {
    if !req.is_udp() && !req.is_tcp() {
        return None;
    }

    if let Some(mut packet) = req.as_tcp_mut() {
        let original_src = packet.get_source_port();
        let original_dst = packet.get_destination_port();

        packet.set_source_port(original_dst);
        packet.set_destination_port(original_src);
    }

    if let Some(mut packet) = req.as_udp_mut() {
        let original_src = packet.get_source_port();
        let original_dst = packet.get_destination_port();

        packet.set_source_port(original_dst);
        packet.set_destination_port(original_src);
    }

    let original_src = req.source();
    let original_dst = req.destination();

    req.set_dst(original_src).unwrap();
    req.set_src(original_dst).unwrap();

    Some(req)
}
