use core::fmt;
use std::collections::{HashMap, hash_map::Entry};
use std::hash::Hash;
use std::net::IpAddr;

use connlib_model::{ClientId, GatewayId, ResourceId};
use ip_network::IpNetwork;
use ip_network_table::IpNetworkTable;

use crate::client::{ClientOnClient, GatewayOnClient};
use crate::gateway::ClientOnGateway;

pub(crate) struct PeerStore<TId, P> {
    id_by_ip: IpNetworkTable<TId>,
    peer_by_id: HashMap<TId, P>,
}

impl<TId, P> Default for PeerStore<TId, P> {
    fn default() -> Self {
        Self {
            id_by_ip: IpNetworkTable::new(),
            peer_by_id: HashMap::new(),
        }
    }
}

impl PeerStore<GatewayId, GatewayOnClient> {
    pub(crate) fn add_ips_with_resource(
        &mut self,
        id: &GatewayId,
        ips: impl IntoIterator<Item = impl Into<IpNetwork>>,
        resource: &ResourceId,
    ) {
        for ip in ips {
            let ip = ip.into();

            let Some(peer) = self.add_ip(id, &ip) else {
                continue;
            };
            peer.insert_id(&ip, resource);
        }
    }
}

impl<TId, P> PeerStore<TId, P>
where
    TId: Hash + Eq + Copy + fmt::Debug + fmt::Display,
    P: Peer<Id = TId>,
{
    pub(crate) fn extract_if(&mut self, f: impl Fn(&TId, &mut P) -> bool) -> Vec<(TId, P)> {
        let removed_peers = self
            .peer_by_id
            .extract_if(|id, peer| f(id, peer))
            .collect::<Vec<_>>();

        self.id_by_ip
            .retain(|_, id| self.peer_by_id.contains_key(id));

        removed_peers
    }

    pub(crate) fn add_ip(&mut self, id: &TId, ip: &IpNetwork) -> Option<&mut P> {
        let peer = self.peer_by_id.get_mut(id)?;
        let previous = self.id_by_ip.insert(*ip, *id);

        if previous.is_some_and(|prev| prev != *id) {
            tracing::warn!(%ip, %id, ?previous, "Broken invariant: IP was already assigned to another peer");
        }

        Some(peer)
    }

    pub(crate) fn insert(&mut self, peer: P, ips: &[IpNetwork]) -> Option<P> {
        self.id_by_ip.retain(|_, &mut r_id| r_id != peer.id());

        let id = peer.id();
        let old_peer = self.peer_by_id.insert(id, peer);

        for ip in ips {
            self.add_ip(&id, ip);
        }

        old_peer
    }

    pub(crate) fn entry(&mut self, id: TId) -> Entry<'_, TId, P> {
        self.peer_by_id.entry(id)
    }

    pub(crate) fn remove(&mut self, id: &TId) -> Option<P> {
        self.id_by_ip.retain(|_, r_id| r_id != id);
        self.peer_by_id.remove(id)
    }

    pub(crate) fn get(&self, id: &TId) -> Option<&P> {
        self.peer_by_id.get(id)
    }

    pub(crate) fn get_mut(&mut self, id: &TId) -> Option<&mut P> {
        self.peer_by_id.get_mut(id)
    }

    #[cfg(test)]
    pub(crate) fn peer_by_ip(&self, ip: IpAddr) -> Option<&P> {
        let (_, id) = self.id_by_ip.longest_match(ip)?;
        self.peer_by_id.get(id)
    }

    pub(crate) fn peer_by_ip_mut(&mut self, ip: IpAddr) -> Option<&mut P> {
        let (_, id) = self.id_by_ip.longest_match(ip)?;
        self.peer_by_id.get_mut(id)
    }

    pub(crate) fn iter_mut(&mut self) -> impl Iterator<Item = &mut P> {
        self.peer_by_id.values_mut()
    }

    pub(crate) fn clear(&mut self) {
        self.id_by_ip = IpNetworkTable::new();
        self.peer_by_id.clear();
    }
}

pub(crate) trait Peer {
    type Id;

    fn id(&self) -> Self::Id;
}

impl Peer for ClientOnGateway {
    type Id = ClientId;

    fn id(&self) -> Self::Id {
        ClientOnGateway::id(self)
    }
}

impl Peer for GatewayOnClient {
    type Id = GatewayId;

    fn id(&self) -> Self::Id {
        GatewayOnClient::id(self)
    }
}

impl Peer for ClientOnClient {
    type Id = ClientId;

    fn id(&self) -> Self::Id {
        ClientOnClient::id(self)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct DummyPeer {
        id: u64,
    }

    impl DummyPeer {
        fn new(id: u64) -> Self {
            Self { id }
        }
    }

    impl Peer for DummyPeer {
        type Id = u64;

        fn id(&self) -> Self::Id {
            self.id
        }
    }

    #[test]
    fn can_insert_and_retrieve_peer() {
        let mut peer_storage = PeerStore::<u64, DummyPeer>::default();
        peer_storage.insert(DummyPeer::new(0), &[]);
        assert!(peer_storage.get(&0).is_some());
    }

    #[test]
    fn can_insert_and_retrieve_peer_by_ip() {
        let mut peer_storage = PeerStore::<u64, DummyPeer>::default();
        peer_storage.insert(DummyPeer::new(0), &["100.0.0.0/24".parse().unwrap()]);

        assert_eq!(
            peer_storage
                .peer_by_ip("100.0.0.1".parse().unwrap())
                .unwrap()
                .id,
            0
        );
    }

    #[test]
    fn can_remove_peer() {
        let mut peer_storage = PeerStore::<u64, DummyPeer>::default();
        peer_storage.insert(DummyPeer::new(0), &["100.0.0.0/24".parse().unwrap()]);
        peer_storage.remove(&0);

        assert!(peer_storage.get(&0).is_none());
        assert!(
            peer_storage
                .peer_by_ip("100.0.0.1".parse().unwrap())
                .is_none()
        )
    }

    #[test]
    fn inserting_peer_removes_previous_instances_of_same_id() {
        let mut peer_storage = PeerStore::<u64, DummyPeer>::default();
        peer_storage.insert(DummyPeer::new(0), &["100.0.0.0/24".parse().unwrap()]);
        peer_storage.insert(DummyPeer::new(0), &[]);

        assert!(peer_storage.get(&0).is_some());
        assert!(
            peer_storage
                .peer_by_ip("100.0.0.1".parse().unwrap())
                .is_none()
        )
    }
}
