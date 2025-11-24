//! Extension crate for `etherparse` that provides mutable slices for headers.
//!
//! To be eventually upstreamed to `etherparse`.

#![cfg_attr(not(test), no_std)]
#![cfg_attr(test, allow(clippy::unwrap_used))]

mod icmpv4_header_slice_mut;
mod icmpv6_header_slice_mut;
mod ipv4_header_slice_mut;
mod ipv6_header_slice_mut;
mod slice_utils;
mod tcp_header_slice_mut;
mod udp_header_slice_mut;

pub use icmpv4_header_slice_mut::*;
pub use icmpv6_header_slice_mut::*;
pub use ipv4_header_slice_mut::*;
pub use ipv6_header_slice_mut::*;
pub use tcp_header_slice_mut::*;
pub use udp_header_slice_mut::*;
