use std::collections::HashSet;

use itertools::Itertools;
use str0m::{Candidate, CandidateKind};

/// Custom "set" implementation for [`Candidate`]s based on a [`HashSet`] with an enforced ordering when iterating.
#[derive(Debug, Default)]
pub struct CandidateSet {
    inner: HashSet<Candidate>,
}

impl CandidateSet {
    #[expect(
        clippy::disallowed_methods,
        reason = "We don't care about the ordering."
    )]
    pub fn insert(&mut self, new: Candidate) -> bool {
        match new.kind() {
            CandidateKind::PeerReflexive | CandidateKind::Relayed => {
                debug_assert!(false);
                tracing::warn!(
                    "CandidateSet is not meant to be used with candidates of kind {}",
                    new.kind()
                );
                return false;
            }
            CandidateKind::ServerReflexive | CandidateKind::Host => {}
        }

        // Hashing a `Candidate` takes longer than checking a handful of entries using their `PartialEq` implementation.
        // This function is in the hot-path so it needs to be fast ...
        if self.inner.iter().any(|c| c == &new) {
            return false;
        }

        self.inner.retain(|current| {
            if current.kind() != new.kind() {
                return true; // Don't evict candidates of different kinds.
            }

            if current.kind() != CandidateKind::ServerReflexive {
                return true; // Don't evit candidates other than server reflexive.
            }

            let is_ip_version_different = current.addr().is_ipv4() != new.addr().is_ipv4();

            if !is_ip_version_different {
                tracing::debug!(%current, %new, "Replacing server-reflexive candidate");
            }

            // Candidates of different IP version are also kept.
            is_ip_version_different
        });

        self.inner.insert(new)
    }

    pub fn clear(&mut self) {
        self.inner.clear()
    }

    #[expect(
        clippy::disallowed_methods,
        reason = "We are guaranteeing a stable ordering"
    )]
    pub fn iter(&self) -> impl Iterator<Item = &Candidate> {
        self.inner
            .iter()
            .sorted_by(|l, r| l.prio().cmp(&r.prio()).then(l.addr().cmp(&r.addr())))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};
    use str0m::net::Protocol;

    const SOCK_ADDR_IP4_BASE: SocketAddr = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 10);
    const SOCK_ADDR1: SocketAddr = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 1234);
    const SOCK_ADDR2: SocketAddr = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 5678);

    const SOCK_ADDR_IP6_BASE: SocketAddr = SocketAddr::new(IpAddr::V6(Ipv6Addr::LOCALHOST), 10);
    const SOCK_ADDR3: SocketAddr = SocketAddr::new(IpAddr::V6(Ipv6Addr::LOCALHOST), 1234);
    const SOCK_ADDR4: SocketAddr = SocketAddr::new(IpAddr::V6(Ipv6Addr::LOCALHOST), 5678);

    #[test]
    fn only_allows_one_server_reflexive_candidate_per_ip_family() {
        let mut set = CandidateSet::default();

        let host1 = Candidate::host(SOCK_ADDR_IP4_BASE, Protocol::Udp).unwrap();
        let host2 = Candidate::host(SOCK_ADDR_IP6_BASE, Protocol::Udp).unwrap();

        assert!(set.insert(host1.clone()));
        assert!(set.insert(host2.clone()));

        let c1 =
            Candidate::server_reflexive(SOCK_ADDR1, SOCK_ADDR_IP4_BASE, Protocol::Udp).unwrap();
        let c2 =
            Candidate::server_reflexive(SOCK_ADDR2, SOCK_ADDR_IP4_BASE, Protocol::Udp).unwrap();
        let c3 =
            Candidate::server_reflexive(SOCK_ADDR3, SOCK_ADDR_IP6_BASE, Protocol::Udp).unwrap();
        let c4 =
            Candidate::server_reflexive(SOCK_ADDR4, SOCK_ADDR_IP6_BASE, Protocol::Udp).unwrap();

        assert!(set.insert(c1));
        assert!(set.insert(c2.clone()));
        assert!(set.insert(c3));
        assert!(set.insert(c4.clone()));

        assert_eq!(
            set.iter().cloned().collect::<Vec<_>>(),
            vec![c2, c4, host1, host2]
        );
    }

    #[test]
    fn allows_multiple_host_candidates_of_same_ip_base() {
        let mut set = CandidateSet::default();

        let host1 = Candidate::host(SOCK_ADDR1, Protocol::Udp).unwrap();
        let host2 = Candidate::host(SOCK_ADDR2, Protocol::Udp).unwrap();

        assert!(set.insert(host1.clone()));
        assert!(set.insert(host2.clone()));

        assert_eq!(set.iter().cloned().collect::<Vec<_>>(), vec![host1, host2]);
    }
}
