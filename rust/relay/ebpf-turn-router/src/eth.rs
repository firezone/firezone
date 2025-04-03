use aya_ebpf::programs::XdpContext;
use aya_ebpf::{macros::map, maps::HashMap};
use network_types::eth::{EthHdr, EtherType};

use core::net::{IpAddr, Ipv4Addr, Ipv6Addr};

use crate::{error::Error, slice_mut_at::slice_mut_at};

const MAX_ETHERNET_MAPPINGS: u32 = 0x100000;

pub struct Eth<'a> {
    inner: &'a mut EthHdr,
}

impl<'a> Eth<'a> {
    #[inline(always)]
    pub fn parse(ctx: &'a XdpContext) -> Result<Self, Error> {
        Ok(Self {
            inner: slice_mut_at::<EthHdr>(ctx, 0)?,
        })
    }

    pub fn ether_type(&self) -> EtherType {
        self.inner.ether_type
    }

    pub fn src(&self) -> [u8; 6] {
        self.inner.src_addr
    }

    pub fn dst(&self) -> [u8; 6] {
        self.inner.dst_addr
    }

    /// Update the Ethernet header with the appropriate destination MAC address based on the new destination IP.
    pub fn update(self, new_dst_ip: impl Into<IpAddr>) -> Result<(), Error> {
        let ip_addr = new_dst_ip.into();
        let new_dst_mac = match ip_addr {
            IpAddr::V4(ip) => get_mac_for_ipv4(ip).ok_or(Error::NoMacAddress(ip_addr))?,
            IpAddr::V6(ip) => get_mac_for_ipv6(ip).ok_or(Error::NoMacAddress(ip_addr))?,
        };

        self.inner.src_addr = self.inner.dst_addr;
        self.inner.dst_addr = new_dst_mac;

        Ok(())
    }
}

#[map]
static IP4_TO_MAC: HashMap<[u8; 4], [u8; 6]> = HashMap::with_max_entries(MAX_ETHERNET_MAPPINGS, 0);

#[map]
static IP6_TO_MAC: HashMap<[u8; 16], [u8; 6]> = HashMap::with_max_entries(MAX_ETHERNET_MAPPINGS, 0);

pub(crate) fn get_mac_for_ipv4(ip: Ipv4Addr) -> Option<[u8; 6]> {
    unsafe { IP4_TO_MAC.get(&ip.octets()).copied() }
}

pub(crate) fn get_mac_for_ipv6(ip: Ipv6Addr) -> Option<[u8; 6]> {
    unsafe { IP6_TO_MAC.get(&ip.octets()).copied() }
}

pub(crate) fn save_mac_for_ipv4(ip: Ipv4Addr, mac: [u8; 6]) {
    let _ = IP4_TO_MAC.insert(&ip.octets(), &mac, 0);
}

pub(crate) fn save_mac_for_ipv6(ip: Ipv6Addr, mac: [u8; 6]) {
    let _ = IP6_TO_MAC.insert(&ip.octets(), &mac, 0);
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Memory overhead of an eBPF map.
    ///
    /// Determined empirically.
    const HASH_MAP_OVERHEAD: f32 = 1.5;

    #[test]
    fn hashmaps_are_less_than_100_mb() {
        let ipv4_datatypes = 4 + 6;
        let ipv6_datatypes = 16 + 6;

        let ipv4_map_size =
            ipv4_datatypes as f32 * MAX_ETHERNET_MAPPINGS as f32 * HASH_MAP_OVERHEAD;
        let ipv6_map_size =
            ipv6_datatypes as f32 * MAX_ETHERNET_MAPPINGS as f32 * HASH_MAP_OVERHEAD;

        let total_map_size = (ipv4_map_size + ipv6_map_size) * 2_f32;
        let total_map_size_mb = total_map_size / 1024_f32 / 1024_f32;

        assert!(
            total_map_size_mb < 100_f32,
            "Map size is {total_map_size_mb} MB"
        );
    }
}
