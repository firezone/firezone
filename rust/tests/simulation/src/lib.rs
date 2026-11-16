//! Deterministic, in-process simulations of connlib's components.
#![allow(clippy::unwrap_used, clippy::unwrap_in_result)]
#![allow(clippy::print_stdout, clippy::print_stderr)]

mod arb;
mod assertions;
mod buffered_transmits;
mod clock;
mod dns_records;
mod dns_server_resource;
mod echo;
mod fake_portal;
mod feedback;
mod model_client;
mod model_gateway;
mod network;
mod os;
mod probe;
mod real_client;
mod real_gateway;
mod real_relay;
mod real_tunnel;
mod real_tunnel_system;
mod relay;
mod relay_reference;
mod relay_transition;
mod resource;
mod site_network;
mod stun;
mod tcp;
mod tunnel_model;
mod tunnel_transition;

use std::time::Instant;

use arbitrary::Unstructured;
use chrono::{DateTime, Utc};
use tracing_subscriber::{
    EnvFilter, Layer, layer::SubscriberExt as _, util::SubscriberInitExt as _,
};

use crate::{
    arb::Generator, assertions::check_invariants, clock::Clock,
    real_tunnel_system::RealTunnelSystem,
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
/// against a model. Panics if the tunnel violates an invariant.
pub fn run_tunnel(data: &[u8], now: Instant) {
    let _guard = init_subscriber();

    let utc_start = DateTime::<Utc>::from_timestamp(0, 0).expect("0 is a valid UNIX timestamp");
    let clock = Clock::new(now, utc_start);
    let mut generator = Generator::new(data);
    let domain_tree = generator.domain_tree();
    let mut portal = generator.portal(&domain_tree);
    let mut model = generator.model(&portal, domain_tree);
    let mut feedback_recorder = feedback::Recorder::default();

    let mut tunnel = RealTunnelSystem::init_test(&model, &mut portal, clock.clone());
    check_invariants(&model, &tunnel, &portal);

    for applied in 0..MAX_TUNNEL_TRANSITIONS {
        if generator.is_empty() {
            break;
        }

        let transition = generator.transition(&model, &portal, clock.now());

        tracing::debug!("Applying transition {applied}: {transition:?}");
        feedback_recorder.observe(&transition, &model, clock.now());

        model.invalidate(&transition, &portal);
        tunnel.invalidate(&model);

        portal.apply(&transition, &model);
        model = model.apply(&transition, &portal, clock.now());
        tunnel = tunnel.apply(transition, &model, &mut portal);
        check_invariants(&model, &tunnel, &portal);
        feedback_recorder.record(&model, &tunnel, &portal);
    }
}

/// Runs the relay simulation that `data` describes, with its clock starting at `now`.
///
/// Simulates a relay client, a relay and the portal and checks the client against a reference
/// model. Panics if the client or the relay violates it.
pub fn run_relay(data: &[u8], now: Instant) {
    let _guard = init_subscriber();

    let mut u = Unstructured::new(data);
    let relay = relay::arbitrary_ip_stack(&mut u);
    let client = relay::arbitrary_ip_stack(&mut u);

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

    // Building the layer creates hash maps and `std` seeds each hash map from how many the thread built before it.
    // Without `RUST_LOG` we therefore build it too, with everything filtered out.
    let filter = match std::env::var("RUST_LOG") {
        Ok(filter) => format!("{DEFAULT_FILTER},{filter}"),
        Err(_) => "off".to_owned(),
    };
    let log_layer = tracing_subscriber::fmt::layer()
        .with_writer(std::io::stderr)
        .with_ansi(false)
        .with_filter(EnvFilter::new(filter));

    tracing_subscriber::registry()
        .with(assertions::PanicOnErrorEvents::new())
        .with(log_layer)
        .set_default()
}
