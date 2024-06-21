pub mod make;

#[cfg(feature = "proptest")]
pub mod proptest;

pub use pnet_packet::*;

#[cfg(all(test, feature = "proptest"))]
mod proptests;

use pnet_packet::{
    icmp::{
        echo_reply::MutableEchoReplyPacket, echo_request::MutableEchoRequestPacket, IcmpTypes,
        MutableIcmpPacket,
    },
    icmpv6::{Icmpv6Type, Icmpv6Types, MutableIcmpv6Packet},
    ip::{IpNextHeaderProtocol, IpNextHeaderProtocols},
    ipv4::{Ipv4Flags, Ipv4Packet, MutableIpv4Packet},
    ipv6::{Ipv6Packet, MutableIpv6Packet},
    tcp::{MutableTcpPacket, TcpPacket},
    udp::{MutableUdpPacket, UdpPacket},
};
use std::{
    net::{IpAddr, Ipv4Addr, Ipv6Addr},
    ops::{Deref, DerefMut},
};

macro_rules! for_both {
    ($this:ident, |$name:ident| $body:expr) => {
        match $this {
            Self::Ipv4($name) => $body,
            Self::Ipv6($name) => $body,
        }
    };
}

// no std::mem::swap? no problem
macro_rules! swap_src_dst {
    ($p:expr) => {
        let src = $p.get_source();
        let dst = $p.get_destination();
        $p.set_source(dst);
        $p.set_destination(src);
    };
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Protocol {
    /// Contains either the source or destination port.
    Tcp(u16),
    /// Contains either the source or destination port.
    Udp(u16),
    /// Contains the `identifier` of the ICMP packet.
    Icmp(u16),
}

impl Protocol {
    pub fn same_type(&self, other: &Protocol) -> bool {
        matches!(
            (self, other),
            (Protocol::Tcp(_), Protocol::Tcp(_))
                | (Protocol::Udp(_), Protocol::Udp(_))
                | (Protocol::Icmp(_), Protocol::Icmp(_))
        )
    }

    pub fn value(&self) -> u16 {
        match self {
            Protocol::Tcp(v) => *v,
            Protocol::Udp(v) => *v,
            Protocol::Icmp(v) => *v,
        }
    }

    pub fn with_value(self, value: u16) -> Protocol {
        match self {
            Protocol::Tcp(_) => Protocol::Tcp(value),
            Protocol::Udp(_) => Protocol::Udp(value),
            Protocol::Icmp(_) => Protocol::Icmp(value),
        }
    }
}

#[derive(Debug, PartialEq)]
pub enum IpPacket<'a> {
    Ipv4(Ipv4Packet<'a>),
    Ipv6(Ipv6Packet<'a>),
}

#[derive(Debug, PartialEq)]
pub enum IcmpPacket<'a> {
    Ipv4(icmp::IcmpPacket<'a>),
    Ipv6(icmpv6::Icmpv6Packet<'a>),
}

impl<'a> IcmpPacket<'a> {
    pub fn identifier(&self) -> Option<u16> {
        let request_id = self.as_echo_request().map(|r| r.identifier());
        let reply_id = self.as_echo_reply().map(|r| r.identifier());

        request_id.or(reply_id)
    }

    pub fn sequence(&self) -> Option<u16> {
        let request_id = self.as_echo_request().map(|r| r.sequence());
        let reply_id = self.as_echo_reply().map(|r| r.sequence());

        request_id.or(reply_id)
    }
}

#[derive(Debug, PartialEq)]
pub enum IcmpEchoRequest<'a> {
    Ipv4(icmp::echo_request::EchoRequestPacket<'a>),
    Ipv6(icmpv6::echo_request::EchoRequestPacket<'a>),
}

#[derive(Debug, PartialEq)]
pub enum IcmpEchoReply<'a> {
    Ipv4(icmp::echo_reply::EchoReplyPacket<'a>),
    Ipv6(icmpv6::echo_reply::EchoReplyPacket<'a>),
}

#[derive(Debug, PartialEq, Clone)]
pub enum MutableIpPacket<'a> {
    Ipv4(ConvertibleIpv4Packet<'a>),
    Ipv6(ConvertibleIpv6Packet<'a>),
}

#[derive(Debug, PartialEq)]
enum MaybeOwned<'a> {
    RefMut(&'a mut [u8]),
    Owned(Vec<u8>),
}

impl<'a> MaybeOwned<'a> {
    fn remove_from_head(self, bytes: usize) -> MaybeOwned<'a> {
        match self {
            MaybeOwned::RefMut(ref_mut) => MaybeOwned::RefMut(&mut ref_mut[bytes..]),
            MaybeOwned::Owned(mut owned) => {
                owned.drain(0..bytes);
                MaybeOwned::Owned(owned)
            }
        }
    }
}

impl<'a> Clone for MaybeOwned<'a> {
    fn clone(&self) -> Self {
        match self {
            Self::RefMut(i) => Self::Owned(i.to_vec()),
            Self::Owned(i) => Self::Owned(i.clone()),
        }
    }
}

impl<'a> Deref for MaybeOwned<'a> {
    type Target = [u8];

    fn deref(&self) -> &Self::Target {
        match self {
            MaybeOwned::RefMut(ref_mut) => ref_mut,
            MaybeOwned::Owned(owned) => owned,
        }
    }
}

impl<'a> DerefMut for MaybeOwned<'a> {
    fn deref_mut(&mut self) -> &mut Self::Target {
        match self {
            MaybeOwned::RefMut(ref_mut) => ref_mut,
            MaybeOwned::Owned(owned) => owned,
        }
    }
}

#[derive(Debug, PartialEq, Clone)]
pub struct ConvertibleIpv4Packet<'a> {
    buf: MaybeOwned<'a>,
}

impl<'a> ConvertibleIpv4Packet<'a> {
    pub fn new(buf: &'a mut [u8]) -> Option<ConvertibleIpv4Packet<'a>> {
        MutableIpv4Packet::new(&mut buf[20..])?;
        Some(Self {
            buf: MaybeOwned::RefMut(buf),
        })
    }

    fn owned(mut buf: Vec<u8>) -> Option<ConvertibleIpv4Packet<'a>> {
        MutableIpv4Packet::new(&mut buf[20..])?;
        Some(Self {
            buf: MaybeOwned::Owned(buf),
        })
    }

    fn as_ipv4(&mut self) -> MutableIpv4Packet {
        MutableIpv4Packet::new(&mut self.buf[20..])
            .expect("when constructed we checked that this is some")
    }

    pub fn to_immutable(&self) -> Ipv4Packet {
        Ipv4Packet::new(&self.buf[20..]).expect("when constructed we checked that this is some")
    }

    pub fn get_source(&self) -> Ipv4Addr {
        self.to_immutable().get_source()
    }

    fn get_destination(&self) -> Ipv4Addr {
        self.to_immutable().get_destination()
    }

    fn set_source(&mut self, source: Ipv4Addr) {
        self.as_ipv4().set_source(source);
    }

    fn set_destination(&mut self, destination: Ipv4Addr) {
        self.as_ipv4().set_destination(destination);
    }

    fn set_checksum(&mut self, checksum: u16) {
        self.as_ipv4().set_checksum(checksum);
    }

    pub fn set_total_length(&mut self, total_length: u16) {
        self.as_ipv4().set_total_length(total_length);
    }

    pub fn set_header_length(&mut self, header_length: u8) {
        self.as_ipv4().set_header_length(header_length);
    }

    fn consume_to_immutable(self) -> Ipv4Packet<'a> {
        match self.buf {
            MaybeOwned::RefMut(buf) => {
                Ipv4Packet::new(&buf[20..]).expect("when constructed we checked that this is some")
            }
            MaybeOwned::Owned(mut owned) => {
                owned.drain(..20);
                Ipv4Packet::owned(owned).expect("when constructed we checked that this is some")
            }
        }
    }

    fn consume_to_ipv6(
        mut self,
        src: Ipv6Addr,
        dst: Ipv6Addr,
    ) -> Option<ConvertibleIpv6Packet<'a>> {
        // First we store the old values before modifying the old packet
        let dscp = self.as_ipv4().get_dscp();
        let total_length = self.as_ipv4().get_total_length();
        let header_length = self.header_length();
        let ttl = self.as_ipv4().get_ttl();
        let next_level_protocol = self.as_ipv4().get_next_level_protocol();

        let mut buf = self.buf.remove_from_head(header_length - 20);
        buf[0..40].fill(0);
        let mut pkt = ConvertibleIpv6Packet { buf };

        // TODO:
        /*
        If the DF flag is not set and the IPv4 packet will result in an IPv6
        packet larger than 1280 bytes, the packet SHOULD be fragmented so the
        resulting IPv6 packet (with Fragment Header added to each fragment)
        will be less than or equal to 1280 bytes.  For example, if the packet

        is fragmented prior to the translation, the IPv4 packets should be
        fragmented so that their length, excluding the IPv4 header, is at
        most 1232 bytes (1280 minus 40 for the IPv6 header and 8 for the
        Fragment Header).  The translator MAY provide a configuration
        function for the network administrator to adjust the threshold of the
        minimum IPv6 MTU to a value greater than 1280-byte if the real value
        of the minimum IPv6 MTU in the network is known to the administrator.
        The resulting fragments are then translated independently using the
        logic described below.

        If the DF bit is set and the MTU of the next-hop interface is less
        than the total length value of the IPv4 packet plus 20, the
        translator MUST send an ICMPv4 "Fragmentation Needed" error message
        to the IPv4 source address.

        If the DF bit is set and the packet is not a fragment (i.e., the More
        Fragments (MF) flag is not set and the Fragment Offset is equal to
        zero), then the translator SHOULD NOT add a Fragment Header to the
        resulting packet.
        */
        // Note the RFC has notes on how to set fragmentation fields.

        // Version:  6
        pkt.as_ipv6().set_version(6);

        // Traffic Class:  By default, copied from the IP Type Of Service (TOS)
        //    octet.  According to [RFC2474], the semantics of the bits are
        //    identical in IPv4 and IPv6.  However, in some IPv4 environments
        //    these fields might be used with the old semantics of "Type Of
        //    Service and Precedence".  An implementation of a translator SHOULD
        //    support an administratively configurable option to ignore the IPv4
        //    TOS and always set the IPv6 traffic class (TC) to zero.  In
        //    addition, if the translator is at an administrative boundary, the
        //    filtering and update considerations of [RFC2475] may be
        //    applicable.
        // Note: DSCP is the new name for TOS
        pkt.as_ipv6().set_traffic_class(dscp);

        // Flow Label:  0 (all zero bits)
        pkt.as_ipv6().set_flow_label(0);

        // Payload Length:  Total length value from the IPv4 header, minus the
        //    size of the IPv4 header and IPv4 options, if present.
        pkt.as_ipv6()
            .set_payload_length(total_length - (header_length as u16));

        // Next Header:  For ICMPv4 (1), it is changed to ICMPv6 (58);
        //    otherwise, the protocol field MUST be copied from the IPv4 header.
        let mut pkt = if next_level_protocol == IpNextHeaderProtocols::Icmp {
            let mut pkt = pkt.update_icmpv4_header_to_icmpv6()?;
            pkt.as_ipv6().set_next_header(IpNextHeaderProtocols::Icmpv6);
            pkt
        } else {
            pkt.as_ipv6().set_next_header(next_level_protocol);
            pkt
        };

        // Hop Limit:  The hop limit is derived from the TTL value in the IPv4
        //    header.  Since the translator is a router, as part of forwarding
        //    the packet it needs to decrement either the IPv4 TTL (before the
        //    translation) or the IPv6 Hop Limit (after the translation).  As
        //    part of decrementing the TTL or Hop Limit, the translator (as any
        //    router) MUST check for zero and send the ICMPv4 "TTL Exceeded" or
        //    ICMPv6 "Hop Limit Exceeded" error.
        // TODO: do we really need to act as a router?
        // reducing the ttl and having to send back a message makes things much harder
        pkt.as_ipv6().set_hop_limit(ttl);

        // Source Address:  The IPv4-converted address derived from the IPv4
        //    source address per [RFC6052], Section 2.3.
        // Note: Rust implements RFC4291 with to_ipv6_mapped but buf RFC6145
        // recommends the above. The advantage of using RFC6052 are explained in
        // section 4.2 of that RFC

        //    If the translator gets an illegal source address (e.g., 0.0.0.0,
        //    127.0.0.1, etc.), the translator SHOULD silently drop the packet
        //    (as discussed in Section 5.3.7 of [RFC1812]).
        // TODO: drop illegal source address? I don't think we need to do it
        pkt.set_source(src);

        // Destination Address:  In the stateless mode, which is to say that if
        //    the IPv4 destination address is within a range of configured IPv4
        //    stateless translation prefix, the IPv6 destination address is the
        //    IPv4-translatable address derived from the IPv4 destination
        //    address per [RFC6052], Section 2.3.  A workflow example of
        //    stateless translation is shown in Appendix A of this document.

        //    In the stateful mode (which is to say that if the IPv4 destination
        //    address is not within the range of any configured IPv4 stateless
        //    translation prefix), the IPv6 destination address and
        //    corresponding transport-layer destination port are derived from
        //    the Binding Information Bases (BIBs) reflecting current session
        //    state in the translator as described in [RFC6146].
        pkt.set_destination(dst);

        Some(pkt)
    }

    fn update_icmpv6_header_to_icmpv4(mut self) -> Option<ConvertibleIpv4Packet<'a>> {
        let Some(mut icmp) = MutableIcmpv6Packet::new(self.payload_mut()) else {
            return Some(self);
        };
        // ICMPv6 informational messages:

        match icmp.get_icmpv6_type() {
            //       Echo Request and Echo Reply (Type 128 and 129):  Adjust the Type
            //          values to 8 and 0, respectively, and adjust the ICMP checksum
            //          both to take the type change into account and to exclude the
            //          ICMPv6 pseudo-header.
            Icmpv6Types::EchoRequest => {
                icmp.set_icmpv6_type(Icmpv6Type(8));
            }
            Icmpv6Types::EchoReply => {
                icmp.set_icmpv6_type(Icmpv6Type(0));
            }
            //       MLD Multicast Listener Query/Report/Done (Type 130, 131, 132):
            //          Single-hop message.  Silently drop.
            //       Neighbor Discover messages (Type 133 through 137):  Single-hop
            //          message.  Silently drop.
            //       Unknown informational messages:  Silently drop.
            //    (TODO:)ICMPv6 error messages:
            _ => return None,
        }

        Some(self)
    }

    fn header_length(&self) -> usize {
        self.to_immutable().packet_size() - self.to_immutable().payload().len()
    }
}

impl<'a> Packet for ConvertibleIpv4Packet<'a> {
    fn packet(&self) -> &[u8] {
        &self.buf[20..]
    }

    fn payload(&self) -> &[u8] {
        &self.buf[(self.header_length() + 20)..]
    }
}

impl<'a> MutablePacket for ConvertibleIpv4Packet<'a> {
    fn packet_mut(&mut self) -> &mut [u8] {
        &mut self.buf[20..]
    }

    fn payload_mut(&mut self) -> &mut [u8] {
        let header_len = self.header_length();
        &mut self.buf[(header_len + 20)..]
    }
}

#[derive(Debug, PartialEq, Clone)]
pub struct ConvertibleIpv6Packet<'a> {
    buf: MaybeOwned<'a>,
}

impl<'a> ConvertibleIpv6Packet<'a> {
    pub fn new(buf: &'a mut [u8]) -> Option<ConvertibleIpv6Packet<'a>> {
        MutableIpv6Packet::new(buf)?;
        Some(Self {
            buf: MaybeOwned::RefMut(buf),
        })
    }

    fn owned(mut buf: Vec<u8>) -> Option<ConvertibleIpv6Packet<'a>> {
        MutableIpv6Packet::new(&mut buf)?;
        Some(Self {
            buf: MaybeOwned::Owned(buf),
        })
    }

    fn as_ipv6(&mut self) -> MutableIpv6Packet {
        MutableIpv6Packet::new(&mut self.buf)
            .expect("when constructed we checked that this is some")
    }

    fn to_immutable(&self) -> Ipv6Packet {
        Ipv6Packet::new(&self.buf).expect("when constructed we checked that this is some")
    }

    pub fn get_source(&self) -> Ipv6Addr {
        self.to_immutable().get_source()
    }

    fn get_destination(&self) -> Ipv6Addr {
        self.to_immutable().get_destination()
    }

    fn set_source(&mut self, source: Ipv6Addr) {
        self.as_ipv6().set_source(source);
    }

    fn set_destination(&mut self, destination: Ipv6Addr) {
        self.as_ipv6().set_destination(destination);
    }

    pub fn set_payload_length(&mut self, payload_length: u16) {
        self.as_ipv6().set_payload_length(payload_length);
    }

    fn consume_to_immutable(self) -> Ipv6Packet<'a> {
        match self.buf {
            MaybeOwned::RefMut(buf) => {
                Ipv6Packet::new(buf).expect("when constructed we checked that this is some")
            }
            MaybeOwned::Owned(owned) => {
                Ipv6Packet::owned(owned).expect("when constructed we checked that this is some")
            }
        }
    }

    fn consume_to_ipv4(
        mut self,
        src: Ipv4Addr,
        dst: Ipv4Addr,
    ) -> Option<ConvertibleIpv4Packet<'a>> {
        let traffic_class = self.as_ipv6().get_traffic_class();
        let payload_length = self.as_ipv6().get_payload_length();
        let hop_limit = self.as_ipv6().get_hop_limit();
        let next_header = self.as_ipv6().get_next_header();

        self.buf[..40].fill(0);
        let mut pkt = ConvertibleIpv4Packet { buf: self.buf };

        // TODO:
        // If there is no IPv6 Fragment Header, the IPv4 header fields are set
        // as follows:
        // Note the RFC has notes on how to set fragmentation fields.

        // Version:  4
        pkt.as_ipv4().set_version(4);

        // Internet Header Length:  5 (no IPv4 options)
        pkt.as_ipv4().set_header_length(5);

        // Type of Service (TOS) Octet:  By default, copied from the IPv6
        //    Traffic Class (all 8 bits).  According to [RFC2474], the semantics
        //    of the bits are identical in IPv4 and IPv6.  However, in some IPv4
        //    environments, these bits might be used with the old semantics of
        //    "Type Of Service and Precedence".  An implementation of a
        //    translator SHOULD provide the ability to ignore the IPv6 traffic
        //    class and always set the IPv4 TOS Octet to a specified value.  In
        //    addition, if the translator is at an administrative boundary, the
        //    filtering and update considerations of [RFC2475] may be
        //    applicable.
        pkt.as_ipv4().set_dscp(traffic_class);

        // Total Length:  Payload length value from the IPv6 header, plus the
        //    size of the IPv4 header.
        pkt.as_ipv4().set_total_length(payload_length + 20);

        // Identification:  All zero.  In order to avoid black holes caused by
        //    ICMPv4 filtering or non-[RFC2460]-compatible IPv6 hosts (a
        //    workaround is discussed in Section 6), the translator MAY provide
        //    a function to generate the identification value if the packet size
        //    is greater than 88 bytes and less than or equal to 1280 bytes.
        //    The translator SHOULD provide a method for operators to enable or
        //    disable this function.
        pkt.as_ipv4().set_identification(0);

        // Flags:  The More Fragments flag is set to zero.  The Don't Fragment
        //    (DF) flag is set to one.  In order to avoid black holes caused by
        //    ICMPv4 filtering or non-[RFC2460]-compatible IPv6 hosts (a
        //    workaround is discussed in Section 6), the translator MAY provide
        //    a function as follows.  If the packet size is greater than 88
        //    bytes and less than or equal to 1280 bytes, it sets the DF flag to
        //    zero; otherwise, it sets the DF flag to one.  The translator
        //    SHOULD provide a method for operators to enable or disable this
        //    function.
        pkt.as_ipv4()
            .set_flags(Ipv4Flags::DontFragment | !Ipv4Flags::MoreFragments);

        // Fragment Offset:  All zeros.
        pkt.as_ipv4().set_fragment_offset(0);

        // Time to Live:  Time to Live is derived from Hop Limit value in IPv6
        //    header.  Since the translator is a router, as part of forwarding
        //    the packet it needs to decrement either the IPv6 Hop Limit (before
        //    the translation) or the IPv4 TTL (after the translation).  As part
        //    of decrementing the TTL or Hop Limit the translator (as any
        //    router) MUST check for zero and send the ICMPv4 "TTL Exceeded" or
        //    ICMPv6 "Hop Limit Exceeded" error.
        // Same note as for the other translation
        pkt.as_ipv4().set_ttl(hop_limit);

        // Protocol:  The IPv6-Frag (44) header is handled as discussed in
        //    Section 5.1.1.  ICMPv6 (58) is changed to ICMPv4 (1), and the
        //    payload is translated as discussed in Section 5.2.  The IPv6
        //    headers HOPOPT (0), IPv6-Route (43), and IPv6-Opts (60) are
        //    skipped over during processing as they have no meaning in IPv4.
        //    For the first 'next header' that does not match one of the cases
        //    above, its Next Header value (which contains the transport
        //    protocol number) is copied to the protocol field in the IPv4
        //    header.  This means that all transport protocols are translated.
        //    Note:  Some translated protocols will fail at the receiver for
        //       various reasons: some are known to fail when translated (e.g.,
        //       IPsec Authentication Header (51)), and others will fail
        //       checksum validation if the address translation is not checksum
        //       neutral [RFC6052] and the translator does not update the
        //       transport protocol's checksum (because the translator doesn't
        //       support recalculating the checksum for that transport protocol;
        //       see Section 5.5).

        // Note: this seems to suggest there can be more than 1 next level protocol?
        // maybe I'm misreading this.

        let mut pkt = match next_header {
            IpNextHeaderProtocols::Ipv6Frag => {
                // TODO:
                return None;
            }
            IpNextHeaderProtocols::Icmpv6 => {
                let mut pkt = pkt.update_icmpv6_header_to_icmpv4()?;
                pkt.as_ipv4()
                    .set_next_level_protocol(IpNextHeaderProtocols::Icmp);
                pkt
            }
            IpNextHeaderProtocols::Hopopt
            | IpNextHeaderProtocols::Ipv6Route
            | IpNextHeaderProtocols::Ipv6Opts => {
                return None;
            }
            proto => {
                pkt.as_ipv4().set_next_level_protocol(proto);
                pkt
            }
        };

        // Header Checksum:  Computed once the IPv4 header has been created.

        // Source Address:  In the stateless mode (which is to say that if the
        //    IPv6 source address is within the range of a configured IPv6
        //    translation prefix), the IPv4 source address is derived from the
        //    IPv6 source address per [RFC6052], Section 2.3.  Note that the
        //    original IPv6 source address is an IPv4-translatable address.  A
        //    workflow example of stateless translation is shown in Appendix A
        //    of this document.  If the translator only supports stateless mode
        //    and if the IPv6 source address is not within the range of
        //    configured IPv6 prefix(es), the translator SHOULD drop the packet
        //    and respond with an ICMPv6 "Destination Unreachable, Source
        //    address failed ingress/egress policy" (Type 1, Code 5).

        //    In the stateful mode, which is to say that if the IPv6 source
        //    address is not within the range of any configured IPv6 stateless
        //    translation prefix, the IPv4 source address and transport-layer
        //    source port corresponding to the IPv4-related IPv6 source address
        //    and source port are derived from the Binding Information Bases
        //    (BIBs) as described in [RFC6146].

        //    In stateless and stateful modes, if the translator gets an illegal
        //    source address (e.g., ::1, etc.), the translator SHOULD silently
        //    drop the packet.
        pkt.as_ipv4().set_source(src);

        // Destination Address:  The IPv4 destination address is derived from
        //    the IPv6 destination address of the datagram being translated per
        //    [RFC6052], Section 2.3.  Note that the original IPv6 destination
        //    address is an IPv4-converted address.
        pkt.as_ipv4().set_destination(dst);

        // TODO?: If a Routing header with a non-zero Segments Left field is present,
        // then the packet MUST NOT be translated, and an ICMPv6 "parameter
        // problem/erroneous header field encountered" (Type 4, Code 0) error
        // message, with the Pointer field indicating the first byte of the
        // Segments Left field, SHOULD be returned to the sender.

        Some(pkt)
    }

    fn update_icmpv4_header_to_icmpv6(mut self) -> Option<ConvertibleIpv6Packet<'a>> {
        let Some(mut icmp) = MutableIcmpPacket::new(self.payload_mut()) else {
            return Some(self);
        };

        // Note: we only really need to support reply/request because we need
        // the identification to do nat anyways as source port.
        // So the rest of the implementation is not fully made.
        // Specially some consideration has to be made for ICMP error payload
        // so we will do it only if needed at a later time

        // ICMPv4 query messages:

        match icmp.get_icmp_type() {
            //  Echo and Echo Reply (Type 8 and Type 0):  Adjust the Type values
            //    to 128 and 129, respectively, and adjust the ICMP checksum both
            //    to take the type change into account and to include the ICMPv6
            //    pseudo-header.
            IcmpTypes::EchoRequest => {
                icmp.set_icmp_type(icmp::IcmpType(128));
            }
            IcmpTypes::EchoReply => {
                icmp.set_icmp_type(icmp::IcmpType(129));
            }
            // Time Exceeded (Type 11):  Set the Type to 3, and adjust the
            //   ICMP checksum both to take the type change into account and
            //   to include the ICMPv6 pseudo-header.  The Code is unchanged.
            IcmpTypes::TimeExceeded => {
                icmp.set_icmp_type(icmp::IcmpType(3));
            }
            // (TODO) Destination Unreachable (Type 3):  Translate the Code as
            //   described below, set the Type to 1, and adjust the ICMP
            //   checksum both to take the type/code change into account and
            //   to include the ICMPv6 pseudo-header.

            //  Information Request/Reply (Type 15 and Type 16):  Obsoleted in
            //    ICMPv6.  Silently drop.
            //  Timestamp and Timestamp Reply (Type 13 and Type 14):  Obsoleted in
            //    ICMPv6.  Silently drop.
            //  Address Mask Request/Reply (Type 17 and Type 18):  Obsoleted in
            //     ICMPv6.  Silently drop.
            //  ICMP Router Advertisement (Type 9):  Single-hop message.  Silently
            //    drop.
            //  ICMP Router Solicitation (Type 10):  Single-hop message.  Silently
            //    drop.
            //  Unknown ICMPv4 types:  Silently drop.
            //  IGMP messages:  While the Multicast Listener Discovery (MLD)
            //    messages [RFC2710] [RFC3590] [RFC3810] are the logical IPv6
            //    counterparts for the IPv4 IGMP messages, all the "normal" IGMP
            //    messages are single-hop messages and SHOULD be silently dropped
            //    by the translator.  Other IGMP messages might be used by
            //    multicast routing protocols and, since it would be a
            //    configuration error to try to have router adjacencies across
            //    IP/ICMP translators, those packets SHOULD also be silently
            //    dropped.
            // Redirect (Type 5):  Single-hop message.  Silently drop.
            // Alternative Host Address (Type 6):  Silently drop.
            // Source Quench (Type 4):  Obsoleted in ICMPv6.  Silently drop.
            _ => {
                return None;
            }
        }

        Some(self)
    }
}

impl<'a> Packet for ConvertibleIpv6Packet<'a> {
    fn packet(&self) -> &[u8] {
        &self.buf
    }

    fn payload(&self) -> &[u8] {
        let header_len =
            self.to_immutable().packet_size() - self.to_immutable().get_payload_length() as usize;
        &self.buf[header_len..]
    }
}

impl<'a> MutablePacket for ConvertibleIpv6Packet<'a> {
    fn packet_mut(&mut self) -> &mut [u8] {
        &mut self.buf
    }

    fn payload_mut(&mut self) -> &mut [u8] {
        let header_len =
            self.to_immutable().packet_size() - self.to_immutable().get_payload_length() as usize;
        &mut self.buf[header_len..]
    }
}

pub fn ipv4_embedded(ip: Ipv4Addr) -> Ipv6Addr {
    Ipv6Addr::new(
        0x64,
        0xff9b,
        0x00,
        0x00,
        0x00,
        0x00,
        u16::from_be_bytes([ip.octets()[0], ip.octets()[1]]),
        u16::from_be_bytes([ip.octets()[2], ip.octets()[3]]),
    )
}

pub fn ipv6_translated(ip: Ipv6Addr) -> Option<Ipv4Addr> {
    if ip.segments()[0] != 0x64
        || ip.segments()[1] != 0xff9b
        || ip.segments()[2] != 0
        || ip.segments()[3] != 0
        || ip.segments()[4] != 0
        || ip.segments()[5] != 0
    {
        return None;
    }

    Some(Ipv4Addr::new(
        ip.octets()[12],
        ip.octets()[13],
        ip.octets()[14],
        ip.octets()[15],
    ))
}

impl<'a> MutableIpPacket<'a> {
    // TODO: this API is a bit akward, since you have to pass the extra prepended 20 bytes
    pub fn new(buf: &'a mut [u8]) -> Option<Self> {
        match buf[20] >> 4 {
            4 => Some(MutableIpPacket::Ipv4(ConvertibleIpv4Packet::new(buf)?)),
            6 => Some(MutableIpPacket::Ipv6(ConvertibleIpv6Packet::new(
                &mut buf[20..],
            )?)),
            _ => None,
        }
    }

    pub fn owned(mut data: Vec<u8>) -> Option<MutableIpPacket<'static>> {
        let packet = match data[20] >> 4 {
            4 => ConvertibleIpv4Packet::owned(data)?.into(),
            6 => {
                data.drain(0..20);
                ConvertibleIpv6Packet::owned(data)?.into()
            }
            _ => return None,
        };

        Some(packet)
    }

    pub fn to_owned(&self) -> MutableIpPacket<'static> {
        match self {
            MutableIpPacket::Ipv4(i) => ConvertibleIpv4Packet::owned(i.buf.to_vec())
                .expect("owned packet should still be valid")
                .into(),
            MutableIpPacket::Ipv6(i) => ConvertibleIpv6Packet::owned(i.buf.to_vec())
                .expect("owned packet should still be valid")
                .into(),
        }
    }

    pub fn to_immutable(&self) -> IpPacket {
        for_both!(self, |i| i.to_immutable().into())
    }

    fn consume_to_ipv4(self, src: Ipv4Addr, dst: Ipv4Addr) -> Option<MutableIpPacket<'a>> {
        match self {
            MutableIpPacket::Ipv4(pkt) => Some(MutableIpPacket::Ipv4(pkt)),
            MutableIpPacket::Ipv6(pkt) => {
                Some(MutableIpPacket::Ipv4(pkt.consume_to_ipv4(src, dst)?))
            }
        }
    }

    fn consume_to_ipv6(self, src: Ipv6Addr, dst: Ipv6Addr) -> Option<MutableIpPacket<'a>> {
        match self {
            MutableIpPacket::Ipv4(pkt) => {
                Some(MutableIpPacket::Ipv6(pkt.consume_to_ipv6(src, dst)?))
            }
            MutableIpPacket::Ipv6(pkt) => Some(MutableIpPacket::Ipv6(pkt)),
        }
    }

    pub fn source(&self) -> IpAddr {
        for_both!(self, |i| i.get_source().into())
    }

    pub fn destination(&self) -> IpAddr {
        for_both!(self, |i| i.get_destination().into())
    }

    pub fn set_source_protocol(&mut self, v: u16) {
        if let Some(mut p) = self.as_tcp() {
            p.set_source(v);
        }

        if let Some(mut p) = self.as_udp() {
            p.set_source(v);
        }

        self.set_icmp_identifier(v);
    }

    pub fn set_destination_protocol(&mut self, v: u16) {
        if let Some(mut p) = self.as_tcp() {
            p.set_destination(v);
        }

        if let Some(mut p) = self.as_udp() {
            p.set_destination(v);
        }

        self.set_icmp_identifier(v);
    }

    fn set_icmp_identifier(&mut self, v: u16) {
        if let Some(mut p) = self.as_icmp() {
            if p.get_icmp_type() == IcmpTypes::EchoReply {
                let Some(mut echo_reply) = MutableEchoReplyPacket::new(p.packet_mut()) else {
                    return;
                };
                echo_reply.set_identifier(v)
            }

            if p.get_icmp_type() == IcmpTypes::EchoRequest {
                let Some(mut echo_request) = MutableEchoRequestPacket::new(p.packet_mut()) else {
                    return;
                };
                echo_request.set_identifier(v);
            }
        }

        if let Some(mut p) = self.as_icmpv6() {
            if p.get_icmpv6_type() == Icmpv6Types::EchoReply {
                let Some(mut echo_reply) =
                    icmpv6::echo_reply::MutableEchoReplyPacket::new(p.packet_mut())
                else {
                    return;
                };
                echo_reply.set_identifier(v)
            }

            if p.get_icmpv6_type() == Icmpv6Types::EchoRequest {
                let Some(mut echo_request) =
                    icmpv6::echo_request::MutableEchoRequestPacket::new(p.packet_mut())
                else {
                    return;
                };
                echo_request.set_identifier(v);
            }
        }
    }

    #[inline]
    pub fn update_checksum(&mut self) {
        // Note: ipv6 doesn't have a checksum.
        self.set_icmpv6_checksum();
        self.set_icmpv4_checksum();
        self.set_udp_checksum();
        self.set_tcp_checksum();
        // Note: Ipv4 checksum should be set after the others,
        // since it's in an upper layer.
        self.set_ipv4_checksum();
    }

    pub fn set_ipv4_checksum(&mut self) {
        if let Self::Ipv4(p) = self {
            p.set_checksum(ipv4::checksum(&p.to_immutable()));
        }
    }

    fn set_udp_checksum(&mut self) {
        let checksum = if let Some(p) = self.as_immutable_udp() {
            self.to_immutable().udp_checksum(&p.to_immutable())
        } else {
            return;
        };

        self.as_udp()
            .expect("Developer error: we can only get a UDP checksum if the packet is udp")
            .set_checksum(checksum);
    }

    fn set_tcp_checksum(&mut self) {
        let checksum = if let Some(p) = self.as_immutable_tcp() {
            self.to_immutable().tcp_checksum(&p.to_immutable())
        } else {
            return;
        };

        self.as_tcp()
            .expect("Developer error: we can only get a TCP checksum if the packet is tcp")
            .set_checksum(checksum);
    }

    pub fn into_immutable(self) -> IpPacket<'a> {
        match self {
            Self::Ipv4(p) => p.consume_to_immutable().into(),
            Self::Ipv6(p) => p.consume_to_immutable().into(),
        }
    }

    pub fn as_immutable(&self) -> IpPacket<'_> {
        match self {
            Self::Ipv4(p) => IpPacket::Ipv4(p.to_immutable()),
            Self::Ipv6(p) => IpPacket::Ipv6(p.to_immutable()),
        }
    }

    pub fn as_udp(&mut self) -> Option<MutableUdpPacket> {
        self.to_immutable()
            .is_udp()
            .then(|| MutableUdpPacket::new(self.payload_mut()))
            .flatten()
    }

    /// Unwrap this [`IpPacket`] as a [`MutableUdpPacket`], panicking in case it is not.
    pub fn unwrap_as_udp(&mut self) -> MutableUdpPacket {
        self.as_udp().expect("Packet is not a UDP packet")
    }

    pub fn as_tcp(&mut self) -> Option<MutableTcpPacket> {
        self.to_immutable()
            .is_tcp()
            .then(|| MutableTcpPacket::new(self.payload_mut()))
            .flatten()
    }

    fn set_icmpv6_checksum(&mut self) {
        let (src_addr, dst_addr) = match self {
            MutableIpPacket::Ipv4(_) => return,
            MutableIpPacket::Ipv6(p) => (p.get_source(), p.get_destination()),
        };
        if let Some(mut pkt) = self.as_icmpv6() {
            let checksum = icmpv6::checksum(&pkt.to_immutable(), &src_addr, &dst_addr);
            pkt.set_checksum(checksum);
        }
    }

    fn set_icmpv4_checksum(&mut self) {
        if let Some(mut pkt) = self.as_icmp() {
            let checksum = icmp::checksum(&pkt.to_immutable());
            pkt.set_checksum(checksum);
        }
    }

    fn as_icmp(&mut self) -> Option<MutableIcmpPacket> {
        self.to_immutable()
            .is_icmp()
            .then(|| MutableIcmpPacket::new(self.payload_mut()))
            .flatten()
    }

    fn as_icmpv6(&mut self) -> Option<MutableIcmpv6Packet> {
        self.to_immutable()
            .is_icmpv6()
            .then(|| MutableIcmpv6Packet::new(self.payload_mut()))
            .flatten()
    }

    pub fn as_immutable_udp(&self) -> Option<UdpPacket> {
        self.to_immutable()
            .is_udp()
            .then(|| UdpPacket::new(self.payload()))
            .flatten()
    }

    pub fn as_immutable_tcp(&self) -> Option<TcpPacket> {
        self.to_immutable()
            .is_tcp()
            .then(|| TcpPacket::new(self.payload()))
            .flatten()
    }

    pub fn swap_src_dst(&mut self) {
        match self {
            Self::Ipv4(p) => {
                swap_src_dst!(p);
            }
            Self::Ipv6(p) => {
                swap_src_dst!(p);
            }
        }
    }

    pub fn translate_destination(
        mut self,
        src_v4: Ipv4Addr,
        src_v6: Ipv6Addr,
        dst: IpAddr,
    ) -> Option<MutableIpPacket<'a>> {
        match (&self, dst) {
            (&MutableIpPacket::Ipv4(_), IpAddr::V6(dst)) => self.consume_to_ipv6(src_v6, dst),
            (&MutableIpPacket::Ipv6(_), IpAddr::V4(dst)) => self.consume_to_ipv4(src_v4, dst),
            _ => {
                self.set_dst(dst);
                Some(self)
            }
        }
    }

    pub fn translate_source(
        mut self,
        dst_v4: Ipv4Addr,
        dst_v6: Ipv6Addr,
        src: IpAddr,
    ) -> Option<MutableIpPacket<'a>> {
        match (&self, src) {
            (&MutableIpPacket::Ipv4(_), IpAddr::V6(src)) => self.consume_to_ipv6(src, dst_v6),
            (&MutableIpPacket::Ipv6(_), IpAddr::V4(src)) => self.consume_to_ipv4(src, dst_v4),
            _ => {
                self.set_src(src);
                Some(self)
            }
        }
    }

    #[inline]
    pub fn set_dst(&mut self, dst: IpAddr) {
        match (self, dst) {
            (Self::Ipv4(p), IpAddr::V4(d)) => p.set_destination(d),
            (Self::Ipv6(p), IpAddr::V6(d)) => p.set_destination(d),
            (Self::Ipv4(_), IpAddr::V6(_)) => {
                debug_assert!(false, "Cannot set an IPv6 address on an IPv4 packet")
            }
            (Self::Ipv6(_), IpAddr::V4(_)) => {
                debug_assert!(false, "Cannot set an IPv4 address on an IPv6 packet")
            }
        }
    }

    #[inline]
    pub fn set_src(&mut self, src: IpAddr) {
        match (self, src) {
            (Self::Ipv4(p), IpAddr::V4(s)) => p.set_source(s),
            (Self::Ipv6(p), IpAddr::V6(s)) => p.set_source(s),
            (Self::Ipv4(_), IpAddr::V6(_)) => {
                debug_assert!(false, "Cannot set an IPv6 address on an IPv4 packet")
            }
            (Self::Ipv6(_), IpAddr::V4(_)) => {
                debug_assert!(false, "Cannot set an IPv4 address on an IPv6 packet")
            }
        }
    }
}

impl<'a> IpPacket<'a> {
    pub fn new(buf: &'a [u8]) -> Option<Self> {
        match buf[0] >> 4 {
            4 => Some(IpPacket::Ipv4(Ipv4Packet::new(buf)?)),
            6 => Some(IpPacket::Ipv6(Ipv6Packet::new(buf)?)),
            _ => None,
        }
    }

    pub fn to_owned(&self) -> IpPacket<'static> {
        match self {
            IpPacket::Ipv4(i) => Ipv4Packet::owned(i.packet().to_vec())
                .expect("owned packet should still be valid")
                .into(),
            IpPacket::Ipv6(i) => Ipv6Packet::owned(i.packet().to_vec())
                .expect("owned packet should still be valid")
                .into(),
        }
    }

    pub fn source_protocol(&self) -> Result<Protocol, UnsupportedProtocol> {
        if let Some(p) = self.as_tcp() {
            return Ok(Protocol::Tcp(p.get_source()));
        }

        if let Some(p) = self.as_udp() {
            return Ok(Protocol::Udp(p.get_source()));
        }

        if let Some(p) = self.as_icmp() {
            let id = p
                .identifier()
                .ok_or(UnsupportedProtocol(self.next_header()))?;

            return Ok(Protocol::Icmp(id));
        }

        Err(UnsupportedProtocol(self.next_header()))
    }

    pub fn destination_protocol(&self) -> Result<Protocol, UnsupportedProtocol> {
        if let Some(p) = self.as_tcp() {
            return Ok(Protocol::Tcp(p.get_destination()));
        }

        if let Some(p) = self.as_udp() {
            return Ok(Protocol::Udp(p.get_destination()));
        }

        if let Some(p) = self.as_icmp() {
            let id = p
                .identifier()
                .ok_or(UnsupportedProtocol(self.next_header()))?;

            return Ok(Protocol::Icmp(id));
        }

        Err(UnsupportedProtocol(self.next_header()))
    }

    pub fn source(&self) -> IpAddr {
        for_both!(self, |i| i.get_source().into())
    }

    pub fn destination(&self) -> IpAddr {
        for_both!(self, |i| i.get_destination().into())
    }

    pub fn udp_payload(&self) -> &[u8] {
        debug_assert_eq!(
            match self {
                IpPacket::Ipv4(i) => i.get_next_level_protocol(),
                IpPacket::Ipv6(i) => i.get_next_header(),
            },
            IpNextHeaderProtocols::Udp
        );

        for_both!(self, |i| &i.payload()[8..])
    }

    pub fn owned(data: Vec<u8>) -> Option<IpPacket<'static>> {
        let packet = match data[0] >> 4 {
            4 => Ipv4Packet::owned(data)?.into(),
            6 => Ipv6Packet::owned(data)?.into(),
            _ => return None,
        };

        Some(packet)
    }

    pub fn next_header(&self) -> IpNextHeaderProtocol {
        match self {
            Self::Ipv4(p) => p.get_next_level_protocol(),
            Self::Ipv6(p) => p.get_next_header(),
        }
    }

    fn is_udp(&self) -> bool {
        self.next_header() == IpNextHeaderProtocols::Udp
    }

    fn is_tcp(&self) -> bool {
        self.next_header() == IpNextHeaderProtocols::Tcp
    }

    fn is_icmp(&self) -> bool {
        self.next_header() == IpNextHeaderProtocols::Icmp
    }

    fn is_icmpv6(&self) -> bool {
        self.next_header() == IpNextHeaderProtocols::Icmpv6
    }

    pub fn as_udp(&self) -> Option<UdpPacket> {
        self.is_udp()
            .then(|| UdpPacket::new(self.payload()))
            .flatten()
    }

    /// Unwrap this [`IpPacket`] as a [`UdpPacket`], panicking in case it is not.
    pub fn unwrap_as_udp(&self) -> UdpPacket {
        self.as_udp().expect("Packet is not a UDP packet")
    }

    /// Unwrap this [`IpPacket`] as a DNS message, panicking in case it is not.
    pub fn unwrap_as_dns(&self) -> hickory_proto::op::Message {
        let udp = self.unwrap_as_udp();
        let message = match hickory_proto::op::Message::from_vec(udp.payload()) {
            Ok(message) => message,
            Err(e) => {
                panic!("Failed to parse UDP payload as DNS message: {e}");
            }
        };

        message
    }

    pub fn as_tcp(&self) -> Option<TcpPacket> {
        self.is_tcp()
            .then(|| TcpPacket::new(self.payload()))
            .flatten()
    }

    pub fn as_icmp(&self) -> Option<IcmpPacket> {
        match self {
            IpPacket::Ipv4(v4) if v4.get_next_level_protocol() == IpNextHeaderProtocols::Icmp => {
                Some(IcmpPacket::Ipv4(pnet_packet::icmp::IcmpPacket::new(
                    v4.payload(),
                )?))
            }
            IpPacket::Ipv6(v6) if v6.get_next_header() == IpNextHeaderProtocols::Icmpv6 => {
                Some(IcmpPacket::Ipv6(icmpv6::Icmpv6Packet::new(v6.payload())?))
            }
            IpPacket::Ipv4(_) | IpPacket::Ipv6(_) => None,
        }
    }

    pub fn udp_checksum(&self, dgm: &UdpPacket<'_>) -> u16 {
        match self {
            Self::Ipv4(p) => udp::ipv4_checksum(dgm, &p.get_source(), &p.get_destination()),
            Self::Ipv6(p) => udp::ipv6_checksum(dgm, &p.get_source(), &p.get_destination()),
        }
    }

    fn tcp_checksum(&self, pkt: &TcpPacket<'_>) -> u16 {
        match self {
            Self::Ipv4(p) => tcp::ipv4_checksum(pkt, &p.get_source(), &p.get_destination()),
            Self::Ipv6(p) => tcp::ipv6_checksum(pkt, &p.get_source(), &p.get_destination()),
        }
    }
}

impl<'a> IcmpPacket<'a> {
    pub fn as_echo_request(&self) -> Option<IcmpEchoRequest> {
        match self {
            IcmpPacket::Ipv4(v4) if matches!(v4.get_icmp_type(), icmp::IcmpTypes::EchoRequest) => {
                Some(IcmpEchoRequest::Ipv4(
                    icmp::echo_request::EchoRequestPacket::new(v4.packet())?,
                ))
            }
            IcmpPacket::Ipv6(v6)
                if matches!(v6.get_icmpv6_type(), icmpv6::Icmpv6Types::EchoRequest) =>
            {
                Some(IcmpEchoRequest::Ipv6(
                    icmpv6::echo_request::EchoRequestPacket::new(v6.packet())?,
                ))
            }
            IcmpPacket::Ipv4(_) | IcmpPacket::Ipv6(_) => None,
        }
    }

    pub fn as_echo_reply(&self) -> Option<IcmpEchoReply> {
        match self {
            IcmpPacket::Ipv4(v4) if matches!(v4.get_icmp_type(), icmp::IcmpTypes::EchoReply) => {
                Some(IcmpEchoReply::Ipv4(icmp::echo_reply::EchoReplyPacket::new(
                    v4.packet(),
                )?))
            }
            IcmpPacket::Ipv6(v6)
                if matches!(v6.get_icmpv6_type(), icmpv6::Icmpv6Types::EchoReply) =>
            {
                Some(IcmpEchoReply::Ipv6(
                    icmpv6::echo_reply::EchoReplyPacket::new(v6.packet())?,
                ))
            }
            IcmpPacket::Ipv4(_) | IcmpPacket::Ipv6(_) => None,
        }
    }

    pub fn is_echo_reply(&self) -> bool {
        self.as_echo_reply().is_some()
    }

    pub fn is_echo_request(&self) -> bool {
        self.as_echo_request().is_some()
    }

    pub fn checksum(&self) -> u16 {
        match self {
            IcmpPacket::Ipv4(p) => p.get_checksum(),
            IcmpPacket::Ipv6(p) => p.get_checksum(),
        }
    }
}

impl<'a> IcmpEchoRequest<'a> {
    pub fn sequence(&self) -> u16 {
        for_both!(self, |i| i.get_sequence_number())
    }

    pub fn identifier(&self) -> u16 {
        for_both!(self, |i| i.get_identifier())
    }
}

impl<'a> IcmpEchoReply<'a> {
    pub fn sequence(&self) -> u16 {
        for_both!(self, |i| i.get_sequence_number())
    }

    pub fn identifier(&self) -> u16 {
        for_both!(self, |i| i.get_identifier())
    }
}

impl Clone for IpPacket<'static> {
    fn clone(&self) -> Self {
        match self {
            Self::Ipv4(ip4) => Self::Ipv4(Ipv4Packet::owned(ip4.packet().to_vec()).unwrap()),
            Self::Ipv6(ip6) => Self::Ipv6(Ipv6Packet::owned(ip6.packet().to_vec()).unwrap()),
        }
    }
}

impl<'a> From<Ipv4Packet<'a>> for IpPacket<'a> {
    fn from(value: Ipv4Packet<'a>) -> Self {
        Self::Ipv4(value)
    }
}

impl<'a> From<Ipv6Packet<'a>> for IpPacket<'a> {
    fn from(value: Ipv6Packet<'a>) -> Self {
        Self::Ipv6(value)
    }
}

impl<'a> From<ConvertibleIpv4Packet<'a>> for MutableIpPacket<'a> {
    fn from(value: ConvertibleIpv4Packet<'a>) -> Self {
        Self::Ipv4(value)
    }
}

impl<'a> From<ConvertibleIpv6Packet<'a>> for MutableIpPacket<'a> {
    fn from(value: ConvertibleIpv6Packet<'a>) -> Self {
        Self::Ipv6(value)
    }
}

impl pnet_packet::Packet for MutableIpPacket<'_> {
    fn packet(&self) -> &[u8] {
        for_both!(self, |i| i.packet())
    }

    fn payload(&self) -> &[u8] {
        for_both!(self, |i| i.payload())
    }
}

impl pnet_packet::Packet for IpPacket<'_> {
    fn packet(&self) -> &[u8] {
        for_both!(self, |i| i.packet())
    }

    fn payload(&self) -> &[u8] {
        for_both!(self, |i| i.payload())
    }
}

impl pnet_packet::MutablePacket for MutableIpPacket<'_> {
    fn packet_mut(&mut self) -> &mut [u8] {
        for_both!(self, |i| i.packet_mut())
    }

    fn payload_mut(&mut self) -> &mut [u8] {
        for_both!(self, |i| i.payload_mut())
    }
}

impl<'a> PacketSize for IpPacket<'a> {
    fn packet_size(&self) -> usize {
        match self {
            Self::Ipv4(p) => p.packet_size(),
            Self::Ipv6(p) => p.packet_size(),
        }
    }
}

#[derive(Debug, thiserror::Error)]
#[error("Unsupported IP protocol: {0}")]
pub struct UnsupportedProtocol(IpNextHeaderProtocol);
