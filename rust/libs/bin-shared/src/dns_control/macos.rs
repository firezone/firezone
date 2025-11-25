use std::net::IpAddr;

use super::DnsController;
use anyhow::{Result, bail};
use dns_types::DomainName;

#[derive(clap::ValueEnum, Clone, Copy, Debug, Default)]
pub enum DnsControlMethod {
    #[default]
    None,
}

impl DnsController {
    pub fn deactivate(&mut self) -> Result<()> {
        bail!("Not implemented")
    }

    #[expect(
        clippy::unused_async,
        reason = "Signture must match other operating systems"
    )]
    pub async fn set_dns(
        &mut self,
        _dns_config: Vec<IpAddr>,
        _search_domain: Option<DomainName>,
    ) -> Result<()> {
        bail!("Not implemented")
    }

    pub fn flush(&self) -> Result<()> {
        bail!("Not implemented")
    }
}

pub(crate) fn system_resolvers(_dns_control_method: DnsControlMethod) -> Result<Vec<IpAddr>> {
    bail!("Not implemented")
}
