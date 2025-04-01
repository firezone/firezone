use core::net::Ipv4Addr;

use aya_ebpf::{macros::map, maps::HashMap};

#[map]
static IP4_TO_MAC: HashMap<[u8; 4], [u8; 6]> = HashMap::with_max_entries(0x100, 0);

pub(crate) fn resolve_mac(ip: Ipv4Addr) -> Option<[u8; 6]> {
    unsafe { IP4_TO_MAC.get(&ip.octets()).copied() }
}
