use std::{
    net::{IpAddr, Ipv4Addr, SocketAddr},
    time::{Duration, Instant},
};

use ip_packet::{IcmpEchoHeader, Icmpv4Type, icmpv4, make, make::TcpSegmentFlags};

use super::*;

const PEER: Ipv4Addr = Ipv4Addr::new(100, 64, 0, 2);
const RESOURCE: Ipv4Addr = Ipv4Addr::new(10, 0, 0, 5);
const ROUTER: Ipv4Addr = Ipv4Addr::new(10, 0, 0, 1);

fn commands(f: &mut Forwarder) -> Vec<Command> {
    std::iter::from_fn(|| f.poll_command()).collect()
}

fn packets(f: &mut Forwarder) -> Vec<IpPacket> {
    std::iter::from_fn(|| f.poll_packet()).collect()
}

#[test]
fn udp_is_proxied_both_ways_and_closed_when_idle() {
    let t0 = Instant::now();
    let mut f = Forwarder::new(t0);

    f.handle_packet(
        make::udp_packet(PEER, RESOURCE, 40000, 53, b"hello").unwrap(),
        t0,
    );

    let [Command::UdpSend { flow, remote, data }] =
        <[Command; 1]>::try_from(commands(&mut f)).unwrap()
    else {
        panic!("expected one send")
    };
    assert_eq!(remote, SocketAddr::new(RESOURCE.into(), 53));
    assert_eq!(data, b"hello");

    f.handle_event(
        Event::UdpData {
            flow,
            data: b"world".to_vec(),
        },
        t0,
    );

    let [reply] = <[IpPacket; 1]>::try_from(packets(&mut f)).unwrap();
    assert_eq!(reply.source(), IpAddr::from(RESOURCE));
    assert_eq!(reply.destination(), IpAddr::from(PEER));
    let udp = reply.as_udp().unwrap();
    assert_eq!(udp.source_port(), 53);
    assert_eq!(udp.destination_port(), 40000);
    assert_eq!(udp.payload(), b"world");

    f.handle_timeout(t0 + Duration::from_secs(61));
    assert_eq!(commands(&mut f), vec![Command::UdpClose { flow }]);
    assert_eq!(f.num_flows(), (0, 0, 0));
}

#[test]
fn udp_unreachable_becomes_icmp_port_unreachable() {
    let t0 = Instant::now();
    let mut f = Forwarder::new(t0);

    f.handle_packet(
        make::udp_packet(PEER, RESOURCE, 40000, 53, b"hello").unwrap(),
        t0,
    );
    let [Command::UdpSend { flow, .. }] = <[Command; 1]>::try_from(commands(&mut f)).unwrap()
    else {
        panic!("expected one send")
    };

    f.handle_event(Event::UdpUnreachable { flow }, t0);

    let [error] = <[IpPacket; 1]>::try_from(packets(&mut f)).unwrap();
    assert_eq!(error.source(), IpAddr::from(RESOURCE));
    assert_eq!(error.destination(), IpAddr::from(PEER));
    assert_eq!(
        error.as_icmpv4().unwrap().icmp_type(),
        Icmpv4Type::DestinationUnreachable(icmpv4::DestUnreachableHeader::Port)
    );
    assert_eq!(commands(&mut f), vec![Command::UdpClose { flow }]);
}

#[test]
fn icmp_echo_is_answered_with_the_peers_identifier_and_payload() {
    let t0 = Instant::now();
    let mut f = Forwarder::new(t0);

    f.handle_packet(
        make::icmp_request_packet(PEER.into(), RESOURCE, 7, 0x1234, b"ping").unwrap(),
        t0,
    );

    let [
        Command::IcmpEcho {
            flow,
            remote,
            sequence,
            payload,
            ttl,
        },
    ] = <[Command; 1]>::try_from(commands(&mut f)).unwrap()
    else {
        panic!("expected one echo")
    };
    assert_eq!(remote, IpAddr::from(RESOURCE));
    assert_eq!(sequence, 7);
    assert_eq!(payload, b"ping");
    assert_eq!(ttl, 64);

    f.handle_event(
        Event::IcmpReply {
            flow,
            sequence: 7,
            payload: b"ping".to_vec(),
        },
        t0,
    );

    let [reply] = <[IpPacket; 1]>::try_from(packets(&mut f)).unwrap();
    assert_eq!(reply.source(), IpAddr::from(RESOURCE));
    assert_eq!(reply.destination(), IpAddr::from(PEER));
    let icmp = reply.as_icmpv4().unwrap();
    assert_eq!(
        icmp.icmp_type(),
        Icmpv4Type::EchoReply(IcmpEchoHeader { id: 0x1234, seq: 7 })
    );
    assert_eq!(icmp.payload(), b"ping");

    f.handle_timeout(t0 + Duration::from_secs(31));
    assert_eq!(commands(&mut f), vec![Command::IcmpClose { flow }]);
}

#[test]
fn icmp_errors_quote_the_request() {
    let t0 = Instant::now();
    let mut f = Forwarder::new(t0);

    for seq in [1, 2] {
        f.handle_packet(
            make::icmp_request_packet(PEER.into(), RESOURCE, seq, 9, b"x").unwrap(),
            t0,
        );
    }
    let [Command::IcmpEcho { flow, .. }, Command::IcmpEcho { .. }] =
        <[Command; 2]>::try_from(commands(&mut f)).unwrap()
    else {
        panic!("expected two echos")
    };

    f.handle_event(
        Event::IcmpTimeExceeded {
            flow,
            sequence: 1,
            from: ROUTER.into(),
        },
        t0,
    );
    f.handle_event(
        Event::IcmpUnreachable {
            flow,
            sequence: None,
        },
        t0,
    );

    let [exceeded, unreachable] = <[IpPacket; 2]>::try_from(packets(&mut f)).unwrap();

    assert_eq!(exceeded.source(), IpAddr::from(ROUTER));
    assert_eq!(exceeded.destination(), IpAddr::from(PEER));
    assert_eq!(
        exceeded.as_icmpv4().unwrap().icmp_type(),
        Icmpv4Type::TimeExceeded(icmpv4::TimeExceededCode::TTL_EXCEEDED_IN_TRANSIT)
    );
    let (failed, _) = exceeded.icmp_error().unwrap().unwrap();
    assert_eq!(failed.dst(), IpAddr::from(RESOURCE));

    assert_eq!(unreachable.source(), IpAddr::from(RESOURCE));
    assert_eq!(
        unreachable.as_icmpv4().unwrap().icmp_type(),
        Icmpv4Type::DestinationUnreachable(icmpv4::DestUnreachableHeader::Host)
    );
}

#[test]
fn tcp_connection_is_proxied_both_ways() {
    let t0 = Instant::now();
    let mut f = Forwarder::new(t0);
    let flags = |syn, ack, fin| TcpSegmentFlags {
        syn,
        ack,
        fin,
        ..Default::default()
    };
    let segment = |seq, ack, flags, payload: &[u8]| {
        make::tcp_segment(PEER, RESOURCE, 50000, 80, seq, ack, flags, payload).unwrap()
    };

    // The SYN gets a SYN-ACK, and the host connection is opened.
    f.handle_packet(segment(1000, 0, flags(true, false, false), &[]), t0);

    let [Command::TcpConnect { flow, remote }] =
        <[Command; 1]>::try_from(commands(&mut f)).unwrap()
    else {
        panic!("expected a connect")
    };
    assert_eq!(remote, SocketAddr::new(RESOURCE.into(), 80));

    let [syn_ack] = <[IpPacket; 1]>::try_from(packets(&mut f)).unwrap();
    let tcp = syn_ack.as_tcp().unwrap();
    assert!(tcp.syn() && tcp.ack());
    assert_eq!(tcp.acknowledgment_number(), 1001);
    let mut server_seq = tcp.sequence_number().wrapping_add(1);

    // The host connects before the peer's ACK arrives: nothing to do yet, and the
    // half-open receive side must not read as the peer having closed.
    f.handle_event(Event::TcpConnected { flow }, t0);
    assert!(commands(&mut f).is_empty());

    // Once established, the driver may read from the host.
    f.handle_packet(
        segment(1001, server_seq, flags(false, true, false), &[]),
        t0,
    );
    let [Command::TcpRecvCredit { flow: f1, bytes }] =
        <[Command; 1]>::try_from(commands(&mut f)).unwrap()
    else {
        panic!("expected a credit")
    };
    assert_eq!(f1, flow);
    assert!(bytes > 0);

    // Data from the peer goes to the host within the send credit.
    let request = b"GET / HTTP/1.0\r\n\r\n";
    f.handle_packet(
        segment(1001, server_seq, flags(false, true, false), request),
        t0,
    );
    let mut peer_seq = 1001 + request.len() as u32;

    let [Command::TcpSend { flow: f2, data }] = <[Command; 1]>::try_from(commands(&mut f)).unwrap()
    else {
        panic!("expected a send")
    };
    assert_eq!(f2, flow);
    assert_eq!(data, request);
    let _ack = packets(&mut f);

    // Data from the host goes to the peer.
    let response = b"HTTP/1.0 200 OK\r\n\r\n";
    f.handle_event(
        Event::TcpData {
            flow,
            data: response.to_vec(),
        },
        t0,
    );
    let data_segments = packets(&mut f);
    let payload = data_segments
        .iter()
        .flat_map(|p| p.as_tcp().unwrap().payload().to_vec())
        .collect::<Vec<_>>();
    assert_eq!(payload, response);
    server_seq += response.len() as u32;

    // The host closing its write side sends a FIN to the peer.
    f.handle_event(
        Event::TcpSent {
            flow,
            bytes: request.len(),
        },
        t0,
    );
    f.handle_event(Event::TcpEof { flow }, t0);
    let fin = packets(&mut f)
        .into_iter()
        .find(|p| p.as_tcp().unwrap().fin())
        .expect("a FIN");
    assert_eq!(fin.as_tcp().unwrap().sequence_number(), server_seq);
    server_seq += 1;

    // The peer acknowledges it and closes too; the host connection is shut down and closed.
    f.handle_packet(
        segment(peer_seq, server_seq, flags(false, true, true), &[]),
        t0,
    );
    peer_seq += 1;
    assert_eq!(
        commands(&mut f),
        vec![Command::TcpShutdownWrite { flow }],
        "peer_seq={peer_seq}"
    );

    f.handle_timeout(t0 + Duration::from_secs(15));
    assert_eq!(commands(&mut f), vec![Command::TcpClose { flow }]);
    assert_eq!(f.num_flows(), (0, 0, 0));
}

#[test]
fn refused_host_connection_resets_the_peer() {
    let t0 = Instant::now();
    let mut f = Forwarder::new(t0);

    f.handle_packet(
        make::tcp_segment(
            PEER,
            RESOURCE,
            50000,
            80,
            1000,
            0,
            TcpSegmentFlags {
                syn: true,
                ..Default::default()
            },
            &[],
        )
        .unwrap(),
        t0,
    );
    let [Command::TcpConnect { flow, .. }] = <[Command; 1]>::try_from(commands(&mut f)).unwrap()
    else {
        panic!("expected a connect")
    };
    let _syn_ack = packets(&mut f);

    f.handle_event(
        Event::TcpConnectFailed {
            flow,
            refused: true,
        },
        t0,
    );

    let rst = packets(&mut f)
        .into_iter()
        .find(|p| p.as_tcp().unwrap().rst())
        .expect("a RST");
    assert_eq!(rst.destination(), IpAddr::from(PEER));
    assert!(commands(&mut f).is_empty(), "the host side is already gone");
    assert_eq!(f.num_flows(), (0, 0, 0));
}
