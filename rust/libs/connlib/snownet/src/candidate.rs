//! Adapt str0m candidates into the path-agent's representation.
//!
//! Both the IceAgent (str0m's `Candidate`) and the PathAgent
//! (`path_agent::Candidate`) consume the same gathered candidate set; this
//! conversion lets us feed both from a single source.
//!
//! `PeerReflexive` collapses to `ServerReflexive` because the path-agent's
//! tier scoring doesn't distinguish them: both are "indirect, NAT-mapped".
//! For server-reflexive candidates we preserve `is::Candidate::local()`
//! (the underlying base socket) — it's what we send from on the wire,
//! whereas `addr()` is the NAT-mapped public-facing address.

use is::CandidateKind;

#[allow(dead_code)] // Used in the next commit; staged here so the conversion can be reviewed in isolation.
pub(crate) fn to_path_agent(c: &is::Candidate) -> path_agent::Candidate {
    match c.kind() {
        CandidateKind::Host => path_agent::Candidate::host(c.addr()),
        CandidateKind::ServerReflexive | CandidateKind::PeerReflexive => {
            path_agent::Candidate::server_reflexive(c.addr(), c.local())
        }
        CandidateKind::Relayed => path_agent::Candidate::relayed(c.addr(), c.local()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::SocketAddr;

    fn addr() -> SocketAddr {
        "1.1.1.1:1234".parse().unwrap()
    }

    fn other_addr() -> SocketAddr {
        "2.2.2.2:5678".parse().unwrap()
    }

    #[test]
    fn host_maps_to_host() {
        let c = is::Candidate::host(addr(), "udp").unwrap();
        let mapped = to_path_agent(&c);
        assert_eq!(mapped.kind(), path_agent::CandidateKind::Host);
        assert_eq!(mapped.addr(), addr());
        assert_eq!(mapped.local(), addr());
    }

    #[test]
    fn server_reflexive_preserves_addr_and_local() {
        // `addr` is the NAT-mapped public address peers reach us at;
        // `local` is the underlying base socket we send from.
        let c = is::Candidate::server_reflexive(addr(), other_addr(), "udp").unwrap();
        let mapped = to_path_agent(&c);
        assert_eq!(mapped.kind(), path_agent::CandidateKind::ServerReflexive);
        assert_eq!(mapped.addr(), addr());
        assert_eq!(mapped.local(), other_addr());
    }

    #[test]
    fn relayed_maps_to_relayed() {
        let c = is::Candidate::relayed(addr(), other_addr(), "udp").unwrap();
        let mapped = to_path_agent(&c);
        assert_eq!(mapped.kind(), path_agent::CandidateKind::Relayed);
        assert_eq!(mapped.addr(), addr());
    }
}
