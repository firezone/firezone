//! Per-buffer cost of pulling a buffer from the pool and returning it, within one thread and across threads.
//!
//! Each benchmark runs with three kinds of items:
//!
//! - `Pooled`: a buffer of the packet class.
//! - `Plain`: a value of the same size as a pooled buffer handle that costs nothing to create or drop.
//!   Across threads, this is the cost of the channel alone.
//! - `Alloc`: a freshly allocated `Vec` of the same capacity, i.e. no pooling at all.
//!
//! Items move in batches of `BATCH`, like packets do between connlib's threads.

#![allow(clippy::unwrap_used)]

use std::sync::mpsc as std_mpsc;
use std::thread;

use bufferpool::{Bytes, Class};
use divan::{Bencher, black_box, counter::ItemsCount};
use tokio::sync::mpsc::{self, error::TrySendError};

/// Same as the TUN channels on desktop platforms.
const CHANNEL_CAPACITY: usize = 100;

/// The number of items each benchmark iteration moves (in each direction).
const ITEMS_PER_ITER: usize = 1024;

const BATCHES: [usize; 2] = [1, 32];

#[derive(Debug, Clone, Copy)]
enum Item {
    Pooled,
    Plain,
    Alloc,
}

const ITEMS: [Item; 3] = [Item::Pooled, Item::Plain, Item::Alloc];

fn pooled() -> Bytes {
    Bytes::pull(Class::Packet)
}

fn plain() -> [u8; size_of::<Bytes>()] {
    black_box([0; size_of::<Bytes>()])
}

fn alloc() -> Vec<u8> {
    Vec::with_capacity(Class::Packet.size())
}

fn main() {
    // Grow the pool beyond what any benchmark holds at once, so pulling never allocates.
    let buffers = (0..4 * ITEMS_PER_ITER)
        .map(|_| Bytes::pull(Class::Packet))
        .collect::<Vec<_>>();
    drop(buffers);

    divan::main()
}

/// Creates `BATCH` items and drops them again on the same thread.
#[divan::bench(consts = BATCHES, args = ITEMS)]
fn single_thread<const BATCH: usize>(bencher: Bencher, item: Item) {
    match item {
        Item::Pooled => run_single_thread::<BATCH, _>(bencher, pooled),
        Item::Plain => run_single_thread::<BATCH, _>(bencher, plain),
        Item::Alloc => run_single_thread::<BATCH, _>(bencher, alloc),
    }
}

/// Creates items on this thread and drops them on another one.
#[divan::bench(consts = BATCHES, args = ITEMS)]
fn one_way<const BATCH: usize>(bencher: Bencher, item: Item) {
    match item {
        Item::Pooled => run_one_way::<BATCH, _>(bencher, pooled),
        Item::Plain => run_one_way::<BATCH, _>(bencher, plain),
        Item::Alloc => run_one_way::<BATCH, _>(bencher, alloc),
    }
}

/// Two threads each create items, send them to the other and drop what they receive.
#[divan::bench(consts = BATCHES, args = ITEMS)]
fn both_ways<const BATCH: usize>(bencher: Bencher, item: Item) {
    match item {
        Item::Pooled => run_both_ways::<BATCH, _>(bencher, pooled),
        Item::Plain => run_both_ways::<BATCH, _>(bencher, plain),
        Item::Alloc => run_both_ways::<BATCH, _>(bencher, alloc),
    }
}

fn run_single_thread<const BATCH: usize, T>(bencher: Bencher, make: fn() -> T) {
    bencher
        .counter(ItemsCount::new(BATCH))
        .bench_local(|| drop(black_box(std::array::from_fn::<_, BATCH, _>(|_| make()))));
}

enum Msg<M> {
    Items(M),
    Flush,
}

fn run_one_way<const BATCH: usize, T>(bencher: Bencher, make: fn() -> T)
where
    T: Send + 'static,
{
    let (tx, mut rx) = mpsc::channel::<Msg<[T; BATCH]>>(CHANNEL_CAPACITY);
    let (flushed_tx, flushed_rx) = std_mpsc::channel();

    let consumer = thread::spawn(move || {
        while let Some(msg) = rx.blocking_recv() {
            match msg {
                Msg::Items(items) => drop(items),
                Msg::Flush => flushed_tx.send(()).unwrap(),
            }
        }
    });

    bencher
        .counter(ItemsCount::new(ITEMS_PER_ITER))
        .bench_local(|| {
            for _ in 0..ITEMS_PER_ITER / BATCH {
                let items = std::array::from_fn(|_| make());

                tx.blocking_send(Msg::Items(items)).ok().unwrap();
            }

            tx.blocking_send(Msg::Flush).ok().unwrap();
            flushed_rx.recv().unwrap();
        });

    drop(tx);
    consumer.join().unwrap();
}

fn run_both_ways<const BATCH: usize, T>(bencher: Bencher, make: fn() -> T)
where
    T: Send + 'static,
{
    let (a_tx, mut b_rx) = mpsc::channel::<[T; BATCH]>(CHANNEL_CAPACITY);
    let (b_tx, mut a_rx) = mpsc::channel::<[T; BATCH]>(CHANNEL_CAPACITY);
    let (start_tx, start_rx) = std_mpsc::channel::<()>();
    let (done_tx, done_rx) = std_mpsc::channel::<()>();

    let other = thread::spawn(move || {
        for () in start_rx {
            exchange(&b_tx, &mut b_rx, make);
            done_tx.send(()).unwrap();
        }
    });

    bencher
        .counter(ItemsCount::new(2 * ITEMS_PER_ITER))
        .bench_local(|| {
            start_tx.send(()).unwrap();
            exchange(&a_tx, &mut a_rx, make);
            done_rx.recv().unwrap();
        });

    drop(start_tx);
    other.join().unwrap();
}

/// Sends [`ITEMS_PER_ITER`] items while dropping the ones that arrive, until as many arrived.
///
/// Never blocks on a full channel, as both threads send at the same time.
fn exchange<const BATCH: usize, T>(
    tx: &mpsc::Sender<[T; BATCH]>,
    rx: &mut mpsc::Receiver<[T; BATCH]>,
    make: fn() -> T,
) {
    let batches = ITEMS_PER_ITER / BATCH;
    let mut sent = 0;
    let mut received = 0;
    let mut pending = None;

    while sent < batches || received < batches {
        if sent < batches {
            let items = pending
                .take()
                .unwrap_or_else(|| std::array::from_fn(|_| make()));

            match tx.try_send(items) {
                Ok(()) => sent += 1,
                Err(TrySendError::Full(items)) => pending = Some(items),
                Err(TrySendError::Closed(_)) => panic!("channel closed"),
            }
        }

        while let Ok(items) = rx.try_recv() {
            drop(items);
            received += 1;
        }
    }
}
