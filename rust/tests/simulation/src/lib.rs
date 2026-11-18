//! Deterministic, in-process simulations of connlib's components.
#![allow(clippy::unwrap_used, clippy::unwrap_in_result)]
#![allow(clippy::print_stdout, clippy::print_stderr)]

mod assertions;
mod buffered_transmits;
mod dns_records;
mod dns_server_resource;
mod echo;
mod fake_portal;
mod feedback;
mod flux_capacitor;
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
mod resource;
mod site_network;
mod tcp;
mod tunnel_generator;
mod tunnel_model;
mod tunnel_transition;

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

/// Simulates clients, gateways, relays and the portal and checks the tunnel state machines against a model.
pub mod tunnel {
    use std::time::Instant;

    use jiff::Timestamp;
    use tracing_subscriber::{
        EnvFilter, Layer, layer::SubscriberExt as _, util::SubscriberInitExt as _,
    };

    use super::{
        assertions::{PanicOnErrorEvents, check_invariants},
        feedback,
        flux_capacitor::FluxCapacitor,
        real_tunnel_system::RealTunnelSystem,
        tunnel_generator::TunnelGenerator,
    };

    const MAX_TRANSITIONS: usize = 20;

    /// Runs the simulation that `data` describes, with its clock starting at `now`.
    ///
    /// Panics if the tunnel violates an invariant.
    pub fn run(data: &[u8], now: Instant) {
        let _guard = init_subscriber();

        let flux_capacitor = FluxCapacitor::new(now, Timestamp::UNIX_EPOCH);
        let mut generator = TunnelGenerator::new(data);
        let domain_tree = generator.domain_tree();
        let mut portal = generator.portal(&domain_tree);
        let mut model = generator.model(&portal, domain_tree);
        let mut feedback_recorder = feedback::Recorder::default();

        let mut tunnel = RealTunnelSystem::init_test(&model, &mut portal, flux_capacitor.clone());
        check_invariants(&model, &tunnel, &portal);

        for applied in 0..MAX_TRANSITIONS {
            if generator.is_empty() {
                break;
            }

            let transition = generator.transition(&model, &portal, flux_capacitor.now());

            tracing::debug!("Applying transition {applied}: {transition:?}");
            feedback_recorder.observe(&transition, &model, flux_capacitor.now());

            model.invalidate(&transition, &portal);
            tunnel.invalidate(&model);

            portal.apply(&transition, &model);
            model = model.apply(&transition, &portal, flux_capacitor.now());
            tunnel = tunnel.apply(transition, &model, &mut portal);
            check_invariants(&model, &tunnel, &portal);
            feedback_recorder.record(&model, &tunnel, &portal);
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
            .with(PanicOnErrorEvents::new())
            .with(log_layer)
            .set_default()
    }
}
