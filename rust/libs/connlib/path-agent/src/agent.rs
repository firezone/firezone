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

    /// `true` once a handshake has been accepted from the peer. Probes ride
    /// the session, so they wait for this; it survives a [`Self::rebuild`]
    /// because the session does, too.
    established: bool,

    responder: Responder,

    outbound_init: Option<OutboundInit>,
    /// Consecutive re-key retransmits of our own that went unanswered. Reset
    /// when a response clears `outbound_init` or a fresh fanout starts.
    unanswered_rekeys: u32,
    /// Distinct accepted inbound inits since we last saw peer data. Reset by any
    /// inbound data packet, which proves the peer is hearing us.
    peer_rekeys: u32,
    forwarded_response: Option<Vec<u8>>,

    pending_transmits: VecDeque<Transmit>,
    events: VecDeque<Event>,
    events_queued_at: Option<Instant>,

    peer_reflexive_addrs: BTreeSet<SocketAddr>,
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
    pub(crate) rtt: Option<Rtt>,
    /// Probes awaiting their reply. Several can be outstanding on a
    /// high-RTT path because the burst fires faster than one round trip.
    inflight_probes: Vec<InflightProbe>,
    probes: Probes,
    /// Positive RTT samples collected since the last (re)start. Once this
    /// reaches [`PROBE_SAMPLES`] the pair has settled and stops probing.
    samples: u32,
    /// When the current probing window opened, for the give-up bound.
    probing_since: Option<Instant>,
    next_probe_seq: u16,
}

impl PairState {
    /// (Re)opens a probing window: a fresh burst, a fresh sample count, and a
    /// cleared RTT — so the pair earns a new measurement rather than carrying a
    /// stale one. It probes until it settles, or (once we have a path) gives up.
    fn restart_probes(&mut self, at: Instant) {
        self.probes.hunt(at);
        self.samples = 0;
        self.probing_since = Some(at);
        self.rtt = None;
    }

    /// Drops the pair's data and stops probing it. Used when a settled pair
    /// isn't the primary, or a pair gives up — either way we keep no stale RTT
    /// around, which is what lets selection skip a freshness check.
    fn retire(&mut self) {
        self.probes.stop();
        self.rtt = None;
    }

    /// Keeps the pair on the slow keepalive cadence (it's the primary).
    fn keep_fresh(&mut self, now: Instant) {
        self.probes.keepalive(now);
    }

    fn is_settled(&self) -> bool {
        self.samples >= PROBE_SAMPLES
    }

    /// Whether this pair has probed past the give-up bound without settling.
    fn gave_up(&self, now: Instant) -> bool {
        self.probing_since
            .is_some_and(|since| now.duration_since(since) >= PROBE_GIVE_UP)
    }

    fn record_sample(&mut self) {
        self.samples = self.samples.saturating_add(1);
    }
}

/// The gaps between a pair's probes: a front-loaded burst followed by an
/// endless steady interval.
type ProbeGaps =
    iter::Chain<iter::Copied<std::slice::Iter<'static, Duration>>, iter::Repeat<Duration>>;

const NO_BURST: &[Duration] = &[];

fn probe_gaps(burst: &'static [Duration], steady: Duration) -> ProbeGaps {
    burst.iter().copied().chain(iter::repeat(steady))
}

/// A pair's probe schedule. In its `hunt` phase it front-loads a burst then
/// settles to [`PROBE_INTERVAL`]; the primary switches to the slow
/// [`PROBE_KEEPALIVE`] cadence via `keepalive`. `stop` ends it (settled loser,
/// or given up). The gaps are endless, so an unanswered pair keeps probing
/// until WireGuard, the liveness authority, retires the connection.
struct Probes {
    /// Next probe deadline. `None` when the pair isn't probing.
    next: Option<Instant>,
    gaps: ProbeGaps,
}

impl Default for Probes {
    fn default() -> Self {
        Self {
            next: None,
            gaps: probe_gaps(PROBE_BURST_GAPS, PROBE_INTERVAL),
        }
    }
}

impl Probes {
    /// (Re)starts the burst-then-interval hunt at `at`.
    fn hunt(&mut self, at: Instant) {
        self.next = Some(at);
        self.gaps = probe_gaps(PROBE_BURST_GAPS, PROBE_INTERVAL);
    }

    /// Switches to the slow keepalive cadence, next probe one interval out.
    fn keepalive(&mut self, now: Instant) {
        self.next = Some(now + PROBE_KEEPALIVE);
        self.gaps = probe_gaps(NO_BURST, PROBE_KEEPALIVE);
    }

    /// Stops probing.
    fn stop(&mut self) {
        self.next = None;
    }

    /// The next scheduled probe, if the pair is still probing.
    fn due(&self) -> Option<Instant> {
        self.next
    }

    /// Records that the due probe fired at `now` and schedules the next one.
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
    retransmits: BTreeMap<(SocketAddr, SocketAddr), PairRetransmit>,
    /// Reset when relay pairs arrive late so waiting time doesn't count
    /// against the retransmit ladder.
    started_at: Instant,
}

impl OutboundInit {
    fn new(bytes: Vec<u8>, started_at: Instant) -> Self {
        Self {
            bytes,
            retransmits: BTreeMap::new(),
            started_at,
        }
    }
}

struct ResponderDedup {
    init_bytes: Vec<u8>,
    response_bytes: Vec<u8>,
    cached_at: Instant,
}

/// Front-loaded gaps at the start of a pair's probing, before it settles into
/// the steady [`PROBE_INTERVAL`] cadence: short at first so a NAT filter the
/// peer opens moments after our first probe is caught quickly.
pub const PROBE_BURST_GAPS: &[Duration] = &[
    Duration::from_millis(200),
    Duration::from_millis(300),
    Duration::from_millis(500),
];

/// Inflight probes older than this are forgotten; a reply that late is not
/// meaningful anymore.
pub const PROBE_TIMEOUT: Duration = Duration::from_secs(2);

/// Steady cadence a pair falls back to once its front-loaded burst is spent,
/// while it is still trying to settle (or hunting a path that never answers).
pub const PROBE_INTERVAL: Duration = Duration::from_secs(1);

/// Positive RTT samples a pair collects before it settles and stops probing.
///
/// An answered pair reaches this and goes quiet. A handful of samples is enough
/// for the smoothed RTT to be a fair basis for selection without spending
/// probes forever.
pub const PROBE_SAMPLES: u32 = 5;

/// How long a pair keeps probing without settling once we already have a
/// primary, before it gives up.
///
/// While we have no path we hunt every pair indefinitely (bounded only by
/// WireGuard retiring the connection). But once a path exists, a pair that
/// won't settle is a dead end — e.g. a direct pair that can never punch a
/// symmetric NAT — and probing it forever is pure waste, so we stop.
pub const PROBE_GIVE_UP: Duration = Duration::from_secs(10);

/// Slow cadence the primary keeps after it settles, so its RTT stays current
/// for the next comparison and its NAT mapping warm. This is what lets us drop
/// a time-based freshness check: the primary is the only long-lived pair, and
/// it is never stale.
pub const PROBE_KEEPALIVE: Duration = Duration::from_secs(5);

/// Repeated re-keys — our own retransmits going unanswered, or distinct peer
/// inits with no data in between — that count as WireGuard distress and trigger
/// a path re-evaluation.
///
/// Counting rather than timing decouples the signal from boringtun's now-tunable
/// `REKEY_TIMEOUT` retry pacing. A single stray re-key is ordinary loss; a
/// second one with no progress in between is the peer (or us) stuck on a dead
/// path. Routine re-keys never reach the threshold because data flows between
/// them, resetting the count.
pub const REKEY_DISTRESS_ATTEMPTS: u32 = 2;

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
            responder: Responder::default(),
            outbound_init: None,
            unanswered_rekeys: 0,
            peer_rekeys: 0,
            forwarded_response: None,
            pending_transmits: VecDeque::new(),
            events: VecDeque::new(),
            events_queued_at: None,
            peer_reflexive_addrs: BTreeSet::new(),
        }
    }

    /// Returns whether the candidate was newly added (`false` if already known).
    pub fn add_local_candidate(&mut self, c: Candidate, now: Instant) -> bool {
        if self.locals.contains(&c) {
            return false;
        }

        self.locals.push(c);

        for &remote in &self.remotes.clone() {
            self.add_pair(c, remote, now);
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
            self.add_pair(local, c, now);
        }

        // Candidate arrival hints that the current primary may be dead: the
        // most common reason for new candidates mid-session is that the peer
        // roamed away from the address our primary points at. Re-probe the
        // primary and re-measure it: `restart_probes` clears its RTT, so if it
        // is dead it drops out of selection and a fresh pair takes over; if it
        // is alive its new measurement keeps it winning on bucket.
        if let Some(primary) = self.primary
            && let Some(state) = self.pairs.get_mut(&primary)
        {
            state.restart_probes(now);
        }
    }

    /// Every new pair immediately probes in a burst, regardless of any other
    /// state: candidates are the only signal about new paths we get.
    fn add_pair(&mut self, local: Candidate, remote: Candidate, burst_at: Instant) {
        let pair = (local.local(), remote.addr());

        // Cross-family pairs are unusable.
        if pair.0.is_ipv4() != pair.1.is_ipv4() {
            return;
        }

        let mut state = PairState {
            kinds: (local.kind(), remote.kind()),
            local_family_matched: local.is_family_matched(),
            rtt: None,
            inflight_probes: Vec::new(),
            probes: Probes::default(),
            samples: 0,
            probing_since: None,
            next_probe_seq: 0,
        };
        state.restart_probes(burst_at);

        self.pairs.insert(pair, state);
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
            self.probe_all_pairs(now);
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
            self.probe_all_pairs(now);
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
    /// The session survives a rebuild (the WireGuard key is kept), so probing
    /// resumes as soon as pairs exist again — no handshake required.
    pub fn rebuild(&mut self, mut drop_local: impl FnMut(&Candidate) -> bool, now: Instant) {
        let locals: Vec<Candidate> = self
            .locals
            .iter()
            .copied()
            .filter(|c| !drop_local(c))
            .collect();
        let remotes = std::mem::take(&mut self.remotes);
        let established = self.established;
        let peer_rekeys = self.peer_rekeys;

        *self = Self::new();

        self.established = established;
        self.peer_rekeys = peer_rekeys;

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
        match (
            Tunn::parse_incoming_packet(&bytes),
            &mut self.outbound_init,
            self.primary,
        ) {
            (Ok(Packet::HandshakeInit(_)), outbound_init @ None, _) if !self.established => {
                tracing::debug!(bytes = bytes.len(), "Buffered initial HandshakeInit");

                self.forwarded_response = None;
                outbound_init.replace(OutboundInit::new(bytes, now));
            }
            // A still-stored init means the previous one went unanswered:
            // WireGuard-level failure evidence. Always retry on the incumbent;
            // only re-evaluate once enough retransmits have piled up unanswered.
            (Ok(Packet::HandshakeInit(_)), outbound_init @ Some(_), Some((local, remote))) => {
                let bytes_len = bytes.len();

                outbound_init.replace(OutboundInit::new(bytes.clone(), now));
                self.pending_transmits.push_back(Transmit {
                    local,
                    remote,
                    payload: Payload::Ciphertext(bytes),
                });

                self.unanswered_rekeys = self.unanswered_rekeys.saturating_add(1);

                // A lone unanswered retransmit can be ordinary loss. Only once
                // the peer has ignored `REKEY_DISTRESS_ATTEMPTS` of them do we
                // treat the path as dead and drop the primary pointer: with no
                // primary to protect the bucket veto lifts and the first pair to
                // answer wins — even a worse bucket, so we fail over from a
                // direct path to a relayed one if that is all that works.
                if self.unanswered_rekeys >= REKEY_DISTRESS_ATTEMPTS {
                    tracing::debug!(bytes = bytes_len, "Unanswered re-keys; re-evaluating paths");

                    self.primary = None;
                    self.probe_all_pairs(now);
                    self.select_primary(now);
                } else {
                    tracing::debug!(
                        bytes = bytes_len,
                        "Unanswered re-key; retrying on incumbent"
                    );
                }
            }
            // A routine re-key rides the primary without restarting probes.
            (Ok(Packet::HandshakeInit(_)), outbound_init @ None, Some((local, remote))) => {
                tracing::debug!(bytes = bytes.len(), "Re-key HandshakeInit");

                outbound_init.replace(OutboundInit::new(bytes.clone(), now));
                self.pending_transmits.push_back(Transmit {
                    local,
                    remote,
                    payload: Payload::Ciphertext(bytes),
                });
            }
            // Lost the primary mid-session (roam, candidate retraction):
            // fan out like the initial bootstrap, with probes racing it.
            (Ok(Packet::HandshakeInit(_)), outbound_init, None) => {
                tracing::debug!(
                    bytes = bytes.len(),
                    "Re-key HandshakeInit without a primary; fanning out"
                );

                outbound_init.replace(OutboundInit::new(bytes, now));
                self.unanswered_rekeys = 0;
                self.probe_all_pairs(now);
            }
            (Ok(Packet::HandshakeResponse(_)), _, _) => {
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
                }
            }
            // Probes and data ride the primary; nothing to send without one.
            (_, _, Some((local, remote))) => {
                self.pending_transmits.push_back(Transmit {
                    local,
                    remote,
                    payload: Payload::Ciphertext(bytes),
                });
            }
            (_, _, None) => {}
        }
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

        match (parsed, self.primary) {
            // Replays and duplicates short-circuit before touching the session.
            //
            // A replayed init is served from the cache without touching boringtun.
            (Packet::HandshakeInit(_), _)
                if let Some(response) = self.cached_response(bytes, now) =>
            {
                tracing::trace!(local = %path.0, remote = %path.1, "Replaying cached HandshakeResponse");

                let response_bytes = response.to_vec();
                self.pending_transmits.push_back(Transmit {
                    local: path.0,
                    remote: path.1,
                    payload: Payload::Ciphertext(response_bytes),
                });

                ControlFlow::Break(())
            }
            // Drop dups arriving on multiple pairs in one tick so
            // boringtun doesn't reject as WrongTai64nTimestamp.
            (Packet::HandshakeInit(_), _) if self.responder.last_init.as_deref() == Some(bytes) => {
                tracing::trace!(local = %path.0, remote = %path.1, "Dropped duplicate inbound HandshakeInit");

                ControlFlow::Break(())
            }
            (Packet::HandshakeResponse(_), _)
                if self.forwarded_response.as_deref() == Some(bytes) =>
            {
                tracing::trace!(local = %path.0, remote = %path.1, "Dropped duplicate HandshakeResponse");

                ControlFlow::Break(())
            }
            // Accepts: authenticate, then adopt or re-evaluate.
            (Packet::HandshakeInit(_), primary) => {
                let Some(outbound) = self.decapsulate_init(tunnel, bytes, path, now) else {
                    return ControlFlow::Break(());
                };

                tracing::debug!(local = %path.0, remote = %path.1, "Inbound HandshakeInit accepted");

                // `handle_outbound` for the response below pairs
                // against `last_init`/`last_init_path`.
                self.responder.last_init = Some(bytes.to_vec());
                self.responder.last_init_path = Some(path);

                self.register_peer_reflexive(path, now);
                self.established = true;

                // A re-key with peer data flowing in between is routine (the
                // count was reset by that data). Several distinct inits with no
                // data between them mean the peer isn't hearing our responses or
                // data — its passive-keepalive escalation formats a new init
                // every few seconds. Duplicates of the same init were dropped
                // above, so every increment here is a genuinely new attempt.
                self.peer_rekeys = self.peer_rekeys.saturating_add(1);
                if self.peer_rekeys >= REKEY_DISTRESS_ATTEMPTS {
                    tracing::debug!(local = %path.0, remote = %path.1, "Peer re-keyed without hearing us; re-evaluating paths");

                    // Same as an unanswered outbound re-key: the peer isn't
                    // hearing us on the current primary, so drop the pointer and
                    // let the bucket veto lift for a clean failover.
                    self.primary = None;
                    self.probe_all_pairs(now);
                    self.select_primary(now);
                }

                if primary.is_none() {
                    self.set_primary(path, now);
                }

                for b in outbound {
                    self.handle_outbound(b, now);
                }

                ControlFlow::Break(())
            }
            (Packet::HandshakeResponse(_), primary) => {
                let Some(outbound) = self.decapsulate_response(tunnel, bytes, path, now) else {
                    return ControlFlow::Break(());
                };

                tracing::debug!(local = %path.0, remote = %path.1, "Inbound HandshakeResponse accepted");

                self.outbound_init = None;
                self.unanswered_rekeys = 0;
                self.forwarded_response = Some(bytes.to_vec());
                self.established = true;

                if primary.is_none() {
                    self.set_primary(path, now);
                }

                for b in outbound {
                    self.handle_outbound(b, now);
                }

                ControlFlow::Break(())
            }
            // Peer data proves the peer is hearing us, so the connection isn't
            // in distress: clear the re-key counter that would otherwise build
            // toward a false failover.
            (Packet::PacketData(_), _) => {
                self.peer_rekeys = 0;
                ControlFlow::Continue(bytes)
            }
            (Packet::PacketCookieReply(_), _) => ControlFlow::Continue(bytes),
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

    /// Authenticates an inbound init, returning the packets boringtun wants
    /// to send in response. `None` means the packet was fully handled
    /// (rejected, or answered with a cookie under load).
    fn decapsulate_init(
        &mut self,
        tunnel: &mut Tunn,
        bytes: &[u8],
        path: (SocketAddr, SocketAddr),
        now: Instant,
    ) -> Option<Vec<Vec<u8>>> {
        // Source IP must be set so boringtun can emit cookie replies under load.
        let mut buf = [0u8; ip_packet::MAX_FZ_PAYLOAD];
        let outbound = match tunnel.decapsulate_at(Some(path.1.ip()), bytes, &mut buf, now) {
            TunnResult::Done => Vec::new(),
            TunnResult::WriteToNetwork(response) => vec![response.to_vec()],
            TunnResult::Err(e) => {
                tracing::debug!(local = %path.0, remote = %path.1, error = ?e, "Inbound HandshakeInit rejected");
                return None;
            }
            TunnResult::WriteToTunnelV4(_, _) | TunnResult::WriteToTunnelV6(_, _) => {
                tracing::warn!(local = %path.0, remote = %path.1, "Unexpected data packet from HandshakeInit");
                return None;
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

            return None;
        }

        Some(outbound)
    }

    /// Authenticates an inbound response, returning the packets boringtun
    /// wants to send afterwards (e.g. queued data). `None` means the packet
    /// was rejected.
    fn decapsulate_response(
        &mut self,
        tunnel: &mut Tunn,
        bytes: &[u8],
        path: (SocketAddr, SocketAddr),
        now: Instant,
    ) -> Option<Vec<Vec<u8>>> {
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

                // Triggered check (cf. RFC 8445, section 7.3.1.4): the
                // inbound probe proves the reverse NAT filter is open right
                // now, so probing back completes the hole punch in one round
                // trip. Only for pairs we haven't measured — probing back one
                // we already track would ping-pong bursts between the peers.
                if let Some(state) = self.pairs.get_mut(&pair)
                    && state.rtt.is_none()
                {
                    state.restart_probes(now);
                }
            }
            crate::icmpv6::Echo::Reply => {
                let Some(state) = self.pairs.get_mut(&pair) else {
                    return ControlFlow::Break(());
                };
                let Some(i) = state
                    .inflight_probes
                    .iter()
                    .position(|inflight| inflight.seq == probe.seq)
                else {
                    return ControlFlow::Break(());
                };

                let inflight = state.inflight_probes.remove(i);
                let rtt = now.saturating_duration_since(inflight.sent_at);

                state.rtt = Some(Rtt {
                    smoothed: match state.rtt {
                        None => rtt,
                        Some(prev) => (prev.smoothed + rtt) / 2,
                    },
                });
                state.record_sample();

                tracing::trace!(local = %pair.0, remote = %pair.1, ?rtt, "Probe reply received");

                self.select_primary(now);

                // A pair that has settled either becomes the long-lived primary
                // (kept fresh on the keepalive cadence) or is a loser whose data
                // we drop, so no stale RTT lingers for selection to trip over.
                if self.pairs.get(&pair).is_some_and(PairState::is_settled) {
                    if self.primary == Some(pair) {
                        self.pairs.get_mut(&pair).unwrap().keep_fresh(now);
                    } else {
                        self.pairs.get_mut(&pair).unwrap().retire();
                    }
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
        // Probes wait for the first handshake exchange; see `drive_probes`.
        let next_probe = self
            .established
            .then(|| self.pairs.values().filter_map(|s| s.probes.due()).min())
            .flatten();
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
            .chain(pending_fanout)
            .chain(dedup_expiry)
            .min()
    }

    pub fn handle_timeout(&mut self, now: Instant) {
        self.drive_handshake_retransmits(now);
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

    fn drive_probes(&mut self, now: Instant) {
        // Probes ride the session (they are encapsulated); encapsulating
        // before the first handshake exchange would make boringtun queue
        // them and initiate handshakes on its own.
        if !self.established {
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

            // Once we have a path, stop probing a non-primary pair that won't
            // settle (e.g. a direct pair behind a symmetric NAT). The primary
            // is exempt — probe loss must never retire it — and while we have
            // no path at all we hunt every pair until WireGuard gives up.
            let is_primary = primary == Some((*local, *remote));
            if primary.is_some() && !is_primary && state.gave_up(now) {
                state.retire();
                continue;
            }

            // A reply past this age wouldn't be fresh enough to matter.
            state
                .inflight_probes
                .retain(|p| now.saturating_duration_since(p.sent_at) < PROBE_TIMEOUT);

            let seq = state.next_probe_seq;
            state.next_probe_seq = state.next_probe_seq.wrapping_add(1);
            state
                .inflight_probes
                .push(InflightProbe { seq, sent_at: now });
            state.probes.fire(now);

            tracing::trace!(%local, %remote, seq, "Probe send");

            pending.push_back(Transmit {
                local: *local,
                remote: *remote,
                payload: Payload::Plaintext(Box::new(crate::icmpv6::build_echo_request(0, seq))),
            });
        }
    }

    fn probe_all_pairs(&mut self, now: Instant) {
        for state in self.pairs.values_mut() {
            state.restart_probes(now);
        }
    }

    fn register_peer_reflexive(&mut self, pair: (SocketAddr, SocketAddr), now: Instant) {
        // The peer reached us from a mapping they didn't advertise
        // (symmetric NAT).
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

    fn select_primary(&mut self, now: Instant) {
        // Only pairs with an RTT are candidates. Every RTT we hold is current
        // by construction — the primary is kept fresh on its keepalive cadence,
        // an actively-probing pair is measuring right now, and a settled loser
        // or a re-probed pair has its RTT cleared — so there is no stale
        // measurement to filter out. Selection is bucket-dominant, so a live
        // primary naturally wins over any worse-bucket challenger; a *dead*
        // primary has no RTT (a distress or candidate signal cleared it by
        // re-probing) and drops out, letting a fresh pair take over.
        let best = self
            .pairs
            .iter()
            .filter(|(_, s)| s.rtt.is_some())
            .min_by_key(|(k, s)| pair_score(**k, s))
            .map(|(k, _)| *k);

        let Some(new) = best else { return };

        if self.primary == Some(new) {
            return;
        }

        // The current primary keeps its place unless a challenger clearly wins.
        // A worse bucket never displaces it — even a primary without a fresh
        // RTT holds by candidate kind, so a fresh worse-bucket pair can't steal
        // it while it is being re-measured. Failing over to a *worse* bucket
        // happens only after WireGuard distress, which drops the primary
        // pointer entirely (there is then no primary to protect).
        if let Some(primary) = self.primary
            && let Some(prev) = self.pairs.get(&primary)
        {
            let new_score = pair_score(new, &self.pairs[&new]);
            let prev_score = pair_score(primary, prev);

            if prev_score.bucket < new_score.bucket {
                return;
            }

            // Same bucket: keep the primary unless the challenger beats its RTT
            // by a clear margin — no needless hop for a marginal gain, and no
            // flap between two live same-bucket pairs on jitter.
            if prev_score.bucket == new_score.bucket
                && let Some(prev_rtt) = prev.rtt
            {
                let new_rtt = new_score.rtt.unwrap_or_default();
                let margin = PRIMARY_HYSTERESIS_FLOOR
                    .max(prev_rtt.smoothed.mul_f64(PRIMARY_HYSTERESIS_FRACTION));

                if new_rtt + margin >= prev_rtt.smoothed {
                    return;
                }
            }
        }

        self.set_primary(new, now);
    }

    fn set_primary(&mut self, path: (SocketAddr, SocketAddr), now: Instant) {
        let from = self.primary;

        self.primary = Some(path);

        // The old primary is now a loser: drop its data so nothing stale
        // lingers (a later signal re-probes it if it becomes relevant again).
        if let Some(old) = from
            && old != path
            && let Some(state) = self.pairs.get_mut(&old)
        {
            state.retire();
        }

        // A new primary that has already settled moves to the keepalive cadence
        // to stay fresh; one still hunting keeps bursting until it settles.
        if let Some(state) = self.pairs.get_mut(&path)
            && state.is_settled()
        {
            state.keep_fresh(now);
        }

        tracing::debug!(
            ?from,
            local = %path.0,
            remote = %path.1,
            "Iceless primary changed",
        );

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
