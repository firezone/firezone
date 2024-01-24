use arc_swap::ArcSwapOption;
use bytes::Bytes;
use futures::channel::mpsc;
use futures_util::SinkExt;
use ip_network::IpNetwork;
use ip_network_table::IpNetworkTable;
use std::{collections::HashSet, fmt, net::SocketAddr, sync::Arc};

use connlib_shared::{
    messages::{Relay, RequestConnection, ReuseConnection},
    Callbacks, Error, Result,
};

use crate::{
    device_channel::Device,
    peer::{PacketTransform, Peer},
    peer_handler, ConnectedPeer, RoleState, Tunnel,
};

mod client;
mod gateway;

const ICE_CANDIDATE_BUFFER: usize = 100;
// We should use not more than 1-2 relays (WebRTC in Firefox breaks at 5) due to combinatoric
// complexity of checking all the ICE candidate pairs
const MAX_RELAYS: usize = 2;

const MAX_HOST_CANDIDATES: usize = 8;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Request {
    NewConnection(RequestConnection),
    ReuseConnection(ReuseConnection),
}

impl<CB, TRoleState> Tunnel<CB, TRoleState>
where
    CB: Callbacks + 'static,
    TRoleState: RoleState,
{
    pub async fn add_ice_candidate(
        &self,
        conn_id: TRoleState::Id,
        ice_candidate: String,
    ) -> Result<()> {
        tracing::info!(%ice_candidate, %conn_id, "adding new remote candidate");
        todo!();
        // let peer_connection = self
        //     .peer_connections
        //     .lock()
        //     .get(&conn_id)
        //     .ok_or(Error::ControlProtocolError)?
        //     .clone();
        // peer_connection
        //     .add_remote_candidate(Some(ice_candidate))
        //     .await?;
        Ok(())
    }
}

fn insert_peers<TId: Copy, TTransform>(
    peers_by_ip: &mut IpNetworkTable<ConnectedPeer<TId, TTransform>>,
    ips: &Vec<IpNetwork>,
    peer: ConnectedPeer<TId, TTransform>,
) {
    for ip in ips {
        peers_by_ip.insert(*ip, peer.clone());
    }
}

fn start_handlers<TId, TTransform, TRoleState>(
    tunnel: Arc<Tunnel<impl Callbacks + 'static, TRoleState>>,
    device: Arc<ArcSwapOption<Device>>,
    peer: Arc<Peer<TId, TTransform>>,
    // TODO:
    // ice: Arc<RTCIceTransport>,
    peer_receiver: tokio::sync::mpsc::Receiver<Bytes>,
) where
    TId: Copy + Send + Sync + fmt::Debug + 'static,
    TTransform: Send + Sync + PacketTransform + 'static,
    TRoleState: RoleState<Id = TId>,
{
    let conn_id = peer.conn_id;
    //TODO:
    // ice.on_connection_state_change(Box::new(move |state| {
    //     let tunnel = tunnel.clone();
    //     Box::pin(async move {
    //         if state == RTCIceTransportState::Failed {
    //             tunnel.peers_to_stop.lock().push_back(conn_id);
    //         }
    //     })
    // }));

    tokio::spawn({
        async move {
            // If this fails receiver will be dropped and the connection will expire at some point
            // this will not fail though, since this is always called after start ice
            tokio::spawn(peer_handler::start_peer_handler(device, peer, todo!()));
            tokio::spawn(peer_handler::handle_packet(todo!(), peer_receiver));
        }
    });
}

fn stun(relays: &[Relay]) -> HashSet<SocketAddr> {
    relays
        .iter()
        .filter_map(|r| {
            if let Relay::Stun(r) = r {
                Some(r.addr)
            } else {
                None
            }
        })
        .collect()
}

fn turn(relays: &[Relay]) -> HashSet<SocketAddr> {
    relays
        .iter()
        .filter_map(|r| {
            if let Relay::Turn(r) = r {
                Some(r.addr)
            } else {
                None
            }
        })
        .collect()
}
