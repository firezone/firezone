use std::net::SocketAddr;

/// A candidate address known to one end of a connection.
///
/// The two address axes — `addr` (what the *peer* uses to reach us /
/// what *we* use to reach the peer, depending on which side this
/// candidate represents) and `local` (the socket we actually send
/// from) — diverge for `ServerReflexive` (NAT-mapped) and `Relayed`
/// (TURN-allocated): in both cases `addr` is the public-facing
/// destination and `local` is the local interface we send from.
/// The kind drives tier-based path scoring: direct beats reflexive
/// beats relayed.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Candidate {
    /// Locally-bound socket address. `addr` is also the send-from.
    Host(SocketAddr),
    /// NAT-mapped public-facing address. `addr` is what the peer
    /// reaches us at; `local` is the socket we actually send from.
    ServerReflexive { addr: SocketAddr, local: SocketAddr },
    /// TURN relay-allocated address. `addr` is the allocation —
    /// snownet keys its allocations table on this when it sees it
    /// as a transmit's local, and routes via TURN channel-data.
    /// `local` is the local interface we sent the TURN allocation
    /// request from (i.e. the address we use to communicate with
    /// the relay over TURN). Kept separate so primary scoring can
    /// penalise mismatched-family combinations like a v6 allocation
    /// reached via a v4 TURN socket.
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

    /// The address other endpoints use to reach us (or that we use to
    /// reach a remote). Goes into `Transmit.remote` for an outbound
    /// pair's remote side, and into the pair-key on the remote side.
    pub const fn addr(&self) -> SocketAddr {
        match self {
            Self::Host(a) => *a,
            Self::ServerReflexive { addr, .. } | Self::Relayed { addr, .. } => *addr,
        }
    }

    /// The local socket the path-agent uses to identify a transmit's
    /// origin. Goes into `Transmit.local` for an outbound pair's
    /// local side. For `Host` it's the interface; for
    /// `ServerReflexive` the underlying base; for `Relayed` it's
    /// the *allocation* (so snownet's allocations table can recognise
    /// it as relay-mediated and wrap the payload in TURN channel-data).
    /// To get the actual local-interface socket for a relay, match on
    /// `Self::Relayed { local, .. }` directly.
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

    /// `true` iff this candidate's local-interface IP family matches
    /// its public-facing `addr` family. For `Host` and
    /// `ServerReflexive` this is always true (str0m enforces matching
    /// families when constructing the candidate). For `Relayed` it
    /// depends on whether we obtained the allocation over the same
    /// IP version as the allocation itself — a v6 allocation reached
    /// via a v4 TURN socket counts as a mismatch and is preferable
    /// to skip when a matched-family alternative exists.
    pub const fn is_family_matched(&self) -> bool {
        match self {
            Self::Host(_) | Self::ServerReflexive { .. } => true,
            Self::Relayed { addr, local } => addr.is_ipv4() == local.is_ipv4(),
        }
    }
}

/// Source of a candidate.
///
/// `Ord` follows the preference: `Host < ServerReflexive < Relayed`
/// (lower is better). The `derive(PartialOrd, Ord)` reflects the
/// declaration order, so adding new variants requires care.
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
