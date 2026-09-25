//! Adds domain-specific signals to coverage-guided fuzzing.
//!
//! Edge coverage tells AFL++ which control-flow paths an input reaches, but not
//! whether those paths occur in a meaningful combination of protocol states.
//! [`record`] inspects the reference and simulated states after their invariants
//! have been checked and records selected combinations as IJON set features.
//! Each annotation site has its own feature space, and observing the same value
//! again does not make an input interesting.
//!
//! `prepare_runtime` enables the IJON map before discovery starts. Replay still
//! evaluates the observations, but does not record feedback.

use std::collections::BTreeSet;

use itertools::Itertools as _;

use crate::{
    probe::{
        DNS_NAT_SESSION_TTL, DnsNatObservation, DnsNatSessions, ExpectedOutcome, ProbeRequest,
        Remote, remote_responds_with_icmp_error,
    },
    reference::ReferenceState,
    sim_gateway::DnsResolution,
    sut::TunnelTest,
};

// The AFL runtime defines this symbol weakly. Rust's IJON macros already emit
// the recording calls; this is the enable flag normally emitted by its LLVM pass.
#[cfg(fuzzing)]
#[used]
#[unsafe(no_mangle)]
static mut __afl_ijon_enabled: u32 = 1;

/// Prepares IJON before starting AFL's deferred forkserver.
#[cfg(fuzzing)]
pub fn prepare_runtime() {
    if std::env::var_os("__AFL_SHM_ID").is_none() {
        return;
    }

    unsafe extern "C" {
        static mut __afl_ijon_map_increased: u32;
    }

    // AFL++ 4.40c resets the negotiated map size after sanitizer coverage
    // initializes, but leaves this flag set. Rearm the expansion before
    // the deferred forkserver reports its map size.
    unsafe { __afl_ijon_map_increased = 0 };
}

/// Records a numeric state category as feedback for the fuzzer.
///
/// Each call site records its values independently. The argument is a `u16`
/// evaluated once, including during replay. Prefer small enums or bounded buckets
/// over raw identifiers and counters. Annotations must run on a single thread.
macro_rules! record_value {
    ($value:expr $(,)?) => {{
        let value: u16 = $value;
        ::core::cfg_select! {
            fuzzing => { ::afl::ijon_set!(u32::from(value)); }
            _ => { let _ = value; }
        }
    }};
}

/// Records a combination of boolean state predicates as feedback for the fuzzer.
///
/// Each call site records its combinations independently. Arguments are evaluated
/// once, in order, with the first argument in the lowest bit. At most 16 booleans
/// fit in AFL++'s IJON set bitmap. Annotations must run on a single thread.
/// Replay evaluates the predicates without recording feedback.
macro_rules! record {
    ($($flag:expr),+ $(,)?) => {{
        const {
            assert!(
                [$(stringify!($flag)),+].len() <= 16,
                "fuzzer feedback supports at most 16 booleans",
            );
        }
        let flags: &[bool] = &[$($flag),+];
        let value = flags.iter().enumerate().fold(0, |value, (bit, flag)| {
            value | (u16::from(*flag) << bit)
        });
        record_value!(value);
    }};
}

/// Records observed state combinations that should guide future fuzzing.
pub fn record(reference: &ReferenceState, state: &TunnelTest) {
    record_translated_icmp_error_feedback(reference, state);
    record_dns_refresh_feedback(state);
    record_live_dns_flow_feedback(reference, state);
}

fn record_translated_icmp_error_feedback(reference: &ReferenceState, state: &TunnelTest) {
    for expected in reference.expected_probes.values() {
        let ExpectedOutcome::RoundTripCompleted(route) = expected.outcome else {
            continue;
        };
        let remote = route.remote();
        if !matches!(remote, Remote::Gateway(_)) {
            continue;
        }

        let trace = state.probe_trace(expected.id);
        let ([submitted_request], [received_request], [_received_response]) = (
            trace.submitted_requests.as_slice(),
            trace.received_requests.as_slice(),
            trace.received_responses.as_slice(),
        ) else {
            continue;
        };
        let destination_was_translated =
            submitted_request.packet.destination() != received_request.packet.destination();
        if !destination_was_translated {
            continue;
        }

        let responds_with_icmp_error = remote_responds_with_icmp_error(
            expected,
            received_request,
            remote,
            &reference.icmp_error_hosts,
        );
        record!(
            submitted_request.packet.destination().is_ipv6(),
            received_request.packet.destination().is_ipv6(),
            matches!(expected.request, ProbeRequest::Udp { .. }),
            responds_with_icmp_error,
        );
    }
}

fn record_live_dns_flow_feedback(reference: &ReferenceState, state: &TunnelTest) {
    for observation in state.dns_nat_observations() {
        if observation.response_received_at.is_none()
            || state.now().duration_since(observation.received.at) >= DNS_NAT_SESSION_TTL
            || !(reference.udp_flows.contains_key(&observation.flow_id)
                || reference.icmp_flows.contains_key(&observation.flow_id))
        {
            continue;
        }
        let Remote::Gateway(gateway) = observation.received.remote else {
            continue;
        };
        let Some(gateway) = state.gateway(gateway) else {
            continue;
        };
        if observation.received.dns_nat_generation
            != Some(gateway.dns_nat_generation(observation.submitted.client))
        {
            continue;
        }

        let ipv6 = observation.submitted.packet.destination().is_ipv6();
        let addresses = reference
            .global_dns_records
            .domain_ips_iter(&observation.domain)
            .filter(|ip| ip.is_ipv6() == ipv6)
            .collect::<BTreeSet<_>>();
        let answers_changed = addresses != observation.dns_addresses;
        let old_destination_absent =
            !addresses.contains(&observation.received.packet.destination());
        let udp = observation.submitted.packet.as_udp().is_some();
        record!(ipv6, udp, answers_changed, old_destination_absent);
    }
}

fn record_dns_refresh_feedback(state: &TunnelTest) {
    let sessions = DnsNatSessions::new(state.dns_nat_observations()).sessions;

    for session in sessions {
        let [first, ..] = session.observations.as_slice() else {
            continue;
        };
        let Some(order) = first.received.gateway_order else {
            continue;
        };
        let Some(gateway) = state.gateway(session.key.gateway) else {
            continue;
        };
        let Some(initial_resolution) = gateway.dns_resolution_before(
            session.key.client,
            &first.domain,
            first.received.at,
            order,
            session.key.dns_nat_generation,
            session.key.proxy,
        ) else {
            continue;
        };

        record_dns_refresh_session_feedback(
            &session.observations,
            gateway
                .dns_resolutions(
                    session.key.client,
                    &first.domain,
                    session.key.dns_nat_generation,
                    session.key.proxy,
                )
                .filter(|candidate| candidate.order >= initial_resolution.order),
        );
    }
}

fn record_dns_refresh_session_feedback<'a>(
    session: &[&DnsNatObservation],
    resolutions: impl Iterator<Item = &'a DnsResolution>,
) {
    for (previous, refreshed) in resolutions.tuple_windows() {
        for before in session {
            let Some(response_at) = before.response_received_at else {
                continue;
            };
            if response_at >= refreshed.at
                || refreshed.at.duration_since(before.received.at) >= DNS_NAT_SESSION_TTL
            {
                continue;
            }

            let ipv6 = before.submitted.packet.destination().is_ipv6();
            let previous_addresses = previous
                .addresses
                .iter()
                .filter(|ip| ip.is_ipv6() == ipv6)
                .collect::<BTreeSet<_>>();
            let refreshed_addresses = refreshed
                .addresses
                .iter()
                .filter(|ip| ip.is_ipv6() == ipv6)
                .collect::<BTreeSet<_>>();
            let answers_changed = previous_addresses != refreshed_addresses;
            let old_destination_absent = !refreshed
                .addresses
                .contains(&before.received.packet.destination());
            let udp = before.submitted.packet.as_udp().is_some();
            record!(ipv6, udp, answers_changed, old_destination_absent);

            let flow_exercised_after_refresh = session.iter().any(|after| {
                after.flow_id == before.flow_id
                    && after
                        .received
                        .gateway_order
                        .is_some_and(|order| order > refreshed.order)
                    && after.response_received_at.is_some()
            });
            if flow_exercised_after_refresh {
                record!(ipv6, udp, answers_changed, old_destination_absent);
            }
        }
    }
}
