//! Coalesces individual IP packets into larger packets for writing to a TUN device.
//!
//! The platform backend chooses how the resulting packet is represented: Linux
//! attaches a `virtio_net_hdr` describing segmentation, while Windows submits a
//! fully checksummed TCP super-packet to Wintun.
//!
//! Only packets that the kernel's own GRO would merge are combined, everything else is
//! passed through untouched.

use bufferpool::{Buffer, BufferPool};
use ip_packet::{IpNumber, IpPacket, IpVersion, Ipv6HeaderSlice, TcpSlice, UdpSlice};
use std::net::IpAddr;

use ip_packet::checksum;

/// The maximum size of a coalesced packet.
///
/// IP packets cannot be larger than 65535 bytes (the total-length / payload-length fields
/// are 16 bits wide), and so neither can our super packets.
const MAX_COALESCED_PACKET: usize = u16::MAX as usize;

/// The kernel rejects `VIRTIO_NET_HDR_GSO_UDP_L4` writes with more segments than this
/// (`UDP_MAX_SEGMENTS` in `linux/udp.h`).
const MAX_UDP_SEGMENTS: usize = 128;

const TCP_FLAG_PSH: u8 = 0x08;

/// How transport checksums are represented in a coalesced packet.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ChecksumMode {
    /// Compute the complete transport checksum before handing the packet to the OS.
    Complete,
    /// Leave checksum completion to the receiver of the coalesced packet.
    ///
    /// The transport checksum field contains the folded, uncomplemented pseudo-header
    /// sum described by the returned [`OffloadMetadata`].
    Offloaded,
}

/// A transport protocol whose packets may be coalesced.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Protocol {
    Tcp,
    Udp,
}

/// Coalesces compatible IP packets while preserving per-flow ordering.
pub struct PacketCoalescer {
    /// Queued items, in write order.
    ///
    /// Non-coalescable packets flow through this queue too: a segment may only merge
    /// into the most recent item of its connection, so per-flow ordering is preserved
    /// by construction.
    items: Vec<Item>,
    buffer_pool: BufferPool<Vec<u8>>,
    coalesce_tcp: bool,
    coalesce_udp: bool,
    checksum_mode: ChecksumMode,
}

impl PacketCoalescer {
    /// Builds a coalescer for the selected transport protocols and checksum mode.
    pub fn new(protocols: impl IntoIterator<Item = Protocol>, checksum_mode: ChecksumMode) -> Self {
        let mut coalesce_tcp = false;
        let mut coalesce_udp = false;

        for protocol in protocols {
            match protocol {
                Protocol::Tcp => coalesce_tcp = true,
                Protocol::Udp => coalesce_udp = true,
            }
        }

        Self {
            items: Vec::new(),
            buffer_pool: BufferPool::new(MAX_COALESCED_PACKET, "packet-coalescer"),
            coalesce_tcp,
            coalesce_udp,
            checksum_mode,
        }
    }

    /// Builds a queue that preserves packet boundaries.
    pub fn passthrough() -> Self {
        Self::new([], ChecksumMode::Complete)
    }

    /// Queues a single packet, coalescing it with already queued ones where possible.
    pub fn enqueue(&mut self, packet: IpPacket) {
        let Some(candidate) = Candidate::from_packet(&packet, self.coalesce_tcp, self.coalesce_udp)
        else {
            self.items.push(Item::Packet(packet));
            return;
        };

        // A segment may only merge into the most recent item of its connection;
        // merging into anything older would reorder the flow.
        match self
            .items
            .iter_mut()
            .rev()
            .find(|i| i.same_connection(&packet))
        {
            Some(Item::Batch(batch))
                if batch.key == candidate.key && batch.can_append(&candidate, &packet) =>
            {
                batch.append(&candidate, &packet, &self.buffer_pool)
            }
            _ => self.items.push(Item::Batch(Batch::new(candidate, packet))),
        }
    }

    /// Drains all queued packets, in write order.
    pub fn drain(&mut self) -> impl Iterator<Item = CoalescedPacket> + '_ {
        let checksum_mode = self.checksum_mode;

        self.items
            .drain(..)
            .map(move |item| item.into_outgoing(checksum_mode))
    }
}

/// A pending write to the TUN device.
pub struct CoalescedPacket(Inner);

enum Inner {
    /// An individual IP packet, passed through unchanged.
    Packet(IpPacket),
    /// A coalesced batch.
    Batch {
        buf: Buffer<Vec<u8>>,
        num_segments: usize,
        offload_metadata: Option<OffloadMetadata>,
    },
}

impl CoalescedPacket {
    /// How many IP packets this write carries.
    pub fn num_segments(&self) -> usize {
        match &self.0 {
            Inner::Packet(_) => 1,
            Inner::Batch { num_segments, .. } => *num_segments,
        }
    }

    /// The complete IP packet bytes.
    pub fn packet(&self) -> &[u8] {
        match &self.0 {
            Inner::Packet(packet) => packet.packet(),
            Inner::Batch { buf, .. } => buf,
        }
    }

    /// Metadata required to finish an offloaded coalesced packet.
    pub fn offload_metadata(&self) -> Option<OffloadMetadata> {
        match &self.0 {
            Inner::Packet(_) => None,
            Inner::Batch {
                offload_metadata, ..
            } => *offload_metadata,
        }
    }
}

impl From<IpPacket> for CoalescedPacket {
    fn from(packet: IpPacket) -> Self {
        Self(Inner::Packet(packet))
    }
}

/// An entry in a [`PacketCoalescer`].
enum Item {
    /// A packet that cannot participate in coalescing, passed through as-is.
    Packet(IpPacket),
    /// One or more coalesced segments of a single flow.
    Batch(Batch),
}

impl Item {
    /// Whether this item carries traffic of the same connection as `packet`.
    fn same_connection(&self, packet: &IpPacket) -> bool {
        match self {
            Item::Packet(existing) => same_connection(existing, packet),
            Item::Batch(batch) => batch.key.same_connection(packet),
        }
    }

    fn into_outgoing(self, checksum_mode: ChecksumMode) -> CoalescedPacket {
        match self {
            Item::Packet(packet) => CoalescedPacket::from(packet),
            Item::Batch(batch) => batch.into_outgoing(checksum_mode),
        }
    }
}

/// Whether two packets belong to the same connection.
fn same_connection(a: &IpPacket, b: &IpPacket) -> bool {
    if a.source() != b.source() || a.destination() != b.destination() {
        return false;
    }

    if let (Some(a), Some(b)) = (a.as_tcp(), b.as_tcp()) {
        return a.source_port() == b.source_port() && a.destination_port() == b.destination_port();
    }

    if let (Some(a), Some(b)) = (a.as_udp(), b.as_udp()) {
        return a.source_port() == b.source_port() && a.destination_port() == b.destination_port();
    }

    false
}

struct Candidate {
    key: FlowKey,
    ip_hdr_len: usize,
    l4_hdr_len: usize,
    payload_len: usize,
    seq: u32,
    psh: bool,
}

impl Candidate {
    /// Classifies a packet: `Some` if it may participate in coalescing.
    fn from_packet(packet: &IpPacket, coalesce_tcp: bool, coalesce_udp: bool) -> Option<Self> {
        let ip_hdr_len = ip_layout(packet)?;

        let candidate = match (packet.as_tcp(), packet.as_udp()) {
            (Some(tcp), _) if coalesce_tcp => Self::try_from_tcp(packet, &tcp, ip_hdr_len)?,
            (_, Some(udp)) if coalesce_udp => Self::from_udp(packet, &udp, ip_hdr_len),
            _ => return None,
        };

        if candidate.payload_len == 0 {
            return None;
        }

        // Appending copies `&bytes[ip_hdr_len + l4_hdr_len..]`, so the parsed layout
        // must cover the buffer exactly.
        if ip_hdr_len + candidate.l4_hdr_len + candidate.payload_len != packet.packet().len() {
            return None;
        }

        Some(candidate)
    }

    fn try_from_tcp(packet: &IpPacket, tcp: &TcpSlice, ip_hdr_len: usize) -> Option<Self> {
        // Only plain data segments coalesce: exactly ACK, or ACK|PSH.
        if !tcp.ack() || tcp.syn() || tcp.fin() || tcp.rst() || tcp.urg() || tcp.ece() || tcp.cwr()
        {
            return None;
        }

        Some(Self {
            key: FlowKey::from_tcp(packet, tcp),
            ip_hdr_len,
            l4_hdr_len: tcp.header_len(),
            payload_len: tcp.payload().len(),
            seq: tcp.sequence_number(),
            psh: tcp.psh(),
        })
    }

    fn from_udp(packet: &IpPacket, udp: &UdpSlice, ip_hdr_len: usize) -> Self {
        Self {
            key: FlowKey::from_udp(packet, udp),
            ip_hdr_len,
            l4_hdr_len: 8,
            payload_len: udp.payload().len(),
            seq: 0,
            psh: false,
        }
    }
}

/// Validates the IP layer for coalescing, returning the IP header length.
fn ip_layout(packet: &IpPacket) -> Option<usize> {
    let total_len = packet.packet().len();

    match (packet.ipv4_header(), packet.ipv6_header()) {
        (Some(header), _) => {
            // IP options never coalesce.
            if !header.options().is_empty() {
                return None;
            }

            // The IP length must describe the entire buffer for byte-level coalescing to be sound.
            if header.total_len() as usize != total_len {
                return None;
            }

            Some(header.header_len())
        }
        (_, Some(header)) => {
            if header.payload_length() as usize + Ipv6HeaderSlice::LEN != total_len {
                return None;
            }

            // Extension headers never coalesce.
            if !matches!(header.next_header(), IpNumber::TCP | IpNumber::UDP) {
                return None;
            }

            Some(Ipv6HeaderSlice::LEN)
        }
        (None, None) => None,
    }
}

#[derive(PartialEq, Eq, Clone, Copy)]
struct FlowKey {
    protocol: IpNumber,
    src: IpAddr,
    dst: IpAddr,
    sport: u16,
    dport: u16,
    /// Segments with differing ACK numbers must not be coalesced.
    ///
    /// Always zero for UDP.
    ack: u32,
}

impl FlowKey {
    fn from_tcp(packet: &IpPacket, tcp: &TcpSlice) -> Self {
        Self {
            protocol: IpNumber::TCP,
            src: packet.source(),
            dst: packet.destination(),
            sport: tcp.source_port(),
            dport: tcp.destination_port(),
            ack: tcp.acknowledgment_number(),
        }
    }

    fn from_udp(packet: &IpPacket, udp: &UdpSlice) -> Self {
        Self {
            protocol: IpNumber::UDP,
            src: packet.source(),
            dst: packet.destination(),
            sport: udp.source_port(),
            dport: udp.destination_port(),
            ack: 0,
        }
    }

    fn version(&self) -> IpVersion {
        match self.src {
            IpAddr::V4(_) => IpVersion::V4,
            IpAddr::V6(_) => IpVersion::V6,
        }
    }

    /// Whether `packet` belongs to the same connection (ignoring the ACK number).
    fn same_connection(&self, packet: &IpPacket) -> bool {
        if packet.source() != self.src || packet.destination() != self.dst {
            return false;
        }

        if let Some(tcp) = packet.as_tcp() {
            return self.protocol == IpNumber::TCP
                && tcp.source_port() == self.sport
                && tcp.destination_port() == self.dport;
        }

        if let Some(udp) = packet.as_udp() {
            return self.protocol == IpNumber::UDP
                && udp.source_port() == self.sport
                && udp.destination_port() == self.dport;
        }

        false
    }
}

struct Batch {
    key: FlowKey,
    state: BatchState,

    ip_hdr_len: usize,
    l4_hdr_len: usize,
    /// The gso_size of the super packet: the payload length of the first segment.
    seg_size: usize,
    /// Total IP packet length accumulated so far (headers + all payloads).
    total_len: usize,
    /// The expected sequence number of the next segment (TCP only).
    next_seq: u32,
    num_segs: usize,
    psh: bool,
}

enum BatchState {
    /// A single packet; not copied anywhere yet.
    Single(IpPacket),
    /// Two or more segments coalesced into a buffer.
    Coalesced(Buffer<Vec<u8>>),
}

impl BatchState {
    /// The coalescing buffer, converting from [`BatchState::Single`] on first use.
    fn coalesced(&mut self, pool: &BufferPool<Vec<u8>>) -> &mut Buffer<Vec<u8>> {
        if let BatchState::Single(first) = &*self {
            let mut buf = pool.pull();
            buf.clear();
            buf.extend_from_slice(first.packet());

            *self = BatchState::Coalesced(buf);
        }

        match self {
            BatchState::Coalesced(buf) => buf,
            BatchState::Single(_) => unreachable!("converted to `Coalesced` above"),
        }
    }
}

impl Batch {
    fn new(candidate: Candidate, packet: IpPacket) -> Self {
        Self {
            key: candidate.key,
            ip_hdr_len: candidate.ip_hdr_len,
            l4_hdr_len: candidate.l4_hdr_len,
            seg_size: candidate.payload_len,
            total_len: packet.packet().len(),
            next_seq: candidate.seq.wrapping_add(candidate.payload_len as u32),
            num_segs: 1,
            psh: candidate.psh,
            state: BatchState::Single(packet),
        }
    }

    /// Appends the packet's payload to this batch.
    fn append(&mut self, candidate: &Candidate, packet: &IpPacket, pool: &BufferPool<Vec<u8>>) {
        let bytes = packet.packet();
        let payload = &bytes[candidate.ip_hdr_len + candidate.l4_hdr_len..];

        self.state.coalesced(pool).extend_from_slice(payload);

        self.total_len += payload.len();
        self.next_seq = self.next_seq.wrapping_add(payload.len() as u32);
        self.num_segs += 1;
        self.psh |= candidate.psh;
    }

    /// Whether further segments may be appended.
    ///
    /// A pushed or short segment ends the stream of coalescable data: GSO requires
    /// equal-size segments with at most one shorter, final one.
    fn is_ongoing(&self) -> bool {
        let payload_len = self.total_len - self.ip_hdr_len - self.l4_hdr_len;

        !self.psh && payload_len == self.num_segs * self.seg_size
    }

    fn into_outgoing(self, checksum_mode: ChecksumMode) -> CoalescedPacket {
        let Batch {
            key,
            state,
            ip_hdr_len,
            l4_hdr_len,
            seg_size,
            num_segs,
            psh,
            ..
        } = self;

        match state {
            BatchState::Single(packet) => CoalescedPacket::from(packet),
            BatchState::Coalesced(mut buf) => {
                let offload_metadata = finalize(
                    &mut buf,
                    &key,
                    ip_hdr_len,
                    l4_hdr_len,
                    seg_size,
                    psh,
                    checksum_mode,
                );
                let offload_metadata =
                    matches!(checksum_mode, ChecksumMode::Offloaded).then_some(offload_metadata);

                CoalescedPacket(Inner::Batch {
                    buf,
                    num_segments: num_segs,
                    offload_metadata,
                })
            }
        }
    }

    fn can_append(&self, candidate: &Candidate, packet: &IpPacket) -> bool {
        if !self.is_ongoing() {
            return false;
        }

        if candidate.ip_hdr_len != self.ip_hdr_len {
            return false;
        }

        if candidate.l4_hdr_len != self.l4_hdr_len {
            return false;
        }

        // Only equal-size segments plus at most one shorter, final one form a valid GSO batch.
        if candidate.payload_len > self.seg_size {
            return false;
        }

        if self.total_len + candidate.payload_len > MAX_COALESCED_PACKET {
            return false;
        }

        if candidate.key.protocol == IpNumber::TCP && candidate.seq != self.next_seq {
            return false;
        }

        if candidate.key.protocol == IpNumber::UDP && self.num_segs >= MAX_UDP_SEGMENTS {
            return false;
        }

        if !ip_headers_compatible(self.template(), packet.packet(), self.key.version()) {
            return false;
        }

        if candidate.key.protocol == IpNumber::TCP
            && !tcp_headers_compatible(
                self.template(),
                packet.packet(),
                self.ip_hdr_len,
                self.l4_hdr_len,
            )
        {
            return false;
        }

        true
    }

    /// The first packet of the batch; all compatibility checks compare against its headers.
    fn template(&self) -> &[u8] {
        match &self.state {
            BatchState::Single(packet) => packet.packet(),
            BatchState::Coalesced(buf) => buf,
        }
    }
}

/// Whether the IP-header fields that must match for coalescing are equal in `packet` and the
/// batch `template`.
fn ip_headers_compatible(template: &[u8], packet: &[u8], version: IpVersion) -> bool {
    match version {
        IpVersion::V4 => {
            let tos_matches = template[1] == packet[1];
            let fragment_flags_match = template[6] >> 5 == packet[6] >> 5;
            let ttl_matches = template[8] == packet[8];

            tos_matches && fragment_flags_match && ttl_matches
        }
        IpVersion::V6 => {
            // The flow label is allowed to differ.
            let traffic_class_matches =
                template[0] == packet[0] && template[1] >> 4 == packet[1] >> 4;
            let hop_limit_matches = template[7] == packet[7];

            traffic_class_matches && hop_limit_matches
        }
    }
}

/// Whether the TCP options of `packet` are byte-identical to the batch `template`.
///
/// The rest of the TCP header is either part of the [`FlowKey`] or checked separately (the
/// sequence number and the PSH flag), so only the options can still differ. For a header
/// without options the compared range is empty and this trivially holds.
fn tcp_headers_compatible(
    template: &[u8],
    packet: &[u8],
    ip_hdr_len: usize,
    l4_hdr_len: usize,
) -> bool {
    let start = ip_hdr_len + 20;
    let end = ip_hdr_len + l4_hdr_len;

    template[start..end] == packet[start..end]
}

/// Metadata needed to segment a coalesced packet and complete its transport checksum.
#[derive(Clone, Copy)]
pub struct OffloadMetadata {
    /// The coalesced transport protocol.
    pub protocol: Protocol,
    /// The packet's IP version.
    pub ip_version: IpVersion,
    /// The IP header length in bytes.
    pub ip_header_len: usize,
    /// The transport header length in bytes.
    pub transport_header_len: usize,
    /// The payload size of each segment except, potentially, the final segment.
    pub segment_size: usize,
}

/// Fixes up the IP and transport headers of a coalesced packet.
fn finalize(
    buf: &mut [u8],
    key: &FlowKey,
    ip_hdr_len: usize,
    l4_hdr_len: usize,
    seg_size: usize,
    psh: bool,
    checksum_mode: ChecksumMode,
) -> OffloadMetadata {
    let total_len = buf.len();
    let l4_len = total_len - ip_hdr_len;
    let packet = buf;

    match key.version() {
        IpVersion::V4 => {
            packet[2..4].copy_from_slice(&(total_len as u16).to_be_bytes());

            packet[10] = 0;
            packet[11] = 0;
            let ip_checksum = !checksum::fold(checksum::sum(&packet[..ip_hdr_len], 0));
            packet[10..12].copy_from_slice(&ip_checksum.to_be_bytes());
        }
        IpVersion::V6 => {
            packet[4..6].copy_from_slice(&(l4_len as u16).to_be_bytes());
        }
    }

    let l4 = &mut packet[ip_hdr_len..];

    let pseudo_sum = match (key.src, key.dst) {
        (IpAddr::V4(src), IpAddr::V4(dst)) => {
            checksum::pseudo_header_sum_v4(src, dst, key.protocol, l4_len)
        }
        (IpAddr::V6(src), IpAddr::V6(dst)) => {
            checksum::pseudo_header_sum_v6(src, dst, key.protocol, l4_len)
        }
        _ => unreachable!("src and dst are always the same IP version"),
    };

    let checksum_offset = match key.protocol {
        IpNumber::TCP => {
            if psh {
                l4[13] |= TCP_FLAG_PSH;
            }

            16
        }
        IpNumber::UDP => {
            l4[4..6].copy_from_slice(&(l4_len as u16).to_be_bytes());
            6
        }
        _ => unreachable!("only TCP and UDP packets are coalesced"),
    };

    l4[checksum_offset..checksum_offset + 2].fill(0);

    let checksum = match checksum_mode {
        ChecksumMode::Offloaded => {
            // For an offloaded checksum, the checksum field holds the folded,
            // uncomplemented pseudo-header sum for the receiver to complete.
            checksum::fold(pseudo_sum)
        }
        ChecksumMode::Complete => {
            let checksum = !checksum::fold(checksum::sum(l4, pseudo_sum));

            // A computed UDP checksum of zero is transmitted as all ones.
            if key.protocol == IpNumber::UDP && checksum == 0 {
                u16::MAX
            } else {
                checksum
            }
        }
    };
    l4[checksum_offset..checksum_offset + 2].copy_from_slice(&checksum.to_be_bytes());

    OffloadMetadata {
        protocol: match key.protocol {
            IpNumber::TCP => Protocol::Tcp,
            IpNumber::UDP => Protocol::Udp,
            _ => unreachable!("only TCP and UDP packets are coalesced"),
        },
        ip_version: key.version(),
        ip_header_len: ip_hdr_len,
        transport_header_len: l4_hdr_len,
        segment_size: seg_size,
    }
}

#[cfg(test)]
mod tests {
    use std::net::Ipv4Addr;

    use ingot::ip::{IpProtocol, Ipv4};
    use ingot::tcp::{Tcp, TcpFlags};
    use ingot::types::{Emit, HeaderLen as _};
    use ingot::udp::Udp;
    use ip_packet::IpPacketBuf;

    use super::*;

    const SRC: Ipv4Addr = Ipv4Addr::new(10, 0, 0, 1);
    const DST: Ipv4Addr = Ipv4Addr::new(10, 0, 0, 2);

    #[test]
    fn complete_checksum_mode_emits_one_fully_checksummed_packet() {
        let mut queue = PacketCoalescer::new([Protocol::Tcp], ChecksumMode::Complete);

        queue.enqueue(tcp4(1000, &[1; 100]));
        queue.enqueue(tcp4(1100, &[2; 100]));
        queue.enqueue(tcp4(1200, &[3; 50]));

        let out = queue.drain().collect::<Vec<_>>();
        let [packet] = out.as_slice() else {
            panic!("expected one coalesced packet")
        };

        assert_eq!(packet.num_segments(), 3);
        assert!(packet.offload_metadata().is_none());
        assert_eq!(packet.packet().len(), 20 + 20 + 250);
        assert_eq!(&packet.packet()[40..140], &[1; 100]);
        assert_eq!(&packet.packet()[140..240], &[2; 100]);
        assert_eq!(&packet.packet()[240..290], &[3; 50]);

        let total_len = u16::from_be_bytes([packet.packet()[2], packet.packet()[3]]) as usize;
        assert_eq!(total_len, packet.packet().len());

        let ip_sum = checksum::fold(checksum::sum(&packet.packet()[..20], 0));
        assert_eq!(ip_sum, u16::MAX, "IPv4 checksum must be complete");

        let tcp = &packet.packet()[20..];
        let pseudo = checksum::pseudo_header_sum_v4(SRC, DST, IpNumber::TCP, tcp.len());
        let tcp_sum = checksum::fold(checksum::sum(tcp, pseudo));
        assert_eq!(tcp_sum, u16::MAX, "TCP checksum must be complete");
    }

    #[test]
    fn offloaded_checksum_mode_emits_checksum_seed_and_metadata() {
        let mut queue = PacketCoalescer::new([Protocol::Tcp], ChecksumMode::Offloaded);

        queue.enqueue(tcp4(1000, &[1; 100]));
        queue.enqueue(tcp4(1100, &[2; 100]));

        let out = queue.drain().collect::<Vec<_>>();
        let [packet] = out.as_slice() else {
            panic!("expected one coalesced packet")
        };
        let offload = packet
            .offload_metadata()
            .expect("offloaded packet needs metadata");

        assert_eq!(offload.protocol, Protocol::Tcp);
        assert!(offload.ip_version == IpVersion::V4);
        assert_eq!(offload.ip_header_len, 20);
        assert_eq!(offload.transport_header_len, 20);
        assert_eq!(offload.segment_size, 100);

        let tcp = &packet.packet()[offload.ip_header_len..];
        let checksum = u16::from_be_bytes([tcp[16], tcp[17]]);
        let pseudo = checksum::pseudo_header_sum_v4(SRC, DST, IpNumber::TCP, tcp.len());

        assert_eq!(checksum, checksum::fold(pseudo));
    }

    #[test]
    fn disabled_protocol_does_not_change_packet_boundaries() {
        let mut queue = PacketCoalescer::new([Protocol::Tcp], ChecksumMode::Complete);

        queue.enqueue(udp4(&[1; 100]));
        queue.enqueue(udp4(&[2; 100]));

        let out = queue.drain().collect::<Vec<_>>();

        assert_eq!(out.len(), 2);
        assert!(out.iter().all(|packet| packet.num_segments() == 1));
    }

    #[test]
    fn passthrough_preserves_packet_boundaries() {
        let mut queue = PacketCoalescer::passthrough();

        queue.enqueue(tcp4(1000, &[1; 100]));
        queue.enqueue(tcp4(1100, &[2; 100]));

        let out = queue.drain().collect::<Vec<_>>();

        assert_eq!(out.len(), 2);
        assert!(out.iter().all(|packet| packet.num_segments() == 1));
    }

    #[test]
    fn coalesces_enabled_udp_datagrams() {
        let mut queue =
            PacketCoalescer::new([Protocol::Tcp, Protocol::Udp], ChecksumMode::Offloaded);

        queue.enqueue(udp4(&[1; 100]));
        queue.enqueue(udp4(&[2; 100]));
        queue.enqueue(udp4(&[3; 30]));

        let out = queue.drain().collect::<Vec<_>>();
        let [packet] = out.as_slice() else {
            panic!("expected one coalesced packet")
        };

        assert_eq!(packet.num_segments(), 3);
        assert_eq!(packet.packet().len(), 20 + 8 + 230);

        let metadata = packet
            .offload_metadata()
            .expect("offloaded packet needs metadata");
        assert_eq!(metadata.protocol, Protocol::Udp);
        assert_eq!(metadata.segment_size, 100);
    }

    #[test]
    fn coalesces_interleaved_flows_independently() {
        let mut queue = PacketCoalescer::new([Protocol::Tcp], ChecksumMode::Complete);

        queue.enqueue(tcp4(1000, &[1; 100]));
        queue.enqueue(tcp4_ports(7000, 8000, 9999, &[9; 100]));
        queue.enqueue(tcp4(1100, &[2; 100]));

        let out = queue.drain().collect::<Vec<_>>();

        assert_eq!(out.len(), 2);
        assert_eq!(out[0].num_segments(), 2);
        assert_eq!(out[1].num_segments(), 1);
    }

    #[test]
    fn out_of_order_segment_starts_new_batch() {
        let mut queue = PacketCoalescer::new([Protocol::Tcp], ChecksumMode::Complete);

        queue.enqueue(tcp4(1000, &[1; 100]));
        queue.enqueue(tcp4(1500, &[2; 100]));

        let out = queue.drain().collect::<Vec<_>>();

        assert_eq!(out.len(), 2);
        assert!(out.iter().all(|packet| packet.num_segments() == 1));
    }

    #[test]
    fn psh_closes_the_batch() {
        let mut queue = PacketCoalescer::new([Protocol::Tcp], ChecksumMode::Complete);

        queue.enqueue(tcp4(1000, &[1; 100]));
        queue.enqueue(tcp4_psh(1100, &[2; 100]));
        queue.enqueue(tcp4(1200, &[3; 100]));

        let out = queue.drain().collect::<Vec<_>>();
        let [super_packet, segment] = out.as_slice() else {
            panic!("expected a super packet followed by the post-PSH segment")
        };

        assert_eq!(super_packet.num_segments(), 2);
        assert_eq!(segment.num_segments(), 1);
        assert_eq!(
            super_packet.packet()[33] & TCP_FLAG_PSH,
            TCP_FLAG_PSH,
            "PSH must be set on the super packet"
        );
    }

    #[test]
    fn short_segment_closes_the_batch() {
        let mut queue = PacketCoalescer::new([Protocol::Tcp], ChecksumMode::Complete);

        queue.enqueue(tcp4(1000, &[1; 100]));
        queue.enqueue(tcp4(1100, &[2; 40]));
        queue.enqueue(tcp4(1140, &[3; 100]));

        let out = queue.drain().collect::<Vec<_>>();

        assert_eq!(out.len(), 2);
        assert_eq!(out[0].num_segments(), 2);
        assert_eq!(out[1].num_segments(), 1);
    }

    #[test]
    fn non_candidate_preserves_same_flow_order() {
        let mut queue = PacketCoalescer::new([Protocol::Tcp], ChecksumMode::Complete);

        queue.enqueue(tcp4(1000, &[1; 100]));
        queue.enqueue(tcp4(1100, &[2; 100]));
        queue.enqueue(tcp4(1200, &[]));

        let out = queue.drain().collect::<Vec<_>>();

        assert_eq!(out.len(), 2);
        assert_eq!(out[0].num_segments(), 2);
        assert_eq!(out[1].num_segments(), 1);
    }

    fn tcp4(seq: u32, payload: &[u8]) -> IpPacket {
        tcp4_ports(5000, 6000, seq, payload)
    }

    fn tcp4_ports(source: u16, destination: u16, seq: u32, payload: &[u8]) -> IpPacket {
        ipv4_packet(
            IpProtocol::TCP,
            tcp_header(source, destination, seq, false),
            payload,
        )
    }

    fn tcp4_psh(seq: u32, payload: &[u8]) -> IpPacket {
        ipv4_packet(IpProtocol::TCP, tcp_header(5000, 6000, seq, true), payload)
    }

    fn tcp_header(source: u16, destination: u16, seq: u32, psh: bool) -> Tcp {
        let mut flags = TcpFlags::ACK;
        flags.set(TcpFlags::PSH, psh);

        Tcp {
            source,
            destination,
            sequence: seq,
            acknowledgement: 42,
            flags,
            window_size: 64000,
            ..Default::default()
        }
    }

    fn udp4(payload: &[u8]) -> IpPacket {
        let udp = Udp {
            source: 5000,
            destination: 6000,
            length: (8 + payload.len()) as u16,
            checksum: 0,
        };

        ipv4_packet(IpProtocol::UDP, udp, payload)
    }

    fn ipv4_packet(protocol: IpProtocol, l4_header: impl Emit, payload: &[u8]) -> IpPacket {
        let total_len = Ipv4::MINIMUM_LENGTH + l4_header.packet_length() + payload.len();
        let ipv4 = Ipv4 {
            ihl: 5,
            total_len: total_len as u16,
            hop_limit: 64,
            protocol,
            source: SRC.into(),
            destination: DST.into(),
            ..Default::default()
        };

        let mut bytes = (ipv4, l4_header).to_vec();
        bytes.extend_from_slice(payload);

        let mut buf = IpPacketBuf::new();
        buf.buf()[..bytes.len()].copy_from_slice(&bytes);
        let mut packet =
            IpPacket::new(buf, bytes.len()).expect("constructed test packet must be valid");
        packet.compute_checksums();

        packet
    }
}
