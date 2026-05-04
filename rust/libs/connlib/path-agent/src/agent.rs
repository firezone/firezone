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
    /// Crate-visible so unit tests in `crate::tests::agent` can prime the
    /// agent into a "primary already selected" state without driving a
    /// full probe round-trip.
    pub(crate) primary: Option<(SocketAddr, SocketAddr)>,

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
    /// When this init was first emitted. Used to enforce the overall
    /// `BOOTSTRAP_WINDOW`: if no response lands within that window the
    /// connection is given up on as `BootstrapFailed`.
    started_at: Instant,
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
pub(crate) const PROBE_INTERVAL: Duration = Duration::from_millis(500);

/// Length of the bootstrap probe window measured from the first observed
/// inbound handshake. Probes flow on every pair until this expires; after
/// that the primary is locked in and ongoing liveness is delegated to
/// WireGuard's persistent keepalive.
pub(crate) const BOOTSTRAP_WINDOW: Duration = Duration::from_secs(10);

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
#[derive(Debug, Clone, PartialEq)]
pub struct Transmit {
    pub local: SocketAddr,
    pub remote: SocketAddr,
    pub payload: Payload,
}

/// Whether the transmit's payload is already-encrypted WG bytes (handshake
/// fanout, retransmits, dedup replays) or a plaintext IP packet that the
/// owning snownet connection must run through `Tunn::encapsulate` first.
/// Path probes are the only `Plaintext` source today. Not `Eq` because
/// `IpPacket` doesn't implement it.
#[derive(Debug, Clone, PartialEq)]
pub enum Payload {
    Ciphertext(Vec<u8>),
    Plaintext(ip_packet::IpPacket),
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
    /// Bootstrap timed out before any handshake response landed. The
    /// owning snownet connection should transition to `Failed` and let
    /// the higher-level cleanup take it from there.
    BootstrapFailed,
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
                self.outbound_init = Some(OutboundInit {
                    bytes,
                    retransmits,
                    started_at: now,
                });
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
        packet: &ip_packet::IpPacket,
        pair: (SocketAddr, SocketAddr),
        now: Instant,
    ) -> ControlFlow<()> {
        let Some(probe) = crate::icmpv6::try_parse(packet) else {
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
                    tracing::trace!(
                        local = %pair.0,
                        remote = %pair.1,
                        rtt_ms = rtt.as_millis() as u64,
                        "Probe reply received",
                    );
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

        // Outbound-init bootstrap deadline (initiator give-up). We always
        // wake exactly at `started_at + BOOTSTRAP_WINDOW` so the failure
        // event fires promptly.
        let init_deadline = self
            .outbound_init
            .as_ref()
            .map(|i| i.started_at + BOOTSTRAP_WINDOW);

        // Pairs whose `next_probe_at` is `None` haven't been seeded yet
        // (no `Instant` was available at `add_pair` time). They get seeded
        // by the first `handle_outbound`, so we don't include them here.
        let next_probe = self.pairs.values().filter_map(|s| s.next_probe_at).min();

        [
            self.events_queued_at,
            next_retransmit,
            next_probe,
            self.bootstrap_until,
            init_deadline,
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
        tracing::info!(
            primary = ?self.primary,
            "Iceless bootstrap window closed; probing settled",
        );
    }

    fn drive_handshake_retransmits(&mut self, now: Instant) {
        // Bootstrap deadline check: if the inbound response never arrived,
        // give up on this connection entirely. Done before retransmitting
        // so we don't emit a final useless burst.
        if let Some(outbound) = self.outbound_init.as_ref()
            && now.saturating_duration_since(outbound.started_at) >= BOOTSTRAP_WINDOW
        {
            tracing::warn!(
                pairs = outbound.retransmits.len(),
                window_secs = BOOTSTRAP_WINDOW.as_secs(),
                "Iceless bootstrap timed out without a handshake response",
            );
            self.outbound_init = None;
            self.queue_event(Event::BootstrapFailed, now);
            return;
        }

        // Disjoint-fields borrow: we mutate `outbound_init` and
        // `pending_transmits` via different paths.
        let pending = &mut self.pending_transmits;
        let Some(outbound) = self.outbound_init.as_mut() else {
            return;
        };
        for ((local, remote), state) in outbound.retransmits.iter_mut() {
            if now >= state.next_fire_at {
                tracing::trace!(%local, %remote, step = state.step, "WG init retransmit");
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
            tracing::info!(
                pairs = self.pairs.len(),
                window_secs = BOOTSTRAP_WINDOW.as_secs(),
                "Iceless bootstrap window opened",
            );
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
        let new_rtt = self
            .pairs
            .get(&new)
            .and_then(|s| s.smoothed_rtt)
            .unwrap_or_default();
        match self.primary {
            None => {
                self.primary = Some(new);
                tracing::info!(
                    local = %new.0,
                    remote = %new.1,
                    rtt_ms = new_rtt.as_millis() as u64,
                    "Iceless primary selected",
                );
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
                tracing::info!(
                    from_local = %old.0,
                    from_remote = %old.1,
                    to_local = %new.0,
                    to_remote = %new.1,
                    rtt_ms = new_rtt.as_millis() as u64,
                    "Iceless primary changed",
                );
                self.queue_event(Event::PrimaryChanged { from: old, to: new }, now);
            }
            Some(_) => {}
        }
    }
}
