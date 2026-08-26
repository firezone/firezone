#![no_main]

//! Exercises the relay's STUN & TURN message handling with attacker-controlled input.
//!
//! The relay only reaches its authentication code for a message carrying a `NONCE`
//! it issued itself, so a target that feeds raw bytes alone never gets past the
//! nonce check. An input is therefore a sequence of steps against one [`Server`]:
//! raw datagrams reach the decoder, structured requests are encoded on the fly
//! with the nonce the relay just handed out, and their `MESSAGE-INTEGRITY` is
//! derived from the server's own secret whenever the fuzzer asks for it. That
//! makes the whole `ALLOCATE` / `CHANNEL-BIND` / `REFRESH` state machine, and the
//! username parsing behind it, reachable from a single input.

use std::{
    net::{Ipv4Addr, Ipv6Addr, SocketAddr},
    ops::RangeInclusive,
    time::{Duration, Instant},
};

use arbitrary::Arbitrary;
use bytecodec::{DecodeExt as _, EncodeExt as _};
use libfuzzer_sys::fuzz_target;
use rand::{SeedableRng as _, rngs::StdRng};
use relay_proto::{
    AllocationPort, Attribute, ChannelData, ClientSocket, Command, IpStack, PeerSocket, Server,
    auth,
};
use secrecy::SecretString;
use stun_codec::{
    Message, MessageClass, MessageDecoder, MessageEncoder, Method, TransactionId,
    rfc5389::{
        attributes::{MessageIntegrity, Nonce, Software, Username},
        methods::BINDING,
    },
    rfc5766::{
        attributes::{ChannelNumber, Lifetime, RequestedTransport, XorPeerAddress},
        methods::{ALLOCATE, CHANNEL_BIND, CREATE_PERMISSION, REFRESH},
    },
    rfc8656::attributes::{AdditionalAddressFamily, AddressFamily, RequestedAddressFamily},
};
use tracing_subscriber::{
    EnvFilter, Layer as _, layer::SubscriberExt as _, util::SubscriberInitExt as _,
};
use uuid::Uuid;

/// The number of sockets the fuzzer can act as.
const NUM_CLIENTS: usize = 4;

/// The number of peers the fuzzer can bind channels to and send traffic from.
const NUM_PEERS: usize = 4;

/// The ports the relay hands out allocations from.
///
/// Deliberately tiny: it keeps `InsufficientCapacity` reachable and lets the
/// fuzzer address an existing allocation without having to guess a port out of
/// the 16k the RFC recommends.
const PORTS: RangeInclusive<u16> = 49152..=49155;

/// The port the relay listens on for client traffic.
const LISTEN_PORT: u16 = 3478;

/// Caps how long one case runs; the state machine is exercised across steps, not
/// within one.
const MAX_STEPS: usize = 32;

/// Caps the payload of a relayed packet, so a case stays fast.
const MAX_PAYLOAD: usize = 512;

fuzz_target!(|input: Input| {
    let _guard = init_fuzz_subscriber();

    let mut harness = Harness::new(input.seed, input.stack);

    for step in input.steps.into_iter().take(MAX_STEPS) {
        harness.apply(step);
    }
});

/// Drives one [`Server`] the way the relay's event loop does.
struct Harness {
    server: Server<StdRng>,
    now: Instant,

    /// The nonce the relay last handed out to each client.
    ///
    /// A real client reads this out of the 401 response and echoes it back, which
    /// is the only way to reach the authentication code behind it.
    issued_nonces: [Option<Uuid>; NUM_CLIENTS],
}

impl Harness {
    fn new(seed: u64, stack: Stack) -> Self {
        let public_address = match stack {
            Stack::Ip4 => IpStack::Ip4(Ipv4Addr::new(10, 0, 0, 1)),
            Stack::Ip6 => IpStack::Ip6(Ipv6Addr::new(0x2001, 0xdb8, 0, 0, 0, 0, 0, 1)),
            Stack::Dual => IpStack::Dual {
                ip4: Ipv4Addr::new(10, 0, 0, 1),
                ip6: Ipv6Addr::new(0x2001, 0xdb8, 0, 0, 0, 0, 0, 1),
            },
        };

        Self {
            server: Server::new(
                public_address,
                StdRng::seed_from_u64(seed),
                LISTEN_PORT,
                PORTS,
            ),
            now: Instant::now(),
            issued_nonces: [None; NUM_CLIENTS],
        }
    }

    fn apply(&mut self, step: Step<'_>) {
        match step {
            Step::Datagram { client, bytes } => {
                let len = bytes.len().min(MAX_PAYLOAD);

                self.handle_client_input(&bytes[..len], client);
            }
            Step::Request { client, request } => {
                let Some(bytes) = request.encode(self.server.auth_secret(), self.nonce_of(client))
                else {
                    return;
                };

                self.handle_client_input(&bytes, client);
            }
            Step::ChannelData {
                client,
                channel,
                payload,
            } => {
                let Ok(channel) = ChannelNumber::new(channel) else {
                    return;
                };
                let len = payload.len().min(MAX_PAYLOAD);

                let mut message = vec![0u8; len + 4];
                message[4..].copy_from_slice(&payload[..len]);
                ChannelData::encode_header_to_slice(channel, len as u16, &mut message[..4]);

                self.handle_client_input(&message, client);
            }
            Step::PeerTraffic { peer, port, data } => {
                let len = data.len().min(MAX_PAYLOAD);
                let port =
                    AllocationPort::new(PORTS.start() + port % (PORTS.end() - PORTS.start() + 1));

                self.server
                    .handle_peer_traffic(&data[..len], peer_socket(peer), port);
                self.drain_commands();
            }
            Step::AllocationFailed { port } => {
                let port =
                    AllocationPort::new(PORTS.start() + port % (PORTS.end() - PORTS.start() + 1));

                self.server.handle_allocation_failed(port);
                self.drain_commands();
            }
            Step::AdvanceTime { millis } => {
                self.now += Duration::from_millis(u64::from(millis));

                if self.server.poll_timeout().is_some_and(|at| at <= self.now) {
                    self.server.handle_timeout(self.now);
                    self.drain_commands();
                }
            }
        }
    }

    fn handle_client_input(&mut self, bytes: &[u8], client: u8) {
        let relay_to = self
            .server
            .handle_client_input(bytes, client_socket(client), self.now);

        // The relay's event loop re-parses the datagram as `ChannelData` whenever
        // this returns `Some`, and panics if that fails. Assert what production
        // relies on rather than the weaker "it did not panic".
        if relay_to.is_some() {
            ChannelData::parse(bytes)
                .expect("input to re-parse as `ChannelData` if the relay wants it relayed");
        }

        self.drain_commands();
    }

    fn drain_commands(&mut self) {
        while let Some(command) = self.server.next_command() {
            match command {
                Command::SendMessage { payload, recipient } => {
                    let message = MessageDecoder::<Attribute>::new()
                        .decode_from_bytes(&payload)
                        .expect("relay to only send decodable STUN messages")
                        .expect("relay to only send well-formed STUN attributes");

                    assert!(
                        message.get_attribute::<Software>().is_some(),
                        "every response to carry a `SOFTWARE` attribute"
                    );

                    self.remember_nonce(recipient, &message);
                }
                Command::CreateAllocation { port, family: _ }
                | Command::FreeAllocation { port, family: _ } => {
                    assert!(
                        PORTS.contains(&port.value()),
                        "allocations to stay within the configured port range"
                    );
                }
                Command::CreateChannelBinding { .. } | Command::DeleteChannelBinding { .. } => {}
            }
        }
    }

    /// Records the nonce of a 401 or 438 response, as a real client would.
    fn remember_nonce(&mut self, recipient: ClientSocket, message: &Message<Attribute>) {
        let Some(index) = client_index(recipient) else {
            return;
        };
        let Some(nonce) = message.get_attribute::<Nonce>() else {
            return;
        };
        let Ok(nonce) = nonce.value().parse::<Uuid>() else {
            return;
        };

        self.issued_nonces[index] = Some(nonce);
    }

    fn nonce_of(&self, client: u8) -> Option<Uuid> {
        self.issued_nonces[usize::from(client) % NUM_CLIENTS]
    }
}

#[derive(Arbitrary, Debug)]
struct Input<'a> {
    /// Seeds the relay's port allocation, so a case stays reproducible.
    seed: u64,
    stack: Stack,
    steps: Vec<Step<'a>>,
}

#[derive(Arbitrary, Debug)]
enum Stack {
    Ip4,
    Ip6,
    Dual,
}

#[derive(Arbitrary, Debug)]
enum Step<'a> {
    /// A datagram straight off the wire, reaching the decoder and nothing else.
    Datagram {
        client: u8,
        bytes: &'a [u8],
    },
    /// A STUN request, encoded before it is handed to the relay.
    Request {
        client: u8,
        request: Request<'a>,
    },
    /// A well-formed `ChannelData` message from a client.
    ChannelData {
        client: u8,
        channel: u16,
        payload: &'a [u8],
    },
    /// Data arriving on one of the relay's allocations.
    PeerTraffic {
        peer: u8,
        port: u16,
        data: &'a [u8],
    },
    /// The event loop failed to open the socket for an allocation.
    AllocationFailed {
        port: u16,
    },
    AdvanceTime {
        millis: u32,
    },
}

#[derive(Arbitrary, Debug)]
struct Request<'a> {
    method: RequestMethod,
    class: RequestClass,
    transaction_id: [u8; 12],
    username: UsernameSpec<'a>,
    credentials: Credentials<'a>,
    nonce: NonceSpec<'a>,
    lifetime: Option<u32>,
    requested_transport: Option<u8>,
    requested_address_family: Option<Family>,
    additional_address_family: Option<Family>,
    channel_number: Option<u16>,
    peer_address: Option<u8>,
}

impl Request<'_> {
    /// Encodes the request as it would arrive on the wire.
    ///
    /// Returns [`None`] for a combination `stun_codec` refuses to represent, e.g.
    /// a username longer than the attribute allows.
    fn encode(&self, relay_secret: &SecretString, issued_nonce: Option<Uuid>) -> Option<Vec<u8>> {
        let mut message = Message::<Attribute>::new(
            self.class.into_class(),
            self.method.into_method(),
            TransactionId::new(self.transaction_id),
        );

        if let Some(protocol) = self.requested_transport {
            message.add_attribute(RequestedTransport::new(protocol));
        }
        if let Some(seconds) = self.lifetime {
            let lifetime = Lifetime::new(Duration::from_secs(u64::from(seconds))).ok()?;

            message.add_attribute(lifetime);
        }
        if let Some(family) = self.requested_address_family {
            message.add_attribute(RequestedAddressFamily::new(family.into_family()));
        }
        if let Some(family) = self.additional_address_family {
            message.add_attribute(AdditionalAddressFamily::new(family.into_family()));
        }
        if let Some(number) = self.channel_number
            && let Ok(number) = ChannelNumber::new(number)
        {
            message.add_attribute(number);
        }
        if let Some(peer) = self.peer_address {
            message.add_attribute(XorPeerAddress::new(peer_socket(peer).into_socket()));
        }

        let username = self.username.encode()?;
        if let Some(username) = &username {
            message.add_attribute(username.clone());
        }
        if let Some(nonce) = self.nonce.encode(issued_nonce)? {
            message.add_attribute(nonce);
        }

        // `MESSAGE-INTEGRITY` covers every attribute before it, so it goes last.
        if let Some(password) = self.credentials.password(&self.username, relay_secret) {
            let username = username?;
            let integrity = MessageIntegrity::new_long_term_credential(
                &message,
                &username,
                &auth::FIREZONE,
                &password,
            )
            .ok()?;

            message.add_attribute(integrity);
        }

        MessageEncoder::<Attribute>::new()
            .encode_into_bytes(message)
            .ok()
    }
}

#[derive(Arbitrary, Debug)]
enum UsernameSpec<'a> {
    /// The `{expiry}:{salt}` format the relay expects.
    ///
    /// Drawing `expiry` as a `u64` rather than mutating its decimal form is what
    /// reaches the boundary values: libFuzzer's ASCII-integer mutator can never
    /// grow a 10-digit timestamp into the 20 digits that overflow a `SystemTime`.
    Credentials {
        expiry: u64,
        salt: &'a str,
    },
    /// Any other text, exercising the splitting and the integer parse.
    Raw(&'a str),
    Missing,
}

impl UsernameSpec<'_> {
    /// Returns [`None`] if the name does not fit into a `USERNAME` attribute.
    fn encode(&self) -> Option<Option<Username>> {
        match self {
            UsernameSpec::Credentials { expiry, salt } => {
                Username::new(format!("{expiry}:{salt}")).ok().map(Some)
            }
            UsernameSpec::Raw(name) => Username::new((*name).to_owned()).ok().map(Some),
            UsernameSpec::Missing => Some(None),
        }
    }
}

#[derive(Arbitrary, Debug)]
enum Credentials<'a> {
    /// Sign with the password the relay derives for this username, the only
    /// combination that passes the `MESSAGE-INTEGRITY` check.
    Relay,
    /// Sign with a password of the fuzzer's choosing, which the check rejects.
    Other(&'a str),
    Missing,
}

impl Credentials<'_> {
    fn password(&self, username: &UsernameSpec, relay_secret: &SecretString) -> Option<String> {
        match self {
            Credentials::Missing => None,
            Credentials::Other(password) => Some((*password).to_owned()),
            Credentials::Relay => match username {
                UsernameSpec::Credentials { expiry, salt } => {
                    Some(auth::generate_password(relay_secret, *expiry, salt))
                }
                // Without a username in the relay's format there is no password to derive.
                UsernameSpec::Raw(_) | UsernameSpec::Missing => None,
            },
        }
    }
}

#[derive(Arbitrary, Debug)]
enum NonceSpec<'a> {
    /// Echo the nonce the relay last handed out to this client.
    Issued,
    /// A well-formed nonce the relay never issued.
    Unissued(u128),
    /// Any other text, exercising the UUID parse.
    Raw(&'a str),
    Missing,
}

impl NonceSpec<'_> {
    /// Returns [`None`] if the value does not fit into a `NONCE` attribute.
    fn encode(&self, issued: Option<Uuid>) -> Option<Option<Nonce>> {
        let value = match self {
            NonceSpec::Issued => match issued {
                Some(nonce) => nonce.as_hyphenated().to_string(),
                None => return Some(None),
            },
            NonceSpec::Unissued(value) => Uuid::from_u128(*value).as_hyphenated().to_string(),
            NonceSpec::Raw(value) => (*value).to_owned(),
            NonceSpec::Missing => return Some(None),
        };

        Nonce::new(value).ok().map(Some)
    }
}

#[derive(Arbitrary, Debug, Clone, Copy)]
enum RequestMethod {
    Binding,
    Allocate,
    Refresh,
    ChannelBind,
    CreatePermission,
    /// A method the relay does not implement.
    Unknown,
}

impl RequestMethod {
    fn into_method(self) -> Method {
        match self {
            RequestMethod::Binding => BINDING,
            RequestMethod::Allocate => ALLOCATE,
            RequestMethod::Refresh => REFRESH,
            RequestMethod::ChannelBind => CHANNEL_BIND,
            RequestMethod::CreatePermission => CREATE_PERMISSION,
            RequestMethod::Unknown => {
                Method::new(0x00F).expect("0x00F is below the 12-bit method limit")
            }
        }
    }
}

#[derive(Arbitrary, Debug, Clone, Copy)]
enum RequestClass {
    Request,
    Indication,
    SuccessResponse,
    ErrorResponse,
}

impl RequestClass {
    fn into_class(self) -> MessageClass {
        match self {
            RequestClass::Request => MessageClass::Request,
            RequestClass::Indication => MessageClass::Indication,
            RequestClass::SuccessResponse => MessageClass::SuccessResponse,
            RequestClass::ErrorResponse => MessageClass::ErrorResponse,
        }
    }
}

#[derive(Arbitrary, Debug, Clone, Copy)]
enum Family {
    V4,
    V6,
}

impl Family {
    fn into_family(self) -> AddressFamily {
        match self {
            Family::V4 => AddressFamily::V4,
            Family::V6 => AddressFamily::V6,
        }
    }
}

/// The sockets the fuzzer sends from.
///
/// A fixed set rather than an arbitrary address, so a mutated input keeps
/// addressing the same client and the nonce issued to it stays usable. The last
/// entry has port 0, which the relay refuses to reply to.
fn client_socket(index: u8) -> ClientSocket {
    ClientSocket::new(match usize::from(index) % NUM_CLIENTS {
        0 => SocketAddr::from(([10, 0, 0, 2], 51820)),
        1 => SocketAddr::from(([10, 0, 0, 3], 51821)),
        2 => SocketAddr::from((Ipv6Addr::new(0x2001, 0xdb8, 0, 0, 0, 0, 0, 2), 51822)),
        _ => SocketAddr::from(([10, 0, 0, 4], 0)),
    })
}

fn client_index(socket: ClientSocket) -> Option<usize> {
    (0..NUM_CLIENTS).find(|index| client_socket(*index as u8) == socket)
}

/// The peers the fuzzer can bind channels to, covering both address families.
fn peer_socket(index: u8) -> PeerSocket {
    PeerSocket::new(match usize::from(index) % NUM_PEERS {
        0 => SocketAddr::from(([192, 0, 2, 1], 4000)),
        1 => SocketAddr::from(([192, 0, 2, 2], 4001)),
        2 => SocketAddr::from((Ipv6Addr::new(0x2001, 0xdb8, 0, 0, 0, 0, 1, 1), 4002)),
        _ => SocketAddr::from((Ipv6Addr::new(0x2001, 0xdb8, 0, 0, 0, 0, 1, 2), 4003)),
    })
}

/// Initializes a subscriber for the current fuzz case.
///
/// Mass fuzzing writes no logs; setting `RUST_LOG` additionally writes a trace to
/// stderr when reproducing a saved crash.
fn init_fuzz_subscriber() -> tracing::subscriber::DefaultGuard {
    let log_layer = std::env::var("RUST_LOG").ok().map(|filter| {
        tracing_subscriber::fmt::layer()
            .with_writer(std::io::stderr)
            .with_ansi(false)
            .with_filter(EnvFilter::new(filter))
    });

    tracing_subscriber::registry().with(log_layer).set_default()
}
