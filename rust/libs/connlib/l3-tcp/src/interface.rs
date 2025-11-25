use smoltcp::{
    iface::{Config, Interface},
    wire::{HardwareAddress, Ipv4Address, Ipv4Cidr, Ipv6Address, Ipv6Cidr},
};

use crate::stub_device::InMemoryDevice;

const IP4_ADDR: Ipv4Address = Ipv4Address::new(127, 0, 0, 1);
const IP6_ADDR: Ipv6Address = Ipv6Address::new(0, 0, 0, 0, 0, 0, 0, 1);

/// Creates a smoltcp [`Interface`].
///
/// smoltcp's abstractions allow to directly plug it in a TUN device.
/// As a result, it has all the features you'd expect from a network interface:
/// - Setting IP addresses
/// - Defining routes
///
/// In our implementation, we don't want to use any of that.
/// Our device is entirely backed by in-memory buffers and we and selectively feed IP packets to it.
/// Therefore, we configure it to:
/// - Accept any packet
/// - Define dummy IPs (localhost for IPv4 and IPv6)
/// - Define catch-all routes (0.0.0.0/0) that routes all traffic to the interface
pub fn create_interface(device: &mut InMemoryDevice) -> Interface {
    let mut interface = Interface::new(
        Config::new(HardwareAddress::Ip),
        device,
        smoltcp::time::Instant::ZERO,
    );
    // Accept packets with any destination IP, not just our interface.
    interface.set_any_ip(true);

    // Set our interface IPs. These are just dummies and don't show up anywhere!
    interface.update_ip_addrs(|ips| {
        ips.push(Ipv4Cidr::new(IP4_ADDR, 32).into())
            .expect("should be a valid IPv4 CIDR");
        ips.push(Ipv6Cidr::new(IP6_ADDR, 128).into())
            .expect("should be a valid IPv6 CIDR");
    });

    // Configure catch-all routes, meaning all packets given to `smoltcp` will be routed to our interface.
    interface
        .routes_mut()
        .add_default_ipv4_route(IP4_ADDR)
        .expect("IPv4 default route should fit");
    interface
        .routes_mut()
        .add_default_ipv6_route(IP6_ADDR)
        .expect("IPv6 default route should fit");

    interface
}
