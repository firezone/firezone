#[cfg(target_os = "linux")]
mod per_packet;

#[cfg(target_os = "linux")]
criterion::criterion_main!(per_packet::benches);

#[cfg(not(target_os = "linux"))]
fn main() {}
