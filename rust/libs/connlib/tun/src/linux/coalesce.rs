//! Coalesces individual IP packets into GSO "super packets" for writing to the TUN device.
//!
//! Writing one large packet with a [`VirtioNetHdr`] describing its segmentation lets the
//! entire batch traverse the kernel's network stack as a single skb, which is where the
//! bulk of the per-packet cost lives.
//!
//! Only packets that the kernel's own GRO would merge are combined, everything else is
//! passed through untouched.

use bufferpool::{Buffer, BufferPool};
use ip_packet::{IpNumber, IpPacket, IpVersion, Ipv6Header, TcpSlice, UdpSlice};
use std::net::IpAddr;

use super::checksum;
use super::virtio::*;

/// The maximum size of a coalesced packet.
///
/// IP packets cannot be larger than 65535 bytes (the total-length / payload-length fields
/// are 16 bits wide), and so neither can our super packets.
const MAX_COALESCED_PACKET: usize = u16::MAX as usize;

/// The kernel rejects `VIRTIO_NET_HDR_GSO_UDP_L4` writes with more segments than this
/// (`UDP_MAX_SEGMENTS` in `linux/udp.h`).
const MAX_UDP_SEGMENTS: usize = 128;

const TCP_FLAG_PSH: u8 = 0x08;

const ZEROED_VNET_HDR: [u8; VNET_HDR_LEN] = [0; VNET_HDR_LEN];

/// Coalesces IP packets into GSO super packets.
pub struct TunGsoQueue {
    /// Queued items, in write order.
    ///
    /// Non-coalescable packets flow through this queue too: a segment may only merge
    /// into the most recent item of its connection, so per-flow ordering is preserved
    /// by construction.
    items: Vec<Item>,
    buffer_pool: BufferPool<Vec<u8>>,
}

impl Default for TunGsoQueue {
    fn default() -> Self {
        Self::new()
    }
}

impl TunGsoQueue {
    pub fn new() -> Self {
        Self {
            items: Vec::new(),
            buffer_pool: BufferPool::new(VNET_HDR_LEN + MAX_COALESCED_PACKET, "tun-gso-queue"),
        }
    }

    /// Queues a single packet, coalescing it with already queued ones where possible.
    pub fn enqueue(&mut self, packet: IpPacket) {
        let Some(candidate) = Candidate::from_packet(&packet) else {
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
    pub fn drain(&mut self) -> impl Iterator<Item = Outgoing> + '_ {
        self.items.drain(..).map(Item::into_outgoing)
    }
}

/// A pending write to the TUN device.
pub struct Outgoing(Inner);

enum Inner {
    /// An individual IP packet; written with a zeroed [`VirtioNetHdr`].
    Packet(IpPacket),
    /// A coalesced batch of packets, including its [`VirtioNetHdr`].
    Batch {
        buf: Buffer<Vec<u8>>,
        num_segments: usize,
    },
}

impl Outgoing {
    /// How many IP packets this write carries.
    pub fn num_segments(&self) -> usize {
        match &self.0 {
            Inner::Packet(_) => 1,
            Inner::Batch { num_segments, .. } => *num_segments,
        }
    }

    /// The [`VirtioNetHdr`] and packet bytes of this write, ready for `writev`.
    pub fn bufs(&self) -> [&[u8]; 2] {
        match &self.0 {
            Inner::Packet(packet) => [ZEROED_VNET_HDR.as_slice(), packet.packet()],
            Inner::Batch { buf, .. } => {
                let (hdr, packet) = buf.split_at(VNET_HDR_LEN);

                [hdr, packet]
            }
        }
    }
}

impl From<IpPacket> for Outgoing {
    fn from(packet: IpPacket) -> Self {
        Self(Inner::Packet(packet))
    }
}

/// An entry in the [`TunGsoQueue`].
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

    fn into_outgoing(self) -> Outgoing {
        match self {
            Item::Packet(packet) => Outgoing::from(packet),
            Item::Batch(batch) => batch.into_outgoing(),
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
    fn from_packet(packet: &IpPacket) -> Option<Self> {
        let ip_hdr_len = ip_layout(packet)?;

        let candidate = if let Some(tcp) = packet.as_tcp() {
            Self::try_from_tcp(packet, &tcp, ip_hdr_len)?
        } else {
            let udp = packet.as_udp()?;
            Self::from_udp(packet, &udp, ip_hdr_len)
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
            if !header.options.is_empty() {
                return None;
            }

            // The IP length must describe the entire buffer for byte-level coalescing to be sound.
            if header.total_len as usize != total_len {
                return None;
            }

            Some(header.header_len())
        }
        (_, Some(header)) => {
            if header.payload_length as usize + Ipv6Header::LEN != total_len {
                return None;
            }

            // Extension headers never coalesce.
            if !matches!(header.next_header, IpNumber::TCP | IpNumber::UDP) {
                return None;
            }

            Some(Ipv6Header::LEN)
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
    /// Two or more segments coalesced into a buffer, prefixed by space for the [`VirtioNetHdr`].
    Coalesced(Buffer<Vec<u8>>),
}

impl BatchState {
    /// The coalescing buffer, converting from [`BatchState::Single`] on first use.
    fn coalesced(&mut self, pool: &BufferPool<Vec<u8>>) -> &mut Buffer<Vec<u8>> {
        if let BatchState::Single(first) = &*self {
            let mut buf = pool.pull();
            buf.clear();
            buf.resize(VNET_HDR_LEN, 0);
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

    fn into_outgoing(self) -> Outgoing {
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
            BatchState::Single(packet) => Outgoing::from(packet),
            BatchState::Coalesced(mut buf) => {
                finalize(&mut buf, &key, ip_hdr_len, l4_hdr_len, seg_size, psh);

                Outgoing(Inner::Batch {
                    buf,
                    num_segments: num_segs,
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
            BatchState::Coalesced(buf) => &buf[VNET_HDR_LEN..],
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

/// Writes the [`VirtioNetHdr`] and fixes up the outer headers of a coalesced super packet.
fn finalize(
    buf: &mut [u8],
    key: &FlowKey,
    ip_hdr_len: usize,
    l4_hdr_len: usize,
    seg_size: usize,
    psh: bool,
) {
    let total_len = buf.len() - VNET_HDR_LEN;
    let l4_len = total_len - ip_hdr_len;

    let (gso_type, csum_offset) = match (key.protocol, key.version()) {
        (IpNumber::TCP, IpVersion::V4) => (VIRTIO_NET_HDR_GSO_TCPV4, 16),
        (IpNumber::TCP, IpVersion::V6) => (VIRTIO_NET_HDR_GSO_TCPV6, 16),
        (IpNumber::UDP, _) => (VIRTIO_NET_HDR_GSO_UDP_L4, 6),
        _ => unreachable!("only TCP and UDP packets are coalesced"),
    };

    VirtioNetHdr {
        flags: VIRTIO_NET_HDR_F_NEEDS_CSUM,
        gso_type,
        hdr_len: (ip_hdr_len + l4_hdr_len) as u16,
        gso_size: seg_size as u16,
        csum_start: ip_hdr_len as u16,
        csum_offset: csum_offset as u16,
    }
    .write_to(buf);

    let packet = &mut buf[VNET_HDR_LEN..];

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
            checksum::pseudo_header_sum_v4(src, dst, key.protocol.0, l4_len)
        }
        (IpAddr::V6(src), IpAddr::V6(dst)) => {
            checksum::pseudo_header_sum_v6(src, dst, key.protocol.0, l4_len)
        }
        _ => unreachable!("src and dst are always the same IP version"),
    };

    match key.protocol {
        IpNumber::TCP => {
            if psh {
                l4[13] |= TCP_FLAG_PSH;
            }

            // For a NEEDS_CSUM (i.e. CHECKSUM_PARTIAL) packet, the checksum field must
            // hold the folded, *uncomplemented* pseudo-header sum.
            l4[16..18].copy_from_slice(&checksum::fold(pseudo_sum).to_be_bytes());
        }
        IpNumber::UDP => {
            l4[4..6].copy_from_slice(&(l4_len as u16).to_be_bytes());
            l4[6..8].copy_from_slice(&checksum::fold(pseudo_sum).to_be_bytes());
        }
        _ => unreachable!("only TCP and UDP packets are coalesced"),
    }
}
