use crate::Binding;
use proptest::arbitrary::any;
use proptest::strategy::Just;
use proptest::strategy::Strategy;
use proptest::string::string_regex;
use std::ops::Add;
use std::time::{Duration, SystemTime};
use stun_codec::rfc5766::attributes::{ChannelNumber, Lifetime, RequestedTransport};
use stun_codec::TransactionId;
use uuid::Uuid;

pub fn transaction_id() -> impl Strategy<Value = TransactionId> {
    any::<[u8; 12]>().prop_map(TransactionId::new)
}

pub fn binding() -> impl Strategy<Value = Binding> {
    transaction_id().prop_map(Binding::new)
}

pub fn udp_requested_transport() -> impl Strategy<Value = RequestedTransport> {
    Just(RequestedTransport::new(17)) // 17 is udp.
}

pub fn allocation_lifetime() -> impl Strategy<Value = Lifetime> {
    (1..3600u64).prop_map(|seconds| Lifetime::new(Duration::new(seconds, 0)).unwrap())
}

pub fn channel_number() -> impl Strategy<Value = ChannelNumber> {
    (ChannelNumber::MIN..ChannelNumber::MAX).prop_map(|n| ChannelNumber::new(n).unwrap())
}

pub fn channel_payload() -> impl Strategy<Value = (Vec<u8>, usize)> {
    any::<Vec<u8>>().prop_map(|vec| {
        let len = vec.len();

        (vec, len)
    })
}

pub fn username_salt() -> impl Strategy<Value = String> {
    string_regex("[a-zA-Z0-9]{10}").unwrap()
}

pub fn nonce() -> impl Strategy<Value = Uuid> {
    any::<u128>().prop_map(Uuid::from_u128)
}

/// We let "now" begin somewhere around 2000 up until 2100.
pub fn now() -> impl Strategy<Value = SystemTime> {
    const YEAR: u64 = 60 * 60 * 24 * 365;

    (30 * YEAR..100 * YEAR)
        .prop_map(Duration::from_secs)
        .prop_map(|duration| SystemTime::UNIX_EPOCH.add(duration))
}
