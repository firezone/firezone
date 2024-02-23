use std::collections::HashMap;
use std::hash::Hash;
use std::net::IpAddr;

use crate::peer::{PacketTransform, Peer};
use ip_network::IpNetwork;
use ip_network_table::IpNetworkTable;

pub struct PeerStore<TId, TTransform> {
    id_by_ip: IpNetworkTable<TId>,
    peer_by_id: HashMap<TId, Peer<TId, TTransform>>,
}

impl<T, U> Default for PeerStore<T, U> {
    fn default() -> Self {
        Self {
            id_by_ip: IpNetworkTable::new(),
            peer_by_id: HashMap::new(),
        }
    }
}

impl<TId, TTransform> PeerStore<TId, TTransform>
where
    TId: Hash + Eq + Clone + Copy,
    TTransform: PacketTransform,
{
    pub fn retain(&mut self, f: impl Fn(&TId, &mut Peer<TId, TTransform>) -> bool) {
        self.peer_by_id.retain(f);
        self.id_by_ip
            .retain(|_, id| self.peer_by_id.contains_key(id));
    }

    pub fn add_ips(&mut self, id: &TId, ips: &[IpNetwork]) -> Option<&Peer<TId, TTransform>> {
        let peer = self.peer_by_id.get_mut(id)?;

        for ip in ips {
            self.id_by_ip.insert(*ip, peer.conn_id);
            peer.add_allowed_ip(*ip);
        }

        Some(peer)
    }

    pub fn insert(&mut self, peer: Peer<TId, TTransform>) -> Option<Peer<TId, TTransform>> {
        self.id_by_ip.retain(|_, &mut r_id| r_id != peer.conn_id);

        self.peer_by_id.insert(peer.conn_id, peer)
    }

    pub fn remove(&mut self, id: &TId) -> Option<Peer<TId, TTransform>> {
        self.id_by_ip.retain(|_, r_id| r_id != id);
        self.peer_by_id.remove(id)
    }

    pub fn exact_match(&self, ip: IpNetwork) -> Option<&Peer<TId, TTransform>> {
        let ip = self.id_by_ip.exact_match(ip)?;
        self.peer_by_id.get(ip)
    }

    pub fn get(&self, id: &TId) -> Option<&Peer<TId, TTransform>> {
        self.peer_by_id.get(id)
    }

    pub fn get_mut(&mut self, id: &TId) -> Option<&mut Peer<TId, TTransform>> {
        self.peer_by_id.get_mut(id)
    }

    pub fn peer_by_ip(&self, ip: IpAddr) -> Option<&Peer<TId, TTransform>> {
        let (_, id) = self.id_by_ip.longest_match(ip)?;
        self.peer_by_id.get(id)
    }

    pub fn peer_by_ip_mut(&mut self, ip: IpAddr) -> Option<&mut Peer<TId, TTransform>> {
        let (_, id) = self.id_by_ip.longest_match(ip)?;
        self.peer_by_id.get_mut(id)
    }

    pub fn iter_mut(&mut self) -> impl Iterator<Item = &mut Peer<TId, TTransform>> {
        self.peer_by_id.values_mut()
    }

    pub fn iter(&mut self) -> impl Iterator<Item = &Peer<TId, TTransform>> {
        self.peer_by_id.values()
    }
}
