use std::{
    fmt,
    net::SocketAddr,
    num::{NonZeroUsize, Wrapping},
    ops::{Add, Sub},
};

use ip_packet::IpPacket;
use lru::LruCache;
use smallvec::SmallVec;

pub struct Tcp {
    connections: LruCache<Tuple, State>,

    retransmissions: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
struct Tuple {
    src: SocketAddr,
    dst: SocketAddr,
}

/// State for a single TCP connection
#[derive(Default)]
struct State {
    ranges: SmallVec<[SeqRange; 16]>,
    // Base sequence number (fully acknowledged)
    base_seq: SeqNum,
    // Highest sequence seen (for quick filtering)
    highest_seq_end: SeqNum,
}

/// Represents a TCP sequence range (inclusive start and end)
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
struct SeqRange {
    start: SeqNum,
    end: SeqNum,
}

impl Tcp {
    pub fn on_outgoing(&mut self, packet: &IpPacket) {
        let Some(tcp) = packet.as_tcp() else {
            return;
        };

        let tuple = Tuple {
            src: SocketAddr::new(packet.source(), tcp.source_port()),
            dst: SocketAddr::new(packet.destination(), tcp.destination_port()),
        };

        let data_len = tcp.payload().len();
        let seq_num = SeqNum::new(tcp.sequence_number());
        let ack_num = SeqNum::new(tcp.acknowledgment_number());

        // Account for SYN/FIN that consume sequence space
        let seq_len = data_len + if tcp.syn() || tcp.fin() { 1 } else { 0 };
        let seq_range = SeqRange::new(seq_num, seq_len);

        // Get or create connection state
        let state = self
            .connections
            .get_or_insert_mut_ref(&tuple, State::default);

        // Quick check: if sequence is completely below base, it's definitely a retransmission
        if seq_range.end < state.base_seq {
            self.retransmissions += 1;
            return;
        }

        // Quick check: if sequence is completely above highest seen, definitely not a retransmission
        if state.highest_seq_end < seq_range.start {
            // Update highest seen
            if seq_range.end > state.highest_seq_end {
                state.highest_seq_end = seq_range.end;
            }

            // Add to ranges
            state.add_range(seq_range);
            return;
        }

        if state.is_retransmission(seq_range) {
            self.retransmissions += 1;

            tracing::debug!(?tuple, %seq_num, "TCP retransmission");
        }

        // Even if it is a retransmission, we still need to update our state
        state.add_range(seq_range);

        // Update base sequence based on ACK if present
        if tcp.ack() && ack_num > state.base_seq {
            state.update_base_seq(ack_num);
        }
    }
}

impl State {
    /// Check if a sequence range overlaps with any existing ranges.
    fn is_retransmission(&self, packet_seq: SeqRange) -> bool {
        self.ranges.iter().any(|r| packet_seq.overlaps(r))
    }

    /// Add a sequence range to the state, merging with existing ranges if needed
    fn add_range(&mut self, new_range: SeqRange) {
        // Skip ranges completely below base sequence
        if new_range.end <= self.base_seq {
            return;
        }

        // Adjust start if it's below base
        let adjusted_range = if new_range.start < self.base_seq {
            SeqRange {
                start: self.base_seq,
                end: new_range.end,
            }
        } else {
            new_range
        };

        // Find overlapping or adjacent ranges
        let mut overlap_indices = Vec::new();
        for (i, range) in self.ranges.iter().enumerate() {
            if adjusted_range.overlaps(range) || adjusted_range.is_adjacent(range) {
                overlap_indices.push(i);
            }
        }

        if overlap_indices.is_empty() {
            // No overlaps, just add the new range
            self.ranges.push(adjusted_range);
        } else {
            // Merge with overlapping ranges
            let mut merged = adjusted_range;

            // Process in reverse to safely remove
            for &idx in overlap_indices.iter().rev() {
                let range = self.ranges.remove(idx);
                merged = merged.merge(&range);
            }

            // Add the merged range
            self.ranges.push(merged);
        }

        // Keep the list sorted for efficient operations
        self.ranges.sort();

        // Optional: Merge adjacent ranges to keep list compact
        self.coalesce_ranges();
    }

    /// Merge adjacent ranges to keep the list compact
    fn coalesce_ranges(&mut self) {
        if self.ranges.len() <= 1 {
            return;
        }

        let mut i = 0;
        while i < self.ranges.len() - 1 {
            let current = self.ranges[i];
            let next = self.ranges[i + 1];

            if current.is_adjacent(&next) || current.overlaps(&next) {
                let merged = current.merge(&next);
                self.ranges[i] = merged;
                self.ranges.remove(i + 1);
            } else {
                i += 1;
            }
        }
    }

    /// Update the base sequence number, removing any ranges below it
    fn update_base_seq(&mut self, new_base: SeqNum) {
        self.base_seq = new_base;

        // Remove ranges that are completely below the new base
        self.ranges.retain(|range| range.end > new_base);

        // Adjust the start of ranges that cross the new base
        for range in &mut self.ranges {
            if range.start < new_base {
                range.start = new_base;
            }
        }
    }
}

impl SeqRange {
    fn new(start: SeqNum, len: usize) -> Self {
        // Handle zero-length packets (e.g., pure ACKs)
        let len = std::cmp::max(len, 1) as u32;
        // Handle sequence wraparound for end calculation
        let end = start + (len - 1);

        Self { start, end }
    }

    /// Check if this range overlaps with another
    fn overlaps(&self, other: &SeqRange) -> bool {
        // Special case: exact match
        if self.start == other.start && self.end == other.end {
            return true;
        }

        // For TCP sequence space, we need to handle wrapping
        let self_after_other_start = self.start >= other.start;
        let self_before_other_end = self.start <= other.end;
        let other_after_self_start = other.start >= self.start;
        let other_before_self_end = other.start <= self.end;

        (self_after_other_start && self_before_other_end)
            || (other_after_self_start && other_before_self_end)
    }

    /// Check if this range is adjacent to another (could be merged)
    fn is_adjacent(&self, other: &SeqRange) -> bool {
        self.end + 1 == other.start || other.end + 1 == self.start
    }

    /// Merge this range with another overlapping or adjacent range
    fn merge(&self, other: &SeqRange) -> Self {
        let start = if self.start < other.start {
            self.start
        } else {
            other.start
        };
        let end = if self.end > other.end {
            self.end
        } else {
            other.end
        };

        Self { start, end }
    }
}

impl Default for Tcp {
    fn default() -> Self {
        // One entry in the cache is ~100 bytes, thus 100 connections only take up ~10KB of memory.
        let connections = LruCache::new(NonZeroUsize::new(100).expect("100 > 0"));

        Self {
            connections,
            retransmissions: 0,
        }
    }
}

/// Represents a TCP sequence number.
///
/// TCP sequence numbers can wrap around, therefore they have a specialised [`Ord`] implementation.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
struct SeqNum(Wrapping<u32>);

impl SeqNum {
    fn new(value: u32) -> Self {
        SeqNum(Wrapping(value))
    }
}

impl Ord for SeqNum {
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        if self == other {
            return std::cmp::Ordering::Equal;
        }

        let diff = self.0 - other.0;

        if diff.0 < 0x80000000 {
            std::cmp::Ordering::Greater
        } else {
            std::cmp::Ordering::Less
        }
    }
}

impl PartialOrd for SeqNum {
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        Some(self.cmp(other))
    }
}

impl Sub for SeqNum {
    type Output = SeqNum;

    fn sub(self, rhs: Self) -> Self::Output {
        SeqNum(self.0 - rhs.0)
    }
}

impl Sub<u32> for SeqNum {
    type Output = SeqNum;

    fn sub(self, rhs: u32) -> Self::Output {
        SeqNum(self.0 - Wrapping(rhs))
    }
}

impl Add for SeqNum {
    type Output = SeqNum;

    fn add(self, rhs: Self) -> Self::Output {
        SeqNum(self.0 + rhs.0)
    }
}

impl Add<u32> for SeqNum {
    type Output = SeqNum;

    fn add(self, rhs: u32) -> Self::Output {
        SeqNum(self.0 + Wrapping(rhs))
    }
}

impl fmt::Display for SeqNum {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        self.0.0.fmt(f)
    }
}

#[cfg(test)]
mod tests {
    use std::net::Ipv4Addr;

    use ip_packet::{PacketBuilder, PacketBuilderStep, TcpHeader};

    use super::*;

    #[test]
    fn sequential_packets_are_not_retransmissions() {
        let first = packet(0).len(100).build();
        let second = packet(101).len(100).build();

        let mut conntrack_tcp = Tcp::default();

        conntrack_tcp.on_outgoing(&first);
        conntrack_tcp.on_outgoing(&second);

        assert_eq!(conntrack_tcp.retransmissions, 0);
    }

    #[test]
    fn packet_with_sequence_number_less_than_last_is_retransmission() {
        let first = packet(0).len(100).build();

        let mut conntrack_tcp = Tcp::default();

        conntrack_tcp.on_outgoing(&first);
        conntrack_tcp.on_outgoing(&first);

        assert_eq!(conntrack_tcp.retransmissions, 1);
    }

    #[test]
    fn packet_with_wrapping_sequence_number_is_not_a_retransmission() {
        let first = packet(u32::MAX - 50).len(100).build();
        let second = packet(51).len(100).build();

        let mut conntrack_tcp = Tcp::default();

        conntrack_tcp.on_outgoing(&first);
        conntrack_tcp.on_outgoing(&second);

        assert_eq!(conntrack_tcp.retransmissions, 0);
    }

    #[test]
    fn partial_retransmission_is_detected() {
        let first = packet(100).len(100).build(); // 100-199
        let partial = packet(150).len(100).build(); // 150-249

        let mut conntrack_tcp = Tcp::default();

        conntrack_tcp.on_outgoing(&first);
        conntrack_tcp.on_outgoing(&partial);

        assert_eq!(conntrack_tcp.retransmissions, 1);
    }

    #[test]
    fn syn_packets_consume_sequence_space() {
        let syn = packet(100).syn().build();
        let first_data = packet(101).len(50).build(); // 101-150

        let mut conntrack_tcp = Tcp::default();

        conntrack_tcp.on_outgoing(&syn);
        conntrack_tcp.on_outgoing(&first_data);

        // SYN retransmission
        conntrack_tcp.on_outgoing(&syn);

        assert_eq!(conntrack_tcp.retransmissions, 1);
    }

    #[test]
    fn multiple_discrete_ranges_are_tracked() {
        let first = packet(100).len(100).build(); // 100-199
        let second = packet(300).len(100).build(); // 300-399
        let third = packet(500).len(100).build(); // 500-599

        let mut conntrack_tcp = Tcp::default();

        conntrack_tcp.on_outgoing(&first);
        conntrack_tcp.on_outgoing(&second);
        conntrack_tcp.on_outgoing(&third);

        // Retransmission in first range
        let retrans1 = packet(150).len(50).build();
        conntrack_tcp.on_outgoing(&retrans1);

        // Retransmission in second range
        let retrans2 = packet(350).len(50).build();
        conntrack_tcp.on_outgoing(&retrans2);

        // Retransmission in third range
        let retrans3 = packet(550).len(50).build();
        conntrack_tcp.on_outgoing(&retrans3);

        // New packet in gap (not retransmission)
        let new_packet = packet(200).len(50).build();
        conntrack_tcp.on_outgoing(&new_packet);

        assert_eq!(conntrack_tcp.retransmissions, 3);
    }

    fn packet(seq: u32) -> TcpPacketBuilder {
        let tcp = PacketBuilder::ipv4(
            Ipv4Addr::new(192, 168, 0, 1).octets(),
            Ipv4Addr::new(192, 168, 0, 2).octets(),
            64,
        )
        .tcp(8080, 8081, seq, 128);

        TcpPacketBuilder {
            inner: tcp,
            payload_len: 0,
        }
    }

    struct TcpPacketBuilder {
        inner: PacketBuilderStep<TcpHeader>,
        payload_len: usize,
    }

    impl TcpPacketBuilder {
        fn len(mut self, len: usize) -> Self {
            self.payload_len = len;
            self
        }

        fn syn(mut self) -> Self {
            self.inner = self.inner.syn();
            self
        }

        fn build(self) -> IpPacket {
            (|| {
                let payload = vec![0u8; self.payload_len];

                ip_packet::build!(self.inner, payload)
            })()
            .unwrap()
        }
    }
}
