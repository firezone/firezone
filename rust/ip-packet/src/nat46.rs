use anyhow::Result;
use etherparse::{
    icmpv4,
    icmpv6::{self, ParameterProblemHeader},
    Icmpv4Header, Icmpv4Type, Icmpv6Header, Icmpv6Type, IpNumber, Ipv6FlowLabel, Ipv6Header,
};
use std::{io::Cursor, net::Ipv6Addr};

use crate::{ImpossibleTranslation, NAT46_OVERHEAD};

/// Performs IPv4 -> IPv6 NAT on the packet in `buf` to the given src & dst IP.
///
/// An IPv6 IP-header may be up to 20 bytes bigger than its corresponding IPv4 counterpart.
/// Thus, the IPv4 packet is expected to sit at an offset of [`NAT46_OVERHEAD`] bytes in `buf`.
///
/// # Returns
///
/// - Ok(offset): The offset within `buf` at which the new IPv6 packet starts.
pub fn translate_in_place(buf: &mut [u8], src: Ipv6Addr, dst: Ipv6Addr) -> Result<usize> {
    let ipv4_packet = &buf[NAT46_OVERHEAD..];

    let (headers, payload) = etherparse::IpHeaders::from_ipv4_slice(ipv4_packet)?;
    let (ipv4_header, _extensions) = headers.ipv4().expect("We successfully parsed as IPv4");

    let total_length = ipv4_header.total_len;
    let header_length = ipv4_header.header_len();
    let start_of_ip_payload = 20 + header_length;

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

    let ipv6_header = Ipv6Header {
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
        traffic_class: ipv4_header.dscp.value(),

        // Flow Label:  0 (all zero bits)
        flow_label: Ipv6FlowLabel::ZERO,

        // Payload Length:  Total length value from the IPv4 header, minus the
        //    size of the IPv4 header and IPv4 options, if present.
        payload_length: total_length - (header_length as u16),

        // Next Header:  For ICMPv4 (1), it is changed to ICMPv6 (58);
        //    otherwise, the protocol field MUST be copied from the IPv4 header.
        next_header: match ipv4_header.protocol {
            IpNumber::ICMP => IpNumber::IPV6_ICMP,
            other => other,
        },

        // Hop Limit:  The hop limit is derived from the TTL value in the IPv4
        //    header.  Since the translator is a router, as part of forwarding
        //    the packet it needs to decrement either the IPv4 TTL (before the
        //    translation) or the IPv6 Hop Limit (after the translation).  As
        //    part of decrementing the TTL or Hop Limit, the translator (as any
        //    router) MUST check for zero and send the ICMPv4 "TTL Exceeded" or
        //    ICMPv6 "Hop Limit Exceeded" error.
        // TODO: do we really need to act as a router?
        // reducing the ttl and having to send back a message makes things much harder
        hop_limit: ipv4_header.time_to_live,

        // Source Address:  The IPv4-converted address derived from the IPv4
        //    source address per [RFC6052], Section 2.3.
        // Note: Rust implements RFC4291 with to_ipv6_mapped but buf RFC6145
        // recommends the above. The advantage of using RFC6052 are explained in
        // section 4.2 of that RFC

        //    If the translator gets an illegal source address (e.g., 0.0.0.0,
        //    127.0.0.1, etc.), the translator SHOULD silently drop the packet
        //    (as discussed in Section 5.3.7 of [RFC1812]).
        // TODO: drop illegal source address? I don't think we need to do it
        source: src.octets(),

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
        destination: dst.octets(),
    };

    tracing::trace!(from = ?ipv4_header, to = ?ipv6_header, "Performed IP-NAT46");

    if ipv4_header.protocol == IpNumber::ICMP {
        let (icmpv4_header, _icmp_payload) = Icmpv4Header::from_slice(payload.payload)?;
        let icmpv4_header_length = icmpv4_header.header_len();

        // Optimisation to only clone when we are actually logging.
        let icmpv4_header_dbg = tracing::event_enabled!(tracing::Level::TRACE)
            .then(|| tracing::field::debug(icmpv4_header.clone()));

        let icmpv6_header =
            translate_icmpv4_header(total_length, icmpv4_header).ok_or(ImpossibleTranslation)?;
        let icmpv6_header_length = icmpv6_header.header_len();

        tracing::trace!(from = icmpv4_header_dbg, to = ?icmpv6_header, "Performed ICMP-NAT46");

        // We assume that the sizeof the ICMP header does not change and the payload will be in the correct spot.
        debug_assert_eq!(
            icmpv4_header_length, icmpv6_header_length,
            "Length of ICMPv6 header should be equal to length of ICMPv4 header"
        );

        let (_ip_header, ip_payload) = buf.split_at_mut(start_of_ip_payload);

        icmpv6_header.write(&mut Cursor::new(ip_payload))?;
    };

    let start_of_ipv6_header = start_of_ip_payload - Ipv6Header::LEN;

    let (_, ipv6_header_buf) = buf.split_at_mut(start_of_ipv6_header);
    ipv6_header.write(&mut Cursor::new(ipv6_header_buf))?;

    Ok(start_of_ipv6_header)
}

fn translate_icmpv4_header(
    total_length: u16,
    icmpv4_header: etherparse::Icmpv4Header,
) -> Option<etherparse::Icmpv6Header> {
    // Note: we only really need to support reply/request because we need
    // the identification to do nat anyways as source port.
    // So the rest of the implementation is not fully made.
    // Specially some consideration has to be made for ICMP error payload
    // so we will do it only if needed at a later time

    // ICMPv4 query messages:
    let icmpv6_type = match icmpv4_header.icmp_type {
        //  Echo and Echo Reply (Type 8 and Type 0):  Adjust the Type values
        //    to 128 and 129, respectively, and adjust the ICMP checksum both
        //    to take the type change into account and to include the ICMPv6
        //    pseudo-header.
        Icmpv4Type::EchoRequest(header) => Icmpv6Type::EchoRequest(header),
        Icmpv4Type::EchoReply(header) => Icmpv6Type::EchoReply(header),

        // Time Exceeded (Type 11):  Set the Type to 3, and adjust the
        //   ICMP checksum both to take the type change into account and
        //   to include the ICMPv6 pseudo-header.  The Code is unchanged.
        Icmpv4Type::TimeExceeded(i) => {
            Icmpv6Type::TimeExceeded(icmpv6::TimeExceededCode::from_u8(i.code_u8())?)
        }

        // Destination Unreachable (Type 3):  Translate the Code as
        // described below, set the Type to 1, and adjust the ICMP
        // checksum both to take the type/code change into account and
        // to include the ICMPv6 pseudo-header.
        Icmpv4Type::DestinationUnreachable(i) => translate_icmp_unreachable(i, total_length)?,
        Icmpv4Type::Redirect(_) => return None,
        Icmpv4Type::ParameterProblem(_) => return None,

        //  Timestamp and Timestamp Reply (Type 13 and Type 14):  Obsoleted in
        //    ICMPv6.  Silently drop.
        Icmpv4Type::TimestampRequest(_) | Icmpv4Type::TimestampReply(_) => return None,

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
        Icmpv4Type::Unknown { .. } => return None,
    };

    Some(Icmpv6Header::new(icmpv6_type))
}

pub fn translate_icmp_unreachable(
    header: icmpv4::DestUnreachableHeader,
    total_length: u16,
) -> Option<Icmpv6Type> {
    use icmpv4::DestUnreachableHeader::*;
    use icmpv6::DestUnreachableCode::*;

    Some(match header {
        // Code 0, 1 (Net Unreachable, Host Unreachable):  Set the Code
        //    to 0 (No route to destination).
        Network | Host => Icmpv6Type::DestinationUnreachable(NoRoute),

        // Code 2 (Protocol Unreachable):  Translate to an ICMPv6
        //    Parameter Problem (Type 4, Code 1) and make the Pointer
        //    point to the IPv6 Next Header field.
        Protocol => Icmpv6Type::ParameterProblem(ParameterProblemHeader {
            code: icmpv6::ParameterProblemCode::UnrecognizedNextHeader,
            pointer: 6, // The "Next Header" field is always at a fixed offset.
        }),
        // Code 3 (Port Unreachable):  Set the Code to 4 (Port
        //    unreachable).
        icmpv4::DestUnreachableHeader::Port => {
            Icmpv6Type::DestinationUnreachable(icmpv6::DestUnreachableCode::Port)
        }
        // Code 4 (Fragmentation Needed and DF was Set):  Translate to
        //    an ICMPv6 Packet Too Big message (Type 2) with Code set
        //    to 0.  The MTU field MUST be adjusted for the difference
        //    between the IPv4 and IPv6 header sizes, i.e.,
        //    minimum(advertised MTU+20, MTU_of_IPv6_nexthop,
        //    (MTU_of_IPv4_nexthop)+20).  Note that if the IPv4 router
        //    set the MTU field to zero, i.e., the router does not
        //    implement [RFC1191], then the translator MUST use the
        //    plateau values specified in [RFC1191] to determine a
        //    likely path MTU and include that path MTU in the ICMPv6
        //    packet.  (Use the greatest plateau value that is less
        //    than the returned Total Length field.)

        //    See also the requirements in Section 6.
        FragmentationNeeded { next_hop_mtu: 0 } => {
            const PLATEAU_VALUES: [u16; 10] =
                [68, 296, 508, 1006, 1492, 2002, 4352, 8166, 32000, 65535];

            let mtu = PLATEAU_VALUES
                .into_iter()
                .filter(|mtu| *mtu < total_length)
                .max()?;

            Icmpv6Type::PacketTooBig { mtu: mtu as u32 }
        }
        FragmentationNeeded { .. } => {
            return None; // FIXME: We don't know our IPv4 / IPv6 MTU here so cannot currently implement this.
        }

        // Code 5 (Source Route Failed):  Set the Code to 0 (No route
        //    to destination).  Note that this error is unlikely since
        //    source routes are not translated.
        SourceRouteFailed => Icmpv6Type::DestinationUnreachable(NoRoute),
        // Code 6, 7, 8:  Set the Code to 0 (No route to destination).
        NetworkUnknown | HostUnknown | Isolated => Icmpv6Type::DestinationUnreachable(NoRoute),

        // Code 9, 10 (Communication with Destination Host
        //     Administratively Prohibited):  Set the Code to 1
        //     (Communication with destination administratively
        //     prohibited).
        NetworkProhibited | HostProhibited => Icmpv6Type::DestinationUnreachable(Prohibited),

        //  Code 11, 12:  Set the Code to 0 (No route to destination).
        TosNetwork | TosHost => Icmpv6Type::DestinationUnreachable(NoRoute),

        //  Code 13 (Communication Administratively Prohibited):  Set
        //     the Code to 1 (Communication with destination
        //     administratively prohibited).
        FilterProhibited => Icmpv6Type::DestinationUnreachable(Prohibited),

        //  Code 14 (Host Precedence Violation):  Silently drop.
        HostPrecedenceViolation => return None,

        //  Code 15 (Precedence cutoff in effect):  Set the Code to 1
        //     (Communication with destination administratively
        //     prohibited).
        PrecedenceCutoff => Icmpv6Type::DestinationUnreachable(Prohibited),
    })
}
