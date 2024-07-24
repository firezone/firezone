use crate::tests::sut::TunnelTest;
use proptest::test_runner::Config;

mod assertions;
mod buffered_transmits;
mod composite_strategy;
mod flux_capacitor;
mod reference;
mod run_count_appender;
mod sim_client;
mod sim_gateway;
mod sim_net;
mod sim_relay;
mod strategies;
mod stub_portal;
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
    fn run_tunnel_test(sequential 1..10 => TunnelTest);
}
