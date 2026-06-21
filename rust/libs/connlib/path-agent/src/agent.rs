use std::collections::{BTreeMap, BTreeSet, VecDeque};
use std::iter;
use std::net::SocketAddr;
use std::ops::ControlFlow;
use std::time::{Duration, Instant};

use boringtun::noise::{Packet, Tunn, TunnResult};

use crate::candidate::Candidate;
use crate::event::{Event, Payload, Transmit};
use crate::retransmit::PairRetransmit;
use crate::score::pair_score;

/// Path-selection state machine for ICE-less snownet connections.
///
/// snownet drives outbound WG bytes through [`PathAgent::handle_outbound`]
/// and inbound bytes through [`PathAgent::handle_inbound_network`]. Decisions
/// flow back via [`PathAgent::poll_transmit`] / [`PathAgent::poll_event`].
/// Pair identifiers are `(local, remote)` `SocketAddr` tuples.
///
/// # Lifecycle
///
/// 1. **Handshake.** First outbound `HandshakeInit` fans out across
///    every relay-involved pair with a per-pair retransmit ladder.
///    The first inbound handshake seeds [`PROBE_INTERVAL`]-cadence
///    probing on every pair and adopts the receive path as the
///    initial primary.
/// 2. **Probing.** ICMPv6 echo round-trips populate per-pair smoothed
///    RTTs; the primary is selected by `pair_score`.
/// 3. **Settle.** After [`EVALUATION_WINDOW`], probing winds down to
///    [`PROBE_INTERVAL_LIVE`] on the primary only — just enough to
///    keep its NAT binding alive.
/// 4. **Re-key.** A WG re-key (outbound `HandshakeInit` while
///    `established`) reopens the path-evaluation window so probes restart
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

    window: EvaluationWindow,
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

    /// Addresses we registered as peer-reflexive remote candidates.
    /// Lets [`Self::add_remote_candidate`] promote a peer-reflexive
    /// entry to the signaled candidate when the latter arrives, ICE-
    /// style — replacing the entry in place so accumulated RTT on
    /// the pair survives. Size doubles as a soft cap on growth via
    /// [`MAX_PEER_REFLEXIVE`].
    peer_reflexive_addrs: BTreeSet<SocketAddr>,
}

/// Lifecycle of the aggressive-probing window each fresh handshake
/// opens. `Pending` before the first handshake (and briefly after a
/// reset); `Open` while every pair is probed at [`PROBE_INTERVAL`] up
/// to the deadline; `Settled` once it elapses and probing drops to
/// [`PROBE_INTERVAL_LIVE`] on the primary only. Settling is sticky —
/// only [`PathAgent::reopen_evaluation_window`] returns to `Pending`.
enum EvaluationWindow {
    Pending,
    Open { until: Instant },
    Settled,
}

impl EvaluationWindow {
    fn deadline(&self) -> Option<Instant> {
        match self {
            Self::Open { until } => Some(*until),
            Self::Pending | Self::Settled => None,
        }
    }

    fn is_open(&self) -> bool {
        matches!(self, Self::Open { .. })
    }

    fn is_settled(&self) -> bool {
        matches!(self, Self::Settled)
    }
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

pub(crate) struct PairState {
    pub(crate) kinds: (crate::CandidateKind, crate::CandidateKind),
    /// `true` for non-relay pairs by construction. For relay pairs,
    /// `false` iff the allocation and the local TURN socket use
    /// different IP families — drives a within-tier penalty in
    /// [`crate::score::pair_score`].
    pub(crate) local_family_matched: bool,
    pub(crate) smoothed_rtt: Option<Duration>,
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
    /// so `EVALUATION_WINDOW` doesn't count waiting time.
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

pub const EVALUATION_WINDOW: Duration = Duration::from_secs(10);

/// Cap on peer-reflexive remote candidates we'll register from
/// inbound Echo Requests on otherwise-unknown source addresses.
/// Peer-reflexive discovery handles the symmetric-NAT case where the
/// peer reaches us from a mapping they didn't advertise; the cap
/// bounds growth if NAT mapping flaps or a malicious peer spoofs
/// many sources. Reset implicitly on roam / relay rebuild via
/// [`PathAgent::new`].
const MAX_PEER_REFLEXIVE: usize = 4;

/// Within the same discrete bucket (same tier / relay-first /
/// family-match / v6-first), a challenger pair must beat the current
/// primary's smoothed RTT by `max(FLOOR, FRACTION * primary_rtt)` before
/// we switch to it. Without this, probe jitter flaps the primary between
/// effectively-tied pairs, each flap churning the peer socket and
/// flushing buffers. Categorical improvements (a better discrete axis)
/// bypass the margin and switch immediately.
const PRIMARY_HYSTERESIS_FRACTION: f64 = 0.2;
const PRIMARY_HYSTERESIS_FLOOR: Duration = Duration::from_millis(10);

impl PairState {
    fn involves_relay(&self) -> bool {
        matches!(self.kinds.0, crate::CandidateKind::Relayed)
            || matches!(self.kinds.1, crate::CandidateKind::Relayed)
    }
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
            window: EvaluationWindow::Pending,
            responder: Responder::default(),
            outbound_init: None,
            forwarded_response: None,
            pending_transmits: VecDeque::new(),
            events: VecDeque::new(),
            events_queued_at: None,
            peer_reflexive_addrs: BTreeSet::new(),
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
        // ICE-style peer-reflexive promotion. If the signaled
        // candidate matches an address we previously registered as
        // peer-reflexive, replace the entry in place — the pair-key
        // is `(local, remote.addr())` so the existing `PairState`
        // (smoothed RTT, inflight probe, schedule) survives. Just
        // refresh `kinds.1` in case the signaled kind differs from
        // the assumed `ServerReflexive`.
        if self.peer_reflexive_addrs.remove(&c.addr())
            && let Some(i) = self.remotes.iter().position(|x| x.addr() == c.addr())
        {
            tracing::debug!(
                remote = %c.addr(),
                kind = ?c.kind(),
                "Promoting peer-reflexive remote to signaled candidate",
            );
            self.remotes[i] = c;
            for ((_, remote_addr), state) in self.pairs.iter_mut() {
                if *remote_addr == c.addr() {
                    state.kinds.1 = c.kind();
                }
            }
            return;
        }

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
    /// path-evaluation window so the survivors get re-probed.
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
            self.reopen_evaluation_window(now);
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
        self.peer_reflexive_addrs.remove(&removed_addr);

        if let Some((_, remote)) = self.primary
            && remote == removed_addr
        {
            self.primary = None;
            self.reopen_evaluation_window(now);
        }

        true
    }

    pub fn primary(&self) -> Option<(SocketAddr, SocketAddr)> {
        self.primary
    }

    /// Iterate every relay-involved pair — the handshake fanout set.
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
    ///   and reopen the path-evaluation window so probes restart now
    ///   instead of waiting an RTT for the response.
    /// - `HandshakeResponse`: pair with the most recently forwarded
    ///   inbound init, send on its receive path, cache for replay.
    /// - Anything else (data, cookie): single-send on `primary`.
    pub fn handle_outbound(&mut self, bytes: Vec<u8>, now: Instant) {
        match Tunn::parse_incoming_packet(&bytes) {
            Ok(Packet::HandshakeInit(_)) if !self.established => {
                // Fresh init starts a fresh session.
                self.forwarded_response = None;

                tracing::debug!(bytes = bytes.len(), "Buffered initial HandshakeInit");

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

                self.reopen_evaluation_window(now);

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
                    // Responder side: initial handshake done; later inits are re-keys.
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

    /// Inspect an inbound WG packet on `path`.
    ///
    /// `validator` is the authoritative source for whether the bytes
    /// represent a real handshake. Dedup checks short-circuit before
    /// it runs; for everything else, no state mutation (responder
    /// dedup, evaluation-window reopen, primary adoption, outbound
    /// routing) happens until validation succeeds.
    pub fn handle_inbound_network<'b>(
        &mut self,
        validator: &mut dyn crate::HandshakeValidator,
        bytes: &'b [u8],
        path: (SocketAddr, SocketAddr),
        now: Instant,
    ) -> ControlFlow<(), &'b [u8]> {
        let Ok(parsed) = Tunn::parse_incoming_packet(bytes) else {
            return ControlFlow::Continue(bytes);
        };

        let is_handshake = matches!(
            parsed,
            Packet::HandshakeInit(_) | Packet::HandshakeResponse(_)
        );

        match parsed {
            Packet::HandshakeInit(_) => {
                // Cached-response replay against a bytes-exact dup init.
                // Cheap and pre-validated: the cache entry was populated
                // from a previously-accepted handshake.
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
                //
                // `last_init` was set on a previous accepted call, so
                // matching here means we already validated these bytes.
                if self.responder.last_init.as_deref() == Some(bytes) {
                    tracing::trace!(local = %path.0, remote = %path.1, "Dropped duplicate inbound HandshakeInit");

                    return ControlFlow::Break(());
                }

                let mut outbound = Vec::<Vec<u8>>::new();
                match validator.validate(bytes, now, &mut |b| outbound.push(b)) {
                    Err(crate::Rejected) => {
                        tracing::debug!(local = %path.0, remote = %path.1, "Inbound HandshakeInit rejected by validator");
                        return ControlFlow::Break(());
                    }
                    Ok(crate::Accepted::Cookie) => {
                        tracing::debug!(local = %path.0, remote = %path.1, "Inbound HandshakeInit answered with cookie reply under load");
                        self.send_on_path(outbound, path);
                        return ControlFlow::Break(());
                    }
                    Ok(crate::Accepted::Session) => {}
                }

                tracing::debug!(local = %path.0, remote = %path.1, "Inbound HandshakeInit accepted");

                // Commit: bytes are now known-good. `handle_outbound`
                // for the `HandshakeResponse` pairs against
                // `responder.last_init`/`last_init_path`, so set those
                // before routing.
                self.responder.last_init = Some(bytes.to_vec());
                self.responder.last_init_path = Some(path);
                self.reopen_evaluation_window(now);
                self.maybe_adopt_handshake_primary(is_handshake, path, now);

                for b in outbound {
                    self.handle_outbound(b, now);
                }

                ControlFlow::Break(())
            }
            Packet::HandshakeResponse(_) => {
                // Bytes-exact dup of a response we already processed.
                // Was previously validated, so safe to drop here.
                if self.forwarded_response.as_deref() == Some(bytes) {
                    tracing::trace!(local = %path.0, remote = %path.1, "Dropped duplicate HandshakeResponse");

                    return ControlFlow::Break(());
                }

                let mut outbound = Vec::<Vec<u8>>::new();
                match validator.validate(bytes, now, &mut |b| outbound.push(b)) {
                    Err(crate::Rejected) => {
                        tracing::debug!(local = %path.0, remote = %path.1, "Inbound HandshakeResponse rejected by validator");
                        return ControlFlow::Break(());
                    }
                    Ok(crate::Accepted::Cookie) => {
                        tracing::debug!(local = %path.0, remote = %path.1, "Inbound HandshakeResponse answered with cookie reply under load");
                        self.send_on_path(outbound, path);
                        return ControlFlow::Break(());
                    }
                    Ok(crate::Accepted::Session) => {}
                }

                tracing::debug!(local = %path.0, remote = %path.1, "Inbound HandshakeResponse accepted");

                self.outbound_init = None;
                self.forwarded_response = Some(bytes.to_vec());
                self.reopen_evaluation_window(now);
                self.maybe_adopt_handshake_primary(is_handshake, path, now);

                // Any bytes the validator surfaced (queued data
                // packets boringtun was holding while handshake-pending)
                // ride the now-primary path via the regular outbound
                // routing.
                for b in outbound {
                    self.handle_outbound(b, now);
                }

                ControlFlow::Break(())
            }
            Packet::PacketCookieReply(_) | Packet::PacketData(_) => ControlFlow::Continue(bytes),
        }
    }

    /// Queue `packets` to go out on `path`'s send side. Used for cookie
    /// replies, which must reach the sender on the receive path without
    /// adopting that path or touching any session state.
    fn send_on_path(&mut self, packets: Vec<Vec<u8>>, path: (SocketAddr, SocketAddr)) {
        for bytes in packets {
            self.pending_transmits.push_back(Transmit {
                local: path.0,
                remote: path.1,
                payload: Payload::Ciphertext(bytes),
            });
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
    fn reopen_evaluation_window(&mut self, now: Instant) {
        if let Some(deadline) = self.window.deadline()
            && now < deadline
        {
            return;
        }

        for state in self.pairs.values_mut() {
            state.smoothed_rtt = None;
            // Pre-reset in-flight replies will be ignored by seq mismatch.
            state.inflight_probe = None;
        }

        self.window = EvaluationWindow::Pending;

        self.seed_probe_schedule(now);
    }

    /// Adopt `path` as primary on a fresh inbound handshake — strictly
    /// stronger evidence than smoothed RTT. Must fire *after*
    /// `ForwardHandshake` is queued so the WG session exists before
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

    /// Take ownership of a decrypted inner-IP packet.
    pub fn handle_inbound_tun(
        &mut self,
        packet: ip_packet::IpPacket,
        pair: (SocketAddr, SocketAddr),
        now: Instant,
    ) -> ControlFlow<(), ip_packet::IpPacket> {
        let Some(probe) = crate::icmpv6::Probe::try_parse(&packet) else {
            return ControlFlow::Continue(packet);
        };

        match probe.kind {
            crate::icmpv6::Echo::Request => {
                tracing::trace!(local = %pair.0, remote = %pair.1, seq = probe.seq, "Probe request received");

                self.pending_transmits.push_back(Transmit {
                    local: pair.0,
                    remote: pair.1,
                    payload: Payload::Plaintext(Box::new(crate::icmpv6::build_echo_reply(
                        probe.id, probe.seq,
                    ))),
                });

                // Peer-reflexive discovery: an Echo Request from a
                // remote we never registered (peer reached us from a
                // NAT mapping they didn't advertise) becomes a new
                // server-reflexive candidate. `drive_probes` measures
                // the pair on the current open window — or the next
                // reopen if we're settled — and `select_primary` can
                // then promote it. Bounded by [`MAX_PEER_REFLEXIVE`].
                // If the peer later signals the matching candidate,
                // `add_remote_candidate` promotes the entry in place.
                if self.peer_reflexive_addrs.len() < MAX_PEER_REFLEXIVE
                    && !self.remotes.iter().any(|c| c.addr() == pair.1)
                {
                    tracing::debug!(
                        local = %pair.0,
                        remote = %pair.1,
                        "Discovered peer-reflexive remote candidate",
                    );
                    self.peer_reflexive_addrs.insert(pair.1);
                    self.add_remote_candidate(Candidate::server_reflexive(pair.1, pair.1));
                }
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

        iter::empty()
            .chain(self.events_queued_at)
            .chain(next_retransmit)
            .chain(next_probe)
            .chain(self.window.deadline())
            .chain(pending_fanout)
            .min()
    }

    pub fn handle_timeout(&mut self, now: Instant) {
        self.drive_handshake_retransmits(now);
        self.drive_probes(now);
        self.maybe_settle(now);
    }

    /// At the evaluation deadline, lock the primary in and scale to
    /// [`PROBE_INTERVAL_LIVE`] on it only. Each side settles
    /// independently, so asymmetric primaries keep both directions
    /// alive.
    fn maybe_settle(&mut self, now: Instant) {
        let Some(deadline) = self.window.deadline() else {
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

        self.window = EvaluationWindow::Settled;

        tracing::info!(
            primary = ?self.primary,
            interval = ?PROBE_INTERVAL_LIVE,
            "Iceless path-evaluation window closed; settling on primary",
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
        // `EVALUATION_WINDOW` doesn't count waiting-for-candidates time.
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
        if self.window.is_settled() {
            return;
        }

        if !self.window.is_open() {
            self.window = EvaluationWindow::Open {
                until: now + EVALUATION_WINDOW,
            };

            tracing::info!(
                pairs = self.pairs.len(),
                window = ?EVALUATION_WINDOW,
                "Iceless path-evaluation window opened",
            );
        }

        for state in self.pairs.values_mut() {
            if state.next_probe_at.is_none() {
                state.next_probe_at = Some(now);
            }
        }
    }

    fn drive_probes(&mut self, now: Instant) {
        let (interval, only_primary) = if self.window.is_settled() {
            (PROBE_INTERVAL_LIVE, true)
        } else {
            (PROBE_INTERVAL, false)
        };

        // Lazy seed: pairs added after `seed_probe_schedule` ran (typical
        // for trickled host/srflx candidates landing after the relay
        // handshake) have `next_probe_at == None`. Treat as due now
        // while the window is open. Pre-handshake stays dormant.
        let window_open = self.window.is_open();
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
                payload: Payload::Plaintext(Box::new(crate::icmpv6::build_echo_request(0, seq))),
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
            .min_by_key(|(k, s)| pair_score(**k, s))
            .map(|(k, _)| *k);

        let Some(new) = best else { return };

        if self.primary == Some(new) {
            return;
        }

        // Hysteresis on the RTT axis only. `new` is the global minimum by
        // `pair_score`, so against the incumbent it can only tie or win on
        // the discrete prefix. A strict discrete win switches immediately
        // (e.g. a direct path appearing must displace a relay path). Within
        // the same bucket, require `new` to beat the incumbent's RTT by a
        // margin so probe jitter doesn't flap between near-tied pairs. A
        // missing / unmeasured / dropped incumbent leaves nothing to be
        // sticky about — adopt `new` so evaluation and re-key still converge.
        if let Some(primary) = self.primary
            && let Some(prev) = self.pairs.get(&primary)
            && let Some(prev_rtt) = prev.smoothed_rtt
        {
            let new_state = &self.pairs[&new];

            if pair_score(new, new_state).bucket == pair_score(primary, prev).bucket {
                let new_rtt = new_state.smoothed_rtt.unwrap_or_default();
                let margin =
                    PRIMARY_HYSTERESIS_FLOOR.max(prev_rtt.mul_f64(PRIMARY_HYSTERESIS_FRACTION));

                if new_rtt + margin >= prev_rtt {
                    return;
                }
            }
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
