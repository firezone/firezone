use super::{
    sim_net::{Host, dual_ip_stack, host},
    strategies::latency,
};
use bufferpool::Buffer;
use connlib_model::RelayId;
use firezone_relay::{AddressFamily, AllocationPort, ClientSocket, IpStack, PeerSocket};
use ip_packet::Ecn;
use proptest::prelude::*;
use rand::{SeedableRng as _, rngs::StdRng};
use secrecy::SecretString;
use snownet::{RelaySocket, Transmit};
use std::{
    collections::HashSet,
    net::{Ipv4Addr, Ipv6Addr, SocketAddr, SocketAddrV4, SocketAddrV6},
    time::{Duration, Instant, SystemTime},
};

pub(crate) struct SimRelay {
    pub(crate) sut: firezone_relay::Server<StdRng>,
    pub(crate) allocations: HashSet<(AddressFamily, AllocationPort)>,

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
    pub(crate) fn new(seed: u64, ip4: Option<Ipv4Addr>, ip6: Option<Ipv6Addr>) -> Self {
        let sut = firezone_relay::Server::new(
            IpStack::from((ip4, ip6)),
            rand::rngs::StdRng::seed_from_u64(seed),
            3478,
            49152..=65535,
        );

        Self {
            sut,
            allocations: Default::default(),
            created_at: SystemTime::now(),
        }
    }

    fn explode(
        &self,
        username: &str,
        auth_secret: &SecretString,
        public_address: IpStack,
    ) -> (RelaySocket, String, String, String) {
        let relay_socket = match public_address {
            firezone_relay::IpStack::Ip4(ip4) => RelaySocket::V4(SocketAddrV4::new(ip4, 3478)),
            firezone_relay::IpStack::Ip6(ip6) => {
                RelaySocket::V6(SocketAddrV6::new(ip6, 3478, 0, 0))
            }
            firezone_relay::IpStack::Dual { ip4, ip6 } => RelaySocket::Dual {
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

    pub(crate) fn receive(&mut self, transmit: Transmit, now: Instant) -> Option<Transmit> {
        let dst = transmit.dst;
        let payload = transmit.payload;
        let sender = transmit.src.unwrap();

        if self
            .matching_listen_socket(dst, self.sut.public_address())
            .is_some_and(|s| s == dst)
        {
            return self.handle_client_input(payload, ClientSocket::new(sender), now);
        }

        self.handle_peer_traffic(
            payload,
            PeerSocket::new(sender),
            AllocationPort::new(dst.port()),
        )
    }

    fn handle_client_input(
        &mut self,
        mut payload: Buffer<Vec<u8>>,
        client: ClientSocket,
        now: Instant,
    ) -> Option<Transmit> {
        let (port, peer) = self.sut.handle_client_input(&payload, client, now)?;

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

        firezone_relay::ChannelData::encode_header_to_slice(channel, data_len, header);

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
        const ONE_HOUR: Duration = Duration::from_secs(60 * 60);

        let expiry = self.created_at + ONE_HOUR;

        let secs = expiry
            .duration_since(SystemTime::UNIX_EPOCH)
            .expect("expiry must be later than UNIX_EPOCH")
            .as_secs();

        let password = firezone_relay::auth::generate_password(auth_secret, secs, username);

        (format!("{secs}:{username}"), password)
    }
}

pub(crate) fn ref_relay_host() -> impl Strategy<Value = Host<u64>> {
    host(
        dual_ip_stack(), // For this test, our relays always run in dual-stack mode to ensure connectivity!
        relay_port(),
        any::<u64>(),
        latency(50), // We assume our relays have a good Internet connection.
    )
}

fn relay_port() -> impl Strategy<Value = u16> {
    prop_oneof![
        10 => Just(3478),
        1 => any::<u16>()
    ]
}
