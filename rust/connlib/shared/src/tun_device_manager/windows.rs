use crate::{
    windows::{CREATE_NO_WINDOW, TUNNEL_NAME},
    Cidrv4, Cidrv6,
};
use anyhow::Result;
use std::{
    net::{Ipv4Addr, Ipv6Addr},
    os::windows::process::CommandExt,
    process::{Command, Stdio},
};

pub struct TunDeviceManager {}

impl TunDeviceManager {
    // Fallible on Linux
    #[allow(clippy::unnecessary_wraps)]
    pub fn new() -> Result<Self> {
        Ok(Self {})
    }

    #[tracing::instrument(level = "trace", skip(self))]
    pub async fn set_ips(&mut self, ipv4: Ipv4Addr, ipv6: Ipv6Addr) -> Result<()> {
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

    #[tracing::instrument(level = "trace", skip(self))]
    pub async fn set_routes(&mut self, _: Vec<Cidrv4>, _: Vec<Cidrv6>) -> Result<()> {
        // TODO: Windows still does route updates in `tun_windows.rs`. I can move it up
        // here, but since the Client and Gateway don't know the index of the WinTun
        // interface, I'd have to use the Windows API
        // <https://microsoft.github.io/windows-docs-rs/doc/windows/Win32/NetworkManagement/IpHelper/fn.GetAdaptersAddresses.html>
        unimplemented!()
    }
}
