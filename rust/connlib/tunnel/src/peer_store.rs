use std::collections::{HashMap, HashSet};
use std::hash::Hash;
use std::net::IpAddr;

use crate::peer::{PacketTransform, Peer};
use connlib_shared::messages::ResourceId;
use ip_network::IpNetwork;
use ip_network_table::IpNetworkTable;

pub struct PeerStore<TId, TTransform, TResource> {
    id_by_ip: IpNetworkTable<TId>,
    peer_by_id: HashMap<TId, Peer<TId, TTransform, TResource>>,
}

impl<TId, TTransform, TResource> Default for PeerStore<TId, TTransform, TResource> {
    fn default() -> Self {
        Self {
            id_by_ip: IpNetworkTable::new(),
            peer_by_id: HashMap::new(),
        }
    }
}

impl<TId, TTransform> PeerStore<TId, TTransform, HashSet<ResourceId>>
where
    TId: Hash + Eq + Copy,
    TTransform: PacketTransform,
{
    pub fn add_ips_with_resource(&mut self, id: &TId, ips: &[IpNetwork], resource: &ResourceId) {
        for ip in ips {
            let Some(peer) = self.add_ip(id, ip) else {
                continue;
            };
            peer.insert_id(ip, resource);
        }
    }
}

impl<TId, TTransform, TResource> PeerStore<TId, TTransform, TResource>
where
    TId: Hash + Eq + Copy,
    TTransform: PacketTransform,
{
    pub fn retain(&mut self, f: impl Fn(&TId, &mut Peer<TId, TTransform, TResource>) -> bool) {
        self.peer_by_id.retain(f);
        self.id_by_ip
            .retain(|_, id| self.peer_by_id.contains_key(id));
    }

    pub fn add_ip(
        &mut self,
        id: &TId,
        ip: &IpNetwork,
    ) -> Option<&mut Peer<TId, TTransform, TResource>> {
        let peer = self.peer_by_id.get_mut(id)?;
        self.id_by_ip.insert(*ip, *id);
        Some(peer)
    }

    pub fn insert(
        &mut self,
        peer: Peer<TId, TTransform, TResource>,
    ) -> Option<Peer<TId, TTransform, TResource>> {
        self.id_by_ip.retain(|_, &mut r_id| r_id != peer.conn_id);

        self.peer_by_id.insert(peer.conn_id, peer)
    }

    pub fn remove(&mut self, id: &TId) -> Option<Peer<TId, TTransform, TResource>> {
        self.id_by_ip.retain(|_, r_id| r_id != id);
        self.peer_by_id.remove(id)
    }

    pub fn exact_match(&self, ip: IpNetwork) -> Option<&Peer<TId, TTransform, TResource>> {
        let ip = self.id_by_ip.exact_match(ip)?;
        self.peer_by_id.get(ip)
    }

    pub fn get(&self, id: &TId) -> Option<&Peer<TId, TTransform, TResource>> {
        self.peer_by_id.get(id)
    }

    pub fn get_mut(&mut self, id: &TId) -> Option<&mut Peer<TId, TTransform, TResource>> {
        self.peer_by_id.get_mut(id)
    }

    pub fn peer_by_ip(&self, ip: IpAddr) -> Option<&Peer<TId, TTransform, TResource>> {
        let (_, id) = self.id_by_ip.longest_match(ip)?;
        self.peer_by_id.get(id)
    }

    pub fn peer_by_ip_mut(&mut self, ip: IpAddr) -> Option<&mut Peer<TId, TTransform, TResource>> {
        let (_, id) = self.id_by_ip.longest_match(ip)?;
        self.peer_by_id.get_mut(id)
    }

    pub fn iter_mut(&mut self) -> impl Iterator<Item = &mut Peer<TId, TTransform, TResource>> {
        self.peer_by_id.values_mut()
    }

    pub fn iter(&mut self) -> impl Iterator<Item = &Peer<TId, TTransform, TResource>> {
        self.peer_by_id.values()
    }
}

#[cfg(test)]
mod tests {
    use crate::peer::{PacketTransformGateway, Peer};

    use super::PeerStore;

    #[test]
    fn can_insert_and_retrieve_peer() {
        let mut peer_storage = PeerStore::<_, _, ()>::default();
        peer_storage.insert(Peer::new(0, PacketTransformGateway::default()));
        assert!(peer_storage.get(&0).is_some());
    }

    #[test]
    fn can_insert_and_retrieve_peer_by_ip() {
        let mut peer_storage = PeerStore::<_, _, ()>::default();
        peer_storage.insert(Peer::new(0, PacketTransformGateway::default()));
        peer_storage.add_ip(&0, &"100.0.0.0/24".parse().unwrap());

        assert_eq!(
            peer_storage
                .peer_by_ip("100.0.0.1".parse().unwrap())
                .unwrap()
                .conn_id,
            0
        );
    }

    #[test]
    fn can_remove_peer() {
        let mut peer_storage = PeerStore::<_, _, ()>::default();
        peer_storage.insert(Peer::new(0, PacketTransformGateway::default()));
        peer_storage.add_ip(&0, &"100.0.0.0/24".parse().unwrap());
        peer_storage.remove(&0);

        assert!(peer_storage.get(&0).is_none());
        assert!(peer_storage
            .peer_by_ip("100.0.0.1".parse().unwrap())
            .is_none())
    }

    #[test]
    fn inserting_peer_removes_previous_instances_of_same_id() {
        let mut peer_storage = PeerStore::<_, _, ()>::default();
        peer_storage.insert(Peer::new(0, PacketTransformGateway::default()));
        peer_storage.add_ip(&0, &"100.0.0.0/24".parse().unwrap());
        peer_storage.insert(Peer::new(0, PacketTransformGateway::default()));

        assert!(peer_storage.get(&0).is_some());
        assert!(peer_storage
            .peer_by_ip("100.0.0.1".parse().unwrap())
            .is_none())
    }
}
