//! Simulates a relay client and a relay talking to each other over an unreliable network.

pub fn test(data: &[u8]) {
    let _guard = fuzz::tunnel_proto::init_fuzz_subscriber();

    fuzz::relay::test(data, *crate::START_TIME);
}
