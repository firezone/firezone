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

    /// Responder-side dedup cache: the most recent
    /// `(init_bytes → response_bytes)` pair we processed, plus the path
    /// we sent the response on. When subsequent inbound inits arrive
    /// with byte-identical contents within `RESPONDER_DEDUP_TTL`, we
    /// replay the cached response on the receiving path without
    /// involving boringtun.
    responder_dedup: Option<ResponderDedup>,

    /// Initiator-side dedup: bytes of the most recent inbound
    /// `HandshakeResponse` we forwarded to boringtun. Subsequent inbound
    /// responses with byte-exact match are dropped — feeding them to
    /// boringtun a second time would re-process the response and bump
    /// the session index. Reset whenever we send a fresh outbound init.
    forwarded_response: Option<Vec<u8>>,

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
    /// Deadline by which the bootstrap probe window closes. After this
    /// instant, probes stop on every pair (primary included); WireGuard's
    /// persistent keepalive takes over liveness on the locked-in primary.
    /// Set on the first inbound handshake; `None` until then, and again
    /// `None` after `maybe_settle` runs (so we don't re-fire forever).
    bootstrap_until: Option<Instant>,
    /// Sticky flag: `true` once the bootstrap deadline has elapsed and we've
    /// settled. Prevents re-opening the probe window on later events
    /// (e.g. a peer rekey driving `seed_probe_schedule` again).
    bootstrap_settled: bool,
}

struct PairState {
    /// Kinds of the local + remote candidate, captured at insertion time.
    kinds: (crate::CandidateKind, crate::CandidateKind),
    /// Last observed handshake on this pair.
    last_handshake_at: Option<Instant>,
    /// Smoothed RTT, populated from probe round-trips.
    smoothed_rtt: Option<Duration>,
    /// The most recent probe we sent on this pair and are waiting on.
    /// Cleared when the matching reply arrives. Replies whose seq doesn't
    /// match this slot are ignored as stale.
    inflight_probe: Option<InflightProbe>,
    /// When the next outbound probe is due. `None` means "send as soon as
    /// the timer next fires" (used for the very first probe on a new pair).
    next_probe_at: Option<Instant>,
    /// Per-pair monotonic seq counter for the next outbound probe.
    next_probe_seq: u16,
}

#[derive(Debug, Clone, Copy)]
struct InflightProbe {
    seq: u16,
    sent_at: Instant,
}

/// State associated with the currently-outbound `HandshakeInit` bytes
/// that we're retransmitting per pair until the matching response arrives.
struct OutboundInit {
    bytes: Vec<u8>,
    /// Per-pair retransmit deadlines + backoff step.
    retransmits: BTreeMap<(SocketAddr, SocketAddr), PairRetransmit>,
}

/// Responder-side dedup cache for the most recent inbound
/// `HandshakeInit`/`HandshakeResponse` pair we processed. The cached
/// response is replayed on whichever path a duplicate init arrives
/// from (not necessarily the original recv path).
struct ResponderDedup {
    init_bytes: Vec<u8>,
    response_bytes: Vec<u8>,
    cached_at: Instant,
}

/// How long a cached `(init, response)` pair is considered fresh enough
/// to replay. Long enough to cover the initiator's full retransmit burst
/// (capped at 1.6s per pair, ~10s of total ladder), short enough that any
/// genuine re-handshake produces a fresh entry promptly.
const RESPONDER_DEDUP_TTL: Duration = Duration::from_secs(10);

/// How often to send probes on each pair while we're still measuring.
/// Tight enough to gather several RTT samples within the 10s bootstrap,
/// loose enough to keep bandwidth use modest.
const PROBE_INTERVAL: Duration = Duration::from_millis(500);

/// Length of the bootstrap probe window measured from the first observed
/// inbound handshake. Probes flow on every pair until this expires; after
/// that the primary is locked in and ongoing liveness is delegated to
/// WireGuard's persistent keepalive.
const BOOTSTRAP_WINDOW: Duration = Duration::from_secs(10);

/// Echo `id` baked into every probe. We discriminate replies by `(pair, seq)`
/// rather than by `id`, so a fixed value is fine.
const PROBE_ID: u16 = 0;

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
    pub payload: Payload,
}

/// Whether the transmit's payload is already-encrypted WG bytes (handshake
/// fanout, retransmits, dedup replays) or a plaintext IP packet that the
/// owning snownet connection must run through `Tunn::encapsulate` first.
/// Path probes are the only `Plaintext` source today.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Payload {
    Ciphertext(Vec<u8>),
    Plaintext(Vec<u8>),
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
            responder_dedup: None,
            forwarded_response: None,
            outbound_init: None,
            pending_transmits: VecDeque::new(),
            events: VecDeque::new(),
            events_queued_at: None,
            bootstrap_until: None,
            bootstrap_settled: false,
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
                inflight_probe: None,
                // `None` means "send the very first probe as soon as
                // `handle_timeout` next runs" — we don't have an `Instant`
                // here to compute a deadline against.
                next_probe_at: None,
                next_probe_seq: 0,
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
                //
                // Fresh init means a fresh response is incoming — clear the
                // initiator-side response-dedup so it doesn't reject
                // legitimate new responses as duplicates of the previous
                // session's.
                self.forwarded_response = None;

                let pairs: Vec<_> = self.relay_pairs().collect();
                let mut retransmits = BTreeMap::new();
                for &(local, remote) in &pairs {
                    self.pending_transmits.push_back(Transmit {
                        local,
                        remote,
                        payload: Payload::Ciphertext(bytes.clone()),
                    });
                    retransmits.insert((local, remote), PairRetransmit::new(now));
                }
                self.outbound_init = Some(OutboundInit { bytes, retransmits });
            }
            Ok(Packet::HandshakeResponse(_)) => {
                // Pair this response with the most recent inbound init we
                // forwarded; send back on the same path AND cache the
                // (init bytes, response bytes, path) tuple so duplicate
                // inbound inits within `RESPONDER_DEDUP_TTL` get the same
                // response replayed without re-driving boringtun.
                if let (Some(init_bytes), Some(path)) = (
                    self.last_forwarded_init.take(),
                    self.last_forwarded_init_path.take(),
                ) {
                    self.pending_transmits.push_back(Transmit {
                        local: path.0,
                        remote: path.1,
                        payload: Payload::Ciphertext(bytes.clone()),
                    });
                    // The original `path` is consumed as the routing target
                    // for *this* response. Future duplicate inbound inits
                    // replay on whichever path they arrive on, so the cache
                    // entry doesn't need to remember the original.
                    self.responder_dedup = Some(ResponderDedup {
                        init_bytes,
                        response_bytes: bytes,
                        cached_at: now,
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
                        payload: Payload::Ciphertext(bytes),
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

        // Receiving a handshake (in either direction) is our cue that the
        // network works on at least one pair: time to start probing for a
        // better one. Idempotent — only seeds previously-`None` deadlines.
        self.seed_probe_schedule(now);

        match parsed {
            Packet::HandshakeInit(_) => {
                // Bytes-exact match against the most recently cached
                // (init, response) pair (within TTL) → replay the cached
                // response on the path this init came from. This avoids
                // re-driving boringtun with a duplicate init that
                // anti-replay would reject.
                if let Some(d) = self.responder_dedup.as_ref()
                    && now.duration_since(d.cached_at) < RESPONDER_DEDUP_TTL
                    && d.init_bytes == bytes
                {
                    self.pending_transmits.push_back(Transmit {
                        local: path.0,
                        remote: path.1,
                        payload: Payload::Ciphertext(d.response_bytes.clone()),
                    });
                    return ControlFlow::Break(());
                }

                // Genuinely new init bytes: stash for outbound-response
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
                // Initiator-side dedup: drop byte-exact duplicates of the
                // response we already forwarded. Feeding the same response
                // to boringtun again would advance the session index and
                // potentially desynchronise state.
                if self.forwarded_response.as_deref() == Some(bytes) {
                    return ControlFlow::Break(());
                }

                // First (or genuinely fresh) response: clear the per-pair
                // retransmit ladder, remember the bytes for future dedup,
                // and ask the caller to forward to boringtun.
                self.outbound_init = None;
                self.forwarded_response = Some(bytes.to_vec());
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

    /// Hand off a decrypted inner-IP packet that came out of `Tunn::decapsulate`.
    /// Returns `Break(())` if the packet was a path probe and was absorbed
    /// (caller drops it). Returns `Continue(())` for ordinary user traffic
    /// that the caller should forward to the tun device.
    ///
    /// `pair` is the `(local, remote)` `(SocketAddr, SocketAddr)` the
    /// encrypted bytes arrived on, used to attribute the probe to the right
    /// pair for RTT bookkeeping and reply routing.
    pub fn handle_inbound_decrypted(
        &mut self,
        bytes: &[u8],
        pair: (SocketAddr, SocketAddr),
        now: Instant,
    ) -> ControlFlow<()> {
        let Some(probe) = crate::icmpv6::try_parse(bytes) else {
            return ControlFlow::Continue(());
        };

        match probe.kind {
            crate::icmpv6::Echo::Request => {
                // Mirror back on the same pair. snownet encrypts + sends.
                self.pending_transmits.push_back(Transmit {
                    local: pair.0,
                    remote: pair.1,
                    payload: Payload::Plaintext(crate::icmpv6::build_echo_reply(
                        probe.id, probe.seq,
                    )),
                });
            }
            crate::icmpv6::Echo::Reply => {
                if let Some(state) = self.pairs.get_mut(&pair)
                    && let Some(inflight) = state.inflight_probe
                    && inflight.seq == probe.seq
                {
                    let rtt = now.saturating_duration_since(inflight.sent_at);
                    state.inflight_probe = None;
                    state.smoothed_rtt = Some(match state.smoothed_rtt {
                        None => rtt,
                        // Light EMA — the proper Karn/Partridge or Jacobson smoothing
                        // can land later; for path selection over a 10s window the
                        // signal here is fine.
                        Some(prev) => (prev + rtt) / 2,
                    });
                    self.select_primary(now);
                }
            }
        }
        ControlFlow::Break(())
    }

    pub fn poll_timeout(&self) -> Option<Instant> {
        let next_retransmit = self
            .outbound_init
            .as_ref()
            .and_then(|i| i.retransmits.values().map(|r| r.next_fire_at).min());

        // Pairs whose `next_probe_at` is `None` haven't been seeded yet
        // (no `Instant` was available at `add_pair` time). They get seeded
        // by the first `handle_outbound`, so we don't include them here.
        let next_probe = self.pairs.values().filter_map(|s| s.next_probe_at).min();

        [
            self.events_queued_at,
            next_retransmit,
            next_probe,
            self.bootstrap_until,
        ]
        .into_iter()
        .flatten()
        .min()
    }

    pub fn handle_timeout(&mut self, now: Instant) {
        self.drive_handshake_retransmits(now);
        self.drive_probes(now);
        self.maybe_settle(now);
    }

    /// At the bootstrap deadline, clear per-pair probe schedules so
    /// `poll_timeout` stops surfacing stale probe deadlines. The locked-in
    /// `primary` is unchanged; ongoing liveness on it is WireGuard's job
    /// (persistent keepalive).
    fn maybe_settle(&mut self, now: Instant) {
        let Some(deadline) = self.bootstrap_until else {
            return;
        };
        if now < deadline {
            return;
        }
        for state in self.pairs.values_mut() {
            state.next_probe_at = None;
            state.inflight_probe = None;
        }
        self.bootstrap_until = None;
        self.bootstrap_settled = true;
    }

    fn drive_handshake_retransmits(&mut self, now: Instant) {
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
                    payload: Payload::Ciphertext(outbound.bytes.clone()),
                });
                state.advance(now);
            }
        }
    }

    fn seed_probe_schedule(&mut self, now: Instant) {
        // Once we've settled, leave the schedule alone — a peer's later
        // rekey shouldn't re-open the probe window.
        if self.bootstrap_settled {
            return;
        }
        // First-call wins: subsequent calls don't reset the deadline.
        if self.bootstrap_until.is_none() {
            self.bootstrap_until = Some(now + BOOTSTRAP_WINDOW);
        }
        for state in self.pairs.values_mut() {
            if state.next_probe_at.is_none() {
                state.next_probe_at = Some(now);
            }
        }
    }

    fn drive_probes(&mut self, now: Instant) {
        // Bootstrap window closed → stop probing entirely. WireGuard's
        // persistent keepalive on the locked-in primary handles liveness.
        if self.bootstrap_until.is_some_and(|t| now >= t) {
            return;
        }

        let pending = &mut self.pending_transmits;
        for ((local, remote), state) in self.pairs.iter_mut() {
            // Pairs whose `next_probe_at` is `None` haven't been seeded
            // yet — `seed_probe_schedule` runs on the first inbound
            // handshake. Skip them here.
            let Some(deadline) = state.next_probe_at else {
                continue;
            };
            if now < deadline {
                continue;
            }

            let seq = state.next_probe_seq;
            state.next_probe_seq = state.next_probe_seq.wrapping_add(1);
            state.inflight_probe = Some(InflightProbe { seq, sent_at: now });
            state.next_probe_at = Some(now + PROBE_INTERVAL);

            pending.push_back(Transmit {
                local: *local,
                remote: *remote,
                payload: Payload::Plaintext(crate::icmpv6::build_echo_request(PROBE_ID, seq)),
            });
        }
    }

    /// Pick the best pair (lowest tier; ties broken by lowest smoothed RTT)
    /// among pairs with at least one probe round-trip. Emits
    /// `PrimarySelected` / `PrimaryChanged` if the result differs from the
    /// current `primary`.
    fn select_primary(&mut self, now: Instant) {
        let best = self
            .pairs
            .iter()
            .filter(|(_, s)| s.smoothed_rtt.is_some())
            .min_by(|(_, a), (_, b)| {
                // Pair tier = worse of the two endpoints' kinds.
                let a_tier = a.kinds.0.max(a.kinds.1);
                let b_tier = b.kinds.0.max(b.kinds.1);
                a_tier
                    .cmp(&b_tier)
                    .then_with(|| a.smoothed_rtt.cmp(&b.smoothed_rtt))
            })
            .map(|(k, _)| *k);

        let Some(new) = best else { return };
        match self.primary {
            None => {
                self.primary = Some(new);
                self.queue_event(
                    Event::PrimarySelected {
                        local: new.0,
                        remote: new.1,
                    },
                    now,
                );
            }
            Some(old) if old != new => {
                self.primary = Some(new);
                self.queue_event(Event::PrimaryChanged { from: old, to: new }, now);
            }
            Some(_) => {}
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
            payload: Payload::Ciphertext(vec![1]),
        });
        a.pending_transmits.push_back(Transmit {
            local: addr(3),
            remote: addr(4),
            payload: Payload::Ciphertext(vec![2]),
        });

        assert_eq!(
            a.poll_transmit().unwrap().payload,
            Payload::Ciphertext(vec![1])
        );
        assert_eq!(
            a.poll_transmit().unwrap().payload,
            Payload::Ciphertext(vec![2])
        );
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
        let payload = Payload::Ciphertext(handshake_init_bytes());
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
        assert_eq!(t.payload, Payload::Ciphertext(handshake_response_bytes()));
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
            assert_eq!(t.payload, Payload::Ciphertext(init.clone()));
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
        let init_deadline = a.poll_timeout().expect("init armed retransmits");

        let _ = a.handle_inbound(&handshake_response_bytes(), (addr(2), addr(4)), now);
        while a.poll_event().is_some() {}

        // After handshake completes, the retransmit ladder is gone; the
        // remaining `poll_timeout` value (if any) comes from probe scheduling
        // seeded by the inbound handshake, not from the cleared retransmit.
        let post_deadline = a.poll_timeout();
        assert!(
            post_deadline.is_none_or(|t| t != init_deadline),
            "retransmit deadline should have cleared",
        );
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

    /// Drive the responder side through a full inbound init → outbound
    /// response cycle so the dedup cache is populated.
    fn populate_responder_cache(
        a: &mut PathAgent,
        recv_path: (SocketAddr, SocketAddr),
        now: Instant,
    ) {
        let _ = a.handle_inbound(&handshake_init_bytes(), recv_path, now);
        // Drain ForwardInbound — the test simulates boringtun acting on it.
        while a.poll_event().is_some() {}
        a.handle_outbound(handshake_response_bytes(), now);
        // Drain the response transmit on the recv path.
        while a.poll_transmit().is_some() {}
    }

    #[test]
    fn duplicate_inbound_init_replays_cached_response_on_new_path() {
        let mut a = agent_with_relay_pairs();
        let now = Instant::now();

        populate_responder_cache(&mut a, (addr(2), addr(4)), now);

        // Same init bytes, different recv path (relay×relay vs. host×host).
        let new_path = (addr(1), addr(3));
        let handled = a.handle_inbound(&handshake_init_bytes(), new_path, now);
        assert!(matches!(handled, ControlFlow::Break(())));

        // Cached response replayed on the new path; no ForwardInbound event
        // (we did not re-drive boringtun).
        let t = a.poll_transmit().expect("replay transmit");
        assert_eq!(t.local, new_path.0);
        assert_eq!(t.remote, new_path.1);
        assert_eq!(t.payload, Payload::Ciphertext(handshake_response_bytes()));
        assert!(a.poll_event().is_none());
    }

    #[test]
    fn duplicate_inbound_init_after_ttl_falls_back_to_forward() {
        let mut a = agent_with_relay_pairs();
        let now = Instant::now();

        populate_responder_cache(&mut a, (addr(2), addr(4)), now);

        // Past the 10s TTL.
        let later = now + Duration::from_secs(11);
        let handled = a.handle_inbound(&handshake_init_bytes(), (addr(1), addr(3)), later);
        assert!(matches!(handled, ControlFlow::Break(())));

        // Falls through to the normal forward path: emits a ForwardInbound
        // event and does NOT replay the cached response.
        match a.poll_event() {
            Some(Event::ForwardInbound { bytes }) => assert_eq!(bytes, handshake_init_bytes()),
            other => panic!("expected ForwardInbound, got {other:?}"),
        }
        assert!(a.poll_transmit().is_none());
    }

    #[test]
    fn duplicate_inbound_response_is_dropped_after_first_forward() {
        let mut a = agent_with_relay_pairs();
        let now = Instant::now();

        // First response: forwarded to boringtun.
        let handled = a.handle_inbound(&handshake_response_bytes(), (addr(2), addr(4)), now);
        assert!(matches!(handled, ControlFlow::Break(())));
        match a.poll_event() {
            Some(Event::ForwardInbound { bytes }) => assert_eq!(bytes, handshake_response_bytes()),
            other => panic!("expected ForwardInbound, got {other:?}"),
        }

        // Same bytes on a different path: dropped, no event.
        let handled = a.handle_inbound(&handshake_response_bytes(), (addr(1), addr(3)), now);
        assert!(matches!(handled, ControlFlow::Break(())));
        assert!(a.poll_event().is_none());
        assert!(a.poll_transmit().is_none());
    }

    #[test]
    fn fresh_outbound_init_resets_initiator_response_dedup() {
        let mut a = agent_with_relay_pairs();
        let now = Instant::now();

        // Forward a response, populate dedup.
        let _ = a.handle_inbound(&handshake_response_bytes(), (addr(2), addr(4)), now);
        while a.poll_event().is_some() {}

        // boringtun emits a fresh init (re-key) — should clear dedup.
        a.handle_outbound(handshake_init_bytes(), now);
        while a.poll_transmit().is_some() {}

        // The same response bytes now forward again (new session is
        // expecting a fresh response).
        let handled = a.handle_inbound(&handshake_response_bytes(), (addr(2), addr(4)), now);
        assert!(matches!(handled, ControlFlow::Break(())));
        match a.poll_event() {
            Some(Event::ForwardInbound { .. }) => {}
            other => panic!("expected ForwardInbound after re-init, got {other:?}"),
        }
    }

    /// Match an outbound `Transmit` against an `(local, remote)` pair, returning
    /// the parsed probe payload. Helper for probe-loop tests.
    fn extract_probe_for(
        transmits: &[Transmit],
        pair: (SocketAddr, SocketAddr),
    ) -> crate::icmpv6::Probe {
        let t = transmits
            .iter()
            .find(|t| (t.local, t.remote) == pair)
            .unwrap_or_else(|| panic!("no transmit for {pair:?}"));
        let Payload::Plaintext(ref bytes) = t.payload else {
            panic!("expected Plaintext probe, got {:?}", t.payload);
        };
        crate::icmpv6::try_parse(bytes).expect("parses as probe")
    }

    #[test]
    fn inbound_handshake_seeds_probe_schedule_for_all_pairs() {
        let mut a = agent_with_relay_pairs();
        let now = Instant::now();

        let _ = a.handle_inbound(&handshake_response_bytes(), (addr(2), addr(4)), now);
        while a.poll_event().is_some() {}
        while a.poll_transmit().is_some() {}

        // After seeding, the next deadline is the immediate probe (now).
        assert_eq!(a.poll_timeout(), Some(now));
    }

    #[test]
    fn handle_timeout_emits_one_probe_per_pair() {
        let mut a = agent_with_relay_pairs();
        let now = Instant::now();

        let _ = a.handle_inbound(&handshake_response_bytes(), (addr(2), addr(4)), now);
        while a.poll_event().is_some() {}
        while a.poll_transmit().is_some() {}

        a.handle_timeout(now);
        let transmits: Vec<_> = std::iter::from_fn(|| a.poll_transmit()).collect();

        // 4 pairs (2 locals × 2 remotes), each gets one probe.
        assert_eq!(transmits.len(), 4);
        for t in &transmits {
            assert!(matches!(t.payload, Payload::Plaintext(_)));
        }
    }

    #[test]
    fn probe_seq_advances_per_pair_per_fire() {
        let mut a = agent_with_relay_pairs();
        let now = Instant::now();

        let _ = a.handle_inbound(&handshake_response_bytes(), (addr(2), addr(4)), now);
        while a.poll_event().is_some() {}
        while a.poll_transmit().is_some() {}

        // Fire 1.
        a.handle_timeout(now);
        let first: Vec<_> = std::iter::from_fn(|| a.poll_transmit()).collect();
        let first_seq = extract_probe_for(&first, (addr(1), addr(3))).seq;

        // Fire 2 — advance past the per-pair PROBE_INTERVAL.
        a.handle_timeout(now + PROBE_INTERVAL);
        let second: Vec<_> = std::iter::from_fn(|| a.poll_transmit()).collect();
        let second_seq = extract_probe_for(&second, (addr(1), addr(3))).seq;

        assert_eq!(second_seq, first_seq.wrapping_add(1));
    }

    #[test]
    fn inbound_echo_reply_updates_smoothed_rtt_and_selects_primary() {
        let mut a = agent_with_relay_pairs();
        let now = Instant::now();

        let _ = a.handle_inbound(&handshake_response_bytes(), (addr(2), addr(4)), now);
        while a.poll_event().is_some() {}
        while a.poll_transmit().is_some() {}

        // Send a probe so we have an inflight slot to match against.
        a.handle_timeout(now);
        let outbound: Vec<_> = std::iter::from_fn(|| a.poll_transmit()).collect();
        let probe_on_host_pair = extract_probe_for(&outbound, (addr(1), addr(3)));

        // Reply arrives 50ms later on the same pair.
        let reply = crate::icmpv6::build_echo_reply(probe_on_host_pair.id, probe_on_host_pair.seq);
        let later = now + Duration::from_millis(50);
        let handled = a.handle_inbound_decrypted(&reply, (addr(1), addr(3)), later);
        assert!(matches!(handled, ControlFlow::Break(())));

        // host×host pair has best tier — picked as primary on first RTT.
        assert_eq!(a.primary(), Some((addr(1), addr(3))));
        match a.poll_event() {
            Some(Event::PrimarySelected { local, remote }) => {
                assert_eq!((local, remote), (addr(1), addr(3)));
            }
            other => panic!("expected PrimarySelected, got {other:?}"),
        }
    }

    #[test]
    fn inbound_echo_request_queues_reply_on_same_pair() {
        let mut a = agent_with_relay_pairs();
        let now = Instant::now();

        let request = crate::icmpv6::build_echo_request(0, 42);
        let handled = a.handle_inbound_decrypted(&request, (addr(2), addr(4)), now);
        assert!(matches!(handled, ControlFlow::Break(())));

        let reply_transmit = a.poll_transmit().expect("queued reply");
        assert_eq!(reply_transmit.local, addr(2));
        assert_eq!(reply_transmit.remote, addr(4));
        let Payload::Plaintext(bytes) = reply_transmit.payload else {
            panic!("expected Plaintext reply");
        };
        let probe = crate::icmpv6::try_parse(&bytes).expect("parses");
        assert_eq!(probe.kind, crate::icmpv6::Echo::Reply);
        assert_eq!(probe.seq, 42);
    }

    #[test]
    fn inbound_decrypted_non_probe_returns_continue() {
        let mut a = agent_with_relay_pairs();
        let bytes = vec![0xff; 64];
        let handled = a.handle_inbound_decrypted(&bytes, (addr(2), addr(4)), Instant::now());
        assert!(matches!(handled, ControlFlow::Continue(())));
        assert!(a.poll_transmit().is_none());
    }

    #[test]
    fn primary_changes_when_lower_tier_pair_becomes_alive() {
        let mut a = agent_with_relay_pairs();
        let now = Instant::now();

        let _ = a.handle_inbound(&handshake_response_bytes(), (addr(2), addr(4)), now);
        while a.poll_event().is_some() {}
        while a.poll_transmit().is_some() {}

        // Fire probes to populate inflight slots.
        a.handle_timeout(now);
        let outbound: Vec<_> = std::iter::from_fn(|| a.poll_transmit()).collect();

        // Reply on relay pair first (relay×relay has worst tier).
        let relay_probe = extract_probe_for(&outbound, (addr(2), addr(4)));
        let _ = a.handle_inbound_decrypted(
            &crate::icmpv6::build_echo_reply(relay_probe.id, relay_probe.seq),
            (addr(2), addr(4)),
            now + Duration::from_millis(100),
        );
        assert_eq!(a.primary(), Some((addr(2), addr(4))));

        // Now reply on host×host pair (best tier) — should switch.
        let host_probe = extract_probe_for(&outbound, (addr(1), addr(3)));
        while a.poll_event().is_some() {}
        let _ = a.handle_inbound_decrypted(
            &crate::icmpv6::build_echo_reply(host_probe.id, host_probe.seq),
            (addr(1), addr(3)),
            now + Duration::from_millis(150),
        );
        assert_eq!(a.primary(), Some((addr(1), addr(3))));
        match a.poll_event() {
            Some(Event::PrimaryChanged { from, to }) => {
                assert_eq!(from, (addr(2), addr(4)));
                assert_eq!(to, (addr(1), addr(3)));
            }
            other => panic!("expected PrimaryChanged, got {other:?}"),
        }
    }

    #[test]
    fn stale_echo_reply_is_ignored() {
        let mut a = agent_with_relay_pairs();
        let now = Instant::now();

        let _ = a.handle_inbound(&handshake_response_bytes(), (addr(2), addr(4)), now);
        while a.poll_event().is_some() {}
        while a.poll_transmit().is_some() {}

        a.handle_timeout(now);
        while a.poll_transmit().is_some() {}

        // Reply with a seq that doesn't match the inflight probe (we've only
        // sent seq=0 so far; pretend a much earlier seq replies late).
        let stale_reply = crate::icmpv6::build_echo_reply(0, 0xdead);
        let _ = a.handle_inbound_decrypted(&stale_reply, (addr(1), addr(3)), now);

        // No primary was set since no matching inflight probe was cleared.
        assert_eq!(a.primary(), None);
    }

    #[test]
    fn drive_probes_stops_emitting_after_bootstrap_window() {
        let mut a = agent_with_relay_pairs();
        let now = Instant::now();

        let _ = a.handle_inbound(&handshake_response_bytes(), (addr(2), addr(4)), now);
        while a.poll_event().is_some() {}
        while a.poll_transmit().is_some() {}

        // Inside window — probes fire.
        a.handle_timeout(now);
        let inside: Vec<_> = std::iter::from_fn(|| a.poll_transmit()).collect();
        assert!(!inside.is_empty(), "expected probes inside window");

        // After the window, drive_probes is a no-op even on previously-due pairs.
        a.handle_timeout(now + BOOTSTRAP_WINDOW);
        let after: Vec<_> = std::iter::from_fn(|| a.poll_transmit()).collect();
        assert!(
            after.is_empty(),
            "expected no probes after window: {after:?}"
        );
    }

    #[test]
    fn settle_clears_next_probe_at_and_poll_timeout() {
        let mut a = agent_with_relay_pairs();
        let now = Instant::now();

        let _ = a.handle_inbound(&handshake_response_bytes(), (addr(2), addr(4)), now);
        while a.poll_event().is_some() {}

        // Pump bootstrap-due work.
        a.handle_timeout(now);
        while a.poll_transmit().is_some() {}

        // Settle.
        a.handle_timeout(now + BOOTSTRAP_WINDOW);

        // No probe deadlines, no bootstrap deadline → no further wake-ups
        // unless other state (events, retransmits) demands one.
        assert_eq!(a.poll_timeout(), None);
    }

    #[test]
    fn settle_is_sticky_across_later_handshakes() {
        let mut a = agent_with_relay_pairs();
        let now = Instant::now();

        let _ = a.handle_inbound(&handshake_response_bytes(), (addr(2), addr(4)), now);
        while a.poll_event().is_some() {}
        while a.poll_transmit().is_some() {}

        a.handle_timeout(now + BOOTSTRAP_WINDOW); // settle

        // A later inbound handshake (e.g. peer rekey) must not re-open the
        // probe window.
        let _ = a.handle_inbound(
            &handshake_response_bytes(),
            (addr(2), addr(4)),
            now + BOOTSTRAP_WINDOW + Duration::from_secs(60),
        );
        while a.poll_event().is_some() {}

        a.handle_timeout(now + BOOTSTRAP_WINDOW + Duration::from_secs(60));
        let post: Vec<_> = std::iter::from_fn(|| a.poll_transmit()).collect();
        assert!(post.is_empty(), "expected no probes post-settle: {post:?}");
    }

    #[test]
    fn different_inbound_init_bytes_skip_dedup_cache() {
        let mut a = agent_with_relay_pairs();
        let now = Instant::now();

        populate_responder_cache(&mut a, (addr(2), addr(4)), now);

        // Bytes differ from the cached entry by one byte (e.g. fresh TAI64N).
        let mut different_init = handshake_init_bytes();
        different_init[100] = 0x42;

        let handled = a.handle_inbound(&different_init, (addr(2), addr(4)), now);
        assert!(matches!(handled, ControlFlow::Break(())));

        // No cache replay; falls through to forward-to-boringtun.
        match a.poll_event() {
            Some(Event::ForwardInbound { bytes }) => assert_eq!(bytes, different_init),
            other => panic!("expected ForwardInbound, got {other:?}"),
        }
        assert!(a.poll_transmit().is_none());
    }
}
