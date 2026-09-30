use super::{PacketDevice, buffer::UdpBuffer};
use anyhow::Result;
use bufferpool::BufferPool;
use compio::{
    BufResult,
    buf::IoBuf,
    io::{AsyncRead, AsyncWrite},
    runtime::fd::AsyncFd,
};
use ip_packet::IpPacket;
use packet_coalescer::{ChecksumMode, CoalescedPacket, PacketCoalescer, Protocol};
use std::{
    cell::{Cell, RefCell},
    collections::VecDeque,
    os::fd::OwnedFd,
};
use tun::{
    PacketBatch,
    linux::{
        TunFd,
        split::split,
        virtio::{VNET_HDR_LEN, header_for},
    },
};

/// Completes Linux TUN reads and vectored writes with segmentation offloads.
pub struct OffloadedTun {
    fd: AsyncFd<OwnedFd>,
    receives: BufferPool<Vec<u8>>,
    overflow: RefCell<VecDeque<IpPacket>>,
    coalescer: RefCell<PacketCoalescer>,
    offloads: Cell<bool>,
}

impl OffloadedTun {
    pub fn from_fd(tun: TunFd<OwnedFd>) -> Result<Self> {
        let (fd, offloads) = tun.into_parts();
        Ok(Self {
            fd: AsyncFd::new(fd)?,
            receives: BufferPool::new(VNET_HDR_LEN + u16::MAX as usize, "completion-tun-receive"),
            overflow: RefCell::new(VecDeque::new()),
            coalescer: RefCell::new(PacketCoalescer::new(
                [Protocol::Tcp, Protocol::Udp],
                ChecksumMode::Offloaded,
            )),
            offloads: Cell::new(offloads),
        })
    }
}

impl PacketDevice for OffloadedTun {
    async fn read(&self) -> Result<PacketBatch> {
        loop {
            let mut batch = PacketBatch::default();
            {
                let mut overflow = self.overflow.borrow_mut();
                while let Some(packet) = overflow.pop_front() {
                    if let Err(packet) = batch.try_push(packet) {
                        overflow.push_front(packet);
                        break;
                    }
                }
            }
            if !batch.is_empty() {
                return Ok(batch);
            }
            let mut inner = self.receives.pull();
            inner.resize(VNET_HDR_LEN + u16::MAX as usize, 0);
            let BufResult(result, buffer) = (&self.fd).read(UdpBuffer { inner, len: 0 }).await;
            anyhow::ensure!(result? > 0, "TUN descriptor closed");
            match split(buffer.as_init()) {
                Ok(packets) => self.overflow.borrow_mut().extend(packets),
                Err(error) => tracing::trace!(%error, "Discarding unsupported TUN packet"),
            }
        }
    }

    async fn write(&self, mut batch: PacketBatch) -> Result<()> {
        let ready = if self.offloads.get() {
            let mut coalescer = self.coalescer.borrow_mut();
            for packet in batch.drain() {
                coalescer.enqueue(packet);
            }
            coalescer.drain().collect::<Vec<_>>()
        } else {
            batch.drain().map(CoalescedPacket::from).collect()
        };
        for packet in ready {
            let header = header_for(&packet);
            let len = VNET_HDR_LEN + packet.packet().len();
            let BufResult(result, (_, (packet,))) = (&self.fd)
                .write_vectored((header, (Outgoing(packet),)))
                .await;
            match result {
                Ok(written) => anyhow::ensure!(written == len, "Short TUN write"),
                Err(error)
                    if packet.0.num_segments() > 1
                        && error.raw_os_error() == Some(libc::EINVAL) =>
                {
                    self.offloads.set(false);
                    // The existing splitter completes partial checksums when falling back to individual writes.
                    let bytes = [header.as_slice(), packet.0.packet()].concat();
                    for packet in split(&bytes)? {
                        let len = VNET_HDR_LEN + packet.packet().len();
                        let BufResult(result, _) = (&self.fd)
                            .write_vectored(([0; VNET_HDR_LEN], (Outgoing(packet.into()),)))
                            .await;
                        anyhow::ensure!(result? == len, "Short TUN write");
                    }
                }
                Err(error) => return Err(error.into()),
            }
        }
        Ok(())
    }
}

struct Outgoing(CoalescedPacket);
impl IoBuf for Outgoing {
    fn as_init(&self) -> &[u8] {
        self.0.packet()
    }
}
