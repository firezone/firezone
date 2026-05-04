//! Connection-level agent dispatch.
//!
//! `Agent::Ice` holds the legacy str0m IceAgent. `Agent::Path` holds a
//! `path_agent::PathAgent` plus the candidate lists snownet still needs to
//! query — no credentials, no role.
//!
//! Snownet call sites stay agent-agnostic: they call decision methods named
//! for what they decide (`send_wg_handshake_after_nomination`), not generic
//! state queries (`controlling`). The variant-specific behaviour is hidden
//! inside this module.
//!
//! ICE-specific operations on the `Path` variant are no-ops by design:
//! - STUN inbound (`handle_stun_packet`) returns `false`.
//! - The various `set_*_credentials` calls drop the credentials on the floor.
//! - `poll_ice_event` and `poll_ice_transmit` always return `None`.
//!
//! Path-specific events arrive via the parallel `poll_path_event` method
//! (None on the Ice variant). Path-specific transmits land in a later commit
//! when ICMPv6 probing is implemented.

use std::ops::ControlFlow;
use std::time::Instant;

use is::stun::StunPacket;
use is::{Candidate, IceAgent, IceAgentEvent, IceConnectionState, IceCreds};

use crate::{IceConfig, IceRole};

#[derive(derive_more::Debug)]
pub(crate) enum Agent {
    Ice(IceAgent),
    Path {
        local_candidates: Vec<Candidate>,
        remote_candidates: Vec<Candidate>,
        #[debug(skip)]
        // Used in subsequent commits when iceless dispatch starts driving its own state.
        #[allow(dead_code)]
        path: path_agent::PathAgent,
    },
}

impl Agent {
    pub(crate) fn ice(agent: IceAgent) -> Self {
        Self::Ice(agent)
    }

    pub(crate) fn path() -> Self {
        Self::Path {
            local_candidates: Vec::new(),
            remote_candidates: Vec::new(),
            path: path_agent::PathAgent::new(),
        }
    }

    // Used in subsequent commits when call sites need to branch on the agent variant.
    #[allow(dead_code)]
    pub(crate) fn is_iceless(&self) -> bool {
        matches!(self, Self::Path { .. })
    }

    /// Whether negotiation has progressed far enough that the snownet
    /// idle-state machine can run. ICE: connected. Iceless: a primary path
    /// has been selected.
    pub(crate) fn is_negotiation_complete(&self) -> bool {
        match self {
            Self::Ice(a) => a.state() == IceConnectionState::Connected,
            Self::Path { path, .. } => path.primary().is_some(),
        }
    }

    /// Apply ICE-specific STUN-retransmit configuration. No-op for iceless.
    pub(crate) fn apply_ice_config(&mut self, config: IceConfig) {
        if let Self::Ice(a) = self {
            a.set_max_stun_retransmits(config.max_retrans);
            a.set_max_stun_rto(config.max_rto);
            a.set_initial_stun_rto(config.initial_rto);
        }
    }

    /// Whether this agent matches the parameters of an incoming
    /// `upsert_connection` call so the existing connection can be re-used.
    ///
    /// Iceless connections always report a match: ICE credentials and role
    /// are irrelevant in iceless mode, and the dimensions that actually
    /// matter for reuse (peer public key, preshared key) are verified by
    /// the caller before this method is consulted.
    pub(crate) fn matches_existing_connection(
        &self,
        local_creds: &IceCreds,
        remote_creds: &IceCreds,
        ice_role: IceRole,
    ) -> bool {
        match self {
            Self::Ice(a) => {
                a.local_credentials() == local_creds
                    && a.remote_credentials().is_some_and(|c| c == remote_creds)
                    && a.controlling() == matches!(ice_role, IceRole::Controlling)
            }
            Self::Path { .. } => true,
        }
    }

    /// Whether this side should send a WireGuard `HandshakeInit` after
    /// nominating a peer socket. ICE's controlling agent does this; the
    /// controlled agent waits for the remote to initiate. Iceless mode
    /// has no nomination — it fans out the handshake on relay pairs in
    /// `upsert_connection` directly — so this returns `false`.
    pub(crate) fn send_wg_handshake_after_nomination(&self) -> bool {
        match self {
            Self::Ice(a) => a.controlling(),
            Self::Path { .. } => false,
        }
    }

    /// Whether this side must wait for nomination before being allowed to
    /// originate WireGuard traffic. The ICE controlled agent does; the
    /// controlling agent doesn't. Iceless mode never waits.
    pub(crate) fn wait_for_nomination_before_wg_handshake(&self) -> bool {
        match self {
            Self::Ice(a) => !a.controlling(),
            Self::Path { .. } => false,
        }
    }

    /// Local ICE ufrag, if applicable. Used to track recent disconnects so
    /// stale credential-keyed lookups can be answered. Iceless connections
    /// don't have an ufrag and skip this tracking.
    pub(crate) fn local_ufrag(&self) -> Option<&str> {
        match self {
            Self::Ice(a) => Some(&a.local_credentials().ufrag),
            Self::Path { .. } => None,
        }
    }

    pub(crate) fn set_local_credentials(&mut self, creds: IceCreds) {
        match self {
            Self::Ice(a) => a.set_local_credentials(creds),
            Self::Path { .. } => {} // Iceless has no ICE creds.
        }
    }

    pub(crate) fn set_remote_credentials(&mut self, creds: IceCreds) {
        match self {
            Self::Ice(a) => a.set_remote_credentials(creds),
            Self::Path { .. } => {} // Iceless has no ICE creds.
        }
    }

    pub(crate) fn add_local_candidate(&mut self, c: Candidate) -> Option<&Candidate> {
        match self {
            Self::Ice(a) => a.add_local_candidate(c),
            Self::Path {
                local_candidates,
                path,
                ..
            } => {
                if local_candidates.contains(&c) {
                    return None;
                }
                path.add_local_candidate(crate::candidate::to_path_agent(&c));
                local_candidates.push(c);
                local_candidates.last()
            }
        }
    }

    pub(crate) fn add_remote_candidate(&mut self, c: Candidate) {
        match self {
            Self::Ice(a) => a.add_remote_candidate(c),
            Self::Path {
                remote_candidates,
                path,
                ..
            } => {
                if remote_candidates.contains(&c) {
                    return;
                }
                path.add_remote_candidate(crate::candidate::to_path_agent(&c));
                remote_candidates.push(c);
            }
        }
    }

    pub(crate) fn invalidate_candidate(&mut self, c: &Candidate) -> bool {
        match self {
            Self::Ice(a) => a.invalidate_candidate(c),
            Self::Path {
                local_candidates,
                remote_candidates,
                ..
            } => {
                let removed_local = local_candidates
                    .iter()
                    .position(|x| x == c)
                    .map(|i| local_candidates.remove(i))
                    .is_some();
                let removed_remote = remote_candidates
                    .iter()
                    .position(|x| x == c)
                    .map(|i| remote_candidates.remove(i))
                    .is_some();
                removed_local || removed_remote
            }
        }
    }

    pub(crate) fn local_candidates(&self) -> Box<dyn Iterator<Item = Candidate> + '_> {
        match self {
            Self::Ice(a) => Box::new(a.local_candidates()),
            Self::Path {
                local_candidates, ..
            } => Box::new(local_candidates.iter().cloned()),
        }
    }

    pub(crate) fn remote_candidates(&self) -> Box<dyn Iterator<Item = Candidate> + '_> {
        match self {
            Self::Ice(a) => Box::new(a.remote_candidates()),
            Self::Path {
                remote_candidates, ..
            } => Box::new(remote_candidates.iter().cloned()),
        }
    }

    pub(crate) fn contains_remote_candidate(&self, c: &Candidate) -> bool {
        match self {
            Self::Ice(a) => a.remote_candidates().any(|x| &x == c),
            Self::Path {
                remote_candidates, ..
            } => remote_candidates.iter().any(|x| x == c),
        }
    }

    /// Whether the destination of a freshly-nominated send pair is a relay
    /// candidate on the remote side. Used to classify the resulting
    /// `PeerSocket`. Iceless mode doesn't reach this code path (no
    /// nomination).
    pub(crate) fn remote_candidate_is_relayed(&self, addr: std::net::SocketAddr) -> bool {
        match self {
            Self::Ice(a) => a
                .remote_candidates()
                .any(|c| c.addr() == addr && c.kind() == is::CandidateKind::Relayed),
            Self::Path { path, .. } => path.remote_is_relayed(addr),
        }
    }

    /// Process an inbound STUN packet. Iceless mode doesn't speak STUN, so
    /// the `Path` variant returns `false` (caller treats packet as non-STUN).
    pub(crate) fn handle_stun_packet(&mut self, now: Instant, p: StunPacket<'_>) -> bool {
        match self {
            Self::Ice(a) => a.handle_packet(now, p),
            Self::Path { .. } => false,
        }
    }

    /// Hand off an inbound WG packet to the path-agent.
    /// `ControlFlow::Break(())` means the path-agent took ownership
    /// (handshake — possibly deduped, possibly to be forwarded to boringtun
    /// via [`path_agent::Event::ForwardInbound`]); the caller stops
    /// processing this packet.
    /// `ControlFlow::Continue(())` means non-handshake or ICE connection;
    /// the caller passes the bytes to `Tunn::decapsulate_at` directly.
    pub(crate) fn handle_inbound(
        &mut self,
        bytes: &[u8],
        path: (std::net::SocketAddr, std::net::SocketAddr),
        now: Instant,
    ) -> ControlFlow<()> {
        match self {
            Self::Ice(_) => ControlFlow::Continue(()),
            Self::Path { path: agent, .. } => agent.handle_inbound(bytes, path, now),
        }
    }

    /// Hand off a decrypted inner-IP packet (output of `Tunn::decapsulate_at`)
    /// to the path-agent. `ControlFlow::Break(())` means it was a path probe
    /// and was absorbed; the caller drops it instead of forwarding to the
    /// tun device. `ControlFlow::Continue(())` means ordinary user traffic
    /// (or ICE connection) — caller forwards to tun as usual.
    pub(crate) fn handle_inbound_decrypted(
        &mut self,
        packet: &ip_packet::IpPacket,
        path: (std::net::SocketAddr, std::net::SocketAddr),
        now: Instant,
    ) -> ControlFlow<()> {
        match self {
            Self::Ice(_) => ControlFlow::Continue(()),
            Self::Path { path: agent, .. } => agent.handle_inbound_decrypted(packet, path, now),
        }
    }

    pub(crate) fn handle_timeout(&mut self, now: Instant) {
        match self {
            Self::Ice(a) => a.handle_timeout(now),
            Self::Path { .. } => {
                // Iceless timer-driving lands in subsequent commits.
                let _ = now;
            }
        }
    }

    pub(crate) fn poll_timeout(&mut self) -> Option<Instant> {
        match self {
            Self::Ice(a) => a.poll_timeout(),
            Self::Path { path, .. } => path.poll_timeout(),
        }
    }

    /// Next ICE-agent event; `None` for iceless connections.
    pub(crate) fn poll_ice_event(&mut self) -> Option<IceAgentEvent> {
        match self {
            Self::Ice(a) => a.poll_event(),
            Self::Path { .. } => None,
        }
    }

    /// Next ICE-agent transmit (STUN traffic); `None` for iceless connections.
    pub(crate) fn poll_ice_transmit(&mut self) -> Option<str0m_proto::Transmit> {
        match self {
            Self::Ice(a) => a.poll_transmit(),
            Self::Path { .. } => None,
        }
    }

    /// Next path-agent event; `None` for ICE connections. Future commits
    /// emit `PrimarySelected` / `PrimaryChanged` here.
    pub(crate) fn poll_path_event(&mut self) -> Option<path_agent::PathEvent> {
        match self {
            Self::Ice(_) => None,
            Self::Path { path, .. } => path.poll_event(),
        }
    }

    /// Hand off an outbound WG packet from boringtun to the path-agent.
    /// No-op for ICE connections, which use the existing single-socket
    /// `peer_socket`-based send path.
    pub(crate) fn handle_outbound(&mut self, bytes: Vec<u8>, now: Instant) {
        if let Self::Path { path, .. } = self {
            path.handle_outbound(bytes, now);
        }
    }

    /// Drain the next outbound transmit produced by the path-agent (fanout,
    /// retransmit, replay, etc.). `None` for ICE connections.
    pub(crate) fn poll_path_transmit(&mut self) -> Option<path_agent::Transmit> {
        match self {
            Self::Ice(_) => None,
            Self::Path { path, .. } => path.poll_transmit(),
        }
    }
}
