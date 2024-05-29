use crate::{Cidrv4, Cidrv6};
use anyhow::{Context as _, Result};
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

#[derive(Default)]
pub struct InterfaceManager {}

impl Drop for InterfaceManager {
    fn drop(&mut self) {
        if let Err(error) = crate::windows::dns::deactivate() {
            tracing::error!(?error, "Failed to deactivate DNS control");
        }
    }
}

impl InterfaceManager {
    #[tracing::instrument(level = "trace", skip(self))]
    pub async fn on_set_interface_config(&mut self, ipv4: Ipv4Addr, ipv6: Ipv6Addr) -> Result<()> {
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

        Ok(())
    }

    // async on Linux
    #[allow(clippy::unused_async)]
    pub async fn control_dns(&self, dns_config: Vec<IpAddr>) -> Result<()> {
        crate::windows::dns::change(&dns_config).context("Should be able to control DNS")?;
        Ok(())
    }

    #[tracing::instrument(level = "trace", skip(self))]
    pub async fn on_update_routes(&mut self, _: Vec<Cidrv4>, _: Vec<Cidrv6>) -> Result<()> {
        // TODO: Windows still does route updates in `tun_windows.rs`. I can move it up
        // here, but since the Client and Gateway don't know the index of the WinTun
        // interface, I'd have to use the Windows API
        // <https://microsoft.github.io/windows-docs-rs/doc/windows/Win32/NetworkManagement/IpHelper/fn.GetAdaptersAddresses.html>
        unimplemented!()
    }
}
