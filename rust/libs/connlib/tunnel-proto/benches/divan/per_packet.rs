//! Per-packet work of connlib's main thread on an established Client <> Gateway connection.
//!
//! The `boringtun_*` benches measure the bare WireGuard crypto of the same packets so it can be
//! subtracted from the state-level benches.

#![allow(clippy::unwrap_used)]

use std::collections::BTreeSet;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr, SocketAddrV4};
use std::time::{Duration, Instant, SystemTime};

use boringtun::noise::{Index, Tunn, TunnResult};
use boringtun::x25519::{PublicKey, StaticSecret};
use bytecodec::{DecodeExt as _, EncodeExt as _};
use connlib_model::{ClientId, GatewayId, RelayId, ResourceId, SiteId};
use divan::Bencher;
use dns_types::{Query, RecordType, Response};
use ip_packet::IpPacket;
use snownet::{RelaySocket, Transmit, TransmitBuffer};
use stun_codec::rfc5389::{Attribute, attributes::XorMappedAddress, methods::BINDING};
use stun_codec::{Message, MessageClass, MessageDecoder, MessageEncoder};
use tunnel_proto::messages::{
    IceCredentials, IngestToken, Interface, Key, SecretKey, client, gateway,
};
use tunnel_proto::{ClientEvent, ClientState, GatewayEvent, GatewayState, IpConfig};

const SIZES: [usize; 2] = [64, 1280];

#[derive(Debug, Clone, Copy)]
enum Resource {
    Cidr,
    Dns,
}

const RESOURCES: [Resource; 2] = [Resource::Cidr, Resource::Dns];

#[divan::bench(args = RESOURCES, consts = SIZES)]
fn client_outbound<const SIZE: usize>(bencher: Bencher, resource: Resource) {
    let mut tunnel = Tunnel::established(resource);
    let packet = tunnel.request(SIZE);
    let mut transmits = TransmitBuffer::default();

    bencher
        .with_inputs(|| packet.clone())
        .bench_local_values(|packet| {
            tunnel
                .client
                .handle_tun_input(packet, tunnel.now, &mut transmits)
                .unwrap();
            assert!(transmits.poll_transmit().is_some());
        });
}

#[divan::bench(args = RESOURCES, consts = SIZES)]
fn gateway_inbound<const SIZE: usize>(bencher: Bencher, resource: Resource) {
    let mut tunnel = Tunnel::established(resource);
    let packet = tunnel.request(SIZE);
    let Tunnel {
        client,
        gateway,
        now,
        ..
    } = &mut tunnel;
    let mut transmits = TransmitBuffer::default();

    bencher
        .with_inputs(|| encapsulate_on_client(client, packet.clone(), *now, &mut transmits))
        .bench_local_refs(|datagram| {
            let packet = gateway
                .handle_network_input(GATEWAY_SOCKET, CLIENT_SOCKET, &datagram.payload, *now)
                .unwrap();
            assert!(packet.is_some());
        });
}

#[divan::bench(args = RESOURCES, consts = SIZES)]
fn gateway_outbound<const SIZE: usize>(bencher: Bencher, resource: Resource) {
    let mut tunnel = Tunnel::established(resource);
    let reply = tunnel.reply(SIZE);
    let mut transmits = TransmitBuffer::default();

    bencher
        .with_inputs(|| reply.clone())
        .bench_local_values(|reply| {
            tunnel
                .gateway
                .handle_tun_input(reply, tunnel.now, &mut transmits)
                .unwrap();
            assert!(transmits.poll_transmit().is_some());
        });
}

#[divan::bench(args = RESOURCES, consts = SIZES)]
fn client_inbound<const SIZE: usize>(bencher: Bencher, resource: Resource) {
    let mut tunnel = Tunnel::established(resource);
    let reply = tunnel.reply(SIZE);
    let Tunnel {
        client,
        gateway,
        now,
        ..
    } = &mut tunnel;
    let mut transmits = TransmitBuffer::default();

    bencher
        .with_inputs(|| encapsulate_on_gateway(gateway, reply.clone(), *now, &mut transmits))
        .bench_local_refs(|datagram| {
            let packet = client
                .handle_network_input(CLIENT_SOCKET, GATEWAY_SOCKET, &datagram.payload, *now)
                .unwrap();
            assert!(packet.is_some());
        });
}

#[divan::bench(consts = SIZES)]
fn boringtun_encrypt<const SIZE: usize>(bencher: Bencher) {
    let (mut initiator, _, now) = tunn_pair();
    let packet = udp_packet(CLIENT_TUN_V4.into(), CIDR_RESOURCE_IP.into(), SIZE);
    let mut buf = [0u8; 2048];

    bencher.bench_local(|| {
        initiator
            .encapsulate_data_at(packet.packet(), &mut buf, now)
            .unwrap()
    });
}

#[divan::bench(consts = SIZES)]
fn boringtun_decrypt<const SIZE: usize>(bencher: Bencher) {
    let (mut initiator, mut responder, now) = tunn_pair();
    let packet = udp_packet(CLIENT_TUN_V4.into(), CIDR_RESOURCE_IP.into(), SIZE);
    let mut buf = [0u8; 2048];
    let mut out = [0u8; 2048];

    bencher
        .with_inputs(|| {
            let len = initiator
                .encapsulate_data_at(packet.packet(), &mut buf, now)
                .unwrap();
            buf[..len].to_vec()
        })
        .bench_local_refs(|datagram| {
            let result =
                responder.decapsulate_at(Some(CLIENT_SOCKET.ip()), datagram, &mut out, now);
            assert!(matches!(result, TunnResult::WriteToTunnelV4(..)));
        });
}

const CLIENT_SOCKET: SocketAddr =
    SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::new(10, 0, 0, 1), 1111));
const GATEWAY_SOCKET: SocketAddr =
    SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::new(10, 0, 0, 2), 2222));
const RELAY_SOCKET: SocketAddrV4 = SocketAddrV4::new(Ipv4Addr::new(10, 0, 0, 3), 3478);

const CLIENT_TUN_V4: Ipv4Addr = Ipv4Addr::new(100, 64, 0, 1);
const CLIENT_TUN_V6: Ipv6Addr = Ipv6Addr::new(0xfd00, 0x2021, 0x1111, 0, 0, 0, 0, 1);
const GATEWAY_TUN: IpConfig = IpConfig {
    v4: Ipv4Addr::new(100, 64, 0, 2),
    v6: Ipv6Addr::new(0xfd00, 0x2021, 0x1111, 0, 0, 0, 0, 2),
};

const CID: ClientId = ClientId::from_u128(1);
const GID: GatewayId = GatewayId::from_u128(2);
const SITE: SiteId = SiteId::from_u128(3);
const CIDR_RESOURCE: ResourceId = ResourceId::from_u128(4);
const DNS_RESOURCE: ResourceId = ResourceId::from_u128(5);

const CIDR_RESOURCE_IP: Ipv4Addr = Ipv4Addr::new(172, 16, 0, 1);
const DNS_RESOURCE_DOMAIN: &str = "app.example.com";
const DNS_RESOURCE_IP: Ipv4Addr = Ipv4Addr::new(172, 16, 1, 1);

/// A Client and a Gateway with an established connection through which the Client may reach the
/// given resource.
struct Tunnel {
    client: ClientState,
    gateway: GatewayState,
    now: Instant,
    /// Where the Client sends packets for the resource: its address or the DNS proxy IP.
    dst: IpAddr,
}

impl Tunnel {
    fn established(resource: Resource) -> Self {
        let now = Instant::now();
        let unix_ts = SystemTime::now()
            .duration_since(SystemTime::UNIX_EPOCH)
            .unwrap();

        let mut client = ClientState::new([1; 32], BTreeSet::new(), false, now, unix_ts);
        client.update_interface_config(Interface {
            ipv4: CLIENT_TUN_V4,
            ipv6: CLIENT_TUN_V6,
            upstream_dns: Vec::new(),
            upstream_do53: Vec::new(),
            upstream_doh: Vec::new(),
            search_domain: None,
        });
        client.update_system_resolvers(vec![IpAddr::from([1, 1, 1, 1])]);
        let sentinel = std::iter::from_fn(|| client.poll_event())
            .find_map(|event| {
                let ClientEvent::TunInterfaceUpdated(config) = event else {
                    return None;
                };

                config.dns_by_sentinel.sentinel_ips().first().copied()
            })
            .unwrap();
        client.set_resources(vec![client_resource(resource)], now);
        client.update_relays(BTreeSet::new(), relays(), now);

        let mut gateway = GatewayState::new([2; 32], now, unix_ts);
        gateway.update_tun_device(GATEWAY_TUN);
        gateway.update_relays(BTreeSet::new(), relays(), now);

        let dst = match resource {
            Resource::Cidr => CIDR_RESOURCE_IP.into(),
            Resource::Dns => resolve(&mut client, sentinel, now),
        };

        let mut tunnel = Self {
            client,
            gateway,
            now,
            dst,
        };

        tunnel
            .client
            .handle_tun_input(tunnel.request(64), now, &mut TransmitBuffer::default())
            .unwrap();

        for _ in 0..200 {
            tunnel.step(resource);
        }

        tunnel
    }

    fn request(&self, size: usize) -> IpPacket {
        udp_packet(CLIENT_TUN_V4.into(), self.dst, size)
    }

    /// Mirrors a request as the Gateway writes it to its TUN device.
    fn reply(&mut self, size: usize) -> IpPacket {
        let request = self.request(size);
        let datagram = encapsulate_on_client(
            &mut self.client,
            request,
            self.now,
            &mut TransmitBuffer::default(),
        );
        let request = self
            .gateway
            .handle_network_input(GATEWAY_SOCKET, CLIENT_SOCKET, &datagram.payload, self.now)
            .unwrap()
            .unwrap();
        let udp = request.as_udp().unwrap();

        ip_packet::make::udp_packet(
            request.destination(),
            request.source(),
            udp.destination_port(),
            udp.source_port(),
            &vec![0; size - 28],
        )
        .unwrap()
    }

    fn step(&mut self, resource: Resource) {
        self.now += Duration::from_millis(10);
        let now = self.now;

        if self.client.poll_timeout().is_some_and(|(t, _)| t <= now) {
            self.client.handle_timeout(now);
        }
        if self.gateway.poll_timeout().is_some_and(|(t, _)| t <= now) {
            self.gateway.handle_timeout(now);
        }

        while let Some(event) = self.client.poll_event() {
            if let ClientEvent::RequestAccess { .. } = event {
                self.authorize(resource);
            } else if let ClientEvent::AddedIceCandidates { candidates, .. } = event {
                for candidate in candidates {
                    self.gateway.add_ice_candidate(CID, candidate, now);
                }
            }
        }
        while let Some(event) = self.gateway.poll_event() {
            if let GatewayEvent::AddedIceCandidates { candidates, .. } = event {
                for candidate in candidates {
                    self.client.add_ice_candidate(GID, candidate, now);
                }
            } else if let GatewayEvent::ResolveDns(request) = event {
                self.gateway
                    .handle_domain_resolved(request, Ok(vec![DNS_RESOURCE_IP.into()]), now)
                    .unwrap();
            }
        }

        while let Some(transmit) = self.client.poll_transmit() {
            self.route(CLIENT_SOCKET, transmit);
        }
        while let Some(transmit) = self.gateway.poll_transmit() {
            self.route(GATEWAY_SOCKET, transmit);
        }
        for _ in std::iter::from_fn(|| self.client.poll_packets()) {}
    }

    fn authorize(&mut self, resource: Resource) {
        let preshared_key = || SecretKey::init_with(|| Key([3; 32]));
        let client_ice = IceCredentials {
            username: "client".to_owned(),
            password: "client-password".to_owned(),
        };
        let gateway_ice = IceCredentials {
            username: "gateway".to_owned(),
            password: "gateway-password".to_owned(),
        };

        self.gateway.create_authorization(
            gateway::Client {
                id: CID,
                public_key: self.client.public_key().into(),
                preshared_key: preshared_key(),
                ipv4: CLIENT_TUN_V4,
                ipv6: CLIENT_TUN_V6,
            },
            client_ice.clone(),
            gateway_ice.clone(),
            None,
            gateway_resource(resource),
            false,
            self.now,
            ingest_token(),
        );
        self.client
            .handle_resource_access_authorized(
                resource_id(resource),
                GID,
                self.gateway.public_key(),
                GATEWAY_TUN,
                SITE,
                preshared_key(),
                client_ice,
                gateway_ice,
                false,
                ingest_token(),
                self.now,
            )
            .unwrap();
    }

    /// Delivers a datagram, standing in for a relay that only answers STUN binding requests.
    ///
    /// That is enough for both sides to learn their host candidates and connect directly.
    fn route(&mut self, from: SocketAddr, transmit: Transmit) {
        let relay = SocketAddr::V4(RELAY_SOCKET);

        if transmit.dst != relay {
            self.deliver(from, transmit.dst, &transmit.payload);
            return;
        }

        let Some(response) = binding_response(&transmit.payload, from) else {
            return;
        };
        self.deliver(relay, from, &response);
    }

    fn deliver(&mut self, from: SocketAddr, to: SocketAddr, payload: &[u8]) {
        if to == CLIENT_SOCKET {
            let _ = self
                .client
                .handle_network_input(to, from, payload, self.now);
        }
        if to == GATEWAY_SOCKET {
            let _ = self
                .gateway
                .handle_network_input(to, from, payload, self.now);
        }
    }
}

fn encapsulate_on_client(
    client: &mut ClientState,
    packet: IpPacket,
    now: Instant,
    transmits: &mut TransmitBuffer,
) -> Transmit {
    client.handle_tun_input(packet, now, transmits).unwrap();

    transmits.poll_transmit().unwrap()
}

fn encapsulate_on_gateway(
    gateway: &mut GatewayState,
    packet: IpPacket,
    now: Instant,
    transmits: &mut TransmitBuffer,
) -> Transmit {
    gateway.handle_tun_input(packet, now, transmits).unwrap();

    transmits.poll_transmit().unwrap()
}

/// Resolves the DNS resource through the Client's stub resolver and returns its proxy IP.
fn resolve(client: &mut ClientState, sentinel: IpAddr, now: Instant) -> IpAddr {
    let query = Query::new(DNS_RESOURCE_DOMAIN.parse().unwrap(), RecordType::A).into_bytes();
    let query = ip_packet::make::udp_packet(CLIENT_TUN_V4, sentinel, 5353, 53, &query).unwrap();

    client
        .handle_tun_input(query, now, &mut TransmitBuffer::default())
        .unwrap();
    let response = client.poll_packets().unwrap();
    let response = Response::parse(response.as_udp().unwrap().payload()).unwrap();

    response
        .records()
        .find_map(dns_types::records::extract_ip)
        .unwrap()
}

fn udp_packet(src: IpAddr, dst: IpAddr, size: usize) -> IpPacket {
    ip_packet::make::udp_packet(src, dst, 50000, 443, &vec![0; size - 28]).unwrap()
}

fn binding_response(request: &[u8], from: SocketAddr) -> Option<Vec<u8>> {
    let request = MessageDecoder::<Attribute>::new()
        .decode_from_bytes(request)
        .ok()?
        .ok()?;
    if request.method() != BINDING {
        return None;
    }

    let mut response = Message::<Attribute>::new(
        MessageClass::SuccessResponse,
        BINDING,
        request.transaction_id(),
    );
    response.add_attribute(XorMappedAddress::new(from));

    MessageEncoder::new().encode_into_bytes(response).ok()
}

fn relays() -> BTreeSet<(RelayId, RelaySocket, String, String, String)> {
    BTreeSet::from([(
        RelayId::from_u128(6),
        RelaySocket::V4(RELAY_SOCKET),
        "username".to_owned(),
        "password".to_owned(),
        "firezone".to_owned(),
    )])
}

fn resource_id(resource: Resource) -> ResourceId {
    match resource {
        Resource::Cidr => CIDR_RESOURCE,
        Resource::Dns => DNS_RESOURCE,
    }
}

fn client_resource(resource: Resource) -> client::ResourceDescription {
    let sites = serde_json::json!([{ "id": SITE, "name": "site" }]);
    let description = match resource {
        Resource::Cidr => serde_json::json!({
            "type": "cidr",
            "id": CIDR_RESOURCE,
            "address": "172.16.0.0/24",
            "name": "cidr",
            "address_description": null,
            "sites": sites,
        }),
        Resource::Dns => serde_json::json!({
            "type": "dns",
            "id": DNS_RESOURCE,
            "address": DNS_RESOURCE_DOMAIN,
            "name": "dns",
            "address_description": null,
            "sites": sites,
        }),
    };

    serde_json::from_value(description).unwrap()
}

fn gateway_resource(resource: Resource) -> gateway::ResourceDescription {
    let description = match resource {
        Resource::Cidr => serde_json::json!({
            "type": "cidr",
            "id": CIDR_RESOURCE,
            "address": "172.16.0.0/24",
            "name": "cidr",
            "filters": [],
        }),
        Resource::Dns => serde_json::json!({
            "type": "dns",
            "id": DNS_RESOURCE,
            "address": DNS_RESOURCE_DOMAIN,
            "name": "dns",
            "filters": [],
        }),
    };

    serde_json::from_value(description).unwrap()
}

fn ingest_token() -> IngestToken {
    serde_json::from_value(serde_json::json!(flow_tracker::TEST_INGEST_TOKEN)).unwrap()
}

/// Returns two [`Tunn`]s with a confirmed session from `initiator` to `responder`.
fn tunn_pair() -> (Tunn, Tunn, Instant) {
    let now = Instant::now();
    let initiator_key = StaticSecret::from([1; 32]);
    let responder_key = StaticSecret::from([2; 32]);
    let tunn = |local: &StaticSecret, remote: &StaticSecret, index| {
        Tunn::new_at(
            local.clone(),
            PublicKey::from(remote),
            Some(StaticSecret::from([3; 32])),
            None,
            Index::new_local(index),
            None,
            0,
            now,
            now,
            Duration::ZERO,
        )
    };
    let mut initiator = tunn(&initiator_key, &responder_key, 1);
    let mut responder = tunn(&responder_key, &initiator_key, 2);

    let mut buf = [0u8; 2048];
    let mut out = [0u8; 2048];
    let TunnResult::WriteToNetwork(init) =
        initiator.format_handshake_initiation_at(&mut buf, false, now)
    else {
        panic!("Expected handshake initiation");
    };
    let TunnResult::WriteToNetwork(response) = responder.decapsulate_at(None, init, &mut out, now)
    else {
        panic!("Expected handshake response");
    };
    let TunnResult::WriteToNetwork(keepalive) =
        initiator.decapsulate_at(None, response, &mut buf, now)
    else {
        panic!("Expected keepalive");
    };
    let TunnResult::Done = responder.decapsulate_at(None, keepalive, &mut out, now) else {
        panic!("Expected keepalive to confirm the session");
    };

    (initiator, responder, now)
}
