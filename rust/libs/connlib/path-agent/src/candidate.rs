use std::net::SocketAddr;

/// A candidate address known to one end of a connection.
///
/// The two address axes — `addr` (what the *peer* uses to reach us /
/// what *we* use to reach the peer, depending on which side this
/// candidate represents) and `local` (the socket we actually send
/// from) — only diverge for `ServerReflexive`, which is why the
/// variants are shaped differently. The kind drives tier-based path
/// scoring: direct beats reflexive beats relayed.
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
    Relayed(SocketAddr),
}

impl Candidate {
    pub const fn host(addr: SocketAddr) -> Self {
        Self::Host(addr)
    }

    pub const fn server_reflexive(addr: SocketAddr, local: SocketAddr) -> Self {
        Self::ServerReflexive { addr, local }
    }

    pub const fn relayed(addr: SocketAddr) -> Self {
        Self::Relayed(addr)
    }

    /// The address other endpoints use to reach us (or that we use to
    /// reach a remote). Goes into `Transmit.remote` for an outbound
    /// pair's remote side, and into the pair-key on the remote side.
    pub const fn addr(&self) -> SocketAddr {
        match self {
            Self::Host(a) | Self::Relayed(a) => *a,
            Self::ServerReflexive { addr, .. } => *addr,
        }
    }

    /// The local socket we actually send from on the wire. Goes into
    /// `Transmit.local` for an outbound pair's local side. For all
    /// kinds except `ServerReflexive`, this matches `addr`.
    pub const fn local(&self) -> SocketAddr {
        match self {
            Self::Host(a) | Self::Relayed(a) => *a,
            Self::ServerReflexive { local, .. } => *local,
        }
    }

    pub const fn kind(&self) -> CandidateKind {
        match self {
            Self::Host(_) => CandidateKind::Host,
            Self::ServerReflexive { .. } => CandidateKind::ServerReflexive,
            Self::Relayed(_) => CandidateKind::Relayed,
        }
    }

    pub const fn is_relayed(&self) -> bool {
        matches!(self, Self::Relayed(_))
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

    #[test]
    fn host_beats_srflx_beats_relay() {
        assert!(CandidateKind::Host < CandidateKind::ServerReflexive);
        assert!(CandidateKind::ServerReflexive < CandidateKind::Relayed);
    }

    #[test]
    fn relayed_helper_matches_kind() {
        assert!(Candidate::relayed(addr()).is_relayed());
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
    fn host_and_relayed_addr_equals_local() {
        assert_eq!(Candidate::host(addr()).addr(), addr());
        assert_eq!(Candidate::host(addr()).local(), addr());
        assert_eq!(Candidate::relayed(addr()).addr(), addr());
        assert_eq!(Candidate::relayed(addr()).local(), addr());
    }
}
