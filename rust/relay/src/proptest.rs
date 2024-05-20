use crate::Binding;
use crate::ChannelData;
use crate::IpStack;
use proptest::arbitrary::any;
use proptest::strategy::Just;
use proptest::strategy::Strategy;
use proptest::string::string_regex;
use std::net::Ipv4Addr;
use std::net::Ipv6Addr;
use std::time::Duration;
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
    (ChannelNumber::MIN..=ChannelNumber::MAX).prop_map(|n| ChannelNumber::new(n).unwrap())
}

pub fn channel_payload() -> impl Strategy<Value = (Vec<u8>, u16)> {
    any::<Vec<u8>>()
        .prop_filter("payload does not fit into u16", |vec| {
            vec.len() <= u16::MAX as usize
        })
        .prop_map(|vec| {
            let len = vec.len();

            (vec, len as u16)
        })
}

pub fn channel_data() -> impl Strategy<Value = ChannelData<'static>> {
    let buffer = any::<Vec<u8>>()
        .prop_filter("buffer must be at least 4 bytes", |v| v.len() >= 4)
        .prop_filter("payload does not fit into u16", |vec| {
            vec.len() <= u16::MAX as usize
        });

    (buffer, channel_number()).prop_map(|(payload, number)| {
        let payload = payload.leak(); // This is okay because we only do this for testing.

        ChannelData::encode_header_to_slice(number, (payload.len() - 4) as u16, &mut payload[..4]);

        ChannelData::parse(payload).unwrap()
    })
}

pub fn username_salt() -> impl Strategy<Value = String> {
    string_regex("[a-zA-Z0-9]{10}").unwrap()
}

pub fn nonce() -> impl Strategy<Value = Uuid> {
    any::<u128>().prop_map(Uuid::from_u128)
}

pub fn any_ip_stack() -> impl Strategy<Value = IpStack> {
    (dual_ip_stack(), any::<u8>()).prop_map(|(ip_stack, mode)| match mode % 3 {
        0 => IpStack::Ip4(*ip_stack.as_v4().unwrap()),
        1 => IpStack::Ip6(*ip_stack.as_v6().unwrap()),
        2 => ip_stack,
        _ => unreachable!(),
    })
}

pub fn dual_ip_stack() -> impl Strategy<Value = IpStack> {
    (
        any::<Ipv4Addr>().prop_filter("must be normal ip", |ip| {
            !ip.is_broadcast()
                && !ip.is_unspecified()
                && !ip.is_documentation()
                && !ip.is_link_local()
                && !ip.is_multicast()
        }),
        any::<Ipv6Addr>().prop_filter("must be normal ip", |ip| {
            !ip.is_unspecified() && !ip.is_multicast()
        }),
    )
        .prop_map(|(ip4, ip6)| IpStack::Dual { ip4, ip6 })
}
