use bytecodec::{DecodeExt, EncodeExt};
use firezone_relay::{
    AddressFamily, Allocate, AllocationId, Attribute, Binding, ChannelBind, ChannelData,
    ClientMessage, ClientSocket, Command, IpStack, PeerSocket, Refresh, Server,
};
use rand::rngs::mock::StepRng;
use secrecy::SecretString;
use std::collections::HashMap;
use std::iter;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr, SocketAddrV4, SocketAddrV6};
use std::time::{Duration, SystemTime};
use stun_codec::rfc5389::attributes::{ErrorCode, Nonce, Realm, Username, XorMappedAddress};
use stun_codec::rfc5389::errors::Unauthorized;
use stun_codec::rfc5389::methods::BINDING;
use stun_codec::rfc5766::attributes::{ChannelNumber, Lifetime, XorPeerAddress, XorRelayAddress};
use stun_codec::rfc5766::methods::{ALLOCATE, CHANNEL_BIND, REFRESH};
use stun_codec::{Message, MessageClass, MessageDecoder, MessageEncoder, TransactionId};
use test_strategy::proptest;
use uuid::Uuid;
use Output::{CreateAllocation, FreeAllocation, Wake};

#[proptest]
fn can_answer_stun_request_from_ip4_address(
    #[strategy(firezone_relay::proptest::binding())] request: Binding,
    source: SocketAddrV4,
    public_relay_addr: Ipv4Addr,
) {
    let _ = env_logger::try_init();
    let mut server = TestServer::new(public_relay_addr);

    let transaction_id = request.transaction_id();

    server.assert_commands(
        from_client(source, request, SystemTime::now()),
        [send_message(
            source,
            binding_response(transaction_id, source),
        )],
    );
}

#[proptest]
fn deallocate_once_time_expired(
    #[strategy(firezone_relay::proptest::transaction_id())] transaction_id: TransactionId,
    #[strategy(firezone_relay::proptest::allocation_lifetime())] lifetime: Lifetime,
    #[strategy(firezone_relay::proptest::username_salt())] username_salt: String,
    source: SocketAddrV4,
    public_relay_addr: Ipv4Addr,
    #[strategy(firezone_relay::proptest::now())] now: SystemTime,
    #[strategy(firezone_relay::proptest::nonce())] nonce: Uuid,
) {
    let mut server = TestServer::new(public_relay_addr).with_nonce(nonce);
    let secret = server.auth_secret();

    server.assert_commands(
        from_client(
            source,
            Allocate::new_authenticated_udp_implicit_ip4(
                transaction_id,
                Some(lifetime.clone()),
                valid_username(now, &username_salt),
                secret,
                nonce,
            ),
            now,
        ),
        [
            Wake(now + lifetime.lifetime()),
            CreateAllocation(49152, AddressFamily::V4),
            send_message(
                source,
                allocate_response(transaction_id, public_relay_addr, 49152, source, &lifetime),
            ),
        ],
    );

    server.assert_commands(
        forward_time_to(now + lifetime.lifetime() + Duration::from_secs(1)),
        [FreeAllocation(49152, AddressFamily::V4)],
    );
}

#[proptest]
fn unauthenticated_allocate_triggers_authentication(
    #[strategy(firezone_relay::proptest::transaction_id())] transaction_id: TransactionId,
    #[strategy(firezone_relay::proptest::allocation_lifetime())] lifetime: Lifetime,
    #[strategy(firezone_relay::proptest::username_salt())] username_salt: String,
    source: SocketAddrV4,
    public_relay_addr: Ipv4Addr,
    #[strategy(firezone_relay::proptest::now())] now: SystemTime,
) {
    // Nonces are generated randomly and we control the randomness in the test, thus this is deterministic.
    let first_nonce = Uuid::from_u128(0x0);

    let mut server = TestServer::new(public_relay_addr);
    let secret = server.auth_secret().to_owned();

    server.assert_commands(
        from_client(
            source,
            Allocate::new_unauthenticated_udp(transaction_id, Some(lifetime.clone())),
            now,
        ),
        [send_message(
            source,
            unauthorized_allocate_response(transaction_id, first_nonce),
        )],
    );

    server.assert_commands(
        from_client(
            source,
            Allocate::new_authenticated_udp_implicit_ip4(
                transaction_id,
                Some(lifetime.clone()),
                valid_username(now, &username_salt),
                &secret,
                first_nonce,
            ),
            now,
        ),
        [
            Wake(now + lifetime.lifetime()),
            CreateAllocation(49152, AddressFamily::V4),
            send_message(
                source,
                allocate_response(transaction_id, public_relay_addr, 49152, source, &lifetime),
            ),
        ],
    );
}

#[proptest]
fn when_refreshed_in_time_allocation_does_not_expire(
    #[strategy(firezone_relay::proptest::transaction_id())] allocate_transaction_id: TransactionId,
    #[strategy(firezone_relay::proptest::transaction_id())] refresh_transaction_id: TransactionId,
    #[strategy(firezone_relay::proptest::allocation_lifetime())] allocate_lifetime: Lifetime,
    #[strategy(firezone_relay::proptest::allocation_lifetime())] refresh_lifetime: Lifetime,
    #[strategy(firezone_relay::proptest::username_salt())] username_salt: String,
    source: SocketAddrV4,
    public_relay_addr: Ipv4Addr,
    #[strategy(firezone_relay::proptest::now())] now: SystemTime,
    #[strategy(firezone_relay::proptest::nonce())] nonce: Uuid,
) {
    let mut server = TestServer::new(public_relay_addr).with_nonce(nonce);
    let secret = server.auth_secret().to_owned();
    let first_wake = now + allocate_lifetime.lifetime();

    server.assert_commands(
        from_client(
            source,
            Allocate::new_authenticated_udp_implicit_ip4(
                allocate_transaction_id,
                Some(allocate_lifetime.clone()),
                valid_username(now, &username_salt),
                &secret,
                nonce,
            ),
            now,
        ),
        [
            Wake(first_wake),
            CreateAllocation(49152, AddressFamily::V4),
            send_message(
                source,
                allocate_response(
                    allocate_transaction_id,
                    public_relay_addr,
                    49152,
                    source,
                    &allocate_lifetime,
                ),
            ),
        ],
    );

    // Forward time
    let now = now + allocate_lifetime.lifetime() / 2;
    let second_wake = now + refresh_lifetime.lifetime();

    server.assert_commands(
        from_client(
            source,
            Refresh::new(
                refresh_transaction_id,
                Some(refresh_lifetime.clone()),
                valid_username(now, &username_salt),
                &secret,
                nonce,
            ),
            now,
        ),
        [
            Wake(second_wake),
            send_message(
                source,
                refresh_response(refresh_transaction_id, refresh_lifetime.clone()),
            ),
        ],
    );

    // The allocation MUST NOT be expired 1 sec before its refresh lifetime.
    // Note that depending on how the lifetimes were generated, this may still be before the initial allocation lifetime.
    // This is okay because lifetimes do not roll over, i.e. a refresh is not "added" to the initial lifetime but the allocation's lifetime is simply computed from now + requested lifetime of the refresh request.
    server.assert_commands(
        forward_time_to(now + refresh_lifetime.lifetime() - Duration::from_secs(1)),
        [],
    );
}
#[proptest]
fn when_receiving_lifetime_0_for_existing_allocation_then_delete(
    #[strategy(firezone_relay::proptest::transaction_id())] allocate_transaction_id: TransactionId,
    #[strategy(firezone_relay::proptest::transaction_id())] refresh_transaction_id: TransactionId,
    #[strategy(firezone_relay::proptest::allocation_lifetime())] allocate_lifetime: Lifetime,
    #[strategy(firezone_relay::proptest::username_salt())] username_salt: String,
    source: SocketAddrV4,
    public_relay_addr: Ipv4Addr,
    #[strategy(firezone_relay::proptest::now())] now: SystemTime,
    #[strategy(firezone_relay::proptest::nonce())] nonce: Uuid,
) {
    let mut server = TestServer::new(public_relay_addr).with_nonce(nonce);
    let secret = server.auth_secret().to_owned();
    let first_wake = now + allocate_lifetime.lifetime();

    server.assert_commands(
        from_client(
            source,
            Allocate::new_authenticated_udp_implicit_ip4(
                allocate_transaction_id,
                Some(allocate_lifetime.clone()),
                valid_username(now, &username_salt),
                &secret,
                nonce,
            ),
            now,
        ),
        [
            Wake(first_wake),
            CreateAllocation(49152, AddressFamily::V4),
            send_message(
                source,
                allocate_response(
                    allocate_transaction_id,
                    public_relay_addr,
                    49152,
                    source,
                    &allocate_lifetime,
                ),
            ),
        ],
    );

    // Forward time
    let now = now + allocate_lifetime.lifetime() / 2;

    server.assert_commands(
        from_client(
            source,
            Refresh::new(
                refresh_transaction_id,
                Some(Lifetime::new(Duration::ZERO).unwrap()),
                valid_username(now, &username_salt),
                &secret,
                nonce,
            ),
            now,
        ),
        [
            FreeAllocation(49152, AddressFamily::V4),
            send_message(
                source,
                refresh_response(
                    refresh_transaction_id,
                    Lifetime::new(Duration::ZERO).unwrap(),
                ),
            ),
        ],
    );

    // Assert that forwarding time does not produce an obsolete event.
    server.assert_commands(forward_time_to(first_wake + Duration::from_secs(1)), []);
}

// #[test]
// fn server_waits_for_5_minutes_before_allowing_reuse_of_channel_number_after_expiry() {
//     // todo!()
// }

#[proptest]
fn ping_pong_relay(
    #[strategy(firezone_relay::proptest::transaction_id())] allocate_transaction_id: TransactionId,
    #[strategy(firezone_relay::proptest::transaction_id())]
    channel_bind_transaction_id: TransactionId,
    #[strategy(firezone_relay::proptest::allocation_lifetime())] lifetime: Lifetime,
    #[strategy(firezone_relay::proptest::username_salt())] username_salt: String,
    #[strategy(firezone_relay::proptest::channel_number())] channel: ChannelNumber,
    source: SocketAddrV4,
    peer: SocketAddrV4,
    public_relay_addr: Ipv4Addr,
    #[strategy(firezone_relay::proptest::now())] now: SystemTime,
    peer_to_client_ping: [u8; 32],
    client_to_peer_ping: [u8; 32],
    #[strategy(firezone_relay::proptest::nonce())] nonce: Uuid,
) {
    let _ = env_logger::try_init();

    let mut server = TestServer::new(public_relay_addr).with_nonce(nonce);
    let secret = server.auth_secret().to_owned();

    server.assert_commands(
        from_client(
            source,
            Allocate::new_authenticated_udp_implicit_ip4(
                allocate_transaction_id,
                Some(lifetime.clone()),
                valid_username(now, &username_salt),
                &secret,
                nonce,
            ),
            now,
        ),
        [
            Wake(now + lifetime.lifetime()),
            CreateAllocation(49152, AddressFamily::V4),
            send_message(
                source,
                allocate_response(
                    allocate_transaction_id,
                    public_relay_addr,
                    49152,
                    source,
                    &lifetime,
                ),
            ),
        ],
    );

    let now = now + Duration::from_secs(1);

    server.assert_commands(
        from_client(
            source,
            ChannelBind::new(
                channel_bind_transaction_id,
                channel,
                XorPeerAddress::new(peer.into()),
                valid_username(now, &username_salt),
                &secret,
                nonce,
            ),
            now,
        ),
        [send_message(
            source,
            channel_bind_response(channel_bind_transaction_id),
        )],
    );

    let now = now + Duration::from_secs(1);

    server.assert_commands(
        from_client(
            source,
            ChannelData::new(channel.value(), client_to_peer_ping.as_ref()),
            now,
        ),
        [forward(peer, &client_to_peer_ping, 49152)],
    );

    server.assert_commands(
        from_peer(peer, peer_to_client_ping.as_ref(), 49152),
        [send_channel_data(
            source,
            ChannelData::new(channel.value(), peer_to_client_ping.as_ref()),
        )],
    );
}

#[proptest]
fn ping_pong_ip6_relay(
    #[strategy(firezone_relay::proptest::transaction_id())] allocate_transaction_id: TransactionId,
    #[strategy(firezone_relay::proptest::transaction_id())]
    channel_bind_transaction_id: TransactionId,
    #[strategy(firezone_relay::proptest::allocation_lifetime())] lifetime: Lifetime,
    #[strategy(firezone_relay::proptest::username_salt())] username_salt: String,
    #[strategy(firezone_relay::proptest::channel_number())] channel: ChannelNumber,
    source: SocketAddrV6,
    peer: SocketAddrV6,
    public_relay_ip4_addr: Ipv4Addr,
    public_relay_ip6_addr: Ipv6Addr,
    #[strategy(firezone_relay::proptest::now())] now: SystemTime,
    peer_to_client_ping: [u8; 32],
    client_to_peer_ping: [u8; 32],
    #[strategy(firezone_relay::proptest::nonce())] nonce: Uuid,
) {
    let _ = env_logger::try_init();

    let mut server =
        TestServer::new((public_relay_ip4_addr, public_relay_ip6_addr)).with_nonce(nonce);
    let secret = server.auth_secret().to_owned();

    server.assert_commands(
        from_client(
            source,
            Allocate::new_authenticated_udp_ip6(
                allocate_transaction_id,
                Some(lifetime.clone()),
                valid_username(now, &username_salt),
                &secret,
                nonce,
            ),
            now,
        ),
        [
            Wake(now + lifetime.lifetime()),
            CreateAllocation(49152, AddressFamily::V6),
            send_message(
                source,
                allocate_response(
                    allocate_transaction_id,
                    public_relay_ip6_addr,
                    49152,
                    source,
                    &lifetime,
                ),
            ),
        ],
    );

    let now = now + Duration::from_secs(1);

    server.assert_commands(
        from_client(
            source,
            ChannelBind::new(
                channel_bind_transaction_id,
                channel,
                XorPeerAddress::new(peer.into()),
                valid_username(now, &username_salt),
                &secret,
                nonce,
            ),
            now,
        ),
        [send_message(
            source,
            channel_bind_response(channel_bind_transaction_id),
        )],
    );

    let now = now + Duration::from_secs(1);

    server.assert_commands(
        from_client(
            source,
            ChannelData::new(channel.value(), client_to_peer_ping.as_ref()),
            now,
        ),
        [forward(peer, &client_to_peer_ping, 49152)],
    );

    server.assert_commands(
        from_peer(peer, peer_to_client_ping.as_ref(), 49152),
        [send_channel_data(
            source,
            ChannelData::new(channel.value(), peer_to_client_ping.as_ref()),
        )],
    );
}

struct TestServer {
    server: Server<StepRng>,
    id_to_port: HashMap<u16, AllocationId>,
}

impl TestServer {
    fn new(relay_public_addr: impl Into<IpStack>) -> Self {
        Self {
            server: Server::new(relay_public_addr, StepRng::new(0, 0), 49152, 65535),
            id_to_port: Default::default(),
        }
    }

    fn with_nonce(mut self, nonce: Uuid) -> Self {
        self.server.add_nonce(nonce);

        self
    }

    fn auth_secret(&self) -> &SecretString {
        self.server.auth_secret()
    }

    fn assert_commands<const N: usize>(&mut self, input: Input, output: [Output; N]) {
        match input {
            Input::Client(sender, message, now) => {
                self.server.handle_client_message(message, sender, now);
            }
            Input::Time(now) => {
                self.server.handle_deadline_reached(now);
            }
            Input::Peer(peer, data, port) => {
                self.server
                    .handle_peer_traffic(&data, peer, self.id_to_port[&port]);
            }
        }

        for expected_output in output {
            let Some(actual_output) = self.server.next_command() else {
                let msg = match expected_output {
                    Output::SendMessage((recipient, msg)) => {
                        format!("to send message {:?} to {recipient}", msg)
                    }
                    Wake(time) => format!("to be woken at {time:?}"),
                    CreateAllocation(port, family) => {
                        format!("to create allocation on port {port} for address family {family}")
                    }
                    FreeAllocation(port, family) => {
                        format!("to free allocation on port {port} for address family {family}")
                    }
                    Output::SendChannelData((peer, _)) => {
                        format!("to send channel data from {peer} to client")
                    }
                    Output::Forward((peer, _, _)) => format!("to forward data to peer {peer}"),
                };

                panic!("No commands produced but expected {msg}");
            };

            match (expected_output, actual_output) {
                (
                    Output::SendMessage((to, message)),
                    Command::SendMessage { payload, recipient },
                ) => {
                    let expected_bytes = MessageEncoder::new()
                        .encode_into_bytes(message.clone())
                        .unwrap();

                    if expected_bytes != payload {
                        let expected_message = format!("{:?}", message);
                        let actual_message = format!("{:?}", parse_message(&payload));

                        difference::assert_diff!(&expected_message, &actual_message, "\n", 0);
                    }

                    assert_eq!(recipient, to);
                }
                (Wake(when), Command::Wake { deadline }) => {
                    assert_eq!(when, deadline);
                }
                (
                    CreateAllocation(expected_port, expected_family),
                    Command::CreateAllocation {
                        id,
                        family: actual_family,
                        port: actual_port,
                    },
                ) => {
                    self.id_to_port.insert(actual_port, id);
                    assert_eq!(expected_port, actual_port);
                    assert_eq!(expected_family, actual_family);
                }
                (
                    FreeAllocation(port, family),
                    Command::FreeAllocation {
                        id,
                        family: actual_family,
                    },
                ) => {
                    let actual_id = self.id_to_port.remove(&port).expect("to have port in map");
                    assert_eq!(id, actual_id);
                    assert_eq!(family, actual_family);
                }
                (Wake(when), Command::SendMessage { payload, .. }) => {
                    panic!(
                        "Expected `Wake({})`, got `SendMessage({:?})`",
                        when.duration_since(SystemTime::UNIX_EPOCH)
                            .unwrap()
                            .as_secs(),
                        parse_message(&payload)
                    )
                }
                (
                    Output::SendChannelData((peer, channeldata)),
                    Command::SendMessage { recipient, payload },
                ) => {
                    let expected_channel_data = hex::encode(channeldata.to_bytes());
                    let actual_message = hex::encode(payload);

                    assert_eq!(expected_channel_data, actual_message);
                    assert_eq!(recipient, peer);
                }
                (
                    Output::Forward((peer, expected_data, port)),
                    Command::ForwardData {
                        id,
                        data: actual_data,
                        receiver,
                    },
                ) => {
                    assert_eq!(hex::encode(expected_data), hex::encode(actual_data));
                    assert_eq!(receiver, peer);
                    assert_eq!(self.id_to_port[&port], id);
                }
                (expected, actual) => panic!("Unhandled combination: {expected:?} {actual:?}"),
            }
        }

        let remaining_commands = iter::from_fn(|| self.server.next_command()).collect::<Vec<_>>();

        assert_eq!(remaining_commands, vec![])
    }
}

fn valid_username(now: SystemTime, salt: &str) -> Username {
    let now_unix = now
        .duration_since(SystemTime::UNIX_EPOCH)
        .unwrap()
        .as_secs();

    let expiry = now_unix + 1000;

    Username::new(format!("{expiry}:{salt}")).unwrap()
}

fn binding_response(
    transaction_id: TransactionId,
    address: impl Into<SocketAddr>,
) -> Message<Attribute> {
    let mut message =
        Message::<Attribute>::new(MessageClass::SuccessResponse, BINDING, transaction_id);
    message.add_attribute(XorMappedAddress::new(address.into()));

    message
}

fn allocate_response(
    transaction_id: TransactionId,
    public_relay_addr: impl Into<IpAddr>,
    port: u16,
    source: impl Into<SocketAddr>,
    lifetime: &Lifetime,
) -> Message<Attribute> {
    let mut message =
        Message::<Attribute>::new(MessageClass::SuccessResponse, ALLOCATE, transaction_id);
    message.add_attribute(XorRelayAddress::new(SocketAddr::new(
        public_relay_addr.into(),
        port,
    )));
    message.add_attribute(XorMappedAddress::new(source.into()));
    message.add_attribute(lifetime.clone());

    message
}

fn unauthorized_allocate_response(
    transaction_id: TransactionId,
    nonce: Uuid,
) -> Message<Attribute> {
    let mut message =
        Message::<Attribute>::new(MessageClass::ErrorResponse, ALLOCATE, transaction_id);
    message.add_attribute(ErrorCode::from(Unauthorized));
    message.add_attribute(Nonce::new(nonce.as_hyphenated().to_string()).unwrap());
    message.add_attribute(Realm::new("firezone".to_owned()).unwrap());

    message
}

fn refresh_response(transaction_id: TransactionId, lifetime: Lifetime) -> Message<Attribute> {
    let mut message =
        Message::<Attribute>::new(MessageClass::SuccessResponse, REFRESH, transaction_id);
    message.add_attribute(lifetime);

    message
}

fn channel_bind_response(transaction_id: TransactionId) -> Message<Attribute> {
    Message::<Attribute>::new(MessageClass::SuccessResponse, CHANNEL_BIND, transaction_id)
}

fn parse_message(message: &[u8]) -> Message<Attribute> {
    MessageDecoder::new()
        .decode_from_bytes(message)
        .unwrap()
        .unwrap()
}

enum Input<'a> {
    Client(ClientSocket, ClientMessage<'a>, SystemTime),
    Peer(PeerSocket, Vec<u8>, u16),
    Time(SystemTime),
}

fn from_client<'a>(
    from: impl Into<SocketAddr>,
    message: impl Into<ClientMessage<'a>>,
    now: SystemTime,
) -> Input<'a> {
    Input::Client(ClientSocket::new(from.into()), message.into(), now)
}

fn from_peer<'a>(from: impl Into<SocketAddr>, data: &[u8], port: u16) -> Input<'a> {
    Input::Peer(PeerSocket::new(from.into()), data.to_vec(), port)
}

fn forward_time_to<'a>(when: SystemTime) -> Input<'a> {
    Input::Time(when)
}

#[derive(Debug)]
enum Output<'a> {
    SendMessage((ClientSocket, Message<Attribute>)),
    SendChannelData((ClientSocket, ChannelData<'a>)),
    Forward((PeerSocket, Vec<u8>, u16)),
    Wake(SystemTime),
    CreateAllocation(u16, AddressFamily),
    FreeAllocation(u16, AddressFamily),
}

fn send_message<'a>(source: impl Into<SocketAddr>, message: Message<Attribute>) -> Output<'a> {
    Output::SendMessage((ClientSocket::new(source.into()), message))
}

fn send_channel_data(source: impl Into<SocketAddr>, message: ChannelData) -> Output {
    Output::SendChannelData((ClientSocket::new(source.into()), message))
}

fn forward(source: impl Into<SocketAddr>, data: &[u8], port: u16) -> Output {
    Output::Forward((PeerSocket::new(source.into()), data.to_vec(), port))
}
