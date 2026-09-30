use bufferpool::{BufferPool, Local, Sharing, ThreadSafe};

fn main() {
    divan::main();
}

#[divan::bench(types = [Local, ThreadSafe])]
fn recycle<S: Sharing>(bencher: divan::Bencher) {
    let pool = BufferPool::<Vec<u8>, S>::new(1316, "benchmark");
    drop(pool.pull());
    bencher.bench_local(|| drop(divan::black_box(pool.pull())));
}

#[divan::bench(types = [Local, ThreadSafe])]
fn clone_and_recycle<S: Sharing>(bencher: divan::Bencher) {
    let pool = BufferPool::<Vec<u8>, S>::new(1316, "benchmark");
    let original = pool.pull_initialised(&[42; 1280]);
    drop(original.clone());
    bencher.bench_local(|| drop(divan::black_box(original.clone())));
}
