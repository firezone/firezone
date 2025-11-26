//! Factory module for making all kinds of packets.

use crate::{IpPacket, IpPacketBuf, MAX_IP_SIZE};
use anyhow::{Context as _, Result, bail};
use etherparse::{Icmpv6Header, Ipv6Header, PacketBuilder, icmpv4, icmpv6};
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};

/// Helper macro to turn a [`PacketBuilder`] into an [`IpPacket`].
#[macro_export]
macro_rules! build {
    ($packet:expr, $payload:ident) => {{
        use ::anyhow::Context as _;

        let size = $packet.size($payload.len());
        let mut ip = $crate::IpPacketBuf::new();

        $packet
            .write(&mut std::io::Cursor::new(ip.buf()), &$payload)
            .with_context(|| format!("Payload is too big; len={size}"))?;

        let packet = IpPacket::new(ip, size).context("Failed to create IP packet")?;

        ::anyhow::Ok(packet)
    }};
}

pub fn fz_p2p_control(header: [u8; 8], control_payload: &[u8]) -> Result<IpPacket> {
    let ip_payload_size = header.len() + control_payload.len();

    anyhow::ensure!(ip_payload_size <= crate::MAX_IP_SIZE);

    let builder = etherparse::PacketBuilder::ipv6(
        crate::fz_p2p_control::ADDR.octets(),
        crate::fz_p2p_control::ADDR.octets(),
        0,
    );
    let packet_size = builder.size(ip_payload_size);

    let mut packet_buf = IpPacketBuf::new();

    let mut payload_buf = vec![0u8; 8 + control_payload.len()];
    payload_buf[..8].copy_from_slice(&header);
    payload_buf[8..].copy_from_slice(control_payload);

    builder
        .write(
            &mut std::io::Cursor::new(packet_buf.buf()),
            crate::fz_p2p_control::IP_NUMBER,
            &payload_buf,
        )
        .with_context(|| {
            format!("Buffer should be big enough; ip_payload_size={ip_payload_size}")
        })?;
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
    match (src, dst.into()) {
        (IpAddr::V4(src), IpAddr::V4(dst)) => {
            let packet = PacketBuilder::ipv4(src.octets(), dst.octets(), 64)
                .icmpv4_echo_request(identifier, seq);

            build!(packet, payload)
        }
        (IpAddr::V6(src), IpAddr::V6(dst)) => {
            let packet = PacketBuilder::ipv6(src.octets(), dst.octets(), 64)
                .icmpv6_echo_request(identifier, seq);

            build!(packet, payload)
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
    match (src, dst.into()) {
        (IpAddr::V4(src), IpAddr::V4(dst)) => {
            let packet = PacketBuilder::ipv4(src.octets(), dst.octets(), 64)
                .icmpv4_echo_reply(identifier, seq);

            build!(packet, payload)
        }
        (IpAddr::V6(src), IpAddr::V6(dst)) => {
            let packet = PacketBuilder::ipv6(src.octets(), dst.octets(), 64)
                .icmpv6_echo_reply(identifier, seq);

            build!(packet, payload)
        }
        _ => bail!(IpVersionMismatch),
    }
}

pub fn tcp_packet<IP>(
    saddr: IP,
    daddr: IP,
    sport: u16,
    dport: u16,
    flags: TcpFlags,
    payload: Vec<u8>,
) -> Result<IpPacket>
where
    IP: Into<IpAddr>,
{
    let TcpFlags { rst } = flags;

    match (saddr.into(), daddr.into()) {
        (IpAddr::V4(src), IpAddr::V4(dst)) => {
            let mut packet =
                PacketBuilder::ipv4(src.octets(), dst.octets(), 64).tcp(sport, dport, 0, 128);

            if rst {
                packet = packet.rst();
            }

            build!(packet, payload)
        }
        (IpAddr::V6(src), IpAddr::V6(dst)) => {
            let mut packet =
                PacketBuilder::ipv6(src.octets(), dst.octets(), 64).tcp(sport, dport, 0, 128);

            if rst {
                packet = packet.rst();
            }

            build!(packet, payload)
        }
        _ => bail!(IpVersionMismatch),
    }
}

#[derive(Debug, Default, Clone, Copy)]
pub struct TcpFlags {
    pub rst: bool,
}

pub fn udp_packet<SIP, DIP>(
    saddr: SIP,
    daddr: DIP,
    sport: u16,
    dport: u16,
    payload: Vec<u8>,
) -> Result<IpPacket>
where
    SIP: Into<IpAddr>,
    DIP: Into<IpAddr>,
{
    match (saddr.into(), daddr.into()) {
        (IpAddr::V4(src), IpAddr::V4(dst)) => {
            let packet = PacketBuilder::ipv4(src.octets(), dst.octets(), 64).udp(sport, dport);

            build!(packet, payload)
        }
        (IpAddr::V6(src), IpAddr::V6(dst)) => {
            let packet = PacketBuilder::ipv6(src.octets(), dst.octets(), 64).udp(sport, dport);

            build!(packet, payload)
        }
        _ => bail!(IpVersionMismatch),
    }
}

pub fn icmp_dest_unreachable_prohibited(original_packet: &IpPacket) -> Result<IpPacket> {
    icmp_dest_unreachable(
        original_packet,
        icmpv4::DestUnreachableHeader::FilterProhibited,
        icmpv6::DestUnreachableCode::Prohibited,
    )
}

pub fn icmp_dest_unreachable_network(original_packet: &IpPacket) -> Result<IpPacket> {
    icmp_dest_unreachable(
        original_packet,
        icmpv4::DestUnreachableHeader::Network,
        icmpv6::DestUnreachableCode::Address,
    )
}

fn icmp_dest_unreachable(
    original_packet: &IpPacket,
    icmpv4: icmpv4::DestUnreachableHeader,
    icmpv6: icmpv6::DestUnreachableCode,
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
    code: icmpv4::DestUnreachableHeader,
) -> Result<IpPacket, anyhow::Error> {
    let builder = PacketBuilder::ipv4(src.octets(), dst.octets(), 20)
        .icmpv4(crate::Icmpv4Type::DestinationUnreachable(code));
    let payload = original_packet.packet();

    let header_len = original_packet
        .ipv4_header()
        .context("Not an IPv4 packet")?
        .header_len();
    let icmp_error_payload_len = header_len + 8;

    let actual_payload_len = std::cmp::min(payload.len(), icmp_error_payload_len);
    let error_payload = &payload[..actual_payload_len];

    let ip_packet = crate::build!(builder, error_payload)?;

    Ok(ip_packet)
}

fn icmpv6_unreachable(
    src: Ipv6Addr,
    dst: Ipv6Addr,
    original_packet: &IpPacket,
    code: icmpv6::DestUnreachableCode,
) -> Result<IpPacket, anyhow::Error> {
    const MAX_ICMP_ERROR_PAYLOAD_LEN: usize = MAX_IP_SIZE - Ipv6Header::LEN - Icmpv6Header::MAX_LEN;

    let builder = PacketBuilder::ipv6(src.octets(), dst.octets(), 20)
        .icmpv6(crate::Icmpv6Type::DestinationUnreachable(code));
    let payload = original_packet.packet();

    let actual_payload_len = std::cmp::min(payload.len(), MAX_ICMP_ERROR_PAYLOAD_LEN);
    let error_payload = &payload[..actual_payload_len];

    let ip_packet = crate::build!(builder, error_payload)?;

    Ok(ip_packet)
}

#[derive(thiserror::Error, Debug)]
#[error("IPs must be of the same version")]
pub struct IpVersionMismatch;

#[cfg(all(test, feature = "proptest"))]
mod tests {
    use etherparse::{Ipv4Header, Ipv6Header, UdpHeader};
    use proptest::{
        collection,
        prelude::{Strategy, any},
    };

    use crate::MAX_IP_SIZE;

    use super::*;

    #[test_strategy::proptest()]
    fn ipv4_icmp_unreachable(
        #[strategy(payload(MAX_IP_SIZE - Ipv4Header::MIN_LEN - UdpHeader::LEN))] payload: Vec<u8>,
    ) {
        let unreachable_packet = udp_packet(
            Ipv4Addr::new(10, 0, 0, 1),
            Ipv4Addr::LOCALHOST,
            0,
            0,
            payload,
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
        #[strategy(payload(MAX_IP_SIZE - Ipv6Header::LEN - UdpHeader::LEN))] payload: Vec<u8>,
    ) {
        let unreachable_packet = udp_packet(
            Ipv6Addr::new(1, 0, 0, 0, 0, 0, 0, 1),
            Ipv6Addr::LOCALHOST,
            0,
            0,
            payload,
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
