use std::net::SocketAddr;

/// A candidate address known to one end of a connection. The two
/// address axes — `addr` (public-facing destination) and `local`
/// (send-from socket) — diverge for `ServerReflexive` (NAT-mapped)
/// and `Relayed` (TURN-allocated). Kind drives tier-based scoring:
/// direct beats reflexive beats relayed.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Candidate {
    Host(SocketAddr),
    ServerReflexive {
        addr: SocketAddr,
        local: SocketAddr,
    },
    /// `local` is the TURN-allocation interface (so [`Self::local`]
    /// can return the allocation address itself — snownet keys its
    /// allocations table on that, which decides TURN channel-data
    /// wrapping).
    Relayed {
        addr: SocketAddr,
        local: SocketAddr,
    },
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

    /// The destination address; goes into `Transmit.remote`.
    pub const fn addr(&self) -> SocketAddr {
        match self {
            Self::Host(a) => *a,
            Self::ServerReflexive { addr, .. } | Self::Relayed { addr, .. } => *addr,
        }
    }

    /// The local-side identifier used in pair keys and `Transmit.local`.
    /// For `Relayed` this is the *allocation* (not the local interface),
    /// so snownet recognises it as relay-mediated.
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

    /// `true` iff the local interface and `addr` share an IP family.
    /// Always true for `Host` and `ServerReflexive`; for `Relayed`,
    /// `false` for e.g. a v6 allocation reached via a v4 TURN socket.
    pub const fn is_family_matched(&self) -> bool {
        match self {
            Self::Host(_) | Self::ServerReflexive { .. } => true,
            Self::Relayed { addr, local } => addr.is_ipv4() == local.is_ipv4(),
        }
    }
}

/// `Ord` follows the preference `Host < ServerReflexive < Relayed`
/// — declaration order, so new variants need care.
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
        // For relay, `local()` is intentionally the allocation: snownet's
        // pair-key + allocations-table lookup depend on it.
        assert_eq!(Candidate::relayed(addr(), other_addr()).addr(), addr());
        assert_eq!(Candidate::relayed(addr(), other_addr()).local(), addr());
    }

    #[test]
    fn family_match_for_relayed_uses_addr_vs_local_socket() {
        // v4 alloc reached over v4 → matched
        assert!(Candidate::relayed(addr(), other_addr()).is_family_matched());
        // v6 alloc reached over v6 → matched
        assert!(Candidate::relayed(addr_v6(), addr_v6()).is_family_matched());
        // v6 alloc reached over v4 → mismatched (the case the user flagged)
        assert!(!Candidate::relayed(addr_v6(), addr()).is_family_matched());
        // v4 alloc reached over v6 → mismatched
        assert!(!Candidate::relayed(addr(), addr_v6()).is_family_matched());
    }

    #[test]
    fn family_match_for_host_and_srflx_is_always_true() {
        assert!(Candidate::host(addr()).is_family_matched());
        assert!(Candidate::server_reflexive(addr(), other_addr()).is_family_matched());
    }
}
