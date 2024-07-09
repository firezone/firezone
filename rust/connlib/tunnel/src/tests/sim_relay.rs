use super::sim_net::Host;
use super::strategies::{host_ip4s, host_ip6s};
use connlib_shared::messages::RelayId;
use firezone_relay::{AddressFamily, AllocationPort, ClientSocket, IpStack, PeerSocket};
use proptest::prelude::*;
use rand::rngs::StdRng;
use snownet::{RelaySocket, Transmit};
use std::{
    borrow::Cow,
    collections::HashSet,
    net::{IpAddr, SocketAddr, SocketAddrV4, SocketAddrV6},
    time::{Duration, Instant, SystemTime},
};

#[derive(Clone, derivative::Derivative)]
#[derivative(Debug)]
pub(crate) struct SimRelay<S> {
    pub(crate) state: S,

    ip_stack: firezone_relay::IpStack,
    pub(crate) allocations: HashSet<(AddressFamily, AllocationPort)>,

    #[derivative(Debug = "ignore")]
    buffer: Vec<u8>,
}

impl<S> SimRelay<S> {
    pub(crate) fn new(state: S, ip_stack: firezone_relay::IpStack) -> Self {
        Self {
            state,
            ip_stack,
            allocations: Default::default(),
            buffer: vec![0u8; (1 << 16) - 1],
        }
    }

    pub(crate) fn ip4(&self) -> Option<IpAddr> {
        self.ip_stack.as_v4().copied().map(|i| i.into())
    }

    pub(crate) fn ip6(&self) -> Option<IpAddr> {
        self.ip_stack.as_v6().copied().map(|i| i.into())
    }
}

impl<S> SimRelay<S>
where
    S: Copy,
{
    pub(crate) fn map<T>(&self, f: impl FnOnce(S) -> T) -> SimRelay<T> {
        SimRelay {
            state: f(self.state),
            allocations: self.allocations.clone(),
            buffer: self.buffer.clone(),
            ip_stack: self.ip_stack,
        }
    }
}

pub(crate) fn map_explode<'a>(
    relays: impl Iterator<
            Item = (
                &'a RelayId,
                &'a Host<SimRelay<firezone_relay::Server<StdRng>>>,
            ),
        > + 'a,
    username: &'static str,
) -> impl Iterator<Item = (RelayId, RelaySocket, String, String, String)> + 'a {
    relays.map(move |(id, r)| {
        let (socket, username, password, realm) = r.inner().explode(username);

        (*id, socket, username, password, realm)
    })
}

impl SimRelay<firezone_relay::Server<StdRng>> {
    fn explode(&self, username: &str) -> (RelaySocket, String, String, String) {
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

        (relay_socket, username, password, "firezone".to_owned())
    }

    fn matching_listen_socket(&self, other: SocketAddr) -> Option<SocketAddr> {
        match other {
            SocketAddr::V4(_) => Some(SocketAddr::new((*self.ip_stack.as_v4()?).into(), 3478)),
            SocketAddr::V6(_) => Some(SocketAddr::new((*self.ip_stack.as_v6()?).into(), 3478)),
        }
    }

    pub(crate) fn handle_packet(
        &mut self,
        payload: &[u8],
        sender: SocketAddr,
        dst: SocketAddr,
        now: Instant,
    ) -> Option<Transmit<'static>> {
        if self.matching_listen_socket(dst).is_some_and(|s| s == dst) {
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
        payload: &[u8],
        client: ClientSocket,
        now: Instant,
    ) -> Option<Transmit<'static>> {
        let (port, peer) = self.state.handle_client_input(payload, client, now)?;

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

        Some(Transmit {
            src: Some(src),
            dst,
            payload: Cow::Owned(payload.to_vec()),
        })
    }

    fn handle_peer_traffic(
        &mut self,
        payload: &[u8],
        peer: PeerSocket,
        port: AllocationPort,
    ) -> Option<Transmit<'static>> {
        let (client, channel) = self.state.handle_peer_traffic(payload, peer, port)?;

        let full_length = firezone_relay::ChannelData::encode_header_to_slice(
            channel,
            payload.len() as u16,
            &mut self.buffer[..4],
        );
        self.buffer[4..full_length].copy_from_slice(payload);

        let receiving_socket = client.into_socket();
        let sending_socket = self.matching_listen_socket(receiving_socket).unwrap();

        Some(Transmit {
            src: Some(sending_socket),
            dst: receiving_socket,
            payload: Cow::Owned(self.buffer[..full_length].to_vec()),
        })
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

pub(crate) fn sim_relay_prototype() -> impl Strategy<Value = Host<SimRelay<u64>>> {
    // For this test, our relays always run in dual-stack mode to ensure connectivity!
    let socket_ips = (host_ip4s(), host_ip6s()).prop_map(|(ip4, ip6)| IpStack::Dual { ip4, ip6 });

    (any::<u64>(), socket_ips).prop_map(move |(seed, ip_stack)| {
        let mut host = Host::new(SimRelay::new(seed, ip_stack));
        host.update_interface(ip_stack.as_v4().copied(), ip_stack.as_v6().copied(), 3478);

        host
    })
}
