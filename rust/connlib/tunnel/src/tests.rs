use crate::{ClientState, GatewayState};
use connlib_shared::StaticSecret;
use proptest::{arbitrary::any, strategy::Strategy, test_runner::Config};
use proptest_state_machine::{ReferenceStateMachine, StateMachineTest};

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
        state: Self::SystemUnderTest,
        ref_state: &<Self::Reference as ReferenceStateMachine>::State,
        transition: <Self::Reference as ReferenceStateMachine>::Transition,
    ) -> Self::SystemUnderTest {
        state
    }
}

#[derive(Clone, Debug)]
struct RefState {
    client_priv_key: [u8; 32],
    gateway_priv_key: [u8; 32],
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
            })
            .boxed()
    }

    fn transitions(state: &Self::State) -> proptest::prelude::BoxedStrategy<Self::Transition> {
        todo!()
    }

    fn apply(state: Self::State, transition: &Self::Transition) -> Self::State {
        state
    }
}

/// The possible transitions of the state machine.
#[derive(Clone, Debug)]
enum Transition {}
