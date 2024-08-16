use blake2::digest::{FixedOutput, KeyInit};
use blake2::{Blake2s256, Blake2sMac, Digest};
use criterion::{BenchmarkId, Criterion, Throughput};
use ring::rand::{SecureRandom, SystemRandom};

pub fn bench_blake2s_hash(c: &mut Criterion) {
    let mut group = c.benchmark_group("blake2s_hash");

    group.sample_size(1000);

    for size in [32, 64, 128] {
        group.throughput(Throughput::Bytes(size as u64));

        group.bench_with_input(BenchmarkId::new("blake2s_crate", size), &size, |b, _| {
            let buf_in = vec![0u8; size];

            b.iter(|| {
                let mut hasher = Blake2s256::new();
                hasher.update(&buf_in);
                hasher.finalize();
            });
        });
    }

    group.finish();
}

pub fn bench_blake2s_hmac(c: &mut Criterion) {
    let mut group = c.benchmark_group("blake2s_hmac");

    group.sample_size(1000);

    for size in [16, 32] {
        group.throughput(Throughput::Bytes(size as u64));

        group.bench_with_input(BenchmarkId::new("blake2s_crate", size), &size, |b, _| {
            let buf_in = vec![0u8; size];
            let rng = SystemRandom::new();

            b.iter_batched(
                || {
                    let mut key = [0u8; 32];
                    rng.fill(&mut key).unwrap();
                    key
                },
                |key| {
                    use blake2::digest::Update;
                    type HmacBlake2s = hmac::SimpleHmac<blake2::Blake2s256>;
                    let mut hmac = HmacBlake2s::new_from_slice(&key).unwrap();
                    hmac.update(&buf_in);
                    hmac.finalize_fixed();
                },
                criterion::BatchSize::SmallInput,
            );
        });
    }

    group.finish();
}

pub fn bench_blake2s_keyed(c: &mut Criterion) {
    let mut group = c.benchmark_group("blake2s_keyed_mac");

    group.sample_size(1000);

    for size in [128, 1024] {
        group.throughput(Throughput::Bytes(size as u64));

        group.bench_with_input(BenchmarkId::new("blake2s_crate", size), &size, |b, _| {
            let buf_in = vec![0u8; size];
            let rng = SystemRandom::new();

            b.iter_batched(
                || {
                    let mut key = [0u8; 16];
                    rng.fill(&mut key).unwrap();
                    key
                },
                |key| -> [u8; 16] {
                    let mut hmac = Blake2sMac::new_from_slice(&key).unwrap();
                    blake2::digest::Update::update(&mut hmac, &buf_in);
                    hmac.finalize_fixed().into()
                },
                criterion::BatchSize::SmallInput,
            );
        });
    }

    group.finish();
}
