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
    PROBE_TIMEOUT, PathAgent, Payload, Transmit,
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
fn outbound_handshake_init_arms_retransmits_with_initial_50ms_deadline() {
    let mut a = agent_with_relay_pairs();
    let now = Instant::now();
    a.handle_outbound(handshake_init_bytes(), now);
    a.handle_timeout(now);
    while a.poll_transmit().is_some() {}
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

    let retransmits: Vec<_> = std::iter::from_fn(|| a.poll_transmit()).collect();
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
    while a.poll_transmit().is_some() {}

    let mut t = now + Duration::from_millis(50);
    let expected_step_ms: [u64; 8] = [50, 50, 100, 200, 400, 800, 1600, 1600];
    for &expected_ms in &expected_step_ms {
        a.handle_timeout(t);
        while a.poll_transmit().is_some() {}
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
    while a.poll_transmit().is_some() {}
    let init_deadline = a.poll_timeout().expect("init armed retransmits");

    let mut hs = Handshake::new(now).with_response(now);
    let _ = a.handle_inbound_network(&mut hs.initiator, &hs.response, (addr(2), addr(4)), now);
    while a.poll_event().is_some() {}

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
    while a.poll_transmit().is_some() {}
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
    a.add_remote_candidate(Candidate::relayed(addr(30), addr(30)));

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

    let transmits: Vec<_> = std::iter::from_fn(|| a.poll_transmit()).collect();
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
    let first: Vec<_> = std::iter::from_fn(|| a.poll_transmit()).collect();
    let first_probe = extract_probe_for(&first, (addr(1), addr(3)));
    let first_seq = first_probe.seq;

    let _ = a.handle_inbound_tun(
        build_echo_reply(first_probe.id, first_probe.seq),
        (addr(1), addr(3)),
        now + Duration::from_millis(50),
    );

    a.handle_timeout(now + PROBE_INTERVAL);
    let second: Vec<_> = std::iter::from_fn(|| a.poll_transmit()).collect();
    let second_seq = extract_probe_for(&second, (addr(1), addr(3))).seq;

    assert_eq!(second_seq, first_seq.wrapping_add(1));
}

#[test]
fn probe_skips_while_inflight_until_probe_timeout_lapses() {
    let mut a = agent_with_relay_pairs();
    let now = Instant::now();
    bootstrap_primary(&mut a, (addr(2), addr(4)), now);

    a.handle_timeout(now);
    let first: Vec<_> = std::iter::from_fn(|| a.poll_transmit()).collect();
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

    a.handle_timeout(now);
    let inside: Vec<_> = std::iter::from_fn(|| a.poll_transmit()).collect();
    assert!(!inside.is_empty(), "expected probes inside window");

    let host_probe = extract_probe_for(&inside, primary);
    let _ = a.handle_inbound_tun(
        build_echo_reply(host_probe.id, host_probe.seq),
        primary,
        now + Duration::from_millis(50),
    );
    assert_eq!(a.primary(), Some(primary));
    while a.poll_event().is_some() {}

    a.handle_timeout(now + EVALUATION_WINDOW);
    while a.poll_transmit().is_some() {}

    a.handle_timeout(now + EVALUATION_WINDOW + PROBE_INTERVAL_LIVE - Duration::from_millis(1));
    assert!(a.poll_transmit().is_none(), "before live deadline");

    a.handle_timeout(now + EVALUATION_WINDOW + PROBE_INTERVAL_LIVE);
    let live: Vec<_> = std::iter::from_fn(|| a.poll_transmit()).collect();
    assert_eq!(live.len(), 1, "expected primary-only probe: {live:?}");
    assert_eq!((live[0].local, live[0].remote), primary);
}

#[test]
fn settle_keeps_poll_timeout_armed_for_primary_probes() {
    let mut a = agent_with_relay_pairs();
    let now = Instant::now();
    let primary = (addr(1), addr(3));
    bootstrap_primary(&mut a, (addr(2), addr(4)), now);

    a.handle_timeout(now);
    let outbound: Vec<_> = std::iter::from_fn(|| a.poll_transmit()).collect();
    let host_probe = extract_probe_for(&outbound, primary);
    let _ = a.handle_inbound_tun(
        build_echo_reply(host_probe.id, host_probe.seq),
        primary,
        now + Duration::from_millis(50),
    );
    assert_eq!(a.primary(), Some(primary));
    while a.poll_event().is_some() {} // drain PrimaryChanged

    a.handle_timeout(now + EVALUATION_WINDOW);
    while a.poll_transmit().is_some() {}

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
    while a.poll_event().is_some() {}

    a.handle_timeout(now);
    let outbound: Vec<_> = std::iter::from_fn(|| a.poll_transmit()).collect();
    let host_probe = extract_probe_for(&outbound, primary);
    let _ = a.handle_inbound_tun(
        build_echo_reply(host_probe.id, host_probe.seq),
        primary,
        now + Duration::from_millis(50),
    );
    while a.poll_event().is_some() {}

    a.handle_timeout(now + EVALUATION_WINDOW);
    while a.poll_transmit().is_some() {}

    let live_deadline = a.poll_timeout().expect("live cadence");

    // Re-feeding the same bytes hits the dedup before Tunn runs;
    // `reject_all()` proves it didn't.
    let _ = a.handle_inbound_network(
        &mut reject_all(),
        &hs.response,
        (addr(2), addr(4)),
        now + EVALUATION_WINDOW + Duration::from_secs(60),
    );
    while a.poll_event().is_some() {}

    assert_eq!(a.poll_timeout(), Some(live_deadline));
}

#[test]
fn inbound_handshake_reopens_evaluation_window_after_settle() {
    // Reopen even when the recv path is already known — catches the
    // roam case where signalling beats the data plane.
    let mut a = agent_with_relay_pairs();
    let now = Instant::now();
    let primary = (addr(1), addr(3));
    bootstrap_primary(&mut a, (addr(2), addr(4)), now);

    a.handle_timeout(now);
    let outbound: Vec<_> = std::iter::from_fn(|| a.poll_transmit()).collect();
    let host_probe = extract_probe_for(&outbound, primary);
    let _ = a.handle_inbound_tun(
        build_echo_reply(host_probe.id, host_probe.seq),
        primary,
        now + Duration::from_millis(50),
    );
    while a.poll_event().is_some() {}
    a.handle_timeout(now + EVALUATION_WINDOW);
    while a.poll_transmit().is_some() {}

    let live_tick = now + EVALUATION_WINDOW + PROBE_INTERVAL_LIVE;
    a.handle_timeout(live_tick);
    let live_probes: Vec<_> = std::iter::from_fn(|| a.poll_transmit()).collect();
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
    while a.poll_event().is_some() {}
    a.handle_timeout(reopen_at);
    let reopened_probes: Vec<_> = std::iter::from_fn(|| a.poll_transmit()).collect();
    assert!(
        reopened_probes.len() > 1,
        "all pairs should probe after reopen, got {reopened_probes:?}"
    );
}

#[test]
fn inbound_echo_reply_updates_smoothed_rtt_and_selects_primary() {
    let mut a = agent_with_relay_pairs();
    let now = Instant::now();
    bootstrap_primary(&mut a, (addr(2), addr(4)), now);

    a.handle_timeout(now);
    let outbound: Vec<_> = std::iter::from_fn(|| a.poll_transmit()).collect();
    let probe_on_host_pair = extract_probe_for(&outbound, (addr(1), addr(3)));

    let reply = build_echo_reply(probe_on_host_pair.id, probe_on_host_pair.seq);
    let later = now + Duration::from_millis(50);
    let handled = a.handle_inbound_tun(reply, (addr(1), addr(3)), later);
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

    while a.poll_transmit().is_some() {}

    a.handle_timeout(now);
    let probes: Vec<_> = std::iter::from_fn(|| a.poll_transmit()).collect();

    let _ = extract_probe_for(&probes, (addr(1), addr(99)));
}

#[test]
fn signaled_candidate_promotes_peer_reflexive_in_place() {
    let mut a = agent_with_relay_pairs();
    let now = Instant::now();
    bootstrap_primary(&mut a, (addr(2), addr(4)), now);

    let _ = a.handle_inbound_tun(build_echo_request(0, 1), (addr(1), addr(99)), now);
    while a.poll_transmit().is_some() {}

    a.handle_timeout(now);
    let probes: Vec<_> = std::iter::from_fn(|| a.poll_transmit()).collect();
    let probe = extract_probe_for(&probes, (addr(1), addr(99)));
    let later = now + Duration::from_millis(50);
    let _ = a.handle_inbound_tun(
        build_echo_reply(probe.id, probe.seq),
        (addr(1), addr(99)),
        later,
    );

    assert!(a.pairs().any(|p| p == (addr(1), addr(99))));

    a.add_remote_candidate(Candidate::server_reflexive(addr(99), addr(98)));

    assert!(a.pairs().any(|p| p == (addr(1), addr(99))));
    let count_at_99 = a.pairs().filter(|(_, r)| *r == addr(99)).count();
    assert_eq!(count_at_99, 2, "pairs at addr(99): one per local");

    a.add_remote_candidate(Candidate::server_reflexive(addr(99), addr(98)));
    let count_at_99_again = a.pairs().filter(|(_, r)| *r == addr(99)).count();
    assert_eq!(count_at_99_again, 2, "second signal must not duplicate");
}

#[test]
fn primary_changes_when_lower_tier_pair_becomes_alive() {
    let mut a = agent_with_relay_pairs();
    let now = Instant::now();
    bootstrap_primary(&mut a, (addr(2), addr(4)), now);

    a.handle_timeout(now);
    let outbound: Vec<_> = std::iter::from_fn(|| a.poll_transmit()).collect();

    let relay_probe = extract_probe_for(&outbound, (addr(2), addr(4)));
    let _ = a.handle_inbound_tun(
        build_echo_reply(relay_probe.id, relay_probe.seq),
        (addr(2), addr(4)),
        now + Duration::from_millis(100),
    );
    assert_eq!(a.primary(), Some((addr(2), addr(4))));

    let host_probe = extract_probe_for(&outbound, (addr(1), addr(3)));
    while a.poll_event().is_some() {}
    let _ = a.handle_inbound_tun(
        build_echo_reply(host_probe.id, host_probe.seq),
        (addr(1), addr(3)),
        now + Duration::from_millis(150),
    );
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
    a.add_local_candidate(Candidate::host(addr(1)));
    a.add_local_candidate(Candidate::relayed(addr(2), addr(2)));
    a.add_remote_candidate(Candidate::host(addr(3)));
    a.add_remote_candidate(Candidate::relayed(addr(4), addr(4)));
    let now = Instant::now();

    let remote_relay_pair = (addr(1), addr(4));
    bootstrap_primary(&mut a, remote_relay_pair, now);

    a.handle_timeout(now);
    let outbound: Vec<_> = std::iter::from_fn(|| a.poll_transmit()).collect();

    let remote_relay_probe = extract_probe_for(&outbound, remote_relay_pair);
    let _ = a.handle_inbound_tun(
        build_echo_reply(remote_relay_probe.id, remote_relay_probe.seq),
        remote_relay_pair,
        now + Duration::from_millis(50),
    );
    assert_eq!(a.primary(), Some(remote_relay_pair));
    while a.poll_event().is_some() {}

    let local_relay_pair = (addr(2), addr(3));
    let local_relay_probe = extract_probe_for(&outbound, local_relay_pair);
    let _ = a.handle_inbound_tun(
        build_echo_reply(local_relay_probe.id, local_relay_probe.seq),
        local_relay_pair,
        now + Duration::from_millis(100),
    );
    assert_eq!(
        a.primary(),
        Some(local_relay_pair),
        "local-relay pair should beat remote-relay pair at the same tier",
    );
}

#[test]
fn primary_prefers_ipv6_over_ipv4_at_same_tier() {
    let mut a = PathAgent::new();
    a.add_local_candidate(Candidate::host(addr(1)));
    a.add_local_candidate(Candidate::host(addr_v6(11)));
    a.add_remote_candidate(Candidate::host(addr(2)));
    a.add_remote_candidate(Candidate::host(addr_v6(12)));
    let now = Instant::now();
    bootstrap_primary(&mut a, (addr(1), addr(2)), now);

    a.handle_timeout(now);
    let outbound: Vec<_> = std::iter::from_fn(|| a.poll_transmit()).collect();

    let v4_probe = extract_probe_for(&outbound, (addr(1), addr(2)));
    let _ = a.handle_inbound_tun(
        build_echo_reply(v4_probe.id, v4_probe.seq),
        (addr(1), addr(2)),
        now + Duration::from_millis(50),
    );
    assert_eq!(a.primary(), Some((addr(1), addr(2))));

    while a.poll_event().is_some() {}

    let v6_probe = extract_probe_for(&outbound, (addr_v6(11), addr_v6(12)));
    let _ = a.handle_inbound_tun(
        build_echo_reply(v6_probe.id, v6_probe.seq),
        (addr_v6(11), addr_v6(12)),
        now + Duration::from_millis(100),
    );
    assert_eq!(
        a.primary(),
        Some((addr_v6(11), addr_v6(12))),
        "v6 pair should beat v4 pair at the same tier",
    );
}

#[test]
fn primary_holds_better_bucket_when_incumbent_has_no_rtt() {
    let mut a = PathAgent::new();
    a.add_local_candidate(Candidate::host(addr(1)));
    a.add_local_candidate(Candidate::host(addr_v6(11)));
    a.add_remote_candidate(Candidate::host(addr(2)));
    a.add_remote_candidate(Candidate::host(addr_v6(12)));
    let now = Instant::now();
    let v6_pair = (addr_v6(11), addr_v6(12));

    bootstrap_primary(&mut a, v6_pair, now);
    assert_eq!(a.primary(), Some(v6_pair));

    a.handle_timeout(now);
    let outbound: Vec<_> = std::iter::from_fn(|| a.poll_transmit()).collect();
    let v4_probe = extract_probe_for(&outbound, (addr(1), addr(2)));
    let _ = a.handle_inbound_tun(
        build_echo_reply(v4_probe.id, v4_probe.seq),
        (addr(1), addr(2)),
        now + Duration::from_millis(40),
    );

    assert_eq!(
        a.primary(),
        Some(v6_pair),
        "v4 must not displace a no-RTT v6 incumbent — discrete prefix wins",
    );
}

#[test]
fn primary_prefers_family_matched_relay_within_same_v6_bucket() {
    let mut a = PathAgent::new();
    let matched_local_alloc = addr_v6(10);
    let mismatched_local_alloc = addr_v6(11);
    a.add_local_candidate(Candidate::relayed(matched_local_alloc, addr_v6(100)));
    a.add_local_candidate(Candidate::relayed(mismatched_local_alloc, addr(101)));
    a.add_remote_candidate(Candidate::relayed(addr_v6(20), addr_v6(20)));
    let now = Instant::now();
    bootstrap_primary(&mut a, (mismatched_local_alloc, addr_v6(20)), now);

    a.handle_timeout(now);
    let outbound: Vec<_> = std::iter::from_fn(|| a.poll_transmit()).collect();

    let mismatched_pair = (mismatched_local_alloc, addr_v6(20));
    let mismatched_probe = extract_probe_for(&outbound, mismatched_pair);
    let _ = a.handle_inbound_tun(
        build_echo_reply(mismatched_probe.id, mismatched_probe.seq),
        mismatched_pair,
        now + Duration::from_millis(50),
    );
    assert_eq!(a.primary(), Some(mismatched_pair));
    while a.poll_event().is_some() {}

    let matched_pair = (matched_local_alloc, addr_v6(20));
    let matched_probe = extract_probe_for(&outbound, matched_pair);
    let _ = a.handle_inbound_tun(
        build_echo_reply(matched_probe.id, matched_probe.seq),
        matched_pair,
        now + Duration::from_millis(100),
    );
    assert_eq!(
        a.primary(),
        Some(matched_pair),
        "matched-family relay pair should beat mismatched-family at same v6 tier",
    );
}

#[test]
fn family_match_dominates_ipv6_preference() {
    let mut a = PathAgent::new();
    let v6_mismatched_local_alloc = addr_v6(10);
    let v4_matched_local_alloc = addr(11);
    a.add_local_candidate(Candidate::relayed(v6_mismatched_local_alloc, addr(100)));
    a.add_local_candidate(Candidate::relayed(v4_matched_local_alloc, addr(101)));
    a.add_remote_candidate(Candidate::relayed(addr_v6(20), addr_v6(20)));
    a.add_remote_candidate(Candidate::relayed(addr(30), addr(30)));
    let now = Instant::now();
    bootstrap_primary(&mut a, (v6_mismatched_local_alloc, addr_v6(20)), now);
    a.handle_timeout(now);
    let outbound: Vec<_> = std::iter::from_fn(|| a.poll_transmit()).collect();

    let v6_pair = (v6_mismatched_local_alloc, addr_v6(20));
    let v6_probe = extract_probe_for(&outbound, v6_pair);
    let _ = a.handle_inbound_tun(
        build_echo_reply(v6_probe.id, v6_probe.seq),
        v6_pair,
        now + Duration::from_millis(50),
    );
    assert_eq!(a.primary(), Some(v6_pair));
    while a.poll_event().is_some() {}

    let v4_pair = (v4_matched_local_alloc, addr(30));
    let v4_probe = extract_probe_for(&outbound, v4_pair);
    let _ = a.handle_inbound_tun(
        build_echo_reply(v4_probe.id, v4_probe.seq),
        v4_pair,
        now + Duration::from_millis(100),
    );
    assert_eq!(
        a.primary(),
        Some(v4_pair),
        "fully-matched v4 pair should outrank a mismatched-family v6 pair",
    );
}

#[test]
fn primary_holds_when_rtt_gain_is_within_hysteresis_margin() {
    let mut a = PathAgent::new();
    a.add_local_candidate(Candidate::host(addr(1)));
    a.add_remote_candidate(Candidate::host(addr(3)));
    a.add_remote_candidate(Candidate::host(addr(4)));
    let now = Instant::now();

    bootstrap_primary(&mut a, (addr(1), addr(3)), now);

    a.handle_timeout(now);
    let outbound: Vec<_> = std::iter::from_fn(|| a.poll_transmit()).collect();

    let incumbent_probe = extract_probe_for(&outbound, (addr(1), addr(3)));
    let _ = a.handle_inbound_tun(
        build_echo_reply(incumbent_probe.id, incumbent_probe.seq),
        (addr(1), addr(3)),
        now + Duration::from_millis(50),
    );
    assert_eq!(a.primary(), Some((addr(1), addr(3))));
    while a.poll_event().is_some() {}

    // 45ms is a 5ms gain over the 50ms incumbent — inside the 10ms floor.
    let challenger_probe = extract_probe_for(&outbound, (addr(1), addr(4)));
    let _ = a.handle_inbound_tun(
        build_echo_reply(challenger_probe.id, challenger_probe.seq),
        (addr(1), addr(4)),
        now + Duration::from_millis(45),
    );

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
    a.add_local_candidate(Candidate::host(addr(1)));
    a.add_remote_candidate(Candidate::host(addr(3)));
    a.add_remote_candidate(Candidate::host(addr(4)));
    let now = Instant::now();
    bootstrap_primary(&mut a, (addr(1), addr(3)), now);

    a.handle_timeout(now);
    let outbound: Vec<_> = std::iter::from_fn(|| a.poll_transmit()).collect();

    let incumbent_probe = extract_probe_for(&outbound, (addr(1), addr(3)));
    let _ = a.handle_inbound_tun(
        build_echo_reply(incumbent_probe.id, incumbent_probe.seq),
        (addr(1), addr(3)),
        now + Duration::from_millis(50),
    );
    assert_eq!(a.primary(), Some((addr(1), addr(3))));
    while a.poll_event().is_some() {}

    let challenger_probe = extract_probe_for(&outbound, (addr(1), addr(4)));
    let _ = a.handle_inbound_tun(
        build_echo_reply(challenger_probe.id, challenger_probe.seq),
        (addr(1), addr(4)),
        now + Duration::from_millis(30),
    );

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
    while a.poll_transmit().is_some() {}

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
    while a.poll_transmit().is_some() {}

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
    let outbound: Vec<_> = std::iter::from_fn(|| a.poll_transmit()).collect();
    let initial_probe = extract_probe_for(&outbound, initial_path);
    let _ = a.handle_inbound_tun(
        build_echo_reply(initial_probe.id, initial_probe.seq),
        initial_path,
        now + Duration::from_millis(40),
    );
    assert_eq!(a.primary(), Some(initial_path));
    while a.poll_event().is_some() {}
    while a.poll_transmit().is_some() {}

    let roam_at = now + Duration::from_secs(60);
    let mut hs2 = Handshake::new(roam_at).with_response(roam_at);
    let _ = a.handle_inbound_network(&mut hs2.initiator, &hs2.response, roam_path, roam_at);
    assert_eq!(a.primary(), Some(roam_path));
    while a.poll_event().is_some() {}

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
    let initial: Vec<_> = std::iter::from_fn(|| a.poll_transmit()).collect();
    assert_eq!(initial.len(), 3, "handshake fans out on every relay pair");

    let mut hs = Handshake::new(now).with_response(now);
    let _ = a.handle_inbound_network(&mut hs.initiator, &hs.response, recv_path, now);
    while a.poll_event().is_some() {}
    while a.poll_transmit().is_some() {}

    a.handle_outbound(handshake_init_bytes(), now + Duration::from_secs(120));
    let rekey: Vec<_> = std::iter::from_fn(|| a.poll_transmit()).collect();
    assert_eq!(rekey.len(), 1, "re-key rides the primary: {rekey:?}");
    assert_eq!((rekey[0].local, rekey[0].remote), recv_path);
}

#[test]
fn trickled_candidate_after_handshake_still_gets_probed() {
    let mut a = PathAgent::new();
    a.add_local_candidate(Candidate::host(addr(1)));
    a.add_local_candidate(Candidate::relayed(addr(2), addr(2)));
    a.add_remote_candidate(Candidate::relayed(addr(4), addr(4)));

    let now = Instant::now();
    bootstrap_primary(&mut a, (addr(2), addr(4)), now);

    a.add_remote_candidate(Candidate::host(addr(3)));

    a.handle_timeout(now);
    let transmits: Vec<_> = std::iter::from_fn(|| a.poll_transmit()).collect();

    let _ = extract_probe_for(&transmits, (addr(1), addr(3)));
    let _ = extract_probe_for(&transmits, (addr(2), addr(3)));
}

// --- shared fixtures ---

fn agent_with_relay_pairs() -> PathAgent {
    let mut a = PathAgent::new();
    a.add_local_candidate(Candidate::host(addr(1)));
    a.add_local_candidate(Candidate::relayed(addr(2), addr(2)));
    a.add_remote_candidate(Candidate::host(addr(3)));
    a.add_remote_candidate(Candidate::relayed(addr(4), addr(4)));
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
    while a.poll_event().is_some() {}
    while a.poll_transmit().is_some() {}
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
