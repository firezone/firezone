use core::fmt;
use std::collections::{BTreeSet, HashMap, HashSet};
use std::hash::Hash;
use std::mem;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};
use std::time::Instant;

use fast_random_state::FastRandomState;

use crate::client::{ClientOnClient, GatewayOnClient};
use crate::gateway::ClientOnGateway;

pub(crate) struct PeerStore<TId, P> {
    id_by_ip: HashMap<IpAddr, TId, FastRandomState>,
    peer_by_id: HashMap<TId, P, FastRandomState>,

    /// Peers handed out mutably since the last [`PeerStore::handle_timeout`].
    touched: HashSet<TId, FastRandomState>,
    deadline_by_id: HashMap<TId, Instant, FastRandomState>,
    deadlines: BTreeSet<(Instant, TId)>,
}

impl<TId, P> Default for PeerStore<TId, P> {
    fn default() -> Self {
        Self {
            id_by_ip: HashMap::default(),
            peer_by_id: Default::default(),
            touched: Default::default(),
            deadline_by_id: Default::default(),
            deadlines: Default::default(),
        }
    }
}

impl<TId, P> PeerStore<TId, P>
where
    TId: Eq + Hash + Ord + Copy + fmt::Debug + fmt::Display,
    P: Peer,
{
    pub(crate) fn extract_if(&mut self, f: impl Fn(&TId, &mut P) -> bool) -> Vec<(TId, P)> {
        let removed_peers = self
            .peer_by_id
            .extract_if(|id, peer| f(id, peer))
            .collect::<Vec<_>>();

        for (id, _) in &removed_peers {
            self.forget_deadline(id);
        }

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
        self.touched.insert(pid);

        self.id_by_ip.insert(peer.tun_ipv4().into(), pid);
        self.id_by_ip.insert(peer.tun_ipv6().into(), pid);

        peer
    }

    pub(crate) fn remove(&mut self, id: &TId) -> Option<P> {
        self.id_by_ip.retain(|_, r_id| r_id != id);
        self.forget_deadline(id);
        self.peer_by_id.remove(id)
    }

    pub(crate) fn peer_by_id(&self, id: &TId) -> Option<&P> {
        self.peer_by_id.get(id)
    }

    pub(crate) fn peer_by_id_mut(&mut self, id: &TId) -> Option<&mut P> {
        let peer = self.peer_by_id.get_mut(id)?;
        self.touched.insert(*id);

        Some(peer)
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
        self.touched.insert(*id);

        Some((*id, peer))
    }

    pub(crate) fn iter_mut(&mut self) -> impl Iterator<Item = &mut P> {
        self.touched.extend(self.peer_by_id.keys().copied());

        self.peer_by_id.values_mut()
    }

    pub(crate) fn iter(&self) -> impl Iterator<Item = &P> {
        self.peer_by_id.values()
    }

    pub(crate) fn clear(&mut self) {
        self.id_by_ip.clear();
        self.peer_by_id.clear();
        self.touched.clear();
        self.deadline_by_id.clear();
        self.deadlines.clear();
    }

    /// Calls `f` on every peer that is due at `now` or was handed out mutably since the last call.
    ///
    /// Returns the IDs of the visited peers.
    pub(crate) fn handle_timeout(&mut self, now: Instant, mut f: impl FnMut(&mut P)) -> Vec<TId> {
        let mut ids = mem::take(&mut self.touched);
        ids.extend(
            self.deadlines
                .iter()
                .take_while(|(deadline, _)| *deadline <= now)
                .map(|(_, id)| *id),
        );

        ids.into_iter()
            .filter(|id| {
                let Some(peer) = self.peer_by_id.get_mut(id) else {
                    return false;
                };

                f(peer);

                let new = peer.poll_timeout();
                let old = match new {
                    Some(deadline) => self.deadline_by_id.insert(*id, deadline),
                    None => self.deadline_by_id.remove(id),
                };

                if old != new {
                    if let Some(old) = old {
                        self.deadlines.remove(&(old, *id));
                    }
                    if let Some(new) = new {
                        self.deadlines.insert((new, *id));
                    }
                }

                true
            })
            .collect()
    }

    fn forget_deadline(&mut self, id: &TId) {
        self.touched.remove(id);

        if let Some(deadline) = self.deadline_by_id.remove(id) {
            self.deadlines.remove(&(deadline, *id));
        }
    }
}

pub(crate) trait Peer {
    fn tun_ipv4(&self) -> Ipv4Addr;
    fn tun_ipv6(&self) -> Ipv6Addr;

    /// When [`PeerStore::handle_timeout`] needs to visit this peer next.
    fn poll_timeout(&self) -> Option<Instant>;
}

impl Peer for ClientOnGateway {
    fn tun_ipv4(&self) -> Ipv4Addr {
        self.client_tun().v4
    }

    fn tun_ipv6(&self) -> Ipv6Addr {
        self.client_tun().v6
    }

    fn poll_timeout(&self) -> Option<Instant> {
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

    fn poll_timeout(&self) -> Option<Instant> {
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

    fn poll_timeout(&self) -> Option<Instant> {
        ClientOnClient::poll_timeout(self)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct DummyPeer {
        ipv4: Ipv4Addr,
        ipv6: Ipv6Addr,
        deadline: Option<Instant>,
    }

    impl DummyPeer {
        fn new(ipv4: Ipv4Addr, ipv6: Ipv6Addr) -> Self {
            Self {
                ipv4,
                ipv6,
                deadline: None,
            }
        }
    }

    impl Peer for DummyPeer {
        fn tun_ipv4(&self) -> Ipv4Addr {
            self.ipv4
        }

        fn tun_ipv6(&self) -> Ipv6Addr {
            self.ipv6
        }

        fn poll_timeout(&self) -> Option<Instant> {
            self.deadline
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

    #[test]
    fn handle_timeout_visits_touched_and_due_peers() {
        let mut peer_storage = PeerStore::<u64, DummyPeer>::default();
        let now = Instant::now();
        let later = now + std::time::Duration::from_secs(1);
        peer_storage.upsert(0, || {
            DummyPeer::new(Ipv4Addr::new(1, 1, 1, 1), Ipv6Addr::LOCALHOST)
        });
        peer_storage.upsert(1, || {
            DummyPeer::new(Ipv4Addr::new(2, 2, 2, 2), Ipv6Addr::UNSPECIFIED)
        });

        let mut visited = peer_storage.handle_timeout(now, |p| p.deadline = Some(later));
        visited.sort();
        assert_eq!(visited, vec![0, 1]);

        assert_eq!(peer_storage.handle_timeout(now, |_| {}), Vec::<u64>::new());

        peer_storage.peer_by_id_mut(&0).unwrap().deadline = None;
        assert_eq!(peer_storage.handle_timeout(now, |_| {}), vec![0]);

        assert_eq!(peer_storage.handle_timeout(later, |_| {}), vec![1]);
        assert_eq!(
            peer_storage.handle_timeout(later, |p| p.deadline = None),
            vec![1]
        );
        assert_eq!(
            peer_storage.handle_timeout(later, |_| {}),
            Vec::<u64>::new()
        );
    }
}
