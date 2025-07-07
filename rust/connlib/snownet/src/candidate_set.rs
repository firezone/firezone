use std::{
    collections::{HashMap, HashSet},
    net::SocketAddr,
};

use itertools::Itertools;
use str0m::{Candidate, CandidateKind};

/// Custom "set" implementation for [`Candidate`]s based on a [`HashSet`] with an enforced ordering when iterating.
///
/// The set only allows host and server-reflexive candidates as only those need to be de-duplicated in order to avoid
/// spamming the remote with duplicate candidates.
#[derive(Debug, Default)]
pub struct CandidateSet {
    host: HashSet<Candidate>,
    server_reflexive: HashMap<SocketAddr, Candidate>,

    is_symmetric_nat: bool,
}

impl CandidateSet {
    pub fn insert_host(&mut self, new: Candidate) -> bool {
        debug_assert_eq!(new.kind(), CandidateKind::Host);

        self.host.insert(new)
    }

    pub fn insert_server_reflexive(&mut self, server: SocketAddr, new: Candidate) -> bool {
        debug_assert_eq!(new.kind(), CandidateKind::ServerReflexive);

        let is_new = self
            .server_reflexive
            .insert(server, new.clone())
            .is_none_or(|c| c != new);
        let num_servers = self.server_reflexive.keys().count();

        self.evaluate_symmetric_nat();

        if num_servers >= 2 && self.is_holepunch_friendly() && is_new {
            tracing::info!("Our NAT appears to be hole-punch friendly");
        }

        self.is_holepunch_friendly()
    }

    pub fn clear(&mut self) {
        self.host.clear();
        self.server_reflexive.clear();
        self.is_symmetric_nat = false;
    }

    #[expect(
        clippy::disallowed_methods,
        reason = "We are guaranteeing a stable ordering"
    )]
    pub fn iter(&self) -> impl Iterator<Item = &Candidate> {
        std::iter::empty()
            .chain(self.host.iter())
            .chain(
                self.server_reflexive
                    .values()
                    .unique()
                    .filter(|_| self.is_holepunch_friendly()),
            )
            .sorted_by(|l, r| l.prio().cmp(&r.prio()).then(l.addr().cmp(&r.addr())))
    }

    fn is_holepunch_friendly(&self) -> bool {
        !self.is_symmetric_nat
    }

    fn evaluate_symmetric_nat(&mut self) {
        if self.server_reflexive.len() < 2 {
            tracing::debug!("Not enough candidates to say whether we are behind symmetric NAT");

            return;
        }

        let is_symmetric_nat = !self.server_reflexive.values().all_equal();

        if !self.is_symmetric_nat && is_symmetric_nat {
            tracing::info!("Symmetric NAT detected: suppressing server-reflexive candidates");
        }

        self.is_symmetric_nat = is_symmetric_nat;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::{IpAddr, Ipv4Addr, SocketAddr};
    use str0m::net::Protocol;

    const SOCK_ADDR_IP4_BASE: SocketAddr = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 10);
    const SOCK_ADDR1: SocketAddr = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 1234);
    const SOCK_ADDR2: SocketAddr = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 5678);

    const SERVER1: SocketAddr = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 8888);
    const SERVER2: SocketAddr = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 9999);

    #[test]
    fn ignores_server_reflexive_candidates_if_symmetric_nat() {
        let _guard = firezone_logging::test("trace");

        let mut set = CandidateSet::default();

        let c1 =
            Candidate::server_reflexive(SOCK_ADDR1, SOCK_ADDR_IP4_BASE, Protocol::Udp).unwrap();
        let c2 =
            Candidate::server_reflexive(SOCK_ADDR2, SOCK_ADDR_IP4_BASE, Protocol::Udp).unwrap();

        set.insert_server_reflexive(SERVER1, c1);
        set.insert_server_reflexive(SERVER2, c2);

        assert_eq!(set.iter().collect::<Vec<_>>(), Vec::<&Candidate>::default());
    }

    #[test]
    fn uses_server_reflexive_candiates_if_holepunch_friendly() {
        let _guard = firezone_logging::test("trace");

        let mut set = CandidateSet::default();

        let c1 =
            Candidate::server_reflexive(SOCK_ADDR1, SOCK_ADDR_IP4_BASE, Protocol::Udp).unwrap();

        set.insert_server_reflexive(SERVER1, c1.clone());
        set.insert_server_reflexive(SERVER2, c1.clone());

        assert_eq!(set.iter().collect::<Vec<_>>(), vec![&c1]);
    }

    #[test]
    fn allows_multiple_host_candidates_of_same_ip_base() {
        let mut set = CandidateSet::default();

        let host1 = Candidate::host(SOCK_ADDR1, Protocol::Udp).unwrap();
        let host2 = Candidate::host(SOCK_ADDR2, Protocol::Udp).unwrap();

        assert!(set.insert_host(host1.clone()));
        assert!(set.insert_host(host2.clone()));

        assert_eq!(set.iter().cloned().collect::<Vec<_>>(), vec![host1, host2]);
    }
}
