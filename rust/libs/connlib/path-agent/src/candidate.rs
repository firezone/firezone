use std::net::SocketAddr;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Candidate {
    Host(SocketAddr),
    ServerReflexive { addr: SocketAddr, local: SocketAddr },
    Relayed { addr: SocketAddr, local: SocketAddr },
}

impl Candidate {
    pub const fn host(addr: SocketAddr) -> Self {
        Self::Host(addr)
    }

    pub const fn server_reflexive(addr: SocketAddr, local: SocketAddr) -> Self {
        Self::ServerReflexive { addr, local }
    }

    pub const fn relayed(addr: SocketAddr, local: SocketAddr) -> Self {
        Self::Relayed { addr, local }
    }

    pub const fn addr(&self) -> SocketAddr {
        match self {
            Self::Host(a) => *a,
            Self::ServerReflexive { addr, .. } | Self::Relayed { addr, .. } => *addr,
        }
    }

    /// For `Relayed`, the allocation address — pair keys and the
    /// allocations-table lookup hang off this.
    pub const fn local(&self) -> SocketAddr {
        match self {
            Self::Host(a) => *a,
            Self::ServerReflexive { local, .. } => *local,
            Self::Relayed { addr, .. } => *addr,
        }
    }

    pub const fn kind(&self) -> CandidateKind {
        match self {
            Self::Host(_) => CandidateKind::Host,
            Self::ServerReflexive { .. } => CandidateKind::ServerReflexive,
            Self::Relayed { .. } => CandidateKind::Relayed,
        }
    }

    pub const fn is_relayed(&self) -> bool {
        matches!(self, Self::Relayed { .. })
    }

    pub const fn is_family_matched(&self) -> bool {
        match self {
            Self::Host(_) | Self::ServerReflexive { .. } => true,
            Self::Relayed { addr, local } => addr.is_ipv4() == local.is_ipv4(),
        }
    }
}

/// Declaration order determines `Ord`: `Host < ServerReflexive < Relayed`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum CandidateKind {
    Host,
    ServerReflexive,
    Relayed,
}

#[cfg(test)]
mod tests {
    use super::*;

    fn addr() -> SocketAddr {
        "127.0.0.1:1234".parse().unwrap()
    }

    fn other_addr() -> SocketAddr {
        "192.168.1.5:1234".parse().unwrap()
    }

    fn addr_v6() -> SocketAddr {
        "[::1]:1234".parse().unwrap()
    }

    #[test]
    fn host_beats_srflx_beats_relay() {
        assert!(CandidateKind::Host < CandidateKind::ServerReflexive);
        assert!(CandidateKind::ServerReflexive < CandidateKind::Relayed);
    }

    #[test]
    fn relayed_helper_matches_kind() {
        assert!(Candidate::relayed(addr(), addr()).is_relayed());
        assert!(!Candidate::host(addr()).is_relayed());
        assert!(!Candidate::server_reflexive(addr(), other_addr()).is_relayed());
    }

    #[test]
    fn server_reflexive_addr_and_local_diverge() {
        let c = Candidate::server_reflexive(addr(), other_addr());
        assert_eq!(c.addr(), addr());
        assert_eq!(c.local(), other_addr());
    }

    #[test]
    fn host_and_relayed_local_equal_addr_for_pair_keying() {
        assert_eq!(Candidate::host(addr()).addr(), addr());
        assert_eq!(Candidate::host(addr()).local(), addr());
        assert_eq!(Candidate::relayed(addr(), other_addr()).addr(), addr());
        assert_eq!(Candidate::relayed(addr(), other_addr()).local(), addr());
    }

    #[test]
    fn family_match_for_relayed_uses_addr_vs_local_socket() {
        assert!(Candidate::relayed(addr(), other_addr()).is_family_matched());
        assert!(Candidate::relayed(addr_v6(), addr_v6()).is_family_matched());
        assert!(!Candidate::relayed(addr_v6(), addr()).is_family_matched());
        assert!(!Candidate::relayed(addr(), addr_v6()).is_family_matched());
    }

    #[test]
    fn family_match_for_host_and_srflx_is_always_true() {
        assert!(Candidate::host(addr()).is_family_matched());
        assert!(Candidate::server_reflexive(addr(), other_addr()).is_family_matched());
    }
}
