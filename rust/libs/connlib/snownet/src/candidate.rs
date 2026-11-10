//! Adapt str0m candidates into frostlink's representation.
//!
//! Both the IceAgent (str0m's `Candidate`) and the frostlink `Agent`
//! (`frostlink::Candidate`) consume the same gathered candidate set; this
//! conversion lets us feed both from a single source.
//!
//! For server-reflexive candidates we preserve `is::Candidate::local()`
//! (the underlying base socket) — it's what we send from on the wire,
//! whereas `addr()` is the NAT-mapped public-facing address.

use is::CandidateKind;

/// A host candidate's local preference travels in [`is::Candidate::prio`], see [`from_frostlink`].
pub(crate) fn to_frostlink(c: &is::Candidate) -> frostlink::Candidate {
    match c.kind() {
        CandidateKind::Host => {
            frostlink::Candidate::host(c.addr()).with_local_preference((c.prio() >> 8) as u16)
        }
        CandidateKind::ServerReflexive => {
            frostlink::Candidate::server_reflexive(c.addr(), c.local())
        }
        CandidateKind::PeerReflexive => frostlink::Candidate::peer_reflexive(c.addr()),
        CandidateKind::Relayed => frostlink::Candidate::relayed(c.addr(), c.local()),
    }
}

/// Inverse of [`to_frostlink`]: rebuilds the str0m `Candidate` the rest of
/// snownet works with when decoding a Frostlink candidate off the wire.
pub(crate) fn from_frostlink(c: &frostlink::Candidate) -> Option<is::Candidate> {
    let candidate = match c.address() {
        frostlink::Address::Host(addr) => is::Candidate::host(addr, "udp").map(|_| {
            is::Candidate::from_parts(
                String::new(),
                1,
                is::Protocol::Udp,
                c.priority(),
                addr,
                CandidateKind::Host,
                None,
                None,
                None,
            )
        }),
        frostlink::Address::ServerReflexive { addr, local } => {
            is::Candidate::server_reflexive(addr, local, "udp")
        }
        frostlink::Address::PeerReflexive(addr) => Ok(is::Candidate::from_parts(
            String::new(),
            1,
            is::Protocol::Udp,
            0,
            addr,
            CandidateKind::PeerReflexive,
            None,
            None,
            None,
        )),
        frostlink::Address::Relayed { addr, local } => is::Candidate::relayed(addr, local, "udp"),
    };

    candidate.ok()
}

/// Encode a candidate for signalling: frostlink's SDP codec for Frostlink
/// connections (keeping `is` off the wire), str0m's otherwise.
pub(crate) fn encode(is_frostlink: bool, c: &is::Candidate) -> String {
    if is_frostlink {
        to_frostlink(c).to_sdp_string()
    } else {
        c.to_sdp_string()
    }
}

/// Parse a signalled candidate, choosing the codec by whether the connection
/// uses Frostlink. Returns `None` (and logs) on malformed input.
pub(crate) fn decode(is_frostlink: bool, sdp: &str) -> Option<is::Candidate> {
    if is_frostlink {
        match frostlink::Candidate::from_sdp_string(sdp) {
            Ok(c) => from_frostlink(&c),
            Err(e) => {
                tracing::debug!(%sdp, "Failed to parse Frostlink candidate: {e}");
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
        let mapped = to_frostlink(&c);
        assert_eq!(mapped.kind(), frostlink::CandidateKind::Host);
        assert_eq!(mapped.addr(), addr());
        assert_eq!(mapped.local(), addr());
    }

    #[test]
    fn server_reflexive_preserves_addr_and_local() {
        // `addr` is the NAT-mapped public address peers reach us at;
        // `local` is the underlying base socket we send from.
        let c = is::Candidate::server_reflexive(addr(), other_addr(), "udp").unwrap();
        let mapped = to_frostlink(&c);
        assert_eq!(mapped.kind(), frostlink::CandidateKind::ServerReflexive);
        assert_eq!(mapped.addr(), addr());
        assert_eq!(mapped.local(), other_addr());
    }

    #[test]
    fn relayed_maps_to_relayed() {
        let c = is::Candidate::relayed(addr(), other_addr(), "udp").unwrap();
        let mapped = to_frostlink(&c);
        assert_eq!(mapped.kind(), frostlink::CandidateKind::Relayed);
        assert_eq!(mapped.addr(), addr());
    }

    #[test]
    fn frostlink_encode_decode_preserves_path_representation() {
        for original in [
            is::Candidate::host(addr(), "udp").unwrap(),
            is::Candidate::server_reflexive(addr(), other_addr(), "udp").unwrap(),
            is::Candidate::relayed(addr(), other_addr(), "udp").unwrap(),
        ] {
            let sdp = encode(true, &original);
            let decoded = decode(true, &sdp).expect("frostlink round-trip");

            // The path agent keys off addr/kind/base, so that is what must survive.
            assert_eq!(to_frostlink(&decoded), to_frostlink(&original));
        }
    }

    #[test]
    fn frostlink_host_priority_survives_signalling() {
        let original = frostlink::Candidate::host(addr()).with_local_preference(u16::MAX);

        let signalled = encode(true, &from_frostlink(&original).unwrap());
        let received = to_frostlink(&decode(true, &signalled).unwrap());

        assert_eq!(received.priority(), original.priority());
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
