use super::PacketDevice;
use anyhow::Result;
use compio::driver::{OpCode, OpType};
use ip_packet::{IpPacket, IpPacketBuf};
use packet_coalescer::{ChecksumMode, PacketCoalescer, Protocol};
use std::{cell::RefCell, io, sync::Arc, task::Poll};
use tun::PacketBatch;
use windows_sys::Win32::System::IO::OVERLAPPED;

/// Uses Wintun's rings and bridges its receive event to the completion queue.
pub struct Wintun {
    session: Arc<wintun::Session>,
    lifetime: Arc<dyn Send + Sync>,
    tcp: RefCell<PacketCoalescer>,
    passthrough: RefCell<PacketCoalescer>,
}

impl Wintun {
    pub fn new(session: Arc<wintun::Session>, lifetime: Arc<dyn Send + Sync>) -> Self {
        Self {
            session,
            lifetime,
            tcp: RefCell::new(PacketCoalescer::new(
                [Protocol::Tcp],
                ChecksumMode::Complete,
            )),
            passthrough: RefCell::new(PacketCoalescer::passthrough()),
        }
    }
}

impl PacketDevice for Wintun {
    async fn read(&self) -> Result<PacketBatch> {
        loop {
            if let Some(packet) = self.session.try_receive()? {
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
                    let Some(packet) = self.session.try_receive()? else {
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
            let event = self.session.get_read_wait_event()? as usize;
            compio::runtime::submit(WaitRing {
                _session: self.session.clone(),
                _lifetime: self.lifetime.clone(),
                event,
            })
            .await
            .0?;
        }
    }
    async fn write(&self, mut batch: PacketBatch) -> Result<()> {
        let packets = {
            let mut coalescer = if telemetry::feature_flags::wintun_tcp_coalescing() {
                self.tcp.borrow_mut()
            } else {
                self.passthrough.borrow_mut()
            };
            for packet in batch.drain() {
                coalescer.enqueue(packet);
            }
            coalescer.drain().collect::<Vec<_>>()
        };
        for packet in packets {
            let bytes = packet.packet();
            for attempt in 0..=24 {
                match self.session.allocate_send_packet(bytes.len().try_into()?) {
                    Ok(mut outgoing) => {
                        outgoing.bytes_mut().copy_from_slice(bytes);
                        self.session.send_packet(outgoing);
                        break;
                    }
                    Err(wintun::Error::Io(error)) if error.raw_os_error() == Some(0x6f) => {
                        if attempt == 24 {
                            tracing::trace!("Dropping packet because Wintun ring remains full");
                            break;
                        }
                        for _ in 0..(1u32 << attempt.min(6)) {
                            std::hint::spin_loop();
                        }
                        tokio::task::yield_now().await;
                    }
                    Err(error) => return Err(error.into()),
                }
            }
        }
        Ok(())
    }
}

struct WaitRing {
    _session: Arc<wintun::Session>,
    _lifetime: Arc<dyn Send + Sync>,
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
