//! Instructions the event loop of a Client or Gateway executes, counted by Callgrind.

#[cfg(target_os = "linux")]
mod benches {
    use std::hint::black_box;

    use gungraun::{Callgrind, LibraryBenchmarkConfig, library_benchmark, library_benchmark_group};
    use tunnel_bench::callgrind::{Direction, Idle, Packets, measure};
    use tunnel_bench::fixture::{Connectivity, Resource};

    /// Leaves ring's ChaCha20-Poly1305 out of the counts: entering one of these toggles counting
    /// off until it returns. Its cost depends on the CPU features of the machine running it.
    const AEAD: [&str; 2] = [
        "--toggle-collect=*ring::aead::algorithm::chacha20_poly1305_seal*",
        "--toggle-collect=*ring::aead::algorithm::chacha20_poly1305_open*",
    ];

    const CLIENTS: usize = 1000;

    fn seeded_packets(direction: Direction, resource: Resource) -> Packets {
        seeded_rng::reset(0);

        Packets::new(direction, resource)
    }

    fn seeded_idle(connectivity: Connectivity, clients: usize) -> Idle {
        seeded_rng::reset(0);

        Idle::new(connectivity, clients)
    }

    #[library_benchmark]
    #[bench::cidr_client_outbound(args = (Direction::ClientOutbound, Resource::Cidr), setup = seeded_packets)]
    #[bench::cidr_gateway_inbound(args = (Direction::GatewayInbound, Resource::Cidr), setup = seeded_packets)]
    #[bench::cidr_gateway_outbound(args = (Direction::GatewayOutbound, Resource::Cidr), setup = seeded_packets)]
    #[bench::cidr_client_inbound(args = (Direction::ClientInbound, Resource::Cidr), setup = seeded_packets)]
    #[bench::dns_client_outbound(args = (Direction::ClientOutbound, Resource::Dns), setup = seeded_packets)]
    #[bench::dns_gateway_inbound(args = (Direction::GatewayInbound, Resource::Dns), setup = seeded_packets)]
    #[bench::dns_gateway_outbound(args = (Direction::GatewayOutbound, Resource::Dns), setup = seeded_packets)]
    #[bench::dns_client_inbound(args = (Direction::ClientInbound, Resource::Dns), setup = seeded_packets)]
    fn packets(mut packets: Packets) -> Packets {
        measure(|| packets.run());

        black_box(packets)
    }

    // The Clients' AEAD calls happen while counting is off, where the toggles would count them,
    // so the Gateway's are counted too.
    #[library_benchmark]
    #[bench::ice(args = (Connectivity::Ice, CLIENTS), setup = seeded_idle)]
    #[bench::iceless(args = (Connectivity::Iceless, CLIENTS), setup = seeded_idle)]
    fn idle(mut idle: Idle) -> Idle {
        measure(|| idle.run());

        black_box(idle)
    }

    library_benchmark_group!(
        name = packet_group,
        config = LibraryBenchmarkConfig::default().tool(Callgrind::with_args(AEAD)),
        benchmarks = packets
    );

    library_benchmark_group!(name = idle_group, benchmarks = idle);
}

#[cfg(target_os = "linux")]
use benches::{idle_group, packet_group};

#[cfg(target_os = "linux")]
gungraun::main!(library_benchmark_groups = packet_group, idle_group);

#[cfg(not(target_os = "linux"))]
fn main() {}
