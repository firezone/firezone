use std::collections::{BTreeMap, VecDeque};
use std::net::SocketAddr;
use std::ops::ControlFlow;
use std::time::{Duration, Instant};

use boringtun::noise::{Packet, Tunn};

use crate::candidate::Candidate;

/// Path-selection state machine.
///
/// Mediates between boringtun's WireGuard state machine and the IO layer:
/// snownet hands every encapsulated outbound byte slice to
/// [`PathAgent::handle_outbound`] and every inbound byte slice to
/// [`PathAgent::handle_inbound`]. `PathAgent` parses the bytes and decides
/// what to do (fanout, dedup, replay), emitting work via
/// [`PathAgent::poll_transmit`] / [`PathAgent::poll_event`].
///
/// All public APIs identify pairs by `(local, remote)` `SocketAddr` tuples
/// so callers don't need to maintain a parallel mapping.
pub struct PathAgent {
    locals: Vec<Candidate>,
    remotes: Vec<Candidate>,
    pairs: BTreeMap<(SocketAddr, SocketAddr), PairState>,
    primary: Option<(SocketAddr, SocketAddr)>,

    /// Whether we've left the bootstrap fanout window. `false` until the
    /// first probe round-trip lands a primary; `true` after, at which
    /// point outbound `HandshakeInit` (re-key) goes via primary instead
    /// of fanning out.
    established: bool,

    /// Path the most recently `Forward`ed inbound `HandshakeInit` arrived
    /// on. The next outbound `HandshakeResponse` will be sent back on
    /// this path and cached against the init bytes for replay.
    last_forwarded_init: Option<Vec<u8>>,
    last_forwarded_init_path: Option<(SocketAddr, SocketAddr)>,

    pending_transmits: VecDeque<Transmit>,
    events: VecDeque<Event>,
    /// Timestamp at which the oldest currently-queued event was pushed.
    /// `None` once `poll_event` drains everything. Surfaced through
    /// `poll_timeout` so the owning connection's `handle_timeout` runs
    /// promptly to drain.
    events_queued_at: Option<Instant>,
}

struct PairState {
    /// Kinds of the local + remote candidate, captured at insertion time.
    kinds: (crate::CandidateKind, crate::CandidateKind),
    /// Last observed handshake on this pair.
    last_handshake_at: Option<Instant>,
    /// Smoothed RTT, populated from probe round-trips.
    smoothed_rtt: Option<Duration>,
}

impl PairState {
    fn involves_relay(&self) -> bool {
        matches!(self.kinds.0, crate::CandidateKind::Relayed)
            || matches!(self.kinds.1, crate::CandidateKind::Relayed)
    }
}

/// A single outbound transmit emitted by `PathAgent`.
///
/// `local` is the source side (host bind address or relay-allocation
/// address); `remote` is the destination. The owning snownet code wraps
/// the payload into the appropriate transport (host send vs. TURN
/// channel-data) based on `local`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Transmit {
    pub local: SocketAddr,
    pub remote: SocketAddr,
    pub payload: Vec<u8>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Event {
    /// First time we have a primary path.
    PrimarySelected {
        local: SocketAddr,
        remote: SocketAddr,
    },
    /// Primary path changed mid-life.
    PrimaryChanged {
        from: (SocketAddr, SocketAddr),
        to: (SocketAddr, SocketAddr),
    },
    /// Bytes from a previous `handle_inbound` call that need to flow
    /// through boringtun's state machine. The caller pipes these bytes
    /// into `Tunn::decapsulate_at`.
    ForwardInbound { bytes: Vec<u8> },
}

/// Legacy alias: kept for an existing snownet call site that drains
/// path-specific events separately from the main `Event` channel. Will
/// fold into `Event` in a follow-up commit once the cross-cutting refactor
/// is unblocked.
pub type PathEvent = Event;

impl Default for PathAgent {
    fn default() -> Self {
        Self::new()
    }
}

impl PathAgent {
    pub fn new() -> Self {
        Self {
            locals: Vec::new(),
            remotes: Vec::new(),
            pairs: BTreeMap::new(),
            primary: None,
            established: false,
            last_forwarded_init: None,
            last_forwarded_init_path: None,
            pending_transmits: VecDeque::new(),
            events: VecDeque::new(),
            events_queued_at: None,
        }
    }

    fn queue_event(&mut self, event: Event, now: Instant) {
        self.events.push_back(event);
        self.events_queued_at = self.events_queued_at.or(Some(now));
    }

    pub fn add_local_candidate(&mut self, c: Candidate) {
        if self.locals.contains(&c) {
            return;
        }
        self.locals.push(c);
        for &remote in &self.remotes.clone() {
            self.add_pair(c, remote);
        }
    }

    pub fn add_remote_candidate(&mut self, c: Candidate) {
        if self.remotes.contains(&c) {
            return;
        }
        self.remotes.push(c);
        for &local in &self.locals.clone() {
            self.add_pair(local, c);
        }
    }

    fn add_pair(&mut self, local: Candidate, remote: Candidate) {
        self.pairs.insert(
            (local.addr, remote.addr),
            PairState {
                kinds: (local.kind, remote.kind),
                last_handshake_at: None,
                smoothed_rtt: None,
            },
        );
    }

    /// Note that a WG handshake message (init or response) was received on
    /// this pair. Used to seed initial scoring before probes have data.
    pub fn observe_handshake(&mut self, local: SocketAddr, remote: SocketAddr, now: Instant) {
        if let Some(state) = self.pairs.get_mut(&(local, remote)) {
            state.last_handshake_at = Some(now);
        }
    }

    /// Note an observed RTT for this pair (one ICMPv6 echo round-trip).
    pub fn observe_probe(&mut self, local: SocketAddr, remote: SocketAddr, rtt: Duration) {
        if let Some(state) = self.pairs.get_mut(&(local, remote)) {
            // Placeholder smoothing — proper EMA arrives with the probe loop.
            state.smoothed_rtt = Some(match state.smoothed_rtt {
                None => rtt,
                Some(prev) => (prev + rtt) / 2,
            });
        }
    }

    /// Currently-best send pair, if any.
    pub fn primary(&self) -> Option<(SocketAddr, SocketAddr)> {
        self.primary
    }

    /// Iterate every relay-involved pair. The initial WG handshake fans out
    /// across this set.
    pub fn relay_pairs(&self) -> impl Iterator<Item = (SocketAddr, SocketAddr)> + '_ {
        self.pairs
            .iter()
            .filter(|(_, state)| state.involves_relay())
            .map(|(addrs, _)| *addrs)
    }

    /// Iterate every known pair as `(local, remote)`.
    pub fn pairs(&self) -> impl Iterator<Item = (SocketAddr, SocketAddr)> + '_ {
        self.pairs.keys().copied()
    }

    /// Whether `addr` matches a known remote candidate of relay kind. Used by
    /// the snownet-side dispatch to classify the destination of a freshly
    /// emitted send pair.
    pub fn remote_is_relayed(&self, addr: SocketAddr) -> bool {
        self.remotes
            .iter()
            .any(|c| c.addr == addr && c.is_relayed())
    }

    /// Hand off an outbound WG packet emitted by boringtun. `PathAgent`
    /// decides how to send it: fanout (`HandshakeInit` while bootstrapping),
    /// pair against the most-recent inbound init (`HandshakeResponse`),
    /// or single-send on `primary` (everything else).
    pub fn handle_outbound(&mut self, bytes: Vec<u8>, now: Instant) {
        let _ = now;
        let parsed = Tunn::parse_incoming_packet(&bytes);

        match parsed {
            Ok(Packet::HandshakeInit(_)) if !self.established => {
                // Bootstrap fanout: same bytes on every relay-involved pair.
                for (local, remote) in self.relay_pairs().collect::<Vec<_>>() {
                    self.pending_transmits.push_back(Transmit {
                        local,
                        remote,
                        payload: bytes.clone(),
                    });
                }
            }
            Ok(Packet::HandshakeResponse(_)) => {
                // Pair this response with the most recent inbound init we
                // forwarded; send back on the same path. The dedup cache
                // (next commit) will also store the (init -> response, path)
                // tuple here.
                if let Some(path) = self.last_forwarded_init_path.take() {
                    self.last_forwarded_init = None;
                    self.pending_transmits.push_back(Transmit {
                        local: path.0,
                        remote: path.1,
                        payload: bytes,
                    });
                }
            }
            _ => {
                // HandshakeInit during established phase (re-key), data, cookie:
                // send on primary if we have one.
                if let Some((local, remote)) = self.primary {
                    self.pending_transmits.push_back(Transmit {
                        local,
                        remote,
                        payload: bytes,
                    });
                }
            }
        }
    }

    /// Hand off an inbound WG packet that arrived on `path`.
    /// `ControlFlow::Break(())` means `PathAgent` took ownership of the
    /// packet (it was a handshake — possibly deduped, possibly to be
    /// forwarded via [`Event::ForwardInbound`]); the caller stops
    /// processing this packet.
    /// `ControlFlow::Continue(())` means it's a non-handshake packet;
    /// the caller passes the bytes to `Tunn::decapsulate_at` directly.
    pub fn handle_inbound(
        &mut self,
        bytes: &[u8],
        path: (SocketAddr, SocketAddr),
        now: Instant,
    ) -> ControlFlow<()> {
        let _ = now;
        let Ok(parsed) = Tunn::parse_incoming_packet(bytes) else {
            return ControlFlow::Continue(());
        };

        match parsed {
            Packet::HandshakeInit(_) => {
                // Dedup-cache lookup lands in a follow-up commit. For now
                // every init is treated as new: stash for outbound-response
                // correlation and ask the caller to forward to boringtun.
                self.last_forwarded_init = Some(bytes.to_vec());
                self.last_forwarded_init_path = Some(path);
                self.queue_event(
                    Event::ForwardInbound {
                        bytes: bytes.to_vec(),
                    },
                    now,
                );
                ControlFlow::Break(())
            }
            Packet::HandshakeResponse(_) => {
                // Initiator-side dedup lands in a follow-up commit. For now
                // every response is forwarded.
                self.queue_event(
                    Event::ForwardInbound {
                        bytes: bytes.to_vec(),
                    },
                    now,
                );
                ControlFlow::Break(())
            }
            Packet::PacketCookieReply(_) | Packet::PacketData(_) => ControlFlow::Continue(()),
        }
    }

    pub fn poll_transmit(&mut self) -> Option<Transmit> {
        self.pending_transmits.pop_front()
    }

    pub fn poll_event(&mut self) -> Option<Event> {
        let event = self.events.pop_front();
        if self.events.is_empty() {
            self.events_queued_at = None;
        }
        event
    }

    pub fn poll_timeout(&self) -> Option<Instant> {
        // Retransmit timers land in a follow-up commit. For now, the only
        // pending work is queued events, surfaced as "fire as soon as the
        // caller next runs `handle_timeout`".
        self.events_queued_at
    }

    pub fn handle_timeout(&mut self, _now: Instant) {
        // Retransmit driving lands in a follow-up commit.
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::candidate::Candidate;

    fn addr(p: u16) -> SocketAddr {
        format!("127.0.0.1:{p}").parse().unwrap()
    }

    #[test]
    fn new_agent_has_no_pairs_or_primary() {
        let a = PathAgent::new();
        assert!(a.primary().is_none());
        assert_eq!(a.pairs().count(), 0);
        assert_eq!(a.relay_pairs().count(), 0);
    }

    #[test]
    fn pairs_form_cartesian_product_of_locals_and_remotes() {
        let mut a = PathAgent::new();
        a.add_local_candidate(Candidate::host(addr(1)));
        a.add_local_candidate(Candidate::relayed(addr(2)));
        a.add_remote_candidate(Candidate::host(addr(3)));
        a.add_remote_candidate(Candidate::relayed(addr(4)));

        // 2 × 2 = 4 pairs
        assert_eq!(a.pairs().count(), 4);
    }

    #[test]
    fn relay_pairs_filters_correctly() {
        let mut a = PathAgent::new();
        a.add_local_candidate(Candidate::host(addr(1)));
        a.add_local_candidate(Candidate::relayed(addr(2)));
        a.add_remote_candidate(Candidate::host(addr(3)));
        a.add_remote_candidate(Candidate::relayed(addr(4)));

        // host×host is non-relay; the other 3 involve at least one relay.
        assert_eq!(a.relay_pairs().count(), 3);
    }

    #[test]
    fn remote_is_relayed_matches_only_relay_kind_at_addr() {
        let mut a = PathAgent::new();
        a.add_remote_candidate(Candidate::host(addr(1)));
        a.add_remote_candidate(Candidate::relayed(addr(2)));

        assert!(!a.remote_is_relayed(addr(1)));
        assert!(a.remote_is_relayed(addr(2)));
        assert!(!a.remote_is_relayed(addr(3))); // unknown addr
    }

    #[test]
    fn duplicate_candidates_are_ignored() {
        let mut a = PathAgent::new();
        let c = Candidate::host(addr(1));
        a.add_local_candidate(c);
        a.add_local_candidate(c);
        a.add_remote_candidate(Candidate::host(addr(2)));
        assert_eq!(a.pairs().count(), 1);
    }

    #[test]
    fn observe_handshake_on_unknown_pair_is_noop() {
        let mut a = PathAgent::new();
        a.observe_handshake(addr(1), addr(2), Instant::now()); // does not panic
    }

    #[test]
    fn pairs_yields_local_remote_addresses() {
        let mut a = PathAgent::new();
        a.add_local_candidate(Candidate::host(addr(1)));
        a.add_remote_candidate(Candidate::host(addr(2)));

        let pairs: Vec<_> = a.pairs().collect();
        assert_eq!(pairs, vec![(addr(1), addr(2))]);
    }

    #[test]
    fn inbound_unparseable_bytes_return_false() {
        let mut a = PathAgent::new();
        // Random non-WG bytes — parse_incoming_packet returns Err.
        let handled = a.handle_inbound(
            &[0xde, 0xad, 0xbe, 0xef],
            (addr(1), addr(2)),
            Instant::now(),
        );
        assert!(matches!(handled, ControlFlow::Continue(())));
    }

    #[test]
    fn poll_transmit_drains_in_order() {
        let mut a = PathAgent::new();
        a.pending_transmits.push_back(Transmit {
            local: addr(1),
            remote: addr(2),
            payload: vec![1],
        });
        a.pending_transmits.push_back(Transmit {
            local: addr(3),
            remote: addr(4),
            payload: vec![2],
        });

        assert_eq!(a.poll_transmit().unwrap().payload, vec![1]);
        assert_eq!(a.poll_transmit().unwrap().payload, vec![2]);
        assert!(a.poll_transmit().is_none());
    }

    /// Construct a minimum-validity WG `HandshakeInit` packet:
    /// 4-byte type header (1 = init), padded to the WG-required 148 bytes.
    fn handshake_init_bytes() -> Vec<u8> {
        let mut bytes = vec![0u8; 148];
        bytes[0] = 1;
        bytes
    }

    fn handshake_response_bytes() -> Vec<u8> {
        let mut bytes = vec![0u8; 92];
        bytes[0] = 2;
        bytes
    }

    fn data_packet_bytes() -> Vec<u8> {
        let mut bytes = vec![0u8; 32];
        bytes[0] = 4;
        bytes
    }

    fn agent_with_relay_pairs() -> PathAgent {
        let mut a = PathAgent::new();
        a.add_local_candidate(Candidate::host(addr(1)));
        a.add_local_candidate(Candidate::relayed(addr(2)));
        a.add_remote_candidate(Candidate::host(addr(3)));
        a.add_remote_candidate(Candidate::relayed(addr(4)));
        a
    }

    #[test]
    fn outbound_handshake_init_fans_out_on_every_relay_pair() {
        let mut a = agent_with_relay_pairs();

        a.handle_outbound(handshake_init_bytes(), Instant::now());

        let transmits: Vec<_> = std::iter::from_fn(|| a.poll_transmit()).collect();
        // 3 relay-involved pairs (host×host excluded).
        assert_eq!(transmits.len(), 3);
        // Every fan-out copy carries identical bytes — that's what lets the
        // responder's dedup cache replay a single cached response.
        let payload = handshake_init_bytes();
        for t in &transmits {
            assert_eq!(t.payload, payload);
        }
    }

    #[test]
    fn outbound_handshake_init_fanout_targets_match_relay_pairs() {
        let mut a = agent_with_relay_pairs();

        a.handle_outbound(handshake_init_bytes(), Instant::now());

        let mut emitted: Vec<_> = std::iter::from_fn(|| a.poll_transmit())
            .map(|t| (t.local, t.remote))
            .collect();
        emitted.sort();

        let mut expected: Vec<_> = a.relay_pairs().collect();
        expected.sort();

        assert_eq!(emitted, expected);
    }

    #[test]
    fn outbound_data_with_primary_set_sends_on_primary() {
        let mut a = PathAgent::new();
        a.add_local_candidate(Candidate::host(addr(1)));
        a.add_remote_candidate(Candidate::host(addr(2)));
        a.primary = Some((addr(1), addr(2)));

        a.handle_outbound(data_packet_bytes(), Instant::now());

        let t = a.poll_transmit().expect("primary transmit");
        assert_eq!(t.local, addr(1));
        assert_eq!(t.remote, addr(2));
        assert!(a.poll_transmit().is_none());
    }

    #[test]
    fn outbound_data_without_primary_is_dropped() {
        let mut a = PathAgent::new();

        a.handle_outbound(data_packet_bytes(), Instant::now());

        assert!(a.poll_transmit().is_none());
    }

    #[test]
    fn outbound_handshake_response_without_inbound_init_is_dropped() {
        let mut a = agent_with_relay_pairs();

        a.handle_outbound(handshake_response_bytes(), Instant::now());

        assert!(a.poll_transmit().is_none());
    }

    #[test]
    fn outbound_handshake_response_replays_on_recv_path_of_last_inbound_init() {
        let mut a = agent_with_relay_pairs();
        let recv_path = (addr(2), addr(4));

        // Simulate inbound init arriving on the relay-relay path.
        let handled = a.handle_inbound(&handshake_init_bytes(), recv_path, Instant::now());
        assert!(matches!(handled, ControlFlow::Break(())));
        // Drain the ForwardInbound event so it doesn't pollute later assertions.
        let _ = a.poll_event();

        // boringtun produces a response in reaction; PathAgent ships it
        // back on the same path the init came from.
        a.handle_outbound(handshake_response_bytes(), Instant::now());

        let t = a.poll_transmit().expect("response transmit");
        assert_eq!(t.local, recv_path.0);
        assert_eq!(t.remote, recv_path.1);
        assert_eq!(t.payload, handshake_response_bytes());
    }

    #[test]
    fn inbound_handshake_init_returns_true_and_emits_forward_event() {
        let mut a = agent_with_relay_pairs();

        let handled = a.handle_inbound(&handshake_init_bytes(), (addr(2), addr(4)), Instant::now());
        assert!(matches!(handled, ControlFlow::Break(())));

        match a.poll_event() {
            Some(Event::ForwardInbound { bytes }) => assert_eq!(bytes, handshake_init_bytes()),
            other => panic!("expected ForwardInbound, got {other:?}"),
        }
    }

    #[test]
    fn inbound_handshake_response_returns_true_and_emits_forward_event() {
        let mut a = agent_with_relay_pairs();

        let handled = a.handle_inbound(
            &handshake_response_bytes(),
            (addr(2), addr(4)),
            Instant::now(),
        );
        assert!(matches!(handled, ControlFlow::Break(())));

        match a.poll_event() {
            Some(Event::ForwardInbound { bytes }) => assert_eq!(bytes, handshake_response_bytes()),
            other => panic!("expected ForwardInbound, got {other:?}"),
        }
    }

    #[test]
    fn inbound_data_packet_returns_false_and_emits_no_event() {
        let mut a = agent_with_relay_pairs();

        let handled = a.handle_inbound(&data_packet_bytes(), (addr(2), addr(4)), Instant::now());
        assert!(matches!(handled, ControlFlow::Continue(())));
        assert!(a.poll_event().is_none());
    }
}
