//! Per-packet work of the sans-IO Client and Gateway state.

use std::net::{Ipv4Addr, SocketAddr, SocketAddrV4};

use divan::Bencher;
use snownet::TransmitBuffer;

use crate::setup::{
    RESOURCES, Resource, SIZES, Tunnel, encapsulate_on_client, encapsulate_on_gateway,
};

const CLIENT_SOCKET: SocketAddr =
    SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::new(10, 0, 0, 1), 1111));
const GATEWAY_SOCKET: SocketAddr =
    SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::new(10, 0, 0, 2), 2222));

#[divan::bench(args = RESOURCES, consts = SIZES, sample_size = 64)]
fn client_outbound<const SIZE: usize>(bencher: Bencher, resource: Resource) {
    let mut tunnel = Tunnel::established(resource, CLIENT_SOCKET, GATEWAY_SOCKET);
    let packet = tunnel.request(SIZE);
    let mut transmits = TransmitBuffer::default();

    bencher
        .with_inputs(|| packet.clone())
        .bench_local_values(|packet| {
            tunnel
                .client
                .handle_tun_input(packet, tunnel.now, &mut transmits)
                .unwrap();
            assert!(transmits.poll_transmit().is_some());
        });
}

#[divan::bench(args = RESOURCES, consts = SIZES, sample_size = 64)]
fn gateway_inbound<const SIZE: usize>(bencher: Bencher, resource: Resource) {
    let mut tunnel = Tunnel::established(resource, CLIENT_SOCKET, GATEWAY_SOCKET);
    let packet = tunnel.request(SIZE);
    let Tunnel {
        client,
        gateway,
        now,
        ..
    } = &mut tunnel;
    let mut transmits = TransmitBuffer::default();

    bencher
        .with_inputs(|| encapsulate_on_client(client, packet.clone(), *now, &mut transmits))
        .bench_local_refs(|datagram| {
            let packet = gateway
                .handle_network_input(GATEWAY_SOCKET, CLIENT_SOCKET, &datagram.payload, *now)
                .unwrap();
            assert!(packet.is_some());
        });
}

#[divan::bench(args = RESOURCES, consts = SIZES, sample_size = 64)]
fn gateway_outbound<const SIZE: usize>(bencher: Bencher, resource: Resource) {
    let mut tunnel = Tunnel::established(resource, CLIENT_SOCKET, GATEWAY_SOCKET);
    let reply = tunnel.reply(SIZE);
    let mut transmits = TransmitBuffer::default();

    bencher
        .with_inputs(|| reply.clone())
        .bench_local_values(|reply| {
            tunnel
                .gateway
                .handle_tun_input(reply, tunnel.now, &mut transmits)
                .unwrap();
            assert!(transmits.poll_transmit().is_some());
        });
}

#[divan::bench(args = RESOURCES, consts = SIZES, sample_size = 64)]
fn client_inbound<const SIZE: usize>(bencher: Bencher, resource: Resource) {
    let mut tunnel = Tunnel::established(resource, CLIENT_SOCKET, GATEWAY_SOCKET);
    let reply = tunnel.reply(SIZE);
    let Tunnel {
        client,
        gateway,
        now,
        ..
    } = &mut tunnel;
    let mut transmits = TransmitBuffer::default();

    bencher
        .with_inputs(|| encapsulate_on_gateway(gateway, reply.clone(), *now, &mut transmits))
        .bench_local_refs(|datagram| {
            let packet = client
                .handle_network_input(CLIENT_SOCKET, GATEWAY_SOCKET, &datagram.payload, *now)
                .unwrap();
            assert!(packet.is_some());
        });
}
