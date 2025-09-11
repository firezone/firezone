#![cfg_attr(target_arch = "bpf", no_std)]
#![cfg_attr(target_arch = "bpf", no_main)]

// For non-BPF targets: provide a stub main that exits with an error
#[cfg(not(target_arch = "bpf"))]
fn main() {
    eprintln!("Error: This program is meant to be compiled as an eBPF program.");
    eprintln!("Use --target bpf or --target bpfel-unknown-none to compile for eBPF.");
    std::process::exit(1);
}

#[cfg(any(target_arch = "bpf", target_os = "linux"))]
mod try_handle_turn;

#[cfg(any(target_arch = "bpf", target_os = "linux"))]
#[aya_ebpf::macros::xdp]
pub fn handle_turn(ctx: aya_ebpf::programs::XdpContext) -> u32 {
    use aya_ebpf::bindings::xdp_action;
    use aya_log_ebpf::{debug, trace, warn};
    use try_handle_turn::Error;

    match try_handle_turn::try_handle_turn(&ctx) {
        Ok(()) => {
            trace!(&ctx, target: "eBPF", "==> send packet");

            xdp_action::XDP_TX
        }
        Err(Error::NotIp | Error::NotUdp) => xdp_action::XDP_PASS,
        Err(
            e @ (Error::PacketTooShort
            | Error::DnsPacket
            | Error::NotTurn
            | Error::NotAChannelDataMessage
            | Error::UdpChecksumMissing
            | Error::Ipv4PacketWithOptions),
        ) => {
            debug!(&ctx, target: "eBPF", "^^^ pass packet to userspace: {}", e);

            xdp_action::XDP_PASS
        }
        // In a double symmetric NAT setup, it is easily possible for packets to arrive from IPs that don't have channel bindings.
        Err(e @ Error::NoEntry(_)) => {
            debug!(&ctx,target: "eBPF", "XXX drop packet: {}", e);

            xdp_action::XDP_DROP
        }
        Err(
            e @ (Error::ArrayIndexOutOfBounds
            | Error::IpAddrUnset
            | Error::BadChannelDataLength
            | Error::XdpAdjustHeadFailed(_)),
        ) => {
            warn!(&ctx,target: "eBPF", "XXX drop packet: {}", e);

            xdp_action::XDP_DROP
        }
    }
}

/// Defines our panic handler.
///
/// This doesn't do anything because we can never actually panic in eBPF.
/// Attempting to link a program that wants to abort fails at compile time anyway.
#[cfg(target_arch = "bpf")]
#[panic_handler]
fn on_panic(_: &core::panic::PanicInfo) -> ! {
    loop {}
}
