mod client;
mod codec;
mod interface;
mod server;
mod stub_device;
mod time;

pub use client::{Client, QueryResult};
pub use server::{Query, Server};

fn create_tcp_socket() -> smoltcp::socket::tcp::Socket<'static> {
    /// The 2-byte length prefix of DNS over TCP messages limits their size to effectively u16::MAX.
    /// It is quite unlikely that we have to buffer _multiple_ of these max-sized messages.
    /// Being able to buffer at least one of them means we can handle the extreme case.
    /// In practice, this allows the OS to queue multiple queries even if we can't immediately process them.
    const MAX_TCP_DNS_MSG_LENGTH: usize = u16::MAX as usize;

    smoltcp::socket::tcp::Socket::new(
        smoltcp::storage::RingBuffer::new(vec![0u8; MAX_TCP_DNS_MSG_LENGTH]),
        smoltcp::storage::RingBuffer::new(vec![0u8; MAX_TCP_DNS_MSG_LENGTH]),
    )
}
