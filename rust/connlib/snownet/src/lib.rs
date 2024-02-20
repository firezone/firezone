//! A SANS-IO connectivity library for wireguard connections formed by ICE.

mod allocation;
mod backoff;
mod channel_data;
mod index;
mod info;
mod ip_packet;
mod node;
mod ringbuffer;
mod stun_binding;
mod utils;

pub use info::ConnectionInfo;
pub use ip_packet::{IpPacket, MutableIpPacket};
pub use node::{
    Answer, Client, ClientNode, Credentials, Error, Event, Node, Offer, Server, ServerNode,
    Transmit,
};
