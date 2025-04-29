use crate::platform::DnsControlMethod;
use anyhow::{Result, bail};

pub async fn new_dns_notifier(
    _tokio_handle: tokio::runtime::Handle,
    _method: DnsControlMethod,
) -> Result<Worker> {
    bail!("Not implemented")
}

pub async fn new_network_notifier(
    _tokio_handle: tokio::runtime::Handle,
    _method: DnsControlMethod,
) -> Result<Worker> {
    bail!("Not implemented")
}

pub struct Worker;

impl Worker {
    pub async fn notified(&mut self) -> Result<()> {
        bail!("Not implemented")
    }

    pub fn close(self) -> Result<()> {
        bail!("Not implemented")
    }
}
