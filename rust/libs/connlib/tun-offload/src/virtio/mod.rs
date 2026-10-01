//! Virtio network offload headers, checksum completion, and TCP/UDP segmentation.
//!
//! Frames use the 10-byte legacy header with native-endian multi-byte fields.

mod header;
mod split;

#[cfg(test)]
mod tests;

pub use header::{
    VIRTIO_NET_HDR_F_NEEDS_CSUM, VIRTIO_NET_HDR_GSO_NONE, VIRTIO_NET_HDR_GSO_TCPV4,
    VIRTIO_NET_HDR_GSO_TCPV6, VIRTIO_NET_HDR_GSO_UDP_L4, VNET_HDR_LEN, VirtioNetHdr, header_for,
};
pub use split::split;
