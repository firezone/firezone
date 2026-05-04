use std::net::SocketAddr;

/// A candidate address known to the local end.
///
/// The kind drives tier-based path scoring: direct paths beat reflexive paths
/// beat relayed paths, all else equal.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Candidate {
    pub addr: SocketAddr,
    pub kind: CandidateKind,
}

impl Candidate {
    pub const fn new(addr: SocketAddr, kind: CandidateKind) -> Self {
        Self { addr, kind }
    }

    pub const fn host(addr: SocketAddr) -> Self {
        Self::new(addr, CandidateKind::Host)
    }

    pub const fn server_reflexive(addr: SocketAddr) -> Self {
        Self::new(addr, CandidateKind::ServerReflexive)
    }

    pub const fn relayed(addr: SocketAddr) -> Self {
        Self::new(addr, CandidateKind::Relayed)
    }

    pub const fn is_relayed(&self) -> bool {
        matches!(self.kind, CandidateKind::Relayed)
    }
}

/// Source of a candidate.
///
/// `Ord` follows the preference: `Host < ServerReflexive < Relayed` (lower is
/// better). The `derive(PartialOrd, Ord)` reflects the declaration order, so
/// adding new variants requires care.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum CandidateKind {
    /// A locally-bound socket address.
    Host,
    /// A NAT-mapped server-reflexive address.
    ServerReflexive,
    /// A TURN relay-allocated address.
    Relayed,
}

#[cfg(test)]
mod tests {
    use super::*;

    fn addr() -> SocketAddr {
        "127.0.0.1:1234".parse().unwrap()
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
        assert!(!Candidate::server_reflexive(addr()).is_relayed());
    }
}
