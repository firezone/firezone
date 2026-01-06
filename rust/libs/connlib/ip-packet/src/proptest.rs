use crate::{IpPacket, make::TcpFlags};
use proptest::{arbitrary::any, prelude::Just, prop_oneof, strategy::Strategy};
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};

pub fn udp_packet() -> impl Strategy<Value = IpPacket> {
    prop_oneof![
        (ip4_tuple(), any::<u16>(), any::<u16>()).prop_map(|((saddr, daddr), sport, dport)| {
            crate::make::udp_packet(saddr, daddr, sport, dport, Vec::new()).unwrap()
        }),
        (ip6_tuple(), any::<u16>(), any::<u16>()).prop_map(|((saddr, daddr), sport, dport)| {
            crate::make::udp_packet(saddr, daddr, sport, dport, Vec::new()).unwrap()
        }),
    ]
}

pub fn tcp_packet(
    flags: impl Strategy<Value = TcpFlags> + Clone,
) -> impl Strategy<Value = IpPacket> {
    prop_oneof![
        (ip4_tuple(), any::<u16>(), any::<u16>(), flags.clone()).prop_map(
            |((saddr, daddr), sport, dport, flags)| {
                crate::make::tcp_packet(saddr, daddr, sport, dport, flags, Vec::new()).unwrap()
            }
        ),
        (ip6_tuple(), any::<u16>(), any::<u16>(), flags).prop_map(
            |((saddr, daddr), sport, dport, flags)| {
                crate::make::tcp_packet(saddr, daddr, sport, dport, flags, Vec::new()).unwrap()
            }
        ),
    ]
}

pub fn icmp_request_packet() -> impl Strategy<Value = IpPacket> {
    prop_oneof![
        (ip4_tuple(), any::<u16>(), any::<u16>()).prop_map(|((saddr, daddr), sport, dport)| {
            crate::make::icmp_request_packet(IpAddr::V4(saddr), daddr, sport, dport, &[]).unwrap()
        }),
        (ip6_tuple(), any::<u16>(), any::<u16>()).prop_map(|((saddr, daddr), sport, dport)| {
            crate::make::icmp_request_packet(IpAddr::V6(saddr), daddr, sport, dport, &[]).unwrap()
        }),
    ]
}

pub fn udp_or_tcp_or_icmp_packet() -> impl Strategy<Value = IpPacket> {
    prop_oneof![
        udp_packet(),
        tcp_packet(Just(TcpFlags::default())),
        icmp_request_packet()
    ]
}

fn ip4_tuple() -> impl Strategy<Value = (Ipv4Addr, Ipv4Addr)> {
    (any::<Ipv4Addr>(), any::<Ipv4Addr>())
}

fn ip6_tuple() -> impl Strategy<Value = (Ipv6Addr, Ipv6Addr)> {
    (any::<Ipv6Addr>(), any::<Ipv6Addr>())
}
