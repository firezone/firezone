use crate::{
    dns_records::DnsRecords,
    dns_server_resource::{DnsServers, is_dns_query},
    echo::echo_reply,
    tcp,
};
use anyhow::{Result, bail};
use dns_types::DomainName;
use ip_network::IpNetwork;
use ip_network_table::IpNetworkTable;
use ip_packet::{IcmpEchoHeader, Icmpv4Type, Icmpv6Type, IpPacket};
use std::{
    collections::{BTreeMap, BTreeSet},
    iter,
    net::{IpAddr, SocketAddr},
    time::Instant,
};

/// The routing table of the network behind a site's Gateways.
#[derive(Debug, Clone)]
pub(crate) struct Routes {
    table: IpNetworkTable<RouteType>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub(crate) enum RouteType {
    /// Delivers packets to the host at their destination.
    Deliver,
    /// Answers packets with an ICMP error.
    Unreachable(IcmpError),
    /// Drops packets silently.
    Blackhole,
}

impl Routes {
    pub(crate) fn new(routes: impl IntoIterator<Item = (IpNetwork, RouteType)>) -> Self {
        let mut table = IpNetworkTable::new();
        for (network, route) in routes {
            table.insert(network, route);
        }

        Self { table }
    }

    /// Returns the type of the most specific route to `dst`.
    pub(crate) fn route(&self, dst: IpAddr) -> RouteType {
        let (_, route) = self
            .table
            .longest_match(dst)
            .expect("default routes match every address");

        *route
    }

    pub(crate) fn delivers(&self, dst: IpAddr) -> bool {
        self.route(dst) == RouteType::Deliver
    }
}

/// The network a Gateway forwards to, with the hosts its routes deliver to.
pub(crate) struct SiteNetwork {
    routes: Routes,

    dns_servers: DnsServers,
    /// The TCP resources that probes try to reach, one server per `(domain, port)`.
    ///
    /// Each serves every address the Gateway resolved its domain to.
    tcp_services: BTreeMap<(DomainName, u16), tcp::Server>,
    /// Answers TCP to any address without a TCP server with a reset.
    closed_tcp_ports: tcp::Server,
}

/// What became of a packet sent into a [`SiteNetwork`].
#[derive(Default)]
pub(crate) struct Delivery {
    /// Whether the packet counts as a received request.
    pub(crate) request_received: bool,
    pub(crate) reply: Option<IpPacket>,
}

impl SiteNetwork {
    pub(crate) fn new(
        routes: Routes,
        tcp_services: BTreeMap<DomainName, BTreeSet<u16>>,
        now: Instant,
    ) -> Self {
        let tcp_services = tcp_services
            .into_iter()
            .flat_map(|(domain, ports)| ports.into_iter().map(move |port| (domain.clone(), port)))
            .map(|(domain, port)| {
                let mut server = tcp::Server::new(now);
                if let Err(e) = server.listen(port) {
                    tracing::error!(%domain, %port, "Failed to listen: {e}")
                }

                ((domain, port), server)
            })
            .collect();

        Self {
            routes,
            dns_servers: DnsServers::default(),
            tcp_services,
            closed_tcp_ports: tcp::Server::new(now),
        }
    }

    pub(crate) fn deploy_dns_servers(&mut self, servers: impl IntoIterator<Item = SocketAddr>) {
        self.dns_servers.clear();

        for server in servers {
            // Nothing listens on a resolver that is unreachable.
            if !self.routes.delivers(server.ip()) {
                continue;
            }

            self.dns_servers.deploy(server);
        }
    }

    /// Routes `packet` to its destination.
    ///
    /// `resolved_to` tells whether the Gateway resolved a domain to an address.
    pub(crate) fn deliver(
        &mut self,
        packet: IpPacket,
        resolved_to: impl Fn(&DomainName, IpAddr) -> bool,
        now: Instant,
    ) -> Delivery {
        let dst_ip = packet.destination();

        let icmp_error = match self.routes.route(dst_ip) {
            RouteType::Deliver => None,
            RouteType::Unreachable(error) => Some(icmp_error_reply(&packet, error).unwrap()),
            RouteType::Blackhole => {
                return Delivery {
                    request_received: is_echo_request(&packet)
                        || packet.as_udp().is_some_and(|udp| {
                            !(is_dns_query(&udp) && udp.destination_port() == 53)
                        }),
                    reply: None,
                };
            }
        };

        if let Some(icmp) = packet.as_icmpv4()
            && let Icmpv4Type::EchoRequest(echo) = icmp.icmp_type()
        {
            return Delivery {
                request_received: true,
                reply: Some(
                    icmp_error.unwrap_or_else(|| icmp_echo_reply(&packet, echo, icmp.payload())),
                ),
            };
        }

        if let Some(icmp) = packet.as_icmpv6()
            && let Icmpv6Type::EchoRequest(echo) = icmp.icmp_type()
        {
            return Delivery {
                request_received: true,
                reply: Some(
                    icmp_error.unwrap_or_else(|| icmp_echo_reply(&packet, echo, icmp.payload())),
                ),
            };
        }

        if let Some(server) = self.dns_servers.udp_server_for(&packet) {
            server.handle_input(packet);
            return Delivery::default();
        }

        // A recursive query to a resolver without a deployed DNS server
        // answers with an ICMP error. Connlib consumes this internally.
        if let Some(udp) = packet.as_udp()
            && is_dns_query(&udp)
            && udp.destination_port() == 53
        {
            return Delivery {
                request_received: false,
                reply: icmp_error,
            };
        }

        if let Some(tcp) = packet.as_tcp() {
            let socket = SocketAddr::new(dst_ip, tcp.destination_port());
            let remote = SocketAddr::new(packet.source(), tcp.source_port());

            if icmp_error.is_none()
                && let Some(server) = self.tcp_service_for(socket, remote, &resolved_to)
            {
                server.handle_inbound(packet.clone());

                return Delivery {
                    request_received: tcp.syn() && !tcp.ack(),
                    reply: None,
                };
            }

            // NOTE: we can make this assumption because port 53 is excluded from non-dns query packets
            if let Some(server) = self.dns_servers.tcp_server_for(&packet) {
                server.handle_input(packet, now);
                return Delivery::default();
            }

            if icmp_error.is_none() {
                self.closed_tcp_ports.handle_inbound(packet);
                return Delivery::default();
            }
        }

        let request_received = packet.as_udp().is_some();
        let Some(reply) = icmp_error.or_else(|| echo_reply(packet.clone())) else {
            tracing::error!(?packet, "Unhandled packet");
            return Delivery::default();
        };

        Delivery {
            request_received,
            reply: Some(reply),
        }
    }

    /// Answers the DNS queries received so far.
    pub(crate) fn poll_dns_answers(
        &mut self,
        global_dns_records: &DnsRecords,
        now: Instant,
    ) -> Vec<IpPacket> {
        self.dns_servers.poll_answers(global_dns_records, now)
    }

    pub(crate) fn poll_tcp_servers(&mut self, now: Instant) -> Vec<IpPacket> {
        self.tcp_services
            .values_mut()
            .chain([&mut self.closed_tcp_ports])
            .flat_map(|server| {
                server.handle_timeout(now);

                iter::from_fn(|| server.poll_outbound())
            })
            .collect()
    }

    pub(crate) fn drop_unfinished_tcp_connections(&mut self) {
        for server in self.tcp_services.values_mut() {
            server.drop_unfinished();
        }
    }

    /// Returns the server of the connection between `local` and `remote`, or else the server
    /// of a domain the Gateway resolved to `local`'s IP that serves `local`'s port.
    ///
    /// A host keeps serving after its domain points elsewhere: a Gateway translates to the
    /// addresses it last resolved until the Client re-resolves the domain.
    fn tcp_service_for(
        &mut self,
        local: SocketAddr,
        remote: SocketAddr,
        resolved_to: impl Fn(&DomainName, IpAddr) -> bool,
    ) -> Option<&mut tcp::Server> {
        let key = self
            .tcp_services
            .iter()
            .find(|(_, server)| server.is_established(local, remote))
            .or_else(|| {
                self.tcp_services.iter().find(|((domain, port), _)| {
                    *port == local.port() && resolved_to(domain, local.ip())
                })
            })
            .map(|(key, _)| key.clone())?;

        self.tcp_services.get_mut(&key)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub(crate) enum IcmpError {
    Network,
    Host,
    Port,
    PacketTooBig { mtu: u32 },
    TimeExceeded { code: u8 },
}

fn is_echo_request(packet: &IpPacket) -> bool {
    packet
        .as_icmpv4()
        .is_some_and(|icmp| matches!(icmp.icmp_type(), Icmpv4Type::EchoRequest(_)))
        || packet
            .as_icmpv6()
            .is_some_and(|icmp| matches!(icmp.icmp_type(), Icmpv6Type::EchoRequest(_)))
}

fn icmp_echo_reply(packet: &IpPacket, echo: IcmpEchoHeader, payload: &[u8]) -> IpPacket {
    ip_packet::make::icmp_reply_packet(
        packet.destination(),
        packet.source(),
        echo.seq,
        echo.id,
        payload,
    )
    .expect("src and dst are taken from incoming packet")
}

pub(crate) fn icmp_error_reply(packet: &IpPacket, error: IcmpError) -> Result<IpPacket> {
    use ip_packet::{icmpv4, icmpv6};

    // An ICMP error quotes the offending datagram but must itself fit into the minimum
    // MTU (RFC 4443), leaving room for an IPv6 header and the ICMP header.
    const MAX_QUOTED_LEN: usize = ip_packet::MAX_IP_SIZE - 40 - 8;

    let src = packet.destination();
    let dst = packet.source();
    let quoted = packet.packet();
    let payload = &quoted[..quoted.len().min(MAX_QUOTED_LEN)];

    let reply = match (src, dst) {
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

            ip_packet::make::icmpv4_packet(src, dst, 20, icmp_type, payload)?
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

            ip_packet::make::icmpv6_packet(src, dst, 20, icmp_type, payload)?
        }
        (IpAddr::V6(_), IpAddr::V4(_)) => bail!("Invalid IP combination"),
        (IpAddr::V4(_), IpAddr::V6(_)) => bail!("Invalid IP combination"),
    };

    Ok(reply)
}
