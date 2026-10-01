#![cfg_attr(test, allow(clippy::unwrap_used))]

//! Packet coalescing, segmentation, and checksum offload handling for TUN backends.

mod coalesce;
pub mod virtio;

pub use coalesce::{ChecksumMode, CoalescedPacket, OffloadMetadata, PacketCoalescer, Protocol};
