use anyhow::{Context as _, ErrorExt, Result, bail};
use ip_packet::{IpPacket, IpPacketBuf};
use std::io;
use std::os::fd::AsRawFd;
use tokio::io::unix::AsyncFd;
use tokio::sync::mpsc;

// Maximum size for GSO packets: 64KB for IP + 12 bytes for vnet header
const MAX_GSO_BUFFER_SIZE: usize = 65536 + VIRTIO_NET_HDR_SIZE;

pub const VIRTIO_NET_HDR_SIZE: usize = 12;

pub fn tun_send<T>(
    fd: T,
    mut outbound_rx: mpsc::Receiver<IpPacket>,
    write: impl Fn(i32, &IpPacket) -> std::result::Result<usize, io::Error>,
) -> Result<()>
where
    T: AsRawFd + Clone,
{
    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .context("Failed to create runtime")?
        .block_on(async move {
            let fd = AsyncFd::with_interest(fd, tokio::io::Interest::WRITABLE)?;

            while let Some(packet) = outbound_rx.recv().await {
                if let Err(e) = fd
                    .async_io(tokio::io::Interest::WRITABLE, |fd| {
                        write(fd.as_raw_fd(), &packet)
                    })
                    .await
                {
                    tracing::warn!("Failed to write to TUN FD: {e}");
                }
            }

            anyhow::Ok(())
        })?;

    anyhow::Ok(())
}

pub fn tun_recv<T>(
    fd: T,
    inbound_tx: mpsc::Sender<IpPacket>,
    read: impl Fn(i32, &mut [u8]) -> std::result::Result<usize, io::Error>,
) -> Result<()>
where
    T: AsRawFd + Clone,
{
    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .context("Failed to create runtime")?
        .block_on(async move {
            let fd = AsyncFd::with_interest(fd, tokio::io::Interest::READABLE)?;

            // Reusable buffer for reading GSO packets (vnet header + packet data)
            let mut read_buffer = vec![0u8; MAX_GSO_BUFFER_SIZE];

            loop {
                let next_inbound_packets = fd
                    .async_io(tokio::io::Interest::READABLE, |fd| {
                        let total_len = read(fd.as_raw_fd(), &mut read_buffer)?;

                        if total_len == 0 {
                            return Ok(Vec::new());
                        }

                        let Some((vnet_hdr_buf, ip_data)) = read_buffer.split_first_chunk() else {
                            return Err(io::Error::new(
                                io::ErrorKind::UnexpectedEof,
                                "Read less than vnet header",
                            ));
                        };

                        let packet_len = total_len - VIRTIO_NET_HDR_SIZE;

                        let packets = parse_vnet_packet(vnet_hdr_buf, &ip_data[..packet_len])
                            .context("Failed to parse packet with vnet header")
                            .map_err(|e| io::Error::new(io::ErrorKind::InvalidInput, e))?;

                        Ok(packets)
                    })
                    .await;

                match next_inbound_packets.context("Failed to read from TUN FD") {
                    Ok(packets) if packets.is_empty() => bail!("TUN file descriptor is closed"),
                    Ok(packets) => {
                        let permits = match inbound_tx.reserve_many(packets.len()).await {
                            Ok(permits) => permits,
                            Err(_) => {
                                tracing::debug!("Inbound packet receiver gone, shutting down task");
                                return anyhow::Ok(());
                            }
                        };

                        for (permit, packet) in permits.zip(packets) {
                            permit.send(packet);
                        }
                    }
                    Err(e) if e.any_is::<ip_packet::Fragmented>() => {
                        tracing::debug!("{e:#}"); // Log on debug to be less noisy.
                        continue;
                    }
                    Err(e) => {
                        tracing::warn!("{e:#}");
                        continue;
                    }
                }
            }
        })?;

    anyhow::Ok(())
}

/// Parse a packet with virtio_net_hdr and handle GSO/USO segmentation
fn parse_vnet_packet(
    vnet_hdr: &[u8; VIRTIO_NET_HDR_SIZE],
    ip_data: &[u8],
) -> Result<Vec<IpPacket>> {
    let hdr = VirtioNetHdr {
        flags: vnet_hdr[0],
        gso_type: vnet_hdr[1],
        hdr_len: u16::from_le_bytes([vnet_hdr[2], vnet_hdr[3]]),
        gso_size: u16::from_le_bytes([vnet_hdr[4], vnet_hdr[5]]),
        csum_start: u16::from_le_bytes([vnet_hdr[6], vnet_hdr[7]]),
        csum_offset: u16::from_le_bytes([vnet_hdr[8], vnet_hdr[9]]),
        num_buffers: u16::from_le_bytes([vnet_hdr[10], vnet_hdr[11]]),
    };

    if hdr.gso_type == VIRTIO_NET_HDR_GSO_NONE {
        // Regular packet - copy to a new IpPacketBuf
        let mut buf = IpPacketBuf::new();
        let buf_slice = buf.buf();
        buf_slice[..ip_data.len()].copy_from_slice(ip_data);

        let packet = IpPacket::new(buf, ip_data.len()).context("Failed to parse IP packet")?;

        return Ok(vec![packet]);
    }

    let packets = segment_gso_packet(ip_data, &hdr)?;

    Ok(packets)
}

/// Segment a GSO/USO packet into individual IP packets
fn segment_gso_packet(data: &[u8], hdr: &VirtioNetHdr) -> Result<Vec<IpPacket>> {
    anyhow::ensure!(
        hdr.hdr_len as usize <= data.len(),
        "Header length {} exceeds packet size {}",
        hdr.hdr_len,
        data.len()
    );

    let header_len = hdr.hdr_len as usize;
    let segment_size = hdr.gso_size as usize;
    let payload_start = header_len;
    let total_payload_len = data.len() - header_len;

    anyhow::ensure!(segment_size > 0, "GSO segment size is zero");

    let mut packets = Vec::new();
    let mut offset = 0;

    while offset < total_payload_len {
        let segment_payload_len = std::cmp::min(segment_size, total_payload_len - offset);
        let packet_len = header_len + segment_payload_len;

        let mut packet_buf = IpPacketBuf::new();
        let buf = packet_buf.buf();

        // Copy headers
        buf[..header_len].copy_from_slice(&data[..header_len]);

        // Copy segment payload
        buf[header_len..packet_len].copy_from_slice(
            &data[payload_start + offset..payload_start + offset + segment_payload_len],
        );

        // Update IP length field based on IP version
        if buf[0] >> 4 == 4 {
            // IPv4
            let total_len = packet_len as u16;
            buf[2..4].copy_from_slice(&total_len.to_be_bytes());
        } else if buf[0] >> 4 == 6 {
            // IPv6 - payload length doesn't include the 40-byte header
            let payload_len = (packet_len - 40) as u16;
            buf[4..6].copy_from_slice(&payload_len.to_be_bytes());
        }

        // Update TCP/UDP length if applicable
        match hdr.gso_type {
            VIRTIO_NET_HDR_GSO_TCPV4 | VIRTIO_NET_HDR_GSO_TCPV6 => {
                // TCP: update sequence number for segments after the first
                if offset > 0 && header_len >= 20 + 12 {
                    let tcp_offset = if buf[0] >> 4 == 4 {
                        (buf[0] & 0x0F) as usize * 4 // IPv4 header length
                    } else {
                        40 // IPv6 header is always 40 bytes
                    };

                    if tcp_offset + 4 <= header_len {
                        let seq_offset = tcp_offset + 4;
                        let original_seq = u32::from_be_bytes([
                            buf[seq_offset],
                            buf[seq_offset + 1],
                            buf[seq_offset + 2],
                            buf[seq_offset + 3],
                        ]);
                        let new_seq = original_seq.wrapping_add(offset as u32);
                        buf[seq_offset..seq_offset + 4].copy_from_slice(&new_seq.to_be_bytes());
                    }
                }
            }
            VIRTIO_NET_HDR_GSO_UDP | VIRTIO_NET_HDR_GSO_UDP_L4 => {
                // UDP: update length field
                let udp_offset = if buf[0] >> 4 == 4 {
                    (buf[0] & 0x0F) as usize * 4
                } else {
                    40
                };

                if udp_offset + 4 <= header_len {
                    let udp_len = (segment_payload_len + 8) as u16; // 8-byte UDP header
                    buf[udp_offset + 4..udp_offset + 6].copy_from_slice(&udp_len.to_be_bytes());
                }
            }
            _ => {}
        }

        let mut packet =
            IpPacket::new(packet_buf, packet_len).context("Failed to parse segmented IP packet")?;

        // Recalculate checksums for the segmented packet
        packet.update_checksum();

        packets.push(packet);
        offset += segment_payload_len;
    }

    Ok(packets)
}

// virtio_net_hdr_v1 structure (12 bytes, little-endian)
#[repr(C)]
#[derive(Debug, Clone, Copy)]
struct VirtioNetHdr {
    flags: u8,
    gso_type: u8,
    hdr_len: u16,
    gso_size: u16,
    csum_start: u16,
    csum_offset: u16,
    num_buffers: u16,
}

// GSO types
const VIRTIO_NET_HDR_GSO_NONE: u8 = 0;
const VIRTIO_NET_HDR_GSO_TCPV4: u8 = 1;
const VIRTIO_NET_HDR_GSO_UDP: u8 = 3;
const VIRTIO_NET_HDR_GSO_TCPV6: u8 = 4;
const VIRTIO_NET_HDR_GSO_UDP_L4: u8 = 5;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn can_detect_ip_fragmented_error() {
        let ip_packet_error =
            anyhow::Error::new(ip_packet::Fragmented).context("Failed to parse IP packet");
        let io_error = io::Error::new(io::ErrorKind::InvalidInput, ip_packet_error);

        let final_error = anyhow::Error::new(io_error).context("Failed to read from TUN fd");

        assert!(final_error.any_is::<ip_packet::Fragmented>())
    }
}
