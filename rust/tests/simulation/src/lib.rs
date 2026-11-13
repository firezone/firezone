//! Deterministic, in-process simulations of connlib's components.
#![allow(clippy::unwrap_used, clippy::unwrap_in_result)]
#![allow(clippy::print_stdout, clippy::print_stderr)]

mod arb;
mod assertions;
mod buffered_transmits;
mod dns_records;
mod dns_server_resource;
mod echo;
mod feedback;
mod flux_capacitor;
mod os;
mod probe;
mod ref_client;
mod ref_gateway;
mod relay;
mod relay_reference;
mod relay_transition;
mod resource;
mod sim_client;
mod sim_gateway;
mod sim_net;
mod sim_relay;
mod sim_tunnel;
mod site_network;
mod stub_portal;
mod stun;
mod sut;
mod tcp;
mod tunnel_reference;
mod tunnel_transition;

use std::time::Instant;

use arbitrary::Unstructured;
use chrono::{DateTime, Utc};
use tracing_subscriber::{
    EnvFilter, Layer, layer::SubscriberExt as _, util::SubscriberInitExt as _,
};

use crate::{
    arb::Generator, assertions::check_invariants, flux_capacitor::FluxCapacitor, sut::TunnelTest,
};

type QueryId = u16;

/// A PTR query in the device domain: its name, the server it went to, its ID and how it
/// was sent.
type DeviceListingQuery = (
    dns_types::DomainName,
    ::tunnel_proto::dns::Upstream,
    QueryId,
    tunnel_transition::DnsTransport,
);

/// The response code of an answer to a PTR query in the device domain, its records with
/// their TTLs and its note.
type DeviceListing = (
    dns_types::ResponseCode,
    std::collections::BTreeSet<(dns_types::OwnedRecordData, u32)>,
    Option<String>,
);

const MAX_TUNNEL_TRANSITIONS: usize = 20;
const MAX_RELAY_TRANSITIONS: usize = 64;

/// Runs the tunnel simulation that `data` describes, with its clock starting at `now`.
///
/// Simulates clients, gateways, relays and the portal and checks the tunnel state machines
/// against a reference model. Panics if the tunnel violates an invariant.
pub fn run_tunnel(data: &[u8], now: Instant) {
    let _guard = init_subscriber();

    let utc_start = DateTime::<Utc>::from_timestamp(0, 0).expect("0 is a valid UNIX timestamp");
    let flux_capacitor = FluxCapacitor::new(now, utc_start);
    let mut generator = Generator::new(data);
    let domain_tree = generator.domain_tree();
    let mut portal = generator.portal(&domain_tree);
    let mut reference = generator.reference_state(&portal, domain_tree);
    let mut feedback_recorder = feedback::Recorder::default();

    let mut tunnel = TunnelTest::init_test(&reference, &mut portal, flux_capacitor.clone());
    check_invariants(&reference, &tunnel, &portal);

    for applied in 0..MAX_TUNNEL_TRANSITIONS {
        if generator.is_empty() {
            break;
        }

        let transition = generator.transition(&reference, &portal, flux_capacitor.now());

        tracing::debug!("Applying transition {applied}: {transition:?}");
        feedback_recorder.observe(&transition, &reference, flux_capacitor.now());

        reference.invalidate(&transition, &portal);
        tunnel.invalidate(&reference);

        portal.apply(&transition, &reference);
        reference = reference.apply(&transition, &portal, flux_capacitor.now());
        tunnel = tunnel.apply(transition, &reference, &mut portal);
        check_invariants(&reference, &tunnel, &portal);
        feedback_recorder.record(&reference, &tunnel, &portal);
    }
}

/// Runs the relay simulation that `data` describes, with its clock starting at `now`.
///
/// Simulates a relay client, a relay and the portal and checks the client against a reference
/// model. Panics if the client or the relay violates it.
pub fn run_relay(data: &[u8], now: Instant) {
    let _guard = init_subscriber();

    let mut u = Unstructured::new(data);
    let relay = relay_transition::stack(&mut u);
    let client = relay_transition::stack(&mut u);

    let mut reference = relay_reference::Reference::default();
    let mut world = relay::World::new(relay, client, now);
    world.settle();
    world.check(&reference, true);

    for applied in 0..MAX_RELAY_TRANSITIONS {
        if u.is_empty() {
            break;
        }

        let (transition, loss) = relay_transition::Transition::arbitrary(&mut u);

        tracing::debug!("Applying transition {applied}: {transition:?} with {loss:?}");

        world.apply(&transition, loss);
        let may_interrupt = reference.apply(&transition, world.environment(), world.observed);
        world.check(&reference, may_interrupt);
    }
}

/// Initializes a subscriber that panics on error events.
///
/// It writes no logs by default; setting `RUST_LOG` additionally writes a trace to stderr.
fn init_subscriber() -> tracing::subscriber::DefaultGuard {
    const DEFAULT_FILTER: &str =
        "debug,tunnel_proto=trace,simulation=debug,ip_packet=trace,frostlink=trace";

    let log_layer = std::env::var("RUST_LOG").ok().map(|filter| {
        tracing_subscriber::fmt::layer()
            .with_writer(std::io::stderr)
            .with_ansi(false)
            .with_filter(EnvFilter::new(format!("{DEFAULT_FILTER},{filter}")))
    });

    tracing_subscriber::registry()
        .with(assertions::PanicOnErrorEvents::new())
        .with(log_layer)
        .set_default()
}
