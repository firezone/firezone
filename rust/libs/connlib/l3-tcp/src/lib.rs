//! Abstractions for working with the TCP protocol from an OSI-layer 3 perspective, i.e. IP.
//!
//! This crate is very much work-in-progress.
//! The abstractions in here are intended to grow as we learn more about our needs for interacting with TCP.

mod interface;
mod stub_device;

pub use crate::interface::create_interface;
pub use crate::stub_device::InMemoryDevice;
pub use smoltcp::iface::{Interface, PollResult, SocketHandle, SocketSet};
pub use smoltcp::socket::Socket as AnySocket;
pub use smoltcp::socket::tcp::{Socket, State};
pub use smoltcp::time::{Duration, Instant};
pub use smoltcp::wire::IpEndpoint;

pub fn create_tcp_socket() -> Socket<'static> {
    /// The 2-byte length prefix of DNS over TCP messages limits their size to effectively u16::MAX.
    /// It is quite unlikely that we have to buffer _multiple_ of these max-sized messages.
    /// Being able to buffer at least one of them means we can handle the extreme case.
    /// In practice, this allows the OS to queue multiple queries even if we can't immediately process them.
    const MAX_TCP_DNS_MSG_LENGTH: usize = u16::MAX as usize;

    Socket::new(
        smoltcp::storage::RingBuffer::new(vec![0u8; MAX_TCP_DNS_MSG_LENGTH]),
        smoltcp::storage::RingBuffer::new(vec![0u8; MAX_TCP_DNS_MSG_LENGTH]),
    )
}

/// Computes an instance of [`smoltcp::time::Instant`] based on a given starting point and the current time.
pub fn now(boot: std::time::Instant, now: std::time::Instant) -> Instant {
    let millis_since_startup = now.duration_since(boot).as_millis();

    Instant::from_millis(millis_since_startup as i64)
}
