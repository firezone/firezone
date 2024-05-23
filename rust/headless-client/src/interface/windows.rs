use anyhow::Result;
use connlib_shared::{Cidrv4, Cidrv6};
use ip_network::{IpNetwork, Ipv4Network, Ipv6Network};
use std::{
    collections::HashSet,
    net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddrV4, SocketAddrV6},
};
use windows::Win32::NetworkManagement::IpHelper::{
    CreateIpForwardEntry2, DeleteIpForwardEntry2, InitializeIpForwardEntry, MIB_IPFORWARD_ROW2,
};

pub(crate) struct InterfaceManager {
    iface_idx: u32,
    routes: HashSet<IpNetwork>,
}

impl Drop for InterfaceManager {
    fn drop(&mut self) {
        todo!()
    }
}

impl InterfaceManager {
    pub(crate) fn new() -> Result<Self> {
        todo!()
    }

    #[tracing::instrument(level = "trace", skip(self))]
    pub(crate) async fn on_set_interface_config(
        &mut self,
        ipv4: Ipv4Addr,
        ipv6: Ipv6Addr,
        dns_config: Vec<IpAddr>,
    ) -> Result<()> {
        todo!()
    }

    #[tracing::instrument(level = "trace", skip(self))]
    pub(crate) async fn on_update_routes(
        &mut self,
        ipv4: Vec<Cidrv4>,
        ipv6: Vec<Cidrv6>,
    ) -> Result<()> {
        let new_routes: HashSet<IpNetwork> = ipv4
            .into_iter()
            .map(|x| Into::<Ipv4Network>::into(x).into())
            .chain(
                ipv6.into_iter()
                    .map(|x| Into::<Ipv6Network>::into(x).into()),
            )
            .collect();
        if new_routes == self.routes {
            return Ok(());
        }

        for new_route in new_routes.difference(&self.routes) {
            self.add_route(*new_route)?;
        }

        for old_route in self.routes.difference(&new_routes) {
            self.remove_route(*old_route)?;
        }

        // TODO: Might be calling this more often than it needs
        connlib_shared::windows::dns::flush().expect("Should be able to flush Windows' DNS cache");
        self.routes = new_routes;
        Ok(())
    }

    // It's okay if this blocks until the route is added in the OS.
    fn add_route(&self, route: IpNetwork) -> Result<()> {
        const DUPLICATE_ERR: u32 = 0x80071392;
        let entry = self.forward_entry(route);

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
    fn remove_route(&self, route: IpNetwork) -> Result<()> {
        let entry = self.forward_entry(route);

        // SAFETY: Windows shouldn't store the reference anywhere, it's just a way to pass lots of arguments at once. And no other thread sees this variable.
        unsafe { DeleteIpForwardEntry2(&entry) }.ok()?;
        Ok(())
    }

    fn forward_entry(&self, route: IpNetwork) -> MIB_IPFORWARD_ROW2 {
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

        row.InterfaceIndex = self.iface_idx;
        row.Metric = 0;

        row
    }
}
