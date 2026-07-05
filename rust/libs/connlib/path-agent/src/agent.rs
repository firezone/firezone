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
pub struct PathAgent {
    locals: Vec<Candidate>,
    remotes: Vec<Candidate>,
    pairs: BTreeMap<(SocketAddr, SocketAddr), PairState>,
    primary: Option<(SocketAddr, SocketAddr)>,

    /// `true` once the first handshake has been taken over — later
    /// inits are re-keys.
    established: bool,

    window: EvaluationWindow,
    responder: Responder,

    outbound_init: Option<OutboundInit>,
    forwarded_response: Option<Vec<u8>>,

    pending_transmits: VecDeque<Transmit>,
    events: VecDeque<Event>,
    events_queued_at: Option<Instant>,

    peer_reflexive_addrs: BTreeSet<SocketAddr>,
}

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
    last_init: Option<Vec<u8>>,
    last_init_path: Option<(SocketAddr, SocketAddr)>,
    dedup: Option<ResponderDedup>,
}

pub(crate) struct PairState {
    pub(crate) kinds: (crate::CandidateKind, crate::CandidateKind),
    pub(crate) local_family_matched: bool,
    pub(crate) smoothed_rtt: Option<Duration>,
    inflight_probe: Option<InflightProbe>,
    /// `None` until `drive_probes` lazy-seeds during the open window.
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
    /// Reset when relay pairs arrive late so `EVALUATION_WINDOW`
    /// doesn't count waiting time.
    started_at: Instant,
}

struct ResponderDedup {
    init_bytes: Vec<u8>,
    response_bytes: Vec<u8>,
    cached_at: Instant,
}

pub const PROBE_INTERVAL: Duration = Duration::from_millis(500);
pub const PROBE_TIMEOUT: Duration = Duration::from_secs(2);
pub const PROBE_INTERVAL_LIVE: Duration = Duration::from_secs(25);
pub const EVALUATION_WINDOW: Duration = Duration::from_secs(10);

pub const RESPONDER_DEDUP_TTL: Duration = Duration::from_secs(10);

const MAX_PEER_REFLEXIVE: usize = 4;

/// Per-kind FIFO cap on remote candidates, bounding `pairs` growth
/// across portal-driven relay rotations.
const MAX_REMOTE_PER_KIND: usize = 6;

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

    /// Returns whether the candidate was newly added (`false` if already known).
    pub fn add_local_candidate(&mut self, c: Candidate) -> bool {
        if self.locals.contains(&c) {
            return false;
        }

        self.locals.push(c);

        for &remote in &self.remotes.clone() {
            self.add_pair(c, remote);
        }

        true
    }

    pub fn add_remote_candidate(&mut self, c: Candidate, now: Instant) {
        // Promote a previously-registered peer-reflexive in place so
        // the existing `PairState` (RTT, inflight probe, schedule)
        // survives.
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

        // Per-kind FIFO cap, bounding `pairs` growth across relay rotations.
        let kind = c.kind();
        let at_cap =
            self.remotes.iter().filter(|r| r.kind() == kind).count() >= MAX_REMOTE_PER_KIND;
        if at_cap {
            let evicted = self.remotes.iter().copied().find(|r| r.kind() == kind);
            if let Some(evicted) = evicted {
                tracing::debug!(?evicted, ?kind, "Evicting oldest remote candidate");
                self.remove_remote_candidate(&evicted, now);
            }
        }

        self.remotes.push(c);

        for &local in &self.locals.clone() {
            self.add_pair(local, c);
        }
    }

    fn add_pair(&mut self, local: Candidate, remote: Candidate) {
        let pair = (local.local(), remote.addr());

        // Cross-family pairs are unusable.
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

    pub fn local_candidates(&self) -> impl Iterator<Item = Candidate> + '_ {
        self.locals.iter().copied()
    }

    pub fn remote_candidates(&self) -> impl Iterator<Item = Candidate> + '_ {
        self.remotes.iter().copied()
    }

    pub fn contains_remote_candidate(&self, c: &Candidate) -> bool {
        self.remotes.contains(c)
    }

    /// Drops locals matching `drop_local` and rebuilds from scratch, preserving
    /// every remote. Re-seeds after a roam or relay replacement.
    pub fn rebuild(&mut self, mut drop_local: impl FnMut(&Candidate) -> bool, now: Instant) {
        let locals: Vec<Candidate> = self
            .locals
            .iter()
            .copied()
            .filter(|c| !drop_local(c))
            .collect();
        let remotes = std::mem::take(&mut self.remotes);

        *self = Self::new();

        for local in locals {
            self.add_local_candidate(local);
        }
        for remote in remotes {
            self.add_remote_candidate(remote, now);
        }
    }

    pub fn primary(&self) -> Option<(SocketAddr, SocketAddr)> {
        self.primary
    }

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

    pub fn remote_is_relayed(&self, addr: SocketAddr) -> bool {
        self.remotes
            .iter()
            .any(|c| c.addr() == addr && c.is_relayed())
    }

    pub fn initiate_handshake(&mut self, tunnel: &mut Tunn, force_resend: bool, now: Instant) {
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

    pub fn handle_outbound(&mut self, bytes: Vec<u8>, now: Instant) {
        match Tunn::parse_incoming_packet(&bytes) {
            Ok(Packet::HandshakeInit(_)) if !self.established => {
                tracing::debug!(bytes = bytes.len(), "Buffered initial HandshakeInit");

                self.forwarded_response = None;
                self.established = true;
                self.store_outbound_init(bytes, now);
            }
            // A still-stored init means the previous one went unanswered:
            // failure evidence. Retry on the incumbent while probes
            // re-evaluate.
            Ok(Packet::HandshakeInit(_))
                if let Some((local, remote)) = self.primary
                    && self.outbound_init.is_some() =>
            {
                tracing::debug!(
                    bytes = bytes.len(),
                    "Unanswered re-key HandshakeInit; restarting probes"
                );

                self.reopen_evaluation_window(now);
                self.pending_transmits.push_back(Transmit {
                    local,
                    remote,
                    payload: Payload::Ciphertext(bytes.clone()),
                });
                self.store_outbound_init(bytes, now);
            }
            // A routine re-key rides the primary without restarting probes.
            Ok(Packet::HandshakeInit(_)) if let Some((local, remote)) = self.primary => {
                tracing::debug!(bytes = bytes.len(), "Re-key HandshakeInit");

                self.pending_transmits.push_back(Transmit {
                    local,
                    remote,
                    payload: Payload::Ciphertext(bytes.clone()),
                });
                self.store_outbound_init(bytes, now);
            }
            // Lost the primary mid-session (roam, candidate retraction):
            // fan out like the initial bootstrap.
            Ok(Packet::HandshakeInit(_)) => {
                tracing::debug!(
                    bytes = bytes.len(),
                    "Re-key HandshakeInit without a primary; fanning out"
                );

                self.reopen_evaluation_window(now);
                self.store_outbound_init(bytes, now);
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

    /// Stores the init until its response arrives.
    ///
    /// With a primary, `drive_handshake_retransmits` stays quiet and the
    /// stored init only tracks whether a response arrived. Without one,
    /// it fans out on the relay pairs like the initial bootstrap.
    fn store_outbound_init(&mut self, bytes: Vec<u8>, now: Instant) {
        self.outbound_init = Some(OutboundInit {
            bytes,
            retransmits: BTreeMap::new(),
            started_at: now,
        });
    }

    /// Handshake bytes run through `tunnel` to authenticate before
    /// any state mutation; dedup hits short-circuit before the call.
    pub fn handle_inbound_network<'b>(
        &mut self,
        tunnel: &mut Tunn,
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

                // Drop dups arriving on multiple pairs in one tick so
                // boringtun doesn't reject as WrongTai64nTimestamp.
                if self.responder.last_init.as_deref() == Some(bytes) {
                    tracing::trace!(local = %path.0, remote = %path.1, "Dropped duplicate inbound HandshakeInit");

                    return ControlFlow::Break(());
                }

                // Source IP must be set so boringtun can emit cookie replies under load.
                let mut buf = [0u8; ip_packet::MAX_FZ_PAYLOAD];
                let outbound = match tunnel.decapsulate_at(Some(path.1.ip()), bytes, &mut buf, now)
                {
                    TunnResult::Done => Vec::new(),
                    TunnResult::WriteToNetwork(response) => vec![response.to_vec()],
                    TunnResult::Err(e) => {
                        tracing::debug!(local = %path.0, remote = %path.1, error = ?e, "Inbound HandshakeInit rejected");
                        return ControlFlow::Break(());
                    }
                    TunnResult::WriteToTunnelV4(_, _) | TunnResult::WriteToTunnelV6(_, _) => {
                        tracing::warn!(local = %path.0, remote = %path.1, "Unexpected data packet from HandshakeInit");
                        return ControlFlow::Break(());
                    }
                };

                // Cookie replies don't establish a session; return them without touching state.
                if let Some(reply) = outbound.first()
                    && matches!(
                        Tunn::parse_incoming_packet(reply),
                        Ok(Packet::PacketCookieReply(_))
                    )
                {
                    tracing::debug!(local = %path.0, remote = %path.1, "Replying with cookie under load");

                    self.pending_transmits.push_back(Transmit {
                        local: path.0,
                        remote: path.1,
                        payload: Payload::Ciphertext(reply.clone()),
                    });

                    return ControlFlow::Break(());
                }

                tracing::debug!(local = %path.0, remote = %path.1, "Inbound HandshakeInit accepted");

                // `handle_outbound` for the response below pairs
                // against `last_init`/`last_init_path`.
                self.responder.last_init = Some(bytes.to_vec());
                self.responder.last_init_path = Some(path);
                // An init on the current primary is a routine re-key. Only an
                // init from a new path (a roam re-keys to a new address)
                // restarts evaluation, even mid-window: the previous window's
                // RTTs are stale and must not keep a now-dead pair as primary.
                // Duplicates were dropped above.
                if self.primary != Some(path) {
                    self.restart_evaluation(now);
                    self.maybe_adopt_handshake_primary(is_handshake, path, now);
                }

                for b in outbound {
                    self.handle_outbound(b, now);
                }

                ControlFlow::Break(())
            }
            Packet::HandshakeResponse(_) => {
                if self.forwarded_response.as_deref() == Some(bytes) {
                    tracing::trace!(local = %path.0, remote = %path.1, "Dropped duplicate HandshakeResponse");

                    return ControlFlow::Break(());
                }

                let mut buf = [0u8; ip_packet::MAX_FZ_PAYLOAD];
                let mut outbound = Vec::<Vec<u8>>::new();
                match tunnel.decapsulate_at(None, bytes, &mut buf, now) {
                    TunnResult::Done => {}
                    TunnResult::WriteToNetwork(first) => {
                        outbound.push(first.to_vec());
                        while let TunnResult::WriteToNetwork(more) =
                            tunnel.decapsulate_at(None, &[], &mut buf, now)
                        {
                            outbound.push(more.to_vec());
                        }
                    }
                    TunnResult::Err(e) => {
                        tracing::debug!(local = %path.0, remote = %path.1, error = ?e, "Inbound HandshakeResponse rejected");
                        return ControlFlow::Break(());
                    }
                    TunnResult::WriteToTunnelV4(_, _) | TunnResult::WriteToTunnelV6(_, _) => {
                        tracing::warn!(local = %path.0, remote = %path.1, "Unexpected data packet from HandshakeResponse");
                        return ControlFlow::Break(());
                    }
                }

                tracing::debug!(local = %path.0, remote = %path.1, "Inbound HandshakeResponse accepted");

                self.outbound_init = None;
                self.forwarded_response = Some(bytes.to_vec());
                // A response on the current primary completes a routine
                // re-key; only one from a new path re-evaluates.
                if self.primary != Some(path) {
                    self.reopen_evaluation_window(now);
                    self.maybe_adopt_handshake_primary(is_handshake, path, now);
                }

                for b in outbound {
                    self.handle_outbound(b, now);
                }

                ControlFlow::Break(())
            }
            Packet::PacketCookieReply(_) | Packet::PacketData(_) => ControlFlow::Continue(bytes),
        }
    }

    /// Debounced restart: no-op while a window is already open, so an
    /// outbound re-key and the inbound response 1 RTT later (or a burst
    /// of candidate changes) don't repeatedly wipe RTTs mid-evaluation.
    fn reopen_evaluation_window(&mut self, now: Instant) {
        if let Some(deadline) = self.window.deadline()
            && now < deadline
        {
            return;
        }

        self.restart_evaluation(now);
    }

    /// Discard every pair's RTT and open a fresh evaluation window.
    ///
    /// A new handshake means the peer's situation changed (e.g. a roam
    /// to a new address), so a stale RTT must not keep an old, now-dead
    /// pair as primary. Unlike [`Self::reopen_evaluation_window`] this
    /// restarts unconditionally, even mid-window — duplicate handshakes
    /// are already filtered out before we get here.
    fn restart_evaluation(&mut self, now: Instant) {
        for state in self.pairs.values_mut() {
            state.smoothed_rtt = None;
            state.inflight_probe = None;
        }

        self.window = EvaluationWindow::Pending;

        self.seed_probe_schedule(now);
    }

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

                // Peer-reflexive discovery for the symmetric-NAT case:
                // the peer reached us from a mapping they didn't
                // advertise.
                if self.peer_reflexive_addrs.len() < MAX_PEER_REFLEXIVE
                    && !self.remotes.iter().any(|c| c.addr() == pair.1)
                {
                    tracing::debug!(
                        local = %pair.0,
                        remote = %pair.1,
                        "Discovered peer-reflexive remote candidate",
                    );
                    self.peer_reflexive_addrs.insert(pair.1);
                    self.add_remote_candidate(Candidate::server_reflexive(pair.1, pair.1), now);
                }
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
        // Wake immediately if a buffered init is waiting on a relay
        // pair that landed after the initial fanout. With a primary, the
        // init rode it directly and there is nothing to fan out.
        let pending_fanout = self
            .outbound_init
            .as_ref()
            .filter(|_| self.primary.is_none())
            .and_then(|i| {
                self.pairs
                    .iter()
                    .any(|(addrs, state)| {
                        state.involves_relay() && !i.retransmits.contains_key(addrs)
                    })
                    .then_some(i.started_at)
            });
        let dedup_expiry = self
            .responder
            .dedup
            .as_ref()
            .map(|d| d.cached_at + RESPONDER_DEDUP_TTL);

        iter::empty()
            .chain(self.events_queued_at)
            .chain(next_retransmit)
            .chain(next_probe)
            .chain(self.window.deadline())
            .chain(pending_fanout)
            .chain(dedup_expiry)
            .min()
    }

    pub fn handle_timeout(&mut self, now: Instant) {
        self.drive_handshake_retransmits(now);
        self.drive_probes(now);
        self.maybe_settle(now);
        self.expire_dedup(now);
    }

    fn expire_dedup(&mut self, now: Instant) {
        if let Some(d) = &self.responder.dedup
            && now.duration_since(d.cached_at) >= RESPONDER_DEDUP_TTL
        {
            self.responder.dedup = None;
        }
    }

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
        // With a primary, the init rode it directly; boringtun's re-key
        // timer is the retry mechanism, not the fanout ladder.
        if self.primary.is_some() {
            return;
        }

        let pending = &mut self.pending_transmits;
        let Some(outbound) = self.outbound_init.as_mut() else {
            return;
        };

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

        // Pairs trickled in after the initial seed get probed
        // immediately while the window is open; pre-handshake stays
        // dormant.
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

            // Hold off while a probe is inflight so a late reply on a
            // high-RTT path can still match by seq.
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

        if let Some(primary) = self.primary
            && let Some(prev) = self.pairs.get(&primary)
        {
            let new_score = pair_score(new, &self.pairs[&new]);
            let prev_score = pair_score(primary, prev);

            if prev_score.bucket < new_score.bucket {
                return;
            }

            if prev_score.bucket == new_score.bucket
                && let Some(prev_rtt) = prev.smoothed_rtt
            {
                let new_rtt = new_score.rtt.unwrap_or_default();
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
