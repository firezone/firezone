use is::Candidate;
use ringbuffer::{AllocRingBuffer, RingBuffer};

/// The upper bound on how many remote candidates we buffer for connections that have not been created yet.
///
/// Remote candidates may arrive via the signalling channel before the corresponding connection is
/// set up locally. We buffer those so they can be drained once the connection is created. The bound
/// guards against unbounded growth should candidates arrive for a connection that never materialises;
/// once it is reached, the oldest candidate is evicted.
const MAX_BUFFERED_CANDIDATES: usize = 128;

/// Buffers remote candidates that arrive before the corresponding connection has been created.
pub struct BufferedRemoteCandidates<TId> {
    inner: AllocRingBuffer<(TId, Candidate)>,
}

impl<TId> Default for BufferedRemoteCandidates<TId> {
    fn default() -> Self {
        Self {
            inner: AllocRingBuffer::new(MAX_BUFFERED_CANDIDATES),
        }
    }
}

impl<TId> BufferedRemoteCandidates<TId>
where
    TId: PartialEq,
{
    /// Buffers a candidate for a connection that does not exist yet.
    ///
    /// Once the buffer is full, the oldest candidate is evicted to make room.
    pub fn push(&mut self, cid: TId, candidate: Candidate) {
        self.inner.enqueue((cid, candidate));
    }

    /// Removes and returns all buffered candidates for the given connection in arrival order.
    pub fn drain(&mut self, cid: TId) -> Vec<Candidate> {
        let mut drained = Vec::new();

        for (id, candidate) in self.inner.drain().collect::<Vec<_>>() {
            if id == cid {
                drained.push(candidate);
            } else {
                self.inner.enqueue((id, candidate));
            }
        }

        drained
    }

    /// Discards all buffered candidates for the given connection.
    pub fn remove(&mut self, cid: TId) {
        self.drain(cid);
    }

    /// Discards all buffered candidates.
    pub fn clear(&mut self) {
        self.inner.clear();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::SocketAddr;

    #[test]
    fn drain_returns_candidates_for_connection() {
        let mut buffer = BufferedRemoteCandidates::default();
        let candidate = host_candidate(1);

        buffer.push(1u32, candidate.clone());

        assert_eq!(buffer.drain(1u32), vec![candidate]);
    }

    #[test]
    fn drain_only_returns_candidates_for_the_given_connection() {
        let mut buffer = BufferedRemoteCandidates::default();
        let first = host_candidate(1);
        let second = host_candidate(2);

        buffer.push(1u32, first.clone());
        buffer.push(2u32, second.clone());

        assert_eq!(buffer.drain(1u32), vec![first]);
        assert_eq!(buffer.drain(2u32), vec![second]);
    }

    #[test]
    fn drain_preserves_insertion_order() {
        let mut buffer = BufferedRemoteCandidates::default();
        let first = host_candidate(1);
        let second = host_candidate(2);

        buffer.push(1u32, first.clone());
        buffer.push(1u32, second.clone());

        assert_eq!(buffer.drain(1u32), vec![first, second]);
    }

    #[test]
    fn drain_empties_the_buffer_for_that_connection() {
        let mut buffer = BufferedRemoteCandidates::default();

        buffer.push(1u32, host_candidate(1));
        buffer.drain(1u32);

        assert!(buffer.drain(1u32).is_empty());
    }

    #[test]
    fn oldest_candidate_is_evicted_once_full() {
        let mut buffer = BufferedRemoteCandidates::default();

        for port in 0..MAX_BUFFERED_CANDIDATES {
            buffer.push(1u32, host_candidate(port as u16));
        }
        let overflow = host_candidate(u16::MAX);
        buffer.push(1u32, overflow.clone());

        let drained = buffer.drain(1u32);

        assert_eq!(drained.len(), MAX_BUFFERED_CANDIDATES);
        assert!(!drained.contains(&host_candidate(0)));
        assert!(drained.contains(&overflow));
    }

    #[test]
    fn remove_discards_candidates_for_connection() {
        let mut buffer = BufferedRemoteCandidates::default();
        let other = host_candidate(2);

        buffer.push(1u32, host_candidate(1));
        buffer.push(2u32, other.clone());

        buffer.remove(1u32);

        assert!(buffer.drain(1u32).is_empty());
        assert_eq!(buffer.drain(2u32), vec![other]);
    }

    #[test]
    fn clear_discards_all_candidates() {
        let mut buffer = BufferedRemoteCandidates::default();

        buffer.push(1u32, host_candidate(1));
        buffer.push(2u32, host_candidate(2));

        buffer.clear();

        assert!(buffer.drain(1u32).is_empty());
        assert!(buffer.drain(2u32).is_empty());
    }

    fn host_candidate(port: u16) -> Candidate {
        let addr = SocketAddr::from(([127, 0, 0, 1], port));

        Candidate::host(addr, "udp").unwrap()
    }
}
