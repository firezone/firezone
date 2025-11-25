#![cfg_attr(test, allow(clippy::unwrap_used))]

use std::{
    ops::{Deref, DerefMut},
    sync::Arc,
};

use bytes::BytesMut;
use crossbeam_queue::SegQueue;
use opentelemetry::{KeyValue, metrics::UpDownCounter};

/// A lock-free pool of buffers that are all equal in size.
///
/// The buffers are stored in a queue ([`SegQueue`]) and taken from the front and push to the back.
/// This minimizes contention even under high load where buffers are constantly needed and returned.
pub struct BufferPool<B> {
    inner: Arc<SegQueue<BufferStorage<B>>>,

    new_buffer_fn: Arc<dyn Fn() -> BufferStorage<B> + Send + Sync>,
}

impl<B> Clone for BufferPool<B> {
    fn clone(&self) -> Self {
        Self {
            inner: self.inner.clone(),
            new_buffer_fn: self.new_buffer_fn.clone(),
        }
    }
}

impl<B> BufferPool<B>
where
    B: Buf,
{
    pub fn new(capacity: usize, tag: &'static str) -> Self {
        let buffer_counter = opentelemetry::global::meter("connlib")
            .i64_up_down_counter("system.buffer.count")
            .with_description("The number of buffers allocated in the pool.")
            .with_unit("{buffers}")
            .build();

        Self {
            inner: Arc::new(SegQueue::new()),

            // TODO: It would be nice to eventually create a fixed amount of buffers upfront.
            // This however means that getting a buffer can fail which would require us to implement back-pressure.
            new_buffer_fn: Arc::new(move || {
                BufferStorage::new(
                    B::with_capacity(capacity),
                    buffer_counter.clone(),
                    [
                        KeyValue::new("system.buffer.pool.name", tag),
                        KeyValue::new("system.buffer.pool.buffer_size", capacity as i64),
                    ],
                )
            }),
        }
    }

    pub fn pull(&self) -> Buffer<B> {
        Buffer {
            inner: Some(self.inner.pop().unwrap_or_else(|| (self.new_buffer_fn)())),
            pool: self.inner.clone(),
            new_buffer_fn: self.new_buffer_fn.clone(),
        }
    }
}

impl<B> BufferPool<B>
where
    B: Buf + DerefMut<Target = [u8]>,
{
    pub fn pull_initialised(&self, data: &[u8]) -> Buffer<B> {
        let mut buffer = self.pull();
        let len = data.len();

        buffer.resize_to(len);
        buffer.copy_from_slice(data);

        buffer
    }
}

pub struct Buffer<B> {
    inner: Option<BufferStorage<B>>,

    pool: Arc<SegQueue<BufferStorage<B>>>,
    new_buffer_fn: Arc<dyn Fn() -> BufferStorage<B> + Send + Sync>,
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

impl<B> Buffer<B> {
    fn storage(&self) -> &BufferStorage<B> {
        self.inner
            .as_ref()
            .expect("should always have buffer storage until dropped")
    }

    fn storage_mut(&mut self) -> &mut BufferStorage<B> {
        self.inner
            .as_mut()
            .expect("should always have buffer storage until dropped")
    }
}

impl<B> Clone for Buffer<B>
where
    B: Buf,
{
    fn clone(&self) -> Self {
        let mut copy = self.pool.pop().unwrap_or_else(|| (self.new_buffer_fn)());

        self.storage().inner.clone(&mut copy);

        Self {
            inner: Some(copy),
            pool: self.pool.clone(),
            new_buffer_fn: self.new_buffer_fn.clone(),
        }
    }
}

impl<B> PartialEq for Buffer<B>
where
    B: Deref<Target = [u8]>,
{
    fn eq(&self, other: &Self) -> bool {
        self.as_ref() == other.as_ref()
    }
}

impl<B> Eq for Buffer<B> where B: Deref<Target = [u8]> {}

impl<B> PartialOrd for Buffer<B>
where
    B: Deref<Target = [u8]>,
{
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        Some(self.cmp(other))
    }
}

impl<B> Ord for Buffer<B>
where
    B: Deref<Target = [u8]>,
{
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        self.as_ref().cmp(other.as_ref())
    }
}

impl<B> std::fmt::Debug for Buffer<B> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_tuple("Buffer").finish()
    }
}

impl<B> Deref for Buffer<B> {
    type Target = B;

    fn deref(&self) -> &Self::Target {
        self.storage().deref()
    }
}

impl<B> DerefMut for Buffer<B> {
    fn deref_mut(&mut self) -> &mut Self::Target {
        self.storage_mut().deref_mut()
    }
}

impl<B> Drop for Buffer<B> {
    fn drop(&mut self) {
        let buffer_storage = self.inner.take().expect("should have storage in `Drop`");

        self.pool.push(buffer_storage);
    }
}

pub trait Buf: Sized {
    fn with_capacity(capacity: usize) -> Self;
    fn clone(&self, dst: &mut Self);
    fn resize_to(&mut self, len: usize);
}

impl Buf for Vec<u8> {
    fn with_capacity(capacity: usize) -> Self {
        vec![0; capacity]
    }

    fn clone(&self, dst: &mut Self) {
        dst.resize(self.len(), 0);
        dst.copy_from_slice(self);
    }

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

    fn resize_to(&mut self, len: usize) {
        self.resize(len, 0);
    }
}

/// A wrapper around a buffer `B` that keeps track of how many buffers there are in a counter.
struct BufferStorage<B> {
    inner: B,

    attributes: [KeyValue; 2],
    counter: UpDownCounter<i64>,
}

impl<B> Drop for BufferStorage<B> {
    fn drop(&mut self) {
        self.counter.add(-1, &self.attributes);
    }
}

impl<B> BufferStorage<B> {
    fn new(inner: B, counter: UpDownCounter<i64>, attributes: [KeyValue; 2]) -> Self {
        counter.add(1, &attributes);

        Self {
            inner,
            counter,
            attributes,
        }
    }
}

impl<B> Deref for BufferStorage<B> {
    type Target = B;

    fn deref(&self) -> &Self::Target {
        &self.inner
    }
}

impl<B> DerefMut for BufferStorage<B> {
    fn deref_mut(&mut self) -> &mut Self::Target {
        &mut self.inner
    }
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use opentelemetry::global;
    use opentelemetry_sdk::metrics::{
        InMemoryMetricExporter, PeriodicReader, SdkMeterProvider,
        data::{AggregatedMetrics, MetricData},
    };

    use super::*;

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
        let (_provider, exporter) = init_meter_provider();

        let pool = BufferPool::<Vec<u8>>::new(1024, "test");

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
        global::set_meter_provider(provider.clone());

        (provider, exporter)
    }
}
