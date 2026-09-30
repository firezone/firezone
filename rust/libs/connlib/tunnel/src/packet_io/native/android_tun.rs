use super::PacketDevice;
use anyhow::Result;
use compio::{
    BufResult,
    buf::{IoBuf, IoBufMut, SetLen},
    io::{AsyncRead, AsyncWrite},
    runtime::fd::AsyncFd,
};
use ip_packet::{IpPacket, IpPacketBuf};
use std::{mem::MaybeUninit, os::fd::OwnedFd};
use tun::PacketBatch;

/// Owns the plain IP descriptor from Android's `VpnService`.
pub(super) struct AndroidTun {
    fd: AsyncFd<OwnedFd>,
}

impl AndroidTun {
    pub(super) fn from_fd(fd: OwnedFd) -> Result<Self> {
        Ok(Self {
            fd: AsyncFd::new(fd)?,
        })
    }
}

impl PacketDevice for AndroidTun {
    async fn read(&self) -> Result<PacketBatch> {
        loop {
            let BufResult(result, buffer) = (&self.fd).read(Incoming::default()).await;
            let len = result?;
            anyhow::ensure!(len > 0, "TUN descriptor closed");
            match IpPacket::new(buffer.packet, len) {
                Ok(packet) => return Ok(PacketBatch::new(packet)),
                Err(error) => tracing::trace!(%error, "Discarding unsupported TUN packet"),
            }
        }
    }

    async fn write(&self, mut batch: PacketBatch) -> Result<()> {
        for packet in batch.drain() {
            let len = packet.packet().len();
            let BufResult(result, _) = (&self.fd).write(Outgoing(packet)).await;
            anyhow::ensure!(result? == len, "Short TUN write");
        }
        Ok(())
    }
}

#[derive(Default)]
struct Incoming {
    packet: IpPacketBuf,
    len: usize,
}
impl IoBuf for Incoming {
    fn as_init(&self) -> &[u8] {
        &self.packet.as_ref()[..self.len]
    }
}
impl IoBufMut for Incoming {
    fn as_uninit(&mut self) -> &mut [MaybeUninit<u8>] {
        let bytes = self.packet.buf();
        unsafe { std::slice::from_raw_parts_mut(bytes.as_mut_ptr().cast(), bytes.len()) }
    }
}
impl SetLen for Incoming {
    unsafe fn set_len(&mut self, len: usize) {
        assert!(len <= self.packet.as_ref().len());
        self.len = len;
    }
}
struct Outgoing(IpPacket);
impl IoBuf for Outgoing {
    fn as_init(&self) -> &[u8] {
        self.0.packet()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{net::Ipv4Addr, os::unix::net::UnixDatagram};

    #[test]
    fn plain_tun_reads_into_owned_packets_and_preserves_write_order() {
        super::super::tests::test_runtime(
            async {
                let (device, peer) = UnixDatagram::pair().unwrap();
                device.set_nonblocking(true).unwrap();
                peer.set_nonblocking(true).unwrap();
                let device = AndroidTun::from_fd(device.into()).unwrap();
                let peer = AsyncFd::new(OwnedFd::from(peer)).unwrap();
                let packets = (0..3)
                    .map(|sequence| {
                        ip_packet::make::udp_packet(
                            Ipv4Addr::LOCALHOST,
                            Ipv4Addr::LOCALHOST,
                            1234,
                            4321,
                            &[sequence; 500],
                        )
                        .unwrap()
                    })
                    .collect::<Vec<_>>();
                let mut batch = PacketBatch::default();
                for packet in &packets {
                    batch.try_push(packet.clone()).unwrap();
                }
                device.write(batch).await.unwrap();
                for expected in packets {
                    let BufResult(result, bytes) = (&peer).read(Vec::with_capacity(2048)).await;
                    assert_eq!(result.unwrap(), expected.packet().len());
                    assert_eq!(bytes, expected.packet());
                    let BufResult(result, _) = (&peer).write(bytes).await;
                    result.unwrap();
                    let mut received = device.read().await.unwrap();
                    assert_eq!(received.drain().next().unwrap().packet(), expected.packet());
                }
            },
            None,
        )
        .unwrap();
    }
}
