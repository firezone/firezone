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

    pub fn push(&mut self, new: IpPacket) {
        if self.buffer.contains(&new) {
            tracing::trace!(packet = ?new, "Not buffering byte-for-byte duplicate packet");

            return;
        }

        if self
            .buffer
            .iter()
            .any(|buffered| is_tcp_syn_retransmit(buffered, &new))
        {
            tracing::trace!(packet = ?new, "Not buffering TCP SYN retransmission");

            return;
        }

        let num_buffered = self.len() + 1;

        tracing::debug!(%num_buffered, packet = ?new, "Buffering packet");

        self.buffer.push(new);
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

fn is_tcp_syn_retransmit(buffered: &IpPacket, new: &IpPacket) -> bool {
    if buffered.source() != new.source() {
        return false;
    }

    if buffered.destination() != new.destination() {
        return false;
    }

    let Some(buffered) = buffered.as_tcp() else {
        return false;
    };

    let Some(new) = new.as_tcp() else {
        return false;
    };

    buffered.syn()
        && !buffered.ack()
        && new.syn()
        && !new.ack()
        && buffered.source_port() == new.source_port()
        && buffered.destination_port() == new.destination_port()
        && buffered.sequence_number() == new.sequence_number()
}
