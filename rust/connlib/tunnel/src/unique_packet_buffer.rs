use ip_packet::IpPacket;
use ringbuffer::{AllocRingBuffer, RingBuffer};

pub struct UniquePacketBuffer {
    buffer: AllocRingBuffer<IpPacket>,
}

impl UniquePacketBuffer {
    pub fn with_capacity_power_of_2(capacity: usize) -> Self {
        Self {
            buffer: AllocRingBuffer::with_capacity_power_of_2(capacity),
        }
    }

    pub fn push(&mut self, packet: IpPacket) {
        if self.buffer.contains(&packet) {
            tracing::trace!(?packet, "Skipping duplicate packet");

            return;
        }

        self.buffer.push(packet);
    }

    pub fn len(&self) -> usize {
        self.buffer.len()
    }
}

impl Extend<IpPacket> for UniquePacketBuffer {
    fn extend<T: IntoIterator<Item = IpPacket>>(&mut self, iter: T) {
        self.buffer.extend(iter)
    }
}

impl IntoIterator for UniquePacketBuffer {
    type Item = IpPacket;
    type IntoIter = <AllocRingBuffer<IpPacket> as IntoIterator>::IntoIter;

    fn into_iter(self) -> Self::IntoIter {
        self.buffer.into_iter()
    }
}
