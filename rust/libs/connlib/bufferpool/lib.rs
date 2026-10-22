//! Process-wide pools of byte buffers, one per size [`Class`].
//!
//! Internally, each class is a magazine allocator as described by Bonwick and Adams in
//! ["Magazines and Vmem"](https://www.usenix.org/legacy/event/usenix01/full_papers/bonwick/bonwick.pdf):
//! buffers move in batches whose size each class chooses. Each thread pulls and drops buffers
//! through its own magazine of two batches and only locks the class's depot to trade a whole
//! batch, an empty one for a full one or the other way around.

#![cfg_attr(test, allow(clippy::unwrap_used))]

use std::{
    cell::RefCell,
    ops::{Deref, DerefMut},
    sync::{Mutex, MutexGuard, OnceLock, PoisonError},
};

use opentelemetry::{KeyValue, metrics::UpDownCounter};

/// A pooled byte buffer; its capacity picks the pool it returns to when dropped.
#[derive(PartialEq, Eq, PartialOrd, Ord)]
pub struct Bytes(Vec<u8>);

/// The sizes buffers come in; a buffer's capacity identifies its class.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Class {
    /// An IP packet of at most 1280 bytes plus 32 bytes of WireGuard and 4 bytes of TURN channel data overhead.
    Packet,
    K2,
    K4,
    K8,
    K16,
    K32,
    K64,
    /// 64 [`Class::Packet`]s coalesced into one datagram by GRO / URO.
    Gro,
}

const NUM_CLASSES: usize = Class::ALL.len();

static DEPOTS: [Mutex<Depot>; NUM_CLASSES] = [const { Mutex::new(Depot::new()) }; NUM_CLASSES];

thread_local!(static MAGAZINES: RefCell<Magazines> = const { RefCell::new(Magazines::new()) });

impl Class {
    const ALL: [Class; 8] = [
        Class::Packet,
        Class::K2,
        Class::K4,
        Class::K8,
        Class::K16,
        Class::K32,
        Class::K64,
        Class::Gro,
    ];

    /// The capacity of the class's buffers.
    const fn size(self) -> usize {
        match self {
            Class::Packet => 1280 + 32 + 4,
            Class::K2 => 2 * 1024,
            Class::K4 => 4 * 1024,
            Class::K8 => 8 * 1024,
            Class::K16 => 16 * 1024,
            Class::K32 => 32 * 1024,
            Class::K64 => 64 * 1024,
            Class::Gro => 64 * Class::Packet.size(),
        }
    }

    /// How many buffers move between a thread's magazine and the depot at once.
    ///
    /// Each thread can hold up to two batches idle, so it trades fewer locks against more memory:
    /// matched to how many buffers are pulled together, and kept small for large buffers.
    const fn batch(self) -> usize {
        match self {
            Class::Packet => 64,
            Class::K2 => 2,
            Class::K4 => 2,
            Class::K8 => 2,
            Class::K16 => 2,
            Class::K32 => 2,
            Class::K64 => 2,
            Class::Gro => cfg_select! {
                target_os = "android" => { 2 }
                target_os = "windows" => { 1 }
                _ => { 16 }
            },
        }
    }

    /// The smallest class whose buffers hold `len` bytes.
    fn fitting(len: usize) -> Option<Self> {
        Self::ALL.into_iter().find(|class| class.size() >= len)
    }

    fn of_capacity(capacity: usize) -> Option<Self> {
        Self::fitting(capacity).filter(|class| class.size() == capacity)
    }
}

impl Bytes {
    fn pull(class: Class) -> Self {
        let buffer = MAGAZINES
            .try_with(|magazines| magazines.borrow_mut().pop(class))
            .unwrap_or_else(|_| depot(class).pop());

        Self(buffer.unwrap_or_else(|| allocate(class.size())))
    }

    /// Pulls a buffer of the smallest size class holding `len` bytes, at its full length.
    ///
    /// Beyond the largest class, the buffer is allocated for this call alone.
    pub fn fitting(len: usize) -> Self {
        match Class::fitting(len) {
            Some(class) => Self::pull(class),
            None => Self(allocate(len)),
        }
    }

    /// Pulls a buffer holding a copy of `data`, and nothing else.
    pub fn copied_from(data: &[u8]) -> Self {
        let mut buffer = Self::fitting(data.len());

        buffer.0.truncate(data.len());
        buffer.0.copy_from_slice(data);

        buffer
    }

    /// Shortens the buffer to `len` bytes.
    pub fn truncate(&mut self, len: usize) {
        self.0.truncate(len);
    }

    /// Appends `data`, which must fit in the buffer's capacity so that the buffer never reallocates.
    pub fn extend_from_slice(&mut self, data: &[u8]) {
        assert!(
            self.0.len() + data.len() <= self.0.capacity(),
            "{} bytes do not fit in a buffer of {} bytes holding {}",
            data.len(),
            self.0.capacity(),
            self.0.len()
        );

        self.0.extend_from_slice(data);
    }

    /// Shifts the start of the buffer to the right by N bytes, dropping the bytes at the front.
    pub fn shift_start_right(&mut self, num: usize) {
        self.0.drain(..num);
    }

    /// Shifts the start of the buffer to the left by N bytes, returning a slice to the added bytes at the front of the buffer.
    pub fn shift_start_left(&mut self, num: usize) -> &mut [u8] {
        let current_len = self.0.len();

        self.0.resize(current_len + num, 0);
        self.0.copy_within(..current_len, num);

        &mut self.0[..num]
    }
}

impl Clone for Bytes {
    fn clone(&self) -> Self {
        Self::copied_from(&self.0)
    }
}

impl Deref for Bytes {
    type Target = [u8];

    fn deref(&self) -> &[u8] {
        &self.0
    }
}

impl DerefMut for Bytes {
    fn deref_mut(&mut self) -> &mut [u8] {
        &mut self.0
    }
}

impl Drop for Bytes {
    fn drop(&mut self) {
        let mut buffer = std::mem::take(&mut self.0);
        let capacity = buffer.capacity();

        let Some(class) = Class::of_capacity(capacity) else {
            count(-1, capacity);

            return;
        };

        buffer.resize(capacity, 0);

        let mut buffer = Some(buffer);

        let _ = MAGAZINES.try_with(|magazines| {
            if let Some(buffer) = buffer.take() {
                magazines.borrow_mut().push(class, buffer);
            }
        });

        if let Some(buffer) = buffer {
            depot(class).full.push(Batch {
                buffers: vec![buffer],
            });
        }
    }
}

fn allocate(capacity: usize) -> Vec<u8> {
    count(1, capacity);

    vec![0; capacity]
}

/// Records a change in the number of allocated buffers of `capacity` bytes.
fn count(delta: i64, capacity: usize) {
    static COUNTER: OnceLock<UpDownCounter<i64>> = OnceLock::new();

    COUNTER
        .get_or_init(|| {
            cfg_select! {
                test => { tests::counter() }
                _ => { otel_instruments::buffer_count() }
            }
        })
        .add(
            delta,
            &[KeyValue::new(
                "system.buffer.pool.buffer_size",
                capacity as i64,
            )],
        );
}

fn depot(class: Class) -> MutexGuard<'static, Depot> {
    DEPOTS[class as usize]
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
}

// A magazine's slow path: `#[cold]` keeps it from bloating the inlined pull and drop.
#[cold]
fn trade_empty(class: Class, empty: Batch) -> Result<Batch, Batch> {
    depot(class).trade_empty(empty)
}

#[cold]
fn trade_full(class: Class, full: Batch) -> Batch {
    depot(class).trade_full(full, class.batch())
}

/// A thread's magazines, one per class.
///
/// Buffers still in them when the thread exits are handed back to the depots.
struct Magazines([Magazine; NUM_CLASSES]);

impl Magazines {
    const fn new() -> Self {
        Self([const { Magazine::new() }; NUM_CLASSES])
    }

    fn pop(&mut self, class: Class) -> Option<Vec<u8>> {
        self.0[class as usize].pop(class)
    }

    fn push(&mut self, class: Class, buffer: Vec<u8>) {
        self.0[class as usize].push(class, buffer);
    }
}

impl Drop for Magazines {
    fn drop(&mut self) {
        for (class, magazine) in Class::ALL.into_iter().zip(&mut self.0) {
            for batch in [
                std::mem::take(&mut magazine.loaded),
                std::mem::take(&mut magazine.spare),
            ] {
                if !batch.is_empty() {
                    depot(class).full.push(batch);
                }
            }
        }
    }
}

/// A thread's buffers of one class: pulls and drops use `loaded`, `spare` is a full or
/// empty batch on standby.
struct Magazine {
    loaded: Batch,
    spare: Batch,
}

impl Magazine {
    const fn new() -> Self {
        Self {
            loaded: Batch::new(),
            spare: Batch::new(),
        }
    }

    fn pop(&mut self, class: Class) -> Option<Vec<u8>> {
        if self.loaded.is_empty() {
            if self.spare.is_empty() {
                let (Ok(batch) | Err(batch)) = trade_empty(class, std::mem::take(&mut self.loaded));

                self.loaded = batch;
            } else {
                std::mem::swap(&mut self.loaded, &mut self.spare);
            }
        }

        self.loaded.pop()
    }

    fn push(&mut self, class: Class, buffer: Vec<u8>) {
        if self.loaded.len() >= class.batch() {
            if self.spare.len() >= class.batch() {
                self.spare = trade_full(class, std::mem::take(&mut self.spare));
            }

            std::mem::swap(&mut self.loaded, &mut self.spare);
        }

        self.loaded.push(buffer);
    }
}

/// Up to a class's batch size of buffers; empty batches keep their allocation for reuse.
struct Batch {
    buffers: Vec<Vec<u8>>,
}

impl Batch {
    const fn new() -> Self {
        Self {
            buffers: Vec::new(),
        }
    }

    fn pop(&mut self) -> Option<Vec<u8>> {
        self.buffers.pop()
    }

    fn push(&mut self, buffer: Vec<u8>) {
        self.buffers.push(buffer);
    }

    fn len(&self) -> usize {
        self.buffers.len()
    }

    fn is_empty(&self) -> bool {
        self.buffers.is_empty()
    }
}

impl Default for Batch {
    fn default() -> Self {
        Self::new()
    }
}

/// A class's shared stock behind the mutex: full batches to take, empty ones to fill.
struct Depot {
    full: Vec<Batch>,
    empty: Vec<Batch>,
}

impl Depot {
    const fn new() -> Self {
        Self {
            full: Vec::new(),
            empty: Vec::new(),
        }
    }

    /// Gives back an empty batch, takes a full one (if there is any).
    fn trade_empty(&mut self, empty: Batch) -> Result<Batch, Batch> {
        let Some(full) = self.full.pop() else {
            return Err(empty);
        };

        if empty.buffers.capacity() > 0 {
            self.empty.push(empty);
        }

        Ok(full)
    }

    /// Gives back a full batch, takes an empty one (allocating only if there is none).
    fn trade_full(&mut self, full: Batch, batch: usize) -> Batch {
        self.full.push(full);

        self.empty.pop().unwrap_or_else(|| Batch {
            buffers: Vec::with_capacity(batch),
        })
    }

    /// Takes a single buffer, for a thread without a magazine.
    fn pop(&mut self) -> Option<Vec<u8>> {
        let batch = self.full.last_mut()?;
        let buffer = batch.pop();

        if batch.is_empty() {
            self.full.pop();
        }

        buffer
    }
}

#[cfg(test)]
mod tests {
    use std::{collections::HashSet, sync::LazyLock, time::Duration};

    use opentelemetry::{Value, metrics::MeterProvider};
    use opentelemetry_sdk::metrics::{
        InMemoryMetricExporter, PeriodicReader, SdkMeterProvider,
        data::{AggregatedMetrics, MetricData},
    };

    use super::*;

    /// The class the tests that observe depots, magazines or the buffer count have to themselves.
    const CLASS: Class = Class::K32;
    const BATCH_SIZE: usize = CLASS.batch();

    #[test]
    fn buffer_can_be_cloned() {
        let buffer = Bytes::copied_from(b"hello world");

        #[allow(clippy::redundant_clone)]
        let buffer2 = buffer.clone();

        assert_eq!(&buffer2[..], &buffer[..]);
    }

    #[test]
    fn cloned_buffer_owns_its_own_memory() {
        let buffer = Bytes::copied_from(b"hello world");

        let buffer2 = buffer.clone();
        drop(buffer);

        assert_eq!(&buffer2[..11], b"hello world");
    }

    #[test]
    fn copied_buffer_is_only_as_long_as_content() {
        let buffer = Bytes::copied_from(b"hello world");

        assert_eq!(buffer.len(), 11);
    }

    #[test]
    fn fitting_takes_the_smallest_class() {
        for (len, capacity) in [
            (1, Class::Packet.size()),
            (Class::Packet.size(), Class::Packet.size()),
            (Class::Packet.size() + 1, 2 * 1024),
            (2 * 1024 + 1, 4 * 1024),
            (32 * 1024 + 1, 64 * 1024),
            (64 * 1024 + 1, Class::Gro.size()),
            (Class::Gro.size() + 1, Class::Gro.size() + 1),
        ] {
            assert_eq!(Bytes::fitting(len).0.capacity(), capacity);
        }
    }

    #[test]
    fn pulled_buffer_has_full_length() {
        let _exclusive = exclusive(CLASS);

        let mut buffer = Bytes::pull(CLASS);
        buffer.truncate(8);
        drop(buffer);

        assert_eq!(Bytes::pull(CLASS).len(), CLASS.size());
    }

    #[test]
    fn returning_a_reallocated_buffer_discards_it() {
        let _exclusive = exclusive(CLASS);

        let mut buffer = Bytes::pull(CLASS);
        buffer.0.resize(2 * CLASS.size() + 1, 0); // Force a reallocation to a capacity that is no class.
        drop(buffer);

        assert_eq!(Bytes::pull(CLASS).0.capacity(), CLASS.size());
    }

    #[test]
    fn discarded_buffer_is_subtracted_from_buffer_count() {
        let _exclusive = exclusive(CLASS);
        let grown = 2 * CLASS.size() + 1; // A capacity that is no class.
        let before = num_buffers(&[CLASS.size(), grown]);

        let mut buffer = Bytes::pull(CLASS);
        buffer.0.resize(grown, 0);
        drop(buffer);

        assert_eq!(num_buffers(&[CLASS.size(), grown]), before);
    }

    #[test]
    fn buffer_count_includes_pooled_buffers() {
        let _exclusive = exclusive(CLASS);
        let before = num_buffers(&[CLASS.size()]);

        let buffers = (0..3).map(|_| Bytes::pull(CLASS)).collect::<Vec<_>>();
        drop(buffers);
        let _buffers = (0..3).map(|_| Bytes::pull(CLASS)).collect::<Vec<_>>();

        assert_eq!(num_buffers(&[CLASS.size()]), before + 3);
    }

    /// The whole point of pooling is passing buffers around cheaply: a handle is the buffer itself.
    #[cfg(target_pointer_width = "64")]
    #[test]
    fn handles_are_slim() {
        assert_eq!(size_of::<Bytes>(), 24);
    }

    #[test]
    fn pool_recycles_buffers() {
        let _exclusive = exclusive(CLASS);

        let buffer = Bytes::pull(CLASS);
        let storage = buffer.as_ptr();
        drop(buffer);

        assert_eq!(Bytes::pull(CLASS).as_ptr(), storage);
    }

    #[test]
    fn full_magazine_hands_a_batch_to_the_pool() {
        let _exclusive = exclusive(CLASS);

        let buffers = (0..2 * BATCH_SIZE + 1)
            .map(|_| Bytes::pull(CLASS))
            .collect::<Vec<_>>();
        drop(buffers);

        assert_eq!(depot(CLASS).full.len(), 1);
        assert_eq!(depot_len(CLASS), BATCH_SIZE);
        assert_eq!(magazine_len(CLASS), BATCH_SIZE + 1);
    }

    #[test]
    fn empty_magazine_refills_from_the_pool() {
        let _exclusive = exclusive(CLASS);

        let buffers = (0..2 * BATCH_SIZE + 1)
            .map(|_| Bytes::pull(CLASS))
            .collect::<Vec<_>>();
        drop(buffers);

        let _buffers = (0..BATCH_SIZE + 2)
            .map(|_| Bytes::pull(CLASS))
            .collect::<Vec<_>>();

        assert_eq!(depot_len(CLASS), 0);
        assert_eq!(magazine_len(CLASS), BATCH_SIZE - 1);
    }

    #[test]
    fn buffers_dropped_on_another_thread_are_reused() {
        let _exclusive = exclusive(CLASS);

        let buffers = (0..4 * BATCH_SIZE)
            .map(|_| Bytes::pull(CLASS))
            .collect::<Vec<_>>();
        let storage = buffers.iter().map(|b| b.as_ptr()).collect::<HashSet<_>>();
        std::thread::spawn(move || drop(buffers)).join().unwrap();

        let reused = (0..4 * BATCH_SIZE)
            .map(|_| Bytes::pull(CLASS))
            .collect::<Vec<_>>();

        assert_eq!(
            reused.iter().map(|b| b.as_ptr()).collect::<HashSet<_>>(),
            storage
        );
    }

    #[test]
    fn exiting_thread_hands_its_magazine_to_the_pool() {
        let _exclusive = exclusive(CLASS);

        std::thread::spawn(|| {
            let buffers = (0..3).map(|_| Bytes::pull(CLASS)).collect::<Vec<_>>();
            drop(buffers);
        })
        .join()
        .unwrap();

        assert_eq!(depot_len(CLASS), 3);
    }

    #[test]
    fn buffer_dropped_after_the_magazine_returns_to_the_pool() {
        thread_local!(static HOLDER: RefCell<Option<Bytes>> = const { RefCell::new(None) });

        let _exclusive = exclusive(CLASS);

        std::thread::spawn(|| {
            // Initialise the holder before the magazine so it is likely destroyed after it.
            HOLDER.with(|_| {});
            let buffer = Bytes::pull(CLASS);
            HOLDER.with(|h| *h.borrow_mut() = Some(buffer));
        })
        .join()
        .unwrap();

        assert_eq!(depot_len(CLASS), 1);
    }

    #[test]
    fn shift_start_right() {
        let mut buffer = Bytes::copied_from(b"hello world");

        buffer.shift_start_right(5);

        assert_eq!(&*buffer, b" world");
    }

    #[test]
    fn shift_start_left() {
        let mut buffer = Bytes::copied_from(b"hello world");

        let front = buffer.shift_start_left(5);
        front.copy_from_slice(b"12345");

        assert_eq!(&*buffer, b"12345hello world");
    }

    /// Serialises the tests on `class` and empties its depot and this thread's magazine before and after each.
    fn exclusive(class: Class) -> impl Drop {
        struct Exclusive {
            class: Class,
            _guard: MutexGuard<'static, ()>,
        }

        impl Drop for Exclusive {
            fn drop(&mut self) {
                reset(self.class);
            }
        }

        static LOCK: Mutex<()> = Mutex::new(());

        let _guard = LOCK.lock().unwrap_or_else(PoisonError::into_inner);
        reset(class);

        Exclusive { class, _guard }
    }

    fn reset(class: Class) {
        MAGAZINES.with(|magazines| magazines.borrow_mut().0[class as usize] = Magazine::new());
        depot(class).full.clear();
    }

    /// The number of buffers in this thread's magazine of `class`.
    fn magazine_len(class: Class) -> usize {
        MAGAZINES.with(|magazines| {
            let magazine = &magazines.borrow().0[class as usize];

            magazine.loaded.len() + magazine.spare.len()
        })
    }

    /// The number of buffers in the depot of `class`.
    fn depot_len(class: Class) -> usize {
        depot(class).full.iter().map(Batch::len).sum()
    }

    /// The number of allocated buffers of the given sizes the metrics report.
    fn num_buffers(sizes: &[usize]) -> i64 {
        std::thread::sleep(Duration::from_millis(100)); // Wait for metrics to be exported.

        let metrics = METRICS.1.get_finished_metrics().unwrap();

        let Some(metric) = metrics
            .iter()
            .last()
            .and_then(|m| m.scope_metrics().next())
            .and_then(|m| m.metrics().next())
        else {
            return 0;
        };
        let AggregatedMetrics::I64(MetricData::Sum(sum)) = metric.data() else {
            panic!("Not an i64 sum");
        };

        sum.data_points()
            .filter(|point| {
                point.attributes().any(|kv| {
                    sizes
                        .iter()
                        .any(|size| kv.value == Value::I64(*size as i64))
                })
            })
            .map(|point| point.value())
            .sum()
    }

    pub(super) fn counter() -> UpDownCounter<i64> {
        otel_instruments::buffer_count_with(&METRICS.0.meter("bufferpool"))
    }

    static METRICS: LazyLock<(SdkMeterProvider, InMemoryMetricExporter)> = LazyLock::new(|| {
        let exporter = InMemoryMetricExporter::default();

        let provider = SdkMeterProvider::builder()
            .with_reader(
                PeriodicReader::builder(exporter.clone())
                    .with_interval(Duration::from_millis(1))
                    .build(),
            )
            .build();

        (provider, exporter)
    });
}
