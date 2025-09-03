//! Per-CPU data structures to learn relay interface addresses

use core::net::{Ipv4Addr, Ipv6Addr};

use aya_ebpf::{macros::map, maps::PerCpuArray};
use ebpf_shared::{InterfaceAddressV4, InterfaceAddressV6};

use crate::try_handle_turn::Error;

#[map]
static INT_ADDR_V4: PerCpuArray<InterfaceAddressV4> = PerCpuArray::with_max_entries(1, 0);
#[map]
static INT_ADDR_V6: PerCpuArray<InterfaceAddressV6> = PerCpuArray::with_max_entries(1, 0);

#[inline(always)]
pub fn get_interface_ipv4_address() -> Result<Ipv4Addr, Error> {
    let interface_addr = INT_ADDR_V4
        .get_ptr_mut(0)
        .ok_or(Error::InterfaceIpv4AddressAccessFailed)?;

    // SAFETY: This comes from a per-cpu data structure so we can safely access it.
    let addr = unsafe { *interface_addr };

    addr.get().ok_or(Error::InterfaceIpv4AddressNotConfigured)
}

pub fn get_interface_ipv6_address() -> Result<Ipv6Addr, Error> {
    let interface_addr = INT_ADDR_V6
        .get_ptr_mut(0)
        .ok_or(Error::InterfaceIpv6AddressAccessFailed)?;

    // SAFETY: This comes from a per-cpu data structure so we can safely access it.
    let addr = unsafe { *interface_addr };

    addr.get().ok_or(Error::InterfaceIpv6AddressNotConfigured)
}
