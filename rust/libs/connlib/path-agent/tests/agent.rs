//! Integration tests for `PathAgent` against the public crate API.
//!
//! Tests are deliberately narrow: this file covers the path-agent
//! state machine's discrete-prefix scoring, timing, peer-reflexive
//! discovery, and the security regression for the validate-then-commit
//! path. Higher-level flow — dedup behaviour, handshake fanout
//! correctness, roam recovery — rides on the tunnel proptest in
//! `libs/connlib/tunnel/src/tests`, which exercises this code through
//! the full snownet event loop.

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

    // PrimaryChanged firing means `Tunn` accepted the bytes — only
    // accepted handshakes mutate state.
    match a.poll_event() {
        Some(Event::PrimaryChanged { local, remote }) => {
            assert_eq!((local, remote), (addr(2), addr(4)));
        }
        other => panic!("expected PrimaryChanged, got {other:?}"),
    }
}

#[test]
fn rejected_handshake_leaves_state_untouched() {
    // Sanity: when `Tunn` rejects the bytes, none of the responder
    // dedup, evaluation-window reopen, primary adoption, or outbound
    // routing should fire — those are reserved for known-good bytes.
    let mut a = agent_with_relay_pairs();
    let now = Instant::now();
    let mut hs = Handshake::new(now);

    // `reject_all()` is built on a different keypair so it can't
    // authenticate bytes that came from `hs`'s initiator.
    let _ = a.handle_inbound_network(&mut reject_all(), &hs.init, (addr(2), addr(4)), now);

    assert!(
        a.poll_event().is_none(),
        "rejected bytes must not adopt a primary"
    );
    assert!(
        a.poll_transmit().is_none(),
        "rejected bytes must not queue any outbound"
    );

    // A subsequent legitimate arrival of the same bytes still
    // validates — the rejection didn't pollute responder dedup.
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
fn probe_skips_while_inflight_until_probe_timeout_lapses() {
    // Paths whose RTT exceeds `PROBE_INTERVAL` rely on the skip-while-pending
    // semantics: the next probe doesn't fire (and overwrite the inflight
    // seq slot) while the previous one is still in flight, so a late reply
    // can still match. After `PROBE_TIMEOUT` we give up on the inflight
    // probe and a fresh one fires.
    let mut a = agent_with_relay_pairs();
    let now = Instant::now();
    bootstrap_primary(&mut a, (addr(2), addr(4)), now);

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
fn drive_probes_only_emits_on_primary_after_settle() {
    let mut a = agent_with_relay_pairs();
    let now = Instant::now();
    let primary = (addr(1), addr(3)); // host×host wins on best tier
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

    a.handle_timeout(now + EVALUATION_WINDOW); // settle
    while a.poll_transmit().is_some() {}

    let live_deadline = a.poll_timeout().expect("live cadence");

    // Re-feed the same response bytes — hits `forwarded_response`
    // dedup before `Tunn` is touched, so settle's cadence holds.
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
    // Every fresh inbound handshake reopens the probing window so we
    // re-pick the best pair on the new topology. This catches the
    // roam case where signalling delivers the peer's new candidates
    // before the handshake itself (so the recv path is already in
    // `self.pairs`); the path-known-or-unknown axis isn't a reliable
    // signal on its own.
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

    // Sanity: post-settle, only the primary probes.
    let live_tick = now + EVALUATION_WINDOW + PROBE_INTERVAL_LIVE;
    a.handle_timeout(live_tick);
    let live_probes: Vec<_> = std::iter::from_fn(|| a.poll_transmit()).collect();
    assert_eq!(
        live_probes.len(),
        1,
        "post-settle only primary probes, got {live_probes:?}"
    );

    // A fresh handshake (different bytes — built from a separate
    // `Handshake` pair) reopens the window even though the recv path
    // was already known.
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
    // Arrange: agent has remotes (host, relay) at addr(3) / addr(4).
    // A probe arrives from addr(99) — an address the peer never
    // signalled (their NAT picked a different mapping). The path-
    // agent should register it as a remote candidate and create the
    // pair so `drive_probes` measures it on the open window.
    let mut a = agent_with_relay_pairs();
    let now = Instant::now();
    bootstrap_primary(&mut a, (addr(2), addr(4)), now);

    let request = build_echo_request(0, 1);
    let _ = a.handle_inbound_tun(request, (addr(1), addr(99)), now);

    // Drain the immediate echo reply.
    while a.poll_transmit().is_some() {}

    // Act: drive probes. The new (host_local, peer_reflexive) pair
    // should be due immediately (lazy seed during open window) and
    // emit a probe alongside the previously-known pairs.
    a.handle_timeout(now);
    let probes: Vec<_> = std::iter::from_fn(|| a.poll_transmit()).collect();

    // Will panic if the pair didn't fire — exactly what we want.
    let _ = extract_probe_for(&probes, (addr(1), addr(99)));
}

#[test]
fn signaled_candidate_promotes_peer_reflexive_in_place() {
    // Arrange: register a peer-reflexive remote at addr(99) via an
    // Echo Request, then accumulate RTT on the (addr(1), addr(99))
    // pair through one probe round-trip.
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

    // Confirm the peer-reflexive pair now has RTT, and is among
    // primary candidates.
    assert!(a.pairs().any(|p| p == (addr(1), addr(99))));

    // Act: the peer later signals the matching srflx via
    // `add_remote_candidate`. The path-agent should promote the
    // peer-reflexive entry in place.
    a.add_remote_candidate(Candidate::server_reflexive(addr(99), addr(98)));

    // Assert: the pair still exists (same key, RTT preserved by
    // virtue of pair-state survival), and the candidate count
    // didn't double — no duplicate at addr(99).
    assert!(a.pairs().any(|p| p == (addr(1), addr(99))));
    let count_at_99 = a.pairs().filter(|(_, r)| *r == addr(99)).count();
    assert_eq!(count_at_99, 2, "pairs at addr(99): one per local");

    // A second signaled candidate at the same addr is now a no-op
    // (struct-equal dedup applies after promotion clears the set).
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
    // Within the Relayed tier, prefer the locally-relayed pair so a
    // relay rotation stays a local-only concern (no invalidated
    // remote candidate to signal back to the peer).
    let mut a = PathAgent::new();
    a.add_local_candidate(Candidate::host(addr(1)));
    a.add_local_candidate(Candidate::relayed(addr(2), addr(2)));
    a.add_remote_candidate(Candidate::host(addr(3)));
    a.add_remote_candidate(Candidate::relayed(addr(4), addr(4)));
    let now = Instant::now();

    // Bootstrap on the remote-relay pair (LocalHost → RemoteRelay) so
    // the incumbent sits in the worse `RelayEnd::Remote` bucket.
    let remote_relay_pair = (addr(1), addr(4));
    bootstrap_primary(&mut a, remote_relay_pair, now);

    a.handle_timeout(now);
    let outbound: Vec<_> = std::iter::from_fn(|| a.poll_transmit()).collect();

    // Give the incumbent an RTT measurement so the local-relay
    // challenger can't sneak past on the no-RTT-incumbent path.
    let remote_relay_probe = extract_probe_for(&outbound, remote_relay_pair);
    let _ = a.handle_inbound_tun(
        build_echo_reply(remote_relay_probe.id, remote_relay_probe.seq),
        remote_relay_pair,
        now + Duration::from_millis(50),
    );
    assert_eq!(a.primary(), Some(remote_relay_pair));
    while a.poll_event().is_some() {}

    // Reply on the local-relay pair at identical RTT — the
    // `RelayEnd::Local < RelayEnd::Remote` discrete win should swap
    // primary regardless of RTT hysteresis.
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
    // Two host×host pairs, one v4 and one v6, that reply at identical
    // RTT. The v6 tie-break should put the v6 pair in `primary`.
    let mut a = PathAgent::new();
    a.add_local_candidate(Candidate::host(addr(1))); // v4
    a.add_local_candidate(Candidate::host(addr_v6(11))); // v6
    a.add_remote_candidate(Candidate::host(addr(2))); // v4
    a.add_remote_candidate(Candidate::host(addr_v6(12))); // v6
    let now = Instant::now();
    bootstrap_primary(&mut a, (addr(1), addr(2)), now);

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
fn primary_holds_better_bucket_when_incumbent_has_no_rtt() {
    // Regression: a fresh inbound handshake wipes per-pair RTTs and
    // `maybe_adopt_handshake_primary` picks the recv path. The first
    // probe to return RTT after that must NOT displace the incumbent
    // if its bucket is strictly worse on the discrete prefix —
    // otherwise dual-stack peers flop between v4 and v6 on every
    // re-key while the v6 probe is still in flight.
    let mut a = PathAgent::new();
    a.add_local_candidate(Candidate::host(addr(1))); // v4
    a.add_local_candidate(Candidate::host(addr_v6(11))); // v6
    a.add_remote_candidate(Candidate::host(addr(2))); // v4
    a.add_remote_candidate(Candidate::host(addr_v6(12))); // v6
    let now = Instant::now();
    let v6_pair = (addr_v6(11), addr_v6(12));

    // Bootstrap adopts v6 as primary via the handshake recv path; no
    // probes have round-tripped yet, so v6 has no RTT.
    bootstrap_primary(&mut a, v6_pair, now);
    assert_eq!(a.primary(), Some(v6_pair));

    // The v4 probe returns first, in a strictly worse bucket
    // (LocalFamily::V4). v6's probe hasn't come back yet.
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
    bootstrap_primary(&mut a, (mismatched_local_alloc, addr_v6(20)), now);

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
    bootstrap_primary(&mut a, (v6_mismatched_local_alloc, addr_v6(20)), now);
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
    bootstrap_primary(&mut a, (addr(2), addr(4)), now);

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

    // Fresh handshake on a different path (a fresh `Handshake` produces
    // new bytes — they won't hit `forwarded_response` dedup).
    // Adopt-handshake-primary moves primary to roam_path.
    let roam_at = now + Duration::from_secs(60);
    let mut hs2 = Handshake::new(roam_at).with_response(roam_at);
    let _ = a.handle_inbound_network(&mut hs2.initiator, &hs2.response, roam_path, roam_at);
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
    let mut hs = Handshake::new(now).with_response(now);
    let _ = a.handle_inbound_network(&mut hs.initiator, &hs.response, recv_path, now);
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
    bootstrap_primary(&mut a, (addr(2), addr(4)), now);

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

/// Type-tagged synthetic `HandshakeInit`. `handle_outbound` only
/// parses the type byte, so this is enough for tests that drive an
/// outbound init; for `handle_inbound_network`, use [`Handshake`].
fn handshake_init_bytes() -> Vec<u8> {
    let mut bytes = vec![0u8; 148];
    bytes[0] = 1;
    bytes
}

/// Drive `a` through a real inbound handshake on `recv_path` and
/// settle the initial primary on it. Most scoring tests bootstrap
/// the agent this way before exercising probing / RTT mechanics.
fn bootstrap_primary(a: &mut PathAgent, recv_path: (SocketAddr, SocketAddr), now: Instant) {
    let mut hs = Handshake::new(now).with_response(now);
    let _ = a.handle_inbound_network(&mut hs.initiator, &hs.response, recv_path, now);
    while a.poll_event().is_some() {}
    while a.poll_transmit().is_some() {}
}

/// A fresh pair of real boringtun `Tunn`s plus the bytes from the
/// handshake between them. `handle_inbound_network` runs
/// `Tunn::decapsulate_at` to authenticate, so any test that feeds
/// handshake bytes through it needs a real pair.
///
/// Builds one pair per call (each test owns its own) — sharing across
/// tests is unsafe because `Tunn` mutates internal state on decap.
struct Handshake {
    initiator: Tunn,
    responder: Tunn,
    init: Vec<u8>,
    response: Vec<u8>,
}

impl Handshake {
    /// Build a fresh pair. The initiator has emitted its init, but
    /// the responder hasn't consumed it yet — tests feeding
    /// `hs.init` through `handle_inbound_network` use `hs.responder`
    /// here. `hs.response` is empty; call [`with_response`] if the
    /// test also needs the response leg.
    ///
    /// [`with_response`]: Handshake::with_response
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

    /// Drive the responder through the init to capture the response.
    /// After this, `responder` can't re-consume `init` (TAI64N replay),
    /// but `initiator` is positioned to authenticate `response`.
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

/// `Tunn` built on keys that don't match what generated any test
/// handshake bytes — every `decapsulate_at` call rejects. Used to
/// verify path-agent state stays untouched on rejection, and to
/// prove dedup hits short-circuit before `Tunn` is invoked.
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
