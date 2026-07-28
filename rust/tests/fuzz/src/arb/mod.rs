//! Structured, state-aware input generation for the tunnel fuzzer.
//!
//! One [`arbitrary::Unstructured`] is consumed positionally, so mutations stay
//! local and truncated inputs still produce minimal valid scenarios. Stateful
//! allocators make IDs, socket addresses, keys, and packet identities unique by
//! construction; transition preconditions are encoded by the transition
//! generator rather than checked after generation.

use std::time::Instant;

use crate::reference::ReferenceState;
use crate::transition::Transition;

mod context;
mod dns_queries;
mod packets;
mod topology;
mod transitions;
mod values;

pub use context::Generator;

impl Generator<'_> {
    pub fn initial_state(&mut self, start: Instant) -> ReferenceState {
        topology::generate(self, start)
    }

    pub fn transition(&mut self, state: &ReferenceState, now: Instant) -> Option<Transition> {
        transitions::generate(self, state, now)
    }
}
