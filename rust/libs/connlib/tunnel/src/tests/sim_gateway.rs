use super::{
    dns_records::DnsRecords,
    dns_server_resource::{TcpDnsServerResource, UdpDnsServerResource},
    echo::echo_reply,
    icmp_error_hosts::{IcmpError, IcmpErrorHosts},
    sim_net::{ExecMutScope, Host},
    sim_relay::{SimRelay, map_explode},
};
use crate::GatewayState;
use anyhow::{Result, bail};
use connlib_model::{GatewayId, RelayId};
use dns_types::DomainName;
use ip_packet::{IcmpEchoHeader, Icmpv4Type, Icmpv6Type, IpPacket};
use snownet::Transmit;
use std::{
    collections::{BTreeMap, BTreeSet},
    iter,
    net::{IpAddr, SocketAddr},
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

    /// Collects datagrams encapsulated via [`GatewayState::handle_tun_input`].
    transmit_buffer: snownet::TransmitBuffer,
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
            transmit_buffer: snownet::TransmitBuffer::new(),
        }
    }

    pub(crate) fn receive(
        &mut self,
        transmit: Transmit,
        icmp_error_hosts: &IcmpErrorHosts,
        now: Instant,
    ) -> Option<Transmit> {
        let Some(packet) = self
            .sut
            .handle_network_input(transmit.dst, transmit.src.unwrap(), &transmit.payload, now)
            .inspect_err(|e| tracing::warn!("{e:#}"))
            .ok()
            .flatten()
        else {
            self.sut.handle_timeout(now);
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

        // Collect first to end the mutable borrows of the resource maps before encapsulating.
        let packets = udp_server_packets
            .chain(tcp_server_packets)
            .chain(tcp_resource_packets)
            .collect::<Vec<_>>();

        packets
            .into_iter()
            .filter_map(|packet| match self.handle_tun_input(packet, now) {
                Ok(maybe_transmit) => maybe_transmit,
                // The gateway could not encrypt the packet (e.g. no session during a re-key). In
                // production this error bubbles up to the event loop and the packet is dropped;
                // model that as a drop here rather than panicking.
                Err(e) => {
                    tracing::debug!("Gateway failed to encapsulate resource packet: {e:#}");
                    None
                }
            })
            .collect()
    }

    /// Drive the SUT's TUN -> network path, collecting the encapsulated datagram (if any).
    ///
    /// Routes encapsulation through the [`snownet::TransmitBuffer`] field so the rest of the
    /// simulation can keep working with a single [`snownet::Transmit`] per packet.
    fn handle_tun_input(
        &mut self,
        packet: IpPacket,
        now: Instant,
    ) -> anyhow::Result<Option<snownet::Transmit>> {
        self.sut
            .handle_tun_input(packet, now, &mut self.transmit_buffer)?;

        Ok(self.transmit_buffer.poll_transmit())
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

    pub fn handle_timeout(&mut self, now: Instant) {
        if self.sut.poll_timeout().is_some_and(|(t, _)| t <= now) {
            self.sut.handle_timeout(now)
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
            let transmit = self.handle_tun_input(reply, now).unwrap()?;

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

    pub(crate) fn clear_packets(&mut self) {
        self.received_icmp_requests.clear();
        self.received_udp_requests.clear();
        self.tcp_resources.clear();
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

        let transmit = self.handle_tun_input(reply, now).unwrap()?;

        Some(transmit)
    }
}

impl ExecMutScope for SimGateway {
    type Guard = ();

    fn enter(&self) -> Self::Guard {}
}

fn icmp_error_reply(packet: &IpPacket, error: IcmpError) -> Result<IpPacket> {
    use ip_packet::{icmpv4, icmpv6};

    // We are sending a reply, so flip `src` and `dst`.
    let src = packet.destination();
    let dst = packet.source();
    let payload = packet.packet(); // The original packet goes in the ICMP error payload.

    match (src, dst) {
        (IpAddr::V4(src), IpAddr::V4(dst)) => {
            let icmp_type = match error {
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
                    Icmpv4Type::TimeExceeded(icmpv4::TimeExceededCode(code))
                }
            };

            ip_packet::make::icmpv4_packet(src, dst, 20, icmp_type, payload)
        }
        (IpAddr::V6(src), IpAddr::V6(dst)) => {
            let icmp_type = match error {
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
                    Icmpv6Type::TimeExceeded(icmpv6::TimeExceededCode(code))
                }
            };

            ip_packet::make::icmpv6_packet(src, dst, 20, icmp_type, payload)
        }
        (IpAddr::V6(_), IpAddr::V4(_)) | (IpAddr::V4(_), IpAddr::V6(_)) => {
            bail!("Invalid IP combination")
        }
    }
}
