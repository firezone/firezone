//! Scenario coverage for the probe-driven path model.
//!
//! Layout follows the model's life-cycle: bootstrap via handshake fan-out,
//! probing (bursts, triggered checks, peer-reflexive discovery), selection
//! (scoring, hysteresis, freshness), and failure handling (roam recovery,
//! WireGuard distress signals). Flow-level coverage lives in the tunnel
//! proptest.

use std::net::{IpAddr, SocketAddr};
use std::ops::ControlFlow;
use std::time::{Duration, Instant};

use boringtun::noise::{Index, Tunn, TunnResult};
use boringtun::x25519::{PublicKey, StaticSecret};
use ip_packet::{Icmpv6Type, IpPacket};
use path_agent::{
    Candidate, Event, PROBE_BURST_GAPS, PROBE_DST, PROBE_INTERVAL_LIVE, PROBE_SRC, PathAgent,
    Payload, REKEY_DISTRESS_INTERVAL, RESPONDER_DEDUP_TTL, Transmit,
};

// --- bootstrap: handshake fan-out and nomination ---

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
fn outbound_init_keeps_retransmitting_until_answered() {
    let mut a = agent_with_relay_pairs();
    let now = Instant::now();

    a.handle_outbound(handshake_init_bytes(), now);
    a.handle_timeout(now);
    let _ = a.transmits();

    a.handle_timeout(now + Duration::from_secs(11));
    assert!(a.poll_event().is_none(), "no BootstrapFailed-style event");
    assert!(
        a.poll_transmit().is_some(),
        "retransmits should still be firing"
    );
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
fn inbound_handshake_init_validates_then_nominates_when_pathless() {
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
fn srflx_local_uses_base_as_send_from_address() {
    let mut a = PathAgent::new();
    let now = Instant::now();

    let mapped = addr(10);
    let base = addr(11);
    a.add_local_candidate(Candidate::server_reflexive(mapped, base), now);
    a.add_local_candidate(Candidate::relayed(addr(20), addr(20)), now);
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

// --- probing: bursts, triggered checks, peer-reflexive discovery ---

#[test]
fn pairs_probe_in_a_front_loaded_burst_then_only_the_primary_stays_on_live_cadence() {
    let mut a = PathAgent::new();
    let t0 = Instant::now();
    a.add_local_candidate(Candidate::host(addr(1)), t0);
    a.add_remote_candidate(Candidate::host(addr(2)), t0);
    a.add_remote_candidate(Candidate::host(addr(3)), t0);
    bootstrap_primary(&mut a, (addr(1), addr(2)), t0);

    let burst = a.advance(t0, t0 + secs(5));

    // Both pairs fire the full front-loaded ladder without waiting for
    // replies — after a roam, the peer's NAT filter may open between two
    // probes and the next one must follow promptly.
    let expected = burst_ladder(t0);
    assert_eq!(burst.probe_times((addr(1), addr(2))), expected);
    assert_eq!(burst.probe_times((addr(1), addr(3))), expected);

    let after_burst = a.advance(t0 + secs(5), t0 + secs(60));

    // Dormant pairs stay quiet; the primary keeps its RTT fresh and its NAT
    // mappings warm.
    assert_eq!(after_burst.probe_times((addr(1), addr(3))), vec![]);
    assert_eq!(
        after_burst.probe_times((addr(1), addr(2))),
        vec![
            t0 + secs(2) + PROBE_INTERVAL_LIVE,
            t0 + secs(2) + PROBE_INTERVAL_LIVE * 2
        ],
    );
}

#[test]
fn late_reply_to_an_earlier_burst_probe_still_measures_rtt() {
    let mut a = PathAgent::new();
    let t0 = Instant::now();
    a.add_local_candidate(Candidate::host(addr(1)), t0);
    a.add_remote_candidate(Candidate::host(addr(2)), t0);
    a.add_remote_candidate(Candidate::host(addr(3)), t0);
    bootstrap_primary(&mut a, (addr(1), addr(2)), t0);

    let pair = (addr(1), addr(3));
    let burst = a.advance(t0, t0 + ms(300));
    let probes = burst.probes_for(pair);
    assert_eq!(probes.len(), 2, "two ladder steps within 300ms");

    // The reply to the *first* probe arrives after the second was sent.
    let first = probes[0];
    let _ = a.handle_inbound_tun(build_echo_reply(first.id, first.seq), pair, t0 + ms(400));

    assert_eq!(
        a.primary(),
        Some(pair),
        "the late reply must measure and win against the reply-less incumbent"
    );
}

#[test]
fn probe_seq_advances_per_pair_per_fire() {
    let mut a = PathAgent::new();
    let t0 = Instant::now();
    a.add_local_candidate(Candidate::host(addr(1)), t0);
    a.add_remote_candidate(Candidate::host(addr(2)), t0);
    a.add_remote_candidate(Candidate::host(addr(3)), t0);
    bootstrap_primary(&mut a, (addr(1), addr(2)), t0);

    let burst = a.advance(t0, t0 + secs(3));
    let seqs: Vec<u16> = burst
        .probes_for((addr(1), addr(3)))
        .iter()
        .map(|p| p.seq)
        .collect();

    let first = seqs[0];
    let expected: Vec<u16> = (0..seqs.len() as u16)
        .map(|i| first.wrapping_add(i))
        .collect();
    assert_eq!(seqs, expected);
}

#[test]
fn trickled_candidate_probes_immediately_even_while_dormant() {
    let mut a = PathAgent::new();
    let t0 = Instant::now();
    a.add_local_candidate(Candidate::host(addr(1)), t0);
    a.add_local_candidate(Candidate::relayed(addr(2), addr(2)), t0);
    a.add_remote_candidate(Candidate::relayed(addr(4), addr(4)), t0);
    bootstrap_primary(&mut a, (addr(2), addr(4)), t0);

    // Exhaust every burst; the agent is dormant except for the primary.
    let _ = a.advance(t0, t0 + secs(10));

    let t1 = t0 + secs(10);
    a.add_remote_candidate(Candidate::host(addr(3)), t1);

    let activity = a.advance(t1, t1 + secs(1));
    assert!(!activity.probes_for((addr(1), addr(3))).is_empty());
    assert!(!activity.probes_for((addr(2), addr(3))).is_empty());
}

#[test]
fn candidate_arrival_reprobes_the_current_primary() {
    let mut a = PathAgent::new();
    let t0 = Instant::now();
    a.add_local_candidate(Candidate::host(addr(1)), t0);
    a.add_remote_candidate(Candidate::host(addr(2)), t0);
    bootstrap_primary(&mut a, (addr(1), addr(2)), t0);
    let _ = a.advance(t0, t0 + secs(10));

    // New candidates usually mean the peer's situation changed — the
    // incumbent might be dead now.
    let t1 = t0 + secs(10);
    a.add_remote_candidate(Candidate::host(addr(3)), t1);

    let activity = a.advance(t1, t1 + secs(1));
    assert!(
        !activity.probes_for((addr(1), addr(2))).is_empty(),
        "candidate arrival must re-probe the primary"
    );
}

#[test]
fn inbound_probe_triggers_a_probe_back_on_the_same_pair() {
    let mut a = PathAgent::new();
    let t0 = Instant::now();
    a.add_local_candidate(Candidate::host(addr(1)), t0);
    a.add_remote_candidate(Candidate::host(addr(2)), t0);
    a.add_remote_candidate(Candidate::host(addr(3)), t0);
    bootstrap_primary(&mut a, (addr(1), addr(2)), t0);
    let _ = a.advance(t0, t0 + secs(10));

    // An inbound probe proves the reverse NAT filter is open right now;
    // probing back completes the hole punch in one round trip.
    let t1 = t0 + secs(10);
    let _ = a.handle_inbound_tun(build_echo_request(0, 7), (addr(1), addr(3)), t1);

    let reply = a.poll_transmit().expect("echo reply queued");
    assert_eq!((reply.local, reply.remote), (addr(1), addr(3)));

    let activity = a.advance(t1, t1 + secs(1));
    assert!(
        !activity.probes_for((addr(1), addr(3))).is_empty(),
        "inbound probe must trigger a probe back"
    );
}

#[test]
fn inbound_probe_from_unknown_source_registers_peer_reflexive_and_probes_it() {
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
    let later = now + ms(50);
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
fn two_connected_agents_go_quiet_after_converging() {
    // Regression test for a probe storm: every inbound probe used to
    // trigger a probe back unconditionally, so two agents ping-ponged
    // bursts at RTT cadence, forever.
    let t0 = Instant::now();
    let mut hs = Handshake::new(t0).with_response(t0);
    let mut a = PathAgent::new();
    let mut b = PathAgent::new();
    a.add_local_candidate(Candidate::host(addr(1)), t0);
    a.add_remote_candidate(Candidate::host(addr(2)), t0);
    b.add_local_candidate(Candidate::host(addr(2)), t0);
    b.add_remote_candidate(Candidate::host(addr(1)), t0);
    let _ = b.handle_inbound_network(&mut hs.responder, &hs.init, (addr(2), addr(1)), t0);
    let _ = a.handle_inbound_network(&mut hs.initiator, &hs.response, (addr(1), addr(2)), t0);

    // Pump both agents against each other with instant delivery.
    let mut sent_by_a = 0;
    let mut now = t0;
    while now < t0 + secs(60) {
        now += ms(10);
        a.handle_timeout(now);
        b.handle_timeout(now);

        for t in a.transmits() {
            if matches!(t.payload, Payload::Plaintext(_)) {
                sent_by_a += 1;
            }
            deliver(t, &mut b, now);
        }
        for t in b.transmits() {
            deliver(t, &mut a, now);
        }
        a.drain_events();
        b.drain_events();
    }

    // One burst plus live-cadence probes and the occasional triggered
    // re-validation — orders of magnitude below a storm.
    assert!(
        sent_by_a < 30,
        "expected probing to go quiet after convergence, got {sent_by_a} packets in 60s",
    );
}

/// Deliver a plaintext transmit to the other agent, from its point of view.
fn deliver(t: Transmit, to: &mut PathAgent, now: Instant) {
    let Payload::Plaintext(packet) = t.payload else {
        return;
    };

    let _ = to.handle_inbound_tun(*packet, (t.remote, t.local), now);
}

// --- selection: scoring, hysteresis, freshness ---

#[test]
fn inbound_echo_reply_updates_rtt_and_selects_primary() {
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
    a.add_local_candidate(Candidate::host(addr(1)), now);
    a.add_local_candidate(Candidate::relayed(addr(2), addr(2)), now);
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
    a.add_local_candidate(Candidate::relayed(addr(2), addr(2)), now);
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
    a.add_local_candidate(Candidate::host(addr(1)), now);
    a.add_local_candidate(Candidate::host(addr_v6(11)), now);
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
    a.add_local_candidate(Candidate::host(addr(1)), now);
    a.add_local_candidate(Candidate::host(addr_v6(11)), now);
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
    a.add_local_candidate(Candidate::relayed(matched_local_alloc, addr_v6(100)), now);
    a.add_local_candidate(Candidate::relayed(mismatched_local_alloc, addr(101)), now);
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
    a.add_local_candidate(
        Candidate::relayed(v6_mismatched_local_alloc, addr(100)),
        now,
    );
    a.add_local_candidate(Candidate::relayed(v4_matched_local_alloc, addr(101)), now);
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
    a.add_local_candidate(Candidate::host(addr(1)), now);
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
    a.add_local_candidate(Candidate::host(addr(1)), now);
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

// --- WireGuard-signalled failure handling ---

#[test]
fn probe_loss_alone_never_demotes_the_primary() {
    let (mut a, t0) = direct_primary_with_relay_fallback();

    // The primary's live probes go unanswered for a minute (e.g. the peer is
    // busy and drops probes while data flows fine): no WireGuard signal, no
    // demotion — even when a relay pair proves alive via a triggered check.
    let _ = a.advance(t0, t0 + secs(60));
    let t1 = t0 + secs(60);
    prove_pair_alive(&mut a, (addr(2), addr(4)), t1);

    assert_eq!(
        a.primary(),
        Some((addr(1), addr(3))),
        "probe loss without a WireGuard signal must not demote the primary",
    );
    assert!(a.poll_event().is_none());
}

#[test]
fn unanswered_rekey_fails_over_to_a_fresh_pair() {
    let (mut a, t0) = direct_primary_with_relay_fallback();

    // The primary dies silently; its RTT goes stale.
    let _ = a.advance(t0, t0 + secs(60));
    let t1 = t0 + secs(60);

    // boringtun re-keys (rides the primary), gets no answer and retries:
    // WireGuard-level failure evidence.
    a.handle_outbound(handshake_init_bytes(), t1);
    let _ = a.transmits();
    a.handle_outbound(handshake_init_bytes(), t1 + secs(5));
    let _ = a.transmits();

    // The re-evaluation bursts every pair; the relay pair answers.
    let t2 = t1 + secs(5);
    prove_pair_alive(&mut a, (addr(2), addr(4)), t2);

    assert_eq!(
        a.primary(),
        Some((addr(2), addr(4))),
        "with WireGuard distress, the fresh relay pair must displace the dead direct primary",
    );
}

#[test]
fn peer_rekeying_early_fails_over_too() {
    let (mut a, t0) = direct_primary_with_relay_fallback();

    // The peer stops hearing us (one-way blackhole): our WireGuard state
    // stays healthy (we keep receiving), but the peer's escalation shows as
    // repeated distinct inits in quick succession.
    let _ = a.advance(t0, t0 + secs(60));
    let t1 = t0 + secs(60);

    let mut hs1 = Handshake::new(t1);
    let _ = a.handle_inbound_network(&mut hs1.responder, &hs1.init, (addr(2), addr(4)), t1);
    let t2 = t1 + REKEY_DISTRESS_INTERVAL / 2;
    let mut hs2 = Handshake::new(t2);
    let _ = a.handle_inbound_network(&mut hs2.responder, &hs2.init, (addr(2), addr(4)), t2);
    a.drain_events();
    let _ = a.transmits();

    prove_pair_alive(&mut a, (addr(2), addr(4)), t2);

    assert_eq!(
        a.primary(),
        Some((addr(2), addr(4))),
        "repeated early re-keys are peer distress; the fresh pair must take over",
    );
}

#[test]
fn routine_rekeys_do_not_restart_probing() {
    let (mut a, t0) = direct_primary_with_relay_fallback();
    let _ = a.advance(t0, t0 + secs(10));

    // An answered re-key minutes later is routine: it rides the primary and
    // must not burst probes.
    let t1 = t0 + secs(120);
    a.handle_outbound(handshake_init_bytes(), t1);
    let rekey = a.transmits();
    assert_eq!(rekey.len(), 1, "re-key rides the primary: {rekey:?}");
    assert_eq!((rekey[0].local, rekey[0].remote), (addr(1), addr(3)));

    let activity = a.advance(t1, t1 + secs(3));
    assert!(
        activity.probes_for((addr(2), addr(4))).is_empty(),
        "a routine re-key must not burst probes on other pairs",
    );
}

#[test]
fn peer_rekeys_minutes_apart_are_not_distress() {
    let (mut a, t0) = direct_primary_with_relay_fallback();
    let _ = a.advance(t0, t0 + secs(10));

    let t1 = t0 + secs(120);
    let mut hs = Handshake::new(t1);
    let _ = a.handle_inbound_network(&mut hs.responder, &hs.init, (addr(1), addr(3)), t1);
    a.drain_events();
    let _ = a.transmits();

    let activity = a.advance(t1, t1 + secs(3));
    assert!(
        activity.probes_for((addr(2), addr(4))).is_empty(),
        "a lone re-key minutes after the last one must not burst probes",
    );
}

#[test]
fn dead_pair_with_stale_rtt_does_not_win_back_the_primary() {
    let (mut a, t0) = direct_primary_with_relay_fallback();

    // Fail over to the relay pair via WireGuard distress.
    let _ = a.advance(t0, t0 + secs(60));
    let t1 = t0 + secs(60);
    a.handle_outbound(handshake_init_bytes(), t1);
    let _ = a.transmits();
    a.handle_outbound(handshake_init_bytes(), t1 + secs(5));
    let _ = a.transmits();
    prove_pair_alive(&mut a, (addr(2), addr(4)), t1 + secs(5));
    assert_eq!(a.primary(), Some((addr(2), addr(4))));
    a.drain_events();

    // Later replies on the (still alive) relay pair re-run selection. The
    // dead direct pair has a better bucket but only a stale RTT — it must
    // not hijack the primary on a meaningless measurement.
    let t2 = t1 + secs(30);
    prove_pair_alive(&mut a, (addr(2), addr(4)), t2);

    assert_eq!(
        a.primary(),
        Some((addr(2), addr(4))),
        "a stale RTT must not put the dead direct pair back in charge",
    );
}

// --- roam recovery ---

#[test]
fn roam_recovers_the_data_path_via_probes_without_a_handshake() {
    let mut a = PathAgent::new();
    let t0 = Instant::now();
    a.add_local_candidate(Candidate::host(addr(1)), t0);
    a.add_remote_candidate(Candidate::host(addr(9)), t0);
    bootstrap_primary(&mut a, (addr(1), addr(9)), t0);
    let _ = a.advance(t0, t0 + secs(10));

    // Roam: all local candidates are gone; the WireGuard session is kept.
    let t1 = t0 + secs(60);
    a.rebuild(|_| true, t1);
    assert_eq!(a.primary(), None);

    // The new socket produces a new host candidate; the peer's candidates
    // survived the rebuild, so pairs form and probe immediately.
    a.add_local_candidate(Candidate::host(addr(5)), t1);

    let recovery = a.advance(t1, t1 + secs(1));
    let probes = recovery.probes_for((addr(5), addr(9)));
    assert!(
        !probes.is_empty(),
        "roamed pair must probe without any handshake"
    );

    let _ = a.handle_inbound_tun(
        build_echo_reply(probes[0].id, probes[0].seq),
        (addr(5), addr(9)),
        t1 + ms(50),
    );

    assert_eq!(
        a.primary(),
        Some((addr(5), addr(9))),
        "first probe reply must restore the data path",
    );
    assert!(
        recovery
            .transmits
            .iter()
            .all(|(_, t)| matches!(t.payload, Payload::Plaintext(_))),
        "recovery must not require any handshake traffic",
    );
    assert_eq!(recovery.events, vec![], "no path until the reply arrives");
}

#[test]
fn retired_primary_stops_live_probing() {
    let mut a = PathAgent::new();
    let t0 = Instant::now();
    a.add_local_candidate(Candidate::host(addr(1)), t0);
    a.add_remote_candidate(Candidate::host(addr(3)), t0);
    a.add_remote_candidate(Candidate::host(addr(4)), t0);
    bootstrap_primary(&mut a, (addr(1), addr(3)), t0);

    let probes = a.tick(t0);
    a.ack_probe(&probes, (addr(1), addr(3)), t0 + ms(50));
    a.ack_probe(&probes, (addr(1), addr(4)), t0 + ms(10));
    assert_eq!(a.primary(), Some((addr(1), addr(4))));
    a.drain_events();

    // Finish the bursts, then watch the live cadence.
    let _ = a.advance(t0, t0 + secs(3));
    let live = a.advance(t0 + secs(3), t0 + secs(60));

    assert_eq!(
        live.probe_times((addr(1), addr(3))),
        vec![],
        "the retired primary must not keep probing at the live cadence",
    );
    assert!(
        !live.probe_times((addr(1), addr(4))).is_empty(),
        "the new primary keeps probing at the live cadence",
    );
}

#[test]
fn recovering_a_path_requests_a_rekey_to_notify_the_remote() {
    let mut a = PathAgent::new();
    let t0 = Instant::now();
    a.add_local_candidate(Candidate::host(addr(1)), t0);
    a.add_remote_candidate(Candidate::host(addr(9)), t0);
    bootstrap_primary(&mut a, (addr(1), addr(9)), t0);
    a.drain_events();
    let _ = a.advance(t0, t0 + secs(10));

    let t1 = t0 + secs(60);
    a.rebuild(|_| true, t1);
    a.add_local_candidate(Candidate::host(addr(5)), t1);
    let recovery = a.advance(t1, t1 + secs(1));
    let probes = recovery.probes_for((addr(5), addr(9)));
    let _ = a.handle_inbound_tun(
        build_echo_reply(probes[0].id, probes[0].seq),
        (addr(5), addr(9)),
        t1 + ms(50),
    );

    let events: Vec<_> = std::iter::from_fn(|| a.poll_event()).collect();
    assert!(
        events.contains(&Event::PathRecovered),
        "the remote can't observe our recovery; a re-key is the signal, got {events:?}",
    );
}

#[test]
fn rekey_without_a_primary_buffers_for_relay_fanout() {
    // If probes can't find any path (e.g. no relays yet after a roam and
    // direct is filtered), the buffered re-key fans out on relay pairs as
    // soon as they exist — the bootstrap mechanism doubles as the fallback.
    let mut a = agent_with_relay_pairs();
    let now = Instant::now();
    bootstrap_primary(&mut a, (addr(2), addr(4)), now);
    let _ = a.advance(now, now + secs(10));

    assert!(a.remove_local_candidate(&Candidate::relayed(addr(2), addr(2)), now + secs(10)));
    assert_eq!(a.primary(), None, "removing primary's local must clear it");

    let rekey_at = now + secs(120);
    a.handle_outbound(handshake_init_bytes(), rekey_at);
    assert!(
        a.poll_transmit().is_none(),
        "buffered re-key must not transmit before the timer fires"
    );

    a.handle_timeout(rekey_at);
    let outbound = a.transmits();
    assert!(
        outbound
            .iter()
            .any(|t| t.remote == addr(4) && matches!(t.payload, Payload::Ciphertext(_))),
        "buffered re-key must fan out on a relay-involving pair: {outbound:?}"
    );
}

// --- test harness ---

type Pair = (SocketAddr, SocketAddr);

fn addr(p: u16) -> SocketAddr {
    format!("127.0.0.1:{p}").parse().unwrap()
}

fn addr_v6(p: u16) -> SocketAddr {
    format!("[::1]:{p}").parse().unwrap()
}

fn ms(n: u64) -> Duration {
    Duration::from_millis(n)
}

fn secs(n: u64) -> Duration {
    Duration::from_secs(n)
}

/// The probe send times of one burst starting at `start`.
fn burst_ladder(start: Instant) -> Vec<Instant> {
    std::iter::once(start)
        .chain(PROBE_BURST_GAPS.iter().scan(start, |at, gap| {
            *at += *gap;
            Some(*at)
        }))
        .collect()
}

/// Everything an agent did while time advanced.
struct Activity {
    /// Transmits, stamped with the instant they were produced at.
    transmits: Vec<(Instant, Transmit)>,
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

    fn probe_times(&self, pair: Pair) -> Vec<Instant> {
        self.transmits
            .iter()
            .filter(|(_, t)| (t.local, t.remote) == pair)
            .filter(|(_, t)| match &t.payload {
                Payload::Plaintext(packet) => {
                    parse_probe(packet).is_some_and(|p| p.kind == EchoKind::Request)
                }
                Payload::Ciphertext(_) => false,
            })
            .map(|(at, _)| *at)
            .collect()
    }
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
    /// Step the agent from `start` to `end`, firing every deadline in
    /// between and collecting the transmits it produces along the way.
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
            // Queued events keep `poll_timeout` at `now`; collect them so
            // time can move on.
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

/// A host↔host primary at `(1, 3)` with a fresh RTT plus a relay pair
/// `(2, 4)` as the potential fail-over target.
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

fn extract_probe_for(transmits: &[Transmit], pair: Pair) -> ProbeFields {
    let t = transmits
        .iter()
        .find(|t| (t.local, t.remote) == pair)
        .unwrap_or_else(|| panic!("no transmit for {pair:?}"));
    let Payload::Plaintext(ref packet) = t.payload else {
        panic!("expected Plaintext probe, got {:?}", t.payload);
    };
    parse_probe(packet).expect("parses as probe")
}
