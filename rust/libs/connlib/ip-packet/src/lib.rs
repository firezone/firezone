#![cfg_attr(test, allow(clippy::unwrap_used))]

pub mod make;

mod checksum;
mod fz_p2p_control;
mod fz_p2p_control_slice;
mod icmp;
mod icmp_error;
mod slices;

#[cfg(feature = "proptest")]
#[allow(clippy::unwrap_used)]
pub mod proptest;

pub use fz_p2p_control::EventType as FzP2pEventType;
pub use fz_p2p_control_slice::FzP2pControlSlice;
pub use icmp::{IcmpEchoHeader, Icmpv4Type, Icmpv6Type, icmpv4, icmpv6};
pub use icmp_error::{FailedPacket, IcmpError};
pub use ingot::ip::IpProtocol;
// TODO: Temporary alias to keep the `IpNumber` name in downstream crates and
// minimise churn; remove once call-sites are renamed to `IpProtocol`.
pub use ingot::ip::IpProtocol as IpNumber;
pub use slices::{
    Icmpv4Slice, Icmpv4SliceMut, Icmpv6Slice, Icmpv6SliceMut, Ipv4HeaderSlice, Ipv6HeaderSlice,
    TcpSlice, TcpSliceMut, UdpSlice, UdpSliceMut,
};

use anyhow::{Context as _, Result, bail};
use bufferpool::{Buffer, BufferPool};
use incremental_inet_checksum::ChecksumUpdate;
use ingot::icmp::{ValidIcmpV4, ValidIcmpV6};
use ingot::ip::{
    IpV6ExtFragmentRef, Ipv4Flags, Ipv4Mut, Ipv4Ref, Ipv6Mut, Ipv6Ref, ValidIpv4, ValidIpv6,
    ValidLowRentV6Eh,
};
use ingot::tcp::{TcpRef, ValidTcp};
use ingot::types::{HeaderLen as _, HeaderParse as _, NextLayer as _};
use ingot::udp::{UdpRef, ValidUdp};
use std::net::IpAddr;
use std::sync::LazyLock;

static BUFFER_POOL: LazyLock<BufferPool<Vec<u8>>> =
    LazyLock::new(|| BufferPool::new(MAX_FZ_PAYLOAD, "ip-packet"));

/// The maximum size of an IP packet we can handle.
pub const MAX_IP_SIZE: usize = 1280;
/// The maximum payload an IP packet can have.
///
/// IPv6 headers are always a fixed size whereas IPv4 headers can vary.
/// The max length of an IPv4 header is > the fixed length of an IPv6 header.
pub const MAX_IP_PAYLOAD: u16 = (MAX_IP_SIZE - Ipv4HeaderSlice::MAX_LEN) as u16;
/// The maximum payload a UDP packet can have.
pub const MAX_UDP_PAYLOAD: u16 = MAX_IP_PAYLOAD - UdpSlice::HEADER_LEN as u16;

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

/// A human-readable name of well-known IP protocols, for logging.
pub fn ip_protocol_name(protocol: IpProtocol) -> Option<&'static str> {
    let name = match protocol {
        IpProtocol::ICMP => "ICMP",
        IpProtocol::IGMP => "IGMP",
        IpProtocol::TCP => "TCP",
        IpProtocol::UDP => "UDP",
        IpProtocol::ICMP_V6 => "IPv6-ICMP",
        IpProtocol(41) => "IPv6",
        IpProtocol(47) => "GRE",
        IpProtocol(50) => "ESP",
        IpProtocol(51) => "AH",
        IpProtocol(132) => "SCTP",
        _ => return None,
    };

    Some(name)
}

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
    len: usize,

    /// Offset of the transport-layer header within the buffer.
    ///
    /// For IPv6, this includes any extension headers.
    ip_header_length: usize,
    transport: Transport,
    version: IpVersion,
}

/// The transport protocol of an [`IpPacket`], determined and validated on creation.
///
/// For the first four variants, the transport header (and its length field, where
/// the protocol has one) is known to be consistent with the packet length, so
/// views over the transport layer can be created without further checks.
#[derive(Debug, PartialEq, Clone, Copy)]
enum Transport {
    Udp,
    Tcp,
    Icmpv4,
    Icmpv6,
    Other(IpProtocol),
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
                &ip_protocol_name(self.next_header()).unwrap_or("unknown"),
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
    /// Parses and validates the first `len` bytes of `buf` as an IP packet.
    ///
    /// All layout invariants are checked here, once: header lengths and length
    /// fields must be consistent with `len` all the way through the transport
    /// layer. Accessors on the returned packet rely on these invariants and
    /// don't re-validate.
    pub fn new(buf: IpPacketBuf, len: usize) -> Result<Self> {
        anyhow::ensure!(len <= MAX_IP_SIZE, "Packet too large (len: {len})");
        anyhow::ensure!(len <= buf.inner.len(), "Length exceeds buffer size");

        let packet = &buf.inner[..len];

        let (version, ip_header_length, protocol) = match packet.first().map(|b| b >> 4) {
            Some(4) => {
                let (header, _, _) =
                    ValidIpv4::parse(packet).context("Failed to parse IPv4 header")?;

                anyhow::ensure!(header.ihl() >= 5, "IPv4 IHL must be at least 5");
                anyhow::ensure!(
                    header.total_len() as usize == len,
                    "IPv4 total length ({}) does not match packet length ({len})",
                    header.total_len()
                );
                anyhow::ensure!(
                    !header.flags().contains(Ipv4Flags::MORE_FRAGMENTS)
                        && header.fragment_offset() == 0,
                    Fragmented
                );

                (IpVersion::V4, 4 * header.ihl() as usize, header.protocol())
            }
            Some(6) => {
                let (header, _, _) =
                    ValidIpv6::parse(packet).context("Failed to parse IPv6 header")?;

                anyhow::ensure!(
                    header.payload_len() as usize + Ipv6HeaderSlice::LEN == len,
                    "IPv6 payload length ({}) does not match packet length ({len})",
                    header.payload_len()
                );
                anyhow::ensure!(!ipv6_is_fragmenting(&header), Fragmented);

                let protocol = header
                    .next_layer()
                    .context("Failed to determine transport protocol of IPv6 packet")?;

                (IpVersion::V6, header.packet_length(), protocol)
            }
            Some(version) => bail!("Unsupported IP version: {version}"),
            None => bail!("Empty packet"),
        };

        let l4 = &packet[ip_header_length..];

        let transport = match (version, protocol) {
            (_, IpProtocol::UDP) => {
                let (udp, _, _) = ValidUdp::parse(l4).context("Failed to parse UDP header")?;

                anyhow::ensure!(
                    udp.length() as usize == l4.len(),
                    "UDP length ({}) does not match length of IP payload ({})",
                    udp.length(),
                    l4.len()
                );

                Transport::Udp
            }
            (_, IpProtocol::TCP) => {
                let (tcp, _, _) = ValidTcp::parse(l4).context("Failed to parse TCP header")?;

                anyhow::ensure!(tcp.data_offset() >= 5, "TCP data offset must be at least 5");

                Transport::Tcp
            }
            (IpVersion::V4, IpProtocol::ICMP) => {
                ValidIcmpV4::parse(l4).context("Failed to parse ICMPv4 header")?;

                Transport::Icmpv4
            }
            (IpVersion::V6, IpProtocol::ICMP_V6) => {
                ValidIcmpV6::parse(l4).context("Failed to parse ICMPv6 header")?;

                Transport::Icmpv6
            }
            (IpVersion::V6, IpProtocol::ICMP) => {
                bail!("ICMPv4 is only allowed in IPv4 packets")
            }
            (IpVersion::V4, IpProtocol::ICMP_V6) => {
                bail!("ICMPv6 is only allowed in IPv6 packets")
            }
            (_, other) => Transport::Other(other),
        };

        Ok(Self {
            buf: buf.inner,
            len,
            ip_header_length,
            transport,
            version,
        })
    }

    pub fn version(&self) -> IpVersion {
        self.version
    }

    pub fn source(&self) -> IpAddr {
        match self.version {
            IpVersion::V4 => IpAddr::V4(std::net::Ipv4Addr::from(
                self.ipv4_header_unchecked().source(),
            )),
            IpVersion::V6 => IpAddr::V6(std::net::Ipv6Addr::from(
                self.ipv6_header_unchecked().source(),
            )),
        }
    }

    pub fn destination(&self) -> IpAddr {
        match self.version {
            IpVersion::V4 => IpAddr::V4(std::net::Ipv4Addr::from(
                self.ipv4_header_unchecked().destination(),
            )),
            IpVersion::V6 => IpAddr::V6(std::net::Ipv6Addr::from(
                self.ipv6_header_unchecked().destination(),
            )),
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
        match self.transport {
            Transport::Udp => self.payload().len() - UdpSlice::HEADER_LEN,
            Transport::Tcp => self.as_tcp_unchecked().payload().len(),
            Transport::Icmpv4 | Transport::Icmpv6 => self.payload().len() - Icmpv4Slice::HEADER_LEN,
            Transport::Other(_) => self.payload().len(),
        }
    }

    pub fn set_source_protocol(&mut self, v: u16) {
        if let Some(mut p) = self.as_tcp_mut() {
            let checksum = ChecksumUpdate::new(p.get_checksum())
                .remove_u16(p.get_source_port())
                .add_u16(v)
                .into_ip_checksum();

            p.set_source_port(v);
            p.set_checksum(checksum);
        }

        if let Some(mut p) = self.as_udp_mut() {
            let checksum = ChecksumUpdate::new(p.get_checksum())
                .remove_u16(p.get_source_port())
                .add_u16(v)
                .into_udp_checksum();

            p.set_source_port(v);
            set_udp_checksum_if_computed(&mut p, checksum);
        }

        self.set_icmp_identifier(v);
    }

    pub fn set_destination_protocol(&mut self, v: u16) {
        if let Some(mut p) = self.as_tcp_mut() {
            let checksum = ChecksumUpdate::new(p.get_checksum())
                .remove_u16(p.get_destination_port())
                .add_u16(v)
                .into_ip_checksum();

            p.set_destination_port(v);
            p.set_checksum(checksum);
        }

        if let Some(mut p) = self.as_udp_mut() {
            let checksum = ChecksumUpdate::new(p.get_checksum())
                .remove_u16(p.get_destination_port())
                .add_u16(v)
                .into_udp_checksum();

            p.set_destination_port(v);
            set_udp_checksum_if_computed(&mut p, checksum);
        }

        self.set_icmp_identifier(v);
    }

    fn set_icmp_identifier(&mut self, v: u16) {
        if let Some(mut p) = self.as_icmpv4_mut()
            && p.is_echo_request_or_reply()
        {
            let checksum = ChecksumUpdate::new(p.get_checksum())
                .remove_u16(p.get_identifier())
                .add_u16(v)
                .into_ip_checksum();

            p.set_identifier(v);
            p.set_checksum(checksum);
        }

        if let Some(mut p) = self.as_icmpv6_mut()
            && p.is_echo_request_or_reply()
        {
            let checksum = ChecksumUpdate::new(p.get_checksum())
                .remove_u16(p.get_identifier())
                .add_u16(v)
                .into_ip_checksum();

            p.set_identifier(v);
            p.set_checksum(checksum);
        }
    }

    /// Computes all checksums of this packet from scratch.
    ///
    /// The mutators on [`IpPacket`] maintain checksums incrementally, so regular packet
    /// processing never needs this. It exists for packets whose bytes were serialized by
    /// an external stack: smoltcp emits TCP segments with incorrect checksums through our
    /// in-memory device, so `l3-tcp` has to finalize them with a full computation.
    pub fn compute_checksums(&mut self) {
        // Note: ipv6 doesn't have a checksum.
        self.set_icmpv6_checksum();
        self.set_icmpv4_checksum();
        self.set_udp_checksum();
        self.set_tcp_checksum();
        // Note: Ipv4 checksum should be set after the others,
        // since it's in an upper layer.
        self.set_ipv4_checksum();
    }

    /// Patches all transport checksums that cover the IP pseudo-header.
    ///
    /// `patch` receives the running update of each affected checksum and must apply the
    /// diff of the changed pseudo-header words to it. ICMPv4 is deliberately absent:
    /// its checksum does not cover a pseudo-header, so address changes don't affect it.
    fn patch_pseudo_header_checksums(&mut self, patch: impl Fn(ChecksumUpdate) -> ChecksumUpdate) {
        if let Some(mut p) = self.as_tcp_mut() {
            let checksum = patch(ChecksumUpdate::new(p.get_checksum())).into_ip_checksum();
            p.set_checksum(checksum);
        }

        if let Some(mut p) = self.as_udp_mut() {
            let checksum = patch(ChecksumUpdate::new(p.get_checksum())).into_udp_checksum();
            set_udp_checksum_if_computed(&mut p, checksum);
        }

        if let Some(mut p) = self.as_icmpv6_mut() {
            let checksum = patch(ChecksumUpdate::new(p.get_checksum())).into_ip_checksum();
            p.set_checksum(checksum);
        }
    }

    #[expect(
        clippy::unwrap_used,
        reason = "Packet layout was validated on creation."
    )]
    fn ipv4_header_unchecked(&self) -> ValidIpv4<&[u8]> {
        debug_assert!(matches!(self.version, IpVersion::V4));

        let (header, _, _) = ValidIpv4::parse(self.packet()).unwrap();

        header
    }

    #[expect(
        clippy::unwrap_used,
        reason = "Packet layout was validated on creation."
    )]
    fn ipv4_header_mut_unchecked(&mut self) -> ValidIpv4<&mut [u8]> {
        debug_assert!(matches!(self.version, IpVersion::V4));

        let (header, _, _) = ValidIpv4::parse(&mut self.buf[..self.len]).unwrap();

        header
    }

    #[expect(
        clippy::unwrap_used,
        reason = "Packet layout was validated on creation."
    )]
    fn ipv6_header_unchecked(&self) -> ValidIpv6<&[u8]> {
        debug_assert!(matches!(self.version, IpVersion::V6));

        let (header, _, _) = ValidIpv6::parse(self.packet()).unwrap();

        header
    }

    #[expect(
        clippy::unwrap_used,
        reason = "Packet layout was validated on creation."
    )]
    fn ipv6_header_mut_unchecked(&mut self) -> ValidIpv6<&mut [u8]> {
        debug_assert!(matches!(self.version, IpVersion::V6));

        let (header, _, _) = ValidIpv6::parse(&mut self.buf[..self.len]).unwrap();

        header
    }

    fn set_ipv4_checksum(&mut self) {
        if !matches!(self.version, IpVersion::V4) {
            return;
        }

        let checksum = checksum::ipv4_header_checksum(&self.packet()[..self.ip_header_length]);

        self.ipv4_header_mut_unchecked().set_checksum(checksum);
    }

    pub fn calculate_udp_checksum(&self) -> Result<u16, ChecksummingFailed> {
        if !self.is_udp() {
            return Err(ChecksummingFailed::UnexpectedProtocol { protocol: "udp" });
        }

        let checksum =
            checksum::l4_checksum(self.pseudo_header_sum(IpProtocol::UDP), self.payload(), 6);

        // RFC 768: a computed checksum of zero is transmitted as all-ones.
        if checksum == 0 {
            return Ok(0xFFFF);
        }

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
        if !self.is_tcp() {
            return Err(ChecksummingFailed::UnexpectedProtocol { protocol: "tcp" });
        }

        let checksum =
            checksum::l4_checksum(self.pseudo_header_sum(IpProtocol::TCP), self.payload(), 16);

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

    pub fn calculate_icmpv4_checksum(&self) -> Result<u16, ChecksummingFailed> {
        if !self.is_icmp() {
            return Err(ChecksummingFailed::UnexpectedProtocol { protocol: "icmpv4" });
        }

        // The ICMPv4 checksum does not cover a pseudo-header.
        Ok(checksum::l4_checksum(0, self.payload(), 2))
    }

    pub fn calculate_icmpv6_checksum(&self) -> Result<u16, ChecksummingFailed> {
        if !self.is_icmpv6() {
            return Err(ChecksummingFailed::UnexpectedProtocol { protocol: "icmpv6" });
        }

        let checksum = checksum::l4_checksum(
            self.pseudo_header_sum(IpProtocol::ICMP_V6),
            self.payload(),
            2,
        );

        Ok(checksum)
    }

    /// Recomputes the IPv4 header checksum of this packet.
    pub fn calculate_ipv4_header_checksum(&self) -> Result<u16, ChecksummingFailed> {
        if !matches!(self.version, IpVersion::V4) {
            return Err(ChecksummingFailed::UnexpectedProtocol { protocol: "ipv4" });
        }

        Ok(checksum::ipv4_header_checksum(
            &self.packet()[..self.ip_header_length],
        ))
    }

    fn pseudo_header_sum(&self, protocol: IpProtocol) -> u32 {
        match self.version {
            IpVersion::V4 => {
                let header = self.ipv4_header_unchecked();

                checksum::pseudo_header_v4(
                    header.source().into(),
                    header.destination().into(),
                    protocol,
                    self.payload().len(),
                )
            }
            IpVersion::V6 => {
                let header = self.ipv6_header_unchecked();

                checksum::pseudo_header_v6(
                    header.source().into(),
                    header.destination().into(),
                    protocol,
                    self.payload().len(),
                )
            }
        }
    }

    pub fn as_udp(&self) -> Option<UdpSlice<'_>> {
        if !self.is_udp() {
            return None;
        }

        Some(UdpSlice::from_l4(self.payload()))
    }

    pub fn as_udp_mut(&mut self) -> Option<UdpSliceMut<'_>> {
        if !self.is_udp() {
            return None;
        }

        Some(UdpSliceMut::from_l4(self.payload_mut()))
    }

    pub fn as_tcp(&self) -> Option<TcpSlice<'_>> {
        if !self.is_tcp() {
            return None;
        }

        Some(self.as_tcp_unchecked())
    }

    fn as_tcp_unchecked(&self) -> TcpSlice<'_> {
        TcpSlice::from_l4(self.payload())
    }

    pub fn as_tcp_mut(&mut self) -> Option<TcpSliceMut<'_>> {
        if !self.is_tcp() {
            return None;
        }

        Some(TcpSliceMut::from_l4(self.payload_mut()))
    }

    fn set_icmpv6_checksum(&mut self) {
        let Ok(checksum) = self.calculate_icmpv6_checksum() else {
            return;
        };

        let Some(mut i) = self.as_icmpv6_mut() else {
            return;
        };

        i.set_checksum(checksum);
    }

    fn set_icmpv4_checksum(&mut self) {
        let Ok(checksum) = self.calculate_icmpv4_checksum() else {
            return;
        };

        let Some(mut i) = self.as_icmpv4_mut() else {
            return;
        };

        i.set_checksum(checksum);
    }

    pub fn as_icmpv4(&self) -> Option<Icmpv4Slice<'_>> {
        if !self.is_icmp() {
            return None;
        }

        Some(Icmpv4Slice::from_l4(self.payload()))
    }

    pub fn as_icmpv4_mut(&mut self) -> Option<Icmpv4SliceMut<'_>> {
        if !self.is_icmp() {
            return None;
        }

        Some(Icmpv4SliceMut::from_l4(self.payload_mut()))
    }

    /// In case the packet is an ICMP error with a failed packet, parses the failed packet from the ICMP payload.
    pub fn icmp_error(&self) -> Result<Option<(FailedPacket, IcmpError)>> {
        icmp_error::parse_icmp_error(self)
    }

    pub fn as_icmpv6(&self) -> Option<Icmpv6Slice<'_>> {
        if !self.is_icmpv6() {
            return None;
        }

        Some(Icmpv6Slice::from_l4(self.payload()))
    }

    pub fn as_icmpv6_mut(&mut self) -> Option<Icmpv6SliceMut<'_>> {
        if !self.is_icmpv6() {
            return None;
        }

        Some(Icmpv6SliceMut::from_l4(self.payload_mut()))
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
            IpAddr::V4(addr) => {
                anyhow::ensure!(matches!(self.version, IpVersion::V4), "Not an IPv4 packet");

                let (old, new) = {
                    let mut hdr = self.ipv4_header_mut_unchecked();

                    let old = std::net::Ipv4Addr::from(hdr.destination()).to_bits();
                    let new = addr.to_bits();

                    hdr.set_destination(addr.into());

                    let checksum = ChecksumUpdate::new(hdr.checksum())
                        .remove_u32(old)
                        .add_u32(new)
                        .into_ip_checksum();
                    hdr.set_checksum(checksum);

                    (old, new)
                };

                self.patch_pseudo_header_checksums(|u| u.remove_u32(old).add_u32(new));
            }
            IpAddr::V6(addr) => {
                anyhow::ensure!(matches!(self.version, IpVersion::V6), "Not an IPv6 packet");

                let (old, new) = {
                    let mut hdr = self.ipv6_header_mut_unchecked();

                    let old = std::net::Ipv6Addr::from(hdr.destination()).to_bits();
                    let new = addr.to_bits();

                    hdr.set_destination(addr.into());

                    (old, new)
                };

                self.patch_pseudo_header_checksums(|u| u.remove_u128(old).add_u128(new));
            }
        }

        Ok(())
    }

    #[inline]
    pub fn set_src(&mut self, src: IpAddr) -> Result<()> {
        match src {
            IpAddr::V4(addr) => {
                anyhow::ensure!(matches!(self.version, IpVersion::V4), "Not an IPv4 packet");

                let (old, new) = {
                    let mut hdr = self.ipv4_header_mut_unchecked();

                    let old = std::net::Ipv4Addr::from(hdr.source()).to_bits();
                    let new = addr.to_bits();

                    hdr.set_source(addr.into());

                    let checksum = ChecksumUpdate::new(hdr.checksum())
                        .remove_u32(old)
                        .add_u32(new)
                        .into_ip_checksum();
                    hdr.set_checksum(checksum);

                    (old, new)
                };

                self.patch_pseudo_header_checksums(|u| u.remove_u32(old).add_u32(new));
            }
            IpAddr::V6(addr) => {
                anyhow::ensure!(matches!(self.version, IpVersion::V6), "Not an IPv6 packet");

                let (old, new) = {
                    let mut hdr = self.ipv6_header_mut_unchecked();

                    let old = std::net::Ipv6Addr::from(hdr.source()).to_bits();
                    let new = addr.to_bits();

                    hdr.set_source(addr.into());

                    (old, new)
                };

                self.patch_pseudo_header_checksums(|u| u.remove_u128(old).add_u128(new));
            }
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
        match self.version {
            IpVersion::V4 => {
                // The ECN bits are part of the checksummed word formed by the first two
                // header bytes; the L4 checksums don't cover them.
                let old = u16::from_be_bytes([self.buf[0], self.buf[1]]);
                let new = (old & !0b11) | ecn as u16;

                self.buf[1] = new.to_be_bytes()[1];

                let mut hdr = self.ipv4_header_mut_unchecked();
                let checksum = ChecksumUpdate::new(hdr.checksum())
                    .remove_u16(old)
                    .add_u16(new)
                    .into_ip_checksum();
                hdr.set_checksum(checksum);
            }
            // IPv6 has no header checksum and the traffic class is not part of the
            // pseudo-header, so no checksum needs updating.
            //
            // The ECN bits are the low two bits of the traffic class,
            // which spans the low nibble of the first byte and the high nibble of the second.
            IpVersion::V6 => {
                self.buf[1] = (self.buf[1] & !0b0011_0000) | ((ecn as u8) << 4);
            }
        }

        self
    }

    pub fn ecn(&self) -> Ecn {
        let bits = match self.version {
            IpVersion::V4 => self.buf[1] & 0b11,
            IpVersion::V6 => (self.buf[1] >> 4) & 0b11,
        };

        match bits {
            0b00 => Ecn::NonEct,
            0b01 => Ecn::Ect1,
            0b10 => Ecn::Ect0,
            0b11 => Ecn::Ce,
            _ => unreachable!(),
        }
    }

    pub fn ipv4_header(&self) -> Option<Ipv4HeaderSlice<'_>> {
        if !matches!(self.version, IpVersion::V4) {
            return None;
        }

        Some(Ipv4HeaderSlice::from_packet(self.packet()))
    }

    pub fn ipv6_header(&self) -> Option<Ipv6HeaderSlice<'_>> {
        if !matches!(self.version, IpVersion::V6) {
            return None;
        }

        Some(Ipv6HeaderSlice::from_packet(
            self.packet(),
            self.next_header(),
        ))
    }

    /// The protocol of the transport layer, after any IPv6 extension headers.
    pub fn next_header(&self) -> IpProtocol {
        match self.transport {
            Transport::Udp => IpProtocol::UDP,
            Transport::Tcp => IpProtocol::TCP,
            Transport::Icmpv4 => IpProtocol::ICMP,
            Transport::Icmpv6 => IpProtocol::ICMP_V6,
            Transport::Other(protocol) => protocol,
        }
    }

    pub fn is_udp(&self) -> bool {
        matches!(self.transport, Transport::Udp)
    }

    pub fn is_tcp(&self) -> bool {
        matches!(self.transport, Transport::Tcp)
    }

    pub fn is_icmp(&self) -> bool {
        matches!(self.transport, Transport::Icmpv4)
    }

    /// Whether the packet is a Firezone p2p control protocol packet.
    pub fn is_fz_p2p_control(&self) -> bool {
        self.next_header() == fz_p2p_control::IP_NUMBER
            && self.source() == fz_p2p_control::ADDR
            && self.destination() == fz_p2p_control::ADDR
    }

    pub fn is_icmpv6(&self) -> bool {
        matches!(self.transport, Transport::Icmpv6)
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

/// Whether the packet's extension headers mark it as a fragment of a larger packet.
///
/// A fragment header with offset 0 and the "more fragments" flag unset
/// (an "atomic" fragment) does not fragment the payload.
fn ipv6_is_fragmenting(header: &ValidIpv6<&[u8]>) -> bool {
    use ingot::types::Header;

    let first_protocol = header.next_header();

    let Header::Raw(extensions) = &header.1 else {
        return false;
    };

    extensions.iter(Some(first_protocol)).any(|extension| {
        let Ok(ValidLowRentV6Eh::IpV6ExtFragment(fragment)) = extension else {
            return false;
        };

        fragment.fragment_offset() != 0 || fragment.more_frags() == 1
    })
}

#[derive(Debug, thiserror::Error)]
#[error("Fragmented IP packets are unsupported")]
pub struct Fragmented;

/// Writes `checksum` to the packet unless its current checksum is zero.
///
/// A zero UDP checksum means "not computed" (IPv4); translation must preserve that.
fn set_udp_checksum_if_computed(p: &mut UdpSliceMut<'_>, checksum: u16) {
    if p.get_checksum() == 0 {
        return;
    }

    p.set_checksum(checksum);
}

#[derive(Debug, thiserror::Error)]
pub enum ChecksummingFailed {
    #[error("Not a {protocol} packet")]
    UnexpectedProtocol { protocol: &'static str },
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

#[derive(Debug, Clone, thiserror::Error)]
pub enum UnsupportedProtocol {
    #[error("Unsupported IP protocol: {0:?}")]
    UnsupportedIpPayload(IpProtocol),
    #[error("Unsupported ICMPv4 type: {0:?}")]
    UnsupportedIcmpv4Type(Icmpv4Type),
    #[error("Unsupported ICMPv6 type: {0:?}")]
    UnsupportedIcmpv6Type(Icmpv6Type),
}

#[cfg(test)]
mod tests {
    use std::net::{Ipv4Addr, Ipv6Addr};

    use super::*;

    #[test]
    fn udp_packet_payload() {
        let udp_packet =
            crate::make::udp_packet(Ipv4Addr::LOCALHOST, Ipv4Addr::LOCALHOST, 0, 0, b"foobar")
                .unwrap();

        let ip_payload = udp_packet.payload();
        let udp_payload = &ip_payload[UdpSlice::HEADER_LEN..];

        assert_eq!(udp_payload, b"foobar");
    }

    #[test]
    fn ipv4_ecn() {
        let p =
            crate::make::udp_packet(Ipv4Addr::LOCALHOST, Ipv4Addr::LOCALHOST, 0, 0, &[]).unwrap();

        assert_eq!(p.clone().with_ecn(Ecn::NonEct).ecn(), Ecn::NonEct);
        assert_eq!(p.clone().with_ecn(Ecn::Ect0).ecn(), Ecn::Ect0);
        assert_eq!(p.clone().with_ecn(Ecn::Ect1).ecn(), Ecn::Ect1);
        assert_eq!(p.with_ecn(Ecn::Ce).ecn(), Ecn::Ce);
    }

    #[test]
    fn ipv6_ecn() {
        let p =
            crate::make::udp_packet(Ipv6Addr::LOCALHOST, Ipv6Addr::LOCALHOST, 0, 0, &[]).unwrap();

        assert_eq!(p.clone().with_ecn(Ecn::NonEct).ecn(), Ecn::NonEct);
        assert_eq!(p.clone().with_ecn(Ecn::Ect1).ecn(), Ecn::Ect1);
        assert_eq!(p.clone().with_ecn(Ecn::Ect0).ecn(), Ecn::Ect0);
        assert_eq!(p.with_ecn(Ecn::Ce).ecn(), Ecn::Ce);
    }

    #[test]
    fn ip4_checksum_after_ecn_is_correct() {
        let p =
            crate::make::udp_packet(Ipv4Addr::LOCALHOST, Ipv4Addr::LOCALHOST, 0, 0, &[]).unwrap();

        let p_with_ecn = p.with_ecn(Ecn::Ect0);

        assert_eq!(
            p_with_ecn.ipv4_header().unwrap().checksum(),
            p_with_ecn.calculate_ipv4_header_checksum().unwrap()
        );
    }

    #[test]
    fn ecn_from_transport_happy_path() {
        let p = crate::make::udp_packet(Ipv4Addr::LOCALHOST, Ipv4Addr::LOCALHOST, 0, 0, &[])
            .unwrap()
            .with_ecn(Ecn::Ect0);

        let p_with_ce = p.with_ecn_from_transport(Ecn::Ce);

        assert_eq!(p_with_ce.ecn(), Ecn::Ce);
    }

    #[test]
    fn ecn_from_transport_no_clear_ect() {
        let p = crate::make::udp_packet(Ipv4Addr::LOCALHOST, Ipv4Addr::LOCALHOST, 0, 0, &[])
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
        let mut p =
            crate::make::udp_packet(Ipv4Addr::LOCALHOST, Ipv4Addr::LOCALHOST, 0, 0, &[]).unwrap();

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
        let mut p =
            crate::make::udp_packet(Ipv4Addr::LOCALHOST, Ipv4Addr::LOCALHOST, 0, 0, &[]).unwrap();

        p.set_src(IpAddr::V4(Ipv4Addr::new(1, 1, 1, 1))).unwrap();

        assert_eq!(p.source(), IpAddr::V4(Ipv4Addr::new(1, 1, 1, 1)));
    }

    #[test]
    fn dst_is_updated() {
        let mut p =
            crate::make::udp_packet(Ipv4Addr::LOCALHOST, Ipv4Addr::LOCALHOST, 0, 0, &[]).unwrap();

        p.set_dst(IpAddr::V4(Ipv4Addr::new(1, 1, 1, 1))).unwrap();

        assert_eq!(p.destination(), IpAddr::V4(Ipv4Addr::new(1, 1, 1, 1)));
    }
}
