#![cfg_attr(test, allow(clippy::unwrap_used))]

mod sharing;

#[cfg(any(target_os = "linux", target_os = "macos", target_os = "ios"))]
#[path = "shared_local.rs"]
mod shared;
#[cfg(not(any(target_os = "linux", target_os = "macos", target_os = "ios")))]
#[path = "shared_thread_safe.rs"]
mod shared;

pub use shared::{DefaultSharing, SharedBufferPool};
pub use sharing::{Local, Sharing, ThreadSafe};

use bytes::BytesMut;
use std::ops::{Deref, DerefMut};

/// A pool with no synchronization that belongs to a single thread.
///
/// Its buffers cannot cross threads:
///
/// ```compile_fail
/// let pool = bufferpool::LocalBufferPool::<Vec<u8>>::new(1024, "example");
/// let buffer = pool.pull();
/// std::thread::spawn(move || drop(buffer));
/// ```
pub type LocalBufferPool<B> = BufferPool<B, Local>;
/// A pool that supports sharing buffers between threads.
pub type ThreadSafeBufferPool<B> = BufferPool<B, ThreadSafe>;

use opentelemetry::{
    KeyValue,
    metrics::{Meter, UpDownCounter},
};

/// A pool of equally sized buffers.
///
/// The sharing policy also determines whether its buffers may cross threads.
/// The default is local on Linux, macOS and iOS, and thread-safe elsewhere.
pub struct BufferPool<B, S: Sharing = DefaultSharing> {
    inner: S::Shared<PoolInner<B, S>>,
}

impl<B, S: Sharing> Clone for BufferPool<B, S> {
    fn clone(&self) -> Self {
        Self {
            inner: self.inner.clone(),
        }
    }
}

/// The state shared between a pool and all of its buffers.
///
/// Everything that is constant per pool lives here (rather than in each buffer),
/// keeping a [`Buffer`] handle at the size of the buffer itself plus one pool reference.
struct PoolInner<B, S: Sharing> {
    queue: S::Queue<B>,

    /// Creates (and counts) a new buffer for when the queue is empty.
    new_buffer_fn: Box<dyn Fn() -> B + Send + Sync>,

    /// The size every buffer in the pool is allocated with.
    ///
    /// A returned buffer whose capacity deviates from this no longer fits the pool's
    /// "all buffers are equal in size" invariant and indicates an accidental reallocation.
    capacity: usize,
    /// The pool's name, used to attribute a capacity deviation to a specific pool.
    tag: &'static str,
    /// Reads the current capacity of a buffer.
    ///
    /// Captured as a function pointer so the capacity can be inspected in `Buffer`'s
    /// `Drop`, which cannot itself require the [`Buf`] bound.
    capacity_of: fn(&B) -> usize,
    /// Restores a buffer to a pristine state; see [`Buf::reset`].
    ///
    /// A function pointer for the same reason as `capacity_of`.
    reset: fn(&mut B),

    attributes: [KeyValue; 2],
    counter: UpDownCounter<i64>,
}

impl<B, S: Sharing> Drop for PoolInner<B, S> {
    fn drop(&mut self) {
        let mut num_buffers = 0;

        while S::pop(&self.queue).is_some() {
            num_buffers += 1;
        }

        self.counter.add(-num_buffers, &self.attributes);
    }
}

impl<B, S: Sharing> BufferPool<B, S>
where
    B: Buf,
{
    pub fn new(capacity: usize, tag: &'static str) -> Self {
        Self::with_counter(capacity, tag, otel_instruments::buffer_count())
    }

    /// Like [`BufferPool::new`], but records the buffer count through the given `meter`.
    pub fn with_meter(capacity: usize, tag: &'static str, meter: &Meter) -> Self {
        Self::with_counter(capacity, tag, otel_instruments::buffer_count_with(meter))
    }

    fn with_counter(
        capacity: usize,
        tag: &'static str,
        buffer_counter: UpDownCounter<i64>,
    ) -> Self {
        let attributes = [
            KeyValue::new("system.buffer.pool.name", tag),
            KeyValue::new("system.buffer.pool.buffer_size", capacity as i64),
        ];

        Self {
            inner: S::share(PoolInner {
                queue: S::Queue::default(),

                // TODO: It would be nice to eventually create a fixed amount of buffers upfront.
                // This however means that getting a buffer can fail which would require us to implement back-pressure.
                new_buffer_fn: Box::new({
                    let counter = buffer_counter.clone();
                    let attributes = attributes.clone();

                    move || {
                        counter.add(1, &attributes);

                        B::with_capacity(capacity)
                    }
                }),
                capacity,
                tag,
                capacity_of: B::capacity,
                reset: B::reset,
                attributes,
                counter: buffer_counter,
            }),
        }
    }

    pub fn pull(&self) -> Buffer<B, S> {
        Buffer {
            inner: Some(S::pop(&self.inner.queue).unwrap_or_else(|| (self.inner.new_buffer_fn)())),
            pool: self.inner.clone(),
        }
    }
}

impl<B, S: Sharing> BufferPool<B, S>
where
    B: ResizeBuf + DerefMut<Target = [u8]>,
{
    pub fn pull_initialised(&self, data: &[u8]) -> Buffer<B, S> {
        let mut buffer = self.pull();
        let len = data.len();

        buffer.resize_to(len);
        buffer.copy_from_slice(data);

        buffer
    }
}

pub struct Buffer<B, S: Sharing = DefaultSharing> {
    inner: Option<B>,

    pool: S::Shared<PoolInner<B, S>>,
}

impl<S: Sharing> Buffer<Vec<u8>, S> {
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

impl<B, S: Sharing> Buffer<B, S> {
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

impl<B, S: Sharing> Clone for Buffer<B, S>
where
    B: Buf,
{
    fn clone(&self) -> Self {
        let mut copy = S::pop(&self.pool.queue).unwrap_or_else(|| (self.pool.new_buffer_fn)());

        self.storage().clone(&mut copy);

        Self {
            inner: Some(copy),
            pool: self.pool.clone(),
        }
    }
}

impl<B, S: Sharing> PartialEq for Buffer<B, S>
where
    B: Deref<Target = [u8]>,
{
    fn eq(&self, other: &Self) -> bool {
        self.as_ref() == other.as_ref()
    }
}

impl<B, S: Sharing> Eq for Buffer<B, S> where B: Deref<Target = [u8]> {}

impl<B, S: Sharing> PartialOrd for Buffer<B, S>
where
    B: Deref<Target = [u8]>,
{
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        Some(self.cmp(other))
    }
}

impl<B, S: Sharing> Ord for Buffer<B, S>
where
    B: Deref<Target = [u8]>,
{
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        self.as_ref().cmp(other.as_ref())
    }
}

impl<B, S: Sharing> std::fmt::Debug for Buffer<B, S> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_tuple("Buffer").finish()
    }
}

impl<B, S: Sharing> Deref for Buffer<B, S> {
    type Target = B;

    fn deref(&self) -> &Self::Target {
        self.storage()
    }
}

impl<B, S: Sharing> DerefMut for Buffer<B, S> {
    fn deref_mut(&mut self) -> &mut Self::Target {
        self.storage_mut()
    }
}

impl<B, S: Sharing> Drop for Buffer<B, S> {
    fn drop(&mut self) {
        let mut buffer = self.inner.take().expect("should have storage in `Drop`");

        (self.pool.reset)(&mut buffer);

        let actual = (self.pool.capacity_of)(&buffer);
        if let Some(actual) = deviating_capacity(self.pool.capacity, actual) {
            // Discard deviating buffers: re-pooling them would re-emit this warning on every reuse.
            tracing::warn!(
                pool = %self.pool.tag,
                expected_capacity = %self.pool.capacity,
                actual_capacity = %actual,
                "Discarding buffer with a different capacity than it was allocated with"
            );

            self.pool.counter.add(-1, &self.pool.attributes);

            return;
        }

        S::push(&self.pool.queue, buffer);
    }
}

/// Returns the `actual` capacity if it deviates from the `expected` one a pool allocates its buffers with.
fn deviating_capacity(expected: usize, actual: usize) -> Option<usize> {
    (expected != actual).then_some(actual)
}

pub trait Buf: Sized {
    fn with_capacity(capacity: usize) -> Self;
    fn clone(&self, dst: &mut Self);
    fn capacity(&self) -> usize;

    /// Restores the buffer to a pristine state before it returns to the pool.
    ///
    /// Byte buffers are plain scratch space and don't need this; containers like
    /// [`VecBuf`] use it to drop their items so those don't stay alive inside an
    /// idle pool.
    fn reset(&mut self) {}
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

impl<T> Buf for VecBuf<T>
where
    T: Clone,
{
    fn with_capacity(capacity: usize) -> Self {
        Self(Vec::with_capacity(capacity))
    }

    fn clone(&self, dst: &mut Self) {
        dst.0.clear();
        dst.0.extend(self.0.iter().cloned());
    }

    fn capacity(&self) -> usize {
        self.0.capacity()
    }

    fn reset(&mut self) {
        self.0.clear();
    }
}

impl Buf for Vec<u8> {
    fn with_capacity(capacity: usize) -> Self {
        vec![0; capacity]
    }

    fn clone(&self, dst: &mut Self) {
        dst.resize(self.len(), 0);
        dst.copy_from_slice(self);
    }

    fn capacity(&self) -> usize {
        Vec::capacity(self)
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

    fn clone(&self, dst: &mut Self) {
        dst.resize(self.len(), 0);
        dst.copy_from_slice(self);
    }

    fn capacity(&self) -> usize {
        BytesMut::capacity(self)
    }
}

impl ResizeBuf for BytesMut {
    fn resize_to(&mut self, len: usize) {
        self.resize(len, 0);
    }
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use opentelemetry::metrics::MeterProvider;
    use opentelemetry_sdk::metrics::{
        InMemoryMetricExporter, PeriodicReader, SdkMeterProvider,
        data::{AggregatedMetrics, MetricData},
    };

    use super::*;

    #[test]
    fn thread_safe_buffers_return_to_their_pool_across_threads() {
        fn assert_send_sync<T: Send + Sync>() {}
        assert_send_sync::<ThreadSafeBufferPool<Vec<u8>>>();
        assert_send_sync::<Buffer<Vec<u8>, ThreadSafe>>();

        let pool = ThreadSafeBufferPool::<Vec<u8>>::new(1024, "test");
        let buffer = pool.pull();
        let address = buffer.as_ptr() as usize;
        let worker_pool = pool.clone();

        std::thread::spawn(move || {
            drop(buffer);
            let mut recycled = worker_pool.pull();
            assert_eq!(recycled.as_ptr() as usize, address);
            recycled[0] = 42;
        })
        .join()
        .unwrap();

        let recycled = pool.pull();
        assert_eq!(recycled.as_ptr() as usize, address);
        assert_eq!(recycled[0], 42);
    }

    #[test]
    fn static_pools_keep_distinct_capacities_for_the_same_buffer_type() {
        static SMALL: SharedBufferPool<Vec<u8>> = shared_buffer_pool!(Vec<u8>, 8, "small");
        static LARGE: SharedBufferPool<Vec<u8>> = shared_buffer_pool!(Vec<u8>, 16, "large");

        assert_eq!(SMALL.pull().capacity(), 8);
        assert_eq!(LARGE.pull().capacity(), 16);
    }

    #[test]
    fn buffer_can_be_cloned() {
        let pool = BufferPool::<Vec<u8>>::new(1024, "test");

        let buffer = pool.pull_initialised(b"hello world");

        #[allow(clippy::redundant_clone)]
        let buffer2 = buffer.clone();

        assert_eq!(&buffer2[..], &buffer[..]);
    }

    #[test]
    fn cloned_buffer_owns_its_own_memory() {
        let pool = BufferPool::<Vec<u8>>::new(1024, "test");

        let buffer = pool.pull_initialised(b"hello world");

        let buffer2 = buffer.clone();
        drop(buffer);

        assert_eq!(&buffer2[..11], b"hello world");
    }

    #[test]
    fn initialised_buffer_is_only_as_long_as_content() {
        let pool = BufferPool::<Vec<u8>>::new(1024, "test");

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
        let pool = BufferPool::<Vec<u8>>::new(8, "test");

        let mut buffer = pool.pull();
        buffer.resize_to(8 * 1024); // Force a reallocation beyond the pool's capacity.
        drop(buffer);

        assert_eq!(pool.pull().capacity(), 8);
    }

    #[tokio::test]
    async fn discarded_buffer_is_subtracted_from_buffer_count() {
        let (provider, exporter) = init_meter_provider();
        let meter = provider.meter("connlib");

        let pool = BufferPool::<Vec<u8>>::with_meter(8, "test", &meter);

        let mut buffer = pool.pull();
        buffer.resize_to(8 * 1024); // Force a reallocation beyond the pool's capacity.
        drop(buffer);

        tokio::time::sleep(Duration::from_millis(100)).await; // Wait for metrics to be exported.

        assert_eq!(get_num_buffers(&exporter), 0);
    }

    /// The whole point of pooling is passing buffers around cheaply: a handle is
    /// the buffer itself plus one pool reference; everything else lives in the pool.
    #[cfg(target_pointer_width = "64")]
    #[test]
    fn handles_are_slim() {
        assert_eq!(size_of::<Buffer<Vec<u8>, Local>>(), 32);
        assert_eq!(size_of::<Buffer<Vec<u8>, ThreadSafe>>(), 32);
    }

    #[test]
    fn vec_buf_returns_to_the_pool_empty() {
        let pool = BufferPool::<VecBuf<String>>::new(4, "test");

        let mut buf = pool.pull();
        buf.push("hello".to_owned());
        drop(buf);

        // The dropped buffer's storage is recycled; it must come back empty.
        let buf = pool.pull();
        assert!(buf.is_empty());
    }

    #[test]
    fn shift_start_right() {
        let pool = BufferPool::<Vec<u8>>::new(1024, "test");

        let mut buffer = pool.pull_initialised(b"hello world");

        let front = buffer.shift_start_right(5);

        assert_eq!(front, b"hello");
        assert_eq!(&*buffer, b" world");
    }

    #[test]
    fn shift_start_left() {
        let pool = BufferPool::<Vec<u8>>::new(1024, "test");

        let mut buffer = pool.pull_initialised(b"hello world");

        let front = buffer.shift_start_left(5);
        front.copy_from_slice(b"12345");

        assert_eq!(&*buffer, b"12345hello world");
    }

    #[tokio::test]
    async fn buffer_pool_metrics() {
        let (provider, exporter) = init_meter_provider();
        let meter = provider.meter("connlib");

        let pool = BufferPool::<Vec<u8>>::with_meter(1024, "test", &meter);

        let buffer1 = pool.pull_initialised(b"hello world");
        let buffer2 = pool.pull_initialised(b"hello world");
        let buffer3 = pool.pull_initialised(b"hello world");

        tokio::time::sleep(Duration::from_millis(100)).await; // Wait for metrics to be exported.

        assert_eq!(get_num_buffers(&exporter), 3);

        drop(pool);
        drop(buffer1);
        drop(buffer2);
        drop(buffer3);

        tokio::time::sleep(Duration::from_millis(100)).await; // Wait for metrics to be exported.

        assert_eq!(get_num_buffers(&exporter), 0);
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

        sum.data_points().next().unwrap().value()
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
