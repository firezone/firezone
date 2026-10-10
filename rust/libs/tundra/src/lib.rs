//! Rust bindings for the Tundra Windows TUN driver.
//!
//! * [`abi`]: the raw user <-> kernel interface (mirrors `include/tundra.h`).
//! * [`Packet`] / [`PacketMut`]: packets as the rings hold them.
//! * `Session` (Windows): packet I/O through rings shared with the driver.
//! * `Device` (Windows): queries and offload configuration.
//! * `Adapter` / `install_driver` (Windows): adapter lifecycle.
//!
//! # Offloads
//!
//! Packet headers use Linux `virtio_net_hdr` semantics, so segmentation and coalescing
//! code written for `IFF_VNET_HDR` TUN devices (segmentation, checksum completion,
//! coalescing) works unchanged; this crate deliberately doesn't duplicate it. Consumers
//! that do not want to deal with offloads call `Device::set_offloads` with `0`.
//!
//! # Async runtimes
//!
//! `Session` exposes `poll_*` methods plus `async` wrappers that work with any runtime:
//! wakeups come from the Windows thread pool waiting on the driver's events, so no
//! extra thread is needed and the whole data path can live on a single task.
//!
//! ```ignore
//! let mut session = Session::start(adapter.open()?, SessionConfig::default())?;
//! loop {
//!     for packet in session.receiver().recv().await?.iter() {
//!         // ... encrypt and send `packet.data` ...
//!     }
//!     let sender = session.sender();
//!     sender.send_ready(reply.len()).await?;
//!     sender.send_batch().push(PacketHeader::default(), &reply)?;
//! }
//! ```

#![cfg_attr(test, allow(clippy::unwrap_used))]

pub mod abi;
mod packet;

pub use abi::{AdapterInfo, PacketHeader, Statistics};
pub use packet::{Packet, PacketMut};

#[cfg(windows)]
mod adapter;
#[cfg(windows)]
mod device;
#[cfg(windows)]
mod session;

#[cfg(windows)]
pub use adapter::{Adapter, install_driver};
#[cfg(windows)]
pub use device::{Device, device_path};
#[cfg(windows)]
pub use session::{
    Receiver, RecvBatch, RecvIter, RecvIterMut, RingFull, SendBatch, Sender, Session, SessionConfig,
};
