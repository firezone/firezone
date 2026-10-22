//! Micro-benchmarks for the Internet checksum.

fn main() {
    divan::main()
}

/// Sums a 1280-byte packet and a maximum-size GSO super packet.
#[divan::bench(args = [1280, 65535])]
fn sum(bencher: divan::Bencher, len: usize) {
    let bytes = (0..len)
        .map(|i| (i as u8).wrapping_mul(37).wrapping_add(3))
        .collect::<Vec<_>>();

    bencher
        .bench(|| ip_packet::checksum::fold(ip_packet::checksum::sum(divan::black_box(&bytes), 0)));
}
