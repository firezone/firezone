//! Linux-specific TUN I/O using segmentation offloads (`IFF_VNET_HDR` + `TUNSETOFFLOAD`).
//!
//! With offloads enabled, the kernel exchanges "super packets" of up to 64 KiB with us:
//!
//! - Reads may return a single TSO / USO packet that we split into MTU-sized [`IpPacket`](ip_packet::IpPacket)s
//!   before handing them to the main thread ([`split`]).
//! - Writes may combine multiple same-flow packets into one GSO write that traverses the
//!   kernel's network stack as a single skb ([`packet_coalescer`]).
//!
//! Coalescing extends across one batch of packets ready at the same state transition.

pub mod split;
pub mod virtio;

#[cfg(test)]
mod tests;

/// A TUN device file descriptor together with whether segmentation offloads are enabled on it.
///
/// The device always has `IFF_VNET_HDR` set, so reads and writes carry a
/// `virtio_net_hdr` either way; without offloads it is simply always trivial
/// (`VIRTIO_NET_HDR_GSO_NONE`) and writes must not use GSO.
#[derive(Clone)]
pub struct TunFd<T> {
    fd: T,
    offloads: bool,
}

impl<T> TunFd<T> {
    pub fn new(fd: T, offloads: bool) -> Self {
        Self { fd, offloads }
    }

    pub fn into_parts(self) -> (T, bool) {
        (self.fd, self.offloads)
    }
}
