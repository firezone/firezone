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

pub(crate) fn to_path_agent(c: &is::Candidate) -> path_agent::Candidate {
    match c.kind() {
        CandidateKind::Host => path_agent::Candidate::host(c.addr()),
        CandidateKind::ServerReflexive | CandidateKind::PeerReflexive => {
            path_agent::Candidate::server_reflexive(c.addr(), c.local())
        }
        CandidateKind::Relayed => path_agent::Candidate::relayed(c.addr(), c.local()),
    }
}

/// Inverse of [`to_path_agent`]: rebuilds the str0m `Candidate` the rest of
/// snownet works with when decoding an ICE-less candidate off the wire.
fn from_path_agent(c: &path_agent::Candidate) -> Option<is::Candidate> {
    let candidate = match *c {
        path_agent::Candidate::Host(addr) => is::Candidate::host(addr, "udp"),
        path_agent::Candidate::ServerReflexive { addr, local } => {
            is::Candidate::server_reflexive(addr, local, "udp")
        }
        path_agent::Candidate::Relayed { addr, local } => {
            is::Candidate::relayed(addr, local, "udp")
        }
    };

    candidate.ok()
}

/// Encode a candidate for signalling: the path-agent's SDP codec when ICE-less
/// (keeping `is` off the wire), str0m's otherwise.
pub(crate) fn encode(iceless: bool, c: &is::Candidate) -> String {
    if iceless {
        to_path_agent(c).to_sdp_string()
    } else {
        c.to_sdp_string()
    }
}

/// Parse a signalled candidate, choosing the codec by whether the connection is
/// ICE-less. Returns `None` (and logs) on malformed input.
pub(crate) fn decode(iceless: bool, sdp: &str) -> Option<is::Candidate> {
    if iceless {
        match path_agent::Candidate::from_sdp_string(sdp) {
            Ok(c) => from_path_agent(&c),
            Err(e) => {
                tracing::debug!(%sdp, "Failed to parse ICE-less candidate: {e}");
                None
            }
        }
    } else {
        match is::Candidate::from_sdp_string(sdp) {
            Ok(c) => Some(c),
            Err(e) => {
                tracing::debug!(%sdp, "Failed to parse ICE candidate: {e}");
                None
            }
        }
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

    #[test]
    fn iceless_encode_decode_preserves_path_representation() {
        for original in [
            is::Candidate::host(addr(), "udp").unwrap(),
            is::Candidate::server_reflexive(addr(), other_addr(), "udp").unwrap(),
            is::Candidate::relayed(addr(), other_addr(), "udp").unwrap(),
        ] {
            let sdp = encode(true, &original);
            let decoded = decode(true, &sdp).expect("iceless round-trip");

            // The path agent keys off addr/kind/base, so that is what must survive.
            assert_eq!(to_path_agent(&decoded), to_path_agent(&original));
        }
    }

    #[test]
    fn ice_encode_is_byte_for_byte_str0m() {
        let original = is::Candidate::server_reflexive(addr(), other_addr(), "udp").unwrap();

        assert_eq!(encode(false, &original), original.to_sdp_string());
    }

    #[test]
    fn ice_decode_recovers_addr_and_kind() {
        // str0m omits `raddr` for srflx, so a full-equality round-trip isn't
        // meaningful; what matters is the address and kind come back.
        let original = is::Candidate::host(addr(), "udp").unwrap();
        let decoded = decode(false, &encode(false, &original)).unwrap();

        assert_eq!(decoded.addr(), original.addr());
        assert_eq!(decoded.kind(), original.kind());
    }

    #[test]
    fn decode_skips_malformed() {
        assert_eq!(decode(true, "garbage"), None);
        assert_eq!(decode(false, "garbage"), None);
    }
}
