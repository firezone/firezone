/// The gateway's allocator, so the benchmark exercises the same one.
#[global_allocator]
static ALLOC: mimalloc::MiMalloc = mimalloc::MiMalloc;

mod event_loop;

criterion::criterion_main!(event_loop::benches);
