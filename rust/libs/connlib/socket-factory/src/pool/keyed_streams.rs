//! A [`SelectAll`] whose streams can be removed again by key.

use std::{
    pin::Pin,
    task::{Context, Poll, Waker, ready},
};

use futures::{Stream, StreamExt as _, stream::SelectAll};

/// Polls all streams at once, yielding each item together with its stream's key.
pub(crate) struct KeyedStreams<K, S> {
    inner: SelectAll<Entry<K, S>>,
}

impl<K, S> KeyedStreams<K, S>
where
    K: PartialEq + Copy + Unpin,
    S: Stream + Unpin,
{
    pub(crate) fn push(&mut self, key: K, stream: S) {
        self.inner.push(Entry {
            key,
            stream: Some(stream),
            waker: Waker::noop().clone(),
        });
    }

    /// Removes and returns the stream for `key`.
    pub(crate) fn remove(&mut self, key: &K) -> Option<S> {
        let entry = self
            .inner
            .iter_mut()
            .find(|entry| entry.key == *key && entry.stream.is_some())?;
        let stream = entry.stream.take();

        // `SelectAll` only drops the emptied entry once it polls it again.
        entry.waker.wake_by_ref();

        stream
    }
}

impl<K, S> Default for KeyedStreams<K, S>
where
    K: Copy + Unpin,
    S: Stream + Unpin,
{
    fn default() -> Self {
        Self {
            inner: SelectAll::new(),
        }
    }
}

impl<K, S> Stream for KeyedStreams<K, S>
where
    K: Copy + Unpin,
    S: Stream + Unpin,
{
    type Item = (K, S::Item);

    fn poll_next(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Option<Self::Item>> {
        self.inner.poll_next_unpin(cx)
    }
}

struct Entry<K, S> {
    key: K,
    /// `None` once removed; the entry then ends on its next poll.
    stream: Option<S>,
    waker: Waker,
}

impl<K, S> Stream for Entry<K, S>
where
    K: Copy + Unpin,
    S: Stream + Unpin,
{
    type Item = (K, S::Item);

    fn poll_next(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Option<Self::Item>> {
        let this = self.get_mut();
        this.waker.clone_from(cx.waker());

        let Some(stream) = &mut this.stream else {
            return Poll::Ready(None);
        };
        let item = ready!(stream.poll_next_unpin(cx));

        Poll::Ready(item.map(|item| (this.key, item)))
    }
}

#[cfg(test)]
mod tests {
    use futures::{executor::block_on, stream};

    use super::*;

    #[test]
    fn other_streams_keep_yielding_after_a_removal() {
        let mut streams = KeyedStreams::default();
        streams.push(1, stream::iter([1, 2]));
        streams.push(2, stream::iter([3, 4]));

        assert!(streams.remove(&2).is_some());

        assert_eq!(block_on(streams.collect::<Vec<_>>()), [(1, 1), (1, 2)]);
    }

    #[test]
    fn removing_a_pending_stream_ends_it() {
        let mut streams = KeyedStreams::default();
        streams.push(1, stream::pending::<()>());
        let mut cx = Context::from_waker(Waker::noop());

        assert!(streams.poll_next_unpin(&mut cx).is_pending());
        assert!(streams.remove(&1).is_some());

        assert!(matches!(
            streams.poll_next_unpin(&mut cx),
            Poll::Ready(None)
        ));
    }
}
