use super::PacketDevice;
use anyhow::Result;
use compio::driver::{OpCode, OpType};
use ip_packet::{IpPacket, IpPacketBuf};
use std::{io, sync::Arc, task::Poll};
use tun::PacketBatch;
use windows_sys::Win32::System::IO::OVERLAPPED;

/// Uses Wintun's rings and bridges its receive event to the completion queue.
pub struct Wintun(pub Arc<wintun::Session>);

impl PacketDevice for Wintun {
    async fn read(&self) -> Result<PacketBatch> {
        loop {
            if let Some(packet) = self.0.try_receive()? {
                let bytes = packet.bytes();
                let mut buffer = IpPacketBuf::new();
                anyhow::ensure!(
                    bytes.len() <= buffer.buf().len(),
                    "Wintun packet exceeds buffer capacity"
                );
                buffer.buf()[..bytes.len()].copy_from_slice(bytes);
                let mut batch = PacketBatch::new(IpPacket::new(buffer, bytes.len())?);
                drop(packet);
                for _ in 1..tun::MAX_BATCH_SIZE {
                    let Some(packet) = self.0.try_receive()? else {
                        break;
                    };
                    let bytes = packet.bytes();
                    let mut buffer = IpPacketBuf::new();
                    anyhow::ensure!(
                        bytes.len() <= buffer.buf().len(),
                        "Wintun packet exceeds buffer capacity"
                    );
                    buffer.buf()[..bytes.len()].copy_from_slice(bytes);
                    let packet = IpPacket::new(buffer, bytes.len())?;
                    if batch.try_push(packet).is_err() {
                        unreachable!();
                    }
                }
                return Ok(batch);
            }
            let event = self.0.get_read_wait_event()? as usize;
            compio::runtime::submit(WaitRing {
                _session: self.0.clone(),
                event,
            })
            .await
            .0?;
        }
    }
    async fn write(&self, mut batch: PacketBatch) -> Result<()> {
        for packet in batch.drain() {
            let mut outgoing = self
                .0
                .allocate_send_packet(packet.packet().len().try_into()?)?;
            outgoing.bytes_mut().copy_from_slice(packet.packet());
            self.0.send_packet(outgoing);
        }
        Ok(())
    }
}

struct WaitRing {
    _session: Arc<wintun::Session>,
    event: usize,
}

// The operation owns the session which keeps the Wintun event alive until cancellation or completion.
unsafe impl OpCode for WaitRing {
    type Control = ();
    fn op_type(&self, _: &Self::Control) -> OpType {
        OpType::Event(self.event as _)
    }
    unsafe fn operate(
        &mut self,
        _: &mut Self::Control,
        _: *mut OVERLAPPED,
    ) -> Poll<io::Result<usize>> {
        Poll::Ready(Ok(0))
    }
}
