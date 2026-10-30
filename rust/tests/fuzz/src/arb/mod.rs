//! Structured, state-aware input generation for the tunnel fuzzer.
//!
//! One [`arbitrary::Unstructured`] is consumed positionally, so mutations stay
//! local and truncated inputs still produce minimal valid scenarios. Stateful
//! allocators make IDs, socket addresses, keys, and packet identities unique by
//! construction; transition preconditions are encoded by the transition
//! generator rather than checked after generation.

use std::time::Instant;

use dns_types::DomainName;

use crate::reference::ReferenceState;
use crate::stub_portal::StubPortal;
use crate::transition::Transition;

mod context;
mod dns_queries;
mod packets;
mod topology;
mod transitions;
mod values;

pub use context::Generator;

impl Generator<'_> {
    pub fn domain_tree(&mut self) -> Vec<DomainName> {
        values::arb_domain_tree(self)
    }

    pub fn portal(&mut self, domain_tree: &[DomainName]) -> StubPortal {
        topology::arb_stub_portal(self, domain_tree)
    }

    pub fn reference_state(
        &mut self,
        portal: &StubPortal,
        domain_tree: Vec<DomainName>,
    ) -> ReferenceState {
        topology::generate(self, portal, domain_tree)
    }

    pub fn transition(
        &mut self,
        state: &ReferenceState,
        portal: &StubPortal,
        now: Instant,
    ) -> Transition {
        transitions::generate(self, state, portal, now)
    }
}
