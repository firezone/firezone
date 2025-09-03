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
    use aya_log_ebpf::{debug, warn};
    use try_handle_turn::Error;

    try_handle_turn::try_handle_turn(&ctx).unwrap_or_else(|e| match e {
        Error::NotIp | Error::NotUdp => xdp_action::XDP_PASS,

        Error::InterfaceIpv4AddressAccessFailed
        | Error::InterfaceIpv6AddressAccessFailed
        | Error::PacketTooShort
        | Error::NotTurn
        | Error::NotAChannelDataMessage
        | Error::UdpChecksumMissing
        | Error::Ipv4PacketWithOptions => {
            debug!(&ctx, "Passing packet to the stack: {}", e);

            xdp_action::XDP_PASS
        }

        Error::InterfaceIpv4AddressNotConfigured
        | Error::PacketLoop
        | Error::NoEntry(_)
        | Error::InterfaceIpv6AddressNotConfigured => {
            debug!(&ctx, "Dropping packet: {}", e);

            xdp_action::XDP_DROP
        }

        Error::BadChannelDataLength | Error::XdpAdjustHeadFailed(_) => {
            warn!(&ctx, "Dropping packet: {}", e);

            xdp_action::XDP_DROP
        }
    })
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
