#[cfg(target_os = "linux")]
mod event_loop;

#[cfg(target_os = "linux")]
criterion::criterion_main!(event_loop::benches);

#[cfg(not(target_os = "linux"))]
fn main() {}
