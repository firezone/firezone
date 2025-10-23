use ip_packet::IpPacket;
use opentelemetry::KeyValue;
use ringbuffer::{AllocRingBuffer, RingBuffer};

use crate::otel;

pub struct UniquePacketBuffer {
    buffer: AllocRingBuffer<IpPacket>,
    tag: &'static str,

    num_dropped_packets: opentelemetry::metrics::Counter<u64>,
}

impl UniquePacketBuffer {
    pub fn with_capacity_power_of_2(capacity: usize, tag: &'static str) -> Self {
        Self {
            buffer: AllocRingBuffer::with_capacity_power_of_2(capacity),
            tag,
            num_dropped_packets: crate::otel::metrics::network_packet_dropped(),
        }
    }

    pub fn push(&mut self, new: IpPacket) {
        if self.buffer.contains(&new) {
            tracing::trace!(packet = ?new, "Not buffering byte-for-byte duplicate packet");

            return;
        }

        for buffered in self.buffer.iter_mut() {
            if is_tcp_syn_retransmit(buffered, &new) {
                tracing::trace!(packet = ?new, "Detected TCP SYN retransmission; replacing old one");
                *buffered = new;

                return;
            }
        }

        tracing::debug!(tag = %self.tag, is_full = %self.buffer.is_full(), packet = ?new, "Buffering packet");

        if self.buffer.is_full() {
            self.num_dropped_packets.add(
                1,
                &[
                    otel::attr::network_type_for_packet(&new),
                    otel::attr::network_io_direction_transmit(),
                    KeyValue::new("system.buffer.pool.name", self.tag),
                    otel::attr::error_type("BufferFull"),
                ],
            );
        }

        self.buffer.enqueue(new);
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

#[cfg(test)]
mod tests {
    use anyhow::Result;
    use ip_packet::TcpOptionElement;

    use super::*;

    #[test]
    fn replaces_existing_tcp_syn_retransmission() {
        let mut buffer = UniquePacketBuffer::with_capacity_power_of_2(2, "test");

        buffer.push(tcp_syn_packet(0, 1024, 0).unwrap());
        buffer.push(tcp_syn_packet(0, 1025, 0).unwrap());

        let packets = buffer.into_iter().collect::<Vec<_>>();

        assert_eq!(packets.len(), 1);
        assert_eq!(
            packets[0]
                .as_tcp()
                .unwrap()
                .options_iterator()
                .next()
                .unwrap()
                .unwrap(),
            TcpOptionElement::Timestamp(1025, 0)
        );
    }

    fn tcp_syn_packet(seq: u32, ts_val: u32, ts_echo: u32) -> Result<IpPacket> {
        let packet = ip_packet::PacketBuilder::ipv4([0u8; 4], [0u8; 4], 1)
            .tcp(0, 0, seq, 256)
            .syn()
            .options(&[TcpOptionElement::Timestamp(ts_val, ts_echo)])?;
        let payload = vec![];

        ip_packet::build!(packet, payload)
    }
}
