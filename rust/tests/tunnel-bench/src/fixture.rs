//! Clients and a Gateway connected in-process through their fake tunnels, and a TURN relay run by
//! its sans-IO state.

#![allow(clippy::unwrap_used, clippy::wildcard_enum_match_arm)]

use std::collections::{BTreeSet, VecDeque};
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr, SocketAddrV4};
use std::ops::RangeInclusive;
use std::sync::LazyLock;
use std::task::{Context, Poll, Waker};
use std::time::{Duration, Instant, SystemTime};

use connlib_model::{ClientId, GatewayId, RelayId, ResourceId, SiteId};
use dns_types::{Query, RecordType, Response};
use ip_packet::{Ecn, IpPacket};
use rand::{SeedableRng as _, rngs::StdRng};
use relay_proto::auth::AccountId;
use relay_proto::{AllocationPort, ChannelData, ClientSocket, Command, PeerSocket};
use snownet::{RelaySocket, Transmit};
use socket_factory::{DatagramBatch, DatagramOut};
use tun::PacketBatch;
use tunnel::{ClientState, FakeTunnelEnds, GatewayState, Role, Tunnel};
use tunnel_proto::messages::{IceCredentials, IngestToken, Interface, Key, SecretKey, gateway};
use tunnel_proto::{ClientEvent, GatewayEvent, IpConfig};
use uuid::Uuid;

use crate::callgrind;

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

/// How often the set-up lets time pass, which is also the round-trip time.
const STEP: Duration = Duration::from_millis(100);

/// How many datagrams one receive returns at most (`quinn_udp::BATCH_SIZE` on Linux).
const RECV_BATCH_SIZE: usize = 32;

/// How often an idle connection sends a keepalive.
pub const KEEPALIVE: Duration = Duration::from_secs(25);

/// How often a connection renews its WireGuard session.
const REKEY: Duration = Duration::from_secs(120);

/// The port of the first Client's socket; each further Client takes the next one.
const CLIENT_PORT: u16 = 1111;
pub static GATEWAY_SOCKET: LazyLock<SocketAddr> =
    LazyLock::new(|| SocketAddr::new(*LOCAL_IP, 2222));

/// Returns the socket of the Client with the given index.
///
/// Only the first Client's socket gets bound, by the packet benchmarks. The others need an address
/// each, as the Gateway rate-limits handshakes per source address.
fn client_socket(index: usize) -> SocketAddr {
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
fn client_index(socket: SocketAddr) -> Option<usize> {
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

/// A Client's or the Gateway's tunnel, running on the calling thread and on simulated time.
///
/// Its crypto jobs run inline, and the caller stands in for its UDP socket and TUN device: time
/// only moves when the caller moves it, to the deadline the tunnel asked for.
pub struct Host<R> {
    tunnel: Tunnel<R>,
    /// The fake tunnel's TUN device, sockets and resolver; every address is IPv4.
    ends: FakeTunnelEnds,
    /// The deadline the tunnel asked to be woken at.
    alarm: Option<Instant>,
}

impl<R: Role> Host<R> {
    fn new(state: R) -> Self {
        let (tunnel, ends) = Tunnel::fake(state);

        Self {
            tunnel,
            ends,
            alarm: None,
        }
    }

    /// Wakes the tunnel at `now` and polls it until it waits for input or a later deadline,
    /// returning its events.
    ///
    /// Like the Client's and the Gateway's event loops, it handles a deadline that has passed
    /// before anything else, and asks for the next deadline only once the tunnel is pending.
    pub fn run(&mut self, now: Instant) -> Vec<R::Event> {
        let mut cx = Context::from_waker(Waker::noop());
        let mut events = Vec::new();

        loop {
            if self.alarm.is_some_and(|alarm| alarm <= now) {
                self.tunnel.handle_timeout(now);
            }

            while let Poll::Ready(result) = self.tunnel.poll_next_event(&mut cx, now) {
                match result {
                    Ok(event) => events.push(event),
                    Err(mut errors) => for _ in errors.drain() {},
                }
            }

            self.alarm = self.tunnel.next_timeout(now);

            if !self.alarm.is_some_and(|alarm| alarm <= now) {
                return events;
            }
        }
    }

    /// The deadline the tunnel asked to be woken at.
    pub fn deadline(&self) -> Option<Instant> {
        self.alarm
    }

    /// Returns the tunnel's state to change, and has the tunnel woken at `now`.
    pub fn state_mut(&mut self, now: Instant) -> &mut R {
        self.alarm = Some(now);

        self.tunnel.state_mut()
    }

    pub fn into_state(self) -> R {
        self.tunnel.into_state()
    }

    /// Hands `batch` to the tunnel as if the TUN device had read it.
    pub fn read_from_tun(&self, batch: PacketBatch) {
        self.ends
            .tun_inbound
            .try_send(batch)
            .expect("TUN channel should have room");
    }

    /// Takes the packets the tunnel wrote to the TUN device.
    pub fn written_to_tun(&mut self) -> Vec<IpPacket> {
        let mut packets = Vec::new();

        while let Ok(mut batch) = self.ends.tun_outbound.try_recv() {
            packets.extend(batch.drain());
        }

        packets
    }

    /// Hands `batch` to the tunnel as if its socket had received it, or returns it if the
    /// socket's channel is full.
    pub fn receive(&self, batch: DatagramBatch) -> Result<(), DatagramBatch> {
        self.ends.socket_v4.receive(batch)
    }

    /// Takes the datagrams the tunnel sent, split into the segments that go on the wire.
    pub fn take_sent(&mut self) -> Vec<Transmit> {
        self.ends.socket_v4.take_sent()
    }

    /// Returns `count` copies of `packet` as the tunnel encrypts them for `dst`, in as few GSO
    /// batches as fit.
    fn encrypt(
        &mut self,
        packet: &IpPacket,
        count: usize,
        dst: SocketAddr,
        now: Instant,
    ) -> Vec<DatagramOut> {
        let mut segments = Vec::new();
        for batch in tun_batches(packet, count) {
            self.read_from_tun(batch);
            self.run(now);
            segments.extend(self.take_sent());
        }
        let segment_size = segments[0].payload.len();

        segments
            .chunks(DatagramOut::max_len(dst, segment_size) / segment_size)
            .map(|segments| {
                let mut packet = bufferpool::Bytes::fitting(64 * 1024);
                for segment in segments {
                    packet.extend_from_slice(&segment.payload);
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

/// Returns `count` copies of `packet`, in batches as full as the TUN device's.
pub fn tun_batches(packet: &IpPacket, count: usize) -> Vec<PacketBatch> {
    let packets = vec![packet.clone(); count];

    packets
        .chunks(tun::MAX_BATCH_SIZE)
        .map(|chunk| {
            let mut batch = PacketBatch::default();
            for packet in chunk {
                batch.try_push(packet.clone()).unwrap();
            }

            batch
        })
        .collect()
}

pub enum AnyHost {
    Client(Host<ClientState>),
    Gateway(Host<GatewayState>),
}

/// One side of an established connection.
pub struct Side {
    pub host: AnyHost,
    pub socket: SocketAddr,
    /// What this side reads from its TUN device.
    pub reads: IpPacket,
}

impl Side {
    /// Returns `count` copies of what this side reads from its TUN device, encrypted for `dst`
    /// in as few GSO batches as fit.
    pub fn encrypt(&mut self, count: usize, dst: SocketAddr, now: Instant) -> Vec<DatagramOut> {
        match &mut self.host {
            AnyHost::Client(host) => host.encrypt(&self.reads, count, dst, now),
            AnyHost::Gateway(host) => host.encrypt(&self.reads, count, dst, now),
        }
    }
}

/// Returns both sides of a connection, through which the Client may reach `resource`.
pub fn connect(resource: Resource) -> (Side, Side, Instant) {
    let mut network = Network::established(1, Connectivity::Ice, resource);
    let reply = network.reply();
    let client = network.clients.remove(0);

    let client = Side {
        socket: client_socket(client.index),
        reads: client.request(),
        host: AnyHost::Client(client.host),
    };
    let gateway = Side {
        host: AnyHost::Gateway(network.gateway),
        socket: *GATEWAY_SOCKET,
        reads: reply,
    };

    (client, gateway, network.now)
}

/// Clients and a Gateway with an established connection each, through which the Clients may
/// reach the given resource.
///
/// Datagrams pass between them and the relay without delay, and simulated time jumps from one
/// deadline to the next.
pub struct Network {
    pub clients: Vec<Client>,
    pub gateway: Host<GatewayState>,
    relay: Relay,
    pub now: Instant,
    connectivity: Connectivity,
    resource: Resource,
    /// Datagrams in flight, as source, destination and payload.
    in_flight: VecDeque<(SocketAddr, SocketAddr, Vec<u8>)>,
}

pub struct Client {
    index: usize,
    pub host: Host<ClientState>,
    /// Where it sends packets for the resource: its address or the DNS proxy IP.
    dst: IpAddr,
}

impl Network {
    pub fn established(clients: usize, connectivity: Connectivity, resource: Resource) -> Self {
        let now = Instant::now();
        let unix_ts = SystemTime::now()
            .duration_since(SystemTime::UNIX_EPOCH)
            .unwrap();
        let relay = Relay::new(now);

        let mut gateway = Host::new(GatewayState::new([2; 32], now, unix_ts));
        let state = gateway.state_mut(now);
        state.set_flow_logs_enabled(true);
        state.update_tun_device(GATEWAY_TUN);
        state.update_relays(BTreeSet::new(), relay.description("gateway"), now);

        let clients = (0..clients)
            .map(|index| Client::new(index, resource, &relay, now, unix_ts))
            .collect();

        let mut network = Self {
            clients,
            gateway,
            relay,
            now,
            connectivity,
            resource,
            in_flight: VecDeque::new(),
        };

        // A Gateway only signals candidates for a connection once it has a relay allocation.
        network.step_until(now + Duration::from_secs(1));

        // Spread over a session, so the connections' keepalives and rekeys do not fire at once.
        let start = network.now;
        let count = u32::try_from(network.clients.len()).unwrap();
        for index in 0..network.clients.len() {
            network.step_until(start + REKEY * u32::try_from(index).unwrap() / count);

            network.request(index);
        }

        // Until the TURN allocations' retransmits and the connections' initial probing are done.
        network.step_until(network.now + Duration::from_secs(20));

        network
    }

    /// Mirrors the first Client's request as the Gateway writes it to its TUN device.
    fn reply(&mut self) -> IpPacket {
        let request = self.forward(0).pop().unwrap();
        let udp = request.as_udp().unwrap();
        let (sport, dport) = (udp.source_port(), udp.destination_port());

        packet(request.destination(), request.source(), dport, sport)
    }

    /// Has a Client send its request for the resource, and returns what the Gateway wrote to its
    /// TUN device meanwhile.
    pub fn forward(&mut self, index: usize) -> Vec<IpPacket> {
        self.request(index);
        self.deliver();

        self.gateway.written_to_tun()
    }

    /// Has a Client's TUN device read its request for the resource.
    fn request(&mut self, index: usize) {
        let client = &self.clients[index];
        client
            .host
            .read_from_tun(PacketBatch::new(client.request()));
        self.wake_client(index);
    }

    /// Lets time pass until `until`, waking every tunnel at its deadline.
    pub fn run_until(&mut self, until: Instant) {
        self.advance(until, Duration::ZERO);
    }

    /// Lets time pass until `until` in steps of [`STEP`], waking the tunnels due at each.
    ///
    /// Waking them together lines up their timers, which keeps the idle benchmark's wake-ups few.
    fn step_until(&mut self, until: Instant) {
        self.advance(until, STEP);
    }

    fn advance(&mut self, until: Instant, step: Duration) {
        loop {
            self.deliver();
            for _ in self.gateway.written_to_tun() {}

            let Some(next) = self
                .clients
                .iter()
                .map(|client| client.host.deadline())
                .chain([self.gateway.deadline()])
                .flatten()
                .min()
                .filter(|next| *next <= until)
            else {
                break;
            };
            self.now = self.step_to(next, step, 1);
            let now = self.now;

            if self.gateway.deadline().is_some_and(|t| t <= now) {
                self.wake_gateway();
            }
            for index in 0..self.clients.len() {
                if self.clients[index]
                    .host
                    .deadline()
                    .is_some_and(|t| t <= now)
                {
                    self.wake_client(index);
                }
            }
        }
        self.now = self.step_to(until, step, 0);
    }

    /// Returns the earliest instant from now in whole `step`s, at least `min_steps` of them, that
    /// is not before `t`; without steps, the later of now and `t`.
    fn step_to(&self, t: Instant, step: Duration, min_steps: u128) -> Instant {
        if step.is_zero() {
            return self.now.max(t);
        }

        let steps = t
            .saturating_duration_since(self.now)
            .as_nanos()
            .div_ceil(step.as_nanos())
            .max(min_steps);

        self.now + step * u32::try_from(steps).unwrap()
    }

    /// Delivers the datagrams in flight and those sent in turn, until there are none.
    fn deliver(&mut self) {
        let mut to_gateway = Vec::new();

        while !self.in_flight.is_empty() {
            while let Some((from, to, payload)) = self.in_flight.pop_front() {
                if self.relay.serves(to) {
                    let datagrams = self.relay.handle(from, to, &payload, self.now);
                    self.in_flight.extend(datagrams);

                    continue;
                }

                if to == *GATEWAY_SOCKET {
                    to_gateway.push(datagram(from, to, &payload));

                    continue;
                }

                if let Some(index) = client_index(to).filter(|index| *index < self.clients.len()) {
                    let batch = DatagramBatch::from_datagrams([datagram(from, to, &payload)]);
                    self.clients[index].host.receive(batch).unwrap();
                    self.wake_client(index);
                }
            }

            if to_gateway.is_empty() {
                continue;
            }
            let mut batches = VecDeque::new();
            let mut datagrams = to_gateway.drain(..).peekable();
            while datagrams.peek().is_some() {
                batches.push_back(DatagramBatch::from_datagrams(
                    datagrams.by_ref().take(RECV_BATCH_SIZE),
                ));
            }
            drop(datagrams);

            while let Some(batch) = batches.pop_front() {
                if let Err(batch) = self.gateway.receive(batch) {
                    batches.push_front(batch);
                    self.wake_gateway();
                }
            }
            self.wake_gateway();
        }
    }

    /// Runs the Gateway's tunnel, counting its instructions, handles its events and puts what it
    /// sent in flight.
    fn wake_gateway(&mut self) {
        let now = self.now;

        for event in callgrind::count(|| self.gateway.run(now)) {
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
                        client
                            .host
                            .state_mut(now)
                            .add_ice_candidate(GID, candidate, now);
                    }
                }
                GatewayEvent::ResolveDns(request) => {
                    self.gateway
                        .state_mut(now)
                        .handle_domain_resolved(request, Ok(vec![DNS_RESOURCE_IP.into()]), now)
                        .unwrap();
                }
                _ => {}
            }
        }

        for transmit in self.gateway.take_sent() {
            self.in_flight
                .push_back((*GATEWAY_SOCKET, transmit.dst, transmit.payload.to_vec()));
        }
    }

    /// Runs a Client's tunnel, handles its events and puts what it sent in flight.
    fn wake_client(&mut self, index: usize) {
        let now = self.now;

        for event in self.clients[index].host.run(now) {
            match event {
                ClientEvent::RequestAccess { .. } => self.authorize(index),
                ClientEvent::AddedIceCandidates { candidates, .. } => {
                    for candidate in candidates {
                        self.gateway.state_mut(now).add_ice_candidate(
                            client_id(index),
                            candidate,
                            now,
                        );
                    }
                }
                _ => {}
            }
        }

        let host = &mut self.clients[index].host;
        for _ in host.written_to_tun() {}
        for transmit in host.take_sent() {
            self.in_flight.push_back((
                client_socket(index),
                transmit.dst,
                transmit.payload.to_vec(),
            ));
        }
    }

    fn authorize(&mut self, index: usize) {
        let now = self.now;
        let client = self.clients[index].host.state_mut(now);
        let gateway = self.gateway.state_mut(now);
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

        gateway.create_authorization(
            gateway::Client {
                id: client_id(index),
                public_key: client.public_key().into(),
                preshared_key: preshared_key(),
                ipv4: tun.v4,
                ipv6: tun.v6,
            },
            client_ice.clone(),
            gateway_ice.clone(),
            None,
            serde_json::from_value(self.resource.description()).unwrap(),
            self.connectivity.iceless(),
            now,
            ingest_token(),
        );
        client
            .handle_resource_access_authorized(
                self.resource.id(),
                GID,
                gateway.public_key(),
                GATEWAY_TUN,
                SITE,
                preshared_key(),
                client_ice,
                gateway_ice,
                self.connectivity.iceless(),
                ingest_token(),
                now,
            )
            .unwrap();
    }
}

fn datagram(from: SocketAddr, to: SocketAddr, payload: &[u8]) -> DatagramOut {
    DatagramOut {
        src: Some(from),
        dst: to,
        packet: bufferpool::Bytes::copied_from(payload),
        segment_size: payload.len(),
        ecn: Ecn::NonEct,
    }
}

impl Client {
    fn new(
        index: usize,
        resource: Resource,
        relay: &Relay,
        now: Instant,
        unix_ts: Duration,
    ) -> Self {
        let tun = client_tun(index);
        let mut key = [1; 32];
        key[..8].copy_from_slice(&(index as u64).to_be_bytes());

        let mut host = Host::new(ClientState::new(key, BTreeSet::new(), false, now, unix_ts));
        let state = host.state_mut(now);
        state.set_flow_logs_enabled(true);
        state.update_interface_config(Interface {
            ipv4: tun.v4,
            ipv6: tun.v6,
            upstream_dns: Vec::new(),
            upstream_do53: Vec::new(),
            upstream_doh: Vec::new(),
            search_domain: None,
        });
        state.update_system_resolvers(vec![IpAddr::from([1, 1, 1, 1])]);
        state.set_resources(
            vec![serde_json::from_value(resource.description()).unwrap()],
            now,
        );
        let sentinel = host
            .run(now)
            .into_iter()
            .find_map(|event| {
                let ClientEvent::TunInterfaceUpdated(config) = event else {
                    return None;
                };

                config.dns_by_sentinel.sentinel_ips().first().copied()
            })
            .unwrap();

        let dst = match resource {
            Resource::Cidr => CIDR_RESOURCE_IP.into(),
            Resource::Dns => resolve(&mut host, tun.v4, sentinel, now),
        };
        host.state_mut(now).update_relays(
            BTreeSet::new(),
            relay.description(&format!("client-{index}")),
            now,
        );

        Self { index, host, dst }
    }

    pub fn request(&self) -> IpPacket {
        packet(client_tun(self.index).v4.into(), self.dst, 50000, 443)
    }
}

/// Resolves the DNS resource through the Client's stub resolver and returns its proxy IP.
fn resolve(
    client: &mut Host<ClientState>,
    tun: Ipv4Addr,
    sentinel: IpAddr,
    now: Instant,
) -> IpAddr {
    let query = Query::new(DNS_RESOURCE_DOMAIN.parse().unwrap(), RecordType::A).into_bytes();
    let query = ip_packet::make::udp_packet(tun, sentinel, 5353, 53, &query).unwrap();

    client.read_from_tun(PacketBatch::new(query));
    client.run(now);
    let response = client.written_to_tun().pop().unwrap();
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
struct Relay {
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
    fn serves(&self, socket: SocketAddr) -> bool {
        socket == RELAY_SOCKET.into()
            || socket.ip() == *RELAY_SOCKET.ip() && self.allocations.contains(&socket.port())
    }

    /// Handles a datagram to one of its sockets and returns the datagrams it sends in turn, as
    /// source, destination and payload.
    fn handle(
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
