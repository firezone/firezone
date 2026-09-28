use super::sim_net::{ExecMutScope, Host};
use bufferpool::Buffer;
use bytecodec::{DecodeExt as _, EncodeExt as _};
use connlib_model::RelayId;
use ip_packet::Ecn;
use rand::{SeedableRng as _, rngs::StdRng};
use relay_proto::{AddressFamily, AllocationPort, Attribute, ClientSocket, IpStack, PeerSocket};
use secrecy::SecretString;
use snownet::{RelaySocket, Transmit};
use std::{
    collections::HashSet,
    net::{Ipv4Addr, Ipv6Addr, SocketAddr, SocketAddrV4, SocketAddrV6},
    time::{Duration, Instant, SystemTime},
};
use stun_codec::rfc5389::attributes::{ErrorCode, MessageIntegrity, Nonce, Realm, Username};
use stun_codec::rfc5766::{errors::InsufficientCapacity, methods::ALLOCATE};
use stun_codec::{Message, MessageClass, MessageDecoder, MessageEncoder};
use uuid::Uuid;

pub(crate) struct SimRelay {
    pub(crate) sut: relay_proto::Server<StdRng>,
    pub(crate) allocations: HashSet<(AddressFamily, AllocationPort)>,

    /// Whether authenticated `ALLOCATE` requests are answered with `508 Insufficient Capacity`,
    /// as if the relay had run out of ports. Existing allocations keep working.
    pub(crate) rejects_allocations: bool,

    created_at: SystemTime,
}

pub(crate) fn map_explode<'a>(
    relays: impl Iterator<Item = (&'a RelayId, &'a Host<SimRelay>)> + 'a,
    username: impl Into<String>,
) -> impl Iterator<Item = (RelayId, RelaySocket, String, String, String)> + 'a {
    let username = username.into();

    relays.map(move |(id, r)| {
        let (socket, username, password, realm) = r.inner().explode(
            &username,
            r.inner().sut.auth_secret(),
            r.inner().sut.public_address(),
        );

        (*id, socket, username, password, realm)
    })
}

impl SimRelay {
    pub(crate) fn new(
        seed: u64,
        ip4: Option<Ipv4Addr>,
        ip6: Option<Ipv6Addr>,
        created_at: SystemTime,
    ) -> Self {
        let mut sut = relay_proto::Server::new(
            IpStack::from((ip4, ip6)),
            rand::rngs::StdRng::seed_from_u64(seed),
            3478,
            49152..=65535,
        );
        sut.set_accounts([relay_proto::auth::AccountId::from(Uuid::nil())]);

        Self {
            sut,
            allocations: Default::default(),
            rejects_allocations: false,
            created_at,
        }
    }

    fn explode(
        &self,
        username: &str,
        auth_secret: &SecretString,
        public_address: IpStack,
    ) -> (RelaySocket, String, String, String) {
        let relay_socket = match public_address {
            relay_proto::IpStack::Ip4(ip4) => RelaySocket::V4(SocketAddrV4::new(ip4, 3478)),
            relay_proto::IpStack::Ip6(ip6) => RelaySocket::V6(SocketAddrV6::new(ip6, 3478, 0, 0)),
            relay_proto::IpStack::Dual { ip4, ip6 } => RelaySocket::Dual {
                v4: SocketAddrV4::new(ip4, 3478),
                v6: SocketAddrV6::new(ip6, 3478, 0, 0),
            },
        };

        let (username, password) = self.make_credentials(username, auth_secret);

        (relay_socket, username, password, "firezone".to_owned())
    }

    fn matching_listen_socket(
        &self,
        other: SocketAddr,
        public_address: IpStack,
    ) -> Option<SocketAddr> {
        match other {
            SocketAddr::V4(_) => Some(SocketAddr::new((*public_address.as_v4()?).into(), 3478)),
            SocketAddr::V6(_) => Some(SocketAddr::new((*public_address.as_v6()?).into(), 3478)),
        }
    }

    pub(crate) fn receive(
        &mut self,
        transmit: Transmit,
        now: Instant,
        now_utc: SystemTime,
    ) -> Option<Transmit> {
        let dst = transmit.dst;
        let mut payload = transmit.payload;
        let sender = transmit.src.unwrap();

        if self
            .matching_listen_socket(dst, self.sut.public_address())
            .is_some_and(|s| s == dst)
        {
            if self.rejects_allocations
                && let Some(response) = self.reject_allocation(&payload)
            {
                payload.clear();
                payload.extend_from_slice(&response);

                return Some(Transmit {
                    src: Some(dst),
                    dst: sender,
                    payload,
                    ecn: Ecn::NonEct,
                });
            }

            return self.handle_client_input(payload, ClientSocket::new(sender), now, now_utc);
        }

        self.handle_peer_traffic(
            payload,
            PeerSocket::new(sender),
            AllocationPort::new(dst.port()),
        )
    }

    /// Answers an `ALLOCATE` that already carries a nonce the way a relay without free ports does.
    ///
    /// Requests without a nonce still reach the server, so clients authenticate first, as they
    /// would against a real relay.
    fn reject_allocation(&self, payload: &[u8]) -> Option<Vec<u8>> {
        let request = MessageDecoder::<Attribute>::new()
            .decode_from_bytes(payload)
            .ok()?
            .ok()?;
        if request.class() != MessageClass::Request || request.method() != ALLOCATE {
            return None;
        }
        request.get_attribute::<Nonce>()?;
        let username = request.get_attribute::<Username>()?;

        let mut response = Message::<Attribute>::new(
            MessageClass::ErrorResponse,
            ALLOCATE,
            request.transaction_id(),
        );
        response.add_attribute(ErrorCode::from(InsufficientCapacity));
        let password =
            relay_proto::auth::generate_password(self.sut.auth_secret(), username.name());
        let realm = Realm::new("firezone".to_owned()).ok()?;
        let integrity =
            MessageIntegrity::new_long_term_credential(&response, username, &realm, &password)
                .ok()?;
        response.add_attribute(integrity);

        MessageEncoder::new().encode_into_bytes(response).ok()
    }

    fn handle_client_input(
        &mut self,
        mut payload: Buffer<Vec<u8>>,
        client: ClientSocket,
        now: Instant,
        now_utc: SystemTime,
    ) -> Option<Transmit> {
        let (port, peer) = self
            .sut
            .handle_client_input(&payload, client, now, now_utc)?;

        payload.shift_start_right(4);

        // The `dst` of the relayed packet is what TURN calls a "peer".
        let dst = peer.into_socket();

        // The `src_ip` is the relay's IP
        let src_ip = match dst {
            SocketAddr::V4(_) => {
                assert!(
                    self.allocations.contains(&(AddressFamily::V4, port)),
                    "IPv4 allocation to be present if we want to send to an IPv4 socket"
                );

                self.sut
                    .public_ip4()
                    .expect("listen on IPv4 if we have an allocation")
            }
            SocketAddr::V6(_) => {
                assert!(
                    self.allocations.contains(&(AddressFamily::V6, port)),
                    "IPv6 allocation to be present if we want to send to an IPv6 socket"
                );

                self.sut
                    .public_ip6()
                    .expect("listen on IPv6 if we have an allocation")
            }
        };

        // The `src` of the relayed packet is the relay itself _from_ the allocated port.
        let src = SocketAddr::new(src_ip, port.value());

        Some(Transmit {
            src: Some(src),
            dst,
            payload,
            ecn: Ecn::NonEct,
        })
    }

    fn handle_peer_traffic(
        &mut self,
        mut payload: Buffer<Vec<u8>>,
        peer: PeerSocket,
        port: AllocationPort,
    ) -> Option<Transmit> {
        let (client, channel) = self.sut.handle_peer_traffic(&payload, peer, port)?;

        let data_len = payload.len() as u16;
        let header = payload.shift_start_left(4);

        relay_proto::ChannelData::encode_header_to_slice(channel, data_len, header);

        let receiving_socket = client.into_socket();
        let sending_socket = self
            .matching_listen_socket(receiving_socket, self.sut.public_address())
            .unwrap();

        Some(Transmit {
            src: Some(sending_socket),
            dst: receiving_socket,
            payload,
            ecn: Ecn::NonEct,
        })
    }

    fn make_credentials(&self, username: &str, auth_secret: &SecretString) -> (String, String) {
        // Deliberately out of reach: a run simulates ~2h at most, so nothing expires.
        // Shortening it would cover the relay's expiry and re-auth paths, which nothing
        // does today, but the reference model needs to predict that first.
        const VALIDITY: Duration = Duration::from_secs(24 * 60 * 60);

        let secs = (self.created_at + VALIDITY)
            .duration_since(SystemTime::UNIX_EPOCH)
            .expect("expiry must be later than UNIX_EPOCH")
            .as_secs();

        let username = format!(
            "{secs}:{}:{username}",
            relay_proto::auth::hash_account_id(&relay_proto::auth::AccountId::from(Uuid::nil()))
        );
        let password = relay_proto::auth::generate_password(auth_secret, &username);

        (username, password)
    }
}

impl ExecMutScope for SimRelay {
    type Guard = ();

    fn enter(&self) -> Self::Guard {}
}

impl ExecMutScope for u64 {
    type Guard = ();

    fn enter(&self) -> Self::Guard {}
}
