//! Process-wide pools of buffers, declared with [`buffer_pool!`].
//!
//! A pool hands out buffers of one capacity: either fixed at compile time or, for a
//! [`ResizableBufferPool`], the capacity requested most recently.
//!
//! Internally, a pool is a magazine allocator as described by Bonwick and Adams in
//! ["Magazines and Vmem"](https://www.usenix.org/legacy/event/usenix01/full_papers/bonwick/bonwick.pdf):
//! buffers move in batches of up to `BATCH_SIZE`. Each thread pulls and drops buffers through its
//! own magazine of two batches and only locks the pool's depot to trade a whole batch, an empty
//! one for a full one or the other way around.

#![cfg_attr(test, allow(clippy::unwrap_used))]

use std::{
    cell::RefCell,
    ops::{Deref, DerefMut},
    sync::{
        Mutex, MutexGuard, OnceLock, PoisonError,
        atomic::{AtomicUsize, Ordering},
    },
    thread::LocalKey,
};

use bytes::BytesMut;
use opentelemetry::{KeyValue, metrics::UpDownCounter};

/// Declares a process-wide [`BufferPool`] together with the thread-local magazine of its buffers.
///
/// With a capacity, the static is the pool itself:
///
/// ```
/// bufferpool::buffer_pool!(static PACKETS: Vec<u8> = (1280, "packets"));
///
/// let buffer = PACKETS.pull();
/// ```
///
/// Without, the static is a [`ResizableBufferPool`] whose capacity is set at runtime:
///
/// ```
/// bufferpool::buffer_pool!(static DATAGRAMS: Vec<u8>, "datagrams");
///
/// let pool = DATAGRAMS.with_capacity(64 * 1280);
/// let buffer = pool.pull();
/// ```
#[macro_export]
macro_rules! buffer_pool {
    ($(#[$attr:meta])* $vis:vis static $name:ident: $ty:ty = ($capacity:expr, $tag:expr $(,)?)) => {
        $(#[$attr])*
        $vis static $name: $crate::BufferPool<$ty> = {
            ::std::thread_local!(static MAGAZINE: ::std::cell::RefCell<$crate::Magazine<$ty>> = const { ::std::cell::RefCell::new($crate::Magazine::new()) });

            $crate::BufferPool::new($capacity, $tag, &MAGAZINE)
        };
    };
    ($(#[$attr:meta])* $vis:vis static $name:ident: $ty:ty, $tag:expr $(,)?) => {
        $(#[$attr])*
        $vis static $name: $crate::ResizableBufferPool<$ty> = {
            ::std::thread_local!(static MAGAZINE: ::std::cell::RefCell<$crate::Magazine<$ty>> = const { ::std::cell::RefCell::new($crate::Magazine::new()) });

            $crate::ResizableBufferPool::new($tag, &MAGAZINE)
        };
    };
}

/// The number of buffers that move between a thread's magazine and its pool at once.
const BATCH_SIZE: usize = 32;

/// A process-wide pool of buffers that are all equal in size, declared with [`buffer_pool!`].
///
/// Each thread keeps up to two batches of buffers in its own magazine and only locks the depot
/// to refill an empty magazine or to hand back a batch from a full one.
pub struct BufferPool<B: 'static> {
    depot: Mutex<Depot<B>>,
    magazine: &'static LocalKey<RefCell<Magazine<B>>>,

    /// The size every buffer in the pool is allocated with.
    capacity: AtomicUsize,
    /// The pool's name, used to attribute a capacity deviation to a specific pool.
    tag: &'static str,
    buffer_count: OnceLock<BufferCount>,
}

impl<B> BufferPool<B>
where
    B: Buf,
{
    #[doc(hidden)]
    pub const fn new(
        capacity: usize,
        tag: &'static str,
        magazine: &'static LocalKey<RefCell<Magazine<B>>>,
    ) -> Self {
        Self {
            depot: Mutex::new(Depot {
                full: Vec::new(),
                empty: Vec::new(),
            }),
            magazine,
            capacity: AtomicUsize::new(capacity),
            tag,
            buffer_count: OnceLock::new(),
        }
    }

    pub fn pull(&'static self) -> Buffer<B> {
        let buffer = self.take();

        Buffer {
            capacity: B::capacity(&buffer),
            inner: Some(buffer),
            pool: self,
        }
    }

    /// Takes a buffer from this thread's magazine, discarding any of a previous capacity.
    ///
    /// During thread exit, the buffer comes from the depot directly.
    fn take(&'static self) -> B {
        let capacity = self.capacity();

        loop {
            let buffer = self
                .magazine
                .try_with(|magazine| magazine.borrow_mut().pop(self))
                .unwrap_or_else(|_| self.depot().pop());

            let Some(buffer) = buffer else {
                // TODO: It would be nice to eventually create a fixed amount of buffers upfront.
                // This however means that getting a buffer can fail which would require us to implement back-pressure.
                self.buffer_count().add(1, capacity);

                return B::with_capacity(capacity);
            };

            if B::capacity(&buffer) == capacity {
                return buffer;
            }

            self.buffer_count().add(-1, B::capacity(&buffer));
        }
    }

    /// Puts a buffer into this thread's magazine.
    ///
    /// During thread exit, the buffer goes to the depot directly.
    fn give(&'static self, buffer: B) {
        let mut buffer = Some(buffer);

        let _ = self.magazine.try_with(|magazine| {
            if let Some(buffer) = buffer.take() {
                magazine.borrow_mut().push(self, buffer);
            }
        });

        if let Some(buffer) = buffer {
            self.depot().full.push(Batch {
                buffers: vec![buffer],
            });
        }
    }

    fn buffer_count(&self) -> &BufferCount {
        self.buffer_count
            .get_or_init(|| BufferCount::new(otel_instruments::buffer_count(), self.tag))
    }
}

impl<B> BufferPool<B>
where
    B: ResizeBuf + DerefMut<Target = [u8]>,
{
    pub fn pull_initialised(&'static self, data: &[u8]) -> Buffer<B> {
        let mut buffer = self.pull();
        let len = data.len();

        buffer.resize_to(len);
        buffer.copy_from_slice(data);

        buffer
    }
}

impl<B> BufferPool<B> {
    fn capacity(&self) -> usize {
        self.capacity.load(Ordering::Relaxed)
    }

    // A magazine's slow path: `#[cold]` keeps it from bloating the inlined pull and drop.
    #[cold]
    fn trade_empty(&self, empty: Batch<B>) -> Result<Batch<B>, Batch<B>> {
        self.depot().trade_empty(empty)
    }

    #[cold]
    fn trade_full(&self, full: Batch<B>) -> Batch<B> {
        self.depot().trade_full(full)
    }

    fn depot(&self) -> MutexGuard<'_, Depot<B>> {
        self.depot.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

/// A [`BufferPool`] whose capacity is only known at runtime, declared with [`buffer_pool!`].
///
/// Only the capacity requested most recently keeps its buffers: changing it discards the idle
/// buffers of the previous one, and buffers of the previous capacity still in use are discarded
/// once they return.
pub struct ResizableBufferPool<B: 'static> {
    pool: BufferPool<B>,
}

impl<B> ResizableBufferPool<B>
where
    B: Buf,
{
    #[doc(hidden)]
    pub const fn new(tag: &'static str, magazine: &'static LocalKey<RefCell<Magazine<B>>>) -> Self {
        Self {
            pool: BufferPool::new(0, tag, magazine),
        }
    }

    /// Returns the pool, changing the capacity of its buffers to `capacity` if necessary.
    pub fn with_capacity(&'static self, capacity: usize) -> &'static BufferPool<B> {
        let pool = &self.pool;

        if pool.capacity() == capacity {
            return pool;
        }

        pool.capacity.store(capacity, Ordering::Relaxed);

        // Without a buffer count, the pool has not allocated any buffers yet.
        if let Some(buffer_count) = pool.buffer_count.get() {
            let idle = std::mem::take(&mut pool.depot().full);

            for buffer in idle.into_iter().flat_map(|batch| batch.buffers) {
                buffer_count.add(-1, B::capacity(&buffer));
            }
        }

        pool
    }
}

/// A thread's buffers of a [`BufferPool`]: pulls and drops use `loaded`, `spare` is a full or
/// empty batch on standby.
///
/// Buffers still in the magazine when the thread exits are handed back to the pool.
#[doc(hidden)]
pub struct Magazine<B: 'static> {
    loaded: Batch<B>,
    spare: Batch<B>,
    /// Where the buffers go when the thread exits; set once the magazine holds any.
    pool: Option<&'static BufferPool<B>>,
}

impl<B> Magazine<B> {
    #[expect(
        clippy::new_without_default,
        reason = "Must be `const` for `thread_local!`"
    )]
    pub const fn new() -> Self {
        Self {
            loaded: Batch::new(),
            spare: Batch::new(),
            pool: None,
        }
    }

    fn pop(&mut self, pool: &'static BufferPool<B>) -> Option<B> {
        self.pool = Some(pool);

        if self.loaded.is_empty() {
            if self.spare.is_empty() {
                let (Ok(batch) | Err(batch)) = pool.trade_empty(std::mem::take(&mut self.loaded));

                self.loaded = batch;
            } else {
                std::mem::swap(&mut self.loaded, &mut self.spare);
            }
        }

        self.loaded.pop()
    }

    fn push(&mut self, pool: &'static BufferPool<B>, buffer: B) {
        self.pool = Some(pool);

        if self.loaded.is_full() {
            if self.spare.is_full() {
                self.spare = pool.trade_full(std::mem::take(&mut self.spare));
            }

            std::mem::swap(&mut self.loaded, &mut self.spare);
        }

        self.loaded.push(buffer);
    }
}

impl<B> Drop for Magazine<B> {
    fn drop(&mut self) {
        let Some(pool) = self.pool else {
            return;
        };

        for batch in [
            std::mem::take(&mut self.loaded),
            std::mem::take(&mut self.spare),
        ] {
            if !batch.is_empty() {
                pool.depot().full.push(batch);
            }
        }
    }
}

/// Up to [`BATCH_SIZE`] buffers; empty batches keep their allocation for reuse.
struct Batch<B> {
    buffers: Vec<B>,
}

impl<B> Batch<B> {
    const fn new() -> Self {
        Self {
            buffers: Vec::new(),
        }
    }

    fn pop(&mut self) -> Option<B> {
        self.buffers.pop()
    }

    fn push(&mut self, buffer: B) {
        self.buffers.push(buffer);
    }

    fn is_full(&self) -> bool {
        self.buffers.len() >= BATCH_SIZE
    }

    fn is_empty(&self) -> bool {
        self.buffers.is_empty()
    }
}

impl<B> Default for Batch<B> {
    fn default() -> Self {
        Self::new()
    }
}

/// The pool's shared stock behind the mutex: full batches to take, empty ones to fill.
struct Depot<B> {
    full: Vec<Batch<B>>,
    empty: Vec<Batch<B>>,
}

impl<B> Depot<B> {
    /// Gives back an empty batch, takes a full one (if there is any).
    fn trade_empty(&mut self, empty: Batch<B>) -> Result<Batch<B>, Batch<B>> {
        let Some(full) = self.full.pop() else {
            return Err(empty);
        };

        if empty.buffers.capacity() > 0 {
            self.empty.push(empty);
        }

        Ok(full)
    }

    /// Gives back a full batch, takes an empty one (allocating only if there is none).
    fn trade_full(&mut self, full: Batch<B>) -> Batch<B> {
        self.full.push(full);

        self.empty.pop().unwrap_or_else(|| Batch {
            buffers: Vec::with_capacity(BATCH_SIZE),
        })
    }

    /// Takes a single buffer, for a thread without a magazine.
    fn pop(&mut self) -> Option<B> {
        let batch = self.full.last_mut()?;
        let buffer = batch.pop();

        if batch.is_empty() {
            self.full.pop();
        }

        buffer
    }
}

/// Counts the buffers a pool has allocated and not yet discarded, per capacity.
struct BufferCount {
    counter: UpDownCounter<i64>,
    tag: &'static str,
}

impl BufferCount {
    fn new(counter: UpDownCounter<i64>, tag: &'static str) -> Self {
        Self { counter, tag }
    }

    fn add(&self, delta: i64, capacity: usize) {
        self.counter.add(
            delta,
            &[
                KeyValue::new("system.buffer.pool.name", self.tag),
                KeyValue::new("system.buffer.pool.buffer_size", capacity as i64),
            ],
        );
    }
}

pub struct Buffer<B: Buf + 'static> {
    inner: Option<B>,
    /// The capacity `inner` was pulled with; it only deviates when `inner` was reallocated.
    capacity: usize,

    pool: &'static BufferPool<B>,
}

impl Buffer<Vec<u8>> {
    /// Shifts the start of the buffer to the right by N bytes, returning the bytes removed from the front of the buffer.
    pub fn shift_start_right(&mut self, num: usize) -> Vec<u8> {
        let num_to_end = self.split_off(num);

        std::mem::replace(self.storage_mut(), num_to_end)
    }

    /// Shifts the start of the buffer to the left by N bytes, returning a slice to the added bytes at the front of the buffer.
    pub fn shift_start_left(&mut self, num: usize) -> &mut [u8] {
        let current_len = self.len();

        self.resize(current_len + num, 0);
        self.copy_within(..current_len, num);

        &mut self[..num]
    }
}

impl<B> Buffer<B>
where
    B: Buf,
{
    fn storage(&self) -> &B {
        self.inner
            .as_ref()
            .expect("should always have buffer storage until dropped")
    }

    fn storage_mut(&mut self) -> &mut B {
        self.inner
            .as_mut()
            .expect("should always have buffer storage until dropped")
    }
}

impl<B> Clone for Buffer<B>
where
    B: CloneBuf,
{
    fn clone(&self) -> Self {
        let mut copy = self.pool.take();

        self.storage().clone(&mut copy);

        Self {
            capacity: B::capacity(&copy),
            inner: Some(copy),
            pool: self.pool,
        }
    }
}

impl<B> PartialEq for Buffer<B>
where
    B: Buf + Deref<Target = [u8]>,
{
    fn eq(&self, other: &Self) -> bool {
        self.as_ref() == other.as_ref()
    }
}

impl<B> Eq for Buffer<B> where B: Buf + Deref<Target = [u8]> {}

impl<B> PartialOrd for Buffer<B>
where
    B: Buf + Deref<Target = [u8]>,
{
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        Some(self.cmp(other))
    }
}

impl<B> Ord for Buffer<B>
where
    B: Buf + Deref<Target = [u8]>,
{
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        self.as_ref().cmp(other.as_ref())
    }
}

impl<B> std::fmt::Debug for Buffer<B>
where
    B: Buf,
{
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_tuple("Buffer").finish()
    }
}

impl<B> Deref for Buffer<B>
where
    B: Buf,
{
    type Target = B;

    fn deref(&self) -> &Self::Target {
        self.storage()
    }
}

impl<B> DerefMut for Buffer<B>
where
    B: Buf,
{
    fn deref_mut(&mut self) -> &mut Self::Target {
        self.storage_mut()
    }
}

impl<B> Drop for Buffer<B>
where
    B: Buf,
{
    fn drop(&mut self) {
        let mut buffer = self.inner.take().expect("should have storage in `Drop`");

        buffer.reset();

        let expected = self.capacity;
        if let Some(actual) = deviating_capacity(expected, B::capacity(&buffer)) {
            // Discard deviating buffers: re-pooling them would re-emit this warning on every reuse.
            tracing::warn!(
                pool = %self.pool.tag,
                expected_capacity = %expected,
                actual_capacity = %actual,
                "Discarding buffer with a different capacity than it was allocated with"
            );

            self.pool.buffer_count().add(-1, expected);

            return;
        }

        // The pool was resized while this buffer was in use.
        if expected != self.pool.capacity() {
            self.pool.buffer_count().add(-1, expected);

            return;
        }

        self.pool.give(buffer);
    }
}

/// Returns the `actual` capacity if it deviates from the `expected` one a pool allocates its buffers with.
fn deviating_capacity(expected: usize, actual: usize) -> Option<usize> {
    (expected != actual).then_some(actual)
}

pub trait Buf: Sized {
    fn with_capacity(capacity: usize) -> Self;
    fn capacity(&self) -> usize;

    /// Restores the buffer to a pristine state before it returns to the pool.
    ///
    /// Byte buffers are plain scratch space and don't need this; containers like
    /// [`VecBuf`] use it to drop their items so those don't stay alive inside an
    /// idle pool.
    fn reset(&mut self) {}
}

/// A [`Buf`] whose contents can be copied into another buffer of its pool.
pub trait CloneBuf: Buf {
    fn clone(&self, dst: &mut Self);
}

/// A [`Buf`] whose length can be set directly, e.g. to fit incoming data.
///
/// Only byte buffers implement this; containers like [`VecBuf`] deliberately
/// don't: their length only ever changes by pushing or truncating actual items.
pub trait ResizeBuf: Buf {
    fn resize_to(&mut self, len: usize);
}

/// A pooled `Vec` of arbitrary items.
///
/// In contrast to the byte-oriented [`Buf`] implementations ([`Vec<u8>`] and
/// [`BytesMut`]) - which hand out zero-initialised, full-length scratch space to be
/// written into - a `VecBuf` is a container: it is pulled empty, pushed into, and
/// emptied again when it returns to the pool.
#[derive(Debug)]
pub struct VecBuf<T>(Vec<T>);

impl<T> Deref for VecBuf<T> {
    type Target = Vec<T>;

    fn deref(&self) -> &Vec<T> {
        &self.0
    }
}

impl<T> DerefMut for VecBuf<T> {
    fn deref_mut(&mut self) -> &mut Vec<T> {
        &mut self.0
    }
}

impl<T> Buf for VecBuf<T> {
    fn with_capacity(capacity: usize) -> Self {
        Self(Vec::with_capacity(capacity))
    }

    fn capacity(&self) -> usize {
        self.0.capacity()
    }

    fn reset(&mut self) {
        self.0.clear();
    }
}

impl<T> CloneBuf for VecBuf<T>
where
    T: Clone,
{
    fn clone(&self, dst: &mut Self) {
        dst.0.clear();
        dst.0.extend(self.0.iter().cloned());
    }
}

impl Buf for Vec<u8> {
    fn with_capacity(capacity: usize) -> Self {
        vec![0; capacity]
    }

    fn capacity(&self) -> usize {
        Vec::capacity(self)
    }
}

impl CloneBuf for Vec<u8> {
    fn clone(&self, dst: &mut Self) {
        dst.resize(self.len(), 0);
        dst.copy_from_slice(self);
    }
}

impl ResizeBuf for Vec<u8> {
    fn resize_to(&mut self, len: usize) {
        self.resize(len, 0);
    }
}

impl Buf for BytesMut {
    fn with_capacity(capacity: usize) -> Self {
        BytesMut::zeroed(capacity)
    }

    fn capacity(&self) -> usize {
        BytesMut::capacity(self)
    }
}

impl CloneBuf for BytesMut {
    fn clone(&self, dst: &mut Self) {
        dst.resize(self.len(), 0);
        dst.copy_from_slice(self);
    }
}

impl ResizeBuf for BytesMut {
    fn resize_to(&mut self, len: usize) {
        self.resize(len, 0);
    }
}

#[cfg(test)]
mod tests {
    use std::{collections::HashSet, time::Duration};

    use opentelemetry::metrics::MeterProvider;
    use opentelemetry_sdk::metrics::{
        InMemoryMetricExporter, PeriodicReader, SdkMeterProvider,
        data::{AggregatedMetrics, MetricData},
    };

    use super::*;

    #[test]
    fn buffer_can_be_cloned() {
        let pool = test_pool!(1024);

        let buffer = pool.pull_initialised(b"hello world");

        #[allow(clippy::redundant_clone)]
        let buffer2 = buffer.clone();

        assert_eq!(&buffer2[..], &buffer[..]);
    }

    #[test]
    fn cloned_buffer_owns_its_own_memory() {
        let pool = test_pool!(1024);

        let buffer = pool.pull_initialised(b"hello world");

        let buffer2 = buffer.clone();
        drop(buffer);

        assert_eq!(&buffer2[..11], b"hello world");
    }

    #[test]
    fn initialised_buffer_is_only_as_long_as_content() {
        let pool = test_pool!(1024);

        let buffer = pool.pull_initialised(b"hello world");

        assert_eq!(buffer.len(), 11);
    }

    #[test]
    fn deviating_capacity_flags_only_changed_sizes() {
        assert_eq!(deviating_capacity(1024, 1024), None);
        assert_eq!(deviating_capacity(1024, 2048), Some(2048));
        assert_eq!(deviating_capacity(1024, 512), Some(512));
    }

    #[test]
    fn returning_a_reallocated_buffer_discards_it() {
        let pool = test_pool!(8);

        let mut buffer = pool.pull();
        buffer.resize_to(8 * 1024); // Force a reallocation beyond the pool's capacity.
        drop(buffer);

        assert_eq!(pool.pull().capacity(), 8);
    }

    #[tokio::test]
    async fn discarded_buffer_is_subtracted_from_buffer_count() {
        let (provider, exporter) = init_meter_provider();
        let pool = test_pool!(8);
        record_buffer_count(pool, &provider);

        let mut buffer = pool.pull();
        buffer.resize_to(8 * 1024); // Force a reallocation beyond the pool's capacity.
        drop(buffer);

        tokio::time::sleep(Duration::from_millis(100)).await; // Wait for metrics to be exported.

        assert_eq!(get_num_buffers(&exporter), 0);
    }

    #[tokio::test]
    async fn buffer_count_includes_pooled_buffers() {
        let (provider, exporter) = init_meter_provider();
        let pool = test_pool!(1024);
        record_buffer_count(pool, &provider);

        let buffers = (0..3).map(|_| pool.pull()).collect::<Vec<_>>();
        drop(buffers);
        let _buffers = (0..3).map(|_| pool.pull()).collect::<Vec<_>>();

        tokio::time::sleep(Duration::from_millis(100)).await; // Wait for metrics to be exported.

        assert_eq!(get_num_buffers(&exporter), 3);
    }

    /// The whole point of pooling is passing buffers around cheaply: a handle is
    /// the buffer itself plus a reference to its pool.
    #[cfg(target_pointer_width = "64")]
    #[test]
    fn handles_are_slim() {
        assert_eq!(size_of::<Buffer<Vec<u8>>>(), 32);
    }

    #[test]
    fn pool_recycles_buffers() {
        let pool = test_pool!(8);

        let buffer = pool.pull();
        let storage = buffer.as_ptr();
        drop(buffer);

        assert_eq!(pool.pull().as_ptr(), storage);
    }

    #[test]
    fn full_magazine_hands_a_batch_to_the_pool() {
        let pool = test_pool!(8);

        let buffers = (0..2 * BATCH_SIZE + 1)
            .map(|_| pool.pull())
            .collect::<Vec<_>>();
        drop(buffers);

        assert_eq!(pool.depot().full.len(), 1);
        assert_eq!(depot_len(pool), BATCH_SIZE);
        assert_eq!(magazine_len(pool), BATCH_SIZE + 1);
    }

    #[test]
    fn empty_magazine_refills_from_the_pool() {
        let pool = test_pool!(8);

        let buffers = (0..2 * BATCH_SIZE + 1)
            .map(|_| pool.pull())
            .collect::<Vec<_>>();
        drop(buffers);

        let _buffers = (0..BATCH_SIZE + 2).map(|_| pool.pull()).collect::<Vec<_>>();

        assert_eq!(depot_len(pool), 0);
        assert_eq!(magazine_len(pool), BATCH_SIZE - 1);
    }

    #[test]
    fn buffers_dropped_on_another_thread_are_reused() {
        let pool = test_pool!(8);

        let buffers = (0..4 * BATCH_SIZE).map(|_| pool.pull()).collect::<Vec<_>>();
        let storage = buffers.iter().map(|b| b.as_ptr()).collect::<HashSet<_>>();
        std::thread::spawn(move || drop(buffers)).join().unwrap();

        let reused = (0..4 * BATCH_SIZE).map(|_| pool.pull()).collect::<Vec<_>>();

        assert_eq!(
            reused.iter().map(|b| b.as_ptr()).collect::<HashSet<_>>(),
            storage
        );
    }

    #[test]
    fn exiting_thread_hands_its_magazine_to_the_pool() {
        let pool = test_pool!(8);

        std::thread::spawn(|| {
            let buffers = (0..3).map(|_| pool.pull()).collect::<Vec<_>>();
            drop(buffers);
        })
        .join()
        .unwrap();

        assert_eq!(depot_len(pool), 3);
    }

    #[test]
    fn buffer_dropped_after_the_magazine_returns_to_the_pool() {
        thread_local!(static HOLDER: RefCell<Option<Buffer<Vec<u8>>>> = const { RefCell::new(None) });

        let pool = test_pool!(8);

        std::thread::spawn(|| {
            // Initialise the holder before the magazine so it is likely destroyed after it.
            HOLDER.with(|_| {});
            let buffer = pool.pull();
            HOLDER.with(|h| *h.borrow_mut() = Some(buffer));
        })
        .join()
        .unwrap();

        assert_eq!(depot_len(pool), 1);
    }

    #[test]
    fn with_capacity_returns_the_same_pool() {
        buffer_pool!(static POOL: Vec<u8>, "test");

        let pool = POOL.with_capacity(8);
        let again = POOL.with_capacity(16);

        assert!(std::ptr::eq(pool, again));
        assert_eq!(pool.pull().capacity(), 16);
    }

    #[test]
    fn changing_the_capacity_frees_idle_buffers() {
        buffer_pool!(static POOL: Vec<u8>, "test");
        let pool = POOL.with_capacity(8);

        let buffers = (0..4 * BATCH_SIZE).map(|_| pool.pull()).collect::<Vec<_>>();
        std::thread::spawn(move || drop(buffers)).join().unwrap();
        assert_eq!(depot_len(pool), 4 * BATCH_SIZE);

        POOL.with_capacity(16);

        assert_eq!(depot_len(pool), 0);
    }

    #[tokio::test]
    async fn buffer_of_a_previous_capacity_is_discarded_on_return() {
        let (provider, exporter) = init_meter_provider();
        buffer_pool!(static POOL: Vec<u8>, "test");
        let pool = POOL.with_capacity(8);
        record_buffer_count(pool, &provider);
        let logs = logging::CapturingWriter::default();
        let _guard = tracing::subscriber::set_default(
            tracing_subscriber::fmt().with_writer(logs.clone()).finish(),
        );

        let buffer = pool.pull();
        POOL.with_capacity(16);
        drop(buffer);

        tokio::time::sleep(Duration::from_millis(100)).await; // Wait for metrics to be exported.

        assert_eq!(get_num_buffers(&exporter), 0);
        assert_eq!(magazine_len(pool), 0);
        assert!(logs.lines().is_empty());
    }

    #[test]
    fn magazine_discards_buffers_of_a_previous_capacity() {
        buffer_pool!(static POOL: Vec<u8>, "test");
        let pool = POOL.with_capacity(8);

        let buffers = (0..3).map(|_| pool.pull()).collect::<Vec<_>>();
        drop(buffers);
        POOL.with_capacity(16);
        let buffer = pool.pull();

        assert_eq!(buffer.capacity(), 16);
        assert_eq!(magazine_len(pool), 0);
    }

    #[test]
    fn switching_back_to_a_previous_capacity() {
        buffer_pool!(static POOL: Vec<u8>, "test");
        let pool = POOL.with_capacity(8);
        drop(pool.pull());

        POOL.with_capacity(16);
        drop(pool.pull());
        POOL.with_capacity(8);

        let buffer = pool.pull();
        let storage = buffer.as_ptr();
        assert_eq!(buffer.capacity(), 8);
        drop(buffer);

        assert_eq!(pool.pull().as_ptr(), storage);
    }

    #[test]
    fn vec_buf_returns_to_the_pool_empty() {
        buffer_pool!(static POOL: VecBuf<String> = (4, "test"));

        let mut buf = POOL.pull();
        buf.push("hello".to_owned());
        drop(buf);

        // The dropped buffer's storage is recycled; it must come back empty.
        let buf = POOL.pull();
        assert!(buf.is_empty());
    }

    #[test]
    fn shift_start_right() {
        let pool = test_pool!(1024);

        let mut buffer = pool.pull_initialised(b"hello world");

        let front = buffer.shift_start_right(5);

        assert_eq!(front, b"hello");
        assert_eq!(&*buffer, b" world");
    }

    #[test]
    fn shift_start_left() {
        let pool = test_pool!(1024);

        let mut buffer = pool.pull_initialised(b"hello world");

        let front = buffer.shift_start_left(5);
        front.copy_from_slice(b"12345");

        assert_eq!(&*buffer, b"12345hello world");
    }

    /// Declares a new pool, so tests don't share buffers.
    macro_rules! test_pool {
        ($capacity:expr) => {{
            buffer_pool!(static POOL: Vec<u8> = ($capacity, "test"));

            &POOL
        }};
    }
    use test_pool;

    /// The number of buffers in this thread's magazine of `pool`.
    fn magazine_len(pool: &BufferPool<Vec<u8>>) -> usize {
        pool.magazine.with(|m| {
            let magazine = m.borrow();

            magazine.loaded.buffers.len() + magazine.spare.buffers.len()
        })
    }

    /// The number of buffers in the depot of `pool`.
    fn depot_len(pool: &BufferPool<Vec<u8>>) -> usize {
        pool.depot().full.iter().map(|b| b.buffers.len()).sum()
    }

    fn record_buffer_count(pool: &BufferPool<Vec<u8>>, provider: &SdkMeterProvider) {
        let counter = otel_instruments::buffer_count_with(&provider.meter("connlib"));

        assert!(
            pool.buffer_count
                .set(BufferCount::new(counter, pool.tag))
                .is_ok()
        );
    }

    fn get_num_buffers(exporter: &InMemoryMetricExporter) -> i64 {
        let metrics = exporter.get_finished_metrics().unwrap();

        let metric = &metrics
            .iter()
            .last()
            .and_then(|m| m.scope_metrics().next())
            .and_then(|m| m.metrics().next())
            .unwrap();
        let AggregatedMetrics::I64(MetricData::Sum(sum)) = metric.data() else {
            panic!("Not an i64 sum");
        };

        sum.data_points().map(|point| point.value()).sum()
    }

    fn init_meter_provider() -> (SdkMeterProvider, InMemoryMetricExporter) {
        let exporter = InMemoryMetricExporter::default();

        let provider = SdkMeterProvider::builder()
            .with_reader(
                PeriodicReader::builder(exporter.clone())
                    .with_interval(Duration::from_millis(1))
                    .build(),
            )
            .build();

        (provider, exporter)
    }
}
