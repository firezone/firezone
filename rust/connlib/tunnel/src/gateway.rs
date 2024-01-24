use crate::device_channel::Device;
use crate::peer::PacketTransformGateway;
use crate::sockets::UdpSockets;
use crate::{
    ConnectedPeer, Event, RoleState, Tunnel, ICE_GATHERING_TIMEOUT_SECONDS,
    MAX_CONCURRENT_ICE_GATHERING, MAX_UDP_SIZE,
};
use boringtun::x25519::StaticSecret;
use connlib_shared::messages::{ClientId, Interface as InterfaceConfig};
use connlib_shared::Callbacks;
use firezone_connection::{ConnectionPool, ServerConnectionPool};
use futures::channel::mpsc::Receiver;
use futures_bounded::{PushError, StreamMap};
use futures_util::FutureExt;
use if_watch::tokio::IfWatcher;
use ip_network_table::IpNetworkTable;
use itertools::Itertools;
use rand_core::OsRng;
use std::collections::VecDeque;
use std::sync::Arc;
use std::task::{ready, Context, Poll};
use std::time::Duration;

const PEERS_IPV4: &str = "100.64.0.0/11";
const PEERS_IPV6: &str = "fd00:2021:1111::/107";

impl<CB> Tunnel<CB, GatewayState>
where
    CB: Callbacks + 'static,
{
    /// Sets the interface configuration and starts background tasks.
    #[tracing::instrument(level = "trace", skip(self))]
    pub fn set_interface(&self, config: &InterfaceConfig) -> connlib_shared::Result<()> {
        // Note: the dns fallback strategy is irrelevant for gateways
        let device = Arc::new(Device::new(config, vec![], self.callbacks())?);

        let result_v4 = device.add_route(PEERS_IPV4.parse().unwrap(), self.callbacks());
        let result_v6 = device.add_route(PEERS_IPV6.parse().unwrap(), self.callbacks());
        result_v4.or(result_v6)?;

        self.device.store(Some(device.clone()));
        self.no_device_waker.wake();

        tracing::debug!("background_loop_started");

        Ok(())
    }

    /// Clean up a connection to a resource.
    // FIXME: this cleanup connection is wrong!
    pub fn cleanup_connection(&self, id: ClientId) {
        // TODO:
        // self.peer_connections.lock().remove(&id);
    }
}

/// [`Tunnel`] state specific to gateways.
pub struct GatewayState {
    #[allow(clippy::type_complexity)]
    pub peers_by_ip: IpNetworkTable<ConnectedPeer<ClientId, PacketTransformGateway>>,
    pub connection_pool: ServerConnectionPool<ClientId>,
    if_watcher: IfWatcher,
    udp_sockets: UdpSockets<MAX_UDP_SIZE>,
    relay_socket: tokio::net::UdpSocket,
}

impl Default for GatewayState {
    fn default() -> Self {
        let if_watcher = IfWatcher::new().expect(
            "Program should be able to list interfaces on the system. Check binary's permissions",
        );
        let mut connection_pool = ConnectionPool::new(
            StaticSecret::random_from_rng(OsRng),
            std::time::Instant::now(),
        );
        let mut udp_sockets = UdpSockets::default();

        for ip in if_watcher.iter() {
            tracing::info!(address = %ip.addr(), "New local interface address found");
            match udp_sockets.bind((ip.addr(), 0)) {
                Ok(addr) => connection_pool.add_local_interface(addr),
                Err(e) => {
                    tracing::debug!(address = %ip.addr(), err = ?e, "Couldn't bind socket to interface: {e:#?}")
                }
            }
        }

        let relay_socket = tokio::net::UdpSocket::bind("0.0.0.0:0")
            .now_or_never()
            .expect("binding to `SocketAddr` is not async")
            // Note: We could relax this condition
            .expect("Program should be able to bind to 0.0.0.0:0 to be able to connect to relays");

        Self {
            peers_by_ip: IpNetworkTable::new(),
            connection_pool,
            if_watcher,
            udp_sockets,
            relay_socket,
        }
    }
}

impl RoleState for GatewayState {
    type Id = ClientId;

    fn add_remote_candidate(&mut self, conn_id: ClientId, ice_candidate: String) {
        self.connection_pool
            .add_remote_candidate(conn_id, ice_candidate);
    }

    fn poll_next_event(&mut self, cx: &mut Context<'_>) -> Poll<Event<Self::Id>> {
        loop {
            while let Some(transmit) = self.connection_pool.poll_transmit() {
                if let Err(e) = match transmit.src {
                    Some(src) => self
                        .udp_sockets
                        .try_send_to(src, transmit.dst, &transmit.payload),
                    None => self
                        .relay_socket
                        .try_send_to(&transmit.payload, transmit.dst),
                } {
                    tracing::warn!(src = ?transmit.src, dst = %transmit.dst, "Failed to send UDP packet: {e:#?}");
                }
            }

            match self.connection_pool.poll_event() {
                Some(firezone_connection::Event::SignalIceCandidate {
                    connection,
                    candidate,
                }) => {
                    return Poll::Ready(Event::SignalIceCandidate {
                        conn_id: connection,
                        candidate,
                    })
                }
                Some(firezone_connection::Event::ConnectionEstablished(id)) => todo!(),
                Some(firezone_connection::Event::ConnectionFailed(id)) => todo!(),
                None => {}
            }

            match self.if_watcher.poll_if_event(cx) {
                Poll::Ready(Ok(ev)) => match ev {
                    if_watch::IfEvent::Up(ip) => {
                        tracing::info!(address = %ip.addr(), "New local interface address found");
                        match self.udp_sockets.bind((ip.addr(), 0)) {
                            Ok(addr) => self.connection_pool.add_local_interface(addr),
                            Err(e) => {
                                tracing::debug!(address = %ip.addr(), err = ?e, "Couldn't bind socket to interface: {e:#?}")
                            }
                        }
                    }
                    if_watch::IfEvent::Down(ip) => {
                        tracing::info!(address = %ip.addr(), "Interface IP no longer available");
                        todo!()
                    }
                },
                Poll::Ready(Err(e)) => {
                    tracing::debug!("Error while polling interfces: {e:#?}");
                }
                Poll::Pending => {}
            }
        }
    }

    fn remove_peers(&mut self, conn_id: ClientId) {
        self.peers_by_ip.retain(|_, p| p.inner.conn_id != conn_id);
    }

    fn refresh_peers(&mut self) -> VecDeque<Self::Id> {
        let mut peers_to_stop = VecDeque::new();
        for (_, peer) in self.peers_by_ip.iter().unique_by(|(_, p)| p.inner.conn_id) {
            let conn_id = peer.inner.conn_id;

            peer.inner.transform.expire_resources();

            if peer.inner.transform.is_emptied() {
                tracing::trace!(%conn_id, "peer_expired");
                peers_to_stop.push_back(conn_id);

                continue;
            }

            // TODO:
            // let bytes = match peer.inner.update_timers() {
            //     Ok(Some(bytes)) => bytes,
            //     Ok(None) => continue,
            //     Err(e) => {
            //         tracing::error!("Failed to update timers for peer: {e}");
            //         if e.is_fatal_connection_error() {
            //             peers_to_stop.push_back(conn_id);
            //         }

            //         continue;
            //     }
            // };

            let peer_channel = peer.channel.clone();

            tokio::spawn(async move {
                if let Err(e) = peer_channel.send(todo!()).await {
                    tracing::error!("Failed to send packet to peer: {e:#}");
                }
            });
        }

        peers_to_stop
    }
}
