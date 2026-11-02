use std::{
    net::SocketAddrV4,
    sync::{
        Arc,
        atomic::{AtomicU64, Ordering},
    },
    time::{Duration, Instant},
};

use aya::{
    TestRun as _, TestRunOptions,
    maps::{
        MapData, PerCpuArray, PerfEventArray, RingBuf,
        perf::{PerfEvent, PerfEventArrayBuffer},
    },
    programs::Xdp,
};
use ebpf_shared::{PacketCounter, SizeEvent, StatsEvent};
use opentelemetry::metrics::Histogram;
use opentelemetry_sdk::metrics::{ManualReader, SdkMeterProvider};
use tokio::io::unix::AsyncFd;
use tracing::level_filters::LevelFilter;

use super::{
    PAGE_COUNT, Program, load,
    tests::{ALLOCATION, CLIENT_V4, PEER_V4, RELAY_V4, XDP_TX, channel_data_ipv4_from},
};

#[derive(Clone, Copy)]
enum Kind {
    Stats,
    Sizes,
}

#[derive(Default)]
struct Counts {
    stats_read: AtomicU64,
    stats_lost: AtomicU64,
    sizes_read: AtomicU64,
    sizes_lost: AtomicU64,
    drains: AtomicU64,
    max_lost_per_drain: AtomicU64,
}

#[derive(Clone)]
struct Instruments {
    packet_size: Histogram<u64>,
    processing_duration: Histogram<u64>,
    record: bool,
}

#[test]
#[ignore = "Benchmark, needs root to load eBPF programs"]
fn perf_wakeups() {
    let per_packet = env_or("BENCH_PER_PACKET", 0_u8);
    let wakeup_events = env_or("BENCH_WAKEUP_EVENTS", 1_u32);
    let pages = env_or("BENCH_PAGES", PAGE_COUNT);
    let secs = env_or("BENCH_SECS", 5_u64);
    let repeat = env_or("BENCH_REPEAT", 100_000_u32);
    let reader = std::env::var("BENCH_READER").unwrap_or_else(|_| "epoll".to_owned());
    let drain_interval = Duration::from_millis(env_or("BENCH_DRAIN_MS", 100_u64));
    let ring_mib = env_or("BENCH_RING_MIB", 4_u32);

    let meter_provider = SdkMeterProvider::builder()
        .with_reader(ManualReader::builder().build())
        .build();
    opentelemetry::global::set_meter_provider(meter_provider.clone());
    let instruments = Instruments {
        packet_size: otel_instruments::relay_packet_size(),
        processing_duration: otel_instruments::relay_xdp_processing_duration(),
        record: env_or("BENCH_RECORD", 1_u8) != 0,
    };

    let mut ebpf = load(
        LevelFilter::OFF,
        per_packet,
        Some(ring_mib << 20),
        Some(RELAY_V4),
        None,
        Some(RELAY_V4),
        None,
    )
    .unwrap();
    let mut stats = PerfEventArray::try_from(ebpf.take_map("STATS").unwrap()).unwrap();
    let mut sizes = PerfEventArray::try_from(ebpf.take_map("SIZES").unwrap()).unwrap();
    let mut ring =
        (per_packet == 2).then(|| RingBuf::try_from(ebpf.take_map("SIZES_RB").unwrap()).unwrap());

    let cpus = aya::util::online_cpus().unwrap();
    let bench_cpus = env_or("BENCH_THREADS", cpus.len());
    let mut buffers = Vec::new();
    for &cpu in &cpus {
        let buf = open_buffer(cpu, PAGE_COUNT, 1);
        stats.set(cpu, &buf).unwrap();
        buffers.push((Kind::Stats, buf));

        if per_packet == 1 {
            let buf = open_buffer(cpu, pages, wakeup_events);
            sizes.set(cpu, &buf).unwrap();
            buffers.push((Kind::Sizes, buf));
        }
    }

    let mut program = Program { ebpf, stats };

    // The XDP program answers from the destination address of the packet it rewrites, so these
    // two bindings turn the output of one run into the input of the next: ChannelData from
    // PEER:3478 to CLIENT:3478 goes out as UDP from CLIENT:ALLOCATION to PEER, which comes back
    // as the same ChannelData. `test_run` with `repeat` keeps running on the rewritten packet.
    let peer_stun = SocketAddrV4::new(*PEER_V4.ip(), 3478);
    let client_stun = SocketAddrV4::new(*CLIENT_V4.ip(), 3478);
    program.bind_channel_with(peer_stun.into(), PEER_V4.into(), ALLOCATION);
    program.bind_channel_with(
        client_stun.into(),
        SocketAddrV4::new(*CLIENT_V4.ip(), ALLOCATION).into(),
        PEER_V4.port(),
    );
    let packet = channel_data_ipv4_from(peer_stun, *CLIENT_V4.ip(), 0b10);

    let counts = Arc::new(Counts::default());
    let reader_cpu_ns = Arc::new(AtomicU64::new(0));
    let rt = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .on_thread_stop({
            let reader_cpu_ns = reader_cpu_ns.clone();
            move || {
                reader_cpu_ns.fetch_add(thread_cpu_ns(), Ordering::Relaxed);
            }
        })
        .build()
        .unwrap();

    match reader.as_str() {
        "epoll" => {
            if let Some(ring) = ring.take() {
                let counts = counts.clone();
                let instruments = instruments.clone();

                rt.spawn(async move {
                    let mut fd = AsyncFd::new(ring).unwrap();

                    loop {
                        match tokio::time::timeout(drain_interval, fd.readable_mut()).await {
                            Ok(Ok(mut guard)) => {
                                drain_ring(guard.get_inner_mut(), &counts, &instruments);
                                guard.clear_ready();
                            }
                            Ok(Err(e)) => panic!("Failed to wait for ring buffer: {e}"),
                            Err(_) => drain_ring(fd.get_mut(), &counts, &instruments),
                        }
                    }
                });
            }

            for (kind, buf) in buffers {
                let counts = counts.clone();
                let instruments = instruments.clone();

                rt.spawn(async move {
                    // SAFETY: `PerfEventArrayBuffer` owns its descriptor.
                    let mut fd = unsafe { AsyncFd::register(buf).unwrap() };

                    loop {
                        match tokio::time::timeout(drain_interval, fd.readable_mut()).await {
                            Ok(Ok(mut guard)) => {
                                drain(guard.get_inner_mut(), kind, &counts, &instruments);
                                guard.clear_ready();
                            }
                            Ok(Err(e)) => panic!("Failed to wait for perf buffer: {e}"),
                            Err(_) => drain(fd.get_mut(), kind, &counts, &instruments),
                        }
                    }
                });
            }
        }
        "timer" => {
            let counts = counts.clone();
            let instruments = instruments.clone();

            rt.spawn(async move {
                let mut interval = tokio::time::interval(drain_interval);
                interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);

                loop {
                    interval.tick().await;

                    for (kind, buf) in &mut buffers {
                        drain(buf, *kind, &counts, &instruments);
                    }
                    if let Some(ring) = &mut ring {
                        drain_ring(ring, &counts, &instruments);
                    }
                }
            });
        }
        other => panic!("Unknown reader {other}"),
    }

    let relayed_before = relayed(&program);
    let start = Instant::now();
    let deadline = Duration::from_secs(secs);

    let per_cpu = std::thread::scope(|s| {
        let threads = cpus[..bench_cpus]
            .iter()
            .map(|&cpu| {
                let program = &program;
                let packet = &packet;

                s.spawn(move || {
                    pin_to_cpu(cpu);
                    let xdp: &Xdp = program
                        .ebpf
                        .program("handle_turn")
                        .unwrap()
                        .try_into()
                        .unwrap();
                    let cpu_start = thread_cpu_ns();
                    let mut runs = 0_u64;
                    let mut ns = 0_u128;

                    while start.elapsed() < deadline {
                        let result = xdp
                            .test_run(TestRunOptions {
                                data_in: Some(packet),
                                repeat,
                                ..TestRunOptions::default()
                            })
                            .unwrap();
                        assert_eq!(result.return_value, XDP_TX);

                        runs += u64::from(repeat);
                        ns += result.duration.as_nanos() * u128::from(repeat);
                    }

                    (runs, ns, thread_cpu_ns() - cpu_start)
                })
            })
            .collect::<Vec<_>>();

        threads
            .into_iter()
            .map(|t| t.join().unwrap())
            .collect::<Vec<_>>()
    });
    let elapsed = start.elapsed();

    std::thread::sleep(drain_interval * 2 + Duration::from_millis(100));
    let relayed = relayed(&program) - relayed_before;
    rt.shutdown_timeout(Duration::from_secs(1));
    drop(sizes);
    drop(meter_provider);

    let runs = per_cpu.iter().map(|(runs, _, _)| runs).sum::<u64>();
    let pps = per_cpu
        .iter()
        .map(|&(runs, ns, _)| 1e9 * runs as f64 / ns as f64)
        .sum::<f64>();
    let ns_per_packet = per_cpu
        .iter()
        .map(|&(runs, ns, _)| ns as f64 / runs as f64)
        .sum::<f64>()
        / per_cpu.len() as f64;
    let bench_cpu_ns = per_cpu.iter().map(|(_, _, cpu)| cpu).sum::<u64>();

    println!(
        "RESULT variant={} reader={reader} drain_ms={} wakeup_events={wakeup_events} pages={pages} cpus={} pps={pps:.0} ns_per_packet={ns_per_packet:.1} wall_pps={:.0} runs={runs} relayed={relayed} sizes_read={} sizes_lost={} sizes_missing={} stats_read={} stats_lost={} drains={} max_lost_per_drain={} reader_cpu_ms={} bench_cpu_ms={}",
        match per_packet {
            0 => "baseline".to_owned(),
            1 => "per-packet".to_owned(),
            _ => format!("ringbuf-{ring_mib}MiB"),
        },
        drain_interval.as_millis(),
        bench_cpus,
        runs as f64 / elapsed.as_secs_f64(),
        counts.sizes_read.load(Ordering::Relaxed),
        counts.sizes_lost.load(Ordering::Relaxed),
        if per_packet == 0 {
            0
        } else {
            relayed.saturating_sub(
                counts.sizes_read.load(Ordering::Relaxed)
                    + counts.sizes_lost.load(Ordering::Relaxed),
            )
        },
        counts.stats_read.load(Ordering::Relaxed),
        counts.stats_lost.load(Ordering::Relaxed),
        counts.drains.load(Ordering::Relaxed),
        counts.max_lost_per_drain.load(Ordering::Relaxed),
        reader_cpu_ns.load(Ordering::Relaxed) / 1_000_000,
        bench_cpu_ns / 1_000_000,
    );
}

fn drain(buf: &mut PerfEventArrayBuffer, kind: Kind, counts: &Counts, instruments: &Instruments) {
    if !buf.readable() {
        return;
    }

    let attrs = [otel_attributes::relay_datapath_xdp()];
    let (read, lost) = buf.fold((0_u64, 0_u64), |(read, lost), event| match event {
        PerfEvent::Sample { head, tail } => {
            match kind {
                Kind::Stats => {
                    let stats = StatsEvent::from_chunks(head, tail).unwrap();
                    instruments
                        .processing_duration
                        .record(stats.processing_duration().as_nanos() as u64, &[]);
                }
                Kind::Sizes => {
                    let size = SizeEvent::from_chunks(head, tail).unwrap();
                    if instruments.record {
                        instruments.packet_size.record(size.relayed_data(), &attrs);
                    }
                }
            }

            (read + 1, lost)
        }
        PerfEvent::Lost { count } => (read, lost + count),
    });

    let (read_counter, lost_counter) = match kind {
        Kind::Stats => (&counts.stats_read, &counts.stats_lost),
        Kind::Sizes => (&counts.sizes_read, &counts.sizes_lost),
    };
    read_counter.fetch_add(read, Ordering::Relaxed);
    lost_counter.fetch_add(lost, Ordering::Relaxed);
    counts.drains.fetch_add(1, Ordering::Relaxed);
    counts.max_lost_per_drain.fetch_max(lost, Ordering::Relaxed);
}

fn drain_ring(ring: &mut RingBuf<MapData>, counts: &Counts, instruments: &Instruments) {
    let attrs = [otel_attributes::relay_datapath_xdp()];
    let mut read = 0;
    while let Some(item) = ring.next() {
        let size = SizeEvent::from_chunks(&item, &[]).unwrap();
        if instruments.record {
            instruments.packet_size.record(size.relayed_data(), &attrs);
        }
        read += 1;
    }

    counts.sizes_read.fetch_add(read, Ordering::Relaxed);
    counts.drains.fetch_add(1, Ordering::Relaxed);
}

fn open_buffer(cpu: u32, pages: usize, wakeup_events: u32) -> PerfEventArrayBuffer {
    // SAFETY: Buffers are opened before any other thread is spawned.
    unsafe { std::env::set_var("AYA_PERF_WAKEUP_EVENTS", wakeup_events.to_string()) };

    PerfEventArrayBuffer::open(cpu, pages).unwrap()
}

fn relayed(program: &Program) -> u64 {
    let counters =
        PerCpuArray::<_, u64>::try_from(program.ebpf.map("PACKET_COUNTERS").unwrap()).unwrap();

    (0..PacketCounter::NUM_ENTRIES)
        .map(|i| counters.get(&i, 0).unwrap().iter().sum::<u64>())
        .sum()
}

fn pin_to_cpu(cpu: u32) {
    // SAFETY: `cpu_set_t` is plain data and we pass its correct size.
    unsafe {
        let mut set = std::mem::zeroed::<libc::cpu_set_t>();
        libc::CPU_SET(cpu as usize, &mut set);
        assert_eq!(
            libc::sched_setaffinity(0, size_of::<libc::cpu_set_t>(), &set),
            0
        );
    }
}

fn thread_cpu_ns() -> u64 {
    let mut ts = libc::timespec {
        tv_sec: 0,
        tv_nsec: 0,
    };
    // SAFETY: `ts` is a valid `timespec`.
    unsafe { libc::clock_gettime(libc::CLOCK_THREAD_CPUTIME_ID, &mut ts) };

    ts.tv_sec as u64 * 1_000_000_000 + ts.tv_nsec as u64
}

fn env_or<T: std::str::FromStr>(name: &str, default: T) -> T {
    std::env::var(name)
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(default)
}
