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

/// Iceless path selection for a single WireGuard connection.
#[derive(Default)]
pub struct PathAgent {
    locals: Vec<Candidate>,
    remotes: Vec<Candidate>,
    pairs: BTreeMap<(SocketAddr, SocketAddr), PairState>,
    primary: Option<(SocketAddr, SocketAddr)>,

    /// `true` once a handshake (init or response) has been seen and a WireGuard
    /// session therefore exists, so probes can ride it. Survives a
    /// [`Self::rebuild`] because the session key does.
    has_session: bool,

    /// Buffered `init` fanned out over relay pairs during bootstrap only. Once
    /// established, a re-key rides the primary instead.
    outbound_init: Option<OutboundInit>,

    /// Our own re-keys sent since the last one was answered. The second one
    /// unanswered is WireGuard distress: the primary path is dead.
    unanswered_rekeys: u32,
    /// Distinct peer inits since we last saw peer data. The second with no data
    /// in between means the peer isn't hearing us: the primary path is dead.
    peer_rekeys: u32,

    responder: Responder,
    forwarded_response: Option<Vec<u8>>,

    pending_transmits: VecDeque<Transmit>,
    /// The most recent `now` we saw; [`Self::poll_timeout`] returns it while
    /// transmits are queued so the driver drains them without delay.
    last_now: Option<Instant>,
    events: VecDeque<Event>,
    events_queued_at: Option<Instant>,

    peer_reflexive_addrs: BTreeSet<SocketAddr>,
    next_pair_id: u16,
}

#[derive(Default)]
struct Responder {
    last_init: Option<Vec<u8>>,
    dedup: Option<ResponderDedup>,
}

pub(crate) struct PairState {
    pub(crate) kinds: (crate::CandidateKind, crate::CandidateKind),
    pub(crate) local_family_matched: bool,
    pub(crate) rtt: Option<Rtt>,
    /// Probes awaiting a reply. Several can be outstanding on a high-RTT path
    /// because the burst fires faster than one round trip. Bounded to
    /// [`PROBE_BUDGET`] (oldest dropped first) so a pathless pair probing forever
    /// without replies can't grow it without bound.
    inflight: Vec<InflightProbe>,
    probes: Probes,
    /// Probes fired since the last (re)start. Past [`PROBE_BUDGET`] the pair
    /// goes quiet — unless there is no primary, in which case it hunts forever.
    probes_sent: u32,
    /// Identifies this pair in the ICMP `id` field, so a reply to a pair that
    /// has since been recreated (same addresses, fresh id) is ignored.
    id: u16,
    next_seq: u16,
}

impl PairState {
    /// (Re)opens a probing window: a fresh burst, cleared count, cleared RTT and
    /// no stale inflight probes. The pair re-earns its measurement.
    fn restart(&mut self, at: Instant) {
        self.probes.hunt(at);
        self.probes_sent = 0;
        self.rtt = None;
        self.inflight.clear();
    }

    fn is_probing(&self) -> bool {
        self.probes.due().is_some()
    }

    fn involves_relay(&self) -> bool {
        matches!(self.kinds.0, crate::CandidateKind::Relayed)
            || matches!(self.kinds.1, crate::CandidateKind::Relayed)
    }
}

/// The gaps between a pair's probes: a front-loaded burst then an endless
/// steady interval.
type ProbeGaps =
    iter::Chain<iter::Copied<std::slice::Iter<'static, Duration>>, iter::Repeat<Duration>>;

fn probe_gaps() -> ProbeGaps {
    PROBE_BURST_GAPS
        .iter()
        .copied()
        .chain(iter::repeat(PROBE_INTERVAL))
}

/// A pair's probe schedule. `hunt` (re)starts the burst-then-interval cadence;
/// `stop` ends it (budget spent while a primary exists). The gaps are endless,
/// so a pathless agent keeps probing until WireGuard retires the connection.
struct Probes {
    next: Option<Instant>,
    gaps: ProbeGaps,
}

impl Default for Probes {
    fn default() -> Self {
        Self {
            next: None,
            gaps: probe_gaps(),
        }
    }
}

impl Probes {
    fn hunt(&mut self, at: Instant) {
        self.next = Some(at);
        self.gaps = probe_gaps();
    }

    fn stop(&mut self) {
        self.next = None;
    }

    /// Slow cadence the primary keeps after its discovery budget is spent, so an
    /// idle connection's NAT bindings and tunnel stay alive.
    fn keepalive(&mut self, now: Instant) {
        self.next = Some(now + PRIMARY_KEEPALIVE);
    }

    fn due(&self) -> Option<Instant> {
        self.next
    }

    fn fire(&mut self, now: Instant) {
        let gap = self.gaps.next().expect("probe gaps are endless");
        self.next = Some(now + gap);
    }
}

#[derive(Debug, Clone, Copy)]
pub(crate) struct Rtt {
    pub(crate) smoothed: Duration,
}

#[derive(Debug, Clone, Copy)]
struct InflightProbe {
    seq: u16,
    sent_at: Instant,
}

struct OutboundInit {
    bytes: Vec<u8>,
    /// Relay pairs the current `bytes` have been fanned out to. Cleared when a
    /// boringtun re-init replaces `bytes`, so the fresh init reaches every pair.
    fanned: BTreeSet<(SocketAddr, SocketAddr)>,
    /// One-time fast-retransmit ladder, armed per relay pair on its first
    /// fan-out to win the channel-bind race. Not re-armed on a re-init;
    /// boringtun's own cadence drives retransmission after the head.
    ladder: BTreeMap<(SocketAddr, SocketAddr), PairRetransmit>,
    /// When bootstrap began; wakes `poll_timeout` to fan a relay pair that
    /// arrives after the initial fan-out.
    started_at: Instant,
}

impl OutboundInit {
    fn new(bytes: Vec<u8>, started_at: Instant) -> Self {
        Self {
            bytes,
            fanned: BTreeSet::new(),
            ladder: BTreeMap::new(),
            started_at,
        }
    }
}

struct ResponderDedup {
    init_bytes: Vec<u8>,
    response_bytes: Vec<u8>,
    cached_at: Instant,
}

/// Front-loaded gaps before a pair settles into the steady [`PROBE_INTERVAL`]:
/// short at first so a NAT filter the peer opens moments after our first probe
/// is caught quickly.
pub const PROBE_BURST_GAPS: &[Duration] = &[
    Duration::from_millis(200),
    Duration::from_millis(300),
    Duration::from_millis(500),
];

/// Steady cadence once the burst is spent.
pub const PROBE_INTERVAL: Duration = Duration::from_secs(1);

/// Probes a pair fires before it goes quiet — as long as a primary exists. A
/// punchable path answers within the first attempt or two, so this many
/// unanswered probes is firm evidence it is a dead end. Without a primary the
/// budget does not apply: every pair hunts forever until one is selected.
pub const PROBE_BUDGET: u32 = 12;

/// Cadence the primary keeps probing at once its discovery budget is spent.
/// Iceless runs no WireGuard persistent keepalive, so this lone probe is what
/// keeps an idle primary's NAT bindings and tunnel warm. On a busy connection a
/// single probe every 25s is negligible.
pub const PRIMARY_KEEPALIVE: Duration = Duration::from_secs(25);

/// Repeated re-keys with no progress in between that count as WireGuard
/// distress and clear the primary: our own retransmit going unanswered, or a
/// second distinct peer init with no data in between. The first re-key is
/// ordinary (it may still be answered); the second is the distress signal.
pub const REKEY_DISTRESS_ATTEMPTS: u32 = 2;

pub const RESPONDER_DEDUP_TTL: Duration = Duration::from_secs(10);

const MAX_PEER_REFLEXIVE: usize = 4;

/// Per-kind FIFO cap on remote candidates, bounding `pairs` growth across
/// portal-driven relay rotations.
const MAX_REMOTE_PER_KIND: usize = 6;

const PRIMARY_HYSTERESIS_FRACTION: f64 = 0.2;
const PRIMARY_HYSTERESIS_FLOOR: Duration = Duration::from_millis(10);

impl PathAgent {
    pub fn new() -> Self {
        Self::default()
    }

    /// Returns whether the candidate was newly added (`false` if already known).
    pub fn add_local_candidate(&mut self, c: Candidate, now: Instant) -> bool {
        self.last_now = Some(now);

        if self.locals.contains(&c) {
            return false;
        }

        self.locals.push(c);

        for &remote in &self.remotes.clone() {
            self.add_pair(c, remote, now);
        }

        // A new candidate may offer a better path than the incumbent; re-probe.
        self.clear_and_reprobe(now);

        true
    }

    pub fn add_remote_candidate(&mut self, c: Candidate, now: Instant) {
        self.last_now = Some(now);

        // Promote a previously-registered peer-reflexive in place so the
        // existing `PairState` (RTT, inflight, schedule) survives. Only consume
        // the marker once we actually promote: at registration time the srflx
        // candidate is not in `remotes` yet, so `find` is `None` and we must
        // leave the marker for the later signaled candidate.
        if self.peer_reflexive_addrs.contains(&c.addr())
            && let Some(existing) = self.remotes.iter_mut().find(|x| x.addr() == c.addr())
        {
            tracing::debug!(
                remote = %c.addr(),
                kind = ?c.kind(),
                "Promoting peer-reflexive remote to signaled candidate",
            );
            self.peer_reflexive_addrs.remove(&c.addr());
            *existing = c;
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
            self.add_pair(local, c, now);
        }

        self.clear_and_reprobe(now);
    }

    /// Creates a pair. It probes once there is a session to ride: if one exists
    /// it starts hunting now, otherwise `on_session_established` starts it when
    /// the session appears. Cross-family pairs are unusable.
    fn add_pair(&mut self, local: Candidate, remote: Candidate, now: Instant) {
        let pair = (local.local(), remote.addr());

        if pair.0.is_ipv4() != pair.1.is_ipv4() {
            return;
        }

        let id = self.next_pair_id;
        self.next_pair_id = self.next_pair_id.wrapping_add(1);

        let mut state = PairState {
            kinds: (local.kind(), remote.kind()),
            local_family_matched: local.is_family_matched(),
            rtt: None,
            inflight: Vec::new(),
            probes: Probes::default(),
            probes_sent: 0,
            id,
            next_seq: 0,
        };
        if self.has_session {
            state.restart(now);
        }

        self.pairs.insert(pair, state);
    }

    pub fn remove_local_candidate(&mut self, c: &Candidate, now: Instant) -> bool {
        self.last_now = Some(now);

        let Some(i) = self.locals.iter().position(|x| x == c) else {
            return false;
        };

        let removed = self.locals.remove(i).local();
        self.pairs.retain(|(local, _), _| *local != removed);

        if self.primary.is_some_and(|(local, _)| local == removed) {
            self.clear_and_reprobe(now);
        }

        true
    }

    pub fn remove_remote_candidate(&mut self, c: &Candidate, now: Instant) -> bool {
        self.last_now = Some(now);

        let Some(i) = self.remotes.iter().position(|x| x == c) else {
            return false;
        };

        let removed = self.remotes.remove(i).addr();
        self.pairs.retain(|(_, remote), _| *remote != removed);
        self.peer_reflexive_addrs.remove(&removed);

        if self.primary.is_some_and(|(_, remote)| remote == removed) {
            self.clear_and_reprobe(now);
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
    ///
    /// The session survives (the WireGuard key is kept), so probing resumes as
    /// soon as pairs exist again — no handshake required.
    pub fn rebuild(&mut self, mut drop_local: impl FnMut(&Candidate) -> bool, now: Instant) {
        self.last_now = Some(now);

        let locals: Vec<Candidate> = self
            .locals
            .iter()
            .copied()
            .filter(|c| !drop_local(c))
            .collect();
        let remotes = std::mem::take(&mut self.remotes);
        let had_session = self.has_session;

        *self = Self::new();

        self.has_session = had_session;

        for local in locals {
            self.add_local_candidate(local, now);
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

    pub fn initiate_handshake(&mut self, tunnel: &mut Tunn, now: Instant) {
        self.last_now = Some(now);

        const MAX_SCRATCH_SPACE: usize = 148;

        let mut buf = [0u8; MAX_SCRATCH_SPACE];

        let TunnResult::WriteToNetwork(bytes) =
            tunnel.format_handshake_initiation_at(&mut buf, false, now)
        else {
            tracing::debug!("boringtun declined to emit a HandshakeInit");
            return;
        };

        self.handle_outbound(bytes.to_vec(), now);
    }

    pub fn handle_outbound(&mut self, bytes: Vec<u8>, now: Instant) {
        self.last_now = Some(now);

        match Tunn::parse_incoming_packet(&bytes) {
            // Before a session exists we cannot probe: fan the init out over the
            // relay pairs to bootstrap one. This is the *only* use of the fan-out.
            Ok(Packet::HandshakeInit(_)) if !self.has_session => {
                tracing::debug!(bytes = bytes.len(), "Buffered bootstrap HandshakeInit");
                self.forwarded_response = None;
                match &mut self.outbound_init {
                    // A boringtun re-init: carry the fresh bytes and re-fan them
                    // once to every relay pair. The fast ladder is a one-time
                    // head armed on the first init, so it is not restarted here.
                    Some(init) => {
                        init.bytes = bytes;
                        init.fanned.clear();
                    }
                    None => self.outbound_init = Some(OutboundInit::new(bytes, now)),
                }
            }
            // Established: the re-key rides the primary and counts toward distress.
            Ok(Packet::HandshakeInit(_)) => {
                self.unanswered_rekeys = self.unanswered_rekeys.saturating_add(1);

                if let Some((local, remote)) = self.primary {
                    self.pending_transmits.push_back(Transmit {
                        local,
                        remote,
                        payload: Payload::Ciphertext(bytes),
                    });
                }

                // The second unanswered re-key is WireGuard telling us the path
                // is dead: drop the primary and re-probe. Fire once on the
                // crossing — once the primary is cleared, probing recovers it
                // and the re-key rides the new path; re-firing would flap. The
                // count resets when a response finally lands (see
                // `handle_inbound_network`).
                if self.primary.is_some() && self.unanswered_rekeys == REKEY_DISTRESS_ATTEMPTS {
                    tracing::debug!("Unanswered re-keys; clearing primary and re-probing");
                    self.clear_and_reprobe(now);
                }
            }
            // Handshake responses are sent inline where their init is handled
            // (`handle_inbound_network`), on the init's arrival path, so they
            // never reach here. Data and everything else ride the primary;
            // without one there is nothing to send (WireGuard buffers it and
            // re-sends once a path exists).
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

    /// Handshake bytes run through `tunnel` to authenticate before any state
    /// mutation; dedup hits short-circuit before the call.
    pub fn handle_inbound_network<'b>(
        &mut self,
        tunnel: &mut Tunn,
        bytes: &'b [u8],
        path: (SocketAddr, SocketAddr),
        now: Instant,
    ) -> ControlFlow<(), &'b [u8]> {
        self.last_now = Some(now);

        let Ok(parsed) = Tunn::parse_incoming_packet(bytes) else {
            return ControlFlow::Continue(bytes);
        };

        match parsed {
            // A replayed init is served from the cache without touching boringtun.
            Packet::HandshakeInit(_) if let Some(response) = self.cached_response(bytes, now) => {
                tracing::trace!(local = %path.0, remote = %path.1, "Replaying cached HandshakeResponse");

                let response_bytes = response.to_vec();
                self.pending_transmits.push_back(Transmit {
                    local: path.0,
                    remote: path.1,
                    payload: Payload::Ciphertext(response_bytes),
                });

                ControlFlow::Break(())
            }
            // Drop dups arriving on multiple pairs in one tick so boringtun
            // doesn't reject them as WrongTai64nTimestamp.
            Packet::HandshakeInit(_) if self.responder.last_init.as_deref() == Some(bytes) => {
                tracing::trace!(local = %path.0, remote = %path.1, "Dropped duplicate inbound HandshakeInit");

                ControlFlow::Break(())
            }
            Packet::HandshakeResponse(_) if self.forwarded_response.as_deref() == Some(bytes) => {
                tracing::trace!(local = %path.0, remote = %path.1, "Dropped duplicate HandshakeResponse");

                ControlFlow::Break(())
            }
            Packet::HandshakeInit(_) => {
                let Some(response) = self.decapsulate_init(tunnel, bytes, path, now) else {
                    return ControlFlow::Break(());
                };

                tracing::debug!(local = %path.0, remote = %path.1, "Inbound HandshakeInit accepted");

                let had_session = self.has_session;

                // Remembered so fanned-out duplicates arriving on other pairs in
                // this tick are dropped (see the duplicate-init arm above).
                self.responder.last_init = Some(bytes.to_vec());

                self.register_peer_reflexive(path, now);
                self.on_session_established(now);

                // The init that *establishes* the session hands us a working
                // path for free: it arrived over the relay fan-out (the worst
                // tier), so adopting it as the preliminary primary is sound —
                // probing can only promote away from a relay, never get trapped.
                // Without this the responder stays pathless until its first
                // probe reply and its connection drops inbound data until then.
                //
                // A *mid-session* init (a re-key) is different: it rides the
                // peer's primary, which may be a better tier we haven't validated
                // for our own sending, so it must not move our primary — probing
                // decides. Hence we only adopt on the establishing init.
                if !had_session && self.primary.is_none() && self.pairs.contains_key(&path) {
                    self.set_primary(path, now);
                }

                // Distinct inits with no data in between mean the peer isn't
                // hearing us: WireGuard distress.
                self.peer_rekeys = self.peer_rekeys.saturating_add(1);
                if self.primary.is_some() && self.peer_rekeys == REKEY_DISTRESS_ATTEMPTS {
                    tracing::debug!(local = %path.0, remote = %path.1, "Peer re-keyed without hearing us; clearing primary and re-probing");
                    self.clear_and_reprobe(now);
                }

                // boringtun's response MUST go back on the path the init arrived
                // on, never the primary — otherwise bootstrap (and re-keys)
                // can't complete. Cache it so a retransmitted init is answered
                // from memory without re-decapsulating.
                tracing::debug!(local = %path.0, remote = %path.1, "Sending HandshakeResponse on init's recv path");

                self.responder.dedup = Some(ResponderDedup {
                    init_bytes: bytes.to_vec(),
                    response_bytes: response.clone(),
                    cached_at: now,
                });
                self.pending_transmits.push_back(Transmit {
                    local: path.0,
                    remote: path.1,
                    payload: Payload::Ciphertext(response),
                });

                ControlFlow::Break(())
            }
            Packet::HandshakeResponse(_) => {
                let Some(outbound) = self.decapsulate_response(tunnel, bytes, path, now) else {
                    return ControlFlow::Break(());
                };

                tracing::debug!(local = %path.0, remote = %path.1, "Inbound HandshakeResponse accepted");

                // Our re-key was answered: the path works both ways.
                self.outbound_init = None;
                self.unanswered_rekeys = 0;
                self.forwarded_response = Some(bytes.to_vec());
                self.on_session_established(now);

                // A response is bidirectionally validated, so it is safe to
                // adopt as a (tier-ranked) preliminary primary before probing.
                self.promote_from_handshake(path, now);

                for b in outbound {
                    self.handle_outbound(b, now);
                }

                ControlFlow::Break(())
            }
            // Peer data proves the peer is hearing us: not in distress.
            Packet::PacketData(_) => {
                self.peer_rekeys = 0;
                ControlFlow::Continue(bytes)
            }
            Packet::PacketCookieReply(_) => ControlFlow::Continue(bytes),
        }
    }

    fn cached_response(&self, init: &[u8], now: Instant) -> Option<&[u8]> {
        let d = self.responder.dedup.as_ref()?;

        if now.duration_since(d.cached_at) >= RESPONDER_DEDUP_TTL {
            return None;
        }

        if d.init_bytes != init {
            return None;
        }

        Some(d.response_bytes.as_slice())
    }

    /// Authenticates an inbound init. An init yields at most one packet in
    /// return, so this is `Some(Some(response))` when boringtun wants a
    /// handshake response sent back, or `Some(None)` when it accepts the init
    /// silently. The outer `None` means the packet was fully handled here
    /// (rejected, or answered with a cookie under load) and the caller does
    /// nothing further.
    fn decapsulate_init(
        &mut self,
        tunnel: &mut Tunn,
        bytes: &[u8],
        path: (SocketAddr, SocketAddr),
        now: Instant,
    ) -> Option<Vec<u8>> {
        let mut buf = [0u8; ip_packet::MAX_FZ_PAYLOAD];
        let reply = match tunnel.decapsulate_at(Some(path.1.ip()), bytes, &mut buf, now) {
            TunnResult::Done => return None,
            TunnResult::WriteToNetwork(response) => response,
            TunnResult::Err(e) => {
                tracing::debug!(local = %path.0, remote = %path.1, error = ?e, "Inbound HandshakeInit rejected");
                return None;
            }
            TunnResult::WriteToTunnelV4(_, _) | TunnResult::WriteToTunnelV6(_, _) => {
                tracing::warn!(local = %path.0, remote = %path.1, "Unexpected data packet from HandshakeInit");
                return None;
            }
        };

        // Cookie replies don't establish a session; send them without touching state.
        if matches!(
            Tunn::parse_incoming_packet(reply),
            Ok(Packet::PacketCookieReply(_))
        ) {
            tracing::debug!(local = %path.0, remote = %path.1, "Replying with cookie under load");

            self.pending_transmits.push_back(Transmit {
                local: path.0,
                remote: path.1,
                payload: Payload::Ciphertext(reply.to_vec()),
            });

            return None;
        }

        Some(reply.to_vec())
    }

    /// Authenticates an inbound response, returning the packets boringtun wants
    /// to send afterwards (e.g. queued data). `None` means it was rejected.
    fn decapsulate_response(
        &mut self,
        tunnel: &mut Tunn,
        bytes: &[u8],
        path: (SocketAddr, SocketAddr),
        now: Instant,
    ) -> Option<Vec<Vec<u8>>> {
        let mut buf = [0u8; ip_packet::MAX_FZ_PAYLOAD];
        let mut outbound = Vec::<Vec<u8>>::new();
        match tunnel.decapsulate_at(Some(path.1.ip()), bytes, &mut buf, now) {
            TunnResult::Done => {}
            TunnResult::WriteToNetwork(first) => {
                outbound.push(first.to_vec());
                while let TunnResult::WriteToNetwork(more) =
                    tunnel.decapsulate_at(Some(path.1.ip()), &[], &mut buf, now)
                {
                    outbound.push(more.to_vec());
                }
            }
            TunnResult::Err(e) => {
                tracing::debug!(local = %path.0, remote = %path.1, error = ?e, "Inbound HandshakeResponse rejected");
                return None;
            }
            TunnResult::WriteToTunnelV4(_, _) | TunnResult::WriteToTunnelV6(_, _) => {
                tracing::warn!(local = %path.0, remote = %path.1, "Unexpected data packet from HandshakeResponse");
                return None;
            }
        }

        Some(outbound)
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
        self.last_now = Some(now);

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

                self.register_peer_reflexive(pair, now);

                // Triggered check (cf. RFC 8445 §7.3.1.4): the inbound probe
                // proves the reverse filter is open now, so probing back
                // completes the punch. Only for a pair we've gone quiet on
                // without measuring — one we're already probing would ping-pong.
                if let Some(state) = self.pairs.get_mut(&pair)
                    && !state.is_probing()
                    && state.rtt.is_none()
                {
                    state.restart(now);
                }
            }
            crate::icmpv6::Echo::Reply => {
                let Some(state) = self.pairs.get_mut(&pair) else {
                    return ControlFlow::Break(());
                };
                // The id is scoped to the pair: a reply carrying a stale id
                // (a pair recreated at the same address) is not ours.
                if probe.id != state.id {
                    return ControlFlow::Break(());
                }
                let Some(i) = state.inflight.iter().position(|p| p.seq == probe.seq) else {
                    return ControlFlow::Break(());
                };

                let inflight = state.inflight.remove(i);
                let rtt = now.saturating_duration_since(inflight.sent_at);

                state.rtt = Some(Rtt {
                    smoothed: match state.rtt {
                        None => rtt,
                        Some(prev) => (prev.smoothed + rtt) / 2,
                    },
                });

                tracing::trace!(local = %pair.0, remote = %pair.1, ?rtt, "Probe reply received");

                // A probe reply is bidirectionally validated: it may promote.
                self.select_primary(now);
            }
        }
        ControlFlow::Break(())
    }

    pub fn poll_timeout(&self) -> Option<Instant> {
        let next_retransmit = self
            .outbound_init
            .as_ref()
            .filter(|_| !self.has_session)
            .and_then(|i| i.ladder.values().filter_map(|r| r.next_fire_at).min());
        // Probes wait for the first handshake exchange; see `drive_probes`.
        let next_probe = self
            .has_session
            .then(|| self.pairs.values().filter_map(|s| s.probes.due()).min())
            .flatten();
        // Wake immediately if a buffered bootstrap init is waiting on a relay
        // pair that landed after the initial fanout.
        let pending_fanout = self
            .outbound_init
            .as_ref()
            .filter(|_| !self.has_session)
            .and_then(|i| {
                self.pairs
                    .iter()
                    .any(|(addrs, state)| state.involves_relay() && !i.fanned.contains(addrs))
                    .then_some(i.started_at)
            });
        let dedup_expiry = self
            .responder
            .dedup
            .as_ref()
            .map(|d| d.cached_at + RESPONDER_DEDUP_TTL);

        let pending_transmit = (!self.pending_transmits.is_empty())
            .then_some(self.last_now)
            .flatten();

        iter::empty()
            .chain(pending_transmit)
            .chain(self.events_queued_at)
            .chain(next_retransmit)
            .chain(next_probe)
            .chain(pending_fanout)
            .chain(dedup_expiry)
            .min()
    }

    pub fn handle_timeout(&mut self, now: Instant) {
        self.last_now = Some(now);

        self.drive_bootstrap_fanout(now);
        self.drive_probes(now);
        self.expire_dedup(now);
    }

    fn expire_dedup(&mut self, now: Instant) {
        if let Some(d) = &self.responder.dedup
            && now.duration_since(d.cached_at) >= RESPONDER_DEDUP_TTL
        {
            self.responder.dedup = None;
        }
    }

    /// Fans the buffered init out over relay pairs — bootstrap only. Once
    /// established the re-key rides the primary, and a distress-cleared primary
    /// is recovered by probing over the still-valid session, not a fan-out.
    fn drive_bootstrap_fanout(&mut self, now: Instant) {
        if self.has_session {
            return;
        }

        let pending = &mut self.pending_transmits;
        let Some(outbound) = self.outbound_init.as_mut() else {
            return;
        };

        // Relay pairs the current init hasn't reached yet: every pair on the
        // first init, every pair again on a re-init (`fanned` was cleared), plus
        // any relay pair that arrives mid-bootstrap.
        let unfanned: Vec<_> = self
            .pairs
            .iter()
            .filter(|(addrs, state)| state.involves_relay() && !outbound.fanned.contains(*addrs))
            .map(|(addrs, _)| *addrs)
            .collect();

        for (local, remote) in unfanned {
            tracing::debug!(%local, %remote, "Fanning out HandshakeInit on relay pair");

            pending.push_back(Transmit {
                local,
                remote,
                payload: Payload::Ciphertext(outbound.bytes.clone()),
            });
            outbound.fanned.insert((local, remote));
            // Arm the one-time fast head the first time we send to this pair; a
            // pair already laddered keeps its (spent) entry, so a re-init does
            // not restart it.
            outbound
                .ladder
                .entry((local, remote))
                .or_insert_with(|| PairRetransmit::new(now));
        }

        for ((local, remote), state) in outbound.ladder.iter_mut() {
            let Some(fire_at) = state.next_fire_at else {
                continue;
            };
            if now >= fire_at {
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

    fn drive_probes(&mut self, now: Instant) {
        // Probes ride the session; encapsulating before the first handshake
        // would make boringtun queue them and initiate handshakes on its own.
        if !self.has_session {
            return;
        }

        let primary = self.primary;
        let pending = &mut self.pending_transmits;

        for ((local, remote), state) in self.pairs.iter_mut() {
            let Some(deadline) = state.probes.due() else {
                continue;
            };
            if now < deadline {
                continue;
            }

            let seq = state.next_seq;
            state.next_seq = state.next_seq.wrapping_add(1);
            state.inflight.push(InflightProbe { seq, sent_at: now });
            // A pathless pair hunts forever; without a reply to drain them, cap
            // the outstanding set at one budget's worth by forgetting the oldest.
            // A reply that late no longer matters for path selection.
            if state.inflight.len() > PROBE_BUDGET as usize {
                state.inflight.remove(0);
            }
            state.probes_sent = state.probes_sent.saturating_add(1);

            tracing::trace!(%local, %remote, seq, "Probe send");

            pending.push_back(Transmit {
                local: *local,
                remote: *remote,
                payload: Payload::Plaintext(Box::new(crate::icmpv6::build_echo_request(
                    state.id, seq,
                ))),
            });

            // Within the discovery budget — or while we have no path at all —
            // keep the fast burst-then-interval cadence.
            if primary.is_none() || state.probes_sent < PROBE_BUDGET {
                state.probes.fire(now);
                continue;
            }

            // The primary keepalives; every other pair goes quiet.
            if primary == Some((*local, *remote)) {
                state.probes.keepalive(now);
                continue;
            }

            state.probes.stop();
        }
    }

    fn clear_and_reprobe(&mut self, now: Instant) {
        let former = self.primary.take();
        // Before a session exists there is nothing to probe;
        // `on_session_established` starts every pair once one appears.
        if !self.has_session {
            return;
        }

        for (pair, state) in self.pairs.iter_mut() {
            let discovering = state.probes.due().is_some() && state.probes_sent < PROBE_BUDGET;
            if Some(*pair) == former || !discovering {
                state.restart(now);
            }
        }
    }

    fn register_peer_reflexive(&mut self, pair: (SocketAddr, SocketAddr), now: Instant) {
        // The peer reached us from a mapping they didn't advertise (symmetric
        // NAT). Registering it is a new candidate, which re-probes.
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

    fn on_session_established(&mut self, now: Instant) {
        if self.has_session {
            return;
        }
        self.has_session = true;
        // Bootstrap is over; a re-key now rides the primary, not the fan-out.
        self.outbound_init = None;
        // Every pair was created without a schedule (probing waits for a
        // session); now that we have one, start them all hunting.
        for state in self.pairs.values_mut() {
            state.restart(now);
        }
    }

    /// A handshake proves its path works both ways but carries no RTT, so it can
    /// only seed or improve the primary *by tier* — never displace a
    /// better-tier incumbent.
    fn promote_from_handshake(&mut self, path: (SocketAddr, SocketAddr), now: Instant) {
        if !self.pairs.contains_key(&path) {
            return;
        }
        match self.primary {
            None => self.set_primary(path, now),
            Some(primary) if primary != path => {
                let new = pair_score(path, &self.pairs[&path]);
                let cur = pair_score(primary, &self.pairs[&primary]);
                if new.bucket < cur.bucket {
                    self.set_primary(path, now);
                }
            }
            Some(_) => {}
        }
    }

    /// Runs on every probe reply. Probes can only *promote*: the best measured
    /// pair takes over an empty primary, or displaces the incumbent only when it
    /// scores strictly better (a better tier, or the same tier by a clear RTT
    /// margin). A worse pair never demotes a working primary.
    fn select_primary(&mut self, now: Instant) {
        let Some(best) = self
            .pairs
            .iter()
            .filter(|(_, s)| s.rtt.is_some())
            .min_by_key(|(k, s)| pair_score(**k, s))
            .map(|(k, _)| *k)
        else {
            return;
        };

        let Some(primary) = self.primary else {
            self.set_primary(best, now);
            return;
        };

        if best == primary {
            return;
        }

        let new = pair_score(best, &self.pairs[&best]);
        let cur = pair_score(primary, &self.pairs[&primary]);

        if new.bucket < cur.bucket {
            self.set_primary(best, now);
            return;
        }

        // Same bucket: only switch on a clear RTT win, so jitter between two
        // live same-tier pairs doesn't flap the primary.
        if new.bucket == cur.bucket
            && let Some(cur_rtt) = self.pairs[&primary].rtt
        {
            let new_rtt = self.pairs[&best]
                .rtt
                .map(|r| r.smoothed)
                .unwrap_or_default();
            let margin =
                PRIMARY_HYSTERESIS_FLOOR.max(cur_rtt.smoothed.mul_f64(PRIMARY_HYSTERESIS_FRACTION));
            if new_rtt + margin < cur_rtt.smoothed {
                self.set_primary(best, now);
            }
        }
    }

    fn set_primary(&mut self, path: (SocketAddr, SocketAddr), now: Instant) {
        let from = self.primary;
        self.primary = Some(path);

        // Distress is measured per primary: a fresh one starts with a clean
        // slate so a count that climbed on a previous (or no) primary — e.g.
        // while pathless — can't leak in and trip `== REKEY_DISTRESS_ATTEMPTS`
        // on the wrong path.
        self.unanswered_rekeys = 0;
        self.peer_rekeys = 0;

        tracing::debug!(?from, local = %path.0, remote = %path.1, "Iceless primary changed");

        self.queue_event(
            Event::PrimaryChanged {
                local: path.0,
                remote: path.1,
            },
            now,
        );
    }

    fn queue_event(&mut self, event: Event, now: Instant) {
        self.events.push_back(event);
        self.events_queued_at = self.events_queued_at.or(Some(now));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::CandidateKind;

    #[test]
    fn inflight_probes_stay_capped_while_hunting_forever() {
        let mut a = PathAgent {
            has_session: true,
            ..Default::default()
        };

        let pair: (SocketAddr, SocketAddr) = (
            "127.0.0.1:1".parse().unwrap(),
            "127.0.0.1:2".parse().unwrap(),
        );
        let t0 = Instant::now();
        let mut state = PairState {
            kinds: (CandidateKind::Host, CandidateKind::Host),
            local_family_matched: true,
            rtt: None,
            inflight: Vec::new(),
            probes: Probes::default(),
            probes_sent: 0,
            id: 0,
            next_seq: 0,
        };
        state.restart(t0);
        a.pairs.insert(pair, state);

        // No primary, so the pair hunts forever. Drive many probe rounds without
        // ever replying, which would otherwise let `inflight` grow unbounded.
        let mut now = t0;
        for _ in 0..100 {
            a.handle_timeout(now);
            a.pending_transmits.clear();
            now += PROBE_INTERVAL;
        }

        assert!(a.primary.is_none());
        assert!(
            a.pairs[&pair].probes_sent > PROBE_BUDGET * 2,
            "the pair kept probing past its budget while pathless",
        );
        assert!(
            a.pairs[&pair].inflight.len() <= PROBE_BUDGET as usize,
            "inflight probes must stay bounded when hunting forever, got {}",
            a.pairs[&pair].inflight.len(),
        );
    }
}
