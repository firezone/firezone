//! Clients and a Gateway connected in-process, through a TURN relay run by its sans-IO state.

#![allow(clippy::unwrap_used, clippy::wildcard_enum_match_arm)]

use std::collections::BTreeSet;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr, SocketAddrV4};
use std::ops::RangeInclusive;
use std::sync::LazyLock;
use std::time::{Duration, Instant, SystemTime};

use connlib_model::{ClientId, GatewayId, RelayId, ResourceId, SiteId};
use dns_types::{Query, RecordType, Response};
use ip_packet::{Ecn, IpPacket};
use rand::{SeedableRng as _, rngs::StdRng};
use relay_proto::auth::AccountId;
use relay_proto::{AllocationPort, ChannelData, ClientSocket, Command, PeerSocket};
use snownet::RelaySocket;
use socket_factory::DatagramOut;
use tunnel::{ClientState, GatewayState};
use tunnel_proto::messages::{IceCredentials, IngestToken, Interface, Key, SecretKey, gateway};
use tunnel_proto::{ClientEvent, GatewayEvent, IpConfig};
use uuid::Uuid;

/// The size of the IP packets sent through the tunnel.
pub const SIZE: usize = 1280;

#[derive(Debug, Clone, Copy)]
pub enum Resource {
    Cidr,
    Dns,
}

pub const RESOURCES: [Resource; 2] = [Resource::Cidr, Resource::Dns];

/// How a Client and the Gateway find each other's socket.
#[derive(Debug, Clone, Copy)]
pub enum Connectivity {
    Ice,
    Iceless,
}

pub const CONNECTIVITIES: [Connectivity; 2] = [Connectivity::Ice, Connectivity::Iceless];

/// How often the handshake lets time pass, which is also the round-trip time.
const STEP: Duration = Duration::from_millis(100);

/// How often an idle connection sends a keepalive.
pub const KEEPALIVE: Duration = Duration::from_secs(25);

/// How often a connection renews its WireGuard session.
const REKEY: Duration = Duration::from_secs(120);

/// One side of an established connection.
pub struct Side {
    pub state: State,
    pub socket: SocketAddr,
    /// What this side reads from its TUN device.
    pub reads: IpPacket,
}

pub enum State {
    Client(ClientState),
    Gateway(GatewayState),
}

impl State {
    /// Returns `count` copies of `packet` encrypted for `dst`, in as few GSO batches as fit.
    pub fn encapsulate(
        &mut self,
        packet: &IpPacket,
        count: usize,
        now: Instant,
        dst: SocketAddr,
    ) -> Vec<DatagramOut> {
        let segments = (0..count)
            .map(|_| {
                let mut packet = packet.clone();
                let encapsulation = match self {
                    State::Client(client) => client.handle_tun_input(&mut packet, now),
                    State::Gateway(gateway) => gateway.handle_tun_input(&mut packet, now),
                };

                encapsulation
                    .unwrap()
                    .unwrap()
                    .encrypt(&packet)
                    .unwrap()
                    .payload
                    .to_vec()
            })
            .collect::<Vec<_>>();
        let segment_size = segments[0].len();

        segments
            .chunks(DatagramOut::max_len(dst, segment_size) / segment_size)
            .map(|segments| {
                let mut packet = bufferpool::Bytes::fitting(64 * 1024);
                for segment in segments {
                    packet.extend_from_slice(segment);
                }

                DatagramOut {
                    src: None,
                    dst,
                    packet,
                    segment_size,
                    ecn: Ecn::NonEct,
                }
            })
            .collect()
    }
}

/// Returns both sides of a connection, through which the Client may reach `resource`.
pub fn connect(resource: Resource, flow_logs: bool) -> (Side, Side, Instant) {
    let mut tunnel = Tunnel::established(1, Connectivity::Ice, resource, flow_logs);
    let reply = tunnel.reply();
    let client = tunnel.clients.remove(0);

    let client = Side {
        socket: client_socket(client.index),
        reads: client.request(),
        state: State::Client(client.state),
    };
    let gateway = Side {
        state: State::Gateway(tunnel.gateway),
        socket: *GATEWAY_SOCKET,
        reads: reply,
    };

    (client, gateway, tunnel.now)
}

/// The port of the first Client's socket; each further Client takes the next one.
const CLIENT_PORT: u16 = 1111;
pub static GATEWAY_SOCKET: LazyLock<SocketAddr> =
    LazyLock::new(|| SocketAddr::new(*LOCAL_IP, 2222));

/// Returns the socket of the Client with the given index.
///
/// Only the first Client's socket gets bound, by the packet benchmarks. The others need an address
/// each, as the Gateway rate-limits handshakes per source address.
pub fn client_socket(index: usize) -> SocketAddr {
    let ip = match index {
        0 => *LOCAL_IP,
        _ => {
            Ipv4Addr::from(u32::from(Ipv4Addr::new(198, 18, 0, 0)) + u32::try_from(index).unwrap())
                .into()
        }
    };

    SocketAddr::new(ip, CLIENT_PORT + u16::try_from(index).unwrap())
}

/// Returns the index of the Client with the socket `socket`, if any.
pub fn client_index(socket: SocketAddr) -> Option<usize> {
    socket.port().checked_sub(CLIENT_PORT).map(usize::from)
}

/// The IP address to bind the Client's and Gateway's sockets to.
///
/// On macOS, that is the host's primary non-loopback address, falling back to loopback without
/// one. Packets to any local address travel over the loopback interface either way, but NECP
/// decides by address: a loopback address takes a bypass that looks up an entitlement on every
/// datagram, which no real interface pays for, and which hides the policy evaluation they do pay.
static LOCAL_IP: LazyLock<IpAddr> = LazyLock::new(local_ip);

fn local_ip() -> IpAddr {
    #[cfg(target_os = "macos")]
    {
        // Connecting a UDP socket sends nothing but makes the kernel pick the source address.
        let probe = std::net::UdpSocket::bind("0.0.0.0:0").unwrap();
        if probe.connect("192.0.2.1:9").is_ok()
            && let Ok(addr) = probe.local_addr()
            && !addr.ip().is_loopback()
            && !addr.ip().is_unspecified()
        {
            return addr.ip();
        }
    }

    Ipv4Addr::LOCALHOST.into()
}
const RELAY_SOCKET: SocketAddrV4 = SocketAddrV4::new(Ipv4Addr::new(10, 0, 0, 3), 3478);

/// The ports the relay allocates from.
const ALLOCATION_PORTS: RangeInclusive<u16> = 10_000..=19_999;

/// The first Client's TUN addresses; each further Client takes the next ones.
const CLIENT_TUN: IpConfig = IpConfig {
    v4: Ipv4Addr::new(100, 64, 0, 1),
    v6: Ipv6Addr::new(0xfd00, 0x2021, 0x1111, 0, 0, 0, 0, 1),
};
const GATEWAY_TUN: IpConfig = IpConfig {
    v4: Ipv4Addr::new(100, 64, 255, 254),
    v6: Ipv6Addr::new(0xfd00, 0x2021, 0x1111, 0, 0, 0, 0, 0xffff),
};

fn client_id(index: usize) -> ClientId {
    ClientId::from_u128(0x1000 + index as u128)
}

fn client_tun(index: usize) -> IpConfig {
    IpConfig {
        v4: Ipv4Addr::from(u32::from(CLIENT_TUN.v4) + u32::try_from(index).unwrap()),
        v6: Ipv6Addr::from(u128::from(CLIENT_TUN.v6) + index as u128),
    }
}

const GID: GatewayId = GatewayId::from_u128(2);
const SITE: SiteId = SiteId::from_u128(3);
const CIDR_RESOURCE: ResourceId = ResourceId::from_u128(4);
const DNS_RESOURCE: ResourceId = ResourceId::from_u128(5);

const CIDR_RESOURCE_IP: Ipv4Addr = Ipv4Addr::new(172, 16, 0, 1);
const DNS_RESOURCE_DOMAIN: &str = "app.example.com";
const DNS_RESOURCE_IP: Ipv4Addr = Ipv4Addr::new(172, 16, 1, 1);

impl std::fmt::Display for Resource {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Resource::Cidr => f.write_str("cidr"),
            Resource::Dns => f.write_str("dns"),
        }
    }
}

impl std::fmt::Display for Connectivity {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Connectivity::Ice => f.write_str("ice"),
            Connectivity::Iceless => f.write_str("iceless"),
        }
    }
}

impl Connectivity {
    fn iceless(self) -> bool {
        match self {
            Connectivity::Ice => false,
            Connectivity::Iceless => true,
        }
    }
}

impl Resource {
    fn id(self) -> ResourceId {
        match self {
            Resource::Cidr => CIDR_RESOURCE,
            Resource::Dns => DNS_RESOURCE,
        }
    }

    /// Returns the resource as the portal describes it to both the Client and the Gateway.
    fn description(self) -> serde_json::Value {
        let (kind, address) = match self {
            Resource::Cidr => ("cidr", "172.16.0.0/24"),
            Resource::Dns => ("dns", DNS_RESOURCE_DOMAIN),
        };

        serde_json::json!({
            "type": kind,
            "id": self.id(),
            "address": address,
            "name": kind,
            "filters": [],
            "sites": [{ "id": SITE, "name": "site" }],
        })
    }
}

/// Clients and a Gateway with an established connection each, through which the Clients may
/// reach the given resource.
pub struct Tunnel {
    pub clients: Vec<Client>,
    pub gateway: GatewayState,
    pub relay: Relay,
    pub now: Instant,
}

pub struct Client {
    index: usize,
    pub state: ClientState,
    /// Where it sends packets for the resource: its address or the DNS proxy IP.
    dst: IpAddr,
}

impl Tunnel {
    pub fn established(
        clients: usize,
        connectivity: Connectivity,
        resource: Resource,
        flow_logs: bool,
    ) -> Self {
        let now = Instant::now();
        let unix_ts = SystemTime::now()
            .duration_since(SystemTime::UNIX_EPOCH)
            .unwrap();
        let relay = Relay::new(now);

        let mut gateway = GatewayState::new([2; 32], now, unix_ts);
        gateway.set_flow_logs_enabled(flow_logs);
        gateway.update_tun_device(GATEWAY_TUN);
        gateway.update_relays(BTreeSet::new(), relay.description("gateway"), now);

        let clients = (0..clients)
            .map(|index| Client::new(index, resource, flow_logs, &relay, now, unix_ts))
            .collect();

        let mut tunnel = Self {
            clients,
            gateway,
            relay,
            now,
        };

        // A Gateway only signals candidates for a connection once it has a relay allocation.
        tunnel.run_until(now + Duration::from_secs(1), connectivity, resource);

        // Spread over a session, so the connections' keepalives and rekeys do not fire at once.
        let start = tunnel.now;
        let count = u32::try_from(tunnel.clients.len()).unwrap();
        for index in 0..tunnel.clients.len() {
            let at = start + REKEY * u32::try_from(index).unwrap() / count;
            tunnel.run_until(at, connectivity, resource);

            let client = &mut tunnel.clients[index];
            client
                .state
                .handle_tun_input(&mut client.request(), tunnel.now)
                .unwrap();
        }

        // Until the TURN allocations' retransmits and the connections' initial probing are done.
        tunnel.run_until(tunnel.now + Duration::from_secs(20), connectivity, resource);

        tunnel
    }

    /// Mirrors the first Client's request as the Gateway writes it to its TUN device.
    fn reply(&mut self) -> IpPacket {
        let client = &mut self.clients[0];
        let socket = client_socket(client.index);
        let mut request = client.request();
        let datagram = client
            .state
            .handle_tun_input(&mut request, self.now)
            .unwrap()
            .unwrap()
            .encrypt(&request)
            .unwrap();
        let decapsulation = self
            .gateway
            .handle_network_input(*GATEWAY_SOCKET, socket, &datagram.payload, self.now)
            .unwrap()
            .unwrap();
        let request = self
            .gateway
            .handle_peer_input(
                *GATEWAY_SOCKET,
                socket,
                decapsulation.decrypt(&datagram.payload),
                self.now,
            )
            .unwrap()
            .unwrap();
        let udp = request.as_udp().unwrap();
        let (sport, dport) = (udp.source_port(), udp.destination_port());

        packet(request.destination(), request.source(), dport, sport)
    }

    fn run_until(&mut self, until: Instant, connectivity: Connectivity, resource: Resource) {
        while self.now < until {
            self.step(connectivity, resource);
        }
    }

    /// Advances the time by [`STEP`], delivering what the Clients and the Gateway sent meanwhile.
    fn step(&mut self, connectivity: Connectivity, resource: Resource) {
        self.now += STEP;
        let now = self.now;

        for client in &mut self.clients {
            if client.state.poll_timeout().is_some_and(|t| t <= now) {
                client.state.handle_timeout(now);
            }
        }
        if self.gateway.poll_timeout().is_some_and(|t| t <= now) {
            self.gateway.handle_timeout(now);
        }

        for index in 0..self.clients.len() {
            while let Some(event) = self.clients[index].state.poll_event() {
                match event {
                    ClientEvent::RequestAccess { .. } => {
                        self.authorize(index, connectivity, resource)
                    }
                    ClientEvent::AddedIceCandidates { candidates, .. } => {
                        for candidate in candidates {
                            self.gateway
                                .add_ice_candidate(client_id(index), candidate, now);
                        }
                    }
                    _ => {}
                }
            }
        }
        while let Some(event) = self.gateway.poll_event() {
            match event {
                GatewayEvent::AddedIceCandidates {
                    conn_id,
                    candidates,
                } => {
                    let client = self
                        .clients
                        .iter_mut()
                        .find(|client| client_id(client.index) == conn_id)
                        .unwrap();
                    for candidate in candidates {
                        client.state.add_ice_candidate(GID, candidate, now);
                    }
                }
                GatewayEvent::ResolveDns(request) => {
                    self.gateway
                        .handle_domain_resolved(request, Ok(vec![DNS_RESOURCE_IP.into()]), now)
                        .unwrap();
                }
                _ => {}
            }
        }

        for index in 0..self.clients.len() {
            while let Some(transmit) = self.clients[index].state.poll_transmit() {
                self.deliver(client_socket(index), transmit.dst, &transmit.payload);
            }
        }
        while let Some(transmit) = self.gateway.poll_transmit() {
            self.deliver(*GATEWAY_SOCKET, transmit.dst, &transmit.payload);
        }
        for client in &mut self.clients {
            for _ in std::iter::from_fn(|| client.state.poll_packets()) {}
        }
    }

    fn authorize(&mut self, index: usize, connectivity: Connectivity, resource: Resource) {
        let client = &mut self.clients[index];
        let tun = client_tun(index);
        let preshared_key = || SecretKey::init_with(|| Key([3; 32]));
        let client_ice = IceCredentials {
            username: format!("client-{index}"),
            password: format!("client-password-{index}"),
        };
        let gateway_ice = IceCredentials {
            username: format!("gateway-{index}"),
            password: format!("gateway-password-{index}"),
        };

        self.gateway.create_authorization(
            gateway::Client {
                id: client_id(index),
                public_key: client.state.public_key().into(),
                preshared_key: preshared_key(),
                ipv4: tun.v4,
                ipv6: tun.v6,
            },
            client_ice.clone(),
            gateway_ice.clone(),
            None,
            serde_json::from_value(resource.description()).unwrap(),
            connectivity.iceless(),
            self.now,
            ingest_token(),
        );
        client
            .state
            .handle_resource_access_authorized(
                resource.id(),
                GID,
                self.gateway.public_key(),
                GATEWAY_TUN,
                SITE,
                preshared_key(),
                client_ice,
                gateway_ice,
                connectivity.iceless(),
                ingest_token(),
                self.now,
            )
            .unwrap();
    }

    fn deliver(&mut self, from: SocketAddr, to: SocketAddr, payload: &[u8]) {
        if self.relay.serves(to) {
            for (from, to, payload) in self.relay.handle(from, to, payload, self.now) {
                self.deliver(from, to, &payload);
            }

            return;
        }

        if to == *GATEWAY_SOCKET {
            if let Ok(Some(decapsulation)) = self
                .gateway
                .handle_network_input(to, from, payload, self.now)
            {
                let _ = self.gateway.handle_peer_input(
                    to,
                    from,
                    decapsulation.decrypt(payload),
                    self.now,
                );
            }

            return;
        }

        if let Some(client) = client_index(to).and_then(|index| self.clients.get_mut(index)) {
            receive(&mut client.state, to, from, payload, self.now);
        }
    }
}

/// Lets a Client handle a datagram that arrived on its socket `local`.
pub fn receive(
    client: &mut ClientState,
    local: SocketAddr,
    from: SocketAddr,
    payload: &[u8],
    now: Instant,
) {
    if let Ok(Some(decapsulation)) = client.handle_network_input(local, from, payload, now) {
        let _ = client.handle_peer_input(local, from, decapsulation.decrypt(payload), now);
    }
}

impl Client {
    fn new(
        index: usize,
        resource: Resource,
        flow_logs: bool,
        relay: &Relay,
        now: Instant,
        unix_ts: Duration,
    ) -> Self {
        let tun = client_tun(index);
        let mut key = [1; 32];
        key[..8].copy_from_slice(&(index as u64).to_be_bytes());

        let mut state = ClientState::new(key, BTreeSet::new(), false, now, unix_ts);
        state.set_flow_logs_enabled(flow_logs);
        state.update_interface_config(Interface {
            ipv4: tun.v4,
            ipv6: tun.v6,
            upstream_dns: Vec::new(),
            upstream_do53: Vec::new(),
            upstream_doh: Vec::new(),
            search_domain: None,
        });
        state.update_system_resolvers(vec![IpAddr::from([1, 1, 1, 1])]);
        let sentinel = std::iter::from_fn(|| state.poll_event())
            .find_map(|event| {
                let ClientEvent::TunInterfaceUpdated(config) = event else {
                    return None;
                };

                config.dns_by_sentinel.sentinel_ips().first().copied()
            })
            .unwrap();
        state.set_resources(
            vec![serde_json::from_value(resource.description()).unwrap()],
            now,
        );
        state.update_relays(
            BTreeSet::new(),
            relay.description(&format!("client-{index}")),
            now,
        );

        let dst = match resource {
            Resource::Cidr => CIDR_RESOURCE_IP.into(),
            Resource::Dns => resolve(&mut state, tun.v4, sentinel, now),
        };

        Self { index, state, dst }
    }

    pub fn request(&self) -> IpPacket {
        packet(client_tun(self.index).v4.into(), self.dst, 50000, 443)
    }
}

/// Resolves the DNS resource through the Client's stub resolver and returns its proxy IP.
fn resolve(client: &mut ClientState, tun: Ipv4Addr, sentinel: IpAddr, now: Instant) -> IpAddr {
    let query = Query::new(DNS_RESOURCE_DOMAIN.parse().unwrap(), RecordType::A).into_bytes();
    let mut query = ip_packet::make::udp_packet(tun, sentinel, 5353, 53, &query).unwrap();

    client.handle_tun_input(&mut query, now).unwrap();
    let response = client.poll_packets().unwrap();
    let response = Response::parse(response.as_udp().unwrap().payload()).unwrap();

    response
        .records()
        .find_map(dns_types::records::extract_ip)
        .unwrap()
}

/// Returns a UDP packet of [`SIZE`] bytes.
fn packet(src: IpAddr, dst: IpAddr, sport: u16, dport: u16) -> IpPacket {
    ip_packet::make::udp_packet(src, dst, sport, dport, &[0; SIZE - 28]).unwrap()
}

/// A TURN relay on [`RELAY_SOCKET`], run by the relay's own sans-IO state.
pub struct Relay {
    server: relay_proto::Server<StdRng>,
    /// The ports of its allocations.
    allocations: BTreeSet<u16>,
    /// When it started, by the simulated and the system clock.
    started: (Instant, SystemTime),
}

impl Relay {
    fn new(now: Instant) -> Self {
        let mut server = relay_proto::Server::new(
            IpAddr::V4(*RELAY_SOCKET.ip()),
            StdRng::seed_from_u64(0),
            RELAY_SOCKET.port(),
            ALLOCATION_PORTS,
        );
        server.set_accounts([AccountId::from(Uuid::nil())]);

        Self {
            server,
            allocations: BTreeSet::new(),
            started: (now, SystemTime::now()),
        }
    }

    /// Returns the relay as the portal describes it to a Client or Gateway, with credentials for
    /// `user`: the relay keeps one allocation per username.
    fn description(&self, user: &str) -> BTreeSet<(RelayId, RelaySocket, String, String, String)> {
        let expiry = self.started.1 + Duration::from_secs(24 * 60 * 60);
        let username = format!(
            "{}:{}:{user}",
            expiry
                .duration_since(SystemTime::UNIX_EPOCH)
                .unwrap()
                .as_secs(),
            relay_proto::auth::hash_account_id(&AccountId::from(Uuid::nil()))
        );
        let password = relay_proto::auth::generate_password(self.server.auth_secret(), &username);

        BTreeSet::from([(
            RelayId::from_u128(6),
            RelaySocket::V4(RELAY_SOCKET),
            username,
            password,
            "firezone".to_owned(),
        )])
    }

    /// Whether `socket` is the relay's own or one of its allocations.
    pub fn serves(&self, socket: SocketAddr) -> bool {
        socket == RELAY_SOCKET.into()
            || socket.ip() == *RELAY_SOCKET.ip() && self.allocations.contains(&socket.port())
    }

    /// Handles a datagram to one of its sockets and returns the datagrams it sends in turn, as
    /// source, destination and payload.
    pub fn handle(
        &mut self,
        from: SocketAddr,
        to: SocketAddr,
        payload: &[u8],
        now: Instant,
    ) -> Vec<(SocketAddr, SocketAddr, Vec<u8>)> {
        let now_utc = self.started.1 + now.duration_since(self.started.0);
        let mut datagrams = Vec::new();

        if to == RELAY_SOCKET.into() {
            if let Some((port, peer)) =
                self.server
                    .handle_client_input(payload, ClientSocket::new(from), now, now_utc)
            {
                let from = SocketAddr::new(to.ip(), port.value());
                datagrams.push((from, peer.into_socket(), payload[4..].to_vec()));
            }
        } else if let Some((client, channel)) = self.server.handle_peer_traffic(
            payload,
            PeerSocket::new(from),
            AllocationPort::new(to.port()),
        ) {
            let mut message = vec![0; 4];
            let len = u16::try_from(payload.len()).unwrap();
            ChannelData::encode_header_to_slice(channel, len, &mut message);
            message.extend_from_slice(payload);
            datagrams.push((RELAY_SOCKET.into(), client.into_socket(), message));
        }

        while let Some(command) = self.server.next_command() {
            match command {
                Command::SendMessage { payload, recipient } => {
                    datagrams.push((RELAY_SOCKET.into(), recipient.into_socket(), payload));
                }
                Command::CreateAllocation { port, .. } => {
                    self.allocations.insert(port.value());
                }
                Command::FreeAllocation { port, .. } => {
                    self.allocations.remove(&port.value());
                }
                _ => {}
            }
        }

        datagrams
    }
}

fn ingest_token() -> IngestToken {
    serde_json::from_value(serde_json::json!(flow_tracker::TEST_INGEST_TOKEN)).unwrap()
}
