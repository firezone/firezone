//! Micro measurements of the cross-thread costs connlib's main thread pays per batch.
#![allow(clippy::unwrap_used, clippy::print_stdout)]

use std::{
    hint::black_box,
    sync::{Arc, Barrier},
    time::{Duration, Instant},
};

const ITERS: usize = 20_000;
const PACKET: usize = 1280;
const BATCH: usize = 100;

fn main() {
    pin_to_cpu(0);

    wake_parked_receiver();
    copy_from_other_core();
    otel_noop_counter();
}

/// Sending to a receiver that is parked costs a wake-up (futex) on the sending thread.
fn wake_parked_receiver() {
    let (tx, rx) = crossbeam_channel::unbounded::<u64>();
    let (done_tx, done_rx) = crossbeam_channel::unbounded::<()>();
    std::thread::spawn(move || {
        pin_to_cpu(1);
        for _ in rx {
            done_tx.send(()).unwrap();
        }
    });

    let mut send = Duration::ZERO;
    for i in 0..ITERS {
        std::thread::sleep(Duration::from_micros(200)); // Let the receiver park.
        let start = Instant::now();
        tx.send(i as u64).unwrap();
        send += start.elapsed();
        done_rx.recv().unwrap();
    }
    println!(
        "crossbeam send to a parked receiver:      {:7.0} ns/send",
        send.as_nanos() as f64 / ITERS as f64
    );

    let (tx, mut rx) = tokio::sync::mpsc::channel::<u64>(8);
    let (done_tx, done_rx) = crossbeam_channel::unbounded::<()>();
    std::thread::spawn(move || {
        pin_to_cpu(1);
        while rx.blocking_recv().is_some() {
            done_tx.send(()).unwrap();
        }
    });

    let mut send = Duration::ZERO;
    for i in 0..ITERS {
        std::thread::sleep(Duration::from_micros(200));
        let start = Instant::now();
        tx.try_send(i as u64).unwrap();
        send += start.elapsed();
        done_rx.recv().unwrap();
    }
    println!(
        "tokio mpsc try_send to a parked receiver: {:7.0} ns/send",
        send.as_nanos() as f64 / ITERS as f64
    );

    let (tx, rx) = crossbeam_channel::unbounded::<u64>();
    let mut send = Duration::ZERO;
    for i in 0..ITERS {
        let start = Instant::now();
        tx.send(i as u64).unwrap();
        send += start.elapsed();
        rx.recv().unwrap();
    }
    println!(
        "crossbeam send, nobody parked:            {:7.0} ns/send",
        send.as_nanos() as f64 / ITERS as f64
    );
}

/// Copies a batch of packets that the previous owner wrote on this or another core.
fn copy_from_other_core() {
    let make = || (0..BATCH).map(|_| vec![0u8; PACKET]).collect::<Vec<_>>();

    let mut batch = make();
    let mut dst = vec![0u8; PACKET];
    let mut same = Duration::ZERO;
    for i in 0..ITERS / 10 {
        for b in &mut batch {
            b.fill(i as u8);
        }
        let start = Instant::now();
        for b in &batch {
            dst.copy_from_slice(b);
            black_box(&dst);
        }
        same += start.elapsed();
    }

    let (to_writer, writer_rx) = crossbeam_channel::bounded::<Vec<Vec<u8>>>(1);
    let (to_main, main_rx) = crossbeam_channel::bounded::<Vec<Vec<u8>>>(1);
    std::thread::spawn(move || {
        pin_to_cpu(1);
        for (i, mut batch) in writer_rx.into_iter().enumerate() {
            for b in &mut batch {
                b.fill(i as u8);
            }
            to_main.send(batch).unwrap();
        }
    });
    let barrier = Arc::new(Barrier::new(1));
    let mut other = Duration::ZERO;
    let mut batch = make();
    for _ in 0..ITERS / 10 {
        to_writer.send(batch).unwrap();
        batch = main_rx.recv().unwrap();
        barrier.wait();
        let start = Instant::now();
        for b in &batch {
            dst.copy_from_slice(b);
            black_box(&dst);
        }
        other += start.elapsed();
    }

    let per = |d: Duration| d.as_nanos() as f64 / (ITERS / 10 * BATCH) as f64;
    println!(
        "copy {PACKET} B written on this core:        {:7.1} ns/packet",
        per(same)
    );
    println!(
        "copy {PACKET} B written on another core:     {:7.1} ns/packet",
        per(other)
    );
}

/// What a packet counter costs without a meter provider, as in our measurements.
fn otel_noop_counter() {
    let counter = opentelemetry::global::meter("micro").u64_counter("packets").build();
    let start = Instant::now();
    for _ in 0..ITERS * 100 {
        counter.add(
            1,
            &[
                opentelemetry::KeyValue::new("network.protocol.name", "wireguard"),
                opentelemetry::KeyValue::new("network.transport", "udp"),
                opentelemetry::KeyValue::new("network.io.direction", "receive"),
            ],
        );
    }
    println!(
        "noop otel counter.add with 3 attributes:  {:7.1} ns/call",
        start.elapsed().as_nanos() as f64 / (ITERS * 100) as f64
    );
}

fn pin_to_cpu(cpu: usize) {
    // SAFETY: `set` is a valid, zeroed `cpu_set_t` that outlives the call.
    unsafe {
        let mut set = std::mem::zeroed::<libc::cpu_set_t>();
        libc::CPU_SET(cpu, &mut set);
        libc::sched_setaffinity(0, size_of::<libc::cpu_set_t>(), &set);
    }
}
