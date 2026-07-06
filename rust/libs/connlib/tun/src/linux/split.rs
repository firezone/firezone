//! Splits "super packets" read from a TUN fd with offloads enabled into individual IP packets.
//!
//! With `TUNSETOFFLOAD` active, the kernel hands us TSO / USO packets of up to 64 KiB
//! together with a [`VirtioNetHdr`] describing how to segment them.
//! Additionally, locally-generated packets arrive with *partial* checksums
//! ([`VIRTIO_NET_HDR_F_NEEDS_CSUM`]): the transport checksum field only contains the
//! pseudo-header sum and we have to complete it.

use anyhow::{Context as _, Result, bail, ensure};
use ip_packet::{IpNumber, IpPacket, IpPacketBuf, IpVersion};
use smallvec::SmallVec;
use std::net::IpAddr;

use super::checksum;
use super::virtio::*;

/// The most segments a single super packet can split into.
///
/// The kernel bounds TSO / USO packets to 65535 bytes and the minimum sensible
/// gso_size is in the hundreds; 256 is a generous upper bound that protects us
/// from allocating unbounded numbers of buffers on malformed headers.
const MAX_SEGMENTS: usize = 256;

/// Splits the given TUN read (starting with a [`VirtioNetHdr`]) into individual [`IpPacket`]s.
///
/// Most reads are individual packets which the returned `SmallVec` stores inline;
/// super packets spill to the heap where the allocation is amortised across their segments.
pub fn split(buf: &[u8]) -> Result<SmallVec<[IpPacket; 1]>> {
    let (hdr, packet) = VirtioNetHdr::parse(buf).context("Read is too short for virtio hdr")?;

    match hdr.gso_type {
        VIRTIO_NET_HDR_GSO_NONE => {
            let packet = copy_single(&hdr, packet)?;

            Ok(SmallVec::from_buf([packet]))
        }
        VIRTIO_NET_HDR_GSO_TCPV4 | VIRTIO_NET_HDR_GSO_TCPV6 | VIRTIO_NET_HDR_GSO_UDP_L4 => {
            split_gso(&hdr, packet)
        }
        other => bail!("Unsupported GSO type: {other:#x}"),
    }
}

/// Copies a non-GSO packet into an [`IpPacket`], completing a partial checksum if necessary.
fn copy_single(hdr: &VirtioNetHdr, packet: &[u8]) -> Result<IpPacket> {
    let len = packet.len();

    let mut ip_packet_buf = IpPacketBuf::new();
    let dst = ip_packet_buf.buf();
    ensure!(len <= dst.len(), "Packet too large (len: {len})");
    dst[..len].copy_from_slice(packet);

    if hdr.flags & VIRTIO_NET_HDR_F_NEEDS_CSUM != 0 {
        complete_partial_checksum(
            &mut dst[..len],
            hdr.csum_start as usize,
            hdr.csum_offset as usize,
        )?;
    }

    let packet = IpPacket::new(ip_packet_buf, len).context("Failed to parse IP packet")?;

    Ok(packet)
}

/// Completes a partial checksum: the field at `csum_start + csum_offset` holds the
/// pseudo-header sum and the bytes from `csum_start` onwards still need to be summed into it.
fn complete_partial_checksum(packet: &mut [u8], start: usize, offset: usize) -> Result<()> {
    let at = start
        .checked_add(offset)
        .context("Checksum position overflows")?;
    ensure!(
        at + 2 <= packet.len() && start <= packet.len(),
        "Checksum region out of bounds (len={}, csum_start={start}, csum_offset={offset})",
        packet.len()
    );

    let pseudo_sum = u64::from(u16::from_be_bytes([packet[at], packet[at + 1]]));
    packet[at] = 0;
    packet[at + 1] = 0;

    let sum = !checksum::fold(checksum::sum(&packet[start..], pseudo_sum));
    packet[at..at + 2].copy_from_slice(&sum.to_be_bytes());

    Ok(())
}

/// Splits a TSO / USO super packet into individual, fully check-summed segments.
fn split_gso(hdr: &VirtioNetHdr, packet: &[u8]) -> Result<SmallVec<[IpPacket; 1]>> {
    let gso_size = hdr.gso_size as usize;
    ensure!(gso_size > 0, "gso_size must not be zero");

    let (version, protocol, ip_hdr_len) = parse_ip_header(packet)?;

    // `hdr.hdr_len` cannot be trusted: on the forward path, the kernel sets it to the
    // length of the entire linear skb section. Compute it from the packet instead.
    let l4_hdr_len = match (hdr.gso_type, protocol) {
        (VIRTIO_NET_HDR_GSO_TCPV4 | VIRTIO_NET_HDR_GSO_TCPV6, IpNumber::TCP) => {
            ensure!(
                packet.len() >= ip_hdr_len + 20,
                "Packet too short for TCP header"
            );

            let data_offset = ((packet[ip_hdr_len + 12] >> 4) & 0x0F) as usize * 4;
            ensure!((20..=60).contains(&data_offset), "Invalid TCP data offset");

            data_offset
        }
        (VIRTIO_NET_HDR_GSO_UDP_L4, IpNumber::UDP) => 8,
        (gso_type, protocol) => {
            bail!("Mismatch between GSO type ({gso_type:#x}) and IP protocol ({protocol:?})")
        }
    };

    let headers_len = ip_hdr_len + l4_hdr_len;
    ensure!(packet.len() > headers_len, "GSO packet has no payload");

    let (headers, payload) = packet.split_at(headers_len);
    let num_segments = payload.len().div_ceil(gso_size);
    ensure!(
        num_segments <= MAX_SEGMENTS,
        "Too many segments ({num_segments})"
    );

    let (src, dst) = addresses(packet, version)?;

    let mut segments = SmallVec::new();

    for (index, segment) in payload.chunks(gso_size).enumerate() {
        let len = headers_len + segment.len();

        let mut ip_packet_buf = IpPacketBuf::new();
        let buf = ip_packet_buf.buf();
        ensure!(len <= buf.len(), "Segment too large (len: {len})");

        buf[..headers_len].copy_from_slice(headers);
        buf[headers_len..len].copy_from_slice(segment);
        let buf = &mut buf[..len];

        match version {
            IpVersion::V4 => {
                buf[2..4].copy_from_slice(&(len as u16).to_be_bytes());

                let identification =
                    u16::from_be_bytes([headers[4], headers[5]]).wrapping_add(index as u16);
                buf[4..6].copy_from_slice(&identification.to_be_bytes());

                buf[10] = 0;
                buf[11] = 0;
                let ip_checksum = !checksum::fold(checksum::sum(&buf[..ip_hdr_len], 0));
                buf[10..12].copy_from_slice(&ip_checksum.to_be_bytes());
            }
            IpVersion::V6 => {
                let payload_len = (l4_hdr_len + segment.len()) as u16;
                buf[4..6].copy_from_slice(&payload_len.to_be_bytes());
            }
        }

        let is_last = index == num_segments - 1;

        match protocol {
            IpNumber::TCP => {
                let seq = u32::from_be_bytes([
                    headers[ip_hdr_len + 4],
                    headers[ip_hdr_len + 5],
                    headers[ip_hdr_len + 6],
                    headers[ip_hdr_len + 7],
                ])
                .wrapping_add((index * gso_size) as u32);
                buf[ip_hdr_len + 4..ip_hdr_len + 8].copy_from_slice(&seq.to_be_bytes());

                // FIN and PSH only apply to the last segment of the original stream.
                if !is_last {
                    buf[ip_hdr_len + 13] &= !0x09;
                }

                write_l4_checksum(buf, src, dst, protocol, ip_hdr_len, 16)?;
            }
            IpNumber::UDP => {
                let udp_len = (8 + segment.len()) as u16;
                buf[ip_hdr_len + 4..ip_hdr_len + 6].copy_from_slice(&udp_len.to_be_bytes());

                write_l4_checksum(buf, src, dst, protocol, ip_hdr_len, 6)?;
            }
            _ => unreachable!("protocol is validated above"),
        }

        let len = buf.len();

        match IpPacket::new(ip_packet_buf, len)
            .with_context(|| format!("Failed to parse segment {index}"))
        {
            Ok(packet) => segments.push(packet),
            Err(e) => tracing::warn!("{e:#}"),
        }
    }

    Ok(segments)
}

/// Computes the full transport checksum (pseudo-header + header + payload) in place.
fn write_l4_checksum(
    buf: &mut [u8],
    src: IpAddr,
    dst: IpAddr,
    protocol: IpNumber,
    ip_hdr_len: usize,
    csum_offset: usize,
) -> Result<()> {
    let l4_len = buf.len() - ip_hdr_len;

    let at = ip_hdr_len + csum_offset;
    buf[at] = 0;
    buf[at + 1] = 0;

    let pseudo_sum = match (src, dst) {
        (IpAddr::V4(src), IpAddr::V4(dst)) => {
            checksum::pseudo_header_sum_v4(src, dst, protocol.0, l4_len)
        }
        (IpAddr::V6(src), IpAddr::V6(dst)) => {
            checksum::pseudo_header_sum_v6(src, dst, protocol.0, l4_len)
        }
        _ => bail!("Mismatched IP versions"),
    };

    let mut sum = !checksum::fold(checksum::sum(&buf[ip_hdr_len..], pseudo_sum));

    // A UDP checksum of zero means "no checksum"; a computed zero is transmitted as all-ones.
    if protocol == IpNumber::UDP && sum == 0 {
        sum = 0xFFFF;
    }

    buf[at..at + 2].copy_from_slice(&sum.to_be_bytes());

    Ok(())
}

fn parse_ip_header(packet: &[u8]) -> Result<(IpVersion, IpNumber, usize)> {
    ensure!(!packet.is_empty(), "Empty packet");

    match packet[0] >> 4 {
        4 => {
            ensure!(packet.len() >= 20, "Packet too short for IPv4 header");

            let ip_hdr_len = (packet[0] & 0x0F) as usize * 4;
            ensure!(
                (20..=60).contains(&ip_hdr_len),
                "Invalid IPv4 header length"
            );

            Ok((IpVersion::V4, IpNumber(packet[9]), ip_hdr_len))
        }
        6 => {
            ensure!(packet.len() >= 40, "Packet too short for IPv6 header");

            // GSO packets carry the transport header directly after the fixed IPv6 header;
            // extension headers don't occur on TSO / USO packets.
            Ok((IpVersion::V6, IpNumber(packet[6]), 40))
        }
        other => bail!("Not an IP packet (version: {other})"),
    }
}

fn addresses(packet: &[u8], version: IpVersion) -> Result<(IpAddr, IpAddr)> {
    match version {
        IpVersion::V4 => {
            let src: [u8; 4] = packet[12..16].try_into()?;
            let dst: [u8; 4] = packet[16..20].try_into()?;

            Ok((IpAddr::from(src), IpAddr::from(dst)))
        }
        IpVersion::V6 => {
            let src: [u8; 16] = packet[8..24].try_into()?;
            let dst: [u8; 16] = packet[24..40].try_into()?;

            Ok((IpAddr::from(src), IpAddr::from(dst)))
        }
    }
}
