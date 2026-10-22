//! Raw mirror of `include/tundra.h`, the user <-> kernel ABI.
//!
//! Everything is plain old data so it can be shared with other languages as is.

pub const ABI_VERSION: u32 = 3;

/// Hardware ID matched by the driver's INF.
pub const HWID: &str = "Tundra";

/// `\\.\Global\Tundra-<LUID as 16 upper-case hex digits>`
pub const USER_PATH_PREFIX: &str = r"\\.\Global\Tundra-";

/// The largest IP packet (or GSO super-packet) the driver produces or accepts.
pub const MAX_PACKET_SIZE: usize = 0xFFFF;

/// Ring entries start at multiples of this alignment.
pub const ALIGNMENT: usize = 8;

pub const fn align(n: usize) -> usize {
    (n + (ALIGNMENT - 1)) & !(ALIGNMENT - 1)
}

/// The largest ring entry: a header plus a maximum-sized packet.
pub const MAX_ENTRY_SIZE: usize = align(size_of::<PacketHeader>() + MAX_PACKET_SIZE);

pub const MIN_RING_CAPACITY: usize = 128 * 1024;
pub const MAX_RING_CAPACITY: usize = 64 * 1024 * 1024;
/// Entries never wrap: one that starts near the end runs on into this many extra bytes.
pub const RING_TRAILER: usize = MAX_ENTRY_SIZE;
/// Rings must start at a multiple of this.
pub const RING_ALIGNMENT: usize = 64;

/// Total size of a ring with the given capacity.
pub const fn ring_size(capacity: usize) -> usize {
    size_of::<RingHeader>() + capacity + RING_TRAILER
}

/// [`PacketHeader::flags`]: the L4 checksum must be completed (virtio semantics).
pub const PKT_F_NEEDS_CSUM: u8 = 0x01;
/// [`PacketHeader::flags`] (writes only): all checksums are known to be valid.
pub const PKT_F_DATA_VALID: u8 = 0x02;

/// [`PacketHeader::gso_type`], numerically identical to `VIRTIO_NET_HDR_GSO_*`.
pub const GSO_NONE: u8 = 0;
pub const GSO_TCPV4: u8 = 1;
pub const GSO_TCPV6: u8 = 4;
pub const GSO_UDP_L4: u8 = 5;

pub const OFFLOAD_TX_CSUM_IPV4: u32 = 0x0001;
pub const OFFLOAD_TX_CSUM_IPV6: u32 = 0x0002;
pub const OFFLOAD_TX_TSO_IPV4: u32 = 0x0004;
pub const OFFLOAD_TX_TSO_IPV6: u32 = 0x0008;
pub const OFFLOAD_TX_USO_IPV4: u32 = 0x0010;
pub const OFFLOAD_TX_USO_IPV6: u32 = 0x0020;
pub const OFFLOAD_RX_CSUM: u32 = 0x0100;
pub const OFFLOAD_RX_RSC_IPV4: u32 = 0x0200;
pub const OFFLOAD_RX_RSC_IPV6: u32 = 0x0400;
/// UDP GSO writes are indicated to Windows as coalesced segments (URO, NDIS 6.89+).
pub const OFFLOAD_RX_URO: u32 = 0x0800;
pub const OFFLOAD_ALL: u32 = 0x0F3F;

const IOCTL_TYPE: u32 = 0x8A5E;
const METHOD_BUFFERED: u32 = 0;
const FILE_READ_DATA: u32 = 1;
const FILE_WRITE_DATA: u32 = 2;

const fn ctl_code(device_type: u32, function: u32, method: u32, access: u32) -> u32 {
    (device_type << 16) | (access << 14) | (function << 2) | method
}

pub const IOCTL_GET_INFO: u32 = ctl_code(IOCTL_TYPE, 0x800, METHOD_BUFFERED, FILE_READ_DATA);
pub const IOCTL_GET_STATISTICS: u32 = ctl_code(IOCTL_TYPE, 0x801, METHOD_BUFFERED, FILE_READ_DATA);
pub const IOCTL_SET_OFFLOADS: u32 = ctl_code(
    IOCTL_TYPE,
    0x802,
    METHOD_BUFFERED,
    FILE_READ_DATA | FILE_WRITE_DATA,
);
pub const IOCTL_START_SESSION: u32 = ctl_code(
    IOCTL_TYPE,
    0x803,
    METHOD_BUFFERED,
    FILE_READ_DATA | FILE_WRITE_DATA,
);

/// `TUNDRA_RING_HEADER`. Consumer and producer fields live on separate cache lines.
#[repr(C)]
#[derive(Debug)]
pub struct RingHeader {
    pub head: std::sync::atomic::AtomicU32,
    pub consumer_waiting: std::sync::atomic::AtomicU32,
    pub consumer_closed: std::sync::atomic::AtomicU32,
    pub reserved0: [u8; 52],
    pub tail: std::sync::atomic::AtomicU32,
    pub producer_waiting: std::sync::atomic::AtomicU32,
    pub producer_closed: std::sync::atomic::AtomicU32,
    pub reserved1: [u8; 52],
}

const _: () = assert!(size_of::<RingHeader>() == 128);

/// `TUNDRA_SESSION_PARAMETERS`. Addresses and handles are in the calling process.
#[repr(C)]
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct SessionParameters {
    pub transmit_ring: u64,
    pub receive_ring: u64,
    pub transmit_capacity: u32,
    pub receive_capacity: u32,
    pub transmit_data_event: u64,
    pub receive_data_event: u64,
    pub receive_space_event: u64,
}

const _: () = assert!(size_of::<SessionParameters>() == 48);

/// Precedes every packet in a ring (`TUNDRA_PACKET_HEADER`).
///
/// Its last [`VNET_HDR_LEN`] bytes are a legacy Linux `virtio_net_hdr` (little-endian),
/// directly followed by the packet, so an entry from [`VNET_HDR_OFFSET`] onwards is what
/// `read()` / `write()` exchange on a Linux TUN device with `IFF_VNET_HDR`.
#[repr(C)]
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct PacketHeader {
    /// Bytes of IP packet that follow the header.
    pub length: u32,
    pub reserved: u16,
    /// `PKT_F_*`
    pub flags: u8,
    /// `GSO_*`
    pub gso_type: u8,
    /// IP + L4 header length if `gso_type != GSO_NONE`.
    pub hdr_len: u16,
    /// Maximum L4 payload per segment if `gso_type != GSO_NONE`.
    pub gso_size: u16,
    /// Offset of the L4 header if `NEEDS_CSUM` is set.
    pub csum_start: u16,
    /// Offset of the checksum field relative to `csum_start`.
    pub csum_offset: u16,
}

pub const HEADER_LEN: usize = size_of::<PacketHeader>();
const _: () = assert!(HEADER_LEN == 16);

/// Where the `virtio_net_hdr` starts within [`PacketHeader`].
pub const VNET_HDR_OFFSET: usize = 6;
/// Size of the legacy `virtio_net_hdr`.
pub const VNET_HDR_LEN: usize = 10;
const _: () = assert!(VNET_HDR_OFFSET + VNET_HDR_LEN == HEADER_LEN);

impl PacketHeader {
    pub fn parse(buf: &[u8]) -> Option<Self> {
        let b: &[u8; HEADER_LEN] = buf.get(..HEADER_LEN)?.try_into().ok()?;
        let u16_at = |i: usize| u16::from_le_bytes([b[i], b[i + 1]]);
        Some(Self {
            length: u32::from_le_bytes([b[0], b[1], b[2], b[3]]),
            reserved: u16_at(4),
            flags: b[6],
            gso_type: b[7],
            hdr_len: u16_at(8),
            gso_size: u16_at(10),
            csum_start: u16_at(12),
            csum_offset: u16_at(14),
        })
    }

    pub fn to_bytes(self) -> [u8; HEADER_LEN] {
        let mut b = [0u8; HEADER_LEN];
        b[0..4].copy_from_slice(&self.length.to_le_bytes());
        b[4..6].copy_from_slice(&self.reserved.to_le_bytes());
        b[6] = self.flags;
        b[7] = self.gso_type;
        b[8..10].copy_from_slice(&self.hdr_len.to_le_bytes());
        b[10..12].copy_from_slice(&self.gso_size.to_le_bytes());
        b[12..14].copy_from_slice(&self.csum_start.to_le_bytes());
        b[14..16].copy_from_slice(&self.csum_offset.to_le_bytes());
        b
    }

    pub fn needs_csum(&self) -> bool {
        self.flags & PKT_F_NEEDS_CSUM != 0
    }

    pub fn is_gso(&self) -> bool {
        self.gso_type != GSO_NONE
    }
}

/// `TUNDRA_ADAPTER_INFO`
#[repr(C)]
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct AdapterInfo {
    pub abi_version: u32,
    /// `(major << 16) | minor`
    pub ndis_version: u32,
    pub net_luid: u64,
    pub if_index: u32,
    pub max_packet_size: u32,
    pub max_entry_size: u32,
    /// `OFFLOAD_*` the driver/OS combination can do at all.
    pub supported_offloads: u32,
    /// `OFFLOAD_*` currently negotiated with the TCP/IP stack.
    pub active_offloads: u32,
    pub reserved: u32,
}

const _: () = assert!(size_of::<AdapterInfo>() == 40);

/// `TUNDRA_STATISTICS`
#[repr(C)]
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Statistics {
    pub tx_packets: u64,
    pub tx_bytes: u64,
    pub tx_dropped: u64,
    pub rx_packets: u64,
    pub rx_bytes: u64,
    pub rx_dropped: u64,
    pub tx_gso_packets: u64,
    pub rx_coalesced: u64,
    pub rx_segmented: u64,
}
