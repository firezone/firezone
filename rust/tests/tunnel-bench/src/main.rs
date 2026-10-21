/// The gateway's allocator, so the benchmark exercises the same one.
#[global_allocator]
static ALLOC: mimalloc::MiMalloc = mimalloc::MiMalloc;

mod event_loop;
mod thread_cpu;

criterion::criterion_main!(event_loop::benches);
