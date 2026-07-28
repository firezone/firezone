use anyhow::{Result, bail};
use ip_packet::{Icmpv4Type, Icmpv6Type, IpPacket};
use std::{collections::BTreeMap, net::IpAddr};

#[derive(Debug, Clone)]
pub(crate) struct IcmpErrorHosts {
    inner: BTreeMap<IpAddr, IcmpError>,
}

impl IcmpErrorHosts {
    /// Builds from a precomputed IP-to-error map.
    pub(crate) fn from_entries(inner: BTreeMap<IpAddr, IcmpError>) -> Self {
        Self { inner }
    }

    pub(crate) fn icmp_error_for_ip(&self, ip: IpAddr) -> Option<IcmpError> {
        self.inner.get(&ip).copied()
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum IcmpError {
    Network,
    Host,
    Port,
    PacketTooBig { mtu: u32 },
    TimeExceeded { code: u8 },
}

pub(crate) fn icmp_error_reply(packet: &IpPacket, error: IcmpError) -> Result<IpPacket> {
    use ip_packet::{icmpv4, icmpv6};

    let src = packet.destination();
    let dst = packet.source();
    let payload = packet.packet();

    let reply = match (src, dst) {
        (IpAddr::V4(src), IpAddr::V4(dst)) => {
            let icmp_type = match error {
                IcmpError::Network => {
                    Icmpv4Type::DestinationUnreachable(icmpv4::DestUnreachableHeader::Network)
                }
                IcmpError::Host => {
                    Icmpv4Type::DestinationUnreachable(icmpv4::DestUnreachableHeader::Host)
                }
                IcmpError::Port => {
                    Icmpv4Type::DestinationUnreachable(icmpv4::DestUnreachableHeader::Port)
                }
                IcmpError::PacketTooBig { mtu } => Icmpv4Type::DestinationUnreachable(
                    icmpv4::DestUnreachableHeader::FragmentationNeeded {
                        next_hop_mtu: u16::try_from(mtu).unwrap_or(u16::MAX),
                    },
                ),
                IcmpError::TimeExceeded { code } => {
                    Icmpv4Type::TimeExceeded(icmpv4::TimeExceededCode(code))
                }
            };

            ip_packet::make::icmpv4_packet(src, dst, 20, icmp_type, payload)?
        }
        (IpAddr::V6(src), IpAddr::V6(dst)) => {
            let icmp_type = match error {
                IcmpError::Network => {
                    Icmpv6Type::DestinationUnreachable(icmpv6::DestUnreachableCode::NoRoute)
                }
                IcmpError::Host => {
                    Icmpv6Type::DestinationUnreachable(icmpv6::DestUnreachableCode::NoRoute)
                }
                IcmpError::Port => {
                    Icmpv6Type::DestinationUnreachable(icmpv6::DestUnreachableCode::Port)
                }
                IcmpError::PacketTooBig { mtu } => Icmpv6Type::PacketTooBig { mtu },
                IcmpError::TimeExceeded { code } => {
                    Icmpv6Type::TimeExceeded(icmpv6::TimeExceededCode(code))
                }
            };

            ip_packet::make::icmpv6_packet(src, dst, 20, icmp_type, payload)?
        }
        (IpAddr::V6(_), IpAddr::V4(_)) => bail!("Invalid IP combination"),
        (IpAddr::V4(_), IpAddr::V6(_)) => bail!("Invalid IP combination"),
    };

    Ok(reply)
}
