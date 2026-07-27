use std::{collections::BTreeMap, net::IpAddr};

#[derive(Debug, Clone)]
pub(crate) struct IcmpErrorHosts {
    inner: BTreeMap<IpAddr, IcmpError>,
}

impl IcmpErrorHosts {
    /// Builds from a precomputed IP-to-error map.
    pub(crate) fn from_entries(inner: BTreeMap<IpAddr, IcmpError>) -> Self {
        Self { inner }
    }

    pub(crate) fn icmp_error_for_ip(&self, ip: IpAddr) -> Option<IcmpError> {
        self.inner.get(&ip).copied()
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum IcmpError {
    Network,
    Host,
    Port,
    PacketTooBig { mtu: u32 },
    TimeExceeded { code: u8 },
}
