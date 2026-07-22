use std::{
    fmt,
    net::{IpAddr, Ipv4Addr, Ipv6Addr},
};

use anyhow::{Context as _, Result, bail};
use ingot::icmp::{IcmpV4Ref, IcmpV6Ref, ValidIcmpV4, ValidIcmpV6};
use ingot::ip::{IpProtocol, Ipv4Ref, Ipv6Ref, ValidIpv4, ValidIpv6};
use ingot::types::{HeaderParse as _, NextLayer as _};

use crate::icmp::{Icmpv4Type, Icmpv6Type, icmpv4, icmpv6};
use crate::{IpPacket, Layer4Protocol, Protocol};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum IcmpError {
    V4Unreachable(icmpv4::DestUnreachableHeader),
    V4TimeExceeded(icmpv4::TimeExceededCode),
    V6Unreachable(icmpv6::DestUnreachableCode),
    V6PacketTooBig { mtu: u32 },
    V6TimeExceeded(icmpv6::TimeExceededCode),
}

impl IcmpError {
    pub fn into_icmp_v4_type(self) -> Result<Icmpv4Type> {
        let icmpv4_type = match self {
            IcmpError::V4Unreachable(header) => Icmpv4Type::DestinationUnreachable(header),
            IcmpError::V4TimeExceeded(code) => Icmpv4Type::TimeExceeded(code),
            IcmpError::V6Unreachable(_) => {
                bail!("Cannot translate IPv6 unreachable to ICMPv4")
            }
            IcmpError::V6PacketTooBig { .. } => {
                bail!("Cannot translate IPv6 packet too big to ICMPv4")
            }
            IcmpError::V6TimeExceeded { .. } => {
                bail!("Cannot translate IPv6 packet time exceeded to ICMPv4")
            }
        };

        Ok(icmpv4_type)
    }

    pub fn into_icmp_v6_type(self) -> Result<Icmpv6Type> {
        match self {
            IcmpError::V4Unreachable { .. } => {
                bail!("Cannot translate IPv4 unreachable to ICMPv6")
            }
            IcmpError::V4TimeExceeded { .. } => {
                bail!("Cannot translate IPv4 time exceeded to ICMPv6")
            }
            IcmpError::V6Unreachable(code) => Ok(Icmpv6Type::DestinationUnreachable(code)),
            IcmpError::V6PacketTooBig { mtu } => Ok(Icmpv6Type::PacketTooBig { mtu }),
            IcmpError::V6TimeExceeded(code) => Ok(Icmpv6Type::TimeExceeded(code)),
        }
    }

    pub fn is_unreachable_prohibited(&self) -> bool {
        use IcmpError::*;
        use icmpv4::DestUnreachableHeader::*;
        use icmpv6::DestUnreachableCode::*;

        matches!(
            self,
            V4Unreachable(FilterProhibited) | V6Unreachable(Prohibited)
        )
    }

    pub fn is_unreachable_network(&self) -> bool {
        use IcmpError::*;
        use icmpv4::DestUnreachableHeader::*;
        use icmpv6::DestUnreachableCode::*;

        matches!(self, V4Unreachable(Network) | V6Unreachable(Address))
    }
}

impl fmt::Display for IcmpError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            IcmpError::V4Unreachable(inner) => {
                write!(f, "Destination is unreachable (code: {})", inner.code_u8())
            }
            IcmpError::V4TimeExceeded(inner) => {
                write!(f, "Time exceeded (code: {})", inner.code_u8())
            }
            IcmpError::V6Unreachable(inner) => {
                write!(f, "Destination is unreachable (code: {})", inner.code_u8())
            }
            IcmpError::V6PacketTooBig { mtu } => {
                write!(f, "IPv6 packet exceeds allowed MTU ({mtu})")
            }
            IcmpError::V6TimeExceeded(inner) => {
                write!(f, "Time exceeded (code: {})", inner.code_u8())
            }
        }
    }
}

/// In case the packet is an ICMP error with a failed packet, parses the failed packet from the ICMP payload.
pub(crate) fn parse_icmp_error(packet: &IpPacket) -> Result<Option<(FailedPacket, IcmpError)>> {
    if let Some(icmp) = packet.as_icmpv4() {
        let icmp_type = icmp.icmp_type();

        // Handle success case early to avoid erroring below.
        if matches!(
            icmp_type,
            Icmpv4Type::EchoReply(_) | Icmpv4Type::EchoRequest(_)
        ) {
            return Ok(None);
        }

        #[expect(
            clippy::wildcard_enum_match_arm,
            reason = "We only want to match on these variants"
        )]
        let icmp_error = match icmp_type {
            Icmpv4Type::DestinationUnreachable(error) => IcmpError::V4Unreachable(error),
            Icmpv4Type::TimeExceeded(code) => IcmpError::V4TimeExceeded(code),
            other => bail!("ICMP message {other:?} is not supported"),
        };

        // The ICMP payload contains (a portion of) the packet that failed to route,
        // which may be truncated: only the headers are required to be complete.
        let (header, _, l4) = ValidIpv4::parse(icmp.payload())
            .ok()
            .context("Failed to parse payload of ICMPv4 error message as IPv4 packet")?;

        let src = IpAddr::V4(header.source().into());
        let failed_dst = IpAddr::V4(header.destination().into());
        let l4_proto =
            extract_l4_proto(l4, header.protocol()).context("Failed to extract protocol")?;

        return Ok(Some((
            FailedPacket {
                src,
                failed_dst,
                l4_proto,
                raw: icmp.payload().to_vec(),
            },
            icmp_error,
        )));
    }

    if let Some(icmp) = packet.as_icmpv6() {
        let icmp_type = icmp.icmp_type();

        // Handle success case early to avoid erroring below.
        if matches!(
            icmp_type,
            Icmpv6Type::EchoReply(_) | Icmpv6Type::EchoRequest(_)
        ) {
            return Ok(None);
        }

        #[expect(
            clippy::wildcard_enum_match_arm,
            reason = "We only want to match on these variants"
        )]
        let icmp_error = match icmp_type {
            Icmpv6Type::DestinationUnreachable(error) => IcmpError::V6Unreachable(error),
            Icmpv6Type::PacketTooBig { mtu } => IcmpError::V6PacketTooBig { mtu },
            Icmpv6Type::TimeExceeded(code) => IcmpError::V6TimeExceeded(code),
            other => bail!("ICMPv6 message {other:?} is not supported"),
        };

        // The ICMPv6 payload contains (a portion of) the packet that failed to route,
        // which may be truncated: only the headers are required to be complete.
        let (header, _, l4) = ValidIpv6::parse(icmp.payload())
            .ok()
            .context("Failed to parse payload of ICMPv6 error message as IPv6 packet")?;

        let src = IpAddr::V6(header.source().into());
        let failed_dst = IpAddr::V6(header.destination().into());
        let protocol = header
            .next_layer()
            .context("Failed to determine transport protocol of failed packet")?;
        let l4_proto = extract_l4_proto(l4, protocol).context("Failed to extract protocol")?;

        return Ok(Some((
            FailedPacket {
                src,
                failed_dst,
                l4_proto,
                raw: icmp.payload().to_vec(),
            },
            icmp_error,
        )));
    }

    Ok(None)
}

fn extract_l4_proto(payload: &[u8], protocol: IpProtocol) -> Result<Layer4Protocol> {
    // ICMP messages SHOULD always contain at least 8 bytes of the original L4 payload.
    let (src_port, remaining) = payload
        .split_first_chunk::<2>()
        .context("Payload is not long enough for src port")?;
    let (dst_port, _) = remaining
        .split_first_chunk::<2>()
        .context("Payload is not long enough for dst port")?;

    let proto = match protocol {
        IpProtocol::UDP => Layer4Protocol::Udp {
            src: u16::from_be_bytes(*src_port),
            dst: u16::from_be_bytes(*dst_port),
        },
        IpProtocol::TCP => Layer4Protocol::Tcp {
            src: u16::from_be_bytes(*src_port),
            dst: u16::from_be_bytes(*dst_port),
        },
        IpProtocol::ICMP => {
            let (header, _, _) = ValidIcmpV4::parse(payload)
                .ok()
                .context("Failed to parse payload as ICMPv4")?;
            let icmp_type =
                Icmpv4Type::from_wire(header.ty().0, header.code(), header.rest_of_hdr());

            let Icmpv4Type::EchoRequest(echo_header) = icmp_type else {
                bail!("Original packet was not any ICMP echo request but {icmp_type:?}")
            };

            Layer4Protocol::Icmp {
                seq: echo_header.seq,
                id: echo_header.id,
            }
        }
        IpProtocol::ICMP_V6 => {
            let (header, _, _) = ValidIcmpV6::parse(payload)
                .ok()
                .context("Failed to parse payload as ICMPv6")?;
            let icmp_type =
                Icmpv6Type::from_wire(header.ty().0, header.code(), header.rest_of_hdr());

            let Icmpv6Type::EchoRequest(echo_header) = icmp_type else {
                bail!("Original packet was not any ICMP echo request but {icmp_type:?}")
            };

            Layer4Protocol::Icmp {
                seq: echo_header.seq,
                id: echo_header.id,
            }
        }
        other => {
            bail!(
                "Unsupported protocol: {}",
                crate::ip_protocol_name(other).unwrap_or("unknown")
            )
        }
    };
    Ok(proto)
}

/// A packet that failed to route to its destination, extracted from the payload of an ICMP/ICMP6 error message.
#[derive(Debug, PartialEq, Eq)]
pub struct FailedPacket {
    pub(crate) src: IpAddr,
    pub(crate) failed_dst: IpAddr,
    pub(crate) l4_proto: Layer4Protocol,

    pub(crate) raw: Vec<u8>,
}

impl FailedPacket {
    /// The destination we failed to route to.
    pub fn dst(&self) -> IpAddr {
        self.failed_dst
    }

    pub fn src(&self) -> IpAddr {
        self.src
    }

    /// The source protocol of the packet.
    pub fn src_proto(&self) -> Protocol {
        match self.l4_proto {
            Layer4Protocol::Udp { src, .. } => Protocol::Udp(src),
            Layer4Protocol::Tcp { src, .. } => Protocol::Tcp(src),
            Layer4Protocol::Icmp { id, .. } => Protocol::IcmpEcho(id),
        }
    }

    /// The destination protocol of the packet.
    pub fn dst_proto(&self) -> Protocol {
        match self.l4_proto {
            Layer4Protocol::Udp { dst, .. } => Protocol::Udp(dst),
            Layer4Protocol::Tcp { dst, .. } => Protocol::Tcp(dst),
            Layer4Protocol::Icmp { id, .. } => Protocol::IcmpEcho(id),
        }
    }

    pub fn layer4_protocol(&self) -> Layer4Protocol {
        self.l4_proto
    }

    /// Translates the failed packet to point to the new `destination` address and originating from the given `src_proto`.
    pub fn translate_destination(self, dst: IpAddr, src_proto: Protocol) -> Result<Vec<u8>> {
        match (self.failed_dst, dst) {
            (IpAddr::V4(_), IpAddr::V4(dst)) => {
                translate_original_ipv4_packet(self.raw, dst, src_proto)
            }
            (IpAddr::V6(_), IpAddr::V6(dst)) => {
                translate_original_ipv6_packet(self.raw, dst, src_proto)
            }
            (IpAddr::V6(_), IpAddr::V4(_)) => bail!("Cannot translate from IPv6 to IPv4"),
            (IpAddr::V4(_), IpAddr::V6(_)) => bail!("Cannot translate from IPv4 to IPv6"),
        }
    }
}

/// Translates the original packet embedded in an ICMP error message to account for the NAT table.
///
/// The ICMP error was generated by a network device on the path between Gateway and Resource.
/// Hence, it contains the actual destination IP of the resource and the source port assigned in the NAT table.
///
/// The client doesn't know about this, meaning we need to translate the destination IP and source port to those on the "inside" of the NAT table.
fn translate_original_ipv4_packet(
    mut original_packet: Vec<u8>,
    inside_dst: Ipv4Addr,
    inside_proto: Protocol,
) -> Result<Vec<u8>> {
    // `original_packet` is an IPv4 packet, thus the destination IP is found from byte 16..20 in the header.
    original_packet[16..20].copy_from_slice(&inside_dst.octets());

    let (header, _, _) = ValidIpv4::parse(original_packet.as_slice())
        .ok()
        .context("Failed to parse original packet as IPv4")?;

    debug_assert_eq!(
        Ipv4Addr::from(header.destination()),
        inside_dst,
        "Should have modified the destination address correctly"
    );

    let payload_start = 4 * header.ihl() as usize;

    translate_original_packet_protocol(&mut original_packet, payload_start, inside_proto);

    Ok(original_packet)
}

/// Translates the original packet embedded in an ICMPv6 error message to account for the NAT table.
///
/// The ICMP error was generated by a network device on the path between Gateway and Resource.
/// Hence, it contains the actual destination IP of the resource and the source port assigned in the NAT table.
///
/// The client doesn't know about this, meaning we need to translate the destination IP and source port to those on the "inside" of the NAT table.
fn translate_original_ipv6_packet(
    mut original_packet: Vec<u8>,
    inside_dst: Ipv6Addr,
    inside_proto: Protocol,
) -> Result<Vec<u8>> {
    // `original_packet` is an IPv6 packet, thus the destination IP is found from byte 24..40 in the header.
    original_packet[24..40].copy_from_slice(&inside_dst.octets());

    let (header, _, _) = ValidIpv6::parse(original_packet.as_slice())
        .ok()
        .context("Failed to parse original packet as IPv6")?;

    debug_assert_eq!(
        Ipv6Addr::from(header.destination()),
        inside_dst,
        "Should have modified the destination address correctly"
    );

    let payload_start = ingot::types::HeaderLen::packet_length(&header);

    translate_original_packet_protocol(&mut original_packet, payload_start, inside_proto);

    Ok(original_packet)
}

fn translate_original_packet_protocol(
    original_packet: &mut [u8],
    payload_start: usize,
    inside_proto: Protocol,
) {
    let proto_offset = match inside_proto {
        Protocol::Tcp(_) => 0,      // source port is the first thing in a TCP packet.
        Protocol::Udp(_) => 0,      // source port is the first thing in a UDP packet.
        Protocol::IcmpEcho(_) => 4, // icmp identifier comes after type, code and checksum.
    };
    let proto_index = payload_start + proto_offset;

    original_packet[proto_index..(proto_index + 2)]
        .copy_from_slice(&inside_proto.value().to_be_bytes());
}
