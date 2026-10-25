use core::fmt;
use std::collections::HashMap;
use std::hash::Hash;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};
use std::time::Instant;

use deadline_map::{DeadlineMap, PollTimeout};
use fast_random_state::FastRandomState;

use crate::client::{ClientOnClient, GatewayOnClient};
use crate::gateway::ClientOnGateway;

pub(crate) struct PeerStore<TId, P>
where
    P: Peer,
{
    id_by_ip: HashMap<IpAddr, TId, FastRandomState>,
    peer_by_id: DeadlineMap<TId, P>,
}

impl<TId, P> Default for PeerStore<TId, P>
where
    P: Peer,
{
    fn default() -> Self {
        Self {
            id_by_ip: HashMap::default(),
            peer_by_id: Default::default(),
        }
    }
}

impl<TId, P> PeerStore<TId, P>
where
    TId: Eq + Hash + Ord + Copy + fmt::Debug + fmt::Display,
    P: Peer,
{
    pub(crate) fn extract_if(&mut self, f: impl Fn(&TId, &P) -> bool) -> Vec<(TId, P)> {
        let removed_peers = self.peer_by_id.extract_if(f);

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

        let peer = self.peer_by_id.get_or_insert(pid, peer);

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

    pub(crate) fn peer_by_ip(&self, ip: impl Into<IpAddr>) -> Option<(TId, &P)> {
        let ip = ip.into();

        let id = self.id_by_ip.get(&ip)?;
        let peer = self.peer_by_id.get(id)?;

        Some((*id, peer))
    }

    pub(crate) fn peer_by_ip_mut(&mut self, ip: impl Into<IpAddr>) -> Option<(TId, &mut P)> {
        let ip = ip.into();

        let id = self.id_by_ip.get(&ip)?;
        let peer = self.peer_by_id.get_mut(id)?;

        Some((*id, peer))
    }

    pub(crate) fn iter_mut(&mut self) -> impl Iterator<Item = &mut P> {
        self.peer_by_id.iter_mut().map(|(_, p)| p)
    }

    pub(crate) fn iter(&self) -> impl Iterator<Item = &P> {
        self.peer_by_id.values()
    }

    pub(crate) fn clear(&mut self) {
        self.id_by_ip.clear();
        self.peer_by_id.clear();
    }

    /// Hands out the peers that are due at `now` or were handed out mutably since the last [`PeerStore::reindex`].
    pub(crate) fn due_mut(&mut self, now: Instant) -> impl Iterator<Item = (TId, &mut P)> {
        self.peer_by_id.due_mut(now)
    }

    pub(crate) fn reindex(&mut self) {
        self.peer_by_id.reindex(|_, _| {});
    }
}

/// A peer whose [`PollTimeout::poll_timeout`] says when [`PeerStore::due_mut`] needs to hand it out next.
pub(crate) trait Peer: PollTimeout {
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

impl PollTimeout for ClientOnGateway {
    fn poll_timeout(&mut self) -> Option<Instant> {
        ClientOnGateway::poll_timeout(self)
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

impl PollTimeout for GatewayOnClient {
    fn poll_timeout(&mut self) -> Option<Instant> {
        None
    }
}

impl Peer for ClientOnClient {
    fn tun_ipv4(&self) -> Ipv4Addr {
        self.remote_tun().v4
    }

    fn tun_ipv6(&self) -> Ipv6Addr {
        self.remote_tun().v6
    }
}

impl PollTimeout for ClientOnClient {
    fn poll_timeout(&mut self) -> Option<Instant> {
        ClientOnClient::poll_timeout(self)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct DummyPeer {
        ipv4: Ipv4Addr,
        ipv6: Ipv6Addr,
    }

    impl DummyPeer {
        fn new(ipv4: Ipv4Addr, ipv6: Ipv6Addr) -> Self {
            Self { ipv4, ipv6 }
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

    impl PollTimeout for DummyPeer {
        fn poll_timeout(&mut self) -> Option<Instant> {
            None
        }
    }

    #[test]
    fn can_insert_and_retrieve_peer() {
        let mut peer_storage = PeerStore::<u64, DummyPeer>::default();
        peer_storage.upsert(0, || {
            DummyPeer::new(Ipv4Addr::LOCALHOST, Ipv6Addr::LOCALHOST)
        });
        assert!(peer_storage.peer_by_id(&0).is_some());
    }

    #[test]
    fn can_insert_and_retrieve_peer_by_ip() {
        let mut peer_storage = PeerStore::<u64, DummyPeer>::default();
        peer_storage.upsert(0, || {
            DummyPeer::new(Ipv4Addr::LOCALHOST, Ipv6Addr::LOCALHOST)
        });

        assert_eq!(peer_storage.peer_by_ip(Ipv4Addr::LOCALHOST).unwrap().0, 0);
    }

    #[test]
    fn can_remove_peer() {
        let mut peer_storage = PeerStore::<u64, DummyPeer>::default();
        peer_storage.upsert(0, || {
            DummyPeer::new(Ipv4Addr::LOCALHOST, Ipv6Addr::LOCALHOST)
        });
        peer_storage.remove(&0);

        assert!(peer_storage.peer_by_id(&0).is_none());
        assert!(peer_storage.peer_by_ip(Ipv4Addr::LOCALHOST).is_none())
    }

    #[test]
    fn inserting_peer_removes_previous_instances_of_same_id() {
        let mut peer_storage = PeerStore::<u64, DummyPeer>::default();
        peer_storage.upsert(0, || {
            DummyPeer::new(Ipv4Addr::new(1, 1, 1, 1), Ipv6Addr::LOCALHOST)
        });
        peer_storage.upsert(0, || {
            DummyPeer::new(Ipv4Addr::LOCALHOST, Ipv6Addr::LOCALHOST)
        });

        assert!(peer_storage.peer_by_id(&0).is_some());
        assert!(peer_storage.peer_by_ip(Ipv4Addr::new(1, 1, 1, 1)).is_none())
    }
}
