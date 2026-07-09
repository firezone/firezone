//! Scenario coverage for the iceless path model.
//!
//! Layout follows the model's life-cycle: bootstrap via handshake fan-out,
//! session establishment, probing and (promote-only) selection, and failure
//! handling (WireGuard distress, new candidates, roam). Flow-level coverage
//! lives in the tunnel proptest.

use std::net::{IpAddr, SocketAddr};
use std::time::{Duration, Instant};

use boringtun::noise::{Index, Tunn, TunnResult};
use boringtun::x25519::{PublicKey, StaticSecret};
use ip_packet::{Icmpv6Type, IpPacket};
use path_agent::{
    Candidate, Event, PROBE_BUDGET, PROBE_BURST_GAPS, PROBE_DST, PROBE_SRC, PathAgent, Payload,
    REKEY_DISTRESS_ATTEMPTS, RESPONDER_DEDUP_TTL, Transmit,
};

// --- bootstrap: handshake fan-out ---

#[test]
fn outbound_handshake_init_fans_out_on_every_relay_pair() {
    let mut a = agent_with_relay_pairs();
    let now = Instant::now();
    a.handle_outbound(handshake_init_bytes(), now);
    a.handle_timeout(now);

    let transmits = a.transmits();
    assert_eq!(transmits.len(), 3, "one per relay-involving pair");
    let payload = Payload::Ciphertext(handshake_init_bytes());
    for t in &transmits {
        assert_eq!(t.payload, payload);
    }
}

#[test]
fn outbound_handshake_init_arms_retransmits_with_initial_50ms_deadline() {
    let mut a = agent_with_relay_pairs();
    let now = Instant::now();
    a.handle_outbound(handshake_init_bytes(), now);
    a.handle_timeout(now);
    let _ = a.transmits();
    let next = a.poll_timeout().expect("retransmit deadline");
    assert_eq!(next, now + ms(50));
}

#[test]
fn retransmit_ladder_bursts_then_doubles_to_cap() {
    let mut a = agent_with_relay_pairs();
    let now = Instant::now();

    a.handle_outbound(handshake_init_bytes(), now);
    a.handle_timeout(now);
    let _ = a.transmits();

    let mut t = now + ms(50);
    let expected_step_ms: [u64; 8] = [50, 50, 100, 200, 400, 800, 1600, 1600];
    for &expected_ms in &expected_step_ms {
        a.handle_timeout(t);
        let _ = a.transmits();
        let next = a.poll_timeout().expect("deadline");
        assert_eq!(next, t + ms(expected_ms));
        t = next;
    }
}

#[test]
fn inbound_handshake_response_stops_the_fanout() {
    let mut a = agent_with_relay_pairs();
    let now = Instant::now();

    a.handle_outbound(handshake_init_bytes(), now);
    a.handle_timeout(now);
    let _ = a.transmits();

    let mut hs = Handshake::new(now).with_response(now);
    let _ = a.handle_inbound_network(&mut hs.initiator, &hs.response, (addr(2), addr(4)), now);
    a.drain_events();
    let _ = a.transmits();

    // Established: no more init retransmits, only probes now.
    let later = a.advance(now, now + secs(3));
    assert!(
        later
            .transmits
            .iter()
            .all(|(_, t)| matches!(t.payload, Payload::Plaintext(_))),
        "after establishment nothing re-handshakes; only probes go out",
    );
}

#[test]
fn rejected_handshake_leaves_state_untouched() {
    let mut a = agent_with_relay_pairs();
    let now = Instant::now();
    let hs = Handshake::new(now);

    let _ = a.handle_inbound_network(&mut reject_all(), &hs.init, (addr(2), addr(4)), now);

    assert!(a.poll_event().is_none());
    assert!(a.poll_transmit().is_none());
    assert_eq!(a.primary(), None);
}

#[test]
fn responder_dedup_replays_within_window_then_expires() {
    let mut a = agent_with_relay_pairs();
    let now = Instant::now();
    let mut hs = Handshake::new(now);
    let path = (addr(2), addr(4));

    assert!(
        a.handle_inbound_network(&mut hs.responder, &hs.init, path, now)
            .is_break()
    );
    a.drain_events();
    let _ = a.transmits();

    // A replay inside the window is served from the cache; `reject_all` proves
    // boringtun isn't touched.
    let replay_at = now + RESPONDER_DEDUP_TTL - ms(1);
    let _ = a.handle_inbound_network(&mut reject_all(), &hs.init, path, replay_at);
    assert!(a.poll_transmit().is_some(), "cached response replayed");

    a.handle_timeout(now + RESPONDER_DEDUP_TTL);
    let _ = a.transmits();

    let _ = a.handle_inbound_network(
        &mut reject_all(),
        &hs.init,
        path,
        now + RESPONDER_DEDUP_TTL + secs(1),
    );
    assert!(a.poll_transmit().is_none(), "cache expired");
}

// --- session establishment and preliminary primary ---

#[test]
fn inbound_init_establishes_but_does_not_set_the_primary() {
    // An init proves peer->us only; our send primary must come from a
    // bidirectionally-validated signal (a response or a probe reply).
    let mut a = agent_with_relay_pairs();
    let now = Instant::now();
    let mut hs = Handshake::new(now);

    let _ = a.handle_inbound_network(&mut hs.responder, &hs.init, (addr(2), addr(4)), now);

    assert_eq!(a.primary(), None, "an inbound init never sets the primary");
    assert!(
        a.poll_event().is_none(),
        "no PrimaryChanged from an inbound init"
    );

    // But the session is established, so probing now runs.
    let _ = a.transmits();
    let probes = a.tick(now);
    assert!(
        probes
            .iter()
            .any(|t| matches!(t.payload, Payload::Plaintext(_))),
        "probing starts once a session exists",
    );
}

#[test]
fn handshake_response_seeds_preliminary_primary_by_tier() {
    let mut a = agent_with_relay_pairs();
    let t0 = Instant::now();

    // A response on the relay pair adopts it (no other primary yet).
    bootstrap_primary(&mut a, (addr(2), addr(4)), t0);
    assert_eq!(a.primary(), Some((addr(2), addr(4))));
}

// --- probing and promote-only selection ---

#[test]
fn probe_reply_promotes_to_a_better_tier() {
    // Relay preliminary, then a host probe reply promotes (host beats relay).
    let mut a = agent_with_relay_pairs();
    let t0 = Instant::now();
    bootstrap_primary(&mut a, (addr(2), addr(4)), t0);
    assert_eq!(a.primary(), Some((addr(2), addr(4))));
    a.drain_events();

    let probes = a.tick(t0);
    a.ack_probe(&probes, (addr(1), addr(3)), t0 + ms(30));

    assert_eq!(
        a.primary(),
        Some((addr(1), addr(3))),
        "a host probe reply promotes over the relay preliminary",
    );
}

#[test]
fn a_worse_tier_probe_never_demotes_the_primary() {
    let (mut a, t0) = direct_primary_with_relay_fallback(); // primary (1,3), host
    prove_pair_alive(&mut a, (addr(2), addr(4)), t0 + secs(1)); // relay answers

    assert_eq!(
        a.primary(),
        Some((addr(1), addr(3))),
        "a worse-tier reply must not demote the host primary",
    );
}

#[test]
fn a_non_primary_pair_goes_quiet_after_its_probe_budget() {
    let mut a = agent_with_relay_pairs();
    let t0 = Instant::now();
    // Adopt (2,4) as primary so the budget applies to the other pairs.
    bootstrap_primary(&mut a, (addr(2), addr(4)), t0);
    a.drain_events();

    // (1,3) never answers; with a primary in hand it hunts only PROBE_BUDGET
    // times, then stops.
    let dead = (addr(1), addr(3));
    let activity = a.advance(t0, t0 + secs(60));
    assert_eq!(
        activity.probes_for(dead).len() as u32,
        PROBE_BUDGET,
        "a non-primary pair fires exactly its budget then goes quiet",
    );
}

#[test]
fn a_pathless_agent_probes_forever() {
    // Establish via an inbound init (so there is a session but no primary).
    let mut a = agent_with_relay_pairs();
    let t0 = Instant::now();
    let mut hs = Handshake::new(t0);
    let _ = a.handle_inbound_network(&mut hs.responder, &hs.init, (addr(2), addr(4)), t0);
    assert_eq!(a.primary(), None);
    a.drain_events();
    let _ = a.transmits();

    // With no primary, probing never stops.
    let activity = a.advance(t0, t0 + secs(30));
    assert!(
        activity.probes_for((addr(1), addr(3))).len() as u32 > PROBE_BUDGET,
        "without a primary, pairs keep probing past the budget",
    );
}

#[test]
fn a_reply_with_a_stale_pair_id_is_ignored() {
    let mut a = agent_with_relay_pairs();
    let t0 = Instant::now();
    bootstrap_primary(&mut a, (addr(2), addr(4)), t0);
    a.drain_events();

    let probes = a.tick(t0);
    let probe = extract_probe_for(&probes, (addr(1), addr(3)));

    // Reply carrying a different id than the pair was probed with.
    let stale_id = probe.id.wrapping_add(1);
    let _ = a.handle_inbound_tun(
        build_echo_reply(stale_id, probe.seq),
        (addr(1), addr(3)),
        t0 + ms(30),
    );

    assert_eq!(
        a.primary(),
        Some((addr(2), addr(4))),
        "a reply whose id doesn't match the pair must not measure it",
    );
}

// --- WireGuard distress ---

#[test]
fn a_single_unanswered_rekey_is_not_distress() {
    let (mut a, t0) = direct_primary_with_relay_fallback();
    a.handle_outbound(handshake_init_bytes(), t0 + secs(1));
    assert_eq!(
        a.primary(),
        Some((addr(1), addr(3))),
        "one re-key can be ordinary loss; it must not clear the primary",
    );
}

#[test]
fn a_second_unanswered_rekey_clears_the_primary_and_reprobes() {
    let (mut a, t0) = direct_primary_with_relay_fallback();

    let mut t = t0;
    for _ in 0..REKEY_DISTRESS_ATTEMPTS {
        t += secs(1);
        a.handle_outbound(handshake_init_bytes(), t);
        let _ = a.transmits();
    }
    assert_eq!(a.primary(), None, "the distress re-key cleared the primary");

    // The relay pair answers a probe and takes over.
    prove_pair_alive(&mut a, (addr(2), addr(4)), t);
    assert_eq!(a.primary(), Some((addr(2), addr(4))));
}

#[test]
fn an_answered_rekey_resets_the_distress_count() {
    let (mut a, t0) = direct_primary_with_relay_fallback();

    a.handle_outbound(handshake_init_bytes(), t0 + secs(1));
    let _ = a.transmits();

    // A response answers it, resetting the count.
    let mut hs = Handshake::new(t0).with_response(t0);
    let _ = a.handle_inbound_network(
        &mut hs.initiator,
        &hs.response,
        (addr(1), addr(3)),
        t0 + secs(1),
    );
    a.drain_events();
    let _ = a.transmits();

    // The next unanswered re-key is only the first again: no distress.
    a.handle_outbound(handshake_init_bytes(), t0 + secs(2));
    assert_eq!(
        a.primary(),
        Some((addr(1), addr(3))),
        "an answered re-key reset the count, so this lone one is not distress",
    );
}

#[test]
fn a_second_peer_rekey_without_data_clears_the_primary() {
    let (mut a, t0) = direct_primary_with_relay_fallback();

    let mut t = t0;
    for i in 0..REKEY_DISTRESS_ATTEMPTS {
        t += secs(1);
        let mut hs = Handshake::new_seeded(t0, u64::from(i));
        let _ = a.handle_inbound_network(&mut hs.responder, &hs.init, (addr(2), addr(4)), t);
    }
    a.drain_events();
    let _ = a.transmits();

    assert_eq!(
        a.primary(),
        None,
        "repeated peer re-keys with no data are distress; the primary is cleared",
    );
}

#[test]
fn peer_data_resets_the_peer_rekey_count() {
    let (mut a, t0) = direct_primary_with_relay_fallback();

    // Many peer re-keys, but data flows in between each: never distress.
    let mut t = t0;
    for i in 0..(REKEY_DISTRESS_ATTEMPTS + 2) {
        t += secs(1);
        let mut hs = Handshake::new_seeded(t0, u64::from(i));
        let _ = a.handle_inbound_network(&mut hs.responder, &hs.init, (addr(2), addr(4)), t);
        let _ = a.handle_inbound_network(
            &mut reject_all(),
            &data_packet_bytes(),
            (addr(2), addr(4)),
            t,
        );
    }
    a.drain_events();
    let _ = a.transmits();

    assert_eq!(
        a.primary(),
        Some((addr(1), addr(3))),
        "data between re-keys resets the count, so it never reaches distress",
    );
}

// --- new candidate ---

#[test]
fn a_new_candidate_clears_the_primary_and_reprobes() {
    let (mut a, t0) = direct_primary_with_relay_fallback(); // primary (1,3)
    a.drain_events();

    a.add_remote_candidate(Candidate::host(addr(5)), t0 + secs(1));
    assert_eq!(
        a.primary(),
        None,
        "a new candidate may be a better path; the primary is re-evaluated",
    );

    // The old primary re-confirms within a round trip.
    prove_pair_alive(&mut a, (addr(1), addr(3)), t0 + secs(1));
    assert_eq!(a.primary(), Some((addr(1), addr(3))));
}

// --- roam recovery ---

#[test]
fn roam_recovers_the_data_path_via_probes_without_a_handshake() {
    let mut a = PathAgent::new();
    let t0 = Instant::now();
    a.add_local_candidate(Candidate::host(addr(1)), t0);
    a.add_remote_candidate(Candidate::host(addr(9)), t0);
    bootstrap_primary(&mut a, (addr(1), addr(9)), t0);
    assert_eq!(a.primary(), Some((addr(1), addr(9))));
    a.drain_events();

    // Roam: local candidates gone, session kept.
    let t1 = t0 + secs(60);
    a.rebuild(|_| true, t1);
    assert_eq!(a.primary(), None);

    // A new local candidate pairs with the surviving remote and probes.
    a.add_local_candidate(Candidate::host(addr(5)), t1);
    let recovery = a.advance(t1, t1 + secs(1));
    let probes = recovery.probes_for((addr(5), addr(9)));
    assert!(!probes.is_empty(), "roamed pair probes without a handshake");

    let _ = a.handle_inbound_tun(
        build_echo_reply(probes[0].id, probes[0].seq),
        (addr(5), addr(9)),
        t1 + ms(50),
    );
    assert_eq!(
        a.primary(),
        Some((addr(5), addr(9))),
        "the first probe reply restores the data path",
    );
    assert!(
        recovery
            .transmits
            .iter()
            .all(|(_, t)| matches!(t.payload, Payload::Plaintext(_))),
        "recovery needs no handshake traffic",
    );
}

// --- test harness ---

type Pair = (SocketAddr, SocketAddr);

fn addr(p: u16) -> SocketAddr {
    format!("127.0.0.1:{p}").parse().unwrap()
}

fn ms(n: u64) -> Duration {
    Duration::from_millis(n)
}

fn secs(n: u64) -> Duration {
    Duration::from_secs(n)
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum EchoKind {
    Request,
    Reply,
}

#[derive(Clone, Copy)]
struct ProbeFields {
    kind: EchoKind,
    id: u16,
    seq: u16,
}

fn parse_probe(packet: &IpPacket) -> Option<ProbeFields> {
    if packet.source() != IpAddr::V6(PROBE_SRC) || packet.destination() != IpAddr::V6(PROBE_DST) {
        return None;
    }
    let icmp = packet.as_icmpv6()?;
    let (kind, header) = match icmp.icmp_type() {
        Icmpv6Type::EchoRequest(h) => (EchoKind::Request, h),
        Icmpv6Type::EchoReply(h) => (EchoKind::Reply, h),
        _ => return None,
    };
    Some(ProbeFields {
        kind,
        id: header.id,
        seq: header.seq,
    })
}

fn extract_probe_for(transmits: &[Transmit], pair: Pair) -> ProbeFields {
    let t = transmits
        .iter()
        .find(|t| (t.local, t.remote) == pair && matches!(t.payload, Payload::Plaintext(_)))
        .unwrap_or_else(|| panic!("no probe transmit for {pair:?}"));
    let Payload::Plaintext(ref packet) = t.payload else {
        unreachable!()
    };
    parse_probe(packet).expect("parses as probe")
}

/// The probe send times of one burst starting at `start`.
#[allow(dead_code)]
fn burst_ladder(start: Instant) -> Vec<Instant> {
    std::iter::once(start)
        .chain(PROBE_BURST_GAPS.iter().scan(start, |at, gap| {
            *at += *gap;
            Some(*at)
        }))
        .collect()
}

struct Activity {
    transmits: Vec<(Instant, Transmit)>,
    #[allow(dead_code)]
    events: Vec<Event>,
}

impl Activity {
    fn probes_for(&self, pair: Pair) -> Vec<ProbeFields> {
        self.transmits
            .iter()
            .filter(|(_, t)| (t.local, t.remote) == pair)
            .filter_map(|(_, t)| match &t.payload {
                Payload::Plaintext(packet) => parse_probe(packet),
                Payload::Ciphertext(_) => None,
            })
            .filter(|p| p.kind == EchoKind::Request)
            .collect()
    }
}

trait AgentExt {
    fn transmits(&mut self) -> Vec<Transmit>;
    fn drain_events(&mut self);
    fn tick(&mut self, now: Instant) -> Vec<Transmit>;
    fn ack_probe(&mut self, transmits: &[Transmit], pair: Pair, reply_at: Instant);
    fn advance(&mut self, start: Instant, end: Instant) -> Activity;
}

impl AgentExt for PathAgent {
    fn transmits(&mut self) -> Vec<Transmit> {
        std::iter::from_fn(|| self.poll_transmit()).collect()
    }

    fn drain_events(&mut self) {
        while self.poll_event().is_some() {}
    }

    fn tick(&mut self, now: Instant) -> Vec<Transmit> {
        self.handle_timeout(now);
        self.transmits()
    }

    fn ack_probe(&mut self, transmits: &[Transmit], pair: Pair, reply_at: Instant) {
        let probe = extract_probe_for(transmits, pair);
        let _ = self.handle_inbound_tun(build_echo_reply(probe.id, probe.seq), pair, reply_at);
    }

    fn advance(&mut self, start: Instant, end: Instant) -> Activity {
        let mut activity = Activity {
            transmits: Vec::new(),
            events: Vec::new(),
        };
        let mut now = start;

        for _ in 0..10_000 {
            self.handle_timeout(now);
            activity
                .transmits
                .extend(std::iter::from_fn(|| self.poll_transmit()).map(|t| (now, t)));
            activity
                .events
                .extend(std::iter::from_fn(|| self.poll_event()));

            match self.poll_timeout() {
                Some(next) if next <= end => now = next.max(now),
                _ => return activity,
            }
        }

        panic!("agent did not go quiet between {start:?} and {end:?}");
    }
}

// --- shared fixtures ---

fn agent_with_relay_pairs() -> PathAgent {
    let mut a = PathAgent::new();
    let now = Instant::now();
    a.add_local_candidate(Candidate::host(addr(1)), now);
    a.add_local_candidate(Candidate::relayed(addr(2), addr(2)), now);
    a.add_remote_candidate(Candidate::host(addr(3)), now);
    a.add_remote_candidate(Candidate::relayed(addr(4), addr(4)), now);
    a
}

/// A host↔host primary at `(1, 3)` (promoted over a relay preliminary) with a
/// relay pair `(2, 4)` as the fail-over target.
fn direct_primary_with_relay_fallback() -> (PathAgent, Instant) {
    let mut a = agent_with_relay_pairs();
    let t0 = Instant::now();
    bootstrap_primary(&mut a, (addr(2), addr(4)), t0);

    let probes = a.tick(t0);
    a.ack_probe(&probes, (addr(1), addr(3)), t0 + ms(30));
    assert_eq!(a.primary(), Some((addr(1), addr(3))));
    a.drain_events();
    let _ = a.transmits();

    (a, t0)
}

/// Simulate the peer probing us on `pair` and us measuring it: the inbound
/// request triggers a probe back, which we then answer.
fn prove_pair_alive(a: &mut PathAgent, pair: Pair, now: Instant) {
    let _ = a.handle_inbound_tun(build_echo_request(0, 999), pair, now);
    let _ = a.transmits();

    let probes = a.tick(now);
    let probe = extract_probe_for(&probes, pair);
    let _ = a.handle_inbound_tun(build_echo_reply(probe.id, probe.seq), pair, now + ms(20));
}

/// Synthetic — only the type byte matters to `handle_outbound`.
fn handshake_init_bytes() -> Vec<u8> {
    let mut bytes = vec![0u8; 148];
    bytes[0] = 1;
    bytes
}

/// Synthetic data packet: only the type byte and a length past the data
/// overhead matter for it to parse as `PacketData`.
fn data_packet_bytes() -> Vec<u8> {
    let mut bytes = vec![0u8; 32];
    bytes[0] = 4;
    bytes
}

fn bootstrap_primary(a: &mut PathAgent, recv_path: Pair, now: Instant) {
    let mut hs = Handshake::new(now).with_response(now);
    let _ = a.handle_inbound_network(&mut hs.initiator, &hs.response, recv_path, now);
    a.drain_events();
    let _ = a.transmits();
}

struct Handshake {
    initiator: Tunn,
    responder: Tunn,
    init: Vec<u8>,
    response: Vec<u8>,
}

impl Handshake {
    fn new(now: Instant) -> Self {
        Self::new_seeded(now, 0)
    }

    /// `seed` varies the initiator's ephemeral so distinct handshakes produce
    /// distinct init bytes (else they'd be dropped as duplicates).
    fn new_seeded(now: Instant, seed: u64) -> Self {
        let priv_a = StaticSecret::from([1u8; 32]);
        let pub_a = PublicKey::from(&priv_a);
        let priv_b = StaticSecret::from([2u8; 32]);
        let pub_b = PublicKey::from(&priv_b);

        let unix = Duration::from_secs(1);
        let mut initiator = Tunn::new_at(
            priv_a,
            pub_b,
            None,
            None,
            Index::new_local(seed as u32 * 2),
            None,
            seed * 2,
            now,
            now,
            unix,
        );
        let responder = Tunn::new_at(
            priv_b,
            pub_a,
            None,
            None,
            Index::new_local(seed as u32 * 2 + 1),
            None,
            seed * 2 + 1,
            now,
            now,
            unix,
        );

        let mut buf = [0u8; 148];
        let TunnResult::WriteToNetwork(init) =
            initiator.format_handshake_initiation_at(&mut buf, true, now)
        else {
            panic!("expected init");
        };
        let init = init.to_vec();

        Self {
            initiator,
            responder,
            init,
            response: Vec::new(),
        }
    }

    fn with_response(mut self, now: Instant) -> Self {
        let mut buf = [0u8; 148];
        let TunnResult::WriteToNetwork(response) = self
            .responder
            .decapsulate_at(None, &self.init, &mut buf, now)
        else {
            panic!("expected response");
        };
        self.response = response.to_vec();
        self
    }
}

/// Mismatched keypair — every `decapsulate_at` call rejects.
fn reject_all() -> Tunn {
    let now = Instant::now();
    Tunn::new_at(
        StaticSecret::from([3u8; 32]),
        PublicKey::from(&StaticSecret::from([4u8; 32])),
        None,
        None,
        Index::new_local(99),
        None,
        99,
        now,
        now,
        Duration::from_secs(1),
    )
}

fn build_echo_request(id: u16, seq: u16) -> IpPacket {
    ip_packet::make::icmp_request_packet(IpAddr::V6(PROBE_SRC), IpAddr::V6(PROBE_DST), seq, id, &[])
        .expect("magic addresses always fit")
}

fn build_echo_reply(id: u16, seq: u16) -> IpPacket {
    ip_packet::make::icmp_reply_packet(IpAddr::V6(PROBE_SRC), IpAddr::V6(PROBE_DST), seq, id, &[])
        .expect("magic addresses always fit")
}
