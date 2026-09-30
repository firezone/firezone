use bufferpool::BufferPool;

fn main() {
    divan::main();
}

#[divan::bench]
fn recycle(bencher: divan::Bencher) {
    let pool = BufferPool::<Vec<u8>>::new(1316, "benchmark");
    drop(pool.pull());
    bencher.bench_local(|| drop(divan::black_box(pool.pull())));
}

#[divan::bench]
fn clone_and_recycle(bencher: divan::Bencher) {
    let pool = BufferPool::<Vec<u8>>::new(1316, "benchmark");
    let original = pool.pull_initialised(&[42; 1280]);
    drop(original.clone());
    bencher.bench_local(|| drop(divan::black_box(original.clone())));
}
