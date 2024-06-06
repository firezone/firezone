use connlib_shared::{
    messages::{
        client::{ResourceDescriptionCidr, ResourceDescriptionDns, SiteId},
        ClientId, DnsServer, GatewayId, RelayId, ResourceId,
    },
    DomainName,
};
use firezone_relay::{AddressFamily, AllocationPort, ClientSocket, PeerSocket};
use hickory_proto::rr::RecordType;
use ip_network_table::IpNetworkTable;
use proptest::{sample, test_runner::Config};
use rand::rngs::StdRng;
use snownet::{RelaySocket, Transmit};
use std::{
    borrow::Cow,
    collections::{HashMap, HashSet, VecDeque},
    fmt,
    net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr, SocketAddrV4, SocketAddrV6},
    str::FromStr,
    time::{Duration, Instant, SystemTime},
};
use tracing::Span;

mod assertions;
mod reference;
mod strategies;
mod sut;

use assertions::*;
use reference::*;
use sut::*;

proptest_state_machine::prop_state_machine! {
    #![proptest_config(Config {
        cases: 1000,
        .. Config::default()
    })]

    #[test]
    fn run_tunnel_test(sequential 1..20 => TunnelTest);
}

type QueryId = u16;
type IcmpSeq = u16;
type IcmpIdentifier = u16;

/// The possible transitions of the state machine.
#[derive(Clone, Debug)]
pub(crate) enum Transition {
    /// Add a new CIDR resource to the client.
    AddCidrResource(ResourceDescriptionCidr),
    /// Send an ICMP packet to non-resource IP.
    SendICMPPacketToNonResourceIp {
        dst: IpAddr,
        seq: u16,
        identifier: u16,
    },
    /// Send an ICMP packet to an IP we resolved via DNS but is not a resource.
    SendICMPPacketToResolvedNonResourceIp {
        idx: sample::Index,
        seq: u16,
        identifier: u16,
    },
    /// Send an ICMP packet to a resource.
    SendICMPPacketToResource {
        idx: sample::Index,
        seq: u16,
        identifier: u16,
        src: PacketSource,
    },

    /// Add a new DNS resource to the client.
    AddDnsResource {
        resource: ResourceDescriptionDns,
        /// The DNS records to add together with the resource.
        records: HashMap<DomainName, HashSet<IpAddr>>,
    },
    /// Send a DNS query.
    SendDnsQuery {
        /// The index into the list of global DNS names (includes all DNS resources).
        r_idx: sample::Index,
        /// The type of DNS query we should send.
        r_type: RecordType,
        /// The DNS query ID.
        query_id: u16,
        /// The index into our list of DNS servers.
        dns_server_idx: sample::Index,
    },

    /// The system's DNS servers changed.
    UpdateSystemDnsServers { servers: Vec<IpAddr> },
    /// The upstream DNS servers changed.
    UpdateUpstreamDnsServers { servers: Vec<DnsServer> },

    /// Advance time by this many milliseconds.
    Tick { millis: u64 },
}

/// The source of the packet that should be sent through the tunnel.
///
/// In normal operation, this will always be either the tunnel's IPv4 or IPv6 address.
/// A malicious client could send packets with a mangled IP but those must be dropped by gateway.
/// To test this case, we also sometimes send packest from a different IP.
#[derive(Debug, Clone, Copy)]
pub(crate) enum PacketSource {
    TunnelIp4,
    TunnelIp6,
    Other(IpAddr),
}

impl PacketSource {
    fn into_ip(self, tunnel_v4: Ipv4Addr, tunnel_v6: Ipv6Addr) -> IpAddr {
        match self {
            PacketSource::TunnelIp4 => tunnel_v4.into(),
            PacketSource::TunnelIp6 => tunnel_v6.into(),
            PacketSource::Other(ip) => ip,
        }
    }

    fn originates_from_client(&self) -> bool {
        matches!(self, PacketSource::TunnelIp4 | PacketSource::TunnelIp6)
    }

    fn is_ipv4(&self) -> bool {
        matches!(
            self,
            PacketSource::TunnelIp4 | PacketSource::Other(IpAddr::V4(_))
        )
    }

    fn is_ipv6(&self) -> bool {
        matches!(
            self,
            PacketSource::TunnelIp6 | PacketSource::Other(IpAddr::V6(_))
        )
    }
}

#[derive(Debug, Clone)]
enum ResourceDst {
    Cidr(IpAddr),
    Dns(DomainName),
}

impl ResourceDst {
    /// Translates a randomly sampled [`ResourceDst`] into the [`IpAddr`] to be used for the packet.
    ///
    /// For CIDR resources, we use the IP directly.
    /// For DNS resources, we need to pick any of the proxy IPs that connlib gave us for the domain name.
    fn into_actual_packet_dst(
        self,
        idx: sample::Index,
        src: PacketSource,
        client_dns_records: &HashMap<DomainName, Vec<IpAddr>>,
    ) -> IpAddr {
        match self {
            ResourceDst::Cidr(ip) => ip,
            ResourceDst::Dns(domain) => {
                let mut ips = client_dns_records
                    .get(&domain)
                    .expect("DNS records to contain domain name")
                    .clone();

                ips.retain(|ip| ip.is_ipv4() == src.is_ipv4());

                *idx.get(&ips)
            }
        }
    }
}

#[derive(Clone)]
struct SimNode<ID, S> {
    id: ID,
    state: S,

    ip4_socket: Option<SocketAddrV4>,
    ip6_socket: Option<SocketAddrV6>,

    tunnel_ip4: Ipv4Addr,
    tunnel_ip6: Ipv6Addr,

    span: Span,
}

#[derive(Clone)]
struct SimRelay<S> {
    id: RelayId,
    state: S,

    ip_stack: firezone_relay::IpStack,
    allocations: HashSet<(AddressFamily, AllocationPort)>,
    buffer: Vec<u8>,

    span: Span,
}

/// Stub implementation of the portal.
///
/// Currently, we only simulate a connection between a single client and a single gateway on a single site.
#[derive(Debug, Clone)]
struct SimPortal {
    _client: ClientId,
    gateway: GatewayId,
    _relay: RelayId,
}

impl<ID, S> SimNode<ID, S>
where
    ID: Copy,
    S: Copy,
{
    fn map_state<T>(&self, f: impl FnOnce(S) -> T, span: Span) -> SimNode<ID, T> {
        SimNode {
            id: self.id,
            state: f(self.state),
            ip4_socket: self.ip4_socket,
            ip6_socket: self.ip6_socket,
            tunnel_ip4: self.tunnel_ip4,
            tunnel_ip6: self.tunnel_ip6,
            span,
        }
    }
}

impl<ID, S> SimNode<ID, S> {
    fn wants(&self, dst: SocketAddr) -> bool {
        self.ip4_socket.is_some_and(|s| SocketAddr::V4(s) == dst)
            || self.ip6_socket.is_some_and(|s| SocketAddr::V6(s) == dst)
    }

    fn sending_socket_for(&self, dst: impl Into<IpAddr>) -> Option<SocketAddr> {
        Some(match dst.into() {
            IpAddr::V4(_) => self.ip4_socket?.into(),
            IpAddr::V6(_) => self.ip6_socket?.into(),
        })
    }

    fn tunnel_ip(&self, dst: impl Into<IpAddr>) -> IpAddr {
        match dst.into() {
            IpAddr::V4(_) => IpAddr::from(self.tunnel_ip4),
            IpAddr::V6(_) => IpAddr::from(self.tunnel_ip6),
        }
    }
}

impl SimRelay<firezone_relay::Server<StdRng>> {
    fn wants(&self, dst: SocketAddr) -> bool {
        let is_direct = self.matching_listen_socket(dst).is_some_and(|s| s == dst);
        let is_allocation_port = self.allocations.contains(&match dst {
            SocketAddr::V4(_) => (AddressFamily::V4, AllocationPort::new(dst.port())),
            SocketAddr::V6(_) => (AddressFamily::V6, AllocationPort::new(dst.port())),
        });
        let is_allocation_ip = self
            .matching_listen_socket(dst)
            .is_some_and(|s| s.ip() == dst.ip());

        is_direct || (is_allocation_port && is_allocation_ip)
    }

    fn sending_socket_for(&self, dst: SocketAddr, port: u16) -> Option<SocketAddr> {
        Some(match dst {
            SocketAddr::V4(_) => SocketAddr::V4(SocketAddrV4::new(*self.ip_stack.as_v4()?, port)),
            SocketAddr::V6(_) => {
                SocketAddr::V6(SocketAddrV6::new(*self.ip_stack.as_v6()?, port, 0, 0))
            }
        })
    }

    fn explode(&self, username: &str) -> (RelayId, RelaySocket, String, String, String) {
        let relay_socket = match self.ip_stack {
            firezone_relay::IpStack::Ip4(ip4) => RelaySocket::V4(SocketAddrV4::new(ip4, 3478)),
            firezone_relay::IpStack::Ip6(ip6) => {
                RelaySocket::V6(SocketAddrV6::new(ip6, 3478, 0, 0))
            }
            firezone_relay::IpStack::Dual { ip4, ip6 } => RelaySocket::Dual {
                v4: SocketAddrV4::new(ip4, 3478),
                v6: SocketAddrV6::new(ip6, 3478, 0, 0),
            },
        };

        let (username, password) = self.make_credentials(username);

        (
            self.id,
            relay_socket,
            username,
            password,
            "firezone".to_owned(),
        )
    }

    fn matching_listen_socket(&self, other: SocketAddr) -> Option<SocketAddr> {
        match other {
            SocketAddr::V4(_) => Some(SocketAddr::new((*self.ip_stack.as_v4()?).into(), 3478)),
            SocketAddr::V6(_) => Some(SocketAddr::new((*self.ip_stack.as_v6()?).into(), 3478)),
        }
    }

    fn ip4(&self) -> Option<IpAddr> {
        self.ip_stack.as_v4().copied().map(|i| i.into())
    }

    fn ip6(&self) -> Option<IpAddr> {
        self.ip_stack.as_v6().copied().map(|i| i.into())
    }

    fn handle_packet(
        &mut self,
        payload: &[u8],
        sender: SocketAddr,
        dst: SocketAddr,
        now: Instant,
        buffered_transmits: &mut VecDeque<(Transmit<'static>, Option<SocketAddr>)>,
    ) {
        if self.matching_listen_socket(dst).is_some_and(|s| s == dst) {
            self.handle_client_input(payload, ClientSocket::new(sender), now, buffered_transmits);
            return;
        }

        self.handle_peer_traffic(
            payload,
            PeerSocket::new(sender),
            AllocationPort::new(dst.port()),
            buffered_transmits,
        )
    }

    fn handle_client_input(
        &mut self,
        payload: &[u8],
        client: ClientSocket,
        now: Instant,
        buffered_transmits: &mut VecDeque<(Transmit<'static>, Option<SocketAddr>)>,
    ) {
        if let Some((port, peer)) = self
            .span
            .in_scope(|| self.state.handle_client_input(payload, client, now))
        {
            let payload = &payload[4..];

            // The `dst` of the relayed packet is what TURN calls a "peer".
            let dst = peer.into_socket();

            // The `src_ip` is the relay's IP
            let src_ip = match dst {
                SocketAddr::V4(_) => {
                    assert!(
                        self.allocations.contains(&(AddressFamily::V4, port)),
                        "IPv4 allocation to be present if we want to send to an IPv4 socket"
                    );

                    self.ip4().expect("listen on IPv4 if we have an allocation")
                }
                SocketAddr::V6(_) => {
                    assert!(
                        self.allocations.contains(&(AddressFamily::V6, port)),
                        "IPv6 allocation to be present if we want to send to an IPv6 socket"
                    );

                    self.ip6().expect("listen on IPv6 if we have an allocation")
                }
            };

            // The `src` of the relayed packet is the relay itself _from_ the allocated port.
            let src = SocketAddr::new(src_ip, port.value());

            // Check if we need to relay to ourselves (from one allocation to another)
            if self.wants(dst) {
                // When relaying to ourselves, we become our own peer.
                let peer_socket = PeerSocket::new(src);
                // The allocation that the data is arriving on is the `dst`'s port.
                let allocation_port = AllocationPort::new(dst.port());

                self.handle_peer_traffic(payload, peer_socket, allocation_port, buffered_transmits);
                return;
            }

            buffered_transmits.push_back((
                Transmit {
                    src: Some(src),
                    dst,
                    payload: Cow::Owned(payload.to_vec()),
                },
                Some(src),
            ));
        }
    }

    fn handle_peer_traffic(
        &mut self,
        payload: &[u8],
        peer: PeerSocket,
        port: AllocationPort,
        buffered_transmits: &mut VecDeque<(Transmit<'static>, Option<SocketAddr>)>,
    ) {
        if let Some((client, channel)) = self
            .span
            .in_scope(|| self.state.handle_peer_traffic(payload, peer, port))
        {
            let full_length = firezone_relay::ChannelData::encode_header_to_slice(
                channel,
                payload.len() as u16,
                &mut self.buffer[..4],
            );
            self.buffer[4..full_length].copy_from_slice(payload);

            let receiving_socket = client.into_socket();
            let sending_socket = self.matching_listen_socket(receiving_socket).unwrap();

            buffered_transmits.push_back((
                Transmit {
                    src: Some(sending_socket),
                    dst: receiving_socket,
                    payload: Cow::Owned(self.buffer[..full_length].to_vec()),
                },
                Some(sending_socket),
            ));
        }
    }

    fn make_credentials(&self, username: &str) -> (String, String) {
        let expiry = SystemTime::now() + Duration::from_secs(60);

        let secs = expiry
            .duration_since(SystemTime::UNIX_EPOCH)
            .expect("expiry must be later than UNIX_EPOCH")
            .as_secs();

        let password =
            firezone_relay::auth::generate_password(self.state.auth_secret(), expiry, username);

        (format!("{secs}:{username}"), password)
    }
}

impl SimPortal {
    /// Picks, which gateway and site we should connect to for the given resource.
    fn handle_connection_intent(
        &self,
        resource: ResourceId,
        _connected_gateway_ids: HashSet<GatewayId>,
        client_cidr_resources: &IpNetworkTable<ResourceDescriptionCidr>,
        client_dns_resources: &HashMap<ResourceId, ResourceDescriptionDns>,
    ) -> (GatewayId, SiteId) {
        // TODO: Should we somehow vary how many gateways we connect to?
        // TODO: Should we somehow pick, which site to use?

        let cidr_site = client_cidr_resources
            .iter()
            .find_map(|(_, r)| (r.id == resource).then_some(r.sites.first()?.id));

        let dns_site = client_dns_resources
            .get(&resource)
            .and_then(|r| Some(r.sites.first()?.id));

        (
            self.gateway,
            cidr_site
                .or(dns_site)
                .expect("resource to be a known CIDR or DNS resource"),
        )
    }
}

impl<ID: fmt::Debug, S: fmt::Debug> fmt::Debug for SimNode<ID, S> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("SimNode")
            .field("id", &self.id)
            .field("state", &self.state)
            .field("ip4_socket", &self.ip4_socket)
            .field("ip6_socket", &self.ip6_socket)
            .field("tunnel_ip4", &self.tunnel_ip4)
            .field("tunnel_ip6", &self.tunnel_ip6)
            .finish()
    }
}

impl<S: fmt::Debug> fmt::Debug for SimRelay<S> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("SimRelay")
            .field("id", &self.id)
            .field("ip_stack", &self.ip_stack)
            .field("allocations", &self.allocations)
            .finish()
    }
}

#[derive(Clone, Copy, PartialEq)]
struct PrivateKey([u8; 32]);

impl fmt::Debug for PrivateKey {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_tuple("PrivateKey")
            .field(&hex::encode(self.0))
            .finish()
    }
}

fn hickory_name_to_domain(mut name: hickory_proto::rr::Name) -> DomainName {
    name.set_fqdn(false); // Hack to work around hickory always parsing as FQ
    let name = name.to_string();

    let domain = DomainName::from_chars(name.chars()).unwrap();
    debug_assert_eq!(name, domain.to_string());

    domain
}

fn domain_to_hickory_name(domain: DomainName) -> hickory_proto::rr::Name {
    let domain = domain.to_string();

    let name = hickory_proto::rr::Name::from_str(&domain).unwrap();
    debug_assert_eq!(name.to_string(), domain);

    name
}
