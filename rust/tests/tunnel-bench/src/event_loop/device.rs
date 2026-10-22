//! An in-memory TUN device under the platform's real TUN worker threads.
//!
//! Reads hand out a canned packet as often as the harness grants and writes count their packets,
//! so the threads do everything they do on a real device except the syscalls. Where the kernel
//! would hand over a super packet (a GRO train of the canned packet), so does the device.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use ip_packet::IpPacket;

use super::Arrivals;

/// The most segments of the canned packet the device reads at once, as Linux GRO would merge.
#[cfg(target_os = "linux")]
const MAX_SEGMENTS: usize = 64;

#[derive(Clone)]
pub struct Device(Arc<Inner>);

struct Inner {
    packet: IpPacket,
    /// The super packet one read hands over, with its `virtio_net_hdr`.
    #[cfg(target_os = "linux")]
    super_packet: Vec<u8>,
    /// How many copies of the packet one read hands over.
    segments: usize,
    grants: Grants,
    writes: Arrivals,
}

impl Device {
    /// Creates a device that reads `packet` and counts what is written to it.
    pub fn new(packet: &IpPacket) -> Self {
        #[cfg(target_os = "linux")]
        let (super_packet, segments) = linux::super_packet(packet, MAX_SEGMENTS);
        #[cfg(not(target_os = "linux"))]
        let segments = 1;

        Self(Arc::new(Inner {
            packet: packet.clone(),
            #[cfg(target_os = "linux")]
            super_packet,
            segments,
            grants: Grants::default(),
            writes: Arrivals::default(),
        }))
    }

    /// Starts the platform's TUN workers on this device.
    pub fn io(&self, runtime: &tokio::runtime::Handle) -> Box<dyn tun::Tun> {
        cfg_select! {
            target_os = "linux" => {
                Box::new(tun_linux::Io::with_device("bench", self.clone(), true, runtime).unwrap())
            }
            any(target_os = "macos", target_os = "ios") => {
                Box::new(tun_apple::Io::with_device("bench", self.clone(), None, runtime).unwrap())
            }
            windows => {
                Box::new(tun_windows::Io::with_device("bench", self.clone(), || true, runtime).unwrap())
            }
        }
    }

    /// The packets written to the device.
    pub fn writes(&self) -> &Arrivals {
        &self.0.writes
    }

    /// Splits `packets` into the grants to hand out one at a time.
    ///
    /// Every grant but the last is a whole number of super packets, so the device never reads a
    /// partial one while more grants are to come.
    pub fn grants(&self, packets: usize) -> Vec<usize> {
        let segments = self.0.segments;
        let grant = segments * tun::MAX_BATCH_SIZE.div_ceil(segments);

        (0..packets)
            .step_by(grant)
            .map(|granted| grant.min(packets - granted))
            .collect()
    }

    /// Lets the device read `packets` more packets.
    pub fn grant(&self, packets: usize) {
        self.0.grants.add(packets);
    }

    /// Closes the device: pending and future reads report it closed.
    pub fn stop(&self) {
        self.0.grants.stop();
    }
}

/// The packets the harness has granted for reading.
#[derive(Default)]
struct Grants {
    packets: Mutex<usize>,
    stopped: AtomicBool,
    #[cfg(unix)]
    changed: tokio::sync::Notify,
    #[cfg(windows)]
    changed: std::sync::Condvar,
}

impl Grants {
    fn add(&self, packets: usize) {
        *self.packets.lock().unwrap() += packets;
        self.changed.notify_one();
    }

    fn stop(&self) {
        self.stopped.store(true, Ordering::SeqCst);
        self.changed.notify_one();
    }

    fn stopped(&self) -> bool {
        self.stopped.load(Ordering::SeqCst)
    }

    /// Takes up to `max` granted packets.
    fn take(&self, max: usize) -> usize {
        let mut packets = self.packets.lock().unwrap();
        let taken = max.min(*packets);
        *packets -= taken;

        taken
    }

    /// Waits until packets are granted or the device is stopped.
    #[cfg(unix)]
    async fn wait(&self) {
        loop {
            if self.stopped() || *self.packets.lock().unwrap() > 0 {
                return;
            }

            self.changed.notified().await;
        }
    }

    /// Blocks until packets are granted or the device is stopped.
    #[cfg(windows)]
    fn wait(&self) {
        let _granted = self
            .changed
            .wait_while(self.packets.lock().unwrap(), |packets| {
                *packets == 0 && !self.stopped()
            })
            .unwrap();
    }
}

#[cfg(target_os = "linux")]
mod linux {
    use super::*;
    use std::io;
    use tun_offload::virtio::{self, VirtioNetHdr};
    use tun_offload::{ChecksumMode, PacketCoalescer, Protocol};

    impl tun_linux::Device for Device {
        async fn readable(&self) -> io::Result<()> {
            self.0.grants.wait().await;

            Ok(())
        }

        fn try_read(&self, buf: &mut [u8]) -> io::Result<usize> {
            if self.0.grants.stopped() {
                return Ok(0);
            }

            let segments = self.0.grants.take(self.0.segments);

            if segments == 0 {
                return Err(io::ErrorKind::WouldBlock.into());
            }

            if segments == self.0.segments {
                buf[..self.0.super_packet.len()].copy_from_slice(&self.0.super_packet);

                return Ok(self.0.super_packet.len());
            }

            let (super_packet, _) = super_packet(&self.0.packet, segments);
            buf[..super_packet.len()].copy_from_slice(&super_packet);

            Ok(super_packet.len())
        }

        async fn write(&self, header: &[u8], packet: &[u8]) -> io::Result<usize> {
            let (hdr, _) = VirtioNetHdr::parse(header).unwrap();
            let segments = if hdr.gso_size == 0 {
                1
            } else {
                (packet.len() - hdr.hdr_len as usize).div_ceil(hdr.gso_size as usize)
            };
            self.0.writes.add(segments);

            Ok(header.len() + packet.len())
        }
    }

    /// Coalesces up to `segments` copies of `packet` as the TUN send thread would, returning the
    /// super packet behind its `virtio_net_hdr` and how many copies it holds.
    pub fn super_packet(packet: &IpPacket, segments: usize) -> (Vec<u8>, usize) {
        let mut coalescer =
            PacketCoalescer::new([Protocol::Tcp, Protocol::Udp], ChecksumMode::Offloaded);
        for _ in 0..segments {
            coalescer.enqueue(packet.clone());
        }
        let coalesced = coalescer.take();
        let first = &coalesced[0];

        let mut super_packet = virtio::header_for(first).to_vec();
        super_packet.extend_from_slice(first.packet());

        (super_packet, first.num_segments())
    }
}

#[cfg(any(target_os = "macos", target_os = "ios"))]
mod apple {
    use super::*;
    use ip_packet::IpPacketBuf;
    use std::io;
    use tun_offload::CoalescedPacket;

    impl tun_apple::Device for Device {
        async fn recv(&self, bufs: &mut [IpPacketBuf], lens: &mut [usize]) -> io::Result<usize> {
            self.0.grants.wait().await;

            if self.0.grants.stopped() {
                return Ok(0);
            }

            let packets = self.0.grants.take(bufs.len());
            let packet = self.0.packet.packet();

            for (buf, len) in bufs.iter_mut().zip(lens).take(packets) {
                buf.buf()[..packet.len()].copy_from_slice(packet);
                *len = packet.len();
            }

            Ok(packets)
        }

        async fn send(&self, packets: &[CoalescedPacket]) -> io::Result<usize> {
            let segments = packets.iter().map(CoalescedPacket::num_segments).sum();
            self.0.writes.add(segments);

            Ok(packets.len())
        }
    }
}

#[cfg(windows)]
mod windows {
    use super::*;
    use std::io;
    use tun_offload::CoalescedPacket;

    impl tun_windows::Device for Device {
        fn send(&self, packet: &CoalescedPacket) -> io::Result<()> {
            self.0.writes.add(packet.num_segments());

            Ok(())
        }

        fn receive_blocking(&self, buf: &mut [u8]) -> io::Result<usize> {
            self.0.grants.wait();

            if self.0.grants.stopped() {
                return Ok(0);
            }

            self.try_receive(buf)
        }

        fn try_receive(&self, buf: &mut [u8]) -> io::Result<usize> {
            if self.0.grants.take(1) == 0 {
                return Ok(0);
            }

            let packet = self.0.packet.packet();
            buf[..packet.len()].copy_from_slice(packet);

            Ok(packet.len())
        }

        fn shutdown(&self) {
            self.stop();
        }
    }
}
