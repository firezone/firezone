#![allow(clippy::unwrap_used)]

use firezone_relay::{AllocationPort, ClientSocket, PeerSocket};
use std::time::Duration;
use tokio::net::UdpSocket;

use ebpf_shared::Config;
use stun_codec::rfc5766::attributes::ChannelNumber;

#[tokio::test]
async fn ping_pong() {
    let _guard = firezone_logging::test("trace,mio=off");

    let mut program = firezone_relay::ebpf::Program::try_load("lo").unwrap();

    // Linux does not set the correct UDP checksum when sending the packet, so our updated checksum in the eBPF code will be wrong and later dropped.
    // To make the test work, we therefore need to tell the eBPF program to disable UDP checksumming by just setting it to 0.
    program
        .set_config(Config {
            udp_checksum_enabled: false,
        })
        .unwrap();

    let client = UdpSocket::bind("127.0.0.1:0").await.unwrap();
    let peer = UdpSocket::bind("127.0.0.1:0").await.unwrap();

    let client_socket = client.local_addr().unwrap();
    let peer_socket = peer.local_addr().unwrap();

    let channel_number = ChannelNumber::new(0x4000).unwrap();
    let allocation_port = 50000;

    program
        .add_channel_binding(
            ClientSocket::new(client_socket),
            channel_number,
            PeerSocket::new(peer_socket),
            AllocationPort::new(allocation_port),
        )
        .unwrap();

    let msg = b"ping";
    let msg_len = msg.len();
    let mut buf = [0u8; 512];

    let (header, payload) = buf.split_at_mut(4);
    payload[..msg_len].copy_from_slice(msg);

    let len =
        firezone_relay::ChannelData::encode_header_to_slice(channel_number, msg_len as u16, header);

    client.send_to(&buf[..len], "127.0.0.1:3478").await.unwrap();

    let mut recv_buf = [0u8; 512];

    let (len, from) = tokio::time::timeout(Duration::from_secs(1), peer.recv_from(&mut recv_buf))
        .await
        .unwrap()
        .unwrap();

    assert_eq!(from.port(), allocation_port);
    assert_eq!(&recv_buf[..len], msg);
}
