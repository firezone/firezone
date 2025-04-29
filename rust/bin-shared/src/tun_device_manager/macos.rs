use std::net::{Ipv4Addr, Ipv6Addr};

use anyhow::{Result, bail};
use ip_network::{Ipv4Network, Ipv6Network};
use tun::Tun;

pub struct TunDeviceManager {}

impl TunDeviceManager {
    pub fn new(_mtu: usize, _num_threads: usize) -> Result<Self> {
        bail!("Not implemented")
    }

    pub fn make_tun(&mut self) -> Result<Box<dyn Tun>> {
        bail!("Not implemented")
    }

    #[expect(
        clippy::unused_async,
        reason = "Signture must match other operating systems"
    )]
    pub async fn set_ips(&mut self, _ipv4: Ipv4Addr, _ipv6: Ipv6Addr) -> Result<()> {
        bail!("Not implemented")
    }

    #[expect(
        clippy::unused_async,
        reason = "Signture must match other operating systems"
    )]
    pub async fn set_routes(
        &mut self,
        _ipv4: Vec<Ipv4Network>,
        _ipv6: Vec<Ipv6Network>,
    ) -> Result<()> {
        bail!("Not implemented")
    }
}
