use anyhow::Result;
use etherparse::{
    Icmpv6Header, IpFragOffset, IpNumber, Ipv4Dscp, Ipv4Ecn, Ipv4Header, Ipv4Options, Ipv6Header,
};
use std::{io::Cursor, net::Ipv4Addr};

use crate::ImpossibleTranslation;

/// Performs IPv6 -> IPv4 NAT on the packet in `buf` to the given src & dst IP.
///
/// IPv6 headers have a fixed size of 40 bytes.
/// IPv4 options are lost as part of NAT64, meaning the translated packet will always be 20 bytes shorter.
/// Thus, the IPv4 packet will always sit at an offset of 20 bytes in `buf` after the translation.
pub fn translate_in_place(buf: &mut [u8], src: Ipv4Addr, dst: Ipv4Addr) -> Result<()> {
    let (headers, payload) = etherparse::IpHeaders::from_ipv6_slice(buf)?;
    let (ipv6_header, _extensions) = headers.ipv6().expect("We successfully parsed as IPv6");

    // TODO:
    // If there is no IPv6 Fragment Header, the IPv4 header fields are set
    // as follows:
    // Note the RFC has notes on how to set fragmentation fields.

    let mut ipv4_header = Ipv4Header {
        // Internet Header Length:  5 (no IPv4 options)
        options: Ipv4Options::default(),

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
        dscp: Ipv4Dscp::try_new(ipv6_header.traffic_class).unwrap_or(Ipv4Dscp::ZERO),

        // Total Length:  Payload length value from the IPv6 header, plus the
        //    size of the IPv4 header.
        total_len: ipv6_header.payload_length + Ipv4Header::MIN_LEN_U16,

        // Identification:  All zero.  In order to avoid black holes caused by
        //    ICMPv4 filtering or non-[RFC2460]-compatible IPv6 hosts (a
        //    workaround is discussed in Section 6), the translator MAY provide
        //    a function to generate the identification value if the packet size
        //    is greater than 88 bytes and less than or equal to 1280 bytes.
        //    The translator SHOULD provide a method for operators to enable or
        //    disable this function.
        identification: 0,

        // Flags:  The More Fragments flag is set to zero.  The Don't Fragment
        //    (DF) flag is set to one.  In order to avoid black holes caused by
        //    ICMPv4 filtering or non-[RFC2460]-compatible IPv6 hosts (a
        //    workaround is discussed in Section 6), the translator MAY provide
        //    a function as follows.  If the packet size is greater than 88
        //    bytes and less than or equal to 1280 bytes, it sets the DF flag to
        //    zero; otherwise, it sets the DF flag to one.  The translator
        //    SHOULD provide a method for operators to enable or disable this
        //    function.
        more_fragments: false,
        dont_fragment: true,

        // Fragment Offset:  All zeros.
        fragment_offset: IpFragOffset::ZERO,

        ecn: Ipv4Ecn::default(),

        // Time to Live:  Time to Live is derived from Hop Limit value in IPv6
        //    header.  Since the translator is a router, as part of forwarding
        //    the packet it needs to decrement either the IPv6 Hop Limit (before
        //    the translation) or the IPv4 TTL (after the translation).  As part
        //    of decrementing the TTL or Hop Limit the translator (as any
        //    router) MUST check for zero and send the ICMPv4 "TTL Exceeded" or
        //    ICMPv6 "Hop Limit Exceeded" error.
        // Same note as for the other translation
        time_to_live: ipv6_header.hop_limit,

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
        // FIXME: We should take into account the `Ipv6Extensions` from above.
        protocol: match ipv6_header.next_header {
            IpNumber::IPV6_FRAGMENTATION_HEADER // TODO: Implement fragmentation?
            | IpNumber::IPV6_HEADER_HOP_BY_HOP
            | IpNumber::IPV6_ROUTE_HEADER
            | IpNumber::IPV6_DESTINATION_OPTIONS => {
                anyhow::bail!("Unable to translate IPv6 next header protocol: {:?}", ipv6_header.next_header.protocol_str());
            },
            IpNumber::IPV6_ICMP => IpNumber::ICMP,
            other => other
        },

        // Header Checksum:  Computed once the IPv4 header has been created.
        header_checksum: 0,

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
        source: src.octets(),

        // Destination Address:  The IPv4 destination address is derived from
        //    the IPv6 destination address of the datagram being translated per
        //    [RFC6052], Section 2.3.  Note that the original IPv6 destination
        //    address is an IPv4-converted address.
        destination: dst.octets(),
    };

    tracing::trace!(from = ?ipv6_header, to = ?ipv4_header, "Performed IP-NAT64");

    if ipv6_header.next_header == IpNumber::IPV6_ICMP {
        let (icmpv6_header, _icmp_payload) = Icmpv6Header::from_slice(payload.payload)?;
        let icmpv6_header_length = icmpv6_header.header_len();

        // Optimisation to only clone when we are actually logging.
        let icmpv6_header_dbg = tracing::event_enabled!(tracing::Level::TRACE)
            .then(|| tracing::field::debug(icmpv6_header.clone()));

        let icmpv4_header = translate_icmpv6_header(icmpv6_header).ok_or(ImpossibleTranslation)?;
        let icmpv4_header_length = icmpv4_header.header_len();

        tracing::trace!(from = icmpv6_header_dbg, to = ?icmpv4_header, "Performed ICMP-NAT64");

        // We assume that the sizeof the ICMP header does not change and the payload will be in the correct spot.
        debug_assert_eq!(
            icmpv4_header_length, icmpv6_header_length,
            "Length of ICMPv4 header should be equal to length of ICMPv6 header"
        );

        let (_ip_header, ip_payload) = buf.split_at_mut(Ipv6Header::LEN);

        icmpv4_header.write(&mut Cursor::new(ip_payload))?;
    }

    // TODO?: If a Routing header with a non-zero Segments Left field is present,
    // then the packet MUST NOT be translated, and an ICMPv6 "parameter
    // problem/erroneous header field encountered" (Type 4, Code 0) error
    // message, with the Pointer field indicating the first byte of the
    // Segments Left field, SHOULD be returned to the sender.

    ipv4_header.header_checksum = ipv4_header.calc_header_checksum();

    debug_assert_eq!(
        ipv4_header.header_len(),
        Ipv4Header::MIN_LEN,
        "Translated IPv4 header should be minimum length"
    );

    buf[..40].fill(0);
    let ipv4_header_buf = &mut buf[20..];
    ipv4_header.write(&mut Cursor::new(ipv4_header_buf))?;

    Ok(())
}

fn translate_icmpv6_header(
    icmpv6_header: etherparse::Icmpv6Header,
) -> Option<etherparse::Icmpv4Header> {
    use etherparse::{Icmpv4Header, Icmpv4Type, Icmpv6Type, icmpv4};

    // Note: we only really need to support reply/request because we need
    // the identification to do nat anyways as source port.
    // So the rest of the implementation is not fully made.
    // Specially some consideration has to be made for ICMP error payload
    // so we will do it only if needed at a later time

    // ICMPv6 informational messages:

    let icmpv4_type = match icmpv6_header.icmp_type {
        // Echo Request and Echo Reply (Type 128 and 129):  Adjust the Type
        //    values to 8 and 0, respectively, and adjust the ICMP checksum
        //    both to take the type change into account and to exclude the
        //    ICMPv6 pseudo-header.
        Icmpv6Type::EchoRequest(header) => Icmpv4Type::EchoRequest(header),
        Icmpv6Type::EchoReply(header) => Icmpv4Type::EchoReply(header),

        // Destination Unreachable (Type 1)  Set the Type to 3, and adjust
        //     the ICMP checksum both to take the type/code change into
        //     account and to exclude the ICMPv6 pseudo-header.
        //
        // Translate the Code as follows:
        Icmpv6Type::DestinationUnreachable(i) => {
            Icmpv4Type::DestinationUnreachable(translate_dest_unreachable(i)?)
        }
        Icmpv6Type::PacketTooBig { mtu } => {
            Icmpv4Type::DestinationUnreachable(translate_packet_too_big(mtu))
        }
        // Time Exceeded (Type 3):  Set the Type to 11, and adjust the ICMPv4
        //      checksum both to take the type change into account and to
        //      exclude the ICMPv6 pseudo-header.  The Code is unchanged.
        Icmpv6Type::TimeExceeded(code) => {
            Icmpv4Type::TimeExceeded(icmpv4::TimeExceededCode::from_u8(code.code_u8())?)
        }
        //      Translate the Code as follows:
        Icmpv6Type::ParameterProblem(i) => {
            use etherparse::icmpv6::ParameterProblemCode::*;

            match i.code {
                // Code 0 (Erroneous header field encountered):  Set to Type 12,
                //      Code 0, and update the pointer as defined in Figure 6.  (If
                //      the Original IPv6 Pointer Value is not listed or the
                //      Translated IPv4 Pointer Value is listed as "n/a", silently
                //      drop the packet.)
                ErroneousHeaderField => {
                    return None; // FIXME: Need to update the pointer
                }
                // Code 1 (Unrecognized Next Header type encountered):  Translate
                //      this to an ICMPv4 protocol unreachable (Type 3, Code 2).
                UnrecognizedNextHeader => {
                    Icmpv4Type::DestinationUnreachable(icmpv4::DestUnreachableHeader::Protocol)
                }

                // Code 2 (Unrecognized IPv6 option encountered):  Silently drop.
                UnrecognizedIpv6Option => {
                    return None;
                }
                //  Unknown error messages:  Silently drop.
                Ipv6FirstFragmentIncompleteHeaderChain
                | SrUpperLayerHeaderError
                | UnrecognizedNextHeaderByIntermediateNode
                | ExtensionHeaderTooBig
                | ExtensionHeaderChainTooLong
                | TooManyExtensionHeaders
                | TooManyOptionsInExtensionHeader
                | OptionTooBig => {
                    return None;
                }
            }
        }

        // MLD Multicast Listener Query/Report/Done (Type 130, 131, 132):
        // Single-hop message.  Silently drop.

        // Neighbor Discover messages (Type 133 through 137):  Single-hop
        // message.  Silently drop.

        // Unknown informational messages:  Silently drop.
        Icmpv6Type::Unknown { .. } => return None,
    };

    Some(Icmpv4Header::new(icmpv4_type))
}

pub fn translate_packet_too_big(mtu: u32) -> etherparse::icmpv4::DestUnreachableHeader {
    // Packet Too Big (Type 2):  Translate to an ICMPv4 Destination
    //      Unreachable (Type 3) with Code 4, and adjust the ICMPv4
    //      checksum both to take the type change into account and to
    //      exclude the ICMPv6 pseudo-header.  The MTU field MUST be
    //      adjusted for the difference between the IPv4 and IPv6 header
    //      sizes, taking into account whether or not the packet in error
    //      includes a Fragment Header, i.e., minimum(advertised MTU-20,
    //      MTU_of_IPv4_nexthop, (MTU_of_IPv6_nexthop)-20).
    //
    //      See also the requirements in Section 6.

    let mtu = u16::try_from(mtu).unwrap_or(u16::MAX); // Unlikely but necessary fallback.

    etherparse::icmpv4::DestUnreachableHeader::FragmentationNeeded {
        next_hop_mtu: mtu - 20, // We don't know the next-hop MTUs here so we just subtract 20 bytes.
    }
}

pub fn translate_dest_unreachable(
    code: etherparse::icmpv6::DestUnreachableCode,
) -> Option<etherparse::icmpv4::DestUnreachableHeader> {
    use etherparse::icmpv4::{self, DestUnreachableHeader::*};
    use etherparse::icmpv6::{self, DestUnreachableCode::*};

    Some(match code {
        // Code 0 (No route to destination):  Set the Code to 1 (Host
        //     unreachable).
        NoRoute => Host,

        // Code 1 (Communication with destination administratively
        //     prohibited):  Set the Code to 10 (Communication with
        //     destination host administratively prohibited).
        Prohibited => HostProhibited,

        // Code 2 (Beyond scope of source address):  Set the Code to 1
        //      (Host unreachable).  Note that this error is very unlikely
        //      since an IPv4-translatable source address is typically
        //      considered to have global scope.
        BeyondScope => Host,

        // Code 3 (Address unreachable):  Set the Code to 1 (Host
        //      unreachable).
        Address => Host,

        // Code 4 (Port unreachable):  Set the Code to 3 (Port
        //      unreachable).
        icmpv6::DestUnreachableCode::Port => icmpv4::DestUnreachableHeader::Port,

        // Other Code values:  Silently drop.
        SourceAddressFailedPolicy | RejectRoute => {
            return None;
        }
    })
}
