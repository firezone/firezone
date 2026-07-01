use std::net::{IpAddr, SocketAddr};

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

    /// Encodes this candidate as an SDP `candidate:` attribute value.
    ///
    /// `foundation` and `priority` are synthesised; a `srflx`/`relay`
    /// candidate's base is carried in `raddr`/`rport` so the codec round-trips.
    pub fn to_sdp_string(self) -> String {
        let addr = self.addr();
        let (typ, related) = match self {
            Self::Host(_) => ("host", None),
            Self::ServerReflexive { local, .. } => ("srflx", Some(local)),
            Self::Relayed { local, .. } => ("relay", Some(local)),
        };

        let foundation = self.sdp_foundation(related);
        let priority = self.sdp_priority();

        let mut out = format!(
            "candidate:{foundation} 1 udp {priority} {ip} {port} typ {typ}",
            ip = addr.ip(),
            port = addr.port(),
        );

        if let Some(related) = related {
            use std::fmt::Write as _;
            let _ = write!(out, " raddr {} rport {}", related.ip(), related.port());
        }

        out
    }

    /// Parses an SDP `candidate:` value from [`Candidate::to_sdp_string`]. A
    /// `srflx`/`relay` candidate without an `raddr`/`rport` base is rejected.
    pub fn from_sdp_string(s: &str) -> Result<Self, ParseCandidateError> {
        use ParseCandidateError as E;

        let body = s.strip_prefix("candidate:").ok_or(E::Malformed)?;
        let mut fields = body.split_ascii_whitespace();

        let _foundation = fields.next().ok_or(E::Malformed)?;
        let _component = fields.next().ok_or(E::Malformed)?;
        let transport = fields.next().ok_or(E::Malformed)?;
        if !transport.eq_ignore_ascii_case("udp") {
            return Err(E::UnsupportedTransport);
        }
        let _priority = fields.next().ok_or(E::Malformed)?;
        let ip = fields.next().ok_or(E::Malformed)?;
        let port = fields.next().ok_or(E::Malformed)?;
        let addr = parse_socket(ip, port)?;

        if fields.next() != Some("typ") {
            return Err(E::Malformed);
        }
        let typ = fields.next().ok_or(E::Malformed)?;

        let rest: Vec<&str> = fields.collect();
        let related = match rest.iter().position(|f| *f == "raddr") {
            Some(i) => {
                let ip = rest.get(i + 1).ok_or(E::Malformed)?;
                let j = rest
                    .iter()
                    .position(|f| *f == "rport")
                    .ok_or(E::Malformed)?;
                let port = rest.get(j + 1).ok_or(E::Malformed)?;
                Some(parse_socket(ip, port)?)
            }
            None => None,
        };

        match typ {
            "host" => Ok(Self::host(addr)),
            "srflx" => Ok(Self::server_reflexive(addr, related.ok_or(E::MissingBase)?)),
            "relay" => Ok(Self::relayed(addr, related.ok_or(E::MissingBase)?)),
            _ => Err(E::UnknownType),
        }
    }

    /// Stable hash of the candidate's identity for the SDP `foundation`. FNV-1a
    /// so it's deterministic across toolchains, unlike `DefaultHasher`.
    fn sdp_foundation(&self, related: Option<SocketAddr>) -> u64 {
        let mut hash = 0xcbf2_9ce4_8422_2325;
        fnv_bytes(&mut hash, &[self.kind() as u8]);
        fnv_socket(&mut hash, self.addr());
        if let Some(related) = related {
            fnv_socket(&mut hash, related);
        }
        hash
    }

    /// SDP `priority`; only the `host > srflx > relay` ordering matters here.
    fn sdp_priority(&self) -> u32 {
        let type_preference: u32 = match self.kind() {
            CandidateKind::Host => 126,
            CandidateKind::ServerReflexive => 100,
            CandidateKind::Relayed => 0,
        };

        (type_preference << 24) | (0xffff << 8) | 255
    }
}

fn parse_socket(ip: &str, port: &str) -> Result<SocketAddr, ParseCandidateError> {
    let ip: IpAddr = ip
        .parse()
        .map_err(|_| ParseCandidateError::InvalidAddress)?;
    let port: u16 = port
        .parse()
        .map_err(|_| ParseCandidateError::InvalidAddress)?;

    Ok(SocketAddr::new(ip, port))
}

fn fnv_bytes(hash: &mut u64, bytes: &[u8]) {
    for &byte in bytes {
        *hash ^= u64::from(byte);
        *hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
}

fn fnv_socket(hash: &mut u64, socket: SocketAddr) {
    match socket.ip() {
        IpAddr::V4(v4) => fnv_bytes(hash, &v4.octets()),
        IpAddr::V6(v6) => fnv_bytes(hash, &v6.octets()),
    }
    fnv_bytes(hash, &socket.port().to_be_bytes());
}

/// Failure parsing an SDP `candidate:` line.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ParseCandidateError {
    Malformed,
    UnsupportedTransport,
    UnknownType,
    MissingBase,
    InvalidAddress,
}

impl std::fmt::Display for ParseCandidateError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let reason = match self {
            Self::Malformed => "malformed candidate line",
            Self::UnsupportedTransport => "unsupported transport (expected udp)",
            Self::UnknownType => "unknown candidate type",
            Self::MissingBase => "srflx/relay candidate without raddr/rport",
            Self::InvalidAddress => "invalid address or port",
        };

        write!(f, "{reason}")
    }
}

impl std::error::Error for ParseCandidateError {}

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

    fn round_trip(c: Candidate) {
        let encoded = c.to_sdp_string();
        let decoded = Candidate::from_sdp_string(&encoded).unwrap();
        assert_eq!(decoded, c, "round-trip mismatch for {encoded}");
    }

    #[test]
    fn sdp_round_trips_every_kind_and_family() {
        round_trip(Candidate::host(addr()));
        round_trip(Candidate::host(addr_v6()));
        round_trip(Candidate::server_reflexive(addr(), other_addr()));
        round_trip(Candidate::server_reflexive(addr_v6(), addr_v6()));
        round_trip(Candidate::relayed(addr(), other_addr()));
        round_trip(Candidate::relayed(addr_v6(), addr_v6()));
    }

    #[test]
    fn sdp_host_omits_base_and_srflx_relay_carry_it() {
        assert!(!Candidate::host(addr()).to_sdp_string().contains("raddr"));

        let srflx = Candidate::server_reflexive(addr(), other_addr()).to_sdp_string();
        assert!(srflx.contains("typ srflx"));
        assert!(srflx.contains("raddr 192.168.1.5 rport 1234"));

        let relay = Candidate::relayed(addr(), other_addr()).to_sdp_string();
        assert!(relay.contains("typ relay"));
        assert!(relay.contains("raddr 192.168.1.5 rport 1234"));
    }

    #[test]
    fn sdp_encoding_is_deterministic() {
        let c = Candidate::server_reflexive(addr(), other_addr());
        assert_eq!(c.to_sdp_string(), c.to_sdp_string());
    }

    fn priority(c: &Candidate) -> u32 {
        // `candidate:<foundation> <component> <transport> <priority> ...`
        c.to_sdp_string()
            .split_ascii_whitespace()
            .nth(3)
            .unwrap()
            .parse()
            .unwrap()
    }

    #[test]
    fn sdp_priority_orders_host_above_srflx_above_relay() {
        let host = priority(&Candidate::host(addr()));
        let srflx = priority(&Candidate::server_reflexive(addr(), other_addr()));
        let relay = priority(&Candidate::relayed(addr(), other_addr()));

        assert!(host > srflx);
        assert!(srflx > relay);
    }

    #[test]
    fn from_sdp_rejects_srflx_without_base() {
        assert_eq!(
            Candidate::from_sdp_string("candidate:1 1 udp 100 1.1.1.1 80 typ srflx"),
            Err(ParseCandidateError::MissingBase),
        );
    }

    #[test]
    fn from_sdp_rejects_non_udp_and_garbage() {
        assert_eq!(
            Candidate::from_sdp_string("candidate:1 1 tcp 100 1.1.1.1 80 typ host"),
            Err(ParseCandidateError::UnsupportedTransport),
        );
        assert_eq!(
            Candidate::from_sdp_string("not a candidate"),
            Err(ParseCandidateError::Malformed),
        );
        assert_eq!(
            Candidate::from_sdp_string("candidate:1 1 udp 100 999.1.1.1 80 typ host"),
            Err(ParseCandidateError::InvalidAddress),
        );
    }
}
