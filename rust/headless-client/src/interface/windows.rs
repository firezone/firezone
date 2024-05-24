use anyhow::{Context as _, Result};
use connlib_shared::{Cidrv4, Cidrv6};
use std::{
    net::{IpAddr, Ipv4Addr, Ipv6Addr},
    os::windows::process::CommandExt,
    process::{Command, Stdio},
};

// Hides Powershell's console on Windows
// <https://stackoverflow.com/questions/59692146/is-it-possible-to-use-the-standard-library-to-spawn-a-process-without-showing-th#60958956>
const CREATE_NO_WINDOW: u32 = 0x08000000;

// wintun automatically appends " Tunnel" to this
// TODO: De-dupe
const TUNNEL_NAME: &str = "Firezone";

pub(crate) struct InterfaceManager {}

impl Drop for InterfaceManager {
    fn drop(&mut self) {
        if let Err(error) = connlib_shared::windows::dns::deactivate() {
            tracing::error!(?error, "Failed to deactivate DNS control");
        }
    }
}

impl InterfaceManager {
    // Fallible on Linux
    #[allow(clippy::unnecessary_wraps)]
    pub(crate) fn new() -> Result<Self> {
        Ok(Self {})
    }

    #[tracing::instrument(level = "trace", skip(self))]
    pub(crate) async fn on_set_interface_config(
        &mut self,
        ipv4: Ipv4Addr,
        ipv6: Ipv6Addr,
        dns_config: Vec<IpAddr>,
    ) -> Result<()> {
        tracing::debug!("Setting our IPv4 = {}", ipv4);
        tracing::debug!("Setting our IPv6 = {}", ipv6);

        // TODO: See if there's a good Win32 API for this
        // Using netsh directly instead of wintun's `set_network_addresses_tuple` because their code doesn't work for IPv6
        Command::new("netsh")
            .creation_flags(CREATE_NO_WINDOW)
            .arg("interface")
            .arg("ipv4")
            .arg("set")
            .arg("address")
            .arg(format!("name=\"{TUNNEL_NAME}\""))
            .arg("source=static")
            .arg(format!("address={}", ipv4))
            .arg("mask=255.255.255.255")
            .stdout(Stdio::null())
            .status()?;

        Command::new("netsh")
            .creation_flags(CREATE_NO_WINDOW)
            .arg("interface")
            .arg("ipv6")
            .arg("set")
            .arg("address")
            .arg(format!("interface=\"{TUNNEL_NAME}\""))
            .arg(format!("address={}", ipv6))
            .stdout(Stdio::null())
            .status()?;

        connlib_shared::windows::dns::change(&dns_config)
            .context("Should be able to control DNS")?;
        Ok(())
    }

    #[tracing::instrument(level = "trace", skip(self))]
    pub(crate) async fn on_update_routes(&mut self, _: Vec<Cidrv4>, _: Vec<Cidrv6>) -> Result<()> {
        unimplemented!()
    }
}
