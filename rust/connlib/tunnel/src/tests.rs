use crate::{ClientState, GatewayState};
use connlib_shared::{
    messages::{ResourceDescription, ResourceDescriptionCidr, ResourceId},
    StaticSecret,
};
use proptest::{arbitrary::any, prop_oneof, strategy::Strategy, test_runner::Config};
use proptest_state_machine::{ReferenceStateMachine, StateMachineTest};
use std::collections::HashMap;

// Setup the state machine test using the `prop_state_machine!` macro
proptest_state_machine::prop_state_machine! {
    #![proptest_config(Config {
        // Enable verbose mode to make the state machine test print the
        // transitions for each case.
        verbose: 1,
        .. Config::default()
    })]

    #[test]
    fn run_tunnel_test(sequential 1..20 => TunnelTest);
}

struct TunnelTest {
    client: ClientState,
    gateway: GatewayState,
}

impl StateMachineTest for TunnelTest {
    type SystemUnderTest = Self;
    type Reference = RefState;

    fn init_test(
        ref_state: &<Self::Reference as ReferenceStateMachine>::State,
    ) -> Self::SystemUnderTest {
        Self {
            client: ClientState::new(StaticSecret::from(ref_state.client_priv_key)),
            gateway: GatewayState::new(StaticSecret::from(ref_state.gateway_priv_key)),
        }
    }

    fn apply(
        mut state: Self::SystemUnderTest,
        ref_state: &<Self::Reference as ReferenceStateMachine>::State,
        transition: <Self::Reference as ReferenceStateMachine>::Transition,
    ) -> Self::SystemUnderTest {
        match transition {
            Transition::AddCidrResource(r) => {
                state.client.add_resources(&[ResourceDescription::Cidr(r)]);
            }
        };

        // TODO: Assert our routes here.

        state
    }
}

/// The reference state machine of the tunnel.
///
/// This is the "expected" part of our test.
/// i.e. We compare the actual state of the tunnel with what we have in here.
#[derive(Clone, Debug)]
struct RefState {
    client_priv_key: [u8; 32],
    gateway_priv_key: [u8; 32],

    resources: HashMap<ResourceId, ResourceDescriptionCidr>,
}

impl ReferenceStateMachine for RefState {
    type State = Self;
    type Transition = Transition;

    fn init_state() -> proptest::prelude::BoxedStrategy<Self::State> {
        (any::<[u8; 32]>(), any::<[u8; 32]>())
            .prop_filter("client and gateway priv key must be different", |(c, g)| {
                c != g
            })
            .prop_map(|(client_priv_key, gateway_priv_key)| Self {
                client_priv_key,
                gateway_priv_key,
                resources: HashMap::default(),
            })
            .boxed()
    }

    fn transitions(_: &Self::State) -> proptest::prelude::BoxedStrategy<Self::Transition> {
        prop_oneof![connlib_shared::proptest::cidr_resource().prop_map(Transition::AddCidrResource)]
            .boxed()
    }

    fn apply(mut state: Self::State, transition: &Self::Transition) -> Self::State {
        match transition {
            Transition::AddCidrResource(r) => state.resources.insert(r.id, r.clone()),
        };

        state
    }

    fn preconditions(_: &Self::State, _: &Self::Transition) -> bool {
        true
    }
}

/// The possible transitions of the state machine.
#[derive(Clone, Debug)]
enum Transition {
    AddCidrResource(ResourceDescriptionCidr),
}
