//! Per-CPU data structures to store relay interface addresses.

use core::net::{Ipv4Addr, Ipv6Addr};

use aya_ebpf::{macros::map, maps::PerCpuArray};

use crate::try_handle_turn::Error;

#[map]
static INT_ADDR_V4: PerCpuArray<[u8; 4]> = PerCpuArray::with_max_entries(1, 0);
#[map]
static INT_ADDR_V6: PerCpuArray<[u8; 16]> = PerCpuArray::with_max_entries(1, 0);
#[map]
static PUBLIC_ADDR_V4: PerCpuArray<[u8; 4]> = PerCpuArray::with_max_entries(1, 0);
#[map]
static PUBLIC_ADDR_V6: PerCpuArray<[u8; 16]> = PerCpuArray::with_max_entries(1, 0);

#[inline(always)]
pub fn interface_ipv4_address() -> Result<Ipv4Addr, Error> {
    get_ip(&INT_ADDR_V4)
}

#[inline(always)]
pub fn interface_ipv6_address() -> Result<Ipv6Addr, Error> {
    get_ip(&INT_ADDR_V6)
}

#[inline(always)]
pub fn public_ipv4_address() -> Result<Ipv4Addr, Error> {
    get_ip(&PUBLIC_ADDR_V4)
}

#[inline(always)]
pub fn public_ipv6_address() -> Result<Ipv6Addr, Error> {
    get_ip(&PUBLIC_ADDR_V6)
}

fn get_ip<const N: usize, T>(array: &PerCpuArray<[u8; N]>) -> Result<T, Error>
where
    T: From<[u8; N]>,
{
    let addr = *array.get(0).ok_or(Error::ArrayIndexOutOfBounds)?;

    if addr == [0u8; N] {
        return Err(Error::IpAddrUnset);
    }

    Ok(T::from(addr))
}
