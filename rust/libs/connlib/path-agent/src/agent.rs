use std::collections::{BTreeMap, VecDeque};
use std::net::SocketAddr;
use std::ops::ControlFlow;
use std::time::{Duration, Instant};

use boringtun::noise::{Packet, Tunn, TunnResult};

use crate::candidate::Candidate;

/// Path-selection state machine for ICE-less snownet connections.
///
/// snownet drives outbound WG bytes through [`PathAgent::handle_outbound`]
/// and inbound bytes through [`PathAgent::handle_inbound`]. Decisions
/// flow back via [`PathAgent::poll_transmit`] / [`PathAgent::poll_event`].
/// Pair identifiers are `(local, remote)` `SocketAddr` tuples.
///
/// # Lifecycle
///
/// 1. **Bootstrap.** First outbound `HandshakeInit` fans out across
///    every relay-involved pair with a per-pair retransmit ladder.
///    The first inbound handshake seeds [`PROBE_INTERVAL`]-cadence
///    probing on every pair and adopts the receive path as the
///    bootstrap primary.
/// 2. **Probing.** ICMPv6 echo round-trips populate per-pair smoothed
///    RTTs; the primary is selected by [`pair_score`].
/// 3. **Settle.** After [`BOOTSTRAP_WINDOW`], probing winds down to
///    [`PROBE_INTERVAL_LIVE`] on the primary only — just enough to
///    keep its NAT binding alive.
/// 4. **Re-key.** A WG re-key (outbound `HandshakeInit` while
///    `established`) reopens the bootstrap window so probes restart
///    immediately; the same reset fires on every inbound handshake.
pub struct PathAgent {
    locals: Vec<Candidate>,
    remotes: Vec<Candidate>,
    pairs: BTreeMap<(SocketAddr, SocketAddr), PairState>,
    primary: Option<(SocketAddr, SocketAddr)>,

    /// `true` once this side has taken ownership of the first
    /// handshake — initiator-buffered or responder-emitted.
    /// Subsequent inits from boringtun are re-keys.
    established: bool,

    bootstrap: Bootstrap,
    responder: Responder,

    /// In-flight outbound `HandshakeInit` plus per-pair retransmits.
    outbound_init: Option<OutboundInit>,
    /// Most recent forwarded `HandshakeResponse` bytes — re-feeding
    /// the same response to boringtun would desync session state.
    forwarded_response: Option<Vec<u8>>,

    pending_transmits: VecDeque<Transmit>,
    events: VecDeque<Event>,
    /// Pushed-at timestamp of the oldest queued event. Surfaced via
    /// `poll_timeout` so the next tick drains promptly.
    events_queued_at: Option<Instant>,
}

#[derive(Default)]
struct Bootstrap {
    /// Window deadline. `Some` while open; cleared on settle.
    until: Option<Instant>,
    /// Sticky: once the deadline elapses, later events don't reopen
    /// the window.
    settled: bool,
}

#[derive(Default)]
struct Responder {
    /// Most recently forwarded inbound `HandshakeInit` and its receive
    /// path. The next outbound `HandshakeResponse` is paired against
    /// these and the bytes go into [`Responder::dedup`].
    last_init: Option<Vec<u8>>,
    last_init_path: Option<(SocketAddr, SocketAddr)>,
    /// Bytes-exact replay cache: dup inits replay the matching
    /// response without re-driving boringtun.
    dedup: Option<ResponderDedup>,
}

struct PairState {
    kinds: (crate::CandidateKind, crate::CandidateKind),
    /// `true` for non-relay pairs by construction. For relay pairs,
    /// `false` iff the allocation and the local TURN socket use
    /// different IP families — drives a within-tier penalty in
    /// [`pair_score`].
    local_family_matched: bool,
    smoothed_rtt: Option<Duration>,
    inflight_probe: Option<InflightProbe>,
    /// `None` means "not yet seeded"; `drive_probes` lazy-seeds during
    /// the open window.
    next_probe_at: Option<Instant>,
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
    /// First emission timestamp. Reset when relay pairs arrive late
    /// so `BOOTSTRAP_WINDOW` doesn't count waiting time.
    started_at: Instant,
}

struct ResponderDedup {
    init_bytes: Vec<u8>,
    response_bytes: Vec<u8>,
    cached_at: Instant,
}

const RESPONDER_DEDUP_TTL: Duration = Duration::from_secs(10);

pub const PROBE_INTERVAL: Duration = Duration::from_millis(500);

/// Treat an in-flight probe as lost if no reply arrives within this
/// window. Without it, high-RTT paths would never produce a sample.
pub const PROBE_TIMEOUT: Duration = Duration::from_secs(2);

/// Steady-state probe cadence on the primary, matching WG's
/// persistent-keepalive default.
pub const PROBE_INTERVAL_LIVE: Duration = Duration::from_secs(25);

pub const BOOTSTRAP_WINDOW: Duration = Duration::from_secs(10);

struct PairRetransmit {
    next_fire_at: Instant,
    step: usize,
}

impl PairRetransmit {
    /// 50/50/50 ms head covers the race where our init lands on a
    /// relay before the *peer's* channel-bind is registered. Past
    /// that, exponential doubling capped at 1.6 s.
    const LADDER_MS: &'static [u64] = &[50, 50, 50, 100, 200, 400, 800, 1600];

    fn new(now: Instant) -> Self {
        Self {
            next_fire_at: now + Duration::from_millis(Self::LADDER_MS[0]),
            step: 0,
        }
    }

    fn advance(&mut self, now: Instant) {
        self.step = (self.step + 1).min(Self::LADDER_MS.len() - 1);
        self.next_fire_at = now + Duration::from_millis(Self::LADDER_MS[self.step]);
    }
}

impl PairState {
    fn involves_relay(&self) -> bool {
        matches!(self.kinds.0, crate::CandidateKind::Relayed)
            || matches!(self.kinds.1, crate::CandidateKind::Relayed)
    }
}

/// Smaller-is-better sort key for primary selection. Ranks by:
/// worse-of-pair tier, local-relay-first (Relayed tier only),
/// relay-family-matched, IPv6-first, smoothed RTT.
fn pair_score(
    pair: (SocketAddr, SocketAddr),
    state: &PairState,
) -> (crate::CandidateKind, u8, u8, u8, Option<Duration>) {
    let tier = state.kinds.0.max(state.kinds.1);
    let local_relay_first = u8::from(!matches!(state.kinds.0, crate::CandidateKind::Relayed));
    let family_match = u8::from(!state.local_family_matched);
    let v6_first = u8::from(!pair.0.is_ipv6());
    (
        tier,
        local_relay_first,
        family_match,
        v6_first,
        state.smoothed_rtt,
    )
}

/// Outbound transmit. snownet picks the wire transport (host send vs.
/// TURN channel-data) from `local`.
#[derive(Debug, Clone, PartialEq)]
pub struct Transmit {
    pub local: SocketAddr,
    pub remote: SocketAddr,
    pub payload: Payload,
}

/// `Ciphertext`: already-encrypted WG bytes (handshake fanout,
/// retransmits, dedup replays). `Plaintext`: an inner IP packet
/// snownet must run through `Tunn::encapsulate` first — probes only.
#[derive(Debug, Clone, PartialEq)]
pub enum Payload {
    Ciphertext(Vec<u8>),
    Plaintext(ip_packet::IpPacket),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Event {
    /// Primary path set or re-selected. snownet adopts the pair as
    /// its `peer_socket`.
    PrimaryChanged {
        local: SocketAddr,
        remote: SocketAddr,
    },
    /// Inbound handshake bytes the caller must feed to `Tunn::decapsulate_at`.
    ForwardInbound { bytes: Vec<u8> },
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
            bootstrap: Bootstrap::default(),
            responder: Responder::default(),
            outbound_init: None,
            forwarded_response: None,
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
        // Pair-key local side is the *send-from* address — for srflx
        // candidates that's the base socket, not the NAT-mapped one.
        // Remote side is `addr()` — the destination we send to.
        let pair = (local.local(), remote.addr());

        // Cross-family pairs are unusable: TURN allocations are
        // per-family, and a v4 socket can't send to a v6 dest.
        if pair.0.is_ipv4() != pair.1.is_ipv4() {
            return;
        }
        self.pairs.insert(
            pair,
            PairState {
                kinds: (local.kind(), remote.kind()),
                local_family_matched: local.is_family_matched(),
                smoothed_rtt: None,
                inflight_probe: None,
                next_probe_at: None,
                next_probe_seq: 0,
            },
        );
    }

    /// Drop a local candidate and every pair using it. Clears
    /// `primary` if it pointed at a removed pair, and reopens the
    /// bootstrap window so the survivors get re-probed.
    pub fn remove_local_candidate(&mut self, c: &Candidate, now: Instant) -> bool {
        let Some(i) = self.locals.iter().position(|x| x == c) else {
            return false;
        };
        let removed_local = self.locals.remove(i).local();
        self.pairs.retain(|(local, _), _| *local != removed_local);
        if let Some((local, _)) = self.primary
            && local == removed_local
        {
            self.primary = None;
            self.reopen_bootstrap_window(now);
        }
        true
    }

    /// See [`Self::remove_local_candidate`].
    pub fn remove_remote_candidate(&mut self, c: &Candidate, now: Instant) -> bool {
        let Some(i) = self.remotes.iter().position(|x| x == c) else {
            return false;
        };
        let removed_addr = self.remotes.remove(i).addr();
        self.pairs.retain(|(_, remote), _| *remote != removed_addr);
        if let Some((_, remote)) = self.primary
            && remote == removed_addr
        {
            self.primary = None;
            self.reopen_bootstrap_window(now);
        }
        true
    }

    pub fn primary(&self) -> Option<(SocketAddr, SocketAddr)> {
        self.primary
    }

    /// Iterate every relay-involved pair — the bootstrap fanout set.
    pub fn relay_pairs(&self) -> impl Iterator<Item = (SocketAddr, SocketAddr)> + '_ {
        self.pairs
            .iter()
            .filter(|(_, state)| state.involves_relay())
            .map(|(addrs, _)| *addrs)
    }

    #[doc(hidden)]
    pub fn pairs(&self) -> impl Iterator<Item = (SocketAddr, SocketAddr)> + '_ {
        self.pairs.keys().copied()
    }

    /// `true` iff `addr` is a known remote relay candidate.
    pub fn remote_is_relayed(&self, addr: SocketAddr) -> bool {
        self.remotes
            .iter()
            .any(|c| c.addr() == addr && c.is_relayed())
    }

    /// Ask `tunnel` for a `HandshakeInit` and route it through
    /// [`Self::handle_outbound`]. Encapsulates the boringtun-side
    /// scratch-buffer details.
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
    /// - First `HandshakeInit` (`!established`): stash and let
    ///   `handle_timeout` fan it out across relay pairs.
    /// - `HandshakeInit` while `established` (re-key): ride `primary`
    ///   and reopen the bootstrap window so probes restart now
    ///   instead of waiting an RTT for the response.
    /// - `HandshakeResponse`: pair with the most recently forwarded
    ///   inbound init, send on its receive path, cache for replay.
    /// - Anything else (data, cookie): single-send on `primary`.
    pub fn handle_outbound(&mut self, bytes: Vec<u8>, now: Instant) {
        match Tunn::parse_incoming_packet(&bytes) {
            Ok(Packet::HandshakeInit(_)) if !self.established => {
                // Fresh init starts a fresh session.
                self.forwarded_response = None;
                tracing::debug!(bytes = bytes.len(), "Buffered bootstrap HandshakeInit");
                self.outbound_init = Some(OutboundInit {
                    bytes,
                    retransmits: BTreeMap::new(),
                    // Reset on first fanout in `drive_handshake_retransmits`.
                    started_at: now,
                });
                self.established = true;
            }
            Ok(Packet::HandshakeInit(_)) => {
                tracing::debug!(
                    bytes = bytes.len(),
                    "Re-key HandshakeInit; restarting probes"
                );
                self.reopen_bootstrap_window(now);
                if let Some((local, remote)) = self.primary {
                    self.pending_transmits.push_back(Transmit {
                        local,
                        remote,
                        payload: Payload::Ciphertext(bytes),
                    });
                }
            }
            Ok(Packet::HandshakeResponse(_)) => {
                if let (Some(init_bytes), Some(path)) = (
                    self.responder.last_init.take(),
                    self.responder.last_init_path.take(),
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
                    self.responder.dedup = Some(ResponderDedup {
                        init_bytes,
                        response_bytes: bytes,
                        cached_at: now,
                    });
                    // Responder side: bootstrap done; later inits are re-keys.
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

    /// Inspect an inbound WG packet on `path`. `Break(())` if owned
    /// here (handshake deduped or forwarded via [`Event::ForwardInbound`]);
    /// `Continue(())` for non-handshake bytes the caller must feed to
    /// `Tunn::decapsulate_at`.
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
                // Cached-response replay against a bytes-exact dup init.
                if let Some(d) = self.responder.dedup.as_ref()
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

                // In-flight dedup: peer's fanout delivers the same init on
                // several pairs in one tick. Drop dups until the response
                // goes out and `responder.dedup` takes over — otherwise
                // boringtun rejects as `WrongTai64nTimestamp`.
                if self.responder.last_init.as_deref() == Some(bytes) {
                    tracing::trace!(local = %path.0, remote = %path.1, "Dropped duplicate inbound HandshakeInit");
                    return ControlFlow::Break(());
                }

                tracing::debug!(local = %path.0, remote = %path.1, "Inbound HandshakeInit, forwarding to boringtun");
                self.responder.last_init = Some(bytes.to_vec());
                self.responder.last_init_path = Some(path);
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

    /// Treat every forwarded fresh handshake as a topology reset:
    /// wipe smoothed RTTs and re-seed 500 ms probing. Catches roams
    /// where the peer's new candidates arrive via signalling before
    /// the handshake itself.
    ///
    /// Idempotent within an open window: an outbound re-key reopens
    /// immediately; the inbound response 1 RTT later would otherwise
    /// re-wipe accumulated probe data.
    fn reopen_bootstrap_window(&mut self, now: Instant) {
        if let Some(deadline) = self.bootstrap.until
            && now < deadline
            && !self.bootstrap.settled
        {
            return;
        }
        for state in self.pairs.values_mut() {
            state.smoothed_rtt = None;
            // Pre-reset in-flight replies will be ignored by seq mismatch.
            state.inflight_probe = None;
        }
        self.bootstrap.settled = false;
        self.bootstrap.until = None;
        self.seed_probe_schedule(now);
    }

    /// Adopt `path` as primary on a fresh inbound handshake — strictly
    /// stronger evidence than smoothed RTT. Must fire *after*
    /// `ForwardInbound` is queued so the WG session exists before
    /// the consumer flushes buffered data on `PrimaryChanged`.
    fn maybe_adopt_handshake_primary(
        &mut self,
        is_handshake: bool,
        path: (SocketAddr, SocketAddr),
        now: Instant,
    ) {
        if !is_handshake || self.primary == Some(path) {
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

    /// Inspect a decrypted inner-IP packet. `Break(())` for probes
    /// (caller drops), `Continue(())` for user traffic.
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
                    // Light EMA; sufficient for selection inside the 10 s window.
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
        let next_probe = self.pairs.values().filter_map(|s| s.next_probe_at).min();
        // Wake immediately if a buffered init is waiting on relay pairs
        // that arrived after the initial fanout.
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
            self.bootstrap.until,
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

    /// At the bootstrap deadline, lock the primary in and scale to
    /// [`PROBE_INTERVAL_LIVE`] on it only. Each side settles
    /// independently, so asymmetric primaries keep both directions
    /// alive.
    fn maybe_settle(&mut self, now: Instant) {
        let Some(deadline) = self.bootstrap.until else {
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
        self.bootstrap.until = None;
        self.bootstrap.settled = true;
        tracing::info!(
            primary = ?self.primary,
            interval = ?PROBE_INTERVAL_LIVE,
            "Iceless bootstrap window closed; settling on primary",
        );
    }

    fn drive_handshake_retransmits(&mut self, now: Instant) {
        // Disjoint-fields borrow: `outbound_init` and `pending_transmits`
        // never alias.
        let pending = &mut self.pending_transmits;
        let Some(outbound) = self.outbound_init.as_mut() else {
            return;
        };

        // Fan out to relay pairs that arrived after the initial fanout
        // (or to all relay pairs if the init landed before any remote
        // candidates were known). First fan-out resets `started_at` so
        // `BOOTSTRAP_WINDOW` doesn't count waiting-for-candidates time.
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
        if self.bootstrap.settled {
            return;
        }
        if self.bootstrap.until.is_none() {
            self.bootstrap.until = Some(now + BOOTSTRAP_WINDOW);
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
        let (interval, only_primary) = if self.bootstrap.settled {
            (PROBE_INTERVAL_LIVE, true)
        } else {
            (PROBE_INTERVAL, false)
        };
        // Lazy seed: pairs added after `seed_probe_schedule` ran (typical
        // for trickled host/srflx candidates landing after the relay
        // bootstrap) have `next_probe_at == None`. Treat as due now
        // while the window is open. Pre-handshake stays dormant.
        let window_open = self.bootstrap.until.is_some();
        let primary = self.primary;
        let pending = &mut self.pending_transmits;
        for ((local, remote), state) in self.pairs.iter_mut() {
            if only_primary && primary != Some((*local, *remote)) {
                continue;
            }
            let Some(deadline) = state.next_probe_at.or(window_open.then_some(now)) else {
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
                payload: Payload::Plaintext(crate::icmpv6::build_echo_request(0, seq)),
            });
        }
    }

    /// Run [`pair_score`] across pairs with a measured RTT and update
    /// `primary`, emitting `PrimaryChanged` if it moves.
    fn select_primary(&mut self, now: Instant) {
        let best = self
            .pairs
            .iter()
            .filter(|(_, s)| s.smoothed_rtt.is_some())
            .min_by(|(ka, a), (kb, b)| pair_score(**ka, a).cmp(&pair_score(**kb, b)))
            .map(|(k, _)| *k);

        let Some(new) = best else { return };
        if self.primary == Some(new) {
            return;
        }
        let new_rtt = self
            .pairs
            .get(&new)
            .and_then(|s| s.smoothed_rtt)
            .unwrap_or_default();
        let from = self.primary;
        self.primary = Some(new);
        tracing::debug!(
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
