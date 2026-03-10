//! TUN device implementation for Linux without GSO batching or segmentation handling.

use anyhow::{Context as _, ErrorExt, Result, bail};
use futures::SinkExt;
use ip_packet::IpPacket;
use libc::{F_GETFL, F_SETFL, O_NONBLOCK, O_RDWR, S_IFCHR, fcntl, makedev, mknod, open};
use logging;
use std::sync::Arc;
use std::task::{Context, Poll};
use std::{
    ffi::CStr,
    fs, io,
    os::{
        fd::{AsRawFd, FromRawFd as _, OwnedFd, RawFd},
        unix::fs::PermissionsExt,
    },
    path::Path,
};
use telemetry::otel;
use tokio::io::unix::AsyncFd;
use tokio::sync::mpsc;
use tokio_util::sync::PollSender;
use tun::ioctl;

const TUNSETIFF: libc::c_ulong = 0x4004_54ca;
const TUNSETVNETHDRSZ: libc::c_ulong = 0x4004_54d8;
const TUNSETOFFLOAD: libc::c_ulong = 0x4004_54d0;

// virtio_net_hdr_v1 size (12 bytes)
const VIRTIO_NET_HDR_SIZE: usize = 12;

// Maximum size for GSO packets: 64KB for IP + 12 bytes for vnet header
const MAX_GSO_BUFFER_SIZE: usize = 65536 + VIRTIO_NET_HDR_SIZE;

const TUN_DEV_MAJOR: u32 = 10;
const TUN_DEV_MINOR: u32 = 200;

const TUN_FILE: &CStr = c"/dev/net/tun";

// Offload flags for TUNSETOFFLOAD
const TUN_F_CSUM: libc::c_uint = 1;

const QUEUE_SIZE: usize = 10_000;

pub struct Tun {
    outbound_tx: PollSender<IpPacket>,
    inbound_rx: mpsc::Receiver<IpPacket>,
}

impl Tun {
    pub fn new() -> Result<Self> {
        create_tun_device()?;

        let (inbound_tx, inbound_rx) = mpsc::channel(QUEUE_SIZE);
        let (outbound_tx, outbound_rx) = mpsc::channel(QUEUE_SIZE);

        tokio::spawn(otel::metrics::periodic_system_queue_length(
            outbound_tx.downgrade(),
            [
                otel::attr::queue_item_ip_packet(),
                otel::attr::network_io_direction_transmit(),
            ],
        ));
        tokio::spawn(otel::metrics::periodic_system_queue_length(
            inbound_tx.downgrade(),
            [
                otel::attr::queue_item_ip_packet(),
                otel::attr::network_io_direction_receive(),
            ],
        ));

        let fd = Arc::new(open_tun()?);

        std::thread::Builder::new()
            .name("TUN send".to_owned())
            .spawn({
                let fd = fd.clone();

                move || {
                    logging::unwrap_or_warn!(
                        tun_send(fd, outbound_rx),
                        "Failed to send to TUN device: {}"
                    )
                }
            })
            .map_err(io::Error::other)?;
        std::thread::Builder::new()
            .name("TUN recv".to_owned())
            .spawn(move || {
                logging::unwrap_or_warn!(
                    tun_recv(fd, inbound_tx),
                    "Failed to recv from TUN device: {}"
                )
            })
            .map_err(io::Error::other)?;

        Ok(Self {
            outbound_tx: PollSender::new(outbound_tx),
            inbound_rx,
        })
    }
}

fn open_tun() -> Result<OwnedFd> {
    let fd = match unsafe { open(TUN_FILE.as_ptr() as _, O_RDWR) } {
        -1 => {
            let file = TUN_FILE.to_str()?;

            return Err(anyhow::Error::new(get_last_error()))
                .with_context(|| format!("Failed to open '{file}'"));
        }
        fd => fd,
    };

    unsafe {
        ioctl::exec(
            fd,
            TUNSETIFF,
            &mut ioctl::Request::<ioctl::SetTunFlagsPayload>::new(
                super::manager::TunDeviceManager::IFACE_NAME,
            ),
        )
        .context("Failed to set flags on TUN device")?;

        // Set vnet header size to 12 bytes (virtio_net_hdr_v1)
        if libc::ioctl(
            fd,
            TUNSETVNETHDRSZ as _,
            &(VIRTIO_NET_HDR_SIZE as libc::c_int),
        ) < 0
        {
            return Err(anyhow::Error::new(get_last_error()))
                .context("Failed to set vnet header size");
        }

        // Enable checksum offload only (disable segmentation offloads)
        if libc::ioctl(fd, TUNSETOFFLOAD as _, TUN_F_CSUM) < 0 {
            return Err(anyhow::Error::new(get_last_error()))
                .context("Failed to set offload flags");
        }
    }

    set_non_blocking(fd).context("Failed to make TUN device non-blocking")?;

    // Safety: We are not closing the FD.
    let fd = unsafe { OwnedFd::from_raw_fd(fd) };

    Ok(fd)
}

impl tun::Tun for Tun {
    fn poll_send_ready(&mut self, cx: &mut Context) -> Poll<io::Result<()>> {
        self.outbound_tx
            .poll_ready_unpin(cx)
            .map_err(io::Error::other)
    }

    fn send(&mut self, packet: IpPacket) -> io::Result<()> {
        self.outbound_tx
            .start_send_unpin(packet)
            .map_err(io::Error::other)
    }

    fn poll_recv_many(
        &mut self,
        cx: &mut Context,
        buf: &mut Vec<IpPacket>,
        max: usize,
    ) -> Poll<usize> {
        self.inbound_rx.poll_recv_many(cx, buf, max)
    }

    fn name(&self) -> &str {
        super::manager::TunDeviceManager::IFACE_NAME
    }
}

/// Send packets to the TUN device.
fn tun_send<T>(fd: T, mut outbound_rx: mpsc::Receiver<IpPacket>) -> Result<()>
where
    T: AsRawFd + Clone,
{
    use tokio::io::unix::AsyncFd;

    let batch_histogram = telemetry::otel::metrics::system_network_packets_batch_count();

    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .context("Failed to create runtime")?
        .block_on(async move {
            let fd = AsyncFd::with_interest(fd, tokio::io::Interest::WRITABLE)?;

            while let Some(packet) = outbound_rx.recv().await {
                batch_histogram.record(
                    1,
                    &[
                        otel::attr::network_type_for_packet(&packet),
                        telemetry::otel::attr::network_io_direction_transmit(),
                    ],
                );

                if let Err(e) = fd
                    .async_io(tokio::io::Interest::WRITABLE, |fd_ref| {
                        #[cfg(debug_assertions)]
                        tracing::trace!(target: "wire::dev::send", ?packet);

                        write_single(fd_ref.as_raw_fd(), &packet)
                    })
                    .await
                {
                    tracing::warn!("Failed to write packet to TUN FD: {e}");
                }
            }

            anyhow::Ok(())
        })?;

    anyhow::Ok(())
}

/// Receive packets from TUN device.
fn tun_recv<T>(fd: T, inbound_tx: mpsc::Sender<IpPacket>) -> Result<()>
where
    T: AsRawFd + Clone,
{
    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .context("Failed to create runtime")?
        .block_on(async move {
            let fd = AsyncFd::with_interest(fd, tokio::io::Interest::READABLE)?;

            let batch_histogram = telemetry::otel::metrics::system_network_packets_batch_count();

            // Reusable buffer for reading GSO packets (vnet header + packet data)
            let mut read_buffer = vec![0u8; MAX_GSO_BUFFER_SIZE];

            loop {
                let next_inbound_packets = fd
                    .async_io(tokio::io::Interest::READABLE, |fd_ref| {
                        let total_len = read(fd_ref.as_raw_fd(), &mut read_buffer)?;

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
                        let hdr = VirtioNetHdr::from_buf(*vnet_hdr_buf);

                        let packets = parse_vnet_packet(&hdr, &ip_data[..packet_len])
                            .context("Failed to parse packet with vnet header")
                            .map_err(|e| io::Error::new(io::ErrorKind::InvalidInput, e))?;

                        // All packets are the same IP version.
                        if let Some(first) = packets.first() {
                            batch_histogram.record(
                                packets.len() as u64,
                                &[
                                    otel::attr::network_type_for_packet(first),
                                    telemetry::otel::attr::network_io_direction_receive(),
                                ],
                            );
                        }

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

fn get_last_error() -> io::Error {
    io::Error::last_os_error()
}

fn set_non_blocking(fd: RawFd) -> io::Result<()> {
    match unsafe { fcntl(fd, F_GETFL) } {
        -1 => Err(get_last_error()),
        flags => match unsafe { fcntl(fd, F_SETFL, flags | O_NONBLOCK) } {
            -1 => Err(get_last_error()),
            _ => Ok(()),
        },
    }
}

fn create_tun_device() -> io::Result<()> {
    let path = Path::new(TUN_FILE.to_str().map_err(io::Error::other)?);

    if path.exists() {
        return Ok(());
    }

    let parent_dir = path
        .parent()
        .expect("const-declared path always has a parent");
    fs::create_dir_all(parent_dir)?;
    let permissions = fs::Permissions::from_mode(0o751);
    fs::set_permissions(parent_dir, permissions)?;
    if unsafe {
        mknod(
            TUN_FILE.as_ptr() as _,
            S_IFCHR,
            makedev(TUN_DEV_MAJOR, TUN_DEV_MINOR),
        )
    } != 0
    {
        return Err(get_last_error());
    }

    Ok(())
}

/// Read from the given file descriptor into a buffer.
fn read(fd: RawFd, dst: &mut [u8]) -> io::Result<usize> {
    // Safety: Within this module, the file descriptor is always valid.
    match unsafe { libc::read(fd, dst.as_mut_ptr() as _, dst.len()) } {
        -1 => Err(io::Error::last_os_error()),
        n => Ok(n as usize),
    }
}

/// Write the packet to the given file descriptor.
fn write_single(fd: RawFd, packet: &IpPacket) -> io::Result<usize> {
    let vnet_hdr = [0u8; VIRTIO_NET_HDR_SIZE];
    let packet_bytes = packet.packet();

    let iov = [
        libc::iovec {
            iov_base: vnet_hdr.as_ptr() as *mut libc::c_void,
            iov_len: vnet_hdr.len(),
        },
        libc::iovec {
            iov_base: packet_bytes.as_ptr() as *mut libc::c_void,
            iov_len: packet_bytes.len(),
        },
    ];

    // Safety: Within this module, the file descriptor is always valid.
    match unsafe { libc::writev(fd, iov.as_ptr(), 2) } {
        -1 => Err(io::Error::last_os_error()),
        n => Ok(n as usize - VIRTIO_NET_HDR_SIZE),
    }
}

/// Parse a packet with virtio_net_hdr and handle GSO/USO segmentation.
fn parse_vnet_packet(hdr: &VirtioNetHdr, ip_data: &[u8]) -> Result<Vec<IpPacket>> {
    if hdr.gso_type == VIRTIO_NET_HDR_GSO_NONE {
        // Regular packet - copy to a new IpPacketBuf
        let mut buf = ip_packet::IpPacketBuf::new();
        let buf_slice = buf.buf();
        buf_slice[..ip_data.len()].copy_from_slice(ip_data);

        let packet = IpPacket::new(buf, ip_data.len()).context("Failed to parse IP packet")?;

        #[cfg(debug_assertions)]
        tracing::trace!(target: "wire::dev::recv", ?packet);

        return Ok(vec![packet]);
    }

    let packets = segment_packet(hdr, ip_data);

    #[cfg(debug_assertions)]
    tracing::trace!(target: "wire::dev::recv", num_packets = %packets.len());

    Ok(packets)
}

fn segment_packet(hdr: &VirtioNetHdr, data: &[u8]) -> Vec<IpPacket> {
    use ip_packet::{Ipv6Header, UdpHeader};

    let data_len = data.len();
    let header_len = hdr.hdr_len as usize;
    let segment_size = hdr.gso_size as usize;

    // Validate basic packet structure
    if header_len > data_len {
        tracing::debug!(
            header_len,
            data_len,
            "GSO packet header length exceeds data size, discarding"
        );
        return Vec::new();
    }

    if header_len == 0 || header_len > data_len {
        tracing::debug!(
            header_len,
            data_len,
            "Invalid header length, discarding packet"
        );
        return Vec::new();
    }

    if segment_size == 0 {
        tracing::debug!("GSO segment size is zero, discarding packet");
        return Vec::new();
    }

    let (headers, payload) = data.split_at(header_len);

    // Determine IP version and L3 header length once
    let ip_version = headers[0] >> 4;
    let ip_header_len = match ip_version {
        4 => {
            let ip_header_len = (headers[0] & 0x0F) as usize * 4;
            if ip_header_len < 20 || ip_header_len > header_len {
                tracing::debug!(
                    ip_header_len,
                    header_len,
                    "Invalid IPv4 header length, discarding packet"
                );
                return Vec::new();
            }
            ip_header_len
        }
        6 => {
            if header_len < Ipv6Header::LEN {
                tracing::debug!(header_len, "Header too short for IPv6, discarding packet");
                return Vec::new();
            }

            Ipv6Header::LEN
        }
        _ => {
            tracing::debug!(ip_version, "Invalid IP version, discarding packet");
            return Vec::new();
        }
    };

    // Offset constants for IP header fields
    const IPV4_TOTAL_LENGTH_OFFSET: usize = 2;
    const IPV6_PAYLOAD_LENGTH_OFFSET: usize = 4;
    const TCP_SEQUENCE_NUMBER_OFFSET: usize = 4;
    const UDP_LENGTH_OFFSET: usize = 4;

    payload
        .chunks(segment_size)
        .enumerate()
        .filter_map(|(segment_idx, segment_payload)| {
            let mut packet_buf = ip_packet::IpPacketBuf::new();

            let segment_len = segment_payload.len();
            let packet_len = header_len + segment_len;
            let buf = packet_buf.buf();

            // Copy headers and payload
            buf[..header_len].copy_from_slice(headers);
            buf[header_len..packet_len].copy_from_slice(segment_payload);

            // Update IP length field
            match ip_version {
                4 => {
                    let total_len = packet_len as u16;
                    buf[IPV4_TOTAL_LENGTH_OFFSET..IPV4_TOTAL_LENGTH_OFFSET + 2]
                        .copy_from_slice(&total_len.to_be_bytes());
                }
                6 => {
                    buf[IPV6_PAYLOAD_LENGTH_OFFSET..IPV6_PAYLOAD_LENGTH_OFFSET + 2]
                        .copy_from_slice(&segment_len.to_be_bytes());
                }
                _ => {
                    tracing::debug!(ip_version, "Unexpected IP version in segment processing");
                    return None;
                }
            }

            // Update L4 protocol-specific fields
            match hdr.gso_type {
                VIRTIO_NET_HDR_GSO_TCPV4 | VIRTIO_NET_HDR_GSO_TCPV6 => {
                    // Update TCP sequence number for segments after the first
                    if segment_idx > 0 {
                        let seq_offset = ip_header_len + TCP_SEQUENCE_NUMBER_OFFSET;

                        let original_seq = u32::from_be_bytes([
                            buf[seq_offset],
                            buf[seq_offset + 1],
                            buf[seq_offset + 2],
                            buf[seq_offset + 3],
                        ]);
                        let new_seq =
                            original_seq.wrapping_add((segment_idx * segment_size) as u32);

                        buf[seq_offset..seq_offset + 4].copy_from_slice(&new_seq.to_be_bytes());
                    }
                }
                VIRTIO_NET_HDR_GSO_UDP | VIRTIO_NET_HDR_GSO_UDP_L4 => {
                    // Update UDP length field
                    let udp_len_offset = ip_header_len + UDP_LENGTH_OFFSET;

                    let udp_len = (segment_payload.len() + UdpHeader::LEN) as u16;
                    buf[udp_len_offset..udp_len_offset + 2].copy_from_slice(&udp_len.to_be_bytes());
                }
                _ => {}
            }

            let mut packet = IpPacket::new(packet_buf, packet_len)
                .inspect_err(|e| {
                    tracing::debug!(
                        %segment_idx,
                        %packet_len,
                        "Failed to parse segmented IP packet, discarding segment: {e}"
                    )
                })
                .ok()?;

            // Recalculate checksums for the segmented packet
            packet.update_checksum();

            Some(packet)
        })
        .collect()
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

impl VirtioNetHdr {
    fn from_buf(buf: [u8; VIRTIO_NET_HDR_SIZE]) -> Self {
        VirtioNetHdr {
            flags: buf[0],
            gso_type: buf[1],
            hdr_len: u16::from_le_bytes([buf[2], buf[3]]),
            gso_size: u16::from_le_bytes([buf[4], buf[5]]),
            csum_start: u16::from_le_bytes([buf[6], buf[7]]),
            csum_offset: u16::from_le_bytes([buf[8], buf[9]]),
            num_buffers: u16::from_le_bytes([buf[10], buf[11]]),
        }
    }
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
    fn tcp_segments_have_expected_seq_and_lengths() {
        let segment_size = 50;
        let payload_len = 150;
        let (hdr, data, header_len, base_seq) = build_tcp_gso_packet(segment_size, payload_len);

        let packets = segment_packet(&hdr, &data);

        assert_tcp_segments(&packets, header_len, segment_size, base_seq, payload_len);
    }

    #[test]
    fn tcp_segments_handle_smaller_final_payload() {
        let segment_size = 64;
        let payload_len = 150; // last segment will be shorter (22 bytes)
        let (hdr, data, header_len, base_seq) = build_tcp_gso_packet(segment_size, payload_len);

        let packets = segment_packet(&hdr, &data);

        assert_tcp_segments(&packets, header_len, segment_size, base_seq, payload_len);
        let last = packets.last().unwrap();
        let last_payload_len = last.packet().len() - header_len;
        assert_eq!(last_payload_len, 22);
    }

    #[test]
    fn can_detect_ip_fragmented_error() {
        let ip_packet_error =
            anyhow::Error::new(ip_packet::Fragmented).context("Failed to parse IP packet");
        let io_error = io::Error::new(io::ErrorKind::InvalidInput, ip_packet_error);

        let final_error = anyhow::Error::new(io_error).context("Failed to read from TUN fd");

        assert!(final_error.any_is::<ip_packet::Fragmented>())
    }

    fn build_tcp_gso_packet(
        segment_size: usize,
        payload_len: usize,
    ) -> (VirtioNetHdr, Vec<u8>, usize, u32) {
        let payload = (0..payload_len)
            .map(|i| (i % 251) as u8)
            .collect::<Vec<u8>>();

        let packet = ip_packet::make::tcp_packet(
            std::net::Ipv4Addr::new(10, 0, 0, 1),
            std::net::Ipv4Addr::new(10, 0, 0, 2),
            1234,
            5678,
            ip_packet::make::TcpArgs {
                seq: 1,
                ..Default::default()
            },
            payload,
        )
        .expect("build tcp packet");

        let ip_header_len = packet.ipv4_header().unwrap().header_len();
        let tcp_header_len = packet.as_tcp().unwrap().to_header().header_len();
        let header_len = ip_header_len + tcp_header_len;
        let base_seq = packet.as_tcp().unwrap().sequence_number();

        let hdr = VirtioNetHdr {
            flags: 0,
            gso_type: VIRTIO_NET_HDR_GSO_TCPV4,
            hdr_len: header_len as u16,
            gso_size: segment_size as u16,
            csum_start: 0,
            csum_offset: 0,
            num_buffers: 0,
        };

        (hdr, packet.packet().to_vec(), header_len, base_seq)
    }

    fn assert_tcp_segments(
        packets: &[IpPacket],
        header_len: usize,
        segment_size: usize,
        base_seq: u32,
        full_payload_len: usize,
    ) {
        let expected_segments = full_payload_len.div_ceil(segment_size);
        assert_eq!(packets.len(), expected_segments);

        for (idx, packet) in packets.iter().enumerate() {
            let ip_len = packet.packet().len();
            let payload_len = ip_len - header_len;
            let expected_payload = if idx == expected_segments - 1 {
                full_payload_len - segment_size * idx
            } else {
                segment_size
            };
            assert_eq!(payload_len, expected_payload);

            let tcp = packet.as_tcp().expect("packet should be TCP");
            let seq = tcp.sequence_number();
            assert_eq!(seq, base_seq.wrapping_add((segment_size * idx) as u32));
        }
    }
}
