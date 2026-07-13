//! Factory module for making all kinds of packets.

use crate::{IpPacket, IpPacketBuf, Ipv6HeaderSlice, MAX_IP_SIZE, UdpSlice};
use anyhow::{Context as _, Result, bail};
use ingot::icmp::{IcmpV4, IcmpV6};
use ingot::ip::{IpProtocol, Ipv4, Ipv6};
use ingot::tcp::{Tcp, TcpFlags as IngotTcpFlags};
use ingot::types::{Emit, HeaderLen};
use ingot::udp::Udp;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};

pub fn fz_p2p_control(header: [u8; 8], control_payload: &[u8]) -> Result<IpPacket> {
    let ip_payload_size = header.len() + control_payload.len();

    let ipv6 = Ipv6 {
        payload_len: ip_payload_size as u16,
        next_header: crate::fz_p2p_control::IP_NUMBER,
        hop_limit: 0,
        source: crate::fz_p2p_control::ADDR.into(),
        destination: crate::fz_p2p_control::ADDR.into(),
        ..Default::default()
    };

    let packet_size = Ipv6HeaderSlice::LEN + ip_payload_size;
    anyhow::ensure!(packet_size <= crate::MAX_IP_SIZE);

    let mut packet_buf = IpPacketBuf::new();
    let buf = packet_buf.buf();

    let rest = ipv6.emit_prefix(&mut buf[..packet_size]).with_context(|| {
        format!("Buffer should be big enough; ip_payload_size={ip_payload_size}")
    })?;
    rest[..8].copy_from_slice(&header);
    rest[8..].copy_from_slice(control_payload);

    let ip_packet = IpPacket::new(packet_buf, packet_size).context("Unable to create IP packet")?;

    Ok(ip_packet)
}

pub fn icmp_request_packet(
    src: IpAddr,
    dst: impl Into<IpAddr>,
    seq: u16,
    identifier: u16,
    payload: &[u8],
) -> Result<IpPacket> {
    let echo = crate::IcmpEchoHeader {
        id: identifier,
        seq,
    };

    match (src, dst.into()) {
        (IpAddr::V4(src), IpAddr::V4(dst)) => {
            icmpv4_packet(src, dst, 64, crate::Icmpv4Type::EchoRequest(echo), payload)
        }
        (IpAddr::V6(src), IpAddr::V6(dst)) => {
            icmpv6_packet(src, dst, 64, crate::Icmpv6Type::EchoRequest(echo), payload)
        }
        _ => bail!(IpVersionMismatch),
    }
}

pub fn icmp_reply_packet(
    src: IpAddr,
    dst: impl Into<IpAddr>,
    seq: u16,
    identifier: u16,
    payload: &[u8],
) -> Result<IpPacket> {
    let echo = crate::IcmpEchoHeader {
        id: identifier,
        seq,
    };

    match (src, dst.into()) {
        (IpAddr::V4(src), IpAddr::V4(dst)) => {
            icmpv4_packet(src, dst, 64, crate::Icmpv4Type::EchoReply(echo), payload)
        }
        (IpAddr::V6(src), IpAddr::V6(dst)) => {
            icmpv6_packet(src, dst, 64, crate::Icmpv6Type::EchoReply(echo), payload)
        }
        _ => bail!(IpVersionMismatch),
    }
}

/// Creates an ICMP packet with the given type.
pub fn icmpv4_packet(
    src: Ipv4Addr,
    dst: Ipv4Addr,
    ttl: u8,
    icmp_type: crate::Icmpv4Type,
    payload: &[u8],
) -> Result<IpPacket> {
    let (ty, code, rest_of_hdr) = icmp_type.to_wire();

    let icmp = IcmpV4 {
        ty: ingot::icmp::IcmpV4Type(ty),
        code,
        checksum: 0,
        rest_of_hdr,
    };

    ipv4_packet(src, dst, ttl, IpProtocol::ICMP, icmp, payload)
}

/// Creates an ICMPv6 packet with the given type.
pub fn icmpv6_packet(
    src: Ipv6Addr,
    dst: Ipv6Addr,
    hop_limit: u8,
    icmp_type: crate::Icmpv6Type,
    payload: &[u8],
) -> Result<IpPacket> {
    let (ty, code, rest_of_hdr) = icmp_type.to_wire();

    let icmp = IcmpV6 {
        ty: ingot::icmp::IcmpV6Type(ty),
        code,
        checksum: 0,
        rest_of_hdr,
    };

    ipv6_packet(src, dst, hop_limit, IpProtocol::ICMP_V6, icmp, payload)
}

pub fn tcp_packet<IP>(
    saddr: IP,
    daddr: IP,
    sport: u16,
    dport: u16,
    flags: TcpFlags,
    payload: &[u8],
) -> Result<IpPacket>
where
    IP: Into<IpAddr>,
{
    tcp_packet_with_options(saddr, daddr, sport, dport, 0, flags, &[], payload)
}

/// Creates a TCP packet with the given options.
///
/// The length of `options` must be a multiple of 4.
#[expect(clippy::too_many_arguments, reason = "TCP headers have many fields.")]
pub fn tcp_packet_with_options<IP>(
    saddr: IP,
    daddr: IP,
    sport: u16,
    dport: u16,
    seq: u32,
    flags: TcpFlags,
    options: &[u8],
    payload: &[u8],
) -> Result<IpPacket>
where
    IP: Into<IpAddr>,
{
    let TcpFlags { syn, ack, rst } = flags;

    anyhow::ensure!(
        options.len().is_multiple_of(4),
        "TCP options must be padded to a multiple of 4"
    );

    let mut tcp_flags = IngotTcpFlags::empty();
    tcp_flags.set(IngotTcpFlags::SYN, syn);
    tcp_flags.set(IngotTcpFlags::ACK, ack);
    tcp_flags.set(IngotTcpFlags::RST, rst);

    let tcp = Tcp {
        source: sport,
        destination: dport,
        sequence: seq,
        data_offset: 5 + (options.len() / 4) as u8,
        flags: tcp_flags,
        window_size: 128,
        options: options.to_vec(),
        ..Default::default()
    };

    match (saddr.into(), daddr.into()) {
        (IpAddr::V4(src), IpAddr::V4(dst)) => {
            ipv4_packet(src, dst, 64, IpProtocol::TCP, tcp, payload)
        }
        (IpAddr::V6(src), IpAddr::V6(dst)) => {
            ipv6_packet(src, dst, 64, IpProtocol::TCP, tcp, payload)
        }
        _ => bail!(IpVersionMismatch),
    }
}

#[derive(Debug, Default, Clone, Copy)]
pub struct TcpFlags {
    pub syn: bool,
    pub ack: bool,
    pub rst: bool,
}

pub fn udp_packet<SIP, DIP>(
    saddr: SIP,
    daddr: DIP,
    sport: u16,
    dport: u16,
    payload: &[u8],
) -> Result<IpPacket>
where
    SIP: Into<IpAddr>,
    DIP: Into<IpAddr>,
{
    let udp = Udp {
        source: sport,
        destination: dport,
        length: (UdpSlice::HEADER_LEN + payload.len()) as u16,
        checksum: 0,
    };

    match (saddr.into(), daddr.into()) {
        (IpAddr::V4(src), IpAddr::V4(dst)) => {
            ipv4_packet(src, dst, 64, IpProtocol::UDP, udp, payload)
        }
        (IpAddr::V6(src), IpAddr::V6(dst)) => {
            ipv6_packet(src, dst, 64, IpProtocol::UDP, udp, payload)
        }
        _ => bail!(IpVersionMismatch),
    }
}

pub fn icmp_dest_unreachable_prohibited(original_packet: &IpPacket) -> Result<IpPacket> {
    icmp_dest_unreachable(
        original_packet,
        crate::icmpv4::DestUnreachableHeader::FilterProhibited,
        crate::icmpv6::DestUnreachableCode::Prohibited,
    )
}

pub fn icmp_dest_unreachable_network(original_packet: &IpPacket) -> Result<IpPacket> {
    icmp_dest_unreachable(
        original_packet,
        crate::icmpv4::DestUnreachableHeader::Network,
        crate::icmpv6::DestUnreachableCode::Address,
    )
}

fn icmp_dest_unreachable(
    original_packet: &IpPacket,
    icmpv4: crate::icmpv4::DestUnreachableHeader,
    icmpv6: crate::icmpv6::DestUnreachableCode,
) -> Result<IpPacket> {
    let src = original_packet.source();
    let dst = original_packet.destination();

    let icmp_error = match (src, dst) {
        (IpAddr::V4(src), IpAddr::V4(dst)) => {
            icmpv4_unreachable(dst, src, original_packet, icmpv4)?
        }
        (IpAddr::V6(src), IpAddr::V6(dst)) => {
            icmpv6_unreachable(dst, src, original_packet, icmpv6)?
        }
        (IpAddr::V4(_), IpAddr::V6(_)) => {
            bail!("Invalid IP packet: Inconsistent IP address versions")
        }
        (IpAddr::V6(_), IpAddr::V4(_)) => {
            bail!("Invalid IP packet: Inconsistent IP address versions")
        }
    };

    Ok(icmp_error)
}

fn icmpv4_unreachable(
    src: Ipv4Addr,
    dst: Ipv4Addr,
    original_packet: &IpPacket,
    code: crate::icmpv4::DestUnreachableHeader,
) -> Result<IpPacket, anyhow::Error> {
    let payload = original_packet.packet();

    let header_len = original_packet
        .ipv4_header()
        .context("Not an IPv4 packet")?
        .header_len();
    let icmp_error_payload_len = header_len + 8;

    let actual_payload_len = std::cmp::min(payload.len(), icmp_error_payload_len);
    let error_payload = &payload[..actual_payload_len];

    icmpv4_packet(
        src,
        dst,
        20,
        crate::Icmpv4Type::DestinationUnreachable(code),
        error_payload,
    )
}

fn icmpv6_unreachable(
    src: Ipv6Addr,
    dst: Ipv6Addr,
    original_packet: &IpPacket,
    code: crate::icmpv6::DestUnreachableCode,
) -> Result<IpPacket, anyhow::Error> {
    const MAX_ICMP_ERROR_PAYLOAD_LEN: usize =
        MAX_IP_SIZE - Ipv6HeaderSlice::LEN - crate::Icmpv6Slice::HEADER_LEN;

    let payload = original_packet.packet();

    let actual_payload_len = std::cmp::min(payload.len(), MAX_ICMP_ERROR_PAYLOAD_LEN);
    let error_payload = &payload[..actual_payload_len];

    icmpv6_packet(
        src,
        dst,
        20,
        crate::Icmpv6Type::DestinationUnreachable(code),
        error_payload,
    )
}

/// Creates an IPv4 packet with the given transport header and payload,
/// computing all checksums.
fn ipv4_packet(
    src: Ipv4Addr,
    dst: Ipv4Addr,
    ttl: u8,
    protocol: IpProtocol,
    transport_header: impl Emit,
    payload: &[u8],
) -> Result<IpPacket> {
    let total_len = Ipv4::MINIMUM_LENGTH + transport_header.packet_length() + payload.len();

    anyhow::ensure!(
        total_len <= MAX_IP_SIZE,
        "Payload is too big; len={total_len}"
    );

    let ipv4 = Ipv4 {
        ihl: 5,
        total_len: total_len as u16,
        hop_limit: ttl,
        protocol,
        source: src.into(),
        destination: dst.into(),
        ..Default::default()
    };

    let mut packet_buf = IpPacketBuf::new();

    emit_packet(packet_buf.buf(), total_len, ipv4, transport_header, payload)?;

    let mut packet = IpPacket::new(packet_buf, total_len).context("Failed to create IP packet")?;
    packet.compute_checksums();

    Ok(packet)
}

/// Creates an IPv6 packet with the given transport header and payload,
/// computing all checksums.
fn ipv6_packet(
    src: Ipv6Addr,
    dst: Ipv6Addr,
    hop_limit: u8,
    protocol: IpProtocol,
    transport_header: impl Emit,
    payload: &[u8],
) -> Result<IpPacket> {
    let payload_len = transport_header.packet_length() + payload.len();
    let total_len = Ipv6HeaderSlice::LEN + payload_len;

    anyhow::ensure!(
        total_len <= MAX_IP_SIZE,
        "Payload is too big; len={total_len}"
    );

    let ipv6 = Ipv6 {
        payload_len: payload_len as u16,
        next_header: protocol,
        hop_limit,
        source: src.into(),
        destination: dst.into(),
        ..Default::default()
    };

    let mut packet_buf = IpPacketBuf::new();

    emit_packet(packet_buf.buf(), total_len, ipv6, transport_header, payload)?;

    let mut packet = IpPacket::new(packet_buf, total_len).context("Failed to create IP packet")?;
    packet.compute_checksums();

    Ok(packet)
}

fn emit_packet(
    buf: &mut [u8],
    total_len: usize,
    ip_header: impl Emit,
    transport_header: impl Emit,
    payload: &[u8],
) -> Result<()> {
    let buf = buf
        .get_mut(..total_len)
        .context("Buffer too small for packet")?;

    let rest = ip_header
        .emit_prefix(buf)
        .ok()
        .context("Failed to emit IP header")?;
    let rest = transport_header
        .emit_prefix(rest)
        .ok()
        .context("Failed to emit transport header")?;
    rest.copy_from_slice(payload);

    Ok(())
}

#[derive(thiserror::Error, Debug)]
#[error("IPs must be of the same version")]
pub struct IpVersionMismatch;

#[cfg(all(test, feature = "proptest"))]
mod tests {
    use proptest::{
        collection,
        prelude::{Strategy, any},
    };

    use crate::{Ipv4HeaderSlice, Ipv6HeaderSlice, MAX_IP_SIZE, UdpSlice};

    use super::*;

    #[test_strategy::proptest()]
    fn ipv4_icmp_unreachable(
        #[strategy(payload(MAX_IP_SIZE - Ipv4HeaderSlice::MIN_LEN - UdpSlice::HEADER_LEN))]
        payload: Vec<u8>,
    ) {
        let unreachable_packet = udp_packet(
            Ipv4Addr::new(10, 0, 0, 1),
            Ipv4Addr::LOCALHOST,
            0,
            0,
            &payload,
        )
        .unwrap();

        let icmp_error = icmp_dest_unreachable_network(&unreachable_packet).unwrap();

        assert_eq!(
            icmp_error.destination(),
            IpAddr::V4(Ipv4Addr::new(10, 0, 0, 1))
        );
        assert_eq!(icmp_error.source(), IpAddr::V4(Ipv4Addr::LOCALHOST));
        assert!(matches!(icmp_error.icmp_error(), Ok(Some(_))));
    }

    #[test_strategy::proptest()]
    fn ipv6_icmp_unreachable_max_payload(
        #[strategy(payload(MAX_IP_SIZE - Ipv6HeaderSlice::LEN - UdpSlice::HEADER_LEN))]
        payload: Vec<u8>,
    ) {
        let unreachable_packet = udp_packet(
            Ipv6Addr::new(1, 0, 0, 0, 0, 0, 0, 1),
            Ipv6Addr::LOCALHOST,
            0,
            0,
            &payload,
        )
        .unwrap();

        let icmp_error = icmp_dest_unreachable_network(&unreachable_packet).unwrap();

        assert_eq!(
            icmp_error.destination(),
            IpAddr::V6(Ipv6Addr::new(1, 0, 0, 0, 0, 0, 0, 1))
        );
        assert_eq!(icmp_error.source(), IpAddr::V6(Ipv6Addr::LOCALHOST));
        assert!(matches!(icmp_error.icmp_error(), Ok(Some(_))));
    }

    fn payload(max_size: usize) -> impl Strategy<Value = Vec<u8>> {
        collection::vec(any::<u8>(), 0..=max_size)
    }
}
