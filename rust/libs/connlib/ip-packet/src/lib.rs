#![cfg_attr(test, allow(clippy::unwrap_used))]

pub mod make;

mod fz_p2p_control;
mod fz_p2p_control_slice;
mod icmp_error;

#[cfg(feature = "proptest")]
#[allow(clippy::unwrap_used)]
pub mod proptest;

use bufferpool::{Buffer, BufferPool};
use etherparse::err::ValueTooBigError;
pub use etherparse::*;
pub use fz_p2p_control::EventType as FzP2pEventType;
pub use fz_p2p_control_slice::FzP2pControlSlice;
pub use icmp_error::{FailedPacket, IcmpError};

use anyhow::{Context as _, Result, bail};
use std::net::IpAddr;
use std::sync::LazyLock;

use etherparse_ext::Icmpv4HeaderSliceMut;
use etherparse_ext::Icmpv6EchoHeaderSliceMut;
use etherparse_ext::Ipv4HeaderSliceMut;
use etherparse_ext::Ipv6HeaderSliceMut;
use etherparse_ext::TcpHeaderSliceMut;
use etherparse_ext::UdpHeaderSliceMut;

static BUFFER_POOL: LazyLock<BufferPool<Vec<u8>>> =
    LazyLock::new(|| BufferPool::new(MAX_FZ_PAYLOAD, "ip-packet"));

/// The maximum size of an IP packet we can handle.
pub const MAX_IP_SIZE: usize = 1280;
/// The maximum payload an IP packet can have.
///
/// IPv6 headers are always a fixed size whereas IPv4 headers can vary.
/// The max length of an IPv4 header is > the fixed length of an IPv6 header.
pub const MAX_IP_PAYLOAD: u16 = (MAX_IP_SIZE - etherparse::Ipv4Header::MAX_LEN) as u16;
/// The maximum payload a UDP packet can have.
pub const MAX_UDP_PAYLOAD: u16 = MAX_IP_PAYLOAD - etherparse::UdpHeader::LEN as u16;

/// The maximum size of the payload that Firezone will send between nodes.
///
/// - The TUN device MTU is constrained to 1280 ([`MAX_IP_SIZE`]).
/// - WireGuard adds an overhoad of 32 bytes ([`WG_OVERHEAD`]).
/// - In case the connection is relayed, a 4 byte overhead is added ([`DATA_CHANNEL_OVERHEAD`]).
///
/// WireGuard adds its fixed 32-byte overhead and the relayed connections adds its 4 byte overhead.
pub const MAX_FZ_PAYLOAD: usize = MAX_IP_SIZE + WG_OVERHEAD + DATA_CHANNEL_OVERHEAD;
/// Wireguard has a 32-byte overhead (4b message type + 4b receiver idx + 8b packet counter + 16b AEAD tag)
pub const WG_OVERHEAD: usize = 32;
/// TURN's data channels have a 4 byte overhead.
pub const DATA_CHANNEL_OVERHEAD: usize = 4;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
#[cfg_attr(feature = "arbitrary", derive(arbitrary::Arbitrary))]
pub enum Protocol {
    /// Contains either the source or destination port.
    Tcp(u16),
    /// Contains either the source or destination port.
    Udp(u16),
    /// Contains the `identifier` of the ICMP echo packet.
    IcmpEcho(u16),
}

impl Protocol {
    pub fn same_type(&self, other: &Protocol) -> bool {
        matches!(
            (self, other),
            (Protocol::Tcp(_), Protocol::Tcp(_))
                | (Protocol::Udp(_), Protocol::Udp(_))
                | (Protocol::IcmpEcho(_), Protocol::IcmpEcho(_))
        )
    }

    pub fn value(&self) -> u16 {
        match self {
            Protocol::Tcp(v) => *v,
            Protocol::Udp(v) => *v,
            Protocol::IcmpEcho(v) => *v,
        }
    }

    pub fn with_value(self, value: u16) -> Protocol {
        match self {
            Protocol::Tcp(_) => Protocol::Tcp(value),
            Protocol::Udp(_) => Protocol::Udp(value),
            Protocol::IcmpEcho(_) => Protocol::IcmpEcho(value),
        }
    }
}

#[derive(Debug, PartialEq, Eq, Clone, Copy)]
pub enum Layer4Protocol {
    Udp { src: u16, dst: u16 },
    Tcp { src: u16, dst: u16 },
    Icmp { seq: u16, id: u16 },
}

/// A buffer for reading a new [`IpPacket`] from the network.
pub struct IpPacketBuf {
    inner: Buffer<Vec<u8>>,
}

impl Default for IpPacketBuf {
    fn default() -> Self {
        Self {
            inner: BUFFER_POOL.pull(),
        }
    }
}

impl IpPacketBuf {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn buf(&mut self) -> &mut [u8] {
        &mut self.inner
    }
}

#[derive(PartialEq, Clone)]
pub struct IpPacket {
    buf: Buffer<Vec<u8>>,
    ip_header_length: usize,
    len: usize,

    version: IpVersion,
}

#[derive(PartialEq, Clone, Copy)]
pub enum IpVersion {
    V4,
    V6,
}

impl std::fmt::Debug for IpPacket {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let mut dbg = f.debug_struct("Packet");

        dbg.field("src", &self.source())
            .field("dst", &self.destination())
            .field(
                "protocol",
                &self.next_header().keyword_str().unwrap_or("unknown"),
            );

        if let Some(icmp) = self.as_icmpv4() {
            dbg.field("icmp_type", &icmp.icmp_type());
        }

        if let Some(icmp) = self.as_icmpv6() {
            dbg.field("icmp_type", &icmp.icmp_type());
        }

        if let Some(tcp) = self.as_tcp() {
            dbg.field("src_port", &tcp.source_port())
                .field("dst_port", &tcp.destination_port())
                .field("seq", &tcp.sequence_number())
                .field("len", &tcp.payload().len());

            if tcp.syn() {
                dbg.field("syn", &true);
            }

            if tcp.rst() {
                dbg.field("rst", &true);
            }

            if tcp.fin() {
                dbg.field("fin", &true);
            }
        }

        if let Some(udp) = self.as_udp() {
            dbg.field("src_port", &udp.source_port())
                .field("dst_port", &udp.destination_port())
                .field("len", &udp.payload().len());
        }

        match self.ecn() {
            Ecn::NonEct => {}
            Ecn::Ect1 => {
                dbg.field("ecn", &"ECT(1)");
            }
            Ecn::Ect0 => {
                dbg.field("ecn", &"ECT(0)");
            }
            Ecn::Ce => {
                dbg.field("ecn", &"CE");
            }
        };

        dbg.finish()
    }
}

impl IpPacket {
    pub fn new(buf: IpPacketBuf, len: usize) -> Result<Self> {
        anyhow::ensure!(len <= MAX_IP_SIZE, "Packet too large (len: {len})");
        anyhow::ensure!(len <= buf.inner.len(), "Length exceeds buffer size");

        let ip = IpSlice::from_slice(&buf.inner[..len]).context("Failed to parse IP packet")?;

        anyhow::ensure!(!ip.is_fragmenting_payload(), Fragmented);

        let src_ip = ip.source_addr();
        let dst_ip = ip.destination_addr();

        // Validate the packet contents
        match ip.payload_ip_number() {
            IpNumber::UDP => {
                let udp_header = UdpHeaderSlice::from_slice(ip.payload().payload)
                    .context("Failed to parse UDP header")?
                    .to_header();

                UdpSlice::from_slice(ip.payload().payload).with_context(|| {
                    format!("Failed to parse UDP packet; src IP = {src_ip}, dst IP = {dst_ip}, {udp_header:?}")
                })?;
            }
            IpNumber::TCP => {
                let tcp_header = TcpHeaderSlice::from_slice(ip.payload().payload)
                    .context("Failed to parse TCP header")?
                    .to_header();

                TcpSlice::from_slice(ip.payload().payload).with_context(|| {
                    format!("Failed to parse TCP packet; src IP = {src_ip}, dst IP = {dst_ip}, {tcp_header:?}")
                })?;
            }
            IpNumber::ICMP => {
                anyhow::ensure!(
                    matches!(ip, IpSlice::Ipv4(_)),
                    "ICMPv4 is only allowed in IPv4 packets"
                );

                Icmpv4Slice::from_slice(ip.payload().payload).with_context(|| {
                    format!("Failed to parse ICMPv4 packet; src IP = {src_ip}, dst IP = {dst_ip}")
                })?;
            }
            IpNumber::IPV6_ICMP => {
                anyhow::ensure!(
                    matches!(ip, IpSlice::Ipv6(_)),
                    "ICMPv6 is only allowed in IPv6 packets"
                );

                Icmpv6Slice::from_slice(ip.payload().payload).with_context(|| {
                    format!("Failed to parse ICMPv6 packet; src IP = {src_ip}, dst IP = {dst_ip}")
                })?;
            }
            _ => {}
        };
        let version = match ip {
            IpSlice::Ipv4(_) => IpVersion::V4,
            IpSlice::Ipv6(_) => IpVersion::V6,
        };
        let ip_header_length = match ip {
            IpSlice::Ipv4(ipv4) => {
                ipv4.header().ihl() as usize * 4
                    + ipv4.extensions().auth.map_or(0, |ext| ext.slice().len())
            }
            IpSlice::Ipv6(ipv6) => ipv6.header().header_len() + ipv6.extensions().slice().len(),
        };

        Ok(Self {
            buf: buf.inner,
            len,
            version,
            ip_header_length,
        })
    }

    pub fn version(&self) -> IpVersion {
        self.version
    }

    pub fn source(&self) -> IpAddr {
        match self.version {
            IpVersion::V4 => self.as_ipv4_unchecked().header().source_addr().into(),
            IpVersion::V6 => self.as_ipv6_unchecked().header().source_addr().into(),
        }
    }

    pub fn destination(&self) -> IpAddr {
        match self.version {
            IpVersion::V4 => self.as_ipv4_unchecked().header().destination_addr().into(),
            IpVersion::V6 => self.as_ipv6_unchecked().header().destination_addr().into(),
        }
    }

    pub fn source_protocol(&self) -> Result<Protocol, UnsupportedProtocol> {
        if let Some(p) = self.as_tcp() {
            return Ok(Protocol::Tcp(p.source_port()));
        }

        if let Some(p) = self.as_udp() {
            return Ok(Protocol::Udp(p.source_port()));
        }

        if let Some(p) = self.as_icmpv4() {
            let id = self
                .icmpv4_echo_header()
                .ok_or_else(|| UnsupportedProtocol::UnsupportedIcmpv4Type(p.icmp_type()))?
                .id;

            return Ok(Protocol::IcmpEcho(id));
        }

        if let Some(p) = self.as_icmpv6() {
            let id = self
                .icmpv6_echo_header()
                .ok_or_else(|| UnsupportedProtocol::UnsupportedIcmpv6Type(p.icmp_type()))?
                .id;

            return Ok(Protocol::IcmpEcho(id));
        }

        Err(UnsupportedProtocol::UnsupportedIpPayload(
            self.next_header(),
        ))
    }

    pub fn destination_protocol(&self) -> Result<Protocol, UnsupportedProtocol> {
        if let Some(p) = self.as_tcp() {
            return Ok(Protocol::Tcp(p.destination_port()));
        }

        if let Some(p) = self.as_udp() {
            return Ok(Protocol::Udp(p.destination_port()));
        }

        if let Some(p) = self.as_icmpv4() {
            let id = self
                .icmpv4_echo_header()
                .ok_or_else(|| UnsupportedProtocol::UnsupportedIcmpv4Type(p.icmp_type()))?
                .id;

            return Ok(Protocol::IcmpEcho(id));
        }

        if let Some(p) = self.as_icmpv6() {
            let id = self
                .icmpv6_echo_header()
                .ok_or_else(|| UnsupportedProtocol::UnsupportedIcmpv6Type(p.icmp_type()))?
                .id;

            return Ok(Protocol::IcmpEcho(id));
        }

        Err(UnsupportedProtocol::UnsupportedIpPayload(
            self.next_header(),
        ))
    }

    pub fn layer4_payload_len(&self) -> usize {
        if let Some(tcp) = self.as_tcp() {
            return tcp.payload().len();
        }

        if let Some(udp) = self.as_udp() {
            return udp.payload().len();
        }

        if let Some(icmpv4) = self.as_icmpv4() {
            return icmpv4.payload().len();
        }

        if let Some(icmpv6) = self.as_icmpv6() {
            return icmpv6.payload().len();
        }

        self.payload().len()
    }

    pub fn set_source_protocol(&mut self, v: u16) {
        if let Some(mut p) = self.as_tcp_mut() {
            p.set_source_port(v);
        }

        if let Some(mut p) = self.as_udp_mut() {
            p.set_source_port(v);
        }

        self.set_icmp_identifier(v);
    }

    pub fn set_destination_protocol(&mut self, v: u16) {
        if let Some(mut p) = self.as_tcp_mut() {
            p.set_destination_port(v);
        }

        if let Some(mut p) = self.as_udp_mut() {
            p.set_destination_port(v);
        }

        self.set_icmp_identifier(v);
    }

    fn set_icmp_identifier(&mut self, v: u16) {
        if let Some(icmpv4) = self.as_icmpv4()
            && matches!(
                icmpv4.icmp_type(),
                Icmpv4Type::EchoRequest(_) | Icmpv4Type::EchoReply(_)
            )
        {
            self.as_icmpv4_mut()
                .expect("Not an ICMPv4 packet")
                .set_identifier(v);
        }

        if let Some(icmpv6) = self.as_icmpv6()
            && matches!(
                icmpv6.icmp_type(),
                Icmpv6Type::EchoRequest(_) | Icmpv6Type::EchoReply(_)
            )
        {
            self.as_icmpv6_mut()
                .expect("Not an ICMPv6 packet")
                .set_identifier(v);
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

    fn as_ipv4(&self) -> Option<Ipv4Slice<'_>> {
        Ipv4Slice::from_slice(&self.buf[..self.len]).ok()
    }

    fn as_ipv4_header_mut(&mut self) -> Option<Ipv4HeaderSliceMut<'_>> {
        Ipv4HeaderSliceMut::from_slice(&mut self.buf[..self.len]).ok()
    }

    #[expect(clippy::unwrap_used, reason = "The function is marked as `unchecked`.")]
    fn as_ipv4_unchecked(&self) -> Ipv4Slice<'_> {
        self.as_ipv4().unwrap()
    }

    #[expect(clippy::unwrap_used, reason = "The function is marked as `unchecked`.")]
    fn as_ipv4_header_mut_unchecked(&mut self) -> Ipv4HeaderSliceMut<'_> {
        self.as_ipv4_header_mut().unwrap()
    }

    fn as_ipv6(&self) -> Option<Ipv6Slice<'_>> {
        Ipv6Slice::from_slice(&self.buf[..self.len]).ok()
    }

    fn as_ipv6_header_mut(&mut self) -> Option<Ipv6HeaderSliceMut<'_>> {
        Ipv6HeaderSliceMut::from_slice(&mut self.buf[..self.len]).ok()
    }

    #[expect(clippy::unwrap_used, reason = "The function is marked as `unchecked`.")]
    fn as_ipv6_unchecked(&self) -> Ipv6Slice<'_> {
        self.as_ipv6().unwrap()
    }

    #[expect(clippy::unwrap_used, reason = "The function is marked as `unchecked`.")]
    fn as_ipv6_header_mut_unchecked(&mut self) -> Ipv6HeaderSliceMut<'_> {
        self.as_ipv6_header_mut().unwrap()
    }

    fn set_ipv4_checksum(&mut self) {
        let Some(p) = self.as_ipv4() else {
            return;
        };

        let checksum = p.header().to_header().calc_header_checksum();
        self.as_ipv4_header_mut_unchecked().set_checksum(checksum);
    }

    pub fn calculate_udp_checksum(&self) -> Result<u16, ChecksummingFailed> {
        let udp = self
            .as_udp()
            .ok_or(ChecksummingFailed::UnexpectedProtocol { protocol: "udp" })?;

        let checksum = match self.version {
            IpVersion::V4 => udp.to_header().calc_checksum_ipv4(
                &self.as_ipv4_unchecked().header().to_header(),
                udp.payload(),
            ),
            IpVersion::V6 => udp.to_header().calc_checksum_ipv6(
                &self.as_ipv6_unchecked().header().to_header(),
                udp.payload(),
            ),
        }?;

        Ok(checksum)
    }

    fn set_udp_checksum(&mut self) {
        let Ok(checksum) = self.calculate_udp_checksum() else {
            return;
        };

        self.as_udp_mut()
            .expect("Developer error: we can only get a UDP checksum if the packet is udp")
            .set_checksum(checksum);
    }

    pub fn calculate_tcp_checksum(&self) -> Result<u16, ChecksummingFailed> {
        let tcp = self
            .as_tcp()
            .ok_or(ChecksummingFailed::UnexpectedProtocol { protocol: "tcp" })?;

        let checksum = match self.version {
            IpVersion::V4 => tcp.to_header().calc_checksum_ipv4(
                &self.as_ipv4_unchecked().header().to_header(),
                tcp.payload(),
            ),
            IpVersion::V6 => tcp.to_header().calc_checksum_ipv6(
                &self.as_ipv6_unchecked().header().to_header(),
                tcp.payload(),
            ),
        }?;

        Ok(checksum)
    }

    fn set_tcp_checksum(&mut self) {
        let Ok(checksum) = self.calculate_tcp_checksum() else {
            return;
        };

        self.as_tcp_mut()
            .expect("Developer error: we can only get a TCP checksum if the packet is tcp")
            .set_checksum(checksum);
    }

    pub fn as_udp(&self) -> Option<UdpSlice<'_>> {
        if !self.is_udp() {
            return None;
        }

        UdpSlice::from_slice(self.payload()).ok()
    }

    pub fn as_udp_mut(&mut self) -> Option<UdpHeaderSliceMut<'_>> {
        if !self.is_udp() {
            return None;
        }

        UdpHeaderSliceMut::from_slice(self.payload_mut()).ok()
    }

    pub fn as_tcp(&self) -> Option<TcpSlice<'_>> {
        if !self.is_tcp() {
            return None;
        }

        TcpSlice::from_slice(self.payload()).ok()
    }

    pub fn as_tcp_mut(&mut self) -> Option<TcpHeaderSliceMut<'_>> {
        if !self.is_tcp() {
            return None;
        }

        TcpHeaderSliceMut::from_slice(self.payload_mut()).ok()
    }

    fn set_icmpv6_checksum(&mut self) {
        let Some(i) = self.as_icmpv6() else {
            return;
        };

        let ipv6 = self.as_ipv6_unchecked();

        let checksum = i
            .icmp_type()
            .calc_checksum(
                ipv6.header().source_addr().octets(),
                ipv6.header().destination_addr().octets(),
                i.payload(),
            )
            .expect("Payload came from the original packet");

        let Some(mut i) = self.as_icmpv6_mut() else {
            return;
        };

        i.set_checksum(checksum);
    }

    fn set_icmpv4_checksum(&mut self) {
        let Some(i) = self.as_icmpv4() else {
            return;
        };

        let checksum = i.icmp_type().calc_checksum(i.payload());

        let Some(mut i) = self.as_icmpv4_mut() else {
            return;
        };

        i.set_checksum(checksum);
    }

    pub fn as_icmpv4(&self) -> Option<Icmpv4Slice<'_>> {
        if !self.is_icmp() {
            return None;
        }

        Icmpv4Slice::from_slice(self.payload())
            .inspect_err(|e| tracing::debug!("Invalid ICMPv4 packet: {e}"))
            .ok()
    }

    pub fn as_icmpv4_mut(&mut self) -> Option<Icmpv4HeaderSliceMut<'_>> {
        if !self.is_icmp() {
            return None;
        }

        Icmpv4HeaderSliceMut::from_slice(self.payload_mut())
            .inspect_err(|e| tracing::debug!("Invalid ICMPv4 packet: {e}"))
            .ok()
    }

    pub fn icmpv4_payload_mut(&mut self) -> Option<&mut [u8]> {
        let icmpv4_header_len = self.as_icmpv4()?.header_len();
        let (_, payload) = self.payload_mut().split_at_mut_checked(icmpv4_header_len)?;

        Some(payload)
    }

    /// In case the packet is an ICMP error with a failed packet, parses the failed packet from the ICMP payload.
    pub fn icmp_error(&self) -> Result<Option<(FailedPacket, IcmpError)>> {
        if let Some(icmpv4) = self.as_icmpv4() {
            let icmp_type = icmpv4.icmp_type();

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

            let (ipv4, _) = LaxIpv4Slice::from_slice(icmpv4.payload())
                .context("Failed to parse payload of ICMPv4 error message as IPv4 packet")?;
            let header = ipv4.header();

            let src = IpAddr::V4(header.source_addr());
            let failed_dst = IpAddr::V4(header.destination_addr());
            let l4_proto = extract_l4_proto(ipv4.payload().payload, header.protocol())
                .context("Failed to extract protocol")?;

            return Ok(Some((
                FailedPacket {
                    src,
                    failed_dst,
                    l4_proto,
                    raw: icmpv4.payload().to_vec(),
                },
                icmp_error,
            )));
        }

        if let Some(icmpv6) = self.as_icmpv6() {
            let icmp_type = icmpv6.icmp_type();

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

            let (ipv6, _) = LaxIpv6Slice::from_slice(icmpv6.payload())
                .context("Failed to parse payload of ICMPv6 error message as IPv6 packet")?;
            let header = ipv6.header();

            let src = IpAddr::V6(header.source_addr());
            let failed_dst = IpAddr::V6(header.destination_addr());
            let l4_proto = extract_l4_proto(ipv6.payload().payload, header.next_header())
                .context("Failed to extract protocol")?;

            return Ok(Some((
                FailedPacket {
                    src,
                    failed_dst,
                    l4_proto,
                    raw: icmpv6.payload().to_vec(),
                },
                icmp_error,
            )));
        }

        Ok(None)
    }

    pub fn as_icmpv6(&self) -> Option<Icmpv6Slice<'_>> {
        if !self.is_icmpv6() {
            return None;
        }

        Icmpv6Slice::from_slice(self.payload()).ok()
    }

    pub fn as_icmpv6_mut(&mut self) -> Option<Icmpv6EchoHeaderSliceMut<'_>> {
        if !self.is_icmpv6() {
            return None;
        }

        Icmpv6EchoHeaderSliceMut::from_slice(self.payload_mut()).ok()
    }

    pub fn as_fz_p2p_control(&self) -> Option<FzP2pControlSlice<'_>> {
        if !self.is_fz_p2p_control() {
            return None;
        }

        FzP2pControlSlice::from_slice(self.payload()).ok()
    }

    fn icmpv4_echo_header(&self) -> Option<IcmpEchoHeader> {
        let p = self.as_icmpv4()?;

        use Icmpv4Type::*;
        let icmp_type = p.icmp_type();

        let (EchoReply(header) | EchoRequest(header)) = icmp_type else {
            return None;
        };

        Some(header)
    }

    fn icmpv6_echo_header(&self) -> Option<IcmpEchoHeader> {
        let p = self.as_icmpv6()?;

        use Icmpv6Type::*;
        let icmp_type = p.icmp_type();

        let (EchoReply(header) | EchoRequest(header)) = icmp_type else {
            return None;
        };

        Some(header)
    }

    pub fn translate_destination(&mut self, src_proto: Protocol, dst: IpAddr) -> Result<()> {
        self.set_dst(dst)?;
        self.set_source_protocol(src_proto.value());

        Ok(())
    }

    pub fn translate_source(&mut self, dst_proto: Protocol, src: IpAddr) -> Result<()> {
        self.set_src(src)?;
        self.set_destination_protocol(dst_proto.value());

        Ok(())
    }

    #[inline]
    pub fn set_dst(&mut self, dst: IpAddr) -> Result<()> {
        match dst {
            IpAddr::V4(addr) => self
                .as_ipv4_header_mut()
                .context("Not an IPv4 packet")?
                .set_destination(addr.octets()),
            IpAddr::V6(addr) => self
                .as_ipv6_header_mut()
                .context("Not an IPv6 packet")?
                .set_destination(addr.octets()),
        }

        Ok(())
    }

    #[inline]
    pub fn set_src(&mut self, src: IpAddr) -> Result<()> {
        match src {
            IpAddr::V4(addr) => self
                .as_ipv4_header_mut()
                .context("Not an IPv4 packet")?
                .set_source(addr.octets()),
            IpAddr::V6(addr) => self
                .as_ipv6_header_mut()
                .context("Not an IPv6 packet")?
                .set_source(addr.octets()),
        }

        Ok(())
    }

    /// Updates the ECN flags of this packet with the ECN value from the transport layer.
    ///
    /// After tunneling an IP packet, we need to merge the ECN flags from the transport layer with the ones already set on the IP packet.
    /// Essentially, the only time we need to update the ECN flags is:
    /// - if the IP packet signalled an ECN-capable transport (i.e. the originating network stack is ECN-capable)
    /// - and we have experienced congestion along the way (i.e. the provided ECN value is [`Ecn::Ce`]).
    pub fn with_ecn_from_transport(self, ecn: Ecn) -> Self {
        use Ecn::*;

        let ecn = match (self.ecn(), ecn) {
            (NonEct, NonEct) | (Ect1, Ect1) | (Ect0, Ect0) | (Ce, Ce) => {
                // No change needed
                return self;
            }
            (NonEct, Ect0 | Ect1 | Ce) => {
                // Packet sender is not ECN-capable, ignore any update.
                return self;
            }
            (Ect1 | Ect0 | Ce, NonEct) | (Ce, Ect0 | Ect1) => {
                // We already have ECN information, refuse to clear it.
                return self;
            }
            (Ect1, Ect0) | (Ect0, Ect1) => {
                // Don't switch between ECT0 and ECT1, they are equivalent.
                return self;
            }
            (Ect1, Ce) | (Ect0, Ce) => {
                // ECN-capable transport has been signalled and our update is CE, update it!
                Ce
            }
        };

        self.with_ecn(ecn)
    }

    /// Applies the raw ECN value.
    ///
    /// This is most likely not what you want unless you know what you're doing or you are writing a test.
    fn with_ecn(mut self, ecn: Ecn) -> Self {
        match &mut self.version {
            IpVersion::V4 => self.as_ipv4_header_mut_unchecked().set_ecn(ecn as u8),
            IpVersion::V6 => self.as_ipv6_header_mut_unchecked().set_ecn(ecn as u8),
        }
        self.update_checksum();

        self
    }

    pub fn ecn(&self) -> Ecn {
        let byte = match self.version {
            IpVersion::V4 => self.as_ipv4_unchecked().header().ecn().value(),
            IpVersion::V6 => self.as_ipv6_unchecked().header().traffic_class(),
        };

        match byte & 0b00000011 {
            0b00000000 => Ecn::NonEct,
            0b00000001 => Ecn::Ect1,
            0b00000010 => Ecn::Ect0,
            0b00000011 => Ecn::Ce,
            _ => unreachable!(),
        }
    }

    pub fn ipv4_header(&self) -> Option<Ipv4Header> {
        Some(self.as_ipv4()?.header().to_header())
    }

    pub fn ipv6_header(&self) -> Option<Ipv6Header> {
        Some(self.as_ipv6()?.header().to_header())
    }

    pub fn next_header(&self) -> IpNumber {
        match self.version {
            IpVersion::V4 => self.as_ipv4_unchecked().payload_ip_number(),
            IpVersion::V6 => self.as_ipv6_unchecked().payload().ip_number,
        }
    }

    pub fn is_udp(&self) -> bool {
        self.next_header() == IpNumber::UDP
    }

    pub fn is_tcp(&self) -> bool {
        self.next_header() == IpNumber::TCP
    }

    pub fn is_icmp(&self) -> bool {
        self.next_header() == IpNumber::ICMP
    }

    /// Whether the packet is a Firezone p2p control protocol packet.
    pub fn is_fz_p2p_control(&self) -> bool {
        self.next_header() == fz_p2p_control::IP_NUMBER
            && self.source() == fz_p2p_control::ADDR
            && self.destination() == fz_p2p_control::ADDR
    }

    pub fn is_icmpv6(&self) -> bool {
        self.next_header() == IpNumber::IPV6_ICMP
    }

    pub fn packet(&self) -> &[u8] {
        &self.buf[..self.len]
    }

    pub fn payload(&self) -> &[u8] {
        &self.buf[self.ip_header_length..self.len]
    }

    fn payload_mut(&mut self) -> &mut [u8] {
        &mut self.buf[self.ip_header_length..self.len]
    }
}

#[derive(Debug, thiserror::Error)]
#[error("Fragmented IP packets are unsupported")]
pub struct Fragmented;

fn extract_l4_proto(payload: &[u8], protocol: IpNumber) -> Result<Layer4Protocol> {
    // ICMP messages SHOULD always contain at least 8 bytes of the original L4 payload.
    let (src_port, remaining) = payload
        .split_first_chunk::<2>()
        .context("Payload is not long enough for src port")?;
    let (dst_port, _) = remaining
        .split_first_chunk::<2>()
        .context("Payload is not long enough for dst port")?;

    let proto = match protocol {
        IpNumber::UDP => Layer4Protocol::Udp {
            src: u16::from_be_bytes(*src_port),
            dst: u16::from_be_bytes(*dst_port),
        },
        IpNumber::TCP => Layer4Protocol::Tcp {
            src: u16::from_be_bytes(*src_port),
            dst: u16::from_be_bytes(*dst_port),
        },
        IpNumber::ICMP => {
            let icmp_type = Icmpv4Slice::from_slice(payload)
                .context("Failed to parse payload as ICMPv4")?
                .header()
                .icmp_type;

            let Icmpv4Type::EchoRequest(echo_header) = icmp_type else {
                bail!("Original packet was not any ICMP echo request but {icmp_type:?}")
            };

            Layer4Protocol::Icmp {
                seq: echo_header.seq,
                id: echo_header.id,
            }
        }
        IpNumber::IPV6_ICMP => {
            let icmp_type = Icmpv6Slice::from_slice(payload)
                .context("Failed to parse payload as ICMPv6")?
                .header()
                .icmp_type;

            let Icmpv6Type::EchoRequest(echo_header) = icmp_type else {
                bail!("Original packet was not any ICMP echo request but {icmp_type:?}")
            };

            Layer4Protocol::Icmp {
                seq: echo_header.seq,
                id: echo_header.id,
            }
        }
        other => {
            bail!("Unsupported protocol: {:?}", other.keyword_str())
        }
    };
    Ok(proto)
}

#[derive(Debug, thiserror::Error)]
pub enum ChecksummingFailed {
    #[error("Not a {protocol} packet")]
    UnexpectedProtocol { protocol: &'static str },
    #[error(transparent)]
    ValueTooBig(#[from] ValueTooBigError<usize>),
}

/// Models the possible ECN states.
///
/// See <https://www.rfc-editor.org/rfc/rfc3168#section-23.1> for details.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
#[cfg_attr(feature = "arbitrary", derive(arbitrary::Arbitrary))]
pub enum Ecn {
    NonEct = 0b00,
    Ect1 = 0b01,
    Ect0 = 0b10,
    Ce = 0b11,
}

#[derive(Debug, thiserror::Error)]
pub enum UnsupportedProtocol {
    #[error("Unsupported IP protocol: {0:?}")]
    UnsupportedIpPayload(IpNumber),
    #[error("Unsupported ICMPv4 type: {0:?}")]
    UnsupportedIcmpv4Type(Icmpv4Type),
    #[error("Unsupported ICMPv6 type: {0:?}")]
    UnsupportedIcmpv6Type(Icmpv6Type),
}

#[derive(Debug, thiserror::Error)]
#[error("Packet cannot be translated as part of NAT64/46")]
pub struct ImpossibleTranslation;

#[cfg(test)]
mod tests {
    use std::net::{Ipv4Addr, Ipv6Addr};

    use super::*;

    #[test]
    fn udp_packet_payload() {
        let udp_packet = crate::make::udp_packet(
            Ipv4Addr::LOCALHOST,
            Ipv4Addr::LOCALHOST,
            0,
            0,
            b"foobar".to_vec(),
        )
        .unwrap();

        let ip_payload = udp_packet.payload();
        let udp_payload = &ip_payload[etherparse::UdpHeader::LEN..];

        assert_eq!(udp_payload, b"foobar");
    }

    #[test]
    fn ipv4_ecn() {
        let p = crate::make::udp_packet(Ipv4Addr::LOCALHOST, Ipv4Addr::LOCALHOST, 0, 0, vec![])
            .unwrap();

        assert_eq!(p.clone().with_ecn(Ecn::NonEct).ecn(), Ecn::NonEct);
        assert_eq!(p.clone().with_ecn(Ecn::Ect0).ecn(), Ecn::Ect0);
        assert_eq!(p.clone().with_ecn(Ecn::Ect1).ecn(), Ecn::Ect1);
        assert_eq!(p.with_ecn(Ecn::Ce).ecn(), Ecn::Ce);
    }

    #[test]
    fn ipv6_ecn() {
        let p = crate::make::udp_packet(Ipv6Addr::LOCALHOST, Ipv6Addr::LOCALHOST, 0, 0, vec![])
            .unwrap();

        assert_eq!(p.clone().with_ecn(Ecn::NonEct).ecn(), Ecn::NonEct);
        assert_eq!(p.clone().with_ecn(Ecn::Ect1).ecn(), Ecn::Ect1);
        assert_eq!(p.clone().with_ecn(Ecn::Ect0).ecn(), Ecn::Ect0);
        assert_eq!(p.with_ecn(Ecn::Ce).ecn(), Ecn::Ce);
    }

    #[test]
    fn ip4_checksum_after_ecn_is_correct() {
        let p = crate::make::udp_packet(Ipv4Addr::LOCALHOST, Ipv4Addr::LOCALHOST, 0, 0, vec![])
            .unwrap();

        let p_with_ecn = p.with_ecn(Ecn::Ect0);
        let ip4_header = p_with_ecn.ipv4_header().unwrap();

        assert_eq!(
            ip4_header.header_checksum,
            ip4_header.calc_header_checksum()
        );
    }

    #[test]
    fn ecn_from_transport_happy_path() {
        let p = crate::make::udp_packet(Ipv4Addr::LOCALHOST, Ipv4Addr::LOCALHOST, 0, 0, vec![])
            .unwrap()
            .with_ecn(Ecn::Ect0);

        let p_with_ce = p.with_ecn_from_transport(Ecn::Ce);

        assert_eq!(p_with_ce.ecn(), Ecn::Ce);
    }

    #[test]
    fn ecn_from_transport_no_clear_ect() {
        let p = crate::make::udp_packet(Ipv4Addr::LOCALHOST, Ipv4Addr::LOCALHOST, 0, 0, vec![])
            .unwrap()
            .with_ecn(Ecn::Ect0);

        let p_with_ce = p.with_ecn_from_transport(Ecn::NonEct);

        assert_eq!(p_with_ce.ecn(), Ecn::Ect0);
    }

    /// The `as_` functions must be _fast_ because they are being called a lot across `connlib`.
    /// Returning an `anyhow::Error` is detrimential for performance because `anyhow` captures
    /// a stacktrace on each error creation.
    ///
    /// We have this test so we don't forget this.
    ///
    /// One possibility for the future might be to use dedicated `Error` types.
    #[test]
    fn all_as_functions_should_return_option() {
        let mut p = crate::make::udp_packet(Ipv4Addr::LOCALHOST, Ipv4Addr::LOCALHOST, 0, 0, vec![])
            .unwrap();

        let _: Option<_> = p.as_udp();
        let _: Option<_> = p.as_udp_mut();
        let _: Option<_> = p.as_tcp();
        let _: Option<_> = p.as_tcp_mut();
        let _: Option<_> = p.as_icmpv4();
        let _: Option<_> = p.as_icmpv4_mut();
        let _: Option<_> = p.as_icmpv6();
        let _: Option<_> = p.as_icmpv6_mut();
        let _: Option<_> = p.as_fz_p2p_control();
    }

    #[test]
    fn src_is_updated() {
        let mut p = crate::make::udp_packet(Ipv4Addr::LOCALHOST, Ipv4Addr::LOCALHOST, 0, 0, vec![])
            .unwrap();

        p.set_src(IpAddr::V4(Ipv4Addr::new(1, 1, 1, 1))).unwrap();

        assert_eq!(p.source(), IpAddr::V4(Ipv4Addr::new(1, 1, 1, 1)));
    }

    #[test]
    fn dst_is_updated() {
        let mut p = crate::make::udp_packet(Ipv4Addr::LOCALHOST, Ipv4Addr::LOCALHOST, 0, 0, vec![])
            .unwrap();

        p.set_dst(IpAddr::V4(Ipv4Addr::new(1, 1, 1, 1))).unwrap();

        assert_eq!(p.destination(), IpAddr::V4(Ipv4Addr::new(1, 1, 1, 1)));
    }
}
