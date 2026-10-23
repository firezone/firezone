//! Instructions the event loop of a Client or Gateway executes, counted by Callgrind.

#[cfg(target_os = "linux")]
mod benches {
    use std::hint::black_box;

    use event_loop_callgrind::{Connectivity, Direction, Idle, Packets, Resource, measure};
    use gungraun::{Callgrind, LibraryBenchmarkConfig, library_benchmark, library_benchmark_group};

    /// Leaves ring's ChaCha20-Poly1305 out of the counts: entering one of these toggles counting
    /// off until it returns. Its cost depends on the CPU features of the machine running it.
    const AEAD: [&str; 2] = [
        "--toggle-collect=*ring::aead::algorithm::chacha20_poly1305_seal*",
        "--toggle-collect=*ring::aead::algorithm::chacha20_poly1305_open*",
    ];

    const CLIENTS: usize = 1000;

    #[library_benchmark]
    #[bench::cidr_client_outbound(Packets::new(Direction::ClientOutbound, Resource::Cidr))]
    #[bench::cidr_gateway_inbound(Packets::new(Direction::GatewayInbound, Resource::Cidr))]
    #[bench::cidr_gateway_outbound(Packets::new(Direction::GatewayOutbound, Resource::Cidr))]
    #[bench::cidr_client_inbound(Packets::new(Direction::ClientInbound, Resource::Cidr))]
    #[bench::dns_client_outbound(Packets::new(Direction::ClientOutbound, Resource::Dns))]
    #[bench::dns_gateway_inbound(Packets::new(Direction::GatewayInbound, Resource::Dns))]
    #[bench::dns_gateway_outbound(Packets::new(Direction::GatewayOutbound, Resource::Dns))]
    #[bench::dns_client_inbound(Packets::new(Direction::ClientInbound, Resource::Dns))]
    fn packets(mut packets: Packets) -> Packets {
        measure(|| packets.run());

        black_box(packets)
    }

    // The Clients' AEAD calls happen while counting is off, where the toggles would count them,
    // so the Gateway's are counted too.
    #[library_benchmark]
    #[bench::ice(Idle::new(Connectivity::Ice, CLIENTS))]
    #[bench::iceless(Idle::new(Connectivity::Iceless, CLIENTS))]
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
