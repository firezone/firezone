use std::net::{Ipv4Addr, Ipv6Addr};

use anyhow::{Result, bail};
use ip_network::{Ipv4Network, Ipv6Network};
use tun::Tun;

use crate::tun_device_manager::TunIpStack;

pub struct TunDeviceManager {}

impl TunDeviceManager {
    pub fn new(_mtu: usize) -> Result<Self> {
        bail!("Not implemented")
    }

    pub fn make_tun(&mut self) -> Result<Box<dyn Tun>> {
        bail!("Not implemented")
    }

    #[expect(
        clippy::unused_async,
        reason = "Signture must match other operating systems"
    )]
    pub async fn set_ips(&mut self, _ipv4: Ipv4Addr, _ipv6: Ipv6Addr) -> Result<TunIpStack> {
        bail!("Not implemented")
    }

    #[expect(
        clippy::unused_async,
        reason = "Signture must match other operating systems"
    )]
    pub async fn set_routes(
        &mut self,
        _ipv4: impl IntoIterator<Item = Ipv4Network>,
        _ipv6: impl IntoIterator<Item = Ipv6Network>,
    ) -> Result<()> {
        bail!("Not implemented")
    }
}
