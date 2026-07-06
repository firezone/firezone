//! Scoring, timing, peer-reflexive discovery, and the
//! validate-then-commit regression. Flow-level coverage lives in the
//! tunnel proptest.

use std::net::{IpAddr, SocketAddr};
use std::ops::ControlFlow;
use std::time::{Duration, Instant};

use boringtun::noise::{Index, Tunn, TunnResult};
use boringtun::x25519::{PublicKey, StaticSecret};
use ip_packet::{Icmpv6Type, IpPacket};
use path_agent::{
    Candidate, EVALUATION_WINDOW, Event, PROBE_DST, PROBE_INTERVAL, PROBE_INTERVAL_LIVE, PROBE_SRC,
    PROBE_TIMEOUT, PathAgent, Payload, RESPONDER_DEDUP_TTL, Transmit,
};

fn addr(p: u16) -> SocketAddr {
    format!("127.0.0.1:{p}").parse().unwrap()
}

fn addr_v6(p: u16) -> SocketAddr {
    format!("[::1]:{p}").parse().unwrap()
}

#[test]
fn inbound_handshake_init_validates_then_adopts_primary() {
    let mut a = agent_with_relay_pairs();
    let now = Instant::now();
    let mut hs = Handshake::new(now);

    assert!(
        a.handle_inbound_network(&mut hs.responder, &hs.init, (addr(2), addr(4)), now)
            .is_break()
    );

    match a.poll_event() {
        Some(Event::PrimaryChanged { local, remote }) => {
            assert_eq!((local, remote), (addr(2), addr(4)));
        }
        other => panic!("expected PrimaryChanged, got {other:?}"),
    }
}

#[test]
fn rejected_handshake_leaves_state_untouched() {
    let mut a = agent_with_relay_pairs();
    let now = Instant::now();
    let mut hs = Handshake::new(now);

    let _ = a.handle_inbound_network(&mut reject_all(), &hs.init, (addr(2), addr(4)), now);

    assert!(
        a.poll_event().is_none(),
        "rejected bytes must not adopt a primary"
    );
    assert!(
        a.poll_transmit().is_none(),
        "rejected bytes must not queue any outbound"
    );

    // The earlier rejection must not pollute responder dedup.
    let _ = a.handle_inbound_network(&mut hs.responder, &hs.init, (addr(2), addr(4)), now);
    assert!(
        matches!(a.poll_event(), Some(Event::PrimaryChanged { .. })),
        "legitimate retry must adopt a primary"
    );
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

    // Within the window, a replayed init must be served from the
    // cache without touching boringtun; `reject_all()` proves it.
    let replay_at = now + RESPONDER_DEDUP_TTL - Duration::from_millis(1);
    let _ = a.handle_inbound_network(&mut reject_all(), &hs.init, path, replay_at);
    assert!(
        a.poll_transmit().is_some(),
        "replay inside the window must produce a cached response"
    );

    a.handle_timeout(now + RESPONDER_DEDUP_TTL);
    let _ = a.transmits();

    // Past the window the cache must be gone — `reject_all()` runs
    // again and emits no response.
    let _ = a.handle_inbound_network(
        &mut reject_all(),
        &hs.init,
        path,
        now + RESPONDER_DEDUP_TTL + Duration::from_secs(1),
    );
    assert!(
        a.poll_transmit().is_none(),
        "replay past the window must not produce a cached response"
    );
}

#[test]
fn outbound_handshake_init_arms_retransmits_with_initial_50ms_deadline() {
    let mut a = agent_with_relay_pairs();
    let now = Instant::now();
    a.handle_outbound(handshake_init_bytes(), now);
    a.handle_timeout(now);
    let _ = a.transmits();
    let next = a.poll_timeout().expect("retransmit deadline");
    assert_eq!(next, now + Duration::from_millis(50));
}

#[test]
fn handle_timeout_at_or_after_deadline_re_emits_init_per_pair() {
    let mut a = agent_with_relay_pairs();
    let now = Instant::now();
    let init = handshake_init_bytes();

    a.handle_outbound(init.clone(), now);
    a.handle_timeout(now);
    let initial_count = std::iter::from_fn(|| a.poll_transmit()).count();
    assert_eq!(initial_count, 3);

    let later = now + Duration::from_millis(50);
    a.handle_timeout(later);

    let retransmits = a.transmits();
    assert_eq!(retransmits.len(), 3);
    for t in &retransmits {
        assert_eq!(t.payload, Payload::Ciphertext(init.clone()));
    }
}

#[test]
fn retransmit_ladder_bursts_then_doubles_to_cap() {
    let mut a = agent_with_relay_pairs();
    let now = Instant::now();

    a.handle_outbound(handshake_init_bytes(), now);
    a.handle_timeout(now);
    let _ = a.transmits();

    let mut t = now + Duration::from_millis(50);
    let expected_step_ms: [u64; 8] = [50, 50, 100, 200, 400, 800, 1600, 1600];
    for &expected_ms in &expected_step_ms {
        a.handle_timeout(t);
        let _ = a.transmits();
        let next = a.poll_timeout().expect("deadline");
        assert_eq!(next, t + Duration::from_millis(expected_ms));
        t = next;
    }
}

#[test]
fn inbound_handshake_response_clears_retransmits() {
    let mut a = agent_with_relay_pairs();
    let now = Instant::now();

    a.handle_outbound(handshake_init_bytes(), now);
    a.handle_timeout(now);
    let _ = a.transmits();
    let init_deadline = a.poll_timeout().expect("init armed retransmits");

    let mut hs = Handshake::new(now).with_response(now);
    let _ = a.handle_inbound_network(&mut hs.initiator, &hs.response, (addr(2), addr(4)), now);
    a.drain_events();

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
    a.handle_timeout(now);
    let _ = a.transmits();
    a.handle_timeout(now + Duration::from_millis(25));
    assert!(a.poll_transmit().is_none());
}

#[test]
fn srflx_local_uses_base_as_send_from_address() {
    let mut a = PathAgent::new();
    let now = Instant::now();

    let mapped = addr(10);
    let base = addr(11);
    a.add_local_candidate(Candidate::server_reflexive(mapped, base));
    a.add_local_candidate(Candidate::relayed(addr(20), addr(20)));
    a.add_remote_candidate(Candidate::relayed(addr(30), addr(30)), now);

    a.handle_outbound(handshake_init_bytes(), now);
    a.handle_timeout(now);

    let mut emitted: Vec<_> = std::iter::from_fn(|| a.poll_transmit())
        .map(|t| (t.local, t.remote))
        .collect();
    emitted.sort();
    let mut expected = vec![(base, addr(30)), (addr(20), addr(30))];
    expected.sort();
    assert_eq!(emitted, expected);
}

#[test]
fn outbound_handshake_init_fans_out_on_every_relay_pair() {
    let mut a = agent_with_relay_pairs();
    let now = Instant::now();
    a.handle_outbound(handshake_init_bytes(), now);
    a.handle_timeout(now);

    let transmits = a.transmits();
    assert_eq!(transmits.len(), 3);
    let payload = Payload::Ciphertext(handshake_init_bytes());
    for t in &transmits {
        assert_eq!(t.payload, payload);
    }
}

#[test]
fn probe_seq_advances_per_pair_per_fire() {
    let mut a = agent_with_relay_pairs();
    let now = Instant::now();
    bootstrap_primary(&mut a, (addr(2), addr(4)), now);

    a.handle_timeout(now);
    let first = a.transmits();
    let first_probe = extract_probe_for(&first, (addr(1), addr(3)));
    let first_seq = first_probe.seq;

    let _ = a.handle_inbound_tun(
        build_echo_reply(first_probe.id, first_probe.seq),
        (addr(1), addr(3)),
        now + Duration::from_millis(50),
    );

    a.handle_timeout(now + PROBE_INTERVAL);
    let second = a.transmits();
    let second_seq = extract_probe_for(&second, (addr(1), addr(3))).seq;

    assert_eq!(second_seq, first_seq.wrapping_add(1));
}

#[test]
fn probe_skips_while_inflight_until_probe_timeout_lapses() {
    let mut a = agent_with_relay_pairs();
    let now = Instant::now();
    bootstrap_primary(&mut a, (addr(2), addr(4)), now);

    a.handle_timeout(now);
    let first = a.transmits();
    let pair = (addr(1), addr(3));
    let first_seq = extract_probe_for(&first, pair).seq;

    a.handle_timeout(now + PROBE_INTERVAL);
    let mid: Vec<_> = std::iter::from_fn(|| a.poll_transmit())
        .filter(|t| (t.local, t.remote) == pair)
        .collect();
    assert!(
        mid.is_empty(),
        "expected no probe re-fire while previous is inflight: {mid:?}"
    );

    a.handle_timeout(now + PROBE_TIMEOUT);
    let after: Vec<_> = std::iter::from_fn(|| a.poll_transmit())
        .filter(|t| (t.local, t.remote) == pair)
        .collect();
    assert_eq!(
        after.len(),
        1,
        "expected fresh probe after timeout: {after:?}"
    );
    let next_seq = extract_probe_for(&after, pair).seq;
    assert_eq!(next_seq, first_seq.wrapping_add(1));
}

#[test]
fn drive_probes_only_emits_on_primary_after_settle() {
    let mut a = agent_with_relay_pairs();
    let now = Instant::now();
    let primary = (addr(1), addr(3));
    bootstrap_primary(&mut a, (addr(2), addr(4)), now);

    let inside = a.tick(now);
    assert!(!inside.is_empty(), "expected probes inside window");
    a.ack_probe(&inside, primary, now + ms(50));
    assert_eq!(a.primary(), Some(primary));
    a.drain_events();

    a.handle_timeout(now + EVALUATION_WINDOW);
    let _ = a.transmits();

    a.handle_timeout(now + EVALUATION_WINDOW + PROBE_INTERVAL_LIVE - ms(1));
    assert!(a.poll_transmit().is_none(), "before live deadline");

    let live = a.tick(now + EVALUATION_WINDOW + PROBE_INTERVAL_LIVE);
    assert_eq!(live.len(), 1, "expected primary-only probe: {live:?}");
    assert_eq!((live[0].local, live[0].remote), primary);
}

#[test]
fn settle_keeps_poll_timeout_armed_for_primary_probes() {
    let mut a = agent_with_relay_pairs();
    let now = Instant::now();
    let primary = (addr(1), addr(3));
    settle_with_primary(&mut a, (addr(2), addr(4)), primary, now);

    assert_eq!(
        a.poll_timeout(),
        Some(now + EVALUATION_WINDOW + PROBE_INTERVAL_LIVE),
    );
}

#[test]
fn settle_is_sticky_across_later_handshakes() {
    let mut a = agent_with_relay_pairs();
    let now = Instant::now();
    let primary = (addr(1), addr(3));
    let mut hs = Handshake::new(now).with_response(now);

    let _ = a.handle_inbound_network(&mut hs.initiator, &hs.response, (addr(2), addr(4)), now);
    a.drain_events();

    a.handle_timeout(now);
    let outbound = a.transmits();
    let host_probe = extract_probe_for(&outbound, primary);
    let _ = a.handle_inbound_tun(
        build_echo_reply(host_probe.id, host_probe.seq),
        primary,
        now + Duration::from_millis(50),
    );
    a.drain_events();

    a.handle_timeout(now + EVALUATION_WINDOW);
    let _ = a.transmits();

    let live_deadline = a.poll_timeout().expect("live cadence");

    // Re-feeding the same bytes hits the dedup before Tunn runs;
    // `reject_all()` proves it didn't.
    let _ = a.handle_inbound_network(
        &mut reject_all(),
        &hs.response,
        (addr(2), addr(4)),
        now + EVALUATION_WINDOW + Duration::from_secs(60),
    );
    a.drain_events();

    assert_eq!(a.poll_timeout(), Some(live_deadline));
}

#[test]
fn inbound_handshake_reopens_evaluation_window_after_settle() {
    // Reopen even when the recv path is already known — catches the
    // roam case where signalling beats the data plane.
    let mut a = agent_with_relay_pairs();
    let now = Instant::now();
    let primary = (addr(1), addr(3));
    settle_with_primary(&mut a, (addr(2), addr(4)), primary, now);

    let live_tick = now + EVALUATION_WINDOW + PROBE_INTERVAL_LIVE;
    let live_probes = a.tick(live_tick);
    assert_eq!(
        live_probes.len(),
        1,
        "post-settle only primary probes, got {live_probes:?}"
    );

    let reopen_at = live_tick + Duration::from_secs(1);
    let mut hs2 = Handshake::new(reopen_at).with_response(reopen_at);
    let _ = a.handle_inbound_network(
        &mut hs2.initiator,
        &hs2.response,
        (addr(2), addr(4)),
        reopen_at,
    );
    a.drain_events();
    let reopened_probes = a.tick(reopen_at);
    assert!(
        reopened_probes.len() > 1,
        "all pairs should probe after reopen, got {reopened_probes:?}"
    );
}

#[test]
fn new_handshake_inside_open_window_restarts_evaluation() {
    // A roam re-keys to a new address while the *initial* evaluation
    // window is still open. The new handshake must restart the window so
    // stale RTTs are cleared; otherwise the original window settles on a
    // pre-roam pair that is now dead.
    let mut a = agent_with_relay_pairs();
    let now = Instant::now();

    // Handshake 1 opens the window (deadline now + EVALUATION_WINDOW).
    let mut hs1 = Handshake::new(now);
    let _ = a.handle_inbound_network(&mut hs1.responder, &hs1.init, (addr(2), addr(4)), now);
    a.drain_events();

    // A *different* handshake arrives late in the window (a roam re-key
    // to a new address), still inside the original deadline.
    let t2 = now + Duration::from_secs(8);
    let mut hs2 = Handshake::new(t2);
    let _ = a.handle_inbound_network(&mut hs2.responder, &hs2.init, (addr(2), addr(4)), t2);
    a.drain_events();

    // At the *original* deadline a non-restarted window settles and drops
    // to the live cadence (primary-only, +25s). The restart pushed the
    // deadline out to t2 + EVALUATION_WINDOW, so it stays open and probes.
    a.handle_timeout(now + EVALUATION_WINDOW);
    let _ = a.transmits();

    // Past the inflight-probe timeout but well before the restarted
    // deadline: an open window re-probes *every* pair; a settled window
    // probes nothing (its primary isn't due for another ~25s).
    a.handle_timeout(now + EVALUATION_WINDOW + PROBE_TIMEOUT + Duration::from_secs(1));
    let probes = a.transmits();
    assert!(
        probes.len() > 1,
        "a new handshake inside the open window must restart it (re-probe all pairs), got {probes:?}"
    );
}

#[test]
fn inbound_echo_reply_updates_smoothed_rtt_and_selects_primary() {
    let mut a = agent_with_relay_pairs();
    let now = Instant::now();
    bootstrap_primary(&mut a, (addr(2), addr(4)), now);

    let probes = a.tick(now);
    let probe = extract_probe_for(&probes, (addr(1), addr(3)));
    let reply = build_echo_reply(probe.id, probe.seq);
    let handled = a.handle_inbound_tun(reply, (addr(1), addr(3)), now + ms(50));
    assert!(matches!(handled, ControlFlow::Break(())));

    assert_eq!(a.primary(), Some((addr(1), addr(3))));
    match a.poll_event() {
        Some(Event::PrimaryChanged { local, remote }) => {
            assert_eq!((local, remote), (addr(1), addr(3)));
        }
        other => panic!("expected PrimaryChanged, got {other:?}"),
    }
}

#[test]
fn inbound_echo_request_queues_reply_on_same_pair() {
    let mut a = agent_with_relay_pairs();
    let now = Instant::now();

    let request = build_echo_request(0, 42);
    let handled = a.handle_inbound_tun(request, (addr(2), addr(4)), now);
    assert!(matches!(handled, ControlFlow::Break(())));

    let reply_transmit = a.poll_transmit().expect("queued reply");
    assert_eq!(reply_transmit.local, addr(2));
    assert_eq!(reply_transmit.remote, addr(4));
    let Payload::Plaintext(packet) = reply_transmit.payload else {
        panic!("expected Plaintext reply");
    };
    let parsed = parse_probe(&packet).expect("parses");
    assert_eq!(parsed.kind, EchoKind::Reply);
    assert_eq!(parsed.seq, 42);
}

#[test]
fn inbound_echo_request_from_unknown_source_registers_peer_reflexive() {
    let mut a = agent_with_relay_pairs();
    let now = Instant::now();
    bootstrap_primary(&mut a, (addr(2), addr(4)), now);

    let request = build_echo_request(0, 1);
    let _ = a.handle_inbound_tun(request, (addr(1), addr(99)), now);

    let _ = a.transmits();

    a.handle_timeout(now);
    let probes = a.transmits();

    let _ = extract_probe_for(&probes, (addr(1), addr(99)));
}

#[test]
fn signaled_candidate_promotes_peer_reflexive_in_place() {
    let mut a = agent_with_relay_pairs();
    let now = Instant::now();
    bootstrap_primary(&mut a, (addr(2), addr(4)), now);

    let _ = a.handle_inbound_tun(build_echo_request(0, 1), (addr(1), addr(99)), now);
    let _ = a.transmits();

    a.handle_timeout(now);
    let probes = a.transmits();
    let probe = extract_probe_for(&probes, (addr(1), addr(99)));
    let later = now + Duration::from_millis(50);
    let _ = a.handle_inbound_tun(
        build_echo_reply(probe.id, probe.seq),
        (addr(1), addr(99)),
        later,
    );

    assert!(a.pairs().any(|p| p == (addr(1), addr(99))));

    a.add_remote_candidate(Candidate::server_reflexive(addr(99), addr(98)), now);

    assert!(a.pairs().any(|p| p == (addr(1), addr(99))));
    let count_at_99 = a.pairs().filter(|(_, r)| *r == addr(99)).count();
    assert_eq!(count_at_99, 2, "pairs at addr(99): one per local");

    a.add_remote_candidate(Candidate::server_reflexive(addr(99), addr(98)), now);
    let count_at_99_again = a.pairs().filter(|(_, r)| *r == addr(99)).count();
    assert_eq!(count_at_99_again, 2, "second signal must not duplicate");
}

#[test]
fn primary_changes_when_lower_tier_pair_becomes_alive() {
    let mut a = agent_with_relay_pairs();
    let now = Instant::now();
    bootstrap_primary(&mut a, (addr(2), addr(4)), now);

    let probes = a.tick(now);
    a.ack_probe(&probes, (addr(2), addr(4)), now + ms(100));
    assert_eq!(a.primary(), Some((addr(2), addr(4))));
    a.drain_events();

    a.ack_probe(&probes, (addr(1), addr(3)), now + ms(150));
    assert_eq!(a.primary(), Some((addr(1), addr(3))));
    match a.poll_event() {
        Some(Event::PrimaryChanged { local, remote }) => {
            assert_eq!((local, remote), (addr(1), addr(3)));
        }
        other => panic!("expected PrimaryChanged, got {other:?}"),
    }
}

#[test]
fn primary_prefers_local_relay_over_remote_relay_at_same_tier() {
    let mut a = PathAgent::new();
    let now = Instant::now();
    a.add_local_candidate(Candidate::host(addr(1)));
    a.add_local_candidate(Candidate::relayed(addr(2), addr(2)));
    a.add_remote_candidate(Candidate::host(addr(3)), now);
    a.add_remote_candidate(Candidate::relayed(addr(4), addr(4)), now);

    let remote_relay_pair = (addr(1), addr(4));
    bootstrap_primary(&mut a, remote_relay_pair, now);

    let probes = a.tick(now);
    a.ack_probe(&probes, remote_relay_pair, now + ms(50));
    assert_eq!(a.primary(), Some(remote_relay_pair));
    a.drain_events();

    let local_relay_pair = (addr(2), addr(3));
    a.ack_probe(&probes, local_relay_pair, now + ms(100));
    assert_eq!(
        a.primary(),
        Some(local_relay_pair),
        "local-relay pair should beat remote-relay pair at the same tier",
    );
}

#[test]
fn primary_prefers_single_relay_hop_over_double_regardless_of_rtt() {
    // Scoring compares both ends' tiers: (relay, srflx) traverses one
    // relay, (relay, relay) two — the former must win on tier, not flap
    // on RTT jitter.
    let mut a = PathAgent::new();
    let now = Instant::now();
    a.add_local_candidate(Candidate::relayed(addr(2), addr(2)));
    a.add_remote_candidate(Candidate::server_reflexive(addr(3), addr(3)), now);
    a.add_remote_candidate(Candidate::relayed(addr(4), addr(4)), now);

    let double_hop = (addr(2), addr(4));
    bootstrap_primary(&mut a, double_hop, now);

    let probes = a.tick(now);
    a.ack_probe(&probes, double_hop, now + ms(20));
    assert_eq!(a.primary(), Some(double_hop));
    a.drain_events();

    // Even with a much worse RTT, one relay hop beats two.
    let single_hop = (addr(2), addr(3));
    a.ack_probe(&probes, single_hop, now + ms(500));
    assert_eq!(
        a.primary(),
        Some(single_hop),
        "single-relay-hop pair should beat double-relay-hop pair",
    );
}

#[test]
fn primary_prefers_ipv6_over_ipv4_at_same_tier() {
    let mut a = PathAgent::new();
    let now = Instant::now();
    a.add_local_candidate(Candidate::host(addr(1)));
    a.add_local_candidate(Candidate::host(addr_v6(11)));
    a.add_remote_candidate(Candidate::host(addr(2)), now);
    a.add_remote_candidate(Candidate::host(addr_v6(12)), now);
    bootstrap_primary(&mut a, (addr(1), addr(2)), now);

    let probes = a.tick(now);
    a.ack_probe(&probes, (addr(1), addr(2)), now + ms(50));
    assert_eq!(a.primary(), Some((addr(1), addr(2))));
    a.drain_events();

    a.ack_probe(&probes, (addr_v6(11), addr_v6(12)), now + ms(100));
    assert_eq!(
        a.primary(),
        Some((addr_v6(11), addr_v6(12))),
        "v6 pair should beat v4 pair at the same tier",
    );
}

#[test]
fn primary_holds_better_bucket_when_incumbent_has_no_rtt() {
    let mut a = PathAgent::new();
    let now = Instant::now();
    a.add_local_candidate(Candidate::host(addr(1)));
    a.add_local_candidate(Candidate::host(addr_v6(11)));
    a.add_remote_candidate(Candidate::host(addr(2)), now);
    a.add_remote_candidate(Candidate::host(addr_v6(12)), now);
    let v6_pair = (addr_v6(11), addr_v6(12));

    bootstrap_primary(&mut a, v6_pair, now);
    assert_eq!(a.primary(), Some(v6_pair));

    let probes = a.tick(now);
    a.ack_probe(&probes, (addr(1), addr(2)), now + ms(40));

    assert_eq!(
        a.primary(),
        Some(v6_pair),
        "v4 must not displace a no-RTT v6 incumbent — discrete prefix wins",
    );
}

#[test]
fn primary_prefers_family_matched_relay_within_same_v6_bucket() {
    let mut a = PathAgent::new();
    let now = Instant::now();
    let matched_local_alloc = addr_v6(10);
    let mismatched_local_alloc = addr_v6(11);
    a.add_local_candidate(Candidate::relayed(matched_local_alloc, addr_v6(100)));
    a.add_local_candidate(Candidate::relayed(mismatched_local_alloc, addr(101)));
    a.add_remote_candidate(Candidate::relayed(addr_v6(20), addr_v6(20)), now);
    let mismatched_pair = (mismatched_local_alloc, addr_v6(20));
    bootstrap_primary(&mut a, mismatched_pair, now);

    let probes = a.tick(now);
    a.ack_probe(&probes, mismatched_pair, now + ms(50));
    assert_eq!(a.primary(), Some(mismatched_pair));
    a.drain_events();

    let matched_pair = (matched_local_alloc, addr_v6(20));
    a.ack_probe(&probes, matched_pair, now + ms(100));
    assert_eq!(
        a.primary(),
        Some(matched_pair),
        "matched-family relay pair should beat mismatched-family at same v6 tier",
    );
}

#[test]
fn family_match_dominates_ipv6_preference() {
    let mut a = PathAgent::new();
    let now = Instant::now();
    let v6_mismatched_local_alloc = addr_v6(10);
    let v4_matched_local_alloc = addr(11);
    a.add_local_candidate(Candidate::relayed(v6_mismatched_local_alloc, addr(100)));
    a.add_local_candidate(Candidate::relayed(v4_matched_local_alloc, addr(101)));
    a.add_remote_candidate(Candidate::relayed(addr_v6(20), addr_v6(20)), now);
    a.add_remote_candidate(Candidate::relayed(addr(30), addr(30)), now);
    let v6_pair = (v6_mismatched_local_alloc, addr_v6(20));
    bootstrap_primary(&mut a, v6_pair, now);

    let probes = a.tick(now);
    a.ack_probe(&probes, v6_pair, now + ms(50));
    assert_eq!(a.primary(), Some(v6_pair));
    a.drain_events();

    let v4_pair = (v4_matched_local_alloc, addr(30));
    a.ack_probe(&probes, v4_pair, now + ms(100));
    assert_eq!(
        a.primary(),
        Some(v4_pair),
        "fully-matched v4 pair should outrank a mismatched-family v6 pair",
    );
}

#[test]
fn primary_holds_when_rtt_gain_is_within_hysteresis_margin() {
    let mut a = PathAgent::new();
    let now = Instant::now();
    a.add_local_candidate(Candidate::host(addr(1)));
    a.add_remote_candidate(Candidate::host(addr(3)), now);
    a.add_remote_candidate(Candidate::host(addr(4)), now);

    bootstrap_primary(&mut a, (addr(1), addr(3)), now);

    let probes = a.tick(now);
    a.ack_probe(&probes, (addr(1), addr(3)), now + ms(50));
    assert_eq!(a.primary(), Some((addr(1), addr(3))));
    a.drain_events();

    // 45ms is a 5ms gain over the 50ms incumbent — inside the 10ms floor.
    a.ack_probe(&probes, (addr(1), addr(4)), now + ms(45));

    assert_eq!(
        a.primary(),
        Some((addr(1), addr(3))),
        "a sub-margin RTT gain must not unseat the incumbent primary",
    );
    assert!(
        a.poll_event().is_none(),
        "no PrimaryChanged should be emitted while the primary holds",
    );
}

#[test]
fn primary_switches_when_rtt_gain_exceeds_hysteresis_margin() {
    let mut a = PathAgent::new();
    let now = Instant::now();
    a.add_local_candidate(Candidate::host(addr(1)));
    a.add_remote_candidate(Candidate::host(addr(3)), now);
    a.add_remote_candidate(Candidate::host(addr(4)), now);
    bootstrap_primary(&mut a, (addr(1), addr(3)), now);

    let probes = a.tick(now);
    a.ack_probe(&probes, (addr(1), addr(3)), now + ms(50));
    assert_eq!(a.primary(), Some((addr(1), addr(3))));
    a.drain_events();

    a.ack_probe(&probes, (addr(1), addr(4)), now + ms(30));

    assert_eq!(
        a.primary(),
        Some((addr(1), addr(4))),
        "an RTT gain past the margin should switch the primary",
    );
    match a.poll_event() {
        Some(Event::PrimaryChanged { local, remote }) => {
            assert_eq!((local, remote), (addr(1), addr(4)));
        }
        other => panic!("expected PrimaryChanged, got {other:?}"),
    }
}

#[test]
fn stale_echo_reply_is_ignored() {
    let mut a = agent_with_relay_pairs();
    let now = Instant::now();
    bootstrap_primary(&mut a, (addr(2), addr(4)), now);

    a.handle_timeout(now);
    let _ = a.transmits();

    let stale_reply = build_echo_reply(0, 0xdead);
    let _ = a.handle_inbound_tun(stale_reply, (addr(1), addr(3)), now);

    assert_eq!(a.primary(), Some((addr(2), addr(4))));
}

#[test]
fn outbound_init_keeps_retransmitting_past_evaluation_window_without_response() {
    let mut a = agent_with_relay_pairs();
    let now = Instant::now();

    a.handle_outbound(handshake_init_bytes(), now);
    a.handle_timeout(now);
    let _ = a.transmits();

    a.handle_timeout(now + EVALUATION_WINDOW + Duration::from_secs(1));
    assert!(a.poll_event().is_none(), "no BootstrapFailed-style event");
    assert!(
        a.poll_transmit().is_some(),
        "retransmits should still be firing"
    );
}

#[test]
fn fresh_handshake_clears_stale_rtt_so_old_pair_does_not_win_against_new_one() {
    let mut a = agent_with_relay_pairs();
    let now = Instant::now();
    let initial_path = (addr(2), addr(4));
    let roam_path = (addr(1), addr(3));

    bootstrap_primary(&mut a, initial_path, now);
    a.handle_timeout(now);
    let outbound = a.transmits();
    let initial_probe = extract_probe_for(&outbound, initial_path);
    let _ = a.handle_inbound_tun(
        build_echo_reply(initial_probe.id, initial_probe.seq),
        initial_path,
        now + Duration::from_millis(40),
    );
    assert_eq!(a.primary(), Some(initial_path));
    a.drain_events();
    let _ = a.transmits();

    let roam_at = now + Duration::from_secs(60);
    let mut hs2 = Handshake::new(roam_at).with_response(roam_at);
    let _ = a.handle_inbound_network(&mut hs2.initiator, &hs2.response, roam_path, roam_at);
    assert_eq!(a.primary(), Some(roam_path));
    a.drain_events();

    let _ = a.handle_inbound_tun(
        build_echo_reply(initial_probe.id, initial_probe.seq),
        initial_path,
        roam_at + Duration::from_millis(10),
    );
    assert_eq!(
        a.primary(),
        Some(roam_path),
        "stale reply on the old path must not flip primary back"
    );
}

#[test]
fn rekey_handshake_init_rides_primary_instead_of_re_fanning_out() {
    let mut a = agent_with_relay_pairs();
    let now = Instant::now();
    let recv_path = (addr(2), addr(4));

    a.handle_outbound(handshake_init_bytes(), now);
    a.handle_timeout(now);
    let initial = a.transmits();
    assert_eq!(initial.len(), 3, "handshake fans out on every relay pair");

    let mut hs = Handshake::new(now).with_response(now);
    let _ = a.handle_inbound_network(&mut hs.initiator, &hs.response, recv_path, now);
    a.drain_events();
    let _ = a.transmits();

    a.handle_outbound(handshake_init_bytes(), now + Duration::from_secs(120));
    let rekey = a.transmits();
    assert_eq!(rekey.len(), 1, "re-key rides the primary: {rekey:?}");
    assert_eq!((rekey[0].local, rekey[0].remote), recv_path);
}

#[test]
fn rekey_without_primary_buffers_for_relay_fanout() {
    let mut a = agent_with_relay_pairs();
    let now = Instant::now();
    let recv_path = (addr(2), addr(4));

    a.handle_outbound(handshake_init_bytes(), now);
    a.handle_timeout(now);
    let _ = a.transmits();
    let mut hs = Handshake::new(now).with_response(now);
    let _ = a.handle_inbound_network(&mut hs.initiator, &hs.response, recv_path, now);
    a.drain_events();
    let _ = a.transmits();

    // Roam: the primary's local candidate goes away mid-session.
    assert!(a.remove_local_candidate(&Candidate::relayed(addr(2), addr(2)), now));
    assert_eq!(a.primary(), None, "removing primary's local must clear it");

    let rekey_at = now + Duration::from_secs(120);
    a.handle_outbound(handshake_init_bytes(), rekey_at);
    assert!(
        a.poll_transmit().is_none(),
        "buffered re-key must not transmit before the timer fires"
    );

    a.handle_timeout(rekey_at);
    let outbound = a.transmits();
    assert!(
        outbound.iter().any(|t| t.remote == addr(4)),
        "buffered re-key must fan out on a relay-involving pair: {outbound:?}"
    );
}

#[test]
fn trickled_candidate_after_handshake_still_gets_probed() {
    let mut a = PathAgent::new();
    let now = Instant::now();
    a.add_local_candidate(Candidate::host(addr(1)));
    a.add_local_candidate(Candidate::relayed(addr(2), addr(2)));
    a.add_remote_candidate(Candidate::relayed(addr(4), addr(4)), now);

    bootstrap_primary(&mut a, (addr(2), addr(4)), now);

    a.add_remote_candidate(Candidate::host(addr(3)), now);

    a.handle_timeout(now);
    let transmits = a.transmits();

    let _ = extract_probe_for(&transmits, (addr(1), addr(3)));
    let _ = extract_probe_for(&transmits, (addr(2), addr(3)));
}

// --- test harness ---

type Pair = (SocketAddr, SocketAddr);

fn ms(n: u64) -> Duration {
    Duration::from_millis(n)
}

/// Ergonomic wrappers over the poll-based `PathAgent` API used throughout the
/// tests, so each test reads as the sequence of events it exercises rather than
/// the drain/collect boilerplate.
trait AgentExt {
    /// Collect every queued transmit.
    fn transmits(&mut self) -> Vec<Transmit>;
    /// Drop every queued event.
    fn drain_events(&mut self);
    /// `handle_timeout(now)`, then collect the transmits it produced.
    fn tick(&mut self, now: Instant) -> Vec<Transmit>;
    /// Reply to `pair`'s probe (looked up in `transmits`) at `reply_at`. Does not
    /// drain events, so callers can still assert on `PrimaryChanged`.
    fn ack_probe(&mut self, transmits: &[Transmit], pair: Pair, reply_at: Instant);
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
}

/// Bootstrap on `recv_path`, select `primary` by ack'ing its probe, then settle
/// the evaluation window. Leaves the agent settled on `primary`.
fn settle_with_primary(a: &mut PathAgent, recv_path: Pair, primary: Pair, now: Instant) {
    bootstrap_primary(a, recv_path, now);
    let probes = a.tick(now);
    a.ack_probe(&probes, primary, now + ms(50));
    a.drain_events();
    a.handle_timeout(now + EVALUATION_WINDOW);
    let _ = a.transmits();
}

// --- shared fixtures ---

fn agent_with_relay_pairs() -> PathAgent {
    let mut a = PathAgent::new();
    let now = Instant::now();
    a.add_local_candidate(Candidate::host(addr(1)));
    a.add_local_candidate(Candidate::relayed(addr(2), addr(2)));
    a.add_remote_candidate(Candidate::host(addr(3)), now);
    a.add_remote_candidate(Candidate::relayed(addr(4), addr(4)), now);
    a
}

/// Synthetic — only the type byte matters to `handle_outbound`.
fn handshake_init_bytes() -> Vec<u8> {
    let mut bytes = vec![0u8; 148];
    bytes[0] = 1;
    bytes
}

fn bootstrap_primary(a: &mut PathAgent, recv_path: (SocketAddr, SocketAddr), now: Instant) {
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
    /// Initiator has emitted its init; responder hasn't consumed it.
    fn new(now: Instant) -> Self {
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
            Index::new_local(0),
            None,
            0,
            now,
            now,
            unix,
        );
        let responder = Tunn::new_at(
            priv_b,
            pub_a,
            None,
            None,
            Index::new_local(1),
            None,
            1,
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

    /// Consumes the init on the responder; `initiator` is then ready
    /// to authenticate `response`.
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
        Index::new_local(2),
        None,
        2,
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

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum EchoKind {
    Request,
    Reply,
}

#[derive(Debug, Clone, Copy)]
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

fn extract_probe_for(transmits: &[Transmit], pair: (SocketAddr, SocketAddr)) -> ProbeFields {
    let t = transmits
        .iter()
        .find(|t| (t.local, t.remote) == pair)
        .unwrap_or_else(|| panic!("no transmit for {pair:?}"));
    let Payload::Plaintext(ref packet) = t.payload else {
        panic!("expected Plaintext probe, got {:?}", t.payload);
    };
    parse_probe(packet).expect("parses as probe")
}
