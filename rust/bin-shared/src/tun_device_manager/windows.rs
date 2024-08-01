use anyhow::{Context as _, Result};
use connlib_shared::windows::{CREATE_NO_WINDOW, TUNNEL_NAME};
use firezone_tunnel::Tun;
use ip_network::IpNetwork;
use ip_network::{Ipv4Network, Ipv6Network};
use std::{
    collections::HashSet,
    net::{Ipv4Addr, Ipv6Addr, SocketAddrV4, SocketAddrV6},
    os::windows::process::CommandExt,
    process::{Command, Stdio},
};
use windows::Win32::NetworkManagement::IpHelper::{
    CreateIpForwardEntry2, DeleteIpForwardEntry2, InitializeIpForwardEntry, MIB_IPFORWARD_ROW2,
};

pub struct TunDeviceManager {
    iface_idx: Option<u32>,

    routes: HashSet<IpNetwork>,
}

impl TunDeviceManager {
    // Fallible on Linux
    #[allow(clippy::unnecessary_wraps)]
    pub fn new() -> Result<Self> {
        Ok(Self {
            iface_idx: None,
            routes: HashSet::default(),
        })
    }

    pub fn make_tun(&mut self) -> Result<Tun> {
        let tun = Tun::new()?;
        self.iface_idx = Some(tun.iface_idx());

        Ok(tun)
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
            .status()
            .context("Failed to set IPv4 address")?;

        Command::new("netsh")
            .creation_flags(CREATE_NO_WINDOW)
            .arg("interface")
            .arg("ipv6")
            .arg("set")
            .arg("address")
            .arg(format!("interface=\"{TUNNEL_NAME}\""))
            .arg(format!("address={}", ipv6))
            .stdout(Stdio::null())
            .status()
            .context("Failed to set IPv6 address")?;

        Ok(())
    }

    #[tracing::instrument(level = "trace", skip(self))]
    pub async fn set_routes(&mut self, v4: Vec<Ipv4Network>, v6: Vec<Ipv6Network>) -> Result<()> {
        let iface_idx = self
            .iface_idx
            .context("Cannot set routes without having created TUN device")?;

        let new_routes = HashSet::from_iter(
            v4.into_iter()
                .map(IpNetwork::from)
                .chain(v6.into_iter().map(IpNetwork::from)),
        );

        if new_routes == self.routes {
            return Ok(());
        }

        for new_route in new_routes.difference(&self.routes) {
            add_route(*new_route, iface_idx).context("Failed to add route")?;
        }

        for old_route in self.routes.difference(&new_routes) {
            remove_route(*old_route, iface_idx).context("Failed to remove route")?;
        }

        self.routes = new_routes;

        Ok(())
    }
}

// It's okay if this blocks until the route is added in the OS.
fn add_route(route: IpNetwork, iface_idx: u32) -> Result<()> {
    const DUPLICATE_ERR: u32 = 0x80071392;
    let entry = forward_entry(route, iface_idx);

    // SAFETY: Windows shouldn't store the reference anywhere, it's just a way to pass lots of arguments at once. And no other thread sees this variable.
    match unsafe { CreateIpForwardEntry2(&entry) }.ok() {
        Ok(()) => Ok(()),
        Err(e) if e.code().0 as u32 == DUPLICATE_ERR => {
            tracing::debug!(%route, "Failed to add duplicate route, ignoring");
            Ok(())
        }
        Err(e) => Err(e.into()),
    }
}

// It's okay if this blocks until the route is removed in the OS.
fn remove_route(route: IpNetwork, iface_idx: u32) -> Result<()> {
    let entry = forward_entry(route, iface_idx);

    // SAFETY: Windows shouldn't store the reference anywhere, it's just a way to pass lots of arguments at once. And no other thread sees this variable.
    unsafe { DeleteIpForwardEntry2(&entry) }.ok()?;
    Ok(())
}

fn forward_entry(route: IpNetwork, iface_idx: u32) -> MIB_IPFORWARD_ROW2 {
    let mut row = MIB_IPFORWARD_ROW2::default();
    // SAFETY: Windows shouldn't store the reference anywhere, it's just setting defaults
    unsafe { InitializeIpForwardEntry(&mut row) };

    let prefix = &mut row.DestinationPrefix;
    match route {
        IpNetwork::V4(x) => {
            prefix.PrefixLength = x.netmask();
            prefix.Prefix.Ipv4 = SocketAddrV4::new(x.network_address(), 0).into();
        }
        IpNetwork::V6(x) => {
            prefix.PrefixLength = x.netmask();
            prefix.Prefix.Ipv6 = SocketAddrV6::new(x.network_address(), 0, 0, 0).into();
        }
    }

    row.InterfaceIndex = iface_idx;
    row.Metric = 0;

    row
}
