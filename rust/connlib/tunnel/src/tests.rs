use crate::tests::sut::TunnelTest;
use proptest::test_runner::Config;

mod assertions;
mod reference;
mod sim_node;
mod sim_portal;
mod sim_relay;
mod strategies;
mod sut;
mod transition;

type QueryId = u16;
type IcmpSeq = u16;
type IcmpIdentifier = u16;

proptest_state_machine::prop_state_machine! {
    #![proptest_config(Config {
        cases: 1000,
        .. Config::default()
    })]

    #[test]
    fn run_tunnel_test(sequential 1..20 => TunnelTest);
}
