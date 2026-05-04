use std::net::SocketAddr;
use std::ops::ControlFlow;
use std::time::{Duration, Instant};

use crate::agent::{BOOTSTRAP_WINDOW, Event, PROBE_INTERVAL, PathAgent, Payload, Transmit};
use crate::candidate::Candidate;

fn addr(p: u16) -> SocketAddr {
    format!("127.0.0.1:{p}").parse().unwrap()
}

#[test]
fn new_agent_has_no_pairs_or_primary() {
    let a = PathAgent::new();
    assert!(a.primary().is_none());
    assert_eq!(a.pairs().count(), 0);
    assert_eq!(a.relay_pairs().count(), 0);
}

#[test]
fn pairs_form_cartesian_product_of_locals_and_remotes() {
    let mut a = PathAgent::new();
    a.add_local_candidate(Candidate::host(addr(1)));
    a.add_local_candidate(Candidate::relayed(addr(2)));
    a.add_remote_candidate(Candidate::host(addr(3)));
    a.add_remote_candidate(Candidate::relayed(addr(4)));

    // 2 × 2 = 4 pairs
    assert_eq!(a.pairs().count(), 4);
}

#[test]
fn relay_pairs_filters_correctly() {
    let mut a = PathAgent::new();
    a.add_local_candidate(Candidate::host(addr(1)));
    a.add_local_candidate(Candidate::relayed(addr(2)));
    a.add_remote_candidate(Candidate::host(addr(3)));
    a.add_remote_candidate(Candidate::relayed(addr(4)));

    // host×host is non-relay; the other 3 involve at least one relay.
    assert_eq!(a.relay_pairs().count(), 3);
}

#[test]
fn remote_is_relayed_matches_only_relay_kind_at_addr() {
    let mut a = PathAgent::new();
    a.add_remote_candidate(Candidate::host(addr(1)));
    a.add_remote_candidate(Candidate::relayed(addr(2)));

    assert!(!a.remote_is_relayed(addr(1)));
    assert!(a.remote_is_relayed(addr(2)));
    assert!(!a.remote_is_relayed(addr(3))); // unknown addr
}

#[test]
fn duplicate_candidates_are_ignored() {
    let mut a = PathAgent::new();
    let c = Candidate::host(addr(1));
    a.add_local_candidate(c);
    a.add_local_candidate(c);
    a.add_remote_candidate(Candidate::host(addr(2)));
    assert_eq!(a.pairs().count(), 1);
}

#[test]
fn observe_handshake_on_unknown_pair_is_noop() {
    let mut a = PathAgent::new();
    a.observe_handshake(addr(1), addr(2), Instant::now()); // does not panic
}

#[test]
fn pairs_yields_local_remote_addresses() {
    let mut a = PathAgent::new();
    a.add_local_candidate(Candidate::host(addr(1)));
    a.add_remote_candidate(Candidate::host(addr(2)));

    let pairs: Vec<_> = a.pairs().collect();
    assert_eq!(pairs, vec![(addr(1), addr(2))]);
}

#[test]
fn inbound_unparseable_bytes_return_false() {
    let mut a = PathAgent::new();
    // Random non-WG bytes — parse_incoming_packet returns Err.
    let handled = a.handle_inbound(
        &[0xde, 0xad, 0xbe, 0xef],
        (addr(1), addr(2)),
        Instant::now(),
    );
    assert!(matches!(handled, ControlFlow::Continue(())));
}

#[test]
fn poll_transmit_drains_in_order() {
    // Fan out an init across the 3 relay-involved pairs and check we
    // can drain the resulting transmits in the order they were queued.
    let mut a = agent_with_relay_pairs();
    a.handle_outbound(handshake_init_bytes(), Instant::now());

    let first = a.poll_transmit().expect("first transmit");
    let second = a.poll_transmit().expect("second transmit");
    let third = a.poll_transmit().expect("third transmit");
    assert!(a.poll_transmit().is_none());

    // FIFO: order matches `relay_pairs()` insertion order.
    let pairs: Vec<_> = a.relay_pairs().collect();
    assert_eq!((first.local, first.remote), pairs[0]);
    assert_eq!((second.local, second.remote), pairs[1]);
    assert_eq!((third.local, third.remote), pairs[2]);
}

/// Construct a minimum-validity WG `HandshakeInit` packet:
/// 4-byte type header (1 = init), padded to the WG-required 148 bytes.
fn handshake_init_bytes() -> Vec<u8> {
    let mut bytes = vec![0u8; 148];
    bytes[0] = 1;
    bytes
}

fn handshake_response_bytes() -> Vec<u8> {
    let mut bytes = vec![0u8; 92];
    bytes[0] = 2;
    bytes
}

fn data_packet_bytes() -> Vec<u8> {
    let mut bytes = vec![0u8; 32];
    bytes[0] = 4;
    bytes
}

fn agent_with_relay_pairs() -> PathAgent {
    let mut a = PathAgent::new();
    a.add_local_candidate(Candidate::host(addr(1)));
    a.add_local_candidate(Candidate::relayed(addr(2)));
    a.add_remote_candidate(Candidate::host(addr(3)));
    a.add_remote_candidate(Candidate::relayed(addr(4)));
    a
}

#[test]
fn outbound_handshake_init_fans_out_on_every_relay_pair() {
    let mut a = agent_with_relay_pairs();

    a.handle_outbound(handshake_init_bytes(), Instant::now());

    let transmits: Vec<_> = std::iter::from_fn(|| a.poll_transmit()).collect();
    // 3 relay-involved pairs (host×host excluded).
    assert_eq!(transmits.len(), 3);
    // Every fan-out copy carries identical bytes — that's what lets the
    // responder's dedup cache replay a single cached response.
    let payload = Payload::Ciphertext(handshake_init_bytes());
    for t in &transmits {
        assert_eq!(t.payload, payload);
    }
}

#[test]
fn outbound_handshake_init_fanout_targets_match_relay_pairs() {
    let mut a = agent_with_relay_pairs();

    a.handle_outbound(handshake_init_bytes(), Instant::now());

    let mut emitted: Vec<_> = std::iter::from_fn(|| a.poll_transmit())
        .map(|t| (t.local, t.remote))
        .collect();
    emitted.sort();

    let mut expected: Vec<_> = a.relay_pairs().collect();
    expected.sort();

    assert_eq!(emitted, expected);
}

#[test]
fn outbound_data_with_primary_set_sends_on_primary() {
    let mut a = PathAgent::new();
    a.add_local_candidate(Candidate::host(addr(1)));
    a.add_remote_candidate(Candidate::host(addr(2)));
    a.primary = Some((addr(1), addr(2)));

    a.handle_outbound(data_packet_bytes(), Instant::now());

    let t = a.poll_transmit().expect("primary transmit");
    assert_eq!(t.local, addr(1));
    assert_eq!(t.remote, addr(2));
    assert!(a.poll_transmit().is_none());
}

#[test]
fn outbound_data_without_primary_is_dropped() {
    let mut a = PathAgent::new();

    a.handle_outbound(data_packet_bytes(), Instant::now());

    assert!(a.poll_transmit().is_none());
}

#[test]
fn outbound_handshake_response_without_inbound_init_is_dropped() {
    let mut a = agent_with_relay_pairs();

    a.handle_outbound(handshake_response_bytes(), Instant::now());

    assert!(a.poll_transmit().is_none());
}

#[test]
fn outbound_handshake_response_replays_on_recv_path_of_last_inbound_init() {
    let mut a = agent_with_relay_pairs();
    let recv_path = (addr(2), addr(4));

    // Simulate inbound init arriving on the relay-relay path.
    let handled = a.handle_inbound(&handshake_init_bytes(), recv_path, Instant::now());
    assert!(matches!(handled, ControlFlow::Break(())));
    // Drain the ForwardInbound event so it doesn't pollute later assertions.
    let _ = a.poll_event();

    // boringtun produces a response in reaction; PathAgent ships it
    // back on the same path the init came from.
    a.handle_outbound(handshake_response_bytes(), Instant::now());

    let t = a.poll_transmit().expect("response transmit");
    assert_eq!(t.local, recv_path.0);
    assert_eq!(t.remote, recv_path.1);
    assert_eq!(t.payload, Payload::Ciphertext(handshake_response_bytes()));
}

#[test]
fn inbound_handshake_init_returns_true_and_emits_forward_event() {
    let mut a = agent_with_relay_pairs();

    let handled = a.handle_inbound(&handshake_init_bytes(), (addr(2), addr(4)), Instant::now());
    assert!(matches!(handled, ControlFlow::Break(())));

    match a.poll_event() {
        Some(Event::ForwardInbound { bytes }) => assert_eq!(bytes, handshake_init_bytes()),
        other => panic!("expected ForwardInbound, got {other:?}"),
    }
}

#[test]
fn inbound_handshake_response_returns_true_and_emits_forward_event() {
    let mut a = agent_with_relay_pairs();

    let handled = a.handle_inbound(
        &handshake_response_bytes(),
        (addr(2), addr(4)),
        Instant::now(),
    );
    assert!(matches!(handled, ControlFlow::Break(())));

    match a.poll_event() {
        Some(Event::ForwardInbound { bytes }) => assert_eq!(bytes, handshake_response_bytes()),
        other => panic!("expected ForwardInbound, got {other:?}"),
    }
}

#[test]
fn inbound_data_packet_returns_false_and_emits_no_event() {
    let mut a = agent_with_relay_pairs();

    let handled = a.handle_inbound(&data_packet_bytes(), (addr(2), addr(4)), Instant::now());
    assert!(matches!(handled, ControlFlow::Continue(())));
    assert!(a.poll_event().is_none());
}

#[test]
fn outbound_handshake_init_arms_retransmits_with_initial_100ms_deadline() {
    let mut a = agent_with_relay_pairs();
    let now = Instant::now();

    a.handle_outbound(handshake_init_bytes(), now);
    // Drain the immediate fanout transmits so we look at the timer state.
    while a.poll_transmit().is_some() {}

    let next = a.poll_timeout().expect("retransmit deadline");
    // Initial backoff is 100ms.
    assert_eq!(next, now + Duration::from_millis(100));
}

#[test]
fn handle_timeout_at_or_after_deadline_re_emits_init_per_pair() {
    let mut a = agent_with_relay_pairs();
    let now = Instant::now();
    let init = handshake_init_bytes();

    a.handle_outbound(init.clone(), now);
    // Drain the original fanout (3 relay pairs).
    let initial_count = std::iter::from_fn(|| a.poll_transmit()).count();
    assert_eq!(initial_count, 3);

    // Advance to the 100ms deadline and pump.
    let later = now + Duration::from_millis(100);
    a.handle_timeout(later);

    let retransmits: Vec<_> = std::iter::from_fn(|| a.poll_transmit()).collect();
    assert_eq!(retransmits.len(), 3);
    for t in &retransmits {
        assert_eq!(t.payload, Payload::Ciphertext(init.clone()));
    }
}

#[test]
fn retransmit_backoff_doubles_per_pair_up_to_cap() {
    let mut a = agent_with_relay_pairs();
    let now = Instant::now();

    a.handle_outbound(handshake_init_bytes(), now);
    while a.poll_transmit().is_some() {}

    // After fire #1 at +100ms, next is +200ms; after #2, +400ms; etc.
    let mut t = now + Duration::from_millis(100);
    let expected_step_ms: [u64; 5] = [200, 400, 800, 1600, 1600];
    for &expected_ms in &expected_step_ms {
        a.handle_timeout(t);
        while a.poll_transmit().is_some() {}
        let next = a.poll_timeout().expect("deadline");
        assert_eq!(next, t + Duration::from_millis(expected_ms));
        t = next;
    }
    // The cap holds at 1600ms (last entry doubles to 1600, not 3200).
}

#[test]
fn inbound_handshake_response_clears_retransmits() {
    let mut a = agent_with_relay_pairs();
    let now = Instant::now();

    a.handle_outbound(handshake_init_bytes(), now);
    while a.poll_transmit().is_some() {}
    let init_deadline = a.poll_timeout().expect("init armed retransmits");

    let _ = a.handle_inbound(&handshake_response_bytes(), (addr(2), addr(4)), now);
    while a.poll_event().is_some() {}

    // After handshake completes, the retransmit ladder is gone; the
    // remaining `poll_timeout` value (if any) comes from probe scheduling
    // seeded by the inbound handshake, not from the cleared retransmit.
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
    while a.poll_transmit().is_some() {}

    // Tick at +50ms — earlier than the 100ms initial deadline.
    a.handle_timeout(now + Duration::from_millis(50));
    assert!(a.poll_transmit().is_none());
}

/// Drive the responder side through a full inbound init → outbound
/// response cycle so the dedup cache is populated.
fn populate_responder_cache(a: &mut PathAgent, recv_path: (SocketAddr, SocketAddr), now: Instant) {
    let _ = a.handle_inbound(&handshake_init_bytes(), recv_path, now);
    // Drain ForwardInbound — the test simulates boringtun acting on it.
    while a.poll_event().is_some() {}
    a.handle_outbound(handshake_response_bytes(), now);
    // Drain the response transmit on the recv path.
    while a.poll_transmit().is_some() {}
}

#[test]
fn duplicate_inbound_init_replays_cached_response_on_new_path() {
    let mut a = agent_with_relay_pairs();
    let now = Instant::now();

    populate_responder_cache(&mut a, (addr(2), addr(4)), now);

    // Same init bytes, different recv path (relay×relay vs. host×host).
    let new_path = (addr(1), addr(3));
    let handled = a.handle_inbound(&handshake_init_bytes(), new_path, now);
    assert!(matches!(handled, ControlFlow::Break(())));

    // Cached response replayed on the new path; no ForwardInbound event
    // (we did not re-drive boringtun).
    let t = a.poll_transmit().expect("replay transmit");
    assert_eq!(t.local, new_path.0);
    assert_eq!(t.remote, new_path.1);
    assert_eq!(t.payload, Payload::Ciphertext(handshake_response_bytes()));
    assert!(a.poll_event().is_none());
}

#[test]
fn duplicate_inbound_init_after_ttl_falls_back_to_forward() {
    let mut a = agent_with_relay_pairs();
    let now = Instant::now();

    populate_responder_cache(&mut a, (addr(2), addr(4)), now);

    // Past the 10s TTL.
    let later = now + Duration::from_secs(11);
    let handled = a.handle_inbound(&handshake_init_bytes(), (addr(1), addr(3)), later);
    assert!(matches!(handled, ControlFlow::Break(())));

    // Falls through to the normal forward path: emits a ForwardInbound
    // event and does NOT replay the cached response.
    match a.poll_event() {
        Some(Event::ForwardInbound { bytes }) => assert_eq!(bytes, handshake_init_bytes()),
        other => panic!("expected ForwardInbound, got {other:?}"),
    }
    assert!(a.poll_transmit().is_none());
}

#[test]
fn duplicate_inbound_response_is_dropped_after_first_forward() {
    let mut a = agent_with_relay_pairs();
    let now = Instant::now();

    // First response: forwarded to boringtun.
    let handled = a.handle_inbound(&handshake_response_bytes(), (addr(2), addr(4)), now);
    assert!(matches!(handled, ControlFlow::Break(())));
    match a.poll_event() {
        Some(Event::ForwardInbound { bytes }) => assert_eq!(bytes, handshake_response_bytes()),
        other => panic!("expected ForwardInbound, got {other:?}"),
    }

    // Same bytes on a different path: dropped, no event.
    let handled = a.handle_inbound(&handshake_response_bytes(), (addr(1), addr(3)), now);
    assert!(matches!(handled, ControlFlow::Break(())));
    assert!(a.poll_event().is_none());
    assert!(a.poll_transmit().is_none());
}

#[test]
fn fresh_outbound_init_resets_initiator_response_dedup() {
    let mut a = agent_with_relay_pairs();
    let now = Instant::now();

    // Forward a response, populate dedup.
    let _ = a.handle_inbound(&handshake_response_bytes(), (addr(2), addr(4)), now);
    while a.poll_event().is_some() {}

    // boringtun emits a fresh init (re-key) — should clear dedup.
    a.handle_outbound(handshake_init_bytes(), now);
    while a.poll_transmit().is_some() {}

    // The same response bytes now forward again (new session is
    // expecting a fresh response).
    let handled = a.handle_inbound(&handshake_response_bytes(), (addr(2), addr(4)), now);
    assert!(matches!(handled, ControlFlow::Break(())));
    match a.poll_event() {
        Some(Event::ForwardInbound { .. }) => {}
        other => panic!("expected ForwardInbound after re-init, got {other:?}"),
    }
}

/// Match an outbound `Transmit` against an `(local, remote)` pair, returning
/// the parsed probe payload. Helper for probe-loop tests.
fn extract_probe_for(
    transmits: &[Transmit],
    pair: (SocketAddr, SocketAddr),
) -> crate::icmpv6::Probe {
    let t = transmits
        .iter()
        .find(|t| (t.local, t.remote) == pair)
        .unwrap_or_else(|| panic!("no transmit for {pair:?}"));
    let Payload::Plaintext(ref bytes) = t.payload else {
        panic!("expected Plaintext probe, got {:?}", t.payload);
    };
    crate::icmpv6::try_parse(bytes).expect("parses as probe")
}

#[test]
fn inbound_handshake_seeds_probe_schedule_for_all_pairs() {
    let mut a = agent_with_relay_pairs();
    let now = Instant::now();

    let _ = a.handle_inbound(&handshake_response_bytes(), (addr(2), addr(4)), now);
    while a.poll_event().is_some() {}
    while a.poll_transmit().is_some() {}

    // After seeding, the next deadline is the immediate probe (now).
    assert_eq!(a.poll_timeout(), Some(now));
}

#[test]
fn handle_timeout_emits_one_probe_per_pair() {
    let mut a = agent_with_relay_pairs();
    let now = Instant::now();

    let _ = a.handle_inbound(&handshake_response_bytes(), (addr(2), addr(4)), now);
    while a.poll_event().is_some() {}
    while a.poll_transmit().is_some() {}

    a.handle_timeout(now);
    let transmits: Vec<_> = std::iter::from_fn(|| a.poll_transmit()).collect();

    // 4 pairs (2 locals × 2 remotes), each gets one probe.
    assert_eq!(transmits.len(), 4);
    for t in &transmits {
        assert!(matches!(t.payload, Payload::Plaintext(_)));
    }
}

#[test]
fn probe_seq_advances_per_pair_per_fire() {
    let mut a = agent_with_relay_pairs();
    let now = Instant::now();

    let _ = a.handle_inbound(&handshake_response_bytes(), (addr(2), addr(4)), now);
    while a.poll_event().is_some() {}
    while a.poll_transmit().is_some() {}

    // Fire 1.
    a.handle_timeout(now);
    let first: Vec<_> = std::iter::from_fn(|| a.poll_transmit()).collect();
    let first_seq = extract_probe_for(&first, (addr(1), addr(3))).seq;

    // Fire 2 — advance past the per-pair PROBE_INTERVAL.
    a.handle_timeout(now + PROBE_INTERVAL);
    let second: Vec<_> = std::iter::from_fn(|| a.poll_transmit()).collect();
    let second_seq = extract_probe_for(&second, (addr(1), addr(3))).seq;

    assert_eq!(second_seq, first_seq.wrapping_add(1));
}

#[test]
fn inbound_echo_reply_updates_smoothed_rtt_and_selects_primary() {
    let mut a = agent_with_relay_pairs();
    let now = Instant::now();

    let _ = a.handle_inbound(&handshake_response_bytes(), (addr(2), addr(4)), now);
    while a.poll_event().is_some() {}
    while a.poll_transmit().is_some() {}

    // Send a probe so we have an inflight slot to match against.
    a.handle_timeout(now);
    let outbound: Vec<_> = std::iter::from_fn(|| a.poll_transmit()).collect();
    let probe_on_host_pair = extract_probe_for(&outbound, (addr(1), addr(3)));

    // Reply arrives 50ms later on the same pair.
    let reply = crate::icmpv6::build_echo_reply(probe_on_host_pair.id, probe_on_host_pair.seq);
    let later = now + Duration::from_millis(50);
    let handled = a.handle_inbound_decrypted(&reply, (addr(1), addr(3)), later);
    assert!(matches!(handled, ControlFlow::Break(())));

    // host×host pair has best tier — picked as primary on first RTT.
    assert_eq!(a.primary(), Some((addr(1), addr(3))));
    match a.poll_event() {
        Some(Event::PrimarySelected { local, remote }) => {
            assert_eq!((local, remote), (addr(1), addr(3)));
        }
        other => panic!("expected PrimarySelected, got {other:?}"),
    }
}

#[test]
fn inbound_echo_request_queues_reply_on_same_pair() {
    let mut a = agent_with_relay_pairs();
    let now = Instant::now();

    let request = crate::icmpv6::build_echo_request(0, 42);
    let handled = a.handle_inbound_decrypted(&request, (addr(2), addr(4)), now);
    assert!(matches!(handled, ControlFlow::Break(())));

    let reply_transmit = a.poll_transmit().expect("queued reply");
    assert_eq!(reply_transmit.local, addr(2));
    assert_eq!(reply_transmit.remote, addr(4));
    let Payload::Plaintext(packet) = reply_transmit.payload else {
        panic!("expected Plaintext reply");
    };
    let probe = crate::icmpv6::try_parse(&packet).expect("parses");
    assert_eq!(probe.kind, crate::icmpv6::Echo::Reply);
    assert_eq!(probe.seq, 42);
}

#[test]
fn inbound_decrypted_non_probe_returns_continue() {
    let mut a = agent_with_relay_pairs();
    // Plain UDP packet on non-probe IPs — must fall through to the tun device.
    let packet = ip_packet::make::udp_packet(
        std::net::Ipv4Addr::LOCALHOST,
        std::net::Ipv4Addr::LOCALHOST,
        1,
        2,
        b"hello",
    )
    .unwrap();
    let handled = a.handle_inbound_decrypted(&packet, (addr(2), addr(4)), Instant::now());
    assert!(matches!(handled, ControlFlow::Continue(())));
    assert!(a.poll_transmit().is_none());
}

#[test]
fn primary_changes_when_lower_tier_pair_becomes_alive() {
    let mut a = agent_with_relay_pairs();
    let now = Instant::now();

    let _ = a.handle_inbound(&handshake_response_bytes(), (addr(2), addr(4)), now);
    while a.poll_event().is_some() {}
    while a.poll_transmit().is_some() {}

    // Fire probes to populate inflight slots.
    a.handle_timeout(now);
    let outbound: Vec<_> = std::iter::from_fn(|| a.poll_transmit()).collect();

    // Reply on relay pair first (relay×relay has worst tier).
    let relay_probe = extract_probe_for(&outbound, (addr(2), addr(4)));
    let _ = a.handle_inbound_decrypted(
        &crate::icmpv6::build_echo_reply(relay_probe.id, relay_probe.seq),
        (addr(2), addr(4)),
        now + Duration::from_millis(100),
    );
    assert_eq!(a.primary(), Some((addr(2), addr(4))));

    // Now reply on host×host pair (best tier) — should switch.
    let host_probe = extract_probe_for(&outbound, (addr(1), addr(3)));
    while a.poll_event().is_some() {}
    let _ = a.handle_inbound_decrypted(
        &crate::icmpv6::build_echo_reply(host_probe.id, host_probe.seq),
        (addr(1), addr(3)),
        now + Duration::from_millis(150),
    );
    assert_eq!(a.primary(), Some((addr(1), addr(3))));
    match a.poll_event() {
        Some(Event::PrimaryChanged { from, to }) => {
            assert_eq!(from, (addr(2), addr(4)));
            assert_eq!(to, (addr(1), addr(3)));
        }
        other => panic!("expected PrimaryChanged, got {other:?}"),
    }
}

#[test]
fn stale_echo_reply_is_ignored() {
    let mut a = agent_with_relay_pairs();
    let now = Instant::now();

    let _ = a.handle_inbound(&handshake_response_bytes(), (addr(2), addr(4)), now);
    while a.poll_event().is_some() {}
    while a.poll_transmit().is_some() {}

    a.handle_timeout(now);
    while a.poll_transmit().is_some() {}

    // Reply with a seq that doesn't match the inflight probe (we've only
    // sent seq=0 so far; pretend a much earlier seq replies late).
    let stale_reply = crate::icmpv6::build_echo_reply(0, 0xdead);
    let _ = a.handle_inbound_decrypted(&stale_reply, (addr(1), addr(3)), now);

    // No primary was set since no matching inflight probe was cleared.
    assert_eq!(a.primary(), None);
}

#[test]
fn outbound_init_emits_bootstrap_failed_after_window_without_response() {
    let mut a = agent_with_relay_pairs();
    let now = Instant::now();

    a.handle_outbound(handshake_init_bytes(), now);
    while a.poll_transmit().is_some() {}

    // No inbound response arrives — pump past the deadline.
    a.handle_timeout(now + BOOTSTRAP_WINDOW);

    let event = a.poll_event().expect("BootstrapFailed event");
    assert!(matches!(event, Event::BootstrapFailed));

    // Subsequent ticks do not re-emit (outbound_init is cleared).
    a.handle_timeout(now + BOOTSTRAP_WINDOW + Duration::from_secs(1));
    assert!(a.poll_event().is_none());
}

#[test]
fn outbound_init_does_not_fail_if_response_arrives_in_time() {
    let mut a = agent_with_relay_pairs();
    let now = Instant::now();

    a.handle_outbound(handshake_init_bytes(), now);
    while a.poll_transmit().is_some() {}

    // Response arrives near the deadline.
    let _ = a.handle_inbound(
        &handshake_response_bytes(),
        (addr(2), addr(4)),
        now + BOOTSTRAP_WINDOW - Duration::from_millis(1),
    );
    while a.poll_event().is_some() {}

    // Pump past the deadline; no BootstrapFailed since outbound_init
    // was cleared by the response.
    a.handle_timeout(now + BOOTSTRAP_WINDOW + Duration::from_secs(1));
    let event = a.poll_event();
    assert!(
        !matches!(event, Some(Event::BootstrapFailed)),
        "got unexpected BootstrapFailed: {event:?}",
    );
}

#[test]
fn drive_probes_stops_emitting_after_bootstrap_window() {
    let mut a = agent_with_relay_pairs();
    let now = Instant::now();

    let _ = a.handle_inbound(&handshake_response_bytes(), (addr(2), addr(4)), now);
    while a.poll_event().is_some() {}
    while a.poll_transmit().is_some() {}

    // Inside window — probes fire.
    a.handle_timeout(now);
    let inside: Vec<_> = std::iter::from_fn(|| a.poll_transmit()).collect();
    assert!(!inside.is_empty(), "expected probes inside window");

    // After the window, drive_probes is a no-op even on previously-due pairs.
    a.handle_timeout(now + BOOTSTRAP_WINDOW);
    let after: Vec<_> = std::iter::from_fn(|| a.poll_transmit()).collect();
    assert!(
        after.is_empty(),
        "expected no probes after window: {after:?}"
    );
}

#[test]
fn settle_clears_next_probe_at_and_poll_timeout() {
    let mut a = agent_with_relay_pairs();
    let now = Instant::now();

    let _ = a.handle_inbound(&handshake_response_bytes(), (addr(2), addr(4)), now);
    while a.poll_event().is_some() {}

    // Pump bootstrap-due work.
    a.handle_timeout(now);
    while a.poll_transmit().is_some() {}

    // Settle.
    a.handle_timeout(now + BOOTSTRAP_WINDOW);

    // No probe deadlines, no bootstrap deadline → no further wake-ups
    // unless other state (events, retransmits) demands one.
    assert_eq!(a.poll_timeout(), None);
}

#[test]
fn settle_is_sticky_across_later_handshakes() {
    let mut a = agent_with_relay_pairs();
    let now = Instant::now();

    let _ = a.handle_inbound(&handshake_response_bytes(), (addr(2), addr(4)), now);
    while a.poll_event().is_some() {}
    while a.poll_transmit().is_some() {}

    a.handle_timeout(now + BOOTSTRAP_WINDOW); // settle

    // A later inbound handshake (e.g. peer rekey) must not re-open the
    // probe window.
    let _ = a.handle_inbound(
        &handshake_response_bytes(),
        (addr(2), addr(4)),
        now + BOOTSTRAP_WINDOW + Duration::from_secs(60),
    );
    while a.poll_event().is_some() {}

    a.handle_timeout(now + BOOTSTRAP_WINDOW + Duration::from_secs(60));
    let post: Vec<_> = std::iter::from_fn(|| a.poll_transmit()).collect();
    assert!(post.is_empty(), "expected no probes post-settle: {post:?}");
}

#[test]
fn different_inbound_init_bytes_skip_dedup_cache() {
    let mut a = agent_with_relay_pairs();
    let now = Instant::now();

    populate_responder_cache(&mut a, (addr(2), addr(4)), now);

    // Bytes differ from the cached entry by one byte (e.g. fresh TAI64N).
    let mut different_init = handshake_init_bytes();
    different_init[100] = 0x42;

    let handled = a.handle_inbound(&different_init, (addr(2), addr(4)), now);
    assert!(matches!(handled, ControlFlow::Break(())));

    // No cache replay; falls through to forward-to-boringtun.
    match a.poll_event() {
        Some(Event::ForwardInbound { bytes }) => assert_eq!(bytes, different_init),
        other => panic!("expected ForwardInbound, got {other:?}"),
    }
    assert!(a.poll_transmit().is_none());
}
