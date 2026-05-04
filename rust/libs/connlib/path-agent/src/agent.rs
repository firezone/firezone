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

    /// The outbound `HandshakeInit` we're currently retransmitting per
    /// pair. `None` once the matching `HandshakeResponse` arrives, or
    /// when boringtun emits a fresh init (which replaces this slot).
    outbound_init: Option<OutboundInit>,

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

/// State associated with the currently-outbound `HandshakeInit` bytes
/// that we're retransmitting per pair until the matching response arrives.
struct OutboundInit {
    bytes: Vec<u8>,
    /// Per-pair retransmit deadlines + backoff step.
    retransmits: BTreeMap<(SocketAddr, SocketAddr), PairRetransmit>,
}

struct PairRetransmit {
    next_fire_at: Instant,
    /// Current backoff step (0..=MAX_STEP). Each fire produces
    /// `100ms << step` to the next deadline, saturating at `MAX_STEP`.
    step: u32,
}

impl PairRetransmit {
    /// First retransmit fires 100ms after the original send.
    const INITIAL: Duration = Duration::from_millis(100);
    /// `100ms << 4 = 1.6s` is the per-pair retransmit cap.
    const MAX_STEP: u32 = 4;

    fn new(now: Instant) -> Self {
        Self {
            next_fire_at: now + Self::INITIAL,
            step: 0,
        }
    }

    fn advance(&mut self, now: Instant) {
        self.step = (self.step + 1).min(Self::MAX_STEP);
        let backoff = Duration::from_millis(100u64 << self.step);
        self.next_fire_at = now + backoff;
    }
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
            outbound_init: None,
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
        let parsed = Tunn::parse_incoming_packet(&bytes);

        match parsed {
            Ok(Packet::HandshakeInit(_)) if !self.established => {
                // Bootstrap fanout: same bytes on every relay-involved pair.
                // Each pair gets its own retransmit ladder; the cached
                // bytes are what `handle_timeout` re-emits per pair until
                // the matching `HandshakeResponse` arrives.
                let pairs: Vec<_> = self.relay_pairs().collect();
                let mut retransmits = BTreeMap::new();
                for &(local, remote) in &pairs {
                    self.pending_transmits.push_back(Transmit {
                        local,
                        remote,
                        payload: bytes.clone(),
                    });
                    retransmits.insert((local, remote), PairRetransmit::new(now));
                }
                self.outbound_init = Some(OutboundInit { bytes, retransmits });
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
                //
                // Receipt of a response means the corresponding outbound
                // init succeeded: clear the per-pair retransmit ladder so
                // we stop re-emitting it.
                self.outbound_init = None;
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
        let next_retransmit = self
            .outbound_init
            .as_ref()
            .and_then(|i| i.retransmits.values().map(|r| r.next_fire_at).min());

        [self.events_queued_at, next_retransmit]
            .into_iter()
            .flatten()
            .min()
    }

    pub fn handle_timeout(&mut self, now: Instant) {
        // Disjoint-fields borrow: we mutate `outbound_init` and
        // `pending_transmits` via different paths.
        let pending = &mut self.pending_transmits;
        let Some(outbound) = self.outbound_init.as_mut() else {
            return;
        };
        for ((local, remote), state) in outbound.retransmits.iter_mut() {
            if now >= state.next_fire_at {
                pending.push_back(Transmit {
                    local: *local,
                    remote: *remote,
                    payload: outbound.bytes.clone(),
                });
                state.advance(now);
            }
        }
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

    #[test]
    fn outbound_handshake_init_arms_retransmits_with_initial_100ms_deadline() {
        let mut a = agent_with_relay_pairs();
        let now = Instant::now();

        a.handle_outbound(handshake_init_bytes(), now);
        // Drain the immediate fanout transmits so we look at the timer state.
        while a.poll_transmit().is_some() {}

        let next = a.poll_timeout().expect("retransmit deadline");
        // Initial backoff is 100ms.
        assert_eq!(next, now + Duration::from_millis(100));
    }

    #[test]
    fn handle_timeout_at_or_after_deadline_re_emits_init_per_pair() {
        let mut a = agent_with_relay_pairs();
        let now = Instant::now();
        let init = handshake_init_bytes();

        a.handle_outbound(init.clone(), now);
        // Drain the original fanout (3 relay pairs).
        let initial_count = std::iter::from_fn(|| a.poll_transmit()).count();
        assert_eq!(initial_count, 3);

        // Advance to the 100ms deadline and pump.
        let later = now + Duration::from_millis(100);
        a.handle_timeout(later);

        let retransmits: Vec<_> = std::iter::from_fn(|| a.poll_transmit()).collect();
        assert_eq!(retransmits.len(), 3);
        for t in &retransmits {
            assert_eq!(t.payload, init);
        }
    }

    #[test]
    fn retransmit_backoff_doubles_per_pair_up_to_cap() {
        let mut a = agent_with_relay_pairs();
        let now = Instant::now();

        a.handle_outbound(handshake_init_bytes(), now);
        while a.poll_transmit().is_some() {}

        // After fire #1 at +100ms, next is +200ms; after #2, +400ms; etc.
        let mut t = now + Duration::from_millis(100);
        let expected_step_ms: [u64; 5] = [200, 400, 800, 1600, 1600];
        for &expected_ms in &expected_step_ms {
            a.handle_timeout(t);
            while a.poll_transmit().is_some() {}
            let next = a.poll_timeout().expect("deadline");
            assert_eq!(next, t + Duration::from_millis(expected_ms));
            t = next;
        }
        // The cap holds at 1600ms (last entry doubles to 1600, not 3200).
    }

    #[test]
    fn inbound_handshake_response_clears_retransmits() {
        let mut a = agent_with_relay_pairs();
        let now = Instant::now();

        a.handle_outbound(handshake_init_bytes(), now);
        while a.poll_transmit().is_some() {}
        assert!(a.poll_timeout().is_some(), "init armed retransmits");

        let _ = a.handle_inbound(&handshake_response_bytes(), (addr(2), addr(4)), now);
        while a.poll_event().is_some() {}

        // No retransmits scheduled after handshake completes.
        assert!(a.poll_timeout().is_none());
    }

    #[test]
    fn handle_timeout_before_deadline_does_not_emit() {
        let mut a = agent_with_relay_pairs();
        let now = Instant::now();

        a.handle_outbound(handshake_init_bytes(), now);
        while a.poll_transmit().is_some() {}

        // Tick at +50ms — earlier than the 100ms initial deadline.
        a.handle_timeout(now + Duration::from_millis(50));
        assert!(a.poll_transmit().is_none());
    }
}
