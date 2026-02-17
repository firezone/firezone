use core::fmt;
use std::collections::HashMap;
use std::hash::Hash;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};

use crate::client::GatewayOnClient;
use crate::gateway::ClientOnGateway;

pub(crate) struct PeerStore<TId, P> {
    id_by_ip: HashMap<IpAddr, TId>,
    peer_by_id: HashMap<TId, P>,
}

impl<TId, P> Default for PeerStore<TId, P> {
    fn default() -> Self {
        Self {
            id_by_ip: Default::default(),
            peer_by_id: Default::default(),
        }
    }
}

impl<TId, P> PeerStore<TId, P>
where
    TId: Hash + Eq + Copy + fmt::Debug + fmt::Display,
    P: Peer,
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

    pub(crate) fn upsert(&mut self, pid: TId, make_peer: impl FnOnce() -> P) -> &mut P {
        let peer = make_peer();

        if let Some(existing) = self.peer_by_id.get(&pid)
            && (existing.tun_ipv4() != peer.tun_ipv4() || existing.tun_ipv6() != peer.tun_ipv6())
        {
            tracing::debug!(
                %pid,
                old_v4 = %existing.tun_ipv4(),
                old_v6 = %existing.tun_ipv6(),
                new_v4 = %peer.tun_ipv4(),
                new_v6 = %peer.tun_ipv6(),
                "Peer's TUN IP has changed, replacing",
            );

            self.id_by_ip.remove(&existing.tun_ipv4().into());
            self.id_by_ip.remove(&existing.tun_ipv6().into());
            self.peer_by_id.remove(&pid);
        }

        let peer = self.peer_by_id.entry(pid).or_insert(peer);

        self.id_by_ip.insert(peer.tun_ipv4().into(), pid);
        self.id_by_ip.insert(peer.tun_ipv6().into(), pid);

        peer
    }

    pub(crate) fn remove(&mut self, id: &TId) -> Option<P> {
        self.id_by_ip.retain(|_, r_id| r_id != id);
        self.peer_by_id.remove(id)
    }

    pub(crate) fn peer_by_id(&self, id: &TId) -> Option<&P> {
        self.peer_by_id.get(id)
    }

    pub(crate) fn peer_by_id_mut(&mut self, id: &TId) -> Option<&mut P> {
        self.peer_by_id.get_mut(id)
    }

    pub(crate) fn peer_by_ip(&self, ip: IpAddr) -> Option<&P> {
        let id = self.id_by_ip.get(&ip)?;
        let peer = self.peer_by_id.get(id)?;

        Some(peer)
    }

    pub(crate) fn peer_by_ip_mut(&mut self, ip: IpAddr) -> Option<&mut P> {
        let id = self.id_by_ip.get(&ip)?;
        let peer = self.peer_by_id.get_mut(id)?;

        Some(peer)
    }

    pub(crate) fn iter_mut(&mut self) -> impl Iterator<Item = &mut P> {
        self.peer_by_id.values_mut()
    }

    pub(crate) fn clear(&mut self) {
        self.id_by_ip.clear();
        self.peer_by_id.clear();
    }
}

pub(crate) trait Peer {
    fn tun_ipv4(&self) -> Ipv4Addr;
    fn tun_ipv6(&self) -> Ipv6Addr;
}

impl Peer for ClientOnGateway {
    fn tun_ipv4(&self) -> Ipv4Addr {
        self.client_tun().v4
    }

    fn tun_ipv6(&self) -> Ipv6Addr {
        self.client_tun().v6
    }
}

impl Peer for GatewayOnClient {
    fn tun_ipv4(&self) -> Ipv4Addr {
        self.gateway_tun().v4
    }

    fn tun_ipv6(&self) -> Ipv6Addr {
        self.gateway_tun().v6
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct DummyPeer {
        id: u64,
        ipv4: Ipv4Addr,
        ipv6: Ipv6Addr,
    }

    impl DummyPeer {
        fn new(id: u64, ipv4: Ipv4Addr, ipv6: Ipv6Addr) -> Self {
            Self { id, ipv4, ipv6 }
        }
    }

    impl Peer for DummyPeer {
        fn tun_ipv4(&self) -> Ipv4Addr {
            self.ipv4
        }

        fn tun_ipv6(&self) -> Ipv6Addr {
            self.ipv6
        }
    }

    #[test]
    fn can_insert_and_retrieve_peer() {
        let mut peer_storage = PeerStore::<u64, DummyPeer>::default();
        peer_storage.upsert(0, || {
            DummyPeer::new(0, Ipv4Addr::LOCALHOST, Ipv6Addr::LOCALHOST)
        });
        assert!(peer_storage.peer_by_id(&0).is_some());
    }

    #[test]
    fn can_insert_and_retrieve_peer_by_ip() {
        let mut peer_storage = PeerStore::<u64, DummyPeer>::default();
        peer_storage.upsert(0, || {
            DummyPeer::new(0, Ipv4Addr::LOCALHOST, Ipv6Addr::LOCALHOST)
        });

        assert_eq!(
            peer_storage
                .peer_by_ip(Ipv4Addr::LOCALHOST.into())
                .unwrap()
                .id,
            0
        );
    }

    #[test]
    fn can_remove_peer() {
        let mut peer_storage = PeerStore::<u64, DummyPeer>::default();
        peer_storage.upsert(0, || {
            DummyPeer::new(0, Ipv4Addr::LOCALHOST, Ipv6Addr::LOCALHOST)
        });
        peer_storage.remove(&0);

        assert!(peer_storage.peer_by_id(&0).is_none());
        assert!(
            peer_storage
                .peer_by_ip(Ipv4Addr::LOCALHOST.into())
                .is_none()
        )
    }

    #[test]
    fn inserting_peer_removes_previous_instances_of_same_id() {
        let mut peer_storage = PeerStore::<u64, DummyPeer>::default();
        peer_storage.upsert(0, || {
            DummyPeer::new(0, Ipv4Addr::new(1, 1, 1, 1), Ipv6Addr::LOCALHOST)
        });
        peer_storage.upsert(0, || {
            DummyPeer::new(0, Ipv4Addr::LOCALHOST, Ipv6Addr::LOCALHOST)
        });

        assert!(peer_storage.peer_by_id(&0).is_some());
        assert!(
            peer_storage
                .peer_by_ip("1.1.1.1".parse().unwrap())
                .is_none()
        )
    }
}
