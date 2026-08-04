//! A typed view over the transport layer of an [`IpPacket`](crate::IpPacket).
//!
//! [`Transport`] is the eager counterpart of the `as_` / `is_` accessors:
//! the packet was classified into exactly one of its variants on creation,
//! so matching on it handles every state a packet can be in, once.
//!
//! Like the other slice types of this crate, all views here are constructed
//! from byte ranges that were validated when the packet was created, meaning
//! construction is infallible and accessors don't re-validate.

use std::net::IpAddr;

use anyhow::{Result, bail};

use crate::icmp::{Icmpv4Type, Icmpv6Type};
use crate::icmp_error::{FailedPacket, IcmpError, icmpv4_error, icmpv6_error};
use crate::{IcmpEchoHeader, IcmpErrorMeta, IpVersion, Layer4Protocol, Protocol};
use ingot::ip::IpProtocol;

const INVARIANT: &str = "transport layer was validated when the packet was created";

/// The 8-byte header shared by all ICMP(v4/v6) messages.
const ICMP_HEADER_LEN: usize = 8;

/// The transport layer of an [`IpPacket`](crate::IpPacket).
pub enum Transport<'a> {
    Udp(crate::UdpSlice<'a>),
    Tcp(crate::TcpSlice<'a>),
    /// An ICMP(v6) echo request or reply.
    IcmpEcho(IcmpEchoSlice<'a>),
    /// A supported ICMP(v6) error message carrying a parseable original packet.
    IcmpError(IcmpErrorSlice<'a>),
    /// Any other ICMP(v6) message.
    ///
    /// This includes unsupported message types as well as supported error types
    /// whose payload we failed to parse as an IP packet.
    IcmpOther(IcmpOtherSlice<'a>),
    /// A transport protocol we don't parse, e.g. GRE or ESP.
    Other(OtherSlice<'a>),
}

impl<'a> Transport<'a> {
    /// The flow endpoints of this packet, if the transport layer has them.
    ///
    /// ICMP errors don't have their own flow; they belong to the (reversed) flow
    /// of the original packet, see [`IcmpErrorSlice::original`].
    pub fn layer4_protocol(&self) -> Option<Layer4Protocol> {
        match self {
            Transport::Udp(udp) => Some(Layer4Protocol::Udp {
                src: udp.source_port(),
                dst: udp.destination_port(),
            }),
            Transport::Tcp(tcp) => Some(Layer4Protocol::Tcp {
                src: tcp.source_port(),
                dst: tcp.destination_port(),
            }),
            Transport::IcmpEcho(echo) => Some(Layer4Protocol::Icmp {
                seq: echo.sequence(),
                id: echo.identifier(),
            }),
            Transport::IcmpError(_) | Transport::IcmpOther(_) | Transport::Other(_) => None,
        }
    }
}

/// A read-only view of an ICMP(v6) echo request or reply.
#[derive(Debug)]
pub struct IcmpEchoSlice<'a> {
    version: IpVersion,
    l4: &'a [u8],
}

impl<'a> IcmpEchoSlice<'a> {
    pub(crate) fn from_l4(l4: &'a [u8], version: IpVersion) -> Self {
        Self { version, l4 }
    }

    pub fn is_request(&self) -> bool {
        match self.version {
            IpVersion::V4 => self.l4[0] == ingot::icmp::IcmpV4Type::ECHO_REQUEST.0,
            IpVersion::V6 => self.l4[0] == ingot::icmp::IcmpV6Type::ECHO_REQUEST.0,
        }
    }

    pub fn header(&self) -> IcmpEchoHeader {
        let rest_of_header = self.l4[4..ICMP_HEADER_LEN].try_into().expect(INVARIANT);

        IcmpEchoHeader::from_bytes(rest_of_header)
    }

    pub fn identifier(&self) -> u16 {
        self.header().id
    }

    pub fn sequence(&self) -> u16 {
        self.header().seq
    }

    /// The payload after the 8-byte ICMP header.
    pub fn payload(&self) -> &'a [u8] {
        &self.l4[ICMP_HEADER_LEN..]
    }
}

/// A read-only view of a supported ICMP(v6) error message.
#[derive(Debug)]
pub struct IcmpErrorSlice<'a> {
    version: IpVersion,
    l4: &'a [u8],
    meta: IcmpErrorMeta,
}

impl<'a> IcmpErrorSlice<'a> {
    pub(crate) fn from_l4(l4: &'a [u8], version: IpVersion, meta: IcmpErrorMeta) -> Self {
        Self { version, l4, meta }
    }

    /// The kind of error this message represents.
    pub fn error(&self) -> IcmpError {
        let ty = self.l4[0];
        let code = self.l4[1];
        let rest_of_header = self.l4[4..ICMP_HEADER_LEN].try_into().expect(INVARIANT);

        match self.version {
            IpVersion::V4 => {
                icmpv4_error(Icmpv4Type::from_wire(ty, code, rest_of_header)).expect(INVARIANT)
            }
            IpVersion::V6 => {
                icmpv6_error(Icmpv6Type::from_wire(ty, code, rest_of_header)).expect(INVARIANT)
            }
        }
    }

    /// The original packet that failed to route, embedded in the error's payload.
    pub fn original(&self) -> OriginalPacketSlice<'a> {
        OriginalPacketSlice {
            version: self.version,
            bytes: &self.l4[ICMP_HEADER_LEN..],
            l4_proto: self.meta.original_l4,
            l4_offset: self.meta.original_l4_offset as usize,
        }
    }
}

/// A read-only view of the original packet embedded in an ICMP error message.
///
/// The packet may be truncated; only its IP header and the first bytes of its
/// transport header are guaranteed to be present.
#[derive(Debug)]
pub struct OriginalPacketSlice<'a> {
    version: IpVersion,
    bytes: &'a [u8],
    l4_proto: Layer4Protocol,
    l4_offset: usize,
}

impl<'a> OriginalPacketSlice<'a> {
    pub fn source(&self) -> IpAddr {
        match self.version {
            IpVersion::V4 => {
                let octets: [u8; 4] = self.bytes[12..16].try_into().expect(INVARIANT);

                IpAddr::from(octets)
            }
            IpVersion::V6 => {
                let octets: [u8; 16] = self.bytes[8..24].try_into().expect(INVARIANT);

                IpAddr::from(octets)
            }
        }
    }

    /// The destination the original packet failed to reach.
    pub fn destination(&self) -> IpAddr {
        match self.version {
            IpVersion::V4 => {
                let octets: [u8; 4] = self.bytes[16..20].try_into().expect(INVARIANT);

                IpAddr::from(octets)
            }
            IpVersion::V6 => {
                let octets: [u8; 16] = self.bytes[24..40].try_into().expect(INVARIANT);

                IpAddr::from(octets)
            }
        }
    }

    /// The flow endpoints of the original packet.
    pub fn layer4_protocol(&self) -> Layer4Protocol {
        self.l4_proto
    }

    pub fn source_protocol(&self) -> Protocol {
        self.l4_proto.source()
    }

    pub fn destination_protocol(&self) -> Protocol {
        self.l4_proto.destination()
    }

    /// The raw bytes of the original packet, including any ICMP extension structures.
    pub fn bytes(&self) -> &'a [u8] {
        self.bytes
    }

    /// Copies the original packet into an owned [`FailedPacket`].
    pub fn to_failed_packet(&self) -> FailedPacket {
        FailedPacket {
            src: self.source(),
            failed_dst: self.destination(),
            l4_proto: self.l4_proto,
            raw: self.bytes.to_vec(),
        }
    }

    /// Copies the original packet, translating it to point at `dst` and originate from `src_proto`.
    ///
    /// The ICMP error was generated by a network device between Gateway and Resource, so the
    /// embedded copy carries the actual destination IP of the resource and the source endpoint
    /// assigned in the NAT table. Translating those back to the values on the "inside" of the
    /// NAT table keeps the NAT transparent to the client.
    pub fn translate_destination(&self, dst: IpAddr, src_proto: Protocol) -> Result<Vec<u8>> {
        let mut bytes = self.bytes.to_vec();

        match (self.version, dst) {
            (IpVersion::V4, IpAddr::V4(dst)) => bytes[16..20].copy_from_slice(&dst.octets()),
            (IpVersion::V6, IpAddr::V6(dst)) => bytes[24..40].copy_from_slice(&dst.octets()),
            (IpVersion::V4, IpAddr::V6(_)) => bail!("Cannot translate from IPv4 to IPv6"),
            (IpVersion::V6, IpAddr::V4(_)) => bail!("Cannot translate from IPv6 to IPv4"),
        }

        let proto_offset = match src_proto {
            Protocol::Tcp(_) | Protocol::Udp(_) => 0, // The source port is the first field of TCP and UDP.
            Protocol::IcmpEcho(_) => 4, // The identifier comes after type, code and checksum.
        };
        let proto_index = self.l4_offset + proto_offset;

        bytes[proto_index..proto_index + 2].copy_from_slice(&src_proto.value().to_be_bytes());

        Ok(bytes)
    }
}

/// A read-only view of an ICMP(v6) message that is neither an echo nor a supported error.
#[derive(Debug)]
pub struct IcmpOtherSlice<'a> {
    version: IpVersion,
    l4: &'a [u8],
}

impl<'a> IcmpOtherSlice<'a> {
    pub(crate) fn from_l4(l4: &'a [u8], version: IpVersion) -> Self {
        Self { version, l4 }
    }

    pub fn ty(&self) -> u8 {
        self.l4[0]
    }

    pub fn code(&self) -> u8 {
        self.l4[1]
    }

    pub fn icmpv4_type(&self) -> Option<Icmpv4Type> {
        if !matches!(self.version, IpVersion::V4) {
            return None;
        }

        let rest_of_header = self.l4[4..ICMP_HEADER_LEN].try_into().expect(INVARIANT);

        Some(Icmpv4Type::from_wire(
            self.ty(),
            self.code(),
            rest_of_header,
        ))
    }

    pub fn icmpv6_type(&self) -> Option<Icmpv6Type> {
        if !matches!(self.version, IpVersion::V6) {
            return None;
        }

        let rest_of_header = self.l4[4..ICMP_HEADER_LEN].try_into().expect(INVARIANT);

        Some(Icmpv6Type::from_wire(
            self.ty(),
            self.code(),
            rest_of_header,
        ))
    }

    /// The payload after the 8-byte ICMP header.
    pub fn payload(&self) -> &'a [u8] {
        &self.l4[ICMP_HEADER_LEN..]
    }
}

/// A read-only view of the payload of a transport protocol we don't parse.
#[derive(Debug)]
pub struct OtherSlice<'a> {
    protocol: IpProtocol,
    payload: &'a [u8],
}

impl<'a> OtherSlice<'a> {
    pub(crate) fn from_l4(payload: &'a [u8], protocol: IpProtocol) -> Self {
        Self { protocol, payload }
    }

    pub fn protocol(&self) -> IpProtocol {
        self.protocol
    }

    pub fn payload(&self) -> &'a [u8] {
        self.payload
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{icmpv4, make};
    use std::net::{Ipv4Addr, Ipv6Addr};

    #[test]
    fn classifies_udp() {
        let packet =
            make::udp_packet(Ipv4Addr::LOCALHOST, Ipv4Addr::LOCALHOST, 10, 20, b"foo").unwrap();

        let Transport::Udp(udp) = packet.transport() else {
            panic!("Expected UDP transport");
        };

        assert_eq!(udp.source_port(), 10);
        assert_eq!(udp.destination_port(), 20);
        assert_eq!(
            packet.transport().layer4_protocol(),
            Some(Layer4Protocol::Udp { src: 10, dst: 20 })
        );
    }

    #[test]
    fn classifies_tcp() {
        let packet = make::tcp_packet(
            Ipv6Addr::LOCALHOST,
            Ipv6Addr::LOCALHOST,
            10,
            20,
            make::TcpFlags::default(),
            b"foo",
        )
        .unwrap();

        let Transport::Tcp(tcp) = packet.transport() else {
            panic!("Expected TCP transport");
        };

        assert_eq!(tcp.source_port(), 10);
        assert_eq!(tcp.destination_port(), 20);
    }

    #[test]
    fn classifies_icmp_echo() {
        let localhost_pairs: [(IpAddr, IpAddr); 2] = [
            (Ipv4Addr::LOCALHOST.into(), Ipv4Addr::LOCALHOST.into()),
            (Ipv6Addr::LOCALHOST.into(), Ipv6Addr::LOCALHOST.into()),
        ];

        for (src, dst) in localhost_pairs {
            let request = make::icmp_request_packet(src, dst, 5, 42, b"ping").unwrap();
            let reply = make::icmp_reply_packet(src, dst, 5, 42, b"ping").unwrap();

            let Transport::IcmpEcho(echo) = request.transport() else {
                panic!("Expected ICMP echo transport");
            };

            assert!(echo.is_request());
            assert_eq!(echo.identifier(), 42);
            assert_eq!(echo.sequence(), 5);
            assert_eq!(echo.payload(), b"ping");

            let Transport::IcmpEcho(echo) = reply.transport() else {
                panic!("Expected ICMP echo transport");
            };

            assert!(!echo.is_request());
        }
    }

    #[test]
    fn classifies_icmpv4_error_with_original_packet() {
        let original = make::udp_packet(
            Ipv4Addr::new(10, 0, 0, 1),
            Ipv4Addr::new(10, 0, 0, 2),
            10,
            20,
            b"",
        )
        .unwrap();
        let error = make::icmp_dest_unreachable_network(&original).unwrap();

        let Transport::IcmpError(error) = error.transport() else {
            panic!("Expected ICMP error transport");
        };

        assert!(error.error().is_unreachable_network());

        let embedded = error.original();

        assert_eq!(embedded.source(), IpAddr::from(Ipv4Addr::new(10, 0, 0, 1)));
        assert_eq!(
            embedded.destination(),
            IpAddr::from(Ipv4Addr::new(10, 0, 0, 2))
        );
        assert_eq!(
            embedded.layer4_protocol(),
            Layer4Protocol::Udp { src: 10, dst: 20 }
        );
    }

    #[test]
    fn classifies_icmpv6_error_with_original_packet() {
        let original = make::udp_packet(
            Ipv6Addr::new(0xfd, 0, 0, 0, 0, 0, 0, 1),
            Ipv6Addr::new(0xfd, 0, 0, 0, 0, 0, 0, 2),
            10,
            20,
            b"",
        )
        .unwrap();
        let error = make::icmp_dest_unreachable_prohibited(&original).unwrap();

        let Transport::IcmpError(error) = error.transport() else {
            panic!("Expected ICMP error transport");
        };

        assert!(error.error().is_unreachable_prohibited());
        assert_eq!(
            error.original().layer4_protocol(),
            Layer4Protocol::Udp { src: 10, dst: 20 }
        );
    }

    #[test]
    fn translated_original_packet_carries_new_destination_and_source() {
        let original = make::udp_packet(
            Ipv4Addr::new(10, 0, 0, 1),
            Ipv4Addr::new(10, 0, 0, 2),
            10,
            20,
            b"",
        )
        .unwrap();
        let error = make::icmp_dest_unreachable_network(&original).unwrap();

        let Transport::IcmpError(error) = error.transport() else {
            panic!("Expected ICMP error transport");
        };

        let translated = error
            .original()
            .translate_destination("100.96.0.1".parse().unwrap(), Protocol::Udp(999))
            .unwrap();

        assert_eq!(&translated[16..20], &[100, 96, 0, 1]);
        assert_eq!(&translated[20..22], &999_u16.to_be_bytes());
    }

    #[test]
    fn classifies_unsupported_icmp_message_as_other() {
        let timestamp_request = make::icmpv4_packet(
            Ipv4Addr::LOCALHOST,
            Ipv4Addr::LOCALHOST,
            64,
            Icmpv4Type::Unknown {
                ty: 13,
                code: 0,
                rest_of_header: [0u8; 4],
            },
            &[],
        )
        .unwrap();

        let Transport::IcmpOther(other) = timestamp_request.transport() else {
            panic!("Expected other ICMP transport");
        };

        assert_eq!(other.ty(), 13);
        assert!(timestamp_request.icmp_error().is_err());
    }

    #[test]
    fn classifies_error_with_unparseable_original_packet_as_other() {
        let error = make::icmpv4_packet(
            Ipv4Addr::LOCALHOST,
            Ipv4Addr::LOCALHOST,
            64,
            Icmpv4Type::DestinationUnreachable(icmpv4::DestUnreachableHeader::Host),
            &[0u8; 5], // Too short to be an IPv4 packet.
        )
        .unwrap();

        assert!(matches!(error.transport(), Transport::IcmpOther(_)));
        assert!(error.icmp_error().is_err());
    }

    #[test]
    fn classifies_error_with_truncated_original_transport_header_as_error() {
        let original = make::udp_packet(
            Ipv4Addr::new(10, 0, 0, 1),
            Ipv4Addr::new(10, 0, 0, 2),
            10,
            20,
            b"",
        )
        .unwrap();

        // ICMP errors quote the original IP header plus its first 8 bytes;
        // 4 bytes of transport header are enough to extract both ports.
        let truncated = &original.packet()[..original.packet().len() - 4];
        let error = make::icmpv4_packet(
            Ipv4Addr::LOCALHOST,
            Ipv4Addr::LOCALHOST,
            64,
            Icmpv4Type::DestinationUnreachable(icmpv4::DestUnreachableHeader::Host),
            truncated,
        )
        .unwrap();

        assert!(matches!(error.transport(), Transport::IcmpError(_)));
    }

    #[test]
    fn classifies_unparsed_protocol_as_other() {
        let packet = make::fz_p2p_control([0u8; 8], b"control").unwrap();

        let Transport::Other(other) = packet.transport() else {
            panic!("Expected other transport");
        };

        assert_eq!(other.protocol(), IpProtocol(0xFF));
    }

    #[test]
    fn icmp_error_shim_returns_failed_packet() {
        let original = make::udp_packet(
            Ipv4Addr::new(10, 0, 0, 1),
            Ipv4Addr::new(10, 0, 0, 2),
            10,
            20,
            b"",
        )
        .unwrap();
        let error = make::icmp_dest_unreachable_network(&original).unwrap();

        let (failed, kind) = error.icmp_error().unwrap().unwrap();

        assert_eq!(failed.src(), IpAddr::from(Ipv4Addr::new(10, 0, 0, 1)));
        assert_eq!(failed.dst(), IpAddr::from(Ipv4Addr::new(10, 0, 0, 2)));
        assert_eq!(failed.src_proto(), Protocol::Udp(10));
        assert_eq!(failed.dst_proto(), Protocol::Udp(20));
        assert!(kind.is_unreachable_network());
    }

    #[test]
    fn icmp_error_shim_returns_none_for_non_errors() {
        let udp = make::udp_packet(Ipv4Addr::LOCALHOST, Ipv4Addr::LOCALHOST, 10, 20, b"").unwrap();
        let echo = make::icmp_request_packet(
            IpAddr::from(Ipv4Addr::LOCALHOST),
            Ipv4Addr::LOCALHOST,
            5,
            42,
            b"",
        )
        .unwrap();

        assert!(udp.icmp_error().unwrap().is_none());
        assert!(echo.icmp_error().unwrap().is_none());
    }

    #[test]
    fn source_and_destination_protocol_follow_classification() {
        let unreachable = make::icmp_dest_unreachable_network(
            &make::udp_packet(Ipv4Addr::LOCALHOST, Ipv4Addr::LOCALHOST, 10, 20, b"").unwrap(),
        )
        .unwrap();

        assert!(matches!(
            unreachable.source_protocol(),
            Err(crate::UnsupportedProtocol::UnsupportedIcmpv4Type(
                Icmpv4Type::DestinationUnreachable(icmpv4::DestUnreachableHeader::Network)
            ))
        ));

        let echo = make::icmp_request_packet(
            IpAddr::from(Ipv6Addr::LOCALHOST),
            Ipv6Addr::LOCALHOST,
            5,
            42,
            b"",
        )
        .unwrap();

        assert_eq!(echo.source_protocol().unwrap(), Protocol::IcmpEcho(42));
        assert_eq!(echo.destination_protocol().unwrap(), Protocol::IcmpEcho(42));
    }
}
