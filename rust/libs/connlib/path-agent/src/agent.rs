use std::collections::{BTreeMap, VecDeque};
use std::net::SocketAddr;
use std::ops::ControlFlow;
use std::time::{Duration, Instant};

use boringtun::noise::{Packet, Tunn, TunnResult};

use crate::candidate::Candidate;

/// Path-selection state machine for ICE-less snownet connections.
///
/// snownet feeds every WG-encapsulated byte slice through
/// [`PathAgent::handle_outbound`] and every inbound slice through
/// [`PathAgent::handle_inbound`]. Decisions (fanout, dedup, replay,
/// probing) flow back out via [`PathAgent::poll_transmit`] /
/// [`PathAgent::poll_event`]. All pair identifiers are
/// `(local, remote)` `SocketAddr` tuples.
///
/// # Lifecycle
///
/// 1. **Bootstrap.** First outbound `HandshakeInit` fans out across every
///    relay-involved pair with a per-pair retransmit ladder. The first
///    inbound handshake (init or response) seeds [`PROBE_INTERVAL`]-
///    cadence probing on every pair and adopts the receive path as the
///    bootstrap primary so user data flows immediately.
/// 2. **Probing.** ICMPv6 echo round-trips populate per-pair smoothed
///    RTTs; the primary is selected by (worse-of-pair tier, local-relay
///    first, smoothed RTT) — direct beats relayed, our relay beats the
///    peer's.
/// 3. **Settle.** At [`BOOTSTRAP_WINDOW`], probing winds down to
///    [`PROBE_INTERVAL_LIVE`] on the primary only — enough to keep its
///    NAT binding alive without blanket-probing every pair.
/// 4. **Failure.** If no `HandshakeResponse` arrives inside
///    [`BOOTSTRAP_WINDOW`], `Event::BootstrapFailed` fires.
pub struct PathAgent {
    locals: Vec<Candidate>,
    remotes: Vec<Candidate>,
    pairs: BTreeMap<(SocketAddr, SocketAddr), PairState>,
    primary: Option<(SocketAddr, SocketAddr)>,

    /// `true` once we've fanned out the bootstrap `HandshakeInit`.
    /// Subsequent inits from boringtun are re-keys on a working session
    /// and ride `primary` instead of re-fanning out.
    established: bool,

    /// Most recently forwarded inbound `HandshakeInit` and the path it
    /// arrived on. The next outbound `HandshakeResponse` is paired
    /// against these and the bytes go into [`ResponderDedup`].
    last_forwarded_init: Option<Vec<u8>>,
    last_forwarded_init_path: Option<(SocketAddr, SocketAddr)>,

    /// Responder-side dedup. Bytes-exact replay of a cached response
    /// against duplicate inits avoids re-driving boringtun (whose
    /// anti-replay would reject them anyway).
    responder_dedup: Option<ResponderDedup>,

    /// Initiator-side dedup: bytes of the most recently forwarded
    /// `HandshakeResponse`. Re-feeding the same response to boringtun
    /// would advance the session index and desynchronise state. Reset
    /// when boringtun emits a fresh init.
    forwarded_response: Option<Vec<u8>>,

    /// In-flight outbound `HandshakeInit` and its per-pair retransmit
    /// ladder. Cleared on the first matching response, or replaced when
    /// boringtun emits a fresh init.
    outbound_init: Option<OutboundInit>,

    pending_transmits: VecDeque<Transmit>,
    events: VecDeque<Event>,
    /// Pushed-at timestamp of the oldest queued event. Surfaced through
    /// `poll_timeout` so the next `handle_timeout` tick drains promptly.
    events_queued_at: Option<Instant>,
    /// Bootstrap-window deadline. `Some` between the first inbound
    /// handshake and `maybe_settle`; cleared after settling so we don't
    /// re-fire forever.
    bootstrap_until: Option<Instant>,
    /// Sticky: `true` once the bootstrap deadline has elapsed. Prevents
    /// later events from re-opening the window.
    bootstrap_settled: bool,
}

struct PairState {
    /// `(local, remote)` candidate kinds, captured at insertion.
    kinds: (crate::CandidateKind, crate::CandidateKind),
    /// Smoothed RTT from probe round-trips.
    smoothed_rtt: Option<Duration>,
    /// In-flight probe we're awaiting a reply for. Replies whose seq
    /// doesn't match are ignored as stale.
    inflight_probe: Option<InflightProbe>,
    /// Next probe deadline. `None` until [`PathAgent::seed_probe_schedule`]
    /// runs (on the first inbound handshake).
    next_probe_at: Option<Instant>,
    /// Monotonic per-pair seq counter for the next outbound probe.
    next_probe_seq: u16,
}

#[derive(Debug, Clone, Copy)]
struct InflightProbe {
    seq: u16,
    sent_at: Instant,
}

struct OutboundInit {
    bytes: Vec<u8>,
    retransmits: BTreeMap<(SocketAddr, SocketAddr), PairRetransmit>,
    /// First emission timestamp; used for the `BOOTSTRAP_WINDOW` give-up.
    started_at: Instant,
}

struct ResponderDedup {
    init_bytes: Vec<u8>,
    response_bytes: Vec<u8>,
    cached_at: Instant,
}

/// Freshness window for the responder-side `(init, response)` cache.
/// Comfortably covers the initiator's full retransmit ladder.
const RESPONDER_DEDUP_TTL: Duration = Duration::from_secs(10);

/// Probe cadence inside the bootstrap window.
pub const PROBE_INTERVAL: Duration = Duration::from_millis(500);

/// Treat an in-flight probe as lost once its reply fails to arrive
/// within this window. Without it, paths whose RTT exceeds
/// [`PROBE_INTERVAL`] would have every reply land on a stale seq slot.
pub const PROBE_TIMEOUT: Duration = Duration::from_secs(2);

/// Steady-state probe cadence on the primary, post-settle. Sized to
/// match WireGuard's persistent-keepalive default so the on-wire cost
/// is comparable.
pub const PROBE_INTERVAL_LIVE: Duration = Duration::from_secs(25);

/// Length of the bootstrap window measured from the first observed
/// inbound handshake.
pub const BOOTSTRAP_WINDOW: Duration = Duration::from_secs(10);

/// Echo `id` baked into every probe. We discriminate replies by
/// `(pair, seq)`, so a fixed value is fine.
const PROBE_ID: u16 = 0;

struct PairRetransmit {
    next_fire_at: Instant,
    /// Step into [`PairRetransmit::LADDER_MS`], saturating at the last
    /// entry.
    step: usize,
}

impl PairRetransmit {
    /// Per-pair retransmit cadence for the bootstrap WG `HandshakeInit`
    /// fanout. The 50 ms / 50 ms / 50 ms head covers the race where our
    /// init lands on a relay before that relay has the *peer's*
    /// channel-bind registered (the first init gets dropped silently;
    /// a quick burst catches the channel as soon as it appears). Past
    /// that we ease off via exponential doubling capped at 1.6 s.
    const LADDER_MS: &'static [u64] = &[50, 50, 50, 100, 200, 400, 800, 1600];

    fn new(now: Instant) -> Self {
        Self {
            next_fire_at: now + Duration::from_millis(Self::LADDER_MS[0]),
            step: 0,
        }
    }

    fn advance(&mut self, now: Instant) {
        self.step = (self.step + 1).min(Self::LADDER_MS.len() - 1);
        let backoff = Duration::from_millis(Self::LADDER_MS[self.step]);
        self.next_fire_at = now + backoff;
    }
}

impl PairState {
    fn involves_relay(&self) -> bool {
        matches!(self.kinds.0, crate::CandidateKind::Relayed)
            || matches!(self.kinds.1, crate::CandidateKind::Relayed)
    }
}

/// Sort key for primary selection — smaller is better. Ranks by
/// (worse-of-pair tier, local-relay-first, IPv6-first, smoothed RTT).
///
/// The local-relay-first axis only matters at the Relayed tier and
/// breaks ties between routing through *our* relay vs. the peer's. We
/// prefer ours because then our own probe traffic keeps the binding
/// alive.
///
/// IPv6-first is a within-tier tie-break: a v6 path is generally
/// shorter (fewer NATs, often direct) and Firezone runs on dual-stack
/// gear where the v6 leg tends to be the modern default.
fn pair_score(
    pair: (SocketAddr, SocketAddr),
    state: &PairState,
) -> (crate::CandidateKind, u8, u8, Option<Duration>) {
    let tier = state.kinds.0.max(state.kinds.1);
    let local_relay_first = if matches!(state.kinds.0, crate::CandidateKind::Relayed) {
        0
    } else {
        1
    };
    // We filter cross-family pairs in `add_pair`, so it doesn't matter
    // which side we read the family from.
    let v6_first = if pair.0.is_ipv6() { 0 } else { 1 };
    (tier, local_relay_first, v6_first, state.smoothed_rtt)
}

/// Outbound transmit emitted by `PathAgent`.
///
/// snownet picks the wire transport (host send vs. TURN channel-data)
/// from `local`.
#[derive(Debug, Clone, PartialEq)]
pub struct Transmit {
    pub local: SocketAddr,
    pub remote: SocketAddr,
    pub payload: Payload,
}

/// Distinguishes already-encrypted WG bytes (handshake fanout,
/// retransmits, dedup replays) from a plaintext IP packet snownet must
/// run through `Tunn::encapsulate` first. Probes are the only current
/// `Plaintext` source.
#[derive(Debug, Clone, PartialEq)]
pub enum Payload {
    Ciphertext(Vec<u8>),
    Plaintext(ip_packet::IpPacket),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Event {
    /// Primary path set or re-selected. snownet adopts the pair as its
    /// `peer_socket`.
    PrimaryChanged {
        local: SocketAddr,
        remote: SocketAddr,
    },
    /// Inbound handshake bytes the caller must feed to
    /// `Tunn::decapsulate_at`.
    ForwardInbound { bytes: Vec<u8> },
    /// Bootstrap window elapsed without a handshake response. snownet
    /// transitions the connection to `Failed`.
    BootstrapFailed,
}

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
        // The pair's local side is keyed by the *send-from* address
        // (`local.local()` — different from `local.addr()` for
        // server-reflexive candidates, where we send from the underlying
        // base socket, not the NAT-mapped public address). The remote
        // side is keyed by `remote.addr()` — the destination we send to.
        let pair = (local.local(), remote.addr());

        // Skip cross-family pairs: a v4 socket can't send to a v6 dest
        // (and vice versa), and TURN allocations are per-family — so a
        // cross-family pair is unusable in any role (fanout, probe,
        // primary). The bootstrap fanout in particular would try to
        // route a v6 destination through a v4 relay channel binding,
        // which the relay can't do.
        if pair.0.is_ipv4() != pair.1.is_ipv4() {
            return;
        }
        // `next_probe_at: None` here is "not yet seeded";
        // `seed_probe_schedule` flips it to `Some(now)` on the first
        // inbound handshake. Late fanout of a buffered bootstrap init
        // onto this pair (if relay-involved) happens in `handle_timeout`.
        self.pairs.insert(
            pair,
            PairState {
                kinds: (local.kind(), remote.kind()),
                smoothed_rtt: None,
                inflight_probe: None,
                next_probe_at: None,
                next_probe_seq: 0,
            },
        );
    }

    /// Drop a previously-added local candidate and every pair that used
    /// it. Clears `primary` if it pointed at one of the removed pairs.
    pub fn remove_local_candidate(&mut self, c: &Candidate) -> bool {
        let Some(i) = self.locals.iter().position(|x| x == c) else {
            return false;
        };
        let removed = self.locals.remove(i);
        let removed_local = removed.local();
        self.pairs.retain(|(local, _), _| *local != removed_local);
        if let Some((local, _)) = self.primary
            && local == removed_local
        {
            self.primary = None;
        }
        true
    }

    /// Drop a previously-added remote candidate and every pair that used
    /// it. Clears `primary` if it pointed at one of the removed pairs.
    pub fn remove_remote_candidate(&mut self, c: &Candidate) -> bool {
        let Some(i) = self.remotes.iter().position(|x| x == c) else {
            return false;
        };
        let removed = self.remotes.remove(i);
        let removed_addr = removed.addr();
        self.pairs.retain(|(_, remote), _| *remote != removed_addr);
        if let Some((_, remote)) = self.primary
            && remote == removed_addr
        {
            self.primary = None;
        }
        true
    }

    pub fn primary(&self) -> Option<(SocketAddr, SocketAddr)> {
        self.primary
    }

    /// Iterate every relay-involved pair — the set the bootstrap
    /// `HandshakeInit` fans out across.
    pub fn relay_pairs(&self) -> impl Iterator<Item = (SocketAddr, SocketAddr)> + '_ {
        self.pairs
            .iter()
            .filter(|(_, state)| state.involves_relay())
            .map(|(addrs, _)| *addrs)
    }

    /// Iterate every known pair. Test-only.
    #[doc(hidden)]
    pub fn pairs(&self) -> impl Iterator<Item = (SocketAddr, SocketAddr)> + '_ {
        self.pairs.keys().copied()
    }

    /// `true` iff `addr` is a known remote relay candidate. snownet
    /// uses this to classify the destination of a freshly emitted
    /// pair into the right `PeerSocket` variant.
    pub fn remote_is_relayed(&self, addr: SocketAddr) -> bool {
        self.remotes
            .iter()
            .any(|c| c.addr() == addr && c.is_relayed())
    }

    /// Ask `tunnel` for a `HandshakeInit` and route it through
    /// [`Self::handle_outbound`]. Equivalent to calling
    /// `Tunn::format_handshake_initiation_at` and feeding the
    /// resulting bytes back in, but keeps the boringtun-side details
    /// (scratch buffer size, `TunnResult::Done` no-op, force-resend
    /// flag) inside path-agent.
    pub fn initiate_handshake(&mut self, tunnel: &mut Tunn, force_resend: bool, now: Instant) {
        // Largest WG handshake message; responses are smaller.
        const MAX_SCRATCH_SPACE: usize = 148;
        let mut buf = [0u8; MAX_SCRATCH_SPACE];
        let TunnResult::WriteToNetwork(bytes) =
            tunnel.format_handshake_initiation_at(&mut buf, force_resend, now)
        else {
            tracing::debug!("boringtun declined to emit a HandshakeInit");
            return;
        };
        self.handle_outbound(bytes.to_vec(), now);
    }

    /// Route a WG packet boringtun just produced.
    ///
    /// - First `HandshakeInit`: stash the bytes; `handle_timeout` fans
    ///   them out across every relay pair and arms per-pair retransmit
    ///   ladders on the next tick (also when relay pairs arrive late).
    /// - `HandshakeResponse`: pair with the most recently forwarded
    ///   inbound init, send on its receive path, cache for replay.
    /// - Anything else (re-key, data, cookie): single-send on `primary`.
    pub fn handle_outbound(&mut self, bytes: Vec<u8>, now: Instant) {
        let parsed = Tunn::parse_incoming_packet(&bytes);

        match parsed {
            Ok(Packet::HandshakeInit(_)) if !self.established => {
                // Fresh init starts a fresh session — drop the dedup of
                // the *previous* session's response.
                self.forwarded_response = None;
                tracing::debug!(bytes = bytes.len(), "Buffered bootstrap HandshakeInit");
                self.outbound_init = Some(OutboundInit {
                    bytes,
                    retransmits: BTreeMap::new(),
                    // Overwritten on the first actual fanout so the
                    // `BOOTSTRAP_WINDOW` countdown starts from when we
                    // first put bytes on the wire.
                    started_at: now,
                });
                self.established = true;
            }
            Ok(Packet::HandshakeResponse(_)) => {
                if let (Some(init_bytes), Some(path)) = (
                    self.last_forwarded_init.take(),
                    self.last_forwarded_init_path.take(),
                ) {
                    tracing::debug!(
                        local = %path.0,
                        remote = %path.1,
                        "Sending HandshakeResponse on init's recv path",
                    );
                    self.pending_transmits.push_back(Transmit {
                        local: path.0,
                        remote: path.1,
                        payload: Payload::Ciphertext(bytes.clone()),
                    });
                    self.responder_dedup = Some(ResponderDedup {
                        init_bytes,
                        response_bytes: bytes,
                        cached_at: now,
                    });
                    // Acting as responder counts as bootstrap done — any
                    // later init from boringtun is a re-key on this
                    // working session and should ride `primary`, not
                    // re-fan out across every relay pair.
                    self.established = true;
                }
            }
            _ => {
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

    /// Inspect an inbound WG packet on `path`. Returns `Break(())` if
    /// `PathAgent` has taken ownership (handshake — deduped or
    /// forwarded via [`Event::ForwardInbound`]) and `Continue(())` for
    /// non-handshake bytes the caller should feed to `Tunn::decapsulate_at`.
    pub fn handle_inbound(
        &mut self,
        bytes: &[u8],
        path: (SocketAddr, SocketAddr),
        now: Instant,
    ) -> ControlFlow<()> {
        let Ok(parsed) = Tunn::parse_incoming_packet(bytes) else {
            return ControlFlow::Continue(());
        };

        let is_handshake = matches!(
            parsed,
            Packet::HandshakeInit(_) | Packet::HandshakeResponse(_)
        );

        match parsed {
            Packet::HandshakeInit(_) => {
                // Bytes-exact replay against the cached `(init, response)`
                // avoids re-driving boringtun with a dup init that
                // anti-replay would reject anyway.
                if let Some(d) = self.responder_dedup.as_ref()
                    && now.duration_since(d.cached_at) < RESPONDER_DEDUP_TTL
                    && d.init_bytes == bytes
                {
                    tracing::trace!(local = %path.0, remote = %path.1, "Replaying cached HandshakeResponse");
                    self.pending_transmits.push_back(Transmit {
                        local: path.0,
                        remote: path.1,
                        payload: Payload::Ciphertext(d.response_bytes.clone()),
                    });
                    return ControlFlow::Break(());
                }

                // In-flight dedup: the peer's fanout makes the same init
                // arrive on several pairs in the same tick. Once we've
                // queued a `ForwardInbound` for these bytes, dropping
                // dups avoids a second pass through boringtun (which
                // would reject as `WrongTai64nTimestamp`). After the
                // response goes out, `responder_dedup` takes over.
                if self.last_forwarded_init.as_deref() == Some(bytes) {
                    tracing::trace!(local = %path.0, remote = %path.1, "Dropped duplicate inbound HandshakeInit");
                    return ControlFlow::Break(());
                }

                tracing::debug!(local = %path.0, remote = %path.1, "Inbound HandshakeInit, forwarding to boringtun");
                self.last_forwarded_init = Some(bytes.to_vec());
                self.last_forwarded_init_path = Some(path);
                self.queue_event(
                    Event::ForwardInbound {
                        bytes: bytes.to_vec(),
                    },
                    now,
                );
                self.reopen_bootstrap_window(now);
                self.maybe_adopt_handshake_primary(is_handshake, path, now);
                ControlFlow::Break(())
            }
            Packet::HandshakeResponse(_) => {
                // Re-feeding the same response to boringtun would advance
                // the session index and desync state.
                if self.forwarded_response.as_deref() == Some(bytes) {
                    tracing::trace!(local = %path.0, remote = %path.1, "Dropped duplicate HandshakeResponse");
                    return ControlFlow::Break(());
                }

                tracing::debug!(local = %path.0, remote = %path.1, "Inbound HandshakeResponse, forwarding to boringtun");
                self.outbound_init = None;
                self.forwarded_response = Some(bytes.to_vec());
                self.queue_event(
                    Event::ForwardInbound {
                        bytes: bytes.to_vec(),
                    },
                    now,
                );
                self.reopen_bootstrap_window(now);
                self.maybe_adopt_handshake_primary(is_handshake, path, now);
                ControlFlow::Break(())
            }
            Packet::PacketCookieReply(_) | Packet::PacketData(_) => ControlFlow::Continue(()),
        }
    }

    /// Restart the [`BOOTSTRAP_WINDOW`] every time we forward a fresh
    /// handshake to boringtun (i.e., a duplicate that hits one of the
    /// dedup checks doesn't trigger this). Catches the roam case where
    /// signalling delivers the peer's new candidates before the
    /// handshake itself, so the recv path is already in `self.pairs`
    /// — without this, "settle is sticky" would keep the stale
    /// primary on the receiver. Steady-state re-keys also reopen,
    /// which costs ~10 s of all-pair probing every ~120 s; that's
    /// cheap relative to missing a roam.
    fn reopen_bootstrap_window(&mut self, now: Instant) {
        self.bootstrap_settled = false;
        self.bootstrap_until = None;
        self.seed_probe_schedule(now);
    }

    /// Adopt `path` as primary so user packets flow through
    /// `handle_outbound`'s primary branch. Fires whenever a fresh
    /// inbound handshake reaches us on a path other than the current
    /// primary — strictly stronger evidence than smoothed RTT, and
    /// what catches the roam case where the old primary still has a
    /// recent (but stale) RTT sample. Probe-based selection in
    /// `select_primary` continues to refine within the bootstrap
    /// window. Must run *after* `Event::ForwardInbound` is queued so
    /// the consumer drains the handshake (and creates the WG session)
    /// before flushing buffered data on `Event::PrimaryChanged`.
    fn maybe_adopt_handshake_primary(
        &mut self,
        is_handshake: bool,
        path: (SocketAddr, SocketAddr),
        now: Instant,
    ) {
        if !is_handshake {
            return;
        }
        if self.primary == Some(path) {
            return;
        }
        self.primary = Some(path);
        self.queue_event(
            Event::PrimaryChanged {
                local: path.0,
                remote: path.1,
            },
            now,
        );
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

    /// Inspect a decrypted inner-IP packet (output of `Tunn::decapsulate`).
    /// Returns `Break(())` if it was a path probe (caller drops it),
    /// `Continue(())` for ordinary user traffic.
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
                tracing::trace!(local = %pair.0, remote = %pair.1, seq = probe.seq, "Probe request received");
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
                    // Light EMA. Karn/Partridge or Jacobson can land later;
                    // for path selection inside the 10 s window this is enough.
                    state.smoothed_rtt = Some(match state.smoothed_rtt {
                        None => rtt,
                        Some(prev) => (prev + rtt) / 2,
                    });
                    tracing::trace!(local = %pair.0, remote = %pair.1, ?rtt, "Probe reply received");
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
        // Wake at the initiator give-up deadline so `BootstrapFailed`
        // fires promptly. Skipped while retransmits is empty — we
        // haven't fanned out yet, so the deadline is meaningless.
        let init_deadline = self
            .outbound_init
            .as_ref()
            .and_then(|i| (!i.retransmits.is_empty()).then_some(i.started_at + BOOTSTRAP_WINDOW));
        let next_probe = self.pairs.values().filter_map(|s| s.next_probe_at).min();
        // Wake immediately if there's a buffered init waiting on relay
        // pairs that arrived after the initial fanout.
        let pending_fanout = self.outbound_init.as_ref().and_then(|i| {
            self.pairs
                .iter()
                .any(|(addrs, state)| state.involves_relay() && !i.retransmits.contains_key(addrs))
                .then_some(i.started_at)
        });

        [
            self.events_queued_at,
            next_retransmit,
            next_probe,
            self.bootstrap_until,
            init_deadline,
            pending_fanout,
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

    /// At the bootstrap deadline: lock the primary in, scale probing
    /// down to [`PROBE_INTERVAL_LIVE`] on it, and stop probing every
    /// other pair. Each side does this independently on its own primary,
    /// so asymmetric-NAT cases (different primaries on each end) keep
    /// both directions' NAT bindings alive.
    fn maybe_settle(&mut self, now: Instant) {
        let Some(deadline) = self.bootstrap_until else {
            return;
        };
        if now < deadline {
            return;
        }
        for (pair, state) in self.pairs.iter_mut() {
            state.inflight_probe = None;
            state.next_probe_at =
                (Some(*pair) == self.primary).then_some(now + PROBE_INTERVAL_LIVE);
        }
        self.bootstrap_until = None;
        self.bootstrap_settled = true;
        tracing::info!(
            primary = ?self.primary,
            interval = ?PROBE_INTERVAL_LIVE,
            "Iceless bootstrap window closed; settling on primary",
        );
    }

    fn drive_handshake_retransmits(&mut self, now: Instant) {
        // Inbound response never arrived — surface the failure once and
        // tear down the ladder. Skip while retransmits is empty (we
        // haven't fanned out to any pair yet, so there's nothing to
        // give up on). Snownet logs the actual `Connection failed`
        // line when it drains the event.
        if let Some(outbound) = self.outbound_init.as_ref()
            && !outbound.retransmits.is_empty()
            && now.saturating_duration_since(outbound.started_at) >= BOOTSTRAP_WINDOW
        {
            self.outbound_init = None;
            self.queue_event(Event::BootstrapFailed, now);
            return;
        }

        // Disjoint-fields borrow: `outbound_init` and `pending_transmits`
        // share `&mut self` but never alias each other.
        let pending = &mut self.pending_transmits;
        let Some(outbound) = self.outbound_init.as_mut() else {
            return;
        };

        // Fan out to relay pairs that arrived after the initial fanout
        // (or to all relay pairs, if the bootstrap init landed before
        // any remote candidates were known). First fan-out resets
        // `started_at` so the `BOOTSTRAP_WINDOW` timer doesn't count
        // waiting-for-candidates time against the responder.
        let new_relay_pairs: Vec<_> = self
            .pairs
            .iter()
            .filter(|(addrs, state)| {
                state.involves_relay() && !outbound.retransmits.contains_key(*addrs)
            })
            .map(|(addrs, _)| *addrs)
            .collect();
        if !new_relay_pairs.is_empty() && outbound.retransmits.is_empty() {
            outbound.started_at = now;
        }
        for (local, remote) in new_relay_pairs {
            tracing::debug!(%local, %remote, "Fanning out HandshakeInit on relay pair");
            pending.push_back(Transmit {
                local,
                remote,
                payload: Payload::Ciphertext(outbound.bytes.clone()),
            });
            outbound
                .retransmits
                .insert((local, remote), PairRetransmit::new(now));
        }

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
        if self.bootstrap_settled {
            return;
        }
        if self.bootstrap_until.is_none() {
            self.bootstrap_until = Some(now + BOOTSTRAP_WINDOW);
            tracing::info!(
                pairs = self.pairs.len(),
                window = ?BOOTSTRAP_WINDOW,
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
        let (interval, only_primary) = if self.bootstrap_settled {
            (PROBE_INTERVAL_LIVE, true)
        } else {
            (PROBE_INTERVAL, false)
        };
        let primary = self.primary;
        let pending = &mut self.pending_transmits;
        for ((local, remote), state) in self.pairs.iter_mut() {
            if only_primary && primary != Some((*local, *remote)) {
                continue;
            }
            let Some(deadline) = state.next_probe_at else {
                continue;
            };
            if now < deadline {
                continue;
            }

            // Skip-while-pending: don't overwrite the inflight seq slot
            // until the previous probe times out, otherwise late replies
            // on high-RTT paths would never produce a measurement.
            if let Some(inflight) = state.inflight_probe {
                if now.saturating_duration_since(inflight.sent_at) < PROBE_TIMEOUT {
                    state.next_probe_at = Some(inflight.sent_at + PROBE_TIMEOUT);
                    continue;
                }
                state.inflight_probe = None;
            }

            let seq = state.next_probe_seq;
            state.next_probe_seq = state.next_probe_seq.wrapping_add(1);
            state.inflight_probe = Some(InflightProbe { seq, sent_at: now });
            state.next_probe_at = Some(now + interval);

            tracing::trace!(%local, %remote, seq, "Probe send");
            pending.push_back(Transmit {
                local: *local,
                remote: *remote,
                payload: Payload::Plaintext(crate::icmpv6::build_echo_request(PROBE_ID, seq)),
            });
        }
    }

    /// Run [`pair_score`] across the alive pairs and update `primary`.
    /// Emits `PrimaryChanged` if the result differs.
    fn select_primary(&mut self, now: Instant) {
        let best = self
            .pairs
            .iter()
            .filter(|(_, s)| s.smoothed_rtt.is_some())
            .min_by(|(ka, a), (kb, b)| pair_score(**ka, a).cmp(&pair_score(**kb, b)))
            .map(|(k, _)| *k);

        let Some(new) = best else { return };
        let new_rtt = self
            .pairs
            .get(&new)
            .and_then(|s| s.smoothed_rtt)
            .unwrap_or_default();
        if self.primary != Some(new) {
            let from = self.primary;
            self.primary = Some(new);
            tracing::info!(
                ?from,
                local = %new.0,
                remote = %new.1,
                rtt = ?new_rtt,
                "Iceless primary changed",
            );
            self.queue_event(
                Event::PrimaryChanged {
                    local: new.0,
                    remote: new.1,
                },
                now,
            );
        }
    }
}
