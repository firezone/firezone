//! Compares designs for running WireGuard crypto off the main thread.
//!
//! The main thread processes a saturated stream of TUN batches (encryption) or receive batches
//! (decryption), spending a configurable `W` ns of fake work per packet next to the stateful
//! crypto step. Results always end up on a sink thread that models the IO thread.
//!
//! Usage: `crypto-bench [raw|enc|dec|all] [secs=1.5] [reps=3] [w=0,50,100,150,250,500]`

use std::collections::VecDeque;
use std::hint::black_box;
use std::net::{IpAddr, Ipv4Addr};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use boringtun::noise::{Index, Opened, Packet, PendingOpen, PendingSeal, Tunn, TunnResult};
use boringtun::x25519::{PublicKey, StaticSecret};
use crossbeam_channel::{Receiver, Sender, bounded, unbounded};
use rayon::prelude::*;

const TUN_BATCH: usize = 100;
const PAYLOAD: usize = 1300;
const IP_LEN: usize = PAYLOAD + 28;
const SEG: usize = IP_LEN + 32;
const MAX_SEGMENTS: usize = 45;
const MAX_GSO: usize = u16::MAX as usize;
const OPEN_STRIDE: usize = 1408;
/// Datagrams encrypted up front for each decryption round; fresh counters keep the replay window happy.
const DEC_CHUNK: usize = 128 * 1024;
const PEER: IpAddr = IpAddr::V4(Ipv4Addr::new(192, 0, 2, 1));

fn main() {
    let mut mode = "all".to_owned();
    let mut secs = 1.5;
    let mut reps = 3;
    let mut ws = vec![0, 50, 100, 150, 250, 500];
    for arg in std::env::args().skip(1) {
        match arg.split_once('=') {
            Some(("secs", v)) => secs = v.parse().unwrap(),
            Some(("reps", v)) => reps = v.parse().unwrap(),
            Some(("w", v)) => ws = v.split(',').map(|w| w.parse().unwrap()).collect(),
            None => mode = arg,
            _ => panic!("unknown argument {arg}"),
        }
    }
    let measure = Duration::from_secs_f64(secs);
    let iters_per_ns = calibrate();
    eprintln!("spin: {iters_per_ns:.3} iterations/ns");

    if mode == "raw" || mode == "all" {
        raw();
    }

    println!("dir,variant,w_ns,workers,cap,thr,gbps,main_util");
    for &w in &ws {
        let work = Work((w as f64 * iters_per_ns) as u64);
        if mode == "enc" || mode == "all" {
            for v in enc_variants() {
                report("enc", &v.to_string(), w, &v.params(), reps, || {
                    run_encrypt(v, work, measure)
                });
            }
        }
        if mode == "dec" || mode == "all" {
            for v in dec_variants() {
                report("dec", &v.to_string(), w, &v.params(), reps, || {
                    run_decrypt(v, work, measure)
                });
            }
        }
    }
}

fn report(dir: &str, name: &str, w: u64, params: &str, reps: usize, run: impl Fn() -> Sample) {
    let samples = (0..reps).map(|_| run()).collect::<Vec<_>>();
    let gbps = median(samples.iter().map(|s| s.gbps).collect());
    let util = median(samples.iter().map(|s| s.main_util).collect());
    println!("{dir},{name},{w},{params},{gbps:.2},{util:.2}");
}

fn median(mut v: Vec<f64>) -> f64 {
    v.sort_by(f64::total_cmp);
    v[v.len() / 2]
}

struct Sample {
    gbps: f64,
    main_util: f64,
}

impl Sample {
    fn new(plaintext_bytes: u64, wall: Duration, cpu: Duration) -> Self {
        Self {
            gbps: plaintext_bytes as f64 * 8.0 / wall.as_secs_f64() / 1e9,
            main_util: cpu.as_secs_f64() / wall.as_secs_f64(),
        }
    }
}

/// Busy work standing in for everything the main thread does per packet besides crypto.
#[derive(Clone, Copy)]
struct Work(u64);

impl Work {
    #[inline(never)]
    fn run(self) {
        for i in 0..self.0 {
            black_box(i);
        }
    }
}

/// Iterations of [`Work`] per ns, best of several tries so that preemption does not skew it.
fn calibrate() -> f64 {
    let work = Work(50_000_000);

    (0..10)
        .map(|_| {
            let start = Instant::now();
            work.run();
            work.0 as f64 / start.elapsed().as_nanos() as f64
        })
        .fold(0.0, f64::max)
}

fn thread_cpu() -> Duration {
    let mut ts = libc::timespec {
        tv_sec: 0,
        tv_nsec: 0,
    };
    // SAFETY: `ts` is a valid, writable timespec.
    let rc = unsafe { libc::clock_gettime(libc::CLOCK_THREAD_CPUTIME_ID, &mut ts) };
    assert_eq!(rc, 0);

    Duration::new(ts.tv_sec as u64, ts.tv_nsec as u32)
}

/// Two tunnels with a completed handshake. All calls use the same `now`, so sessions never expire.
fn connected(now: Instant) -> (Tunn, Tunn) {
    let unix = Duration::from_secs(1_700_000_000);
    let secret_a = StaticSecret::random();
    let public_a = PublicKey::from(&secret_a);
    let secret_b = StaticSecret::random();
    let public_b = PublicKey::from(&secret_b);
    let mut a = Tunn::new_at(
        secret_a,
        public_b,
        None,
        None,
        Index::new_local(1),
        None,
        1,
        now,
        now,
        unix,
    );
    let mut b = Tunn::new_at(
        secret_b,
        public_a,
        None,
        None,
        Index::new_local(2),
        None,
        2,
        now,
        now,
        unix,
    );

    let mut buf = vec![0u8; 2048];
    let TunnResult::WriteToNetwork(init) = a.format_handshake_initiation_at(&mut buf, false, now)
    else {
        panic!("expected a handshake initiation");
    };
    let mut in_flight = VecDeque::from([(true, init.to_vec())]);
    while let Some((to_b, datagram)) = in_flight.pop_front() {
        let receiver = if to_b { &mut b } else { &mut a };
        let mut datagram = datagram.as_slice();
        loop {
            match receiver.decapsulate_at(Some(PEER), datagram, &mut buf, now) {
                TunnResult::WriteToNetwork(reply) => in_flight.push_back((!to_b, reply.to_vec())),
                TunnResult::Done => break,
                other => panic!("unexpected handshake result: {other:?}"),
            }
            datagram = &[];
        }
    }

    (a, b)
}

fn ip_packets() -> Vec<Vec<u8>> {
    (0..TUN_BATCH)
        .map(|i| {
            let mut p = vec![0u8; IP_LEN];
            p[0] = 0x45;
            p[2..4].copy_from_slice(&(IP_LEN as u16).to_be_bytes());
            p[8] = 64;
            p[9] = 17;
            p[12..16].copy_from_slice(&[10, 0, 0, 1]);
            p[16..20].copy_from_slice(&[10, 0, 0, 2]);
            for (j, b) in p[28..].iter_mut().enumerate() {
                *b = (i * 31 + j) as u8;
            }
            p
        })
        .collect()
}

/// Encrypts `DEC_CHUNK` datagrams from `a` back-to-back into `chunk`, `SEG` bytes each.
fn generate(a: &mut Tunn, packets: &[Vec<u8>], chunk: &mut Vec<u8>, now: Instant) {
    chunk.resize(DEC_CHUNK * SEG, 0);
    let seals = chunk
        .chunks_mut(SEG)
        .zip(packets.iter().cycle())
        .map(|(d, p)| a.encapsulate_data_deferred_at(p, d, now).unwrap())
        .collect::<Vec<_>>();
    seals
        .into_par_iter()
        .zip(chunk.par_chunks_mut(SEG))
        .for_each(|(s, d)| {
            s.seal(d);
        });
}

/// Single-core cost of each crypto step per packet, in batches of `TUN_BATCH` into warm buffers.
fn raw() {
    let now = Instant::now();
    let (mut a, mut b) = connected(now);
    let packets = ip_packets();
    let mut bufs = vec![1u8; TUN_BATCH * OPEN_STRIDE];
    let mut seals = Vec::with_capacity(TUN_BATCH);
    let mut opens = Vec::with_capacity(TUN_BATCH);
    let mut opened = Vec::with_capacity(TUN_BATCH);
    let mut t = [Duration::ZERO; 7];
    let mut lap = |i: usize, start: &mut Instant| {
        let now = Instant::now();
        t[i] += now - *start;
        *start = now;
    };

    let mut chunk = Vec::new();
    let rounds = 8;
    for _ in 0..rounds {
        for _ in 0..DEC_CHUNK / TUN_BATCH {
            let mut start = Instant::now();
            for (p, buf) in packets.iter().zip(bufs.chunks_mut(OPEN_STRIDE)) {
                black_box(a.encapsulate_data_at(p, buf, now).unwrap());
            }
            lap(0, &mut start);
            for (p, buf) in packets.iter().zip(bufs.chunks_mut(OPEN_STRIDE)) {
                seals.push(a.encapsulate_data_deferred_at(p, buf, now).unwrap());
            }
            lap(1, &mut start);
            for (s, buf) in seals.drain(..).zip(bufs.chunks_mut(OPEN_STRIDE)) {
                black_box(s.seal(buf));
            }
            lap(2, &mut start);
        }

        generate(&mut a, &packets, &mut chunk, now);
        for (i, datagrams) in chunk.chunks(SEG * TUN_BATCH).enumerate() {
            let mut start = Instant::now();
            if i % 2 == 0 {
                for (d, buf) in datagrams.chunks(SEG).zip(bufs.chunks_mut(OPEN_STRIDE)) {
                    let TunnResult::WriteToTunnelV4(p, _) =
                        b.decapsulate_at(Some(PEER), d, buf, now)
                    else {
                        panic!("expected a decrypted packet")
                    };
                    black_box(p);
                }
                lap(3, &mut start);
                continue;
            }
            for (d, buf) in datagrams.chunks(SEG).zip(bufs.chunks_mut(OPEN_STRIDE)) {
                let Ok(Packet::PacketData(data)) = Tunn::parse_incoming_packet(d) else {
                    panic!("expected a data message")
                };
                opens.push(b.decapsulate_data_deferred(data, buf).unwrap());
            }
            lap(4, &mut start);
            for (o, buf) in opens.drain(..).zip(bufs.chunks_mut(OPEN_STRIDE)) {
                opened.push(o.open(buf));
            }
            lap(5, &mut start);
            for (o, buf) in opened.drain(..).zip(bufs.chunks_mut(OPEN_STRIDE)) {
                let TunnResult::WriteToTunnelV4(p, _) = b.finish_decapsulate_data_at(o, buf, now)
                else {
                    panic!("expected a decrypted packet")
                };
                black_box(p);
            }
            lap(6, &mut start);
        }
    }
    let seal_n = (rounds * DEC_CHUNK / TUN_BATCH * TUN_BATCH) as f64;
    let open_n = (rounds * DEC_CHUNK / 2) as f64;
    let ns = |i: usize, n: f64| t[i].as_nanos() as f64 / n;

    println!(
        "raw ns/packet ({IP_LEN} byte IP packets, one core, size_of PendingSeal {} / PendingOpen {})",
        size_of::<PendingSeal>(),
        size_of::<PendingOpen>()
    );
    println!(
        "  seal inline (encapsulate_data_at):      {:.0}",
        ns(0, seal_n)
    );
    println!(
        "  seal prepare (deferred, main thread):   {:.0}",
        ns(1, seal_n)
    );
    println!(
        "  seal AEAD only (PendingSeal::seal):     {:.0}",
        ns(2, seal_n)
    );
    println!(
        "  open inline (decapsulate_at):           {:.0}",
        ns(3, open_n)
    );
    println!(
        "  open prepare (parse + deferred, main):  {:.0}",
        ns(4, open_n)
    );
    println!(
        "  open AEAD only (PendingOpen::open):     {:.0}",
        ns(5, open_n)
    );
    println!(
        "  open finish (main thread):              {:.0}",
        ns(6, open_n)
    );
}

/// Releases results in the order their sequence numbers were handed out.
struct Reorder<T> {
    head: u64,
    results: VecDeque<Option<T>>,
}

impl<T> Default for Reorder<T> {
    fn default() -> Self {
        Self {
            head: 0,
            results: VecDeque::new(),
        }
    }
}

impl<T> Reorder<T> {
    fn reserve(&mut self) -> u64 {
        self.results.push_back(None);
        self.head + self.results.len() as u64 - 1
    }

    fn complete(&mut self, seq: u64, result: T) {
        let index = (seq - self.head) as usize;
        if index >= self.results.len() {
            self.results.resize_with(index + 1, || None);
        }
        self.results[index] = Some(result);
    }

    fn pop(&mut self) -> Option<T> {
        let result = self.results.pop_front_if(|r| r.is_some())??;
        self.head += 1;

        Some(result)
    }

    fn len(&self) -> usize {
        self.results.len()
    }
}

trait Job: Send + 'static {
    fn packets(&self) -> usize;
    fn run(&mut self);
}

/// Dedicated workers fed over a channel, results returned to the main thread and released in order.
struct Pipeline<T> {
    jobs: Option<Sender<(u64, T)>>,
    done: Receiver<(u64, T)>,
    reorder: Reorder<T>,
    cap: usize,
    thr: usize,
    workers: Vec<JoinHandle<()>>,
}

impl<T: Job> Pipeline<T> {
    fn new(workers: usize, cap: usize, thr: usize) -> Self {
        let (jobs_tx, jobs_rx) = unbounded::<(u64, T)>();
        let (done_tx, done_rx) = unbounded();
        let workers = (0..workers)
            .map(|_| spawn_worker(jobs_rx.clone(), done_tx.clone()))
            .collect();

        Self {
            jobs: Some(jobs_tx),
            done: done_rx,
            reorder: Reorder::default(),
            cap,
            thr,
            workers,
        }
    }

    fn submit(&mut self, mut job: T, release: &mut impl FnMut(T)) {
        self.drain(false, release);
        while self.reorder.len() >= self.cap {
            self.drain(true, release);
        }

        let seq = self.reorder.reserve();
        if job.packets() < self.thr {
            job.run();
            self.reorder.complete(seq, job);
            self.drain(false, release);
            return;
        }
        self.jobs.as_ref().unwrap().send((seq, job)).unwrap();
    }

    fn drain(&mut self, block: bool, release: &mut impl FnMut(T)) {
        if block {
            let (seq, job) = self.done.recv().unwrap();
            self.reorder.complete(seq, job);
        }
        while let Ok((seq, job)) = self.done.try_recv() {
            self.reorder.complete(seq, job);
        }
        while let Some(job) = self.reorder.pop() {
            release(job);
        }
    }

    fn flush(&mut self, release: &mut impl FnMut(T)) {
        while self.reorder.len() > 0 {
            self.drain(true, release);
        }
    }
}

impl<T> Drop for Pipeline<T> {
    fn drop(&mut self) {
        self.jobs = None;
        for w in self.workers.drain(..) {
            let _ = w.join();
        }
    }
}

fn spawn_worker<T: Job>(jobs: Receiver<(u64, T)>, out: Sender<(u64, T)>) -> JoinHandle<()> {
    thread::spawn(move || {
        for (seq, mut job) in jobs {
            job.run();
            if out.send((seq, job)).is_err() {
                return;
            }
        }
    })
}

fn pooled<T>(pool: &Receiver<T>, new: impl FnOnce() -> T) -> T {
    pool.try_recv().unwrap_or_else(|_| new())
}

// ---------------------------------------------------------------- encryption

struct GsoBatch {
    buf: Vec<u8>,
    segments: usize,
    seals: Vec<PendingSeal>,
}

impl GsoBatch {
    fn new() -> Self {
        Self {
            buf: Vec::with_capacity(MAX_GSO),
            segments: 0,
            seals: Vec::with_capacity(MAX_SEGMENTS),
        }
    }

    fn is_full(&self) -> bool {
        self.segments == MAX_SEGMENTS || self.buf.len() + SEG > MAX_GSO
    }
}

impl Job for GsoBatch {
    fn packets(&self) -> usize {
        self.segments
    }

    fn run(&mut self) {
        for (seal, segment) in self.seals.drain(..).zip(self.buf.chunks_mut(SEG)) {
            seal.seal(segment);
        }
    }
}

#[derive(Clone, Copy)]
enum Enc {
    Inline,
    ForkJoin {
        threads: usize,
    },
    Pipeline {
        workers: usize,
        cap: usize,
        thr: usize,
        /// Submit each GSO batch as soon as it is full instead of after the whole TUN batch.
        eager: bool,
        /// Workers send to the sink, which restores the order, instead of returning to main.
        direct: bool,
    },
}

impl std::fmt::Display for Enc {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Enc::Inline => write!(f, "inline"),
            Enc::ForkJoin { .. } => write!(f, "fork-join"),
            Enc::Pipeline {
                eager: true,
                direct: true,
                ..
            } => write!(f, "pipeline-eager-direct"),
            Enc::Pipeline { eager: true, .. } => write!(f, "pipeline-eager"),
            Enc::Pipeline { direct: true, .. } => write!(f, "pipeline-direct"),
            Enc::Pipeline { .. } => write!(f, "pipeline"),
        }
    }
}

impl Enc {
    fn params(&self) -> String {
        match *self {
            Enc::Inline => "0,-,-".to_owned(),
            Enc::ForkJoin { threads } => format!("{threads},-,-"),
            Enc::Pipeline {
                workers, cap, thr, ..
            } => format!("{workers},{cap},{thr}"),
        }
    }
}

fn enc_variants() -> Vec<Enc> {
    let pipeline = |workers, cap, thr, eager, direct| Enc::Pipeline {
        workers,
        cap,
        thr,
        eager,
        direct,
    };
    let mut v = vec![Enc::Inline];
    v.extend((1..=3).map(|threads| Enc::ForkJoin { threads }));
    for workers in 1..=3 {
        for (cap, thr) in [(8, 8), (4, 8), (16, 8), (8, 0), (8, 16)] {
            v.push(pipeline(workers, cap, thr, false, false));
        }
        v.push(pipeline(workers, 8, 8, true, false));
        v.push(pipeline(workers, 8, 8, false, true));
    }
    v
}

fn run_encrypt(variant: Enc, work: Work, measure: Duration) -> Sample {
    let now = Instant::now();
    let (mut a, _b) = connected(now);
    let packets = ip_packets();
    let (sink_tx, sink_rx) = bounded::<(u64, GsoBatch)>(64);
    let (pool_tx, pool) = unbounded();
    let bytes = Arc::new(AtomicU64::new(0));

    let (credits_tx, credits_rx) = match variant {
        Enc::Pipeline {
            cap, direct: true, ..
        } => {
            let (tx, rx) = bounded(cap);
            (Some(tx), Some(rx))
        }
        _ => (None, None),
    };
    let sink = {
        let bytes = bytes.clone();
        thread::spawn(move || enc_sink(sink_rx, pool_tx, credits_rx, bytes))
    };

    let mut offload = match variant {
        Enc::Inline => EncOffload::Inline,
        Enc::ForkJoin { threads } => EncOffload::ForkJoin(
            rayon::ThreadPoolBuilder::new()
                .num_threads(threads)
                .build()
                .unwrap(),
        ),
        Enc::Pipeline {
            workers,
            cap,
            thr,
            direct: false,
            ..
        } => EncOffload::Pipeline(Pipeline::new(workers, cap, thr)),
        Enc::Pipeline {
            workers,
            thr,
            direct: true,
            ..
        } => {
            let (jobs_tx, jobs_rx) = unbounded();
            let workers = (0..workers)
                .map(|_| spawn_worker(jobs_rx.clone(), sink_tx.clone()))
                .collect();
            EncOffload::Direct {
                jobs: Some(jobs_tx),
                credits: credits_tx.unwrap(),
                thr,
                workers,
            }
        }
    };
    let eager = matches!(variant, Enc::Pipeline { eager: true, .. });
    let inline = matches!(variant, Enc::Inline);

    let mut out = Out {
        tx: sink_tx,
        seq: 0,
    };
    let mut closed = Vec::new();
    let mut cur = pooled(&pool, GsoBatch::new);

    let start = Instant::now();
    let warmup = Duration::from_millis(500);
    let mut t0 = None;
    let sample = loop {
        for p in &packets {
            work.run();
            if cur.is_full() {
                let full = std::mem::replace(&mut cur, pooled(&pool, GsoBatch::new));
                if eager {
                    offload.submit(full, &mut out);
                } else {
                    closed.push(full);
                }
            }
            let offset = cur.buf.len();
            cur.buf.resize(offset + SEG, 0);
            cur.segments += 1;
            let dst = &mut cur.buf[offset..];
            if inline {
                a.encapsulate_data_at(p, dst, now).unwrap();
            } else {
                cur.seals
                    .push(a.encapsulate_data_deferred_at(p, dst, now).unwrap());
            }
        }
        closed.push(std::mem::replace(&mut cur, pooled(&pool, GsoBatch::new)));

        if let EncOffload::ForkJoin(pool) = &offload {
            let mut jobs = closed
                .iter_mut()
                .flat_map(|b| b.seals.drain(..).zip(b.buf.chunks_mut(SEG)))
                .collect::<Vec<_>>();
            pool.install(|| {
                jobs.par_drain(..).for_each(|(seal, segment)| {
                    seal.seal(segment);
                })
            });
        }
        for batch in closed.drain(..) {
            offload.submit(batch, &mut out);
        }
        if let EncOffload::Pipeline(p) = &mut offload {
            p.drain(false, &mut |b| out.send(b));
        }

        let t = Instant::now();
        match t0 {
            None if t - start >= warmup => {
                t0 = Some((t, thread_cpu(), bytes.load(Ordering::Relaxed)));
            }
            Some((t0, cpu0, bytes0)) if t - t0 >= measure => {
                break Sample::new(
                    bytes.load(Ordering::Relaxed) - bytes0,
                    t - t0,
                    thread_cpu() - cpu0,
                );
            }
            _ => {}
        }
    };

    match &mut offload {
        EncOffload::Pipeline(p) => p.flush(&mut |b| out.send(b)),
        EncOffload::Direct { jobs, workers, .. } => {
            *jobs = None;
            for w in workers.drain(..) {
                w.join().unwrap();
            }
        }
        _ => {}
    }
    drop(offload);
    drop(out);
    sink.join().unwrap();

    sample
}

/// The sink's channel, numbering batches in the order they must be sent.
struct Out {
    tx: Sender<(u64, GsoBatch)>,
    seq: u64,
}

impl Out {
    fn next_seq(&mut self) -> u64 {
        self.seq += 1;
        self.seq - 1
    }

    fn send(&mut self, batch: GsoBatch) {
        let seq = self.next_seq();
        self.tx.send((seq, batch)).unwrap();
    }
}

enum EncOffload {
    Inline,
    ForkJoin(rayon::ThreadPool),
    Pipeline(Pipeline<GsoBatch>),
    Direct {
        jobs: Option<Sender<(u64, GsoBatch)>>,
        /// Bounds the batches in flight: one credit per batch, returned by the sink.
        credits: Sender<()>,
        thr: usize,
        workers: Vec<JoinHandle<()>>,
    },
}

impl EncOffload {
    /// Hands a closed GSO batch over; sealed batches leave via `out`.
    fn submit(&mut self, mut batch: GsoBatch, out: &mut Out) {
        match self {
            EncOffload::Inline | EncOffload::ForkJoin(_) => out.send(batch),
            EncOffload::Pipeline(p) => p.submit(batch, &mut |b| out.send(b)),
            EncOffload::Direct {
                jobs, credits, thr, ..
            } => {
                credits.send(()).unwrap();
                if batch.segments < *thr {
                    batch.run();
                    out.send(batch);
                } else {
                    let seq = out.next_seq();
                    jobs.as_ref().unwrap().send((seq, batch)).unwrap();
                }
            }
        }
    }
}

fn enc_sink(
    rx: Receiver<(u64, GsoBatch)>,
    pool: Sender<GsoBatch>,
    credits: Option<Receiver<()>>,
    bytes: Arc<AtomicU64>,
) {
    let mut reorder = Reorder::default();
    let mut touched = 0u8;
    for (seq, batch) in rx {
        reorder.complete(seq, batch);
        while let Some(mut batch) = reorder.pop() {
            for segment in batch.buf.chunks(SEG) {
                touched ^= segment[0];
            }
            bytes.fetch_add((batch.segments * IP_LEN) as u64, Ordering::Relaxed);
            if let Some(credits) = &credits {
                let _ = credits.recv();
            }
            batch.buf.clear();
            batch.segments = 0;
            let _ = pool.send(batch);
        }
    }
    black_box(touched);
}

// ---------------------------------------------------------------- decryption

struct OpenBatch {
    buf: Vec<u8>,
    n: usize,
    opens: Vec<PendingOpen>,
    opened: Vec<Opened>,
}

impl OpenBatch {
    fn new() -> Self {
        Self {
            buf: vec![0; TUN_BATCH * OPEN_STRIDE],
            n: 0,
            opens: Vec::with_capacity(TUN_BATCH),
            opened: Vec::with_capacity(TUN_BATCH),
        }
    }

    fn slot(&mut self, i: usize) -> &mut [u8] {
        &mut self.buf[i * OPEN_STRIDE..(i + 1) * OPEN_STRIDE]
    }
}

impl Job for OpenBatch {
    fn packets(&self) -> usize {
        self.n
    }

    fn run(&mut self) {
        for (open, buf) in self.opens.drain(..).zip(self.buf.chunks_mut(OPEN_STRIDE)) {
            self.opened.push(open.open(buf));
        }
    }
}

#[derive(Clone, Copy)]
enum Dec {
    Inline,
    Pipeline { workers: usize, cap: usize },
}

impl std::fmt::Display for Dec {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Dec::Inline => write!(f, "inline"),
            Dec::Pipeline { .. } => write!(f, "pipeline"),
        }
    }
}

impl Dec {
    fn params(&self) -> String {
        match *self {
            Dec::Inline => "0,-,-".to_owned(),
            Dec::Pipeline { workers, cap } => format!("{workers},{cap},-"),
        }
    }
}

fn dec_variants() -> Vec<Dec> {
    let mut v = vec![Dec::Inline];
    for workers in 1..=3 {
        for cap in [8, 4, 16] {
            v.push(Dec::Pipeline { workers, cap });
        }
    }
    v
}

/// Each receive batch of `TUN_BATCH` datagrams is one job, like one `poll_recv_from` in connlib.
fn run_decrypt(variant: Dec, work: Work, measure: Duration) -> Sample {
    let now = Instant::now();
    let (mut a, mut b) = connected(now);
    let packets = ip_packets();
    let (sink_tx, sink_rx) = bounded::<OpenBatch>(64);
    let (pool_tx, pool) = unbounded();
    let sink = thread::spawn(move || {
        let mut touched = 0u8;
        for mut batch in sink_rx {
            for i in 0..batch.n {
                touched ^= batch.buf[i * OPEN_STRIDE];
            }
            batch.n = 0;
            let _ = pool_tx.send(batch);
        }
        black_box(touched);
    });
    let mut pipeline = match variant {
        Dec::Inline => None,
        Dec::Pipeline { workers, cap } => Some(Pipeline::<OpenBatch>::new(workers, cap, 8)),
    };

    let warmup = Duration::from_millis(500);
    let mut chunk = Vec::new();
    let (mut warm_wall, mut wall, mut cpu, mut total_bytes) =
        (Duration::ZERO, Duration::ZERO, Duration::ZERO, 0);
    while wall < measure {
        generate(&mut a, &packets, &mut chunk, now);
        let mut bytes = 0;
        let mut decrypted = 0;

        let t0 = Instant::now();
        let cpu0 = thread_cpu();
        for datagrams in chunk.chunks(SEG * TUN_BATCH) {
            let mut batch = pooled(&pool, OpenBatch::new);
            for d in datagrams.chunks(SEG) {
                work.run();
                let slot = batch.slot(batch.n);
                if pipeline.is_some() {
                    let Ok(Packet::PacketData(data)) = Tunn::parse_incoming_packet(d) else {
                        panic!("expected a data message");
                    };
                    let open = b.decapsulate_data_deferred(data, slot).unwrap();
                    batch.opens.push(open);
                } else {
                    let TunnResult::WriteToTunnelV4(p, _) =
                        b.decapsulate_at(Some(PEER), d, slot, now)
                    else {
                        panic!("expected a decrypted packet");
                    };
                    bytes += p.len();
                    decrypted += 1;
                }
                batch.n += 1;
            }

            match &mut pipeline {
                Some(p) => p.submit(batch, &mut |batch| {
                    let (n, len) = finish(&mut b, batch, &sink_tx, now);
                    decrypted += n;
                    bytes += len;
                }),
                None => sink_tx.send(batch).unwrap(),
            }
        }
        if let Some(p) = &mut pipeline {
            p.flush(&mut |batch| {
                let (n, len) = finish(&mut b, batch, &sink_tx, now);
                decrypted += n;
                bytes += len;
            });
        }
        let elapsed = t0.elapsed();
        let cpu_elapsed = thread_cpu() - cpu0;

        assert_eq!(decrypted, DEC_CHUNK, "every datagram must decrypt");
        if warm_wall < warmup {
            warm_wall += elapsed;
            continue;
        }
        wall += elapsed;
        cpu += cpu_elapsed;
        total_bytes += bytes as u64;
    }

    drop(pipeline);
    drop(sink_tx);
    sink.join().unwrap();

    Sample::new(total_bytes, wall, cpu)
}

/// Completes the decryption of an opened batch on the main thread and passes it to the sink.
fn finish(
    b: &mut Tunn,
    mut batch: OpenBatch,
    sink: &Sender<OpenBatch>,
    now: Instant,
) -> (usize, usize) {
    let mut bytes = 0;
    let mut n = 0;
    for (opened, buf) in batch
        .opened
        .drain(..)
        .zip(batch.buf.chunks_mut(OPEN_STRIDE))
    {
        let TunnResult::WriteToTunnelV4(p, _) = b.finish_decapsulate_data_at(opened, buf, now)
        else {
            panic!("expected a decrypted packet");
        };
        bytes += p.len();
        n += 1;
    }
    sink.send(batch).unwrap();

    (n, bytes)
}
