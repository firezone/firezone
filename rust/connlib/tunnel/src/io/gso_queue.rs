use std::{
    borrow::Cow,
    collections::BTreeMap,
    net::SocketAddr,
    time::{Duration, Instant},
};

use bytes::BytesMut;
use socket_factory::DatagramOut;

/// Holds UDP datagrams that we need to send, indexed by src, dst and segment size.
///
/// Calling [`Io::send_network`](super::Io::send_network) will copy the provided payload into this buffer.
/// The buffer is then flushed using GSO in a single syscall.
pub struct GsoQueue {
    max_segments: usize,
    inner: BTreeMap<Key, DatagramBuffer>,
}

impl GsoQueue {
    pub fn new(max_segments: usize) -> Self {
        Self {
            max_segments,
            inner: Default::default(),
        }
    }

    pub fn handle_timeout(&mut self, now: Instant) {
        self.inner.retain(|_, b| {
            if !b.is_empty() {
                return true;
            }

            now.duration_since(b.last_access) < Duration::from_secs(60)
        })
    }

    pub fn enqueue(
        &mut self,
        src: Option<SocketAddr>,
        dst: SocketAddr,
        payload: &[u8],
        now: Instant,
    ) {
        self.inner
            .entry(Key {
                src,
                dst,
                segment_size: payload.len(),
            })
            .or_insert_with(|| DatagramBuffer::new(now))
            .extend(payload, now);
    }

    pub fn datagrams(&mut self) -> impl Iterator<Item = DatagramOut<'static>> + '_ {
        self.inner
            .iter_mut()
            .filter(|(_, b)| !b.is_empty())
            .flat_map(|(key, buffer)| {
                let max_length = self.max_segments * key.segment_size;
                let buffer = &mut buffer.inner;

                std::iter::from_fn(move || {
                    if buffer.is_empty() {
                        return None;
                    }

                    let packet = if buffer.len() > max_length {
                        buffer.split_to(max_length)
                    } else {
                        buffer.split()
                    };

                    Some(DatagramOut {
                        src: key.src,
                        dst: key.dst,
                        packet: Cow::Owned(packet.freeze().into()),
                        segment_size: Some(key.segment_size),
                    })
                })
            })
    }

    pub fn clear(&mut self) {
        self.inner.clear()
    }
}

#[derive(Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Clone, Copy)]
struct Key {
    src: Option<SocketAddr>,
    dst: SocketAddr,
    segment_size: usize,
}

struct DatagramBuffer {
    inner: BytesMut,
    last_access: Instant,
}

impl DatagramBuffer {
    pub fn new(now: Instant) -> Self {
        Self {
            inner: Default::default(),
            last_access: now,
        }
    }

    pub(crate) fn is_empty(&self) -> bool {
        self.inner.is_empty()
    }

    pub(crate) fn extend(&mut self, payload: &[u8], now: Instant) {
        self.inner.extend_from_slice(payload);
        self.last_access = now;
    }
}

#[cfg(test)]
mod tests {
    use std::net::{Ipv4Addr, SocketAddrV4};

    use super::*;

    #[test]
    fn send_queue_gcs_after_1_minute() {
        let now = Instant::now();
        let mut send_queue = GsoQueue::new(100);

        send_queue.enqueue(None, DST, b"foobar", now);
        for _entry in send_queue.datagrams() {}

        send_queue.handle_timeout(now + Duration::from_secs(60));

        assert_eq!(send_queue.inner.len(), 0);
    }

    #[test]
    fn does_not_gc_unsent_items() {
        let now = Instant::now();
        let mut send_queue = GsoQueue::new(100);

        send_queue.enqueue(None, DST, b"foobar", now);

        send_queue.handle_timeout(now + Duration::from_secs(60));

        assert_eq!(send_queue.inner.len(), 1);
    }

    #[test]
    fn returns_at_most_max_segments_per_iteration() {
        let now = Instant::now();
        let mut send_queue = GsoQueue::new(2);

        send_queue.enqueue(None, DST, b"test1", now);
        send_queue.enqueue(None, DST, b"test2", now);
        send_queue.enqueue(None, DST, b"test3", now);

        let datagram = send_queue.datagrams().next().unwrap();
        assert_eq!(datagram.packet.as_ref(), b"test1test2");

        let datagram = send_queue.datagrams().next().unwrap();
        assert_eq!(datagram.packet.as_ref(), b"test3");

        let datagram = send_queue.datagrams().next();
        assert!(datagram.is_none());
    }

    const DST: SocketAddr = SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::LOCALHOST, 1234));
}
