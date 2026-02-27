//! TUN device implementation for Linux with GSO batching support

use crate::tun_device_manager::linux::tun_gso_queue::IpPacketBatch;

use super::tun_gso_queue;
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
const TUN_F_TSO4: libc::c_uint = 2;
const TUN_F_TSO6: libc::c_uint = 4;
const TUN_F_USO4: libc::c_uint = 32;
const TUN_F_USO6: libc::c_uint = 64;

const QUEUE_SIZE: usize = 10_000;

/// Represents either a single packet or a batch of packets to send to TUN
#[derive(Debug)]
enum OutboundPacket {
    Single(IpPacket),
    Batch(IpPacketBatch),
}

pub struct Tun {
    outbound_tx: PollSender<OutboundPacket>,
    inbound_rx: mpsc::Receiver<IpPacket>,
    gso_queue: tun_gso_queue::TunGsoQueue,
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
            gso_queue: tun_gso_queue::TunGsoQueue::new(),
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

        // Enable offloads: checksumming, TSO, and USO
        let offload_flags = TUN_F_CSUM | TUN_F_TSO4 | TUN_F_TSO6 | TUN_F_USO4 | TUN_F_USO6;
        if libc::ioctl(fd, TUNSETOFFLOAD as _, offload_flags) < 0 {
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
        // Try to batch the packet, fall back to direct send if not batchable
        if self.gso_queue.enqueue(&packet).is_err() {
            self.outbound_tx
                .start_send_unpin(OutboundPacket::Single(packet))
                .map_err(io::Error::other)?;
        }

        Ok(())
    }

    fn poll_flush(&mut self, cx: &mut Context) -> Poll<io::Result<()>> {
        for batch in self.gso_queue.packets() {
            std::task::ready!(self.outbound_tx.poll_ready_unpin(cx)).map_err(io::Error::other)?;

            self.outbound_tx
                .start_send_unpin(OutboundPacket::Batch(batch))
                .map_err(io::Error::other)?;
        }

        Poll::Ready(Ok(()))
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

/// Custom tun_send that handles both single packets and batches from a unified channel
fn tun_send<T>(fd: T, mut outbound_rx: mpsc::Receiver<OutboundPacket>) -> Result<()>
where
    T: AsRawFd + Clone,
{
    use tokio::io::unix::AsyncFd;

    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .context("Failed to create runtime")?
        .block_on(async move {
            let fd = AsyncFd::with_interest(fd, tokio::io::Interest::WRITABLE)?;

            loop {
                match outbound_rx.recv().await {
                    Some(OutboundPacket::Single(packet)) => {
                        if let Err(e) = fd
                            .async_io(tokio::io::Interest::WRITABLE, |fd_ref| {
                                write_single(fd_ref.as_raw_fd(), &packet)
                            })
                            .await
                        {
                            tracing::warn!("Failed to write single packet to TUN FD: {e}");
                        }
                    }
                    Some(OutboundPacket::Batch(batch)) => {
                        if let Err(e) = fd
                            .async_io(tokio::io::Interest::WRITABLE, |fd_ref| {
                                write_batch(fd_ref.as_raw_fd(), &batch)
                            })
                            .await
                        {
                            tracing::warn!("Failed to write batch to TUN FD: {e}");
                        }
                    }
                    None => break,
                }
            }

            anyhow::Ok(())
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

/// Write a batch of IP packets to the TUN device using `writev`.
fn write_batch(fd: RawFd, batch: &IpPacketBatch) -> io::Result<usize> {
    let (l3, l4) = batch.header.header_slices();

    let iov = [
        libc::iovec {
            iov_base: batch.vnet_hdr.as_ptr() as *mut libc::c_void,
            iov_len: batch.vnet_hdr.len(),
        },
        libc::iovec {
            iov_base: l3.as_ptr() as *mut libc::c_void,
            iov_len: l3.len(),
        },
        libc::iovec {
            iov_base: l4.as_ptr() as *mut libc::c_void,
            iov_len: l4.len(),
        },
        libc::iovec {
            iov_base: batch.payloads.as_ref().as_ptr() as *mut libc::c_void,
            iov_len: batch.payloads.as_ref().len(),
        },
    ];

    // Safety: Within this module, the file descriptor is always valid.
    match unsafe { libc::writev(fd, iov.as_ptr(), 4) } {
        -1 => Err(io::Error::last_os_error()),
        n => Ok(n as usize - VIRTIO_NET_HDR_SIZE),
    }
}

/// Receive packets from TUN device
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
        let mut buf = ip_packet::IpPacketBuf::new();
        let buf_slice = buf.buf();
        buf_slice[..ip_data.len()].copy_from_slice(ip_data);

        let packet = IpPacket::new(buf, ip_data.len()).context("Failed to parse IP packet")?;

        return Ok(vec![packet]);
    }

    let packets = segment_packet(ip_data, &hdr)?;

    Ok(packets)
}

fn segment_packet(data: &[u8], hdr: &VirtioNetHdr) -> Result<Vec<IpPacket>> {
    anyhow::ensure!(
        hdr.hdr_len as usize <= data.len(),
        "Header length {} exceeds packet size {}",
        hdr.hdr_len,
        data.len()
    );

    let header_len = hdr.hdr_len as usize;
    let segment_size = hdr.gso_size as usize;

    anyhow::ensure!(segment_size > 0, "GSO segment size is zero");

    let (headers, payload) = data.split_at(header_len);

    let packets = payload
        .chunks(segment_size)
        .enumerate()
        .map(|(segment_idx, payload)| {
            let packet_len = header_len + payload.len();
            let mut packet_buf = ip_packet::IpPacketBuf::new();
            let buf = packet_buf.buf();

            // Copy headers
            buf[..header_len].copy_from_slice(headers);

            // Copy payload
            buf[header_len..packet_len].copy_from_slice(payload);

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
                    if segment_idx > 0 && header_len >= 20 + 12 {
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
                            let new_seq =
                                original_seq.wrapping_add((segment_idx * segment_size) as u32);
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
                        let udp_len = (payload.len() + 8) as u16; // 8-byte UDP header
                        buf[udp_offset + 4..udp_offset + 6].copy_from_slice(&udp_len.to_be_bytes());
                    }
                }
                _ => {}
            }

            let mut packet = IpPacket::new(packet_buf, packet_len)
                .context("Failed to parse segmented IP packet")?;

            // Recalculate checksums for the segmented packet
            packet.update_checksum();

            anyhow::Ok(packet)
        })
        .collect::<Result<Vec<_>>>()?;

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
