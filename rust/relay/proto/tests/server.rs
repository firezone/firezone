#![allow(clippy::unwrap_used)]

use bytecodec::{DecodeExt as _, EncodeExt as _};
use rand::{SeedableRng as _, rngs::StdRng};
use relay_proto::{
    AddressFamily, AllocationPort, Attribute, ChannelData, ClientSocket, Command, PeerSocket,
    Server, ThroughputLimit, auth,
};
use std::collections::{HashMap, VecDeque};
use std::net::{Ipv4Addr, SocketAddr};
use std::num::NonZeroUsize;
use std::time::{Duration, Instant, SystemTime};
use stun_codec::rfc5389::attributes::{ErrorCode, MessageIntegrity, Nonce, Username};
use stun_codec::rfc5766::attributes::{ChannelNumber, RequestedTransport, XorPeerAddress};
use stun_codec::rfc5766::errors::{AllocationQuotaReached, Forbidden};
use stun_codec::rfc5766::methods::{ALLOCATE, CHANNEL_BIND, CREATE_PERMISSION, REFRESH};
use stun_codec::{Message, MessageClass, MessageDecoder, MessageEncoder, Method, TransactionId};
use uuid::Uuid;

#[test]
fn authenticated_allocate_creates_an_allocation() {
    let mut relay = TestRelay::new();

    let response = relay.allocate();

    assert_eq!(response.class(), MessageClass::SuccessResponse);
    assert!(matches!(
        relay.next_command(),
        Some(Command::CreateAllocation { .. })
    ));
    assert_eq!(relay.next_command(), None);
}

#[test]
fn allocation_limit_applies_per_account() {
    let mut relay = TestRelay::with_ports(8);
    let other_account = auth::AccountId::from(Uuid::from_u128(1));
    let limit = NonZeroUsize::new(1).unwrap();
    relay.server.add_account(other_account, None);
    relay.server.set_allocation_limits(HashMap::from([
        (relay.account, limit),
        (other_account, limit),
    ]));

    let first = relay.allocate();
    let second = relay.allocate_as(socket(1), username(relay.account, EXPIRY, "b"));
    let other = relay.allocate_as(socket(2), username(other_account, EXPIRY, "a"));

    assert_eq!(first.class(), MessageClass::SuccessResponse);
    assert_eq!(
        second.get_attribute::<ErrorCode>().unwrap().code(),
        AllocationQuotaReached::CODEPOINT
    );
    assert_eq!(other.class(), MessageClass::SuccessResponse);
}

#[test]
fn renewed_credentials_replace_device_allocation_at_limit() {
    let mut relay = TestRelay::with_ports(1);
    relay
        .server
        .set_allocation_limit(relay.account, NonZeroUsize::new(1));
    relay.allocate();
    let Some(Command::CreateAllocation { port, .. }) = relay.next_command() else {
        panic!("the relay creates an allocation for an authenticated request");
    };

    let response = relay.allocate_as(socket(1), username(relay.account, EXPIRY + 1, DEVICE));

    assert_eq!(response.class(), MessageClass::SuccessResponse);
    assert_eq!(
        relay.next_command(),
        Some(Command::FreeAllocation {
            port,
            family: AddressFamily::V4,
        })
    );
    assert!(matches!(
        relay.next_command(),
        Some(Command::CreateAllocation { .. })
    ));
    assert_eq!(relay.server.num_allocations(), 1);
}

#[test]
fn lowering_allocation_limit_keeps_existing_allocations() {
    let mut relay = TestRelay::with_ports(8);
    relay
        .server
        .set_allocation_limit(relay.account, NonZeroUsize::new(2));
    relay.allocate();
    relay.allocate_as(socket(1), username(relay.account, EXPIRY, "b"));

    relay
        .server
        .set_allocation_limit(relay.account, NonZeroUsize::new(1));
    let response = relay.allocate_as(socket(2), username(relay.account, EXPIRY, "c"));

    assert_eq!(relay.server.num_allocations(), 2);
    assert_eq!(
        response.get_attribute::<ErrorCode>().unwrap().code(),
        AllocationQuotaReached::CODEPOINT
    );
}

#[test]
fn removing_account_deletes_its_allocations_and_channel_bindings() {
    let peer = PeerSocket::new(SocketAddr::from(([198, 51, 100, 2], 50_001)));
    let channel = ChannelNumber::new(ChannelNumber::MIN).unwrap();
    let mut relay = TestRelay::new();

    relay.allocate();
    let Some(Command::CreateAllocation { port, .. }) = relay.next_command() else {
        panic!("the relay creates an allocation for an authenticated request");
    };
    relay.channel_bind(peer.into_socket());

    assert_eq!(
        relay.next_command(),
        Some(Command::CreateChannelBinding {
            client: relay.client,
            channel_number: channel,
            peer,
            allocation_port: port,
            throughput_limit: None,
        })
    );

    relay.server.remove_account(&relay.account);

    assert_eq!(relay.server.num_allocations(), 0);
    assert_eq!(relay.server.num_active_channels(), 0);
    assert_eq!(
        relay.next_command(),
        Some(Command::DeleteChannelBinding {
            client: relay.client,
            channel_number: channel,
            peer,
            allocation_port: port,
        })
    );
    assert_eq!(
        relay.next_command(),
        Some(Command::FreeAllocation {
            port,
            family: AddressFamily::V4,
        })
    );

    relay.server.remove_account(&relay.account);

    assert_eq!(relay.server.num_allocations(), 0);
    assert_eq!(relay.server.num_active_channels(), 0);
    assert_eq!(relay.next_command(), None);
}

#[test]
fn refuses_to_relay_unknown_payloads() {
    let peer = PeerSocket::new(SocketAddr::from(([198, 51, 100, 2], 50_001)));
    let channel = ChannelNumber::new(ChannelNumber::MIN).unwrap();
    let mut relay = TestRelay::with_allocation();

    relay.channel_bind(peer.into_socket());
    let Some(Command::CreateChannelBinding {
        allocation_port, ..
    }) = relay.next_command()
    else {
        panic!("the relay binds the channel");
    };

    let mut wireguard = [0u8; 32];
    wireguard[0] = 4;
    let dns_query = [
        0x12, 0x34, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    ];

    assert_eq!(
        relay.send_channel_data(channel, &wireguard),
        Some((allocation_port, peer))
    );
    assert_eq!(relay.send_channel_data(channel, &dns_query), None);
    assert_eq!(
        relay
            .server
            .handle_peer_traffic(&wireguard, peer, allocation_port, relay.now),
        Some((relay.client, channel))
    );
    assert_eq!(
        relay
            .server
            .handle_peer_traffic(&dns_query, peer, allocation_port, relay.now),
        None
    );
}

#[test]
fn success_responses_renew_the_nonce() {
    let nonce_window = Duration::from_secs(10 * 60);
    let mut relay = TestRelay::new();

    relay.now_utc += nonce_window;
    relay.nonce = relay
        .allocate()
        .get_attribute::<Nonce>()
        .cloned()
        .expect("a success response carries a nonce");
    relay.now_utc += nonce_window;

    assert_eq!(
        relay.send(REFRESH, []).class(),
        MessageClass::SuccessResponse
    );
}

#[test]
fn channel_bind_to_non_public_peer_is_forbidden() {
    for peer in [
        SocketAddr::from(([127, 0, 0, 1], 53)),
        SocketAddr::from(([169, 254, 169, 254], 53)),
        SocketAddr::from(([10, 0, 0, 1], 53)),
        SocketAddr::from(([100, 64, 0, 1], 53)),
        SocketAddr::from((RELAY_IP, 3478)),
        SocketAddr::from((RELAY_IP, 49_151)),
    ] {
        let mut relay = TestRelay::with_allocation();

        let response = relay.channel_bind(peer);

        assert_eq!(
            response.get_attribute::<ErrorCode>().map(|e| e.code()),
            Some(Forbidden::CODEPOINT),
            "{peer} is forbidden"
        );
        assert_eq!(relay.server.num_active_channels(), 0);
        assert_eq!(relay.next_command(), None);
    }
}

#[test]
fn channel_bind_to_public_peer_succeeds() {
    for peer in [
        SocketAddr::from(([198, 51, 100, 2], 50_001)),
        SocketAddr::from((RELAY_IP, 49_153)),
    ] {
        let mut relay = TestRelay::with_allocation();

        let response = relay.channel_bind(peer);

        assert_eq!(response.class(), MessageClass::SuccessResponse, "{peer}");
        assert_eq!(relay.server.num_active_channels(), 1);
    }
}

#[test]
fn channel_bind_to_private_peer_succeeds_if_allowed() {
    for peer in [
        SocketAddr::from(([10, 0, 0, 1], 53)),
        SocketAddr::from(([172, 31, 0, 1], 53)),
        SocketAddr::from(([192, 168, 1, 1], 53)),
    ] {
        let mut relay = TestRelay::with_allocation();
        relay.server.allow_private_peers();

        let response = relay.channel_bind(peer);

        assert_eq!(response.class(), MessageClass::SuccessResponse, "{peer}");
    }
}

#[test]
fn channel_bind_to_other_non_public_peer_is_forbidden_if_private_peers_are_allowed() {
    for peer in [
        SocketAddr::from(([127, 0, 0, 1], 53)),
        SocketAddr::from(([169, 254, 169, 254], 53)),
        SocketAddr::from(([100, 64, 0, 1], 53)),
    ] {
        let mut relay = TestRelay::with_allocation();
        relay.server.allow_private_peers();

        let response = relay.channel_bind(peer);

        assert_eq!(
            response.get_attribute::<ErrorCode>().map(|e| e.code()),
            Some(Forbidden::CODEPOINT),
            "{peer} is forbidden"
        );
    }
}

#[test]
fn create_permission_for_non_public_peer_is_forbidden() {
    let mut relay = TestRelay::with_allocation();

    let response = relay.create_permission([
        SocketAddr::from(([198, 51, 100, 2], 50_001)),
        SocketAddr::from(([169, 254, 169, 254], 80)),
    ]);

    assert_eq!(
        response.get_attribute::<ErrorCode>().map(|e| e.code()),
        Some(Forbidden::CODEPOINT)
    );
}

#[test]
fn create_permission_for_public_peer_succeeds() {
    let mut relay = TestRelay::with_allocation();

    let response = relay.create_permission([SocketAddr::from(([198, 51, 100, 2], 50_001))]);

    assert_eq!(response.class(), MessageClass::SuccessResponse);
}

#[test]
fn channel_bindings_adopt_a_changed_throughput_limit() {
    let peer = PeerSocket::new(SocketAddr::from(([198, 51, 100, 2], 50_001)));
    let channel = ChannelNumber::new(ChannelNumber::MIN).unwrap();
    let mut relay = TestRelay::with_allocation();
    relay.channel_bind(peer.into_socket());
    let Some(Command::CreateChannelBinding {
        allocation_port, ..
    }) = relay.next_command()
    else {
        panic!("the relay binds the channel");
    };

    relay
        .server
        .add_account(relay.account, Some(limit_5_mbps()));

    assert_eq!(
        relay.next_command(),
        Some(Command::CreateChannelBinding {
            client: relay.client,
            channel_number: channel,
            peer,
            allocation_port,
            throughput_limit: Some(limit_5_mbps()),
        })
    );
    assert_eq!(relay.next_command(), None);

    relay.server.set_accounts([(relay.account, None)]);

    assert_eq!(
        relay.next_command(),
        Some(Command::CreateChannelBinding {
            client: relay.client,
            channel_number: channel,
            peer,
            allocation_port,
            throughput_limit: None,
        })
    );
    assert_eq!(relay.next_command(), None);
}

#[test]
fn unchanged_throughput_limit_does_not_touch_channel_bindings() {
    let mut relay = TestRelay::with_allocation();
    relay
        .server
        .set_accounts([(relay.account, Some(limit_5_mbps()))]);
    relay.channel_bind(SocketAddr::from(([198, 51, 100, 2], 50_001)));
    assert!(matches!(
        relay.next_command(),
        Some(Command::CreateChannelBinding { .. })
    ));

    relay
        .server
        .add_account(relay.account, Some(limit_5_mbps()));
    relay
        .server
        .set_accounts([(relay.account, Some(limit_5_mbps()))]);

    assert_eq!(relay.next_command(), None);
}

#[test]
fn userspace_datapath_drops_traffic_above_throughput_limit() {
    let peer = PeerSocket::new(SocketAddr::from(([198, 51, 100, 2], 50_001)));
    let channel = ChannelNumber::new(ChannelNumber::MIN).unwrap();
    let mut relay = TestRelay::with_allocation();
    relay
        .server
        .set_accounts([(relay.account, Some(limit_5_mbps()))]);
    relay.channel_bind(peer.into_socket());
    let Some(Command::CreateChannelBinding {
        allocation_port, ..
    }) = relay.next_command()
    else {
        panic!("the relay binds the channel");
    };
    let mut payload = [0u8; 1250]; // A WireGuard data message, 2ms at 5 Mbps.
    payload[0] = 4;

    let to_peer = (0..200)
        .filter(|_| relay.send_channel_data(channel, &payload).is_some())
        .count();
    let to_client = (0..200)
        .filter(|_| {
            relay
                .server
                .handle_peer_traffic(&payload, peer, allocation_port, relay.now)
                .is_some()
        })
        .count();

    // The 250ms burst tolerance admits 126 packets (0 - 250ms ahead) per direction.
    assert_eq!(to_peer, 126);
    assert_eq!(to_client, 126);
    relay.now += Duration::from_millis(20);
    assert!(relay.send_channel_data(channel, &payload).is_some());
}

const RELAY_IP: Ipv4Addr = Ipv4Addr::new(203, 0, 113, 1);
const UDP_TRANSPORT: u8 = 17;

struct TestRelay {
    server: Server<StdRng>,
    account: auth::AccountId,
    client: ClientSocket,
    username: Username,
    nonce: Nonce,
    now: Instant,
    now_utc: SystemTime,
    commands: VecDeque<Command>,
}

impl TestRelay {
    fn new() -> Self {
        Self::with_ports(2)
    }

    fn with_ports(ports: u16) -> Self {
        let now = Instant::now();
        let now_utc = SystemTime::UNIX_EPOCH;
        let client = socket(0);
        let account = auth::AccountId::from(Uuid::nil());
        let mut server = Server::new(
            RELAY_IP,
            StdRng::seed_from_u64(0),
            3478,
            49_152..=(49_151 + ports),
        );

        server.set_accounts([(account, None)]);
        let nonce = issue_nonce(&mut server, client, now, now_utc);
        let username = username(account, EXPIRY, DEVICE);

        Self {
            server,
            account,
            client,
            username,
            nonce,
            now,
            now_utc,
            commands: VecDeque::new(),
        }
    }

    fn with_allocation() -> Self {
        let mut relay = Self::new();

        relay.allocate();
        for _ in std::iter::from_fn(|| relay.next_command()) {}

        relay
    }

    fn allocate(&mut self) -> Message<Attribute> {
        self.send(
            ALLOCATE,
            [Attribute::RequestedTransport(RequestedTransport::new(
                UDP_TRANSPORT,
            ))],
        )
    }

    /// Switches to `client` and `username` and allocates with them.
    fn allocate_as(&mut self, client: ClientSocket, username: Username) -> Message<Attribute> {
        self.client = client;
        self.username = username;
        self.nonce = issue_nonce(&mut self.server, client, self.now, self.now_utc);

        self.allocate()
    }

    fn channel_bind(&mut self, peer: SocketAddr) -> Message<Attribute> {
        self.send(
            CHANNEL_BIND,
            [
                Attribute::ChannelNumber(ChannelNumber::new(ChannelNumber::MIN).unwrap()),
                Attribute::XorPeerAddress(XorPeerAddress::new(peer)),
            ],
        )
    }

    fn create_permission(
        &mut self,
        peers: impl IntoIterator<Item = SocketAddr>,
    ) -> Message<Attribute> {
        self.send(
            CREATE_PERMISSION,
            peers
                .into_iter()
                .map(|peer| Attribute::XorPeerAddress(XorPeerAddress::new(peer))),
        )
    }

    fn send_channel_data(
        &mut self,
        channel: ChannelNumber,
        payload: &[u8],
    ) -> Option<(AllocationPort, PeerSocket)> {
        let mut message = vec![0; 4 + payload.len()];
        ChannelData::encode_header_to_slice(channel, payload.len() as u16, &mut message[..4]);
        message[4..].copy_from_slice(payload);

        self.server
            .handle_client_input(&message, self.client, self.now, self.now_utc)
    }

    /// Sends an authenticated request and returns the relay's response.
    fn send(
        &mut self,
        method: Method,
        attributes: impl IntoIterator<Item = Attribute>,
    ) -> Message<Attribute> {
        let mut message = Message::<Attribute>::new(
            MessageClass::Request,
            method,
            TransactionId::new(rand::random()),
        );
        for attribute in attributes {
            message.add_attribute(attribute);
        }
        message.add_attribute(self.username.clone());
        message.add_attribute(self.nonce.clone());

        let password = auth::generate_password(self.server.auth_secret(), self.username.name());
        let integrity = MessageIntegrity::new_long_term_credential(
            &message,
            &self.username,
            &auth::FIREZONE,
            &password,
        )
        .expect("a valid request has valid message integrity");
        message.add_attribute(integrity);

        let request = MessageEncoder::new()
            .encode_into_bytes(message)
            .expect("a well-formed request encodes");
        self.server
            .handle_client_input(&request, self.client, self.now, self.now_utc);

        loop {
            match self.server.next_command() {
                Some(Command::SendMessage { payload, .. }) => return decode(&payload),
                Some(command) => self.commands.push_back(command),
                None => panic!("the relay sends a response"),
            }
        }
    }

    /// The relay's next command, starting with those it emitted ahead of earlier responses.
    fn next_command(&mut self) -> Option<Command> {
        self.commands
            .pop_front()
            .or_else(|| self.server.next_command())
    }
}

fn issue_nonce(
    server: &mut Server<StdRng>,
    client: ClientSocket,
    now: Instant,
    now_utc: SystemTime,
) -> Nonce {
    let mut allocate =
        Message::<Attribute>::new(MessageClass::Request, ALLOCATE, TransactionId::new([0; 12]));
    allocate.add_attribute(RequestedTransport::new(UDP_TRANSPORT));

    let bytes = MessageEncoder::new()
        .encode_into_bytes(allocate)
        .expect("a well-formed ALLOCATE encodes");
    server.handle_client_input(&bytes, client, now, now_utc);

    let Some(Command::SendMessage { payload, .. }) = server.next_command() else {
        panic!("the relay responds to an unauthenticated ALLOCATE");
    };

    decode(&payload)
        .get_attribute::<Nonce>()
        .cloned()
        .expect("a `401` carries a nonce")
}

fn decode(payload: &[u8]) -> Message<Attribute> {
    MessageDecoder::<Attribute>::new()
        .decode_from_bytes(payload)
        .expect("the relay's response decodes")
        .expect("the relay's response is well-formed")
}

const EXPIRY: u64 = 2145916800;
const DEVICE: &str = "credential-salt";

fn username(account: auth::AccountId, expiry: u64, device: &str) -> Username {
    Username::new(format!(
        "{expiry}:{}:{device}",
        auth::hash_account_id(&account)
    ))
    .unwrap()
}

fn socket(index: u16) -> ClientSocket {
    ClientSocket::new(SocketAddr::from(([198, 51, 100, 1], 50_000 + index)))
}

fn limit_5_mbps() -> ThroughputLimit {
    ThroughputLimit::from_bits_per_second(5_000_000).unwrap()
}
