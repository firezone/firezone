#![cfg_attr(test, allow(clippy::unwrap_used))]

use std::{
    ops::{Deref, DerefMut},
    sync::Arc,
};

use bytes::BytesMut;
use opentelemetry::{KeyValue, metrics::UpDownCounter};

#[derive(Clone)]
pub struct BufferPool<B> {
    inner: Arc<lockfree_object_pool::MutexObjectPool<BufferStorage<B>>>,
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
            .init();

        Self {
            inner: Arc::new(lockfree_object_pool::MutexObjectPool::new(
                move || {
                    BufferStorage::new(
                        B::with_capacity(capacity),
                        buffer_counter.clone(),
                        [
                            KeyValue::new("system.buffer.pool.name", tag),
                            KeyValue::new("system.buffer.pool.buffer_size", capacity as i64),
                        ],
                    )
                },
                |_| {},
            )),
        }
    }

    pub fn pull(&self) -> Buffer<B> {
        Buffer {
            inner: self.inner.pull_owned(),
            pool: self.inner.clone(),
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
    inner: lockfree_object_pool::MutexOwnedReusable<BufferStorage<B>>,
    pool: Arc<lockfree_object_pool::MutexObjectPool<BufferStorage<B>>>,
}

impl Buffer<Vec<u8>> {
    /// Truncates N bytes from the front of the buffer.
    pub fn truncate_front(&mut self, num: usize) {
        let current_len = self.len();

        self.copy_within(num.., 0);
        self.truncate(current_len - num);
    }

    /// Moves the buffer back by N bytes, returning the new space at the front of the buffer.
    pub fn move_back(&mut self, num: usize) -> &mut [u8] {
        let current_len = self.len();

        self.resize(current_len + num, 0);
        self.copy_within(..current_len, num);

        &mut self[..num]
    }
}

impl<B> Clone for Buffer<B>
where
    B: Buf,
{
    fn clone(&self) -> Self {
        let mut copy = self.pool.pull_owned();

        self.inner.inner.clone(&mut copy);

        Self {
            inner: copy,
            pool: self.pool.clone(),
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
        self.inner.deref()
    }
}

impl<B> DerefMut for Buffer<B> {
    fn deref_mut(&mut self) -> &mut Self::Target {
        self.inner.deref_mut()
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
    use opentelemetry_sdk::{
        metrics::{PeriodicReader, SdkMeterProvider, data::Sum},
        testing::metrics::InMemoryMetricsExporter,
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

    #[tokio::test]
    async fn buffer_pool_metrics() {
        let (_provider, exporter) = init_meter_provider();

        let pool = BufferPool::<Vec<u8>>::new(1024, "test");

        let buffer1 = pool.pull_initialised(b"hello world");
        let buffer2 = pool.pull_initialised(b"hello world");
        let buffer3 = pool.pull_initialised(b"hello world");

        tokio::time::sleep(Duration::from_millis(10)).await; // Wait for metrics to be exported.

        assert_eq!(get_num_buffers(&exporter), 3);

        drop(pool);
        drop(buffer1);
        drop(buffer2);
        drop(buffer3);

        tokio::time::sleep(Duration::from_millis(10)).await; // Wait for metrics to be exported.

        assert_eq!(get_num_buffers(&exporter), 0);
    }

    fn get_num_buffers(exporter: &InMemoryMetricsExporter) -> i64 {
        let metrics = exporter.get_finished_metrics().unwrap();

        let metric = &metrics.iter().last().unwrap().scope_metrics[0].metrics[0];
        let sum = metric.data.as_any().downcast_ref::<Sum<i64>>().unwrap();

        sum.data_points[0].value
    }

    fn init_meter_provider() -> (SdkMeterProvider, InMemoryMetricsExporter) {
        let exporter = InMemoryMetricsExporter::default();

        let provider = SdkMeterProvider::builder()
            .with_reader(
                PeriodicReader::builder(exporter.clone(), opentelemetry_sdk::runtime::Tokio)
                    .with_interval(Duration::from_millis(1))
                    .build(),
            )
            .build();
        global::set_meter_provider(provider.clone());

        (provider, exporter)
    }
}
