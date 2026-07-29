//! Typed views over the headers and payloads of an [`IpPacket`](crate::IpPacket).
//!
//! All of these types are constructed from byte ranges that were validated when
//! the packet was created, meaning constructing them is infallible and their
//! accessors don't need to perform any further checks.

use ingot::icmp::{IcmpV4Mut, IcmpV4Ref, IcmpV6Mut, IcmpV6Ref, ValidIcmpV4, ValidIcmpV6};
use ingot::ip::{Ipv4Ref, Ipv6Ref, ValidIpv4, ValidIpv6};
use ingot::tcp::{TcpFlags, TcpMut, TcpRef, ValidTcp};
use ingot::types::HeaderParse as _;
use ingot::udp::{UdpMut, UdpRef, ValidUdp};

use crate::icmp::{Icmpv4Type, Icmpv6Type};
use ingot::ip::IpProtocol;
use std::net::{Ipv4Addr, Ipv6Addr};

const INVARIANT: &str = "slice was validated when the packet was created";

/// A read-only view of the IPv4 header of a packet.
pub struct Ipv4HeaderSlice<'a> {
    header: ValidIpv4<&'a [u8]>,
    options: &'a [u8],
}

impl<'a> Ipv4HeaderSlice<'a> {
    pub(crate) fn from_packet(packet: &'a [u8]) -> Self {
        let (header, _, _) = ValidIpv4::parse(packet).expect(INVARIANT);
        let header_len = 4 * header.ihl() as usize;
        let options = &packet[Self::MIN_LEN..header_len];

        Self { header, options }
    }

    pub const MIN_LEN: usize = 20;
    pub const MAX_LEN: usize = 60;

    pub fn header_len(&self) -> usize {
        Self::MIN_LEN + self.options.len()
    }

    pub fn total_len(&self) -> u16 {
        self.header.total_len()
    }

    pub fn identification(&self) -> u16 {
        self.header.identification()
    }

    pub fn ttl(&self) -> u8 {
        self.header.hop_limit()
    }

    pub fn protocol(&self) -> IpProtocol {
        self.header.protocol()
    }

    pub fn checksum(&self) -> u16 {
        self.header.checksum()
    }

    pub fn source(&self) -> Ipv4Addr {
        self.header.source().into()
    }

    pub fn destination(&self) -> Ipv4Addr {
        self.header.destination().into()
    }

    pub fn options(&self) -> &'a [u8] {
        self.options
    }
}

/// A read-only view of the IPv6 header of a packet.
///
/// Extension headers are not part of this view;
/// [`next_header`](Self::next_header) is the protocol that follows them.
pub struct Ipv6HeaderSlice<'a> {
    header: ValidIpv6<&'a [u8]>,
    next_header: IpProtocol,
}

impl<'a> Ipv6HeaderSlice<'a> {
    pub(crate) fn from_packet(packet: &'a [u8], next_header: IpProtocol) -> Self {
        let (header, _, _) = ValidIpv6::parse(packet).expect(INVARIANT);

        Self {
            header,
            next_header,
        }
    }

    pub const LEN: usize = 40;

    pub fn payload_length(&self) -> u16 {
        self.header.payload_len()
    }

    /// The protocol of the transport layer, after any extension headers.
    pub fn next_header(&self) -> IpProtocol {
        self.next_header
    }

    pub fn hop_limit(&self) -> u8 {
        self.header.hop_limit()
    }

    pub fn source(&self) -> Ipv6Addr {
        self.header.source().into()
    }

    pub fn destination(&self) -> Ipv6Addr {
        self.header.destination().into()
    }
}

/// A read-only view of a UDP segment.
pub struct UdpSlice<'a> {
    header: ValidUdp<&'a [u8]>,
    payload: &'a [u8],
}

impl<'a> UdpSlice<'a> {
    pub const HEADER_LEN: usize = 8;

    pub(crate) fn from_l4(l4: &'a [u8]) -> Self {
        let (header, _, payload) = ValidUdp::parse(l4).expect(INVARIANT);

        Self { header, payload }
    }

    pub fn source_port(&self) -> u16 {
        self.header.source()
    }

    pub fn destination_port(&self) -> u16 {
        self.header.destination()
    }

    pub fn length(&self) -> u16 {
        self.header.length()
    }

    pub fn checksum(&self) -> u16 {
        self.header.checksum()
    }

    pub fn payload(&self) -> &'a [u8] {
        self.payload
    }
}

/// A mutable view of a UDP header.
pub struct UdpSliceMut<'a> {
    header: ValidUdp<&'a mut [u8]>,
}

impl<'a> UdpSliceMut<'a> {
    pub(crate) fn from_l4(l4: &'a mut [u8]) -> Self {
        let (header, _, _) = ValidUdp::parse(l4).expect(INVARIANT);

        Self { header }
    }

    pub fn get_source_port(&self) -> u16 {
        self.header.source()
    }

    pub fn get_destination_port(&self) -> u16 {
        self.header.destination()
    }

    pub fn get_checksum(&self) -> u16 {
        self.header.checksum()
    }

    pub fn set_source_port(&mut self, port: u16) {
        self.header.set_source(port);
    }

    pub fn set_destination_port(&mut self, port: u16) {
        self.header.set_destination(port);
    }

    pub fn set_checksum(&mut self, checksum: u16) {
        self.header.set_checksum(checksum);
    }
}

/// A read-only view of a TCP segment.
pub struct TcpSlice<'a> {
    header: ValidTcp<&'a [u8]>,
    options: &'a [u8],
    payload: &'a [u8],
}

impl<'a> TcpSlice<'a> {
    pub const HEADER_MIN_LEN: usize = 20;
    pub const HEADER_MAX_LEN: usize = 60;

    pub(crate) fn from_l4(l4: &'a [u8]) -> Self {
        let (header, _, payload) = ValidTcp::parse(l4).expect(INVARIANT);
        let header_len = 4 * header.data_offset() as usize;
        let options = &l4[Self::HEADER_MIN_LEN..header_len];

        Self {
            header,
            options,
            payload,
        }
    }

    pub fn source_port(&self) -> u16 {
        self.header.source()
    }

    pub fn destination_port(&self) -> u16 {
        self.header.destination()
    }

    pub fn sequence_number(&self) -> u32 {
        self.header.sequence()
    }

    pub fn acknowledgment_number(&self) -> u32 {
        self.header.acknowledgement()
    }

    pub fn header_len(&self) -> usize {
        Self::HEADER_MIN_LEN + self.options.len()
    }

    pub fn window_size(&self) -> u16 {
        self.header.window_size()
    }

    pub fn checksum(&self) -> u16 {
        self.header.checksum()
    }

    pub fn syn(&self) -> bool {
        self.header.flags().contains(TcpFlags::SYN)
    }

    pub fn ack(&self) -> bool {
        self.header.flags().contains(TcpFlags::ACK)
    }

    pub fn fin(&self) -> bool {
        self.header.flags().contains(TcpFlags::FIN)
    }

    pub fn rst(&self) -> bool {
        self.header.flags().contains(TcpFlags::RST)
    }

    pub fn psh(&self) -> bool {
        self.header.flags().contains(TcpFlags::PSH)
    }

    pub fn urg(&self) -> bool {
        self.header.flags().contains(TcpFlags::URG)
    }

    pub fn ece(&self) -> bool {
        self.header.flags().contains(TcpFlags::ECE)
    }

    pub fn cwr(&self) -> bool {
        self.header.flags().contains(TcpFlags::CWR)
    }

    /// The raw bytes of the TCP options.
    pub fn options(&self) -> &'a [u8] {
        self.options
    }

    pub fn payload(&self) -> &'a [u8] {
        self.payload
    }
}

/// A mutable view of a TCP header.
pub struct TcpSliceMut<'a> {
    header: ValidTcp<&'a mut [u8]>,
}

impl<'a> TcpSliceMut<'a> {
    pub(crate) fn from_l4(l4: &'a mut [u8]) -> Self {
        let (header, _, _) = ValidTcp::parse(l4).expect(INVARIANT);

        Self { header }
    }

    pub fn get_source_port(&self) -> u16 {
        self.header.source()
    }

    pub fn get_destination_port(&self) -> u16 {
        self.header.destination()
    }

    pub fn get_checksum(&self) -> u16 {
        self.header.checksum()
    }

    pub fn set_source_port(&mut self, port: u16) {
        self.header.set_source(port);
    }

    pub fn set_destination_port(&mut self, port: u16) {
        self.header.set_destination(port);
    }

    pub fn set_checksum(&mut self, checksum: u16) {
        self.header.set_checksum(checksum);
    }
}

/// A read-only view of an ICMP message.
pub struct Icmpv4Slice<'a> {
    header: ValidIcmpV4<&'a [u8]>,
    payload: &'a [u8],
}

impl<'a> Icmpv4Slice<'a> {
    pub const HEADER_LEN: usize = 8;

    pub(crate) fn from_l4(l4: &'a [u8]) -> Self {
        let (header, _, payload) = ValidIcmpV4::parse(l4).expect(INVARIANT);

        Self { header, payload }
    }

    pub fn icmp_type(&self) -> Icmpv4Type {
        Icmpv4Type::from_wire(
            self.header.ty().0,
            self.header.code(),
            self.header.rest_of_hdr(),
        )
    }

    pub fn checksum(&self) -> u16 {
        self.header.checksum()
    }

    /// The payload after the 8-byte ICMP header.
    pub fn payload(&self) -> &'a [u8] {
        self.payload
    }
}

/// A mutable view of an ICMP header.
pub struct Icmpv4SliceMut<'a> {
    header: ValidIcmpV4<&'a mut [u8]>,
}

impl<'a> Icmpv4SliceMut<'a> {
    pub(crate) fn from_l4(l4: &'a mut [u8]) -> Self {
        let (header, _, _) = ValidIcmpV4::parse(l4).expect(INVARIANT);

        Self { header }
    }

    pub fn is_echo_request_or_reply(&self) -> bool {
        let ty = self.header.ty();

        ty == ingot::icmp::IcmpV4Type::ECHO_REQUEST || ty == ingot::icmp::IcmpV4Type::ECHO_REPLY
    }

    pub fn get_checksum(&self) -> u16 {
        self.header.checksum()
    }

    pub fn get_identifier(&self) -> u16 {
        debug_assert!(
            self.is_echo_request_or_reply(),
            "ICMP identifier only exists for echo requests and replies"
        );

        let [id0, id1, _, _] = self.header.rest_of_hdr();

        u16::from_be_bytes([id0, id1])
    }

    pub fn set_checksum(&mut self, checksum: u16) {
        self.header.set_checksum(checksum);
    }

    pub fn set_identifier(&mut self, id: u16) {
        debug_assert!(
            self.is_echo_request_or_reply(),
            "ICMP identifier only exists for echo requests and replies"
        );

        let [_, _, seq0, seq1] = self.header.rest_of_hdr();
        let [id0, id1] = id.to_be_bytes();

        self.header.set_rest_of_hdr([id0, id1, seq0, seq1]);
    }
}

/// A read-only view of an ICMPv6 message.
pub struct Icmpv6Slice<'a> {
    header: ValidIcmpV6<&'a [u8]>,
    payload: &'a [u8],
}

impl<'a> Icmpv6Slice<'a> {
    pub const HEADER_LEN: usize = 8;

    pub(crate) fn from_l4(l4: &'a [u8]) -> Self {
        let (header, _, payload) = ValidIcmpV6::parse(l4).expect(INVARIANT);

        Self { header, payload }
    }

    pub fn icmp_type(&self) -> Icmpv6Type {
        Icmpv6Type::from_wire(
            self.header.ty().0,
            self.header.code(),
            self.header.rest_of_hdr(),
        )
    }

    pub fn checksum(&self) -> u16 {
        self.header.checksum()
    }

    /// The payload after the 8-byte ICMPv6 header.
    pub fn payload(&self) -> &'a [u8] {
        self.payload
    }
}

/// A mutable view of an ICMPv6 header.
pub struct Icmpv6SliceMut<'a> {
    header: ValidIcmpV6<&'a mut [u8]>,
}

impl<'a> Icmpv6SliceMut<'a> {
    pub(crate) fn from_l4(l4: &'a mut [u8]) -> Self {
        let (header, _, _) = ValidIcmpV6::parse(l4).expect(INVARIANT);

        Self { header }
    }

    pub fn is_echo_request_or_reply(&self) -> bool {
        let ty = self.header.ty();

        ty == ingot::icmp::IcmpV6Type::ECHO_REQUEST || ty == ingot::icmp::IcmpV6Type::ECHO_REPLY
    }

    pub fn get_checksum(&self) -> u16 {
        self.header.checksum()
    }

    pub fn get_identifier(&self) -> u16 {
        debug_assert!(
            self.is_echo_request_or_reply(),
            "ICMPv6 identifier only exists for echo requests and replies"
        );

        let [id0, id1, _, _] = self.header.rest_of_hdr();

        u16::from_be_bytes([id0, id1])
    }

    pub fn set_checksum(&mut self, checksum: u16) {
        self.header.set_checksum(checksum);
    }

    pub fn set_identifier(&mut self, id: u16) {
        debug_assert!(
            self.is_echo_request_or_reply(),
            "ICMPv6 identifier only exists for echo requests and replies"
        );

        let [_, _, seq0, seq1] = self.header.rest_of_hdr();
        let [id0, id1] = id.to_be_bytes();

        self.header.set_rest_of_hdr([id0, id1, seq0, seq1]);
    }
}
