//! Integration tests for `PathAgent` against the public crate API.

use std::net::{IpAddr, SocketAddr};
use std::ops::ControlFlow;
use std::time::{Duration, Instant};

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
    a.add_local_candidate(Candidate::relayed(addr(2), addr(2)));
    a.add_remote_candidate(Candidate::host(addr(3)));
    a.add_remote_candidate(Candidate::relayed(addr(4), addr(4)));

    // 2 × 2 = 4 pairs
    assert_eq!(a.pairs().count(), 4);
}

#[test]
fn relay_pairs_filters_correctly() {
    let mut a = PathAgent::new();
    a.add_local_candidate(Candidate::host(addr(1)));
    a.add_local_candidate(Candidate::relayed(addr(2), addr(2)));
    a.add_remote_candidate(Candidate::host(addr(3)));
    a.add_remote_candidate(Candidate::relayed(addr(4), addr(4)));

    // host×host is non-relay; the other 3 involve at least one relay.
    assert_eq!(a.relay_pairs().count(), 3);
}

#[test]
fn remote_is_relayed_matches_only_relay_kind_at_addr() {
    let mut a = PathAgent::new();
    a.add_remote_candidate(Candidate::host(addr(1)));
    a.add_remote_candidate(Candidate::relayed(addr(2), addr(2)));

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
fn cross_family_pairs_are_skipped() {
    // A v4 socket can't send to a v6 destination (and vice versa), so
    // pairs that mix families never produce a working path. The
    // handshake fanout would try to route a v6 destination through a
    // v4 relay channel binding, which TURN cannot do.
    let mut a = PathAgent::new();
    a.add_local_candidate(Candidate::relayed(addr(1), addr(1)));
    a.add_local_candidate(Candidate::relayed(addr_v6(2), addr_v6(2)));
    a.add_remote_candidate(Candidate::relayed(addr(3), addr(3)));
    a.add_remote_candidate(Candidate::relayed(addr_v6(4), addr_v6(4)));

    let pairs: Vec<_> = a.pairs().collect();
    assert_eq!(pairs.len(), 2, "only same-family pairs are kept: {pairs:?}");
    assert!(pairs.contains(&(addr(1), addr(3))));
    assert!(pairs.contains(&(addr_v6(2), addr_v6(4))));
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
    let mut a = agent_with_relay_pairs();
    assert!(
        a.handle_inbound_network(&[1, 2, 3], (addr(2), addr(4)), Instant::now())
            .is_continue()
    );
}

#[test]
fn outbound_data_after_primary_selected_sends_on_primary() {
    let mut a = agent_with_relay_pairs();
    let now = Instant::now();

    // Drive a real handshake → primary on the host×host pair (best tier).
    let _ = a.handle_inbound_network(&handshake_response_bytes(), (addr(2), addr(4)), now);
    while a.poll_event().is_some() {}
    while a.poll_transmit().is_some() {}

    a.handle_timeout(now);
    let outbound: Vec<_> = std::iter::from_fn(|| a.poll_transmit()).collect();
    let host_probe = extract_probe_for(&outbound, (addr(1), addr(3)));

    let reply = build_echo_reply(host_probe.id, host_probe.seq);
    let _ = a.handle_inbound_tun(reply, (addr(1), addr(3)), now);
    assert_eq!(a.primary(), Some((addr(1), addr(3))));
    while a.poll_event().is_some() {}
    while a.poll_transmit().is_some() {}

    // Outbound user data now routes via the locked-in primary.
    a.handle_outbound(data_packet_bytes(), now);
    let t = a.poll_transmit().expect("primary transmit");
    assert_eq!(t.local, addr(1));
    assert_eq!(t.remote, addr(3));
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

    assert!(
        a.handle_inbound_network(&handshake_init_bytes(), recv_path, Instant::now())
            .is_break()
    );
    let _ = a.poll_event();

    a.handle_outbound(handshake_response_bytes(), Instant::now());

    let t = a.poll_transmit().expect("response transmit");
    assert_eq!(t.local, recv_path.0);
    assert_eq!(t.remote, recv_path.1);
    assert_eq!(t.payload, Payload::Ciphertext(handshake_response_bytes()));
}

#[test]
fn inbound_handshake_init_returns_true_and_emits_forward_event() {
    let mut a = agent_with_relay_pairs();
    assert!(
        a.handle_inbound_network(&handshake_init_bytes(), (addr(2), addr(4)), Instant::now())
            .is_break()
    );

    // `ForwardHandshake` is queued before `PrimaryChanged` so the consumer
    // hands the handshake to boringtun (creating the WG session) before
    // any user-data flush triggered by the primary update.
    match a.poll_event() {
        Some(Event::ForwardHandshake { bytes }) => assert_eq!(bytes, handshake_init_bytes()),
        other => panic!("expected ForwardHandshake, got {other:?}"),
    }
    match a.poll_event() {
        Some(Event::PrimaryChanged { local, remote }) => {
            assert_eq!((local, remote), (addr(2), addr(4)));
        }
        other => panic!("expected PrimaryChanged, got {other:?}"),
    }
}

#[test]
fn inbound_handshake_response_returns_true_and_emits_forward_event() {
    let mut a = agent_with_relay_pairs();
    assert!(
        a.handle_inbound_network(
            &handshake_response_bytes(),
            (addr(2), addr(4)),
            Instant::now()
        )
        .is_break()
    );

    // Same shape as the init case: forward to boringtun first, then
    // adopt the initial primary.
    match a.poll_event() {
        Some(Event::ForwardHandshake { bytes }) => assert_eq!(bytes, handshake_response_bytes()),
        other => panic!("expected ForwardHandshake, got {other:?}"),
    }
    match a.poll_event() {
        Some(Event::PrimaryChanged { local, remote }) => {
            assert_eq!((local, remote), (addr(2), addr(4)));
        }
        other => panic!("expected PrimaryChanged, got {other:?}"),
    }
}

#[test]
fn inbound_data_packet_returns_false_and_emits_no_event() {
    let mut a = agent_with_relay_pairs();
    assert!(
        a.handle_inbound_network(&data_packet_bytes(), (addr(2), addr(4)), Instant::now())
            .is_continue()
    );
    assert!(a.poll_event().is_none());
}

#[test]
fn outbound_handshake_init_arms_retransmits_with_initial_50ms_deadline() {
    let mut a = agent_with_relay_pairs();
    let now = Instant::now();
    a.handle_outbound(handshake_init_bytes(), now);
    a.handle_timeout(now);
    while a.poll_transmit().is_some() {}
    let next = a.poll_timeout().expect("retransmit deadline");
    // First retransmit lives at the head of the ladder — 50 ms — to
    // cover the channel-bind race on the relay.
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

    // First retransmit deadline lands at +50 ms (the head of the burst).
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

    // Cumulative deadlines after the initial fire: 50ms, 50ms, 50ms
    // (the burst), then 100, 200, 400, 800, 1600 (cap), 1600, ...
    // Walk each step and check both the deadline gap and that the
    // expected number of transmits actually fire.
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

    let _ = a.handle_inbound_network(&handshake_response_bytes(), (addr(2), addr(4)), now);
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
    // Tick clearly before the +50 ms head of the retransmit ladder.
    a.handle_timeout(now + Duration::from_millis(25));
    assert!(a.poll_transmit().is_none());
}

#[test]
fn srflx_local_uses_base_as_send_from_address() {
    // Server-reflexive's `addr` is the NAT-mapped public face;
    // `local` is the actual base socket we send from. The handshake
    // fanout must use `local` as `Transmit.local`, not `addr`, or the
    // outbound packet would target a socket we don't own.
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
    // srflx-local pair uses `base`, not `mapped`. Relay-local uses
    // its own addr.
    let expected = vec![(base, addr(30)), (addr(20), addr(30))];
    let mut expected = expected;
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
fn outbound_handshake_init_before_relay_pair_buffers_then_fans_out_on_handle_timeout() {
    // snownet emits the initial WG init from `upsert_connection`,
    // before any remote candidates have arrived over signaling. The
    // path-agent buffers the bytes; `handle_timeout` fans them out
    // once a relay-involved pair shows up.
    let mut a = PathAgent::new();
    let now = Instant::now();

    a.add_local_candidate(Candidate::relayed(addr(1), addr(1)));
    a.handle_outbound(handshake_init_bytes(), now);
    assert!(
        a.poll_transmit().is_none(),
        "no transmit should fire without a remote relay candidate"
    );

    // `poll_timeout` should ask to be re-polled immediately so the
    // fanout drains as soon as a relay pair becomes available.
    a.add_remote_candidate(Candidate::relayed(addr(2), addr(2)));
    let next = a.poll_timeout().expect("pending fanout deadline");
    assert!(next <= now, "pending fanout should wake immediately");

    a.handle_timeout(next);
    let transmits: Vec<_> = std::iter::from_fn(|| a.poll_transmit()).collect();
    assert_eq!(transmits.len(), 1);
    assert_eq!(transmits[0].local, addr(1));
    assert_eq!(transmits[0].remote, addr(2));
    assert_eq!(
        transmits[0].payload,
        Payload::Ciphertext(handshake_init_bytes())
    );
}

#[test]
fn buffered_handshake_init_does_not_emit_events_while_awaiting_relay_pairs() {
    // Without a relay pair we have nothing to fan out on; the buffered
    // init should sit quietly without emitting anything.
    let mut a = PathAgent::new();
    let now = Instant::now();

    a.handle_outbound(handshake_init_bytes(), now);
    a.handle_timeout(now + EVALUATION_WINDOW + Duration::from_secs(1));
    assert!(
        a.poll_event().is_none(),
        "path evaluation should not fail while still waiting for a relay pair"
    );
}

#[test]
fn outbound_handshake_init_fanout_targets_match_relay_pairs() {
    let mut a = agent_with_relay_pairs();
    let now = Instant::now();
    a.handle_outbound(handshake_init_bytes(), now);
    a.handle_timeout(now);

    let mut emitted: Vec<_> = std::iter::from_fn(|| a.poll_transmit())
        .map(|t| (t.local, t.remote))
        .collect();
    emitted.sort();
    let mut expected: Vec<_> = a.relay_pairs().collect();
    expected.sort();
    assert_eq!(emitted, expected);
}

#[test]
fn duplicate_inbound_init_in_flight_does_not_re_forward_to_boringtun() {
    // The peer's handshake fanout makes the same init reach us on
    // multiple pairs within the same tick — before our response has
    // gone out, so `responder_dedup` isn't populated yet. The dedup
    // here drops the duplicate so it doesn't re-trip boringtun's
    // anti-replay (WrongTai64nTimestamp).
    let mut a = agent_with_relay_pairs();
    let now = Instant::now();

    let _ = a.handle_inbound_network(&handshake_init_bytes(), (addr(2), addr(4)), now);
    // First arrival: forwarded for boringtun to chew on.
    let mut events = std::iter::from_fn(|| a.poll_event()).collect::<Vec<_>>();
    let forwarded_count = events
        .iter()
        .filter(|e| matches!(e, Event::ForwardHandshake { .. }))
        .count();
    assert_eq!(forwarded_count, 1);
    events.clear();

    // Same bytes, different path — must not re-forward.
    let _ = a.handle_inbound_network(&handshake_init_bytes(), (addr(1), addr(3)), now);
    while let Some(e) = a.poll_event() {
        events.push(e);
    }
    assert!(
        !events
            .iter()
            .any(|e| matches!(e, Event::ForwardHandshake { .. })),
        "duplicate in-flight init must not produce another ForwardHandshake: {events:?}"
    );
}

#[test]
fn duplicate_inbound_init_replays_cached_response_on_new_path() {
    let mut a = agent_with_relay_pairs();
    let now = Instant::now();
    populate_responder_cache(&mut a, (addr(2), addr(4)), now);

    let new_path = (addr(1), addr(3));
    assert!(
        a.handle_inbound_network(&handshake_init_bytes(), new_path, now)
            .is_break()
    );

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

    let later = now + Duration::from_secs(11);
    assert!(
        a.handle_inbound_network(&handshake_init_bytes(), (addr(1), addr(3)), later)
            .is_break()
    );

    match a.poll_event() {
        Some(Event::ForwardHandshake { bytes }) => assert_eq!(bytes, handshake_init_bytes()),
        other => panic!("expected ForwardHandshake, got {other:?}"),
    }
    assert!(a.poll_transmit().is_none());
}

#[test]
fn duplicate_inbound_response_is_dropped_after_first_forward() {
    let mut a = agent_with_relay_pairs();
    let now = Instant::now();

    assert!(
        a.handle_inbound_network(&handshake_response_bytes(), (addr(2), addr(4)), now)
            .is_break()
    );
    // Drain the initial-primary event the first response produces so we
    // can assert "no further events" on the second.
    while a.poll_event().is_some() {}

    assert!(
        a.handle_inbound_network(&handshake_response_bytes(), (addr(1), addr(3)), now)
            .is_break()
    );
    assert!(a.poll_event().is_none());
    assert!(a.poll_transmit().is_none());
}

#[test]
fn fresh_outbound_init_resets_initiator_response_dedup() {
    let mut a = agent_with_relay_pairs();
    let now = Instant::now();

    let _ = a.handle_inbound_network(&handshake_response_bytes(), (addr(2), addr(4)), now);
    while a.poll_event().is_some() {}

    a.handle_outbound(handshake_init_bytes(), now);
    while a.poll_transmit().is_some() {}

    assert!(
        a.handle_inbound_network(&handshake_response_bytes(), (addr(2), addr(4)), now)
            .is_break()
    );
    match a.poll_event() {
        Some(Event::ForwardHandshake { .. }) => {}
        other => panic!("expected ForwardHandshake after re-init, got {other:?}"),
    }
}

#[test]
fn inbound_handshake_seeds_probe_schedule_for_all_pairs() {
    let mut a = agent_with_relay_pairs();
    let now = Instant::now();

    let _ = a.handle_inbound_network(&handshake_response_bytes(), (addr(2), addr(4)), now);
    while a.poll_event().is_some() {}
    while a.poll_transmit().is_some() {}

    assert_eq!(a.poll_timeout(), Some(now));
}

#[test]
fn handle_timeout_emits_one_probe_per_pair() {
    let mut a = agent_with_relay_pairs();
    let now = Instant::now();

    let _ = a.handle_inbound_network(&handshake_response_bytes(), (addr(2), addr(4)), now);
    while a.poll_event().is_some() {}
    while a.poll_transmit().is_some() {}

    a.handle_timeout(now);
    let transmits: Vec<_> = std::iter::from_fn(|| a.poll_transmit()).collect();

    assert_eq!(transmits.len(), 4);
    for t in &transmits {
        assert!(matches!(t.payload, Payload::Plaintext(_)));
    }
}

#[test]
fn probe_seq_advances_per_pair_per_fire() {
    let mut a = agent_with_relay_pairs();
    let now = Instant::now();

    let _ = a.handle_inbound_network(&handshake_response_bytes(), (addr(2), addr(4)), now);
    while a.poll_event().is_some() {}
    while a.poll_transmit().is_some() {}

    a.handle_timeout(now);
    let first: Vec<_> = std::iter::from_fn(|| a.poll_transmit()).collect();
    let first_probe = extract_probe_for(&first, (addr(1), addr(3)));
    let first_seq = first_probe.seq;

    // Reply lands on the same pair, clearing the inflight slot. Without
    // this, `drive_probes` would skip the next fire while a probe is
    // still inflight (until `PROBE_TIMEOUT`).
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
fn inbound_echo_reply_updates_smoothed_rtt_and_selects_primary() {
    let mut a = agent_with_relay_pairs();
    let now = Instant::now();

    let _ = a.handle_inbound_network(&handshake_response_bytes(), (addr(2), addr(4)), now);
    while a.poll_event().is_some() {}
    while a.poll_transmit().is_some() {}

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
fn inbound_decrypted_non_probe_returns_continue() {
    let mut a = agent_with_relay_pairs();
    let packet = ip_packet::make::udp_packet(
        std::net::Ipv4Addr::LOCALHOST,
        std::net::Ipv4Addr::LOCALHOST,
        1,
        2,
        b"hello",
    )
    .unwrap();
    let handled = a.handle_inbound_tun(packet, (addr(2), addr(4)), Instant::now());
    let ControlFlow::Continue(returned) = handled else {
        panic!("non-probe packet must be handed back, got {handled:?}");
    };
    // Handed back unchanged for the caller to deliver to the TUN.
    assert_eq!(returned.source(), IpAddr::V4(std::net::Ipv4Addr::LOCALHOST));
    assert!(a.poll_transmit().is_none());
}

#[test]
fn primary_changes_when_lower_tier_pair_becomes_alive() {
    let mut a = agent_with_relay_pairs();
    let now = Instant::now();

    let _ = a.handle_inbound_network(&handshake_response_bytes(), (addr(2), addr(4)), now);
    while a.poll_event().is_some() {}
    while a.poll_transmit().is_some() {}

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
    // Setup: only "Relayed-tier" pairs exist, and they split into our
    // relay vs. their relay.  We expect the locally-relayed one to win
    // even when both reply at identical RTT.
    let mut a = PathAgent::new();
    a.add_local_candidate(Candidate::host(addr(1)));
    a.add_local_candidate(Candidate::relayed(addr(2), addr(2)));
    a.add_remote_candidate(Candidate::host(addr(3)));
    a.add_remote_candidate(Candidate::relayed(addr(4), addr(4)));
    let now = Instant::now();

    let _ = a.handle_inbound_network(&handshake_response_bytes(), (addr(2), addr(4)), now);
    while a.poll_event().is_some() {}
    while a.poll_transmit().is_some() {}

    a.handle_timeout(now);
    let outbound: Vec<_> = std::iter::from_fn(|| a.poll_transmit()).collect();

    // Reply on the *remote-relay* pair first (LocalHost → RemoteRelay).
    let remote_relay_probe = extract_probe_for(&outbound, (addr(1), addr(4)));
    let _ = a.handle_inbound_tun(
        build_echo_reply(remote_relay_probe.id, remote_relay_probe.seq),
        (addr(1), addr(4)),
        now + Duration::from_millis(50),
    );
    assert_eq!(a.primary(), Some((addr(1), addr(4))));

    // Now reply on the *local-relay* pair (LocalRelay → RemoteHost) at
    // an identical RTT — the local-relay tie-break should swap primary.
    while a.poll_event().is_some() {}
    let local_relay_probe = extract_probe_for(&outbound, (addr(2), addr(3)));
    let _ = a.handle_inbound_tun(
        build_echo_reply(local_relay_probe.id, local_relay_probe.seq),
        (addr(2), addr(3)),
        now + Duration::from_millis(100),
    );
    assert_eq!(
        a.primary(),
        Some((addr(2), addr(3))),
        "local-relay pair should beat remote-relay pair at the same tier",
    );
}

#[test]
fn primary_prefers_ipv6_over_ipv4_at_same_tier() {
    // Two host×host pairs, one v4 and one v6, that reply at identical
    // RTT. The v6 tie-break should put the v6 pair in `primary`.
    let mut a = PathAgent::new();
    a.add_local_candidate(Candidate::host(addr(1))); // v4
    a.add_local_candidate(Candidate::host(addr_v6(11))); // v6
    a.add_remote_candidate(Candidate::host(addr(2))); // v4
    a.add_remote_candidate(Candidate::host(addr_v6(12))); // v6
    let now = Instant::now();

    let _ = a.handle_inbound_network(&handshake_response_bytes(), (addr(1), addr(2)), now);
    while a.poll_event().is_some() {}
    while a.poll_transmit().is_some() {}

    a.handle_timeout(now);
    let outbound: Vec<_> = std::iter::from_fn(|| a.poll_transmit()).collect();

    // Reply on the v4 host×host pair first.
    let v4_probe = extract_probe_for(&outbound, (addr(1), addr(2)));
    let _ = a.handle_inbound_tun(
        build_echo_reply(v4_probe.id, v4_probe.seq),
        (addr(1), addr(2)),
        now + Duration::from_millis(50),
    );
    assert_eq!(a.primary(), Some((addr(1), addr(2))));

    while a.poll_event().is_some() {}

    // Reply on the v6 host×host pair at identical RTT — the v6 tie-break
    // should swap the primary.
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
fn primary_prefers_family_matched_relay_within_same_v6_bucket() {
    // Two v6 relay-allocated locals that share a v6 remote: one
    // reached over a matching-family v6 TURN socket, one over a
    // mismatched v4 TURN socket. The matched-family pair should win
    // even when both reply at identical RTT.
    let mut a = PathAgent::new();
    let matched_local_alloc = addr_v6(10);
    let mismatched_local_alloc = addr_v6(11);
    a.add_local_candidate(Candidate::relayed(matched_local_alloc, addr_v6(100))); // v6/v6
    a.add_local_candidate(Candidate::relayed(mismatched_local_alloc, addr(101))); // v6/v4
    a.add_remote_candidate(Candidate::relayed(addr_v6(20), addr_v6(20)));
    let now = Instant::now();

    let _ = a.handle_inbound_network(
        &handshake_response_bytes(),
        (mismatched_local_alloc, addr_v6(20)),
        now,
    );
    while a.poll_event().is_some() {}
    while a.poll_transmit().is_some() {}

    a.handle_timeout(now);
    let outbound: Vec<_> = std::iter::from_fn(|| a.poll_transmit()).collect();

    // Reply on the *mismatched* pair first.
    let mismatched_pair = (mismatched_local_alloc, addr_v6(20));
    let mismatched_probe = extract_probe_for(&outbound, mismatched_pair);
    let _ = a.handle_inbound_tun(
        build_echo_reply(mismatched_probe.id, mismatched_probe.seq),
        mismatched_pair,
        now + Duration::from_millis(50),
    );
    assert_eq!(a.primary(), Some(mismatched_pair));
    while a.poll_event().is_some() {}

    // Reply on the *matched* pair at identical RTT — within the
    // same v6 bucket the family-match tie-break should swap primary.
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
    // A v6-mismatched-family pair (v6 alloc reached over a v4 TURN
    // socket) forces the relay to bridge address families, which is
    // worth dodging even at the cost of giving up v6 on the
    // user-data leg. A fully-matched v4 alternative wins over a
    // mismatched-family v6 pair.
    let mut a = PathAgent::new();
    let v6_mismatched_local_alloc = addr_v6(10);
    let v4_matched_local_alloc = addr(11);
    a.add_local_candidate(Candidate::relayed(v6_mismatched_local_alloc, addr(100))); // v6/v4
    a.add_local_candidate(Candidate::relayed(v4_matched_local_alloc, addr(101))); // v4/v4
    a.add_remote_candidate(Candidate::relayed(addr_v6(20), addr_v6(20)));
    a.add_remote_candidate(Candidate::relayed(addr(30), addr(30)));
    let now = Instant::now();

    let _ = a.handle_inbound_network(
        &handshake_response_bytes(),
        (v6_mismatched_local_alloc, addr_v6(20)),
        now,
    );
    while a.poll_event().is_some() {}
    while a.poll_transmit().is_some() {}
    a.handle_timeout(now);
    let outbound: Vec<_> = std::iter::from_fn(|| a.poll_transmit()).collect();

    // Reply on the v6-mismatched pair first (same identity primary).
    let v6_pair = (v6_mismatched_local_alloc, addr_v6(20));
    let v6_probe = extract_probe_for(&outbound, v6_pair);
    let _ = a.handle_inbound_tun(
        build_echo_reply(v6_probe.id, v6_probe.seq),
        v6_pair,
        now + Duration::from_millis(50),
    );
    assert_eq!(a.primary(), Some(v6_pair));
    while a.poll_event().is_some() {}

    // Reply on the v4-matched pair at identical RTT.
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
    // Two host×host pairs in the same discrete bucket. The incumbent
    // settles at 50 ms; a challenger that is only marginally faster
    // (45 ms — a 5 ms gain, inside the 10 ms floor) must NOT displace it,
    // or probe jitter would flap the primary between effectively-tied
    // pairs, each flap churning the peer socket.
    let mut a = PathAgent::new();
    a.add_local_candidate(Candidate::host(addr(1)));
    a.add_remote_candidate(Candidate::host(addr(3)));
    a.add_remote_candidate(Candidate::host(addr(4)));
    let now = Instant::now();

    // Adopt (1,3) as the initial primary, then give it a measured RTT.
    let _ = a.handle_inbound_network(&handshake_response_bytes(), (addr(1), addr(3)), now);
    while a.poll_event().is_some() {}
    while a.poll_transmit().is_some() {}

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

    // Challenger replies at 45 ms — a sub-margin gain.
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
    // Same setup, but the challenger is decisively faster (30 ms vs
    // 50 ms — a 20 ms gain, past the margin), so the primary moves.
    let mut a = PathAgent::new();
    a.add_local_candidate(Candidate::host(addr(1)));
    a.add_remote_candidate(Candidate::host(addr(3)));
    a.add_remote_candidate(Candidate::host(addr(4)));
    let now = Instant::now();

    let _ = a.handle_inbound_network(&handshake_response_bytes(), (addr(1), addr(3)), now);
    while a.poll_event().is_some() {}
    while a.poll_transmit().is_some() {}

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

    // Challenger replies at 30 ms — clear of the margin.
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

    let _ = a.handle_inbound_network(&handshake_response_bytes(), (addr(2), addr(4)), now);
    while a.poll_event().is_some() {}
    while a.poll_transmit().is_some() {}

    a.handle_timeout(now);
    while a.poll_transmit().is_some() {}

    let stale_reply = build_echo_reply(0, 0xdead);
    let _ = a.handle_inbound_tun(stale_reply, (addr(1), addr(3)), now);

    // The initial-primary already adopted the relay-relay path the
    // handshake landed on; a stale reply doesn't unseat it (no RTT
    // sample landed, so `select_primary` has nothing new to consider).
    assert_eq!(a.primary(), Some((addr(2), addr(4))));
}

#[test]
fn outbound_init_keeps_retransmitting_past_evaluation_window_without_response() {
    // We no longer fail the connection on a missed handshake — boringtun's
    // `REKEY_ATTEMPT_TIME` is the source of truth. Verify retransmits
    // keep firing past the old give-up deadline.
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
fn drive_probes_only_emits_on_primary_after_settle() {
    let mut a = agent_with_relay_pairs();
    let now = Instant::now();
    let primary = (addr(1), addr(3)); // host×host wins on best tier

    // Bootstrap with a probe round-trip that promotes host×host to primary.
    let _ = a.handle_inbound_network(&handshake_response_bytes(), (addr(2), addr(4)), now);
    while a.poll_event().is_some() {}
    while a.poll_transmit().is_some() {}

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

    // Settle. Bootstrap-cadence burst fires here for due pairs, then
    // settle re-baselines only the primary onto `PROBE_INTERVAL_LIVE`
    // and clears the rest.
    a.handle_timeout(now + EVALUATION_WINDOW);
    while a.poll_transmit().is_some() {}

    // Within the live window — nothing fires yet.
    a.handle_timeout(now + EVALUATION_WINDOW + PROBE_INTERVAL_LIVE - Duration::from_millis(1));
    assert!(a.poll_transmit().is_none(), "before live deadline");

    // At the live deadline — only the primary fires.
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

    let _ = a.handle_inbound_network(&handshake_response_bytes(), (addr(2), addr(4)), now);
    while a.poll_event().is_some() {}

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

    // After settle, the only armed deadline is the primary's next live tick.
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

    let _ = a.handle_inbound_network(&handshake_response_bytes(), (addr(2), addr(4)), now);
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

    a.handle_timeout(now + EVALUATION_WINDOW); // settle
    while a.poll_transmit().is_some() {}

    let live_deadline = a.poll_timeout().expect("live cadence");

    let _ = a.handle_inbound_network(
        &handshake_response_bytes(),
        (addr(2), addr(4)),
        now + EVALUATION_WINDOW + Duration::from_secs(60),
    );
    while a.poll_event().is_some() {}

    assert_eq!(a.poll_timeout(), Some(live_deadline));
}

#[test]
fn inbound_handshake_reopens_evaluation_window_after_settle() {
    // Every fresh inbound handshake reopens the probing window so we
    // re-pick the best pair on the new topology. The reopen runs
    // *after* the dedup checks in `handle_inbound_network`, so duplicates of
    // an already-forwarded handshake don't trigger it. This catches
    // the roam case where signalling delivers the peer's new
    // candidates before the handshake itself (so the recv path is
    // already in `self.pairs`); the path-known-or-unknown axis isn't
    // a reliable signal on its own.
    let mut a = agent_with_relay_pairs();
    let now = Instant::now();
    let primary = (addr(1), addr(3));

    // Drive a real handshake, settle on the host×host primary.
    let _ = a.handle_inbound_network(&handshake_response_bytes(), (addr(2), addr(4)), now);
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

    // Sanity: post-settle, only the primary probes.
    let live_tick = now + EVALUATION_WINDOW + PROBE_INTERVAL_LIVE;
    a.handle_timeout(live_tick);
    let live_probes: Vec<_> = std::iter::from_fn(|| a.poll_transmit()).collect();
    assert_eq!(
        live_probes.len(),
        1,
        "post-settle only primary probes, got {live_probes:?}"
    );

    // A *fresh* handshake (different bytes — this is a new session,
    // not a duplicate of the one we already forwarded) on a known
    // pair must still reopen the window: we want to reprobe whether
    // signalling beat the data plane (path was already in pairs) or
    // not. Different bytes avoid the in-flight `forwarded_response`
    // dedup.
    let mut fresh_resp = handshake_response_bytes();
    fresh_resp[10] = 0x42;
    let reopen_at = live_tick + Duration::from_secs(1);
    let _ = a.handle_inbound_network(&fresh_resp, (addr(2), addr(4)), reopen_at);
    while a.poll_event().is_some() {}
    a.handle_timeout(reopen_at);
    let reopened_probes: Vec<_> = std::iter::from_fn(|| a.poll_transmit()).collect();
    assert!(
        reopened_probes.len() > 1,
        "all pairs should probe after reopen, got {reopened_probes:?}"
    );
}

#[test]
fn duplicate_inbound_handshake_does_not_reopen_evaluation_window() {
    // Reopen is gated on actually forwarding a handshake to boringtun:
    // dedup-hit duplicates don't count as "new session" and shouldn't
    // disturb the steady state.
    let mut a = agent_with_relay_pairs();
    let now = Instant::now();
    let primary = (addr(1), addr(3));

    let _ = a.handle_inbound_network(&handshake_response_bytes(), (addr(2), addr(4)), now);
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

    // Same response bytes as before -> hits `forwarded_response` dedup
    // and never triggers the reopen path.
    let later = now + EVALUATION_WINDOW + PROBE_INTERVAL_LIVE + Duration::from_secs(1);
    let _ = a.handle_inbound_network(&handshake_response_bytes(), (addr(2), addr(4)), later);
    a.handle_timeout(later);
    let probes: Vec<_> = std::iter::from_fn(|| a.poll_transmit()).collect();
    assert_eq!(
        probes.len(),
        1,
        "duplicate response shouldn't reopen — only primary probes: {probes:?}"
    );
}

#[test]
fn different_inbound_init_bytes_skip_dedup_cache() {
    let mut a = agent_with_relay_pairs();
    let now = Instant::now();

    populate_responder_cache(&mut a, (addr(2), addr(4)), now);

    let mut different_init = handshake_init_bytes();
    different_init[100] = 0x42;

    let handled = a.handle_inbound_network(&different_init, (addr(2), addr(4)), now);
    assert!(matches!(handled, ControlFlow::Break(())));

    match a.poll_event() {
        Some(Event::ForwardHandshake { bytes }) => assert_eq!(bytes, different_init),
        other => panic!("expected ForwardHandshake, got {other:?}"),
    }
    assert!(a.poll_transmit().is_none());
}

#[test]
fn fresh_inbound_handshake_on_new_path_adopts_it_as_primary() {
    // After settle, an inbound handshake on a path other than the
    // current primary is strictly stronger evidence than smoothed
    // RTT — the handshake completed, so the path is known-working.
    // This is what catches the roam case where the old primary's
    // recent (but stale) RTT sample would otherwise dominate the
    // tier-based score.
    let mut a = agent_with_relay_pairs();
    let now = Instant::now();
    let initial_path = (addr(2), addr(4));

    // Bootstrap on the initial path.
    let _ = a.handle_inbound_network(&handshake_response_bytes(), initial_path, now);
    assert_eq!(a.primary(), Some(initial_path));
    while a.poll_event().is_some() {}

    // A fresh handshake (different bytes -> not deduped) lands on a
    // different known pair: primary must adopt it.
    let mut roam_resp = handshake_response_bytes();
    roam_resp[10] = 0xab;
    let new_path = (addr(1), addr(3));
    let _ = a.handle_inbound_network(&roam_resp, new_path, now + Duration::from_secs(60));
    assert_eq!(a.primary(), Some(new_path));

    // The PrimaryChanged event reflects the new path.
    let mut events = std::iter::from_fn(|| a.poll_event()).collect::<Vec<_>>();
    let primary_changed = events
        .iter()
        .rev()
        .find_map(|e| match e {
            Event::PrimaryChanged { local, remote } => Some((*local, *remote)),
            _ => None,
        })
        .expect("PrimaryChanged event");
    assert_eq!(primary_changed, new_path);
    events.clear();
}

#[test]
fn fresh_handshake_clears_stale_rtt_so_old_pair_does_not_win_against_new_one() {
    // Roam scenario: evaluation settles on `initial_path` with a recent
    // RTT measurement. After a fresh handshake on `roam_path`, a stale
    // probe reply for the *old* path can still arrive (peer's NAT
    // hadn't dropped the old binding yet). Without the topology reset,
    // the old pair's recent low RTT outscores the new pair's first —
    // worse — measurement and the gateway stays glued to the dead
    // primary. Wiping all per-pair RTT/inflight state on a fresh
    // handshake forces probes to start over from scratch.
    let mut a = agent_with_relay_pairs();
    let now = Instant::now();
    let initial_path = (addr(2), addr(4));
    let roam_path = (addr(1), addr(3));

    // Bootstrap and settle: get a low RTT on `initial_path`, mark it
    // primary.
    let _ = a.handle_inbound_network(&handshake_response_bytes(), initial_path, now);
    while a.poll_event().is_some() {}
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

    // Fresh handshake on a different path (different bytes -> not
    // deduped). Adopt-handshake-primary moves primary to roam_path.
    let mut roam_resp = handshake_response_bytes();
    roam_resp[10] = 0xab;
    let roam_at = now + Duration::from_secs(60);
    let _ = a.handle_inbound_network(&roam_resp, roam_path, roam_at);
    assert_eq!(a.primary(), Some(roam_path));
    while a.poll_event().is_some() {}

    // A late probe reply for the *old* `initial_path` lands now —
    // its inflight slot was cleared by the topology reset, so the
    // reply is ignored and primary doesn't swing back.
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
fn duplicate_inbound_handshake_does_not_change_primary() {
    // Dedup hits (responder cache, in-flight init, in-flight response)
    // shouldn't disturb the primary — they aren't fresh sessions.
    let mut a = agent_with_relay_pairs();
    let now = Instant::now();
    let initial_path = (addr(2), addr(4));

    let _ = a.handle_inbound_network(&handshake_response_bytes(), initial_path, now);
    while a.poll_event().is_some() {}

    // Same response bytes -> hits `forwarded_response` dedup.
    let _ = a.handle_inbound_network(
        &handshake_response_bytes(),
        (addr(1), addr(3)),
        now + Duration::from_secs(1),
    );
    assert_eq!(a.primary(), Some(initial_path));
    let primary_changed =
        std::iter::from_fn(|| a.poll_event()).any(|e| matches!(e, Event::PrimaryChanged { .. }));
    assert!(
        !primary_changed,
        "duplicate handshake must not emit PrimaryChanged"
    );
}

#[test]
fn first_inbound_handshake_adopts_initial_primary_so_outbound_data_flows() {
    // Closes the user-data drop window between handshake completion and
    // the first probe RTT: the relay path the WG handshake landed on is
    // adopted as the primary immediately.
    let mut a = agent_with_relay_pairs();
    let now = Instant::now();
    let recv_path = (addr(2), addr(4));

    let _ = a.handle_inbound_network(&handshake_response_bytes(), recv_path, now);
    assert_eq!(a.primary(), Some(recv_path));

    // Outbound user data routes through the initial primary.
    while a.poll_event().is_some() {}
    while a.poll_transmit().is_some() {}
    a.handle_outbound(data_packet_bytes(), now);
    let t = a.poll_transmit().expect("primary transmit");
    assert_eq!((t.local, t.remote), recv_path);
}

#[test]
fn responder_rekey_init_rides_primary_after_initial_response_sent() {
    // The Controlled side never fans out a handshake init — it only
    // responds to the Controlling side's. When it later acts as the
    // re-key initiator (boringtun's per-session timer can fire from
    // either side), the resulting `HandshakeInit` should ride `primary`,
    // not re-fan out across every relay pair. Setting `established` on
    // the first sent response is what guarantees that.
    let mut a = agent_with_relay_pairs();
    let now = Instant::now();
    let recv_path = (addr(2), addr(4));

    // Receive an init, send a response.
    let _ = a.handle_inbound_network(&handshake_init_bytes(), recv_path, now);
    while a.poll_event().is_some() {}
    a.handle_outbound(handshake_response_bytes(), now);
    while a.poll_transmit().is_some() {}

    // Re-key init from boringtun: single transmit on primary only.
    a.handle_outbound(handshake_init_bytes(), now + Duration::from_secs(120));
    let rekey: Vec<_> = std::iter::from_fn(|| a.poll_transmit()).collect();
    assert_eq!(rekey.len(), 1, "re-key rides the primary: {rekey:?}");
    assert_eq!((rekey[0].local, rekey[0].remote), recv_path);
}

#[test]
fn rekey_handshake_init_rides_primary_instead_of_re_fanning_out() {
    // After the first handshake fanout, `established` flips so any later
    // `HandshakeInit` boringtun emits (re-keys, every ~120 s) goes via
    // primary on a single pair instead of bursting across all relays.
    let mut a = agent_with_relay_pairs();
    let now = Instant::now();
    let recv_path = (addr(2), addr(4));

    // Bootstrap fanout.
    a.handle_outbound(handshake_init_bytes(), now);
    a.handle_timeout(now);
    let initial: Vec<_> = std::iter::from_fn(|| a.poll_transmit()).collect();
    assert_eq!(initial.len(), 3, "handshake fans out on every relay pair");

    // Inbound response → primary is set, retransmit ladder is cleared.
    let _ = a.handle_inbound_network(&handshake_response_bytes(), recv_path, now);
    while a.poll_event().is_some() {}
    while a.poll_transmit().is_some() {}

    // Re-key init from boringtun should NOT re-fan out — single transmit
    // on the primary pair only.
    a.handle_outbound(handshake_init_bytes(), now + Duration::from_secs(120));
    let rekey: Vec<_> = std::iter::from_fn(|| a.poll_transmit()).collect();
    assert_eq!(rekey.len(), 1, "re-key rides the primary: {rekey:?}");
    assert_eq!((rekey[0].local, rekey[0].remote), recv_path);
}

#[test]
fn probe_skips_while_inflight_until_probe_timeout_lapses() {
    // Paths whose RTT exceeds `PROBE_INTERVAL` rely on the skip-while-pending
    // semantics: the next probe doesn't fire (and overwrite the inflight
    // seq slot) while the previous one is still in flight, so a late reply
    // can still match. After `PROBE_TIMEOUT` we give up on the inflight
    // probe and a fresh one fires.
    let mut a = agent_with_relay_pairs();
    let now = Instant::now();

    let _ = a.handle_inbound_network(&handshake_response_bytes(), (addr(2), addr(4)), now);
    while a.poll_event().is_some() {}
    while a.poll_transmit().is_some() {}

    a.handle_timeout(now);
    let first: Vec<_> = std::iter::from_fn(|| a.poll_transmit()).collect();
    let pair = (addr(1), addr(3));
    let first_seq = extract_probe_for(&first, pair).seq;

    // Tick at next_probe_at = now + PROBE_INTERVAL but no reply yet —
    // the inflight slot is still occupied. We hold off rather than
    // overwriting it.
    a.handle_timeout(now + PROBE_INTERVAL);
    let mid: Vec<_> = std::iter::from_fn(|| a.poll_transmit())
        .filter(|t| (t.local, t.remote) == pair)
        .collect();
    assert!(
        mid.is_empty(),
        "expected no probe re-fire while previous is inflight: {mid:?}"
    );

    // Once `PROBE_TIMEOUT` elapses, the lost probe is dropped and the
    // next fire claims the slot with the next seq.
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
fn trickled_candidate_after_handshake_still_gets_probed() {
    // Reproduces the trickle-ICE production case: initial handshake
    // completes when only relay pairs exist (host/srflx candidates
    // haven't arrived via signalling yet), then a remote host
    // candidate trickles in. The new pair must start probing within
    // the same path-evaluation window — otherwise it's invisible to
    // `select_primary` and `maybe_settle` locks it out for ~2 min
    // until the next re-key reopens the window.
    let mut a = PathAgent::new();
    a.add_local_candidate(Candidate::host(addr(1)));
    a.add_local_candidate(Candidate::relayed(addr(2), addr(2)));
    a.add_remote_candidate(Candidate::relayed(addr(4), addr(4)));

    let now = Instant::now();
    let _ = a.handle_inbound_network(&handshake_response_bytes(), (addr(2), addr(4)), now);
    while a.poll_event().is_some() {}
    while a.poll_transmit().is_some() {}

    // Trickle: remote host candidate arrives after handshake. Its
    // pairs (1,3) and (2,3) get added with `next_probe_at = None`.
    a.add_remote_candidate(Candidate::host(addr(3)));

    a.handle_timeout(now);
    let transmits: Vec<_> = std::iter::from_fn(|| a.poll_transmit()).collect();

    // `extract_probe_for` panics if the pair didn't emit a probe.
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

/// Drive the responder side through a full inbound init → outbound
/// response cycle so the dedup cache is populated.
fn populate_responder_cache(a: &mut PathAgent, recv_path: (SocketAddr, SocketAddr), now: Instant) {
    let _ = a.handle_inbound_network(&handshake_init_bytes(), recv_path, now);
    while a.poll_event().is_some() {}
    a.handle_outbound(handshake_response_bytes(), now);
    while a.poll_transmit().is_some() {}
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

/// Inspect an `IpPacket` carrying our probe shape and pull out
/// `(kind, id, seq)`. `None` if it isn't a well-formed probe between
/// the magic addresses.
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

/// Match an outbound `Transmit` against an `(local, remote)` pair, returning
/// the parsed probe payload.
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
