//! Packets as they appear in the rings.
//!
//! This module is platform-independent so it can be unit-tested anywhere.

use crate::abi::PacketHeader;

/// A packet received from the OS.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Packet<'a> {
    pub header: PacketHeader,
    /// The IP packet.
    pub data: &'a [u8],
    /// The IP packet preceded by its legacy `virtio_net_hdr`, i.e. exactly what a Linux
    /// TUN device with `IFF_VNET_HDR` returns from `read()`.
    pub vnet_frame: &'a [u8],
}

/// A mutable packet received from the OS, e.g. to complete checksums in place.
#[derive(Debug, PartialEq, Eq)]
pub struct PacketMut<'a> {
    pub header: PacketHeader,
    pub data: &'a mut [u8],
}
