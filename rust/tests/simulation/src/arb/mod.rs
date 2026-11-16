//! Structured, state-aware input generation for the tunnel fuzzer.
//!
//! One [`arbitrary::Unstructured`] is consumed positionally, so mutations stay
//! local and truncated inputs still produce minimal valid scenarios. Stateful
//! allocators make IDs, socket addresses, keys, and packet identities unique by
//! construction; transition preconditions are encoded by the transition
//! generator rather than checked after generation.

use std::time::Instant;

use dns_types::DomainName;

use crate::fake_portal::FakePortal;
use crate::tunnel_model::TunnelModel;
use crate::tunnel_transition::Transition;

mod context;
mod dns_queries;
mod packets;
mod queries;
mod topology;
mod transitions;
mod values;

pub use context::Generator;

impl Generator<'_> {
    pub fn domain_tree(&mut self) -> Vec<DomainName> {
        values::arb_domain_tree(self)
    }

    pub fn portal(&mut self, domain_tree: &[DomainName]) -> FakePortal {
        topology::arb_fake_portal(self, domain_tree)
    }

    pub fn model(&mut self, portal: &FakePortal, domain_tree: Vec<DomainName>) -> TunnelModel {
        topology::generate(self, portal, domain_tree)
    }

    pub fn transition(
        &mut self,
        state: &TunnelModel,
        portal: &FakePortal,
        now: Instant,
    ) -> Transition {
        transitions::generate(self, state, portal, now)
    }
}
