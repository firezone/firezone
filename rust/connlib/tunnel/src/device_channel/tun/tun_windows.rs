use connlib_shared::{
    messages::Interface as InterfaceConfig,
    CallbackErrorFacade, Callbacks,
    Error::{self, OnAddRouteFailed, OnSetInterfaceConfigFailed},
    Result,
};
use ip_network::IpNetwork;
use std::sync::Arc;
use windows::Win32::{
    Foundation::BOOLEAN,
    Foundation::NO_ERROR,
    NetworkManagement::IpHelper::{
        AddIPAddress, CreateIpForwardEntry2, DeleteUnicastIpAddressEntry, FreeMibTable,
        GetIpInterfaceEntry, GetUnicastIpAddressTable, SetIpInterfaceEntry, MIB_IPFORWARD_ROW2,
        MIB_IPINTERFACE_ROW, MIB_UNICASTIPADDRESS_ROW, MIB_UNICASTIPADDRESS_TABLE,
    },
    Networking::WinSock::{
        htonl, RouterDiscoveryDisabled, AF_INET, MIB_IPPROTO_NETMGMT, SOCKADDR_INET,
    },
};

const IFACE_NAME: &str = "tun-firezone";
// Using static vaue for MTU
const MTU: u32 = 1280;

pub struct IfaceDevice {
    adapter_index: u32,
    mtu: u32,
    ipv4_address: u32,
    ip_context: u32,
    ip_instance: u32,
}

pub struct IfaceStream {
    session: Arc<wintun::Session>,
}

impl Drop for IfaceStream {
    fn drop(&mut self) {
        // Cancel read operation
        let _ = self.session.shutdown();
    }
}

impl IfaceStream {
    fn write(&self, buf: &[u8]) -> usize {
        let mut packet = self.session.allocate_send_packet(buf.len() as u16).unwrap();
        packet.bytes_mut().copy_from_slice(buf.as_ref());

        self.session.send_packet(packet);
        buf.len()
    }
    pub fn write4(&self, src: &[u8]) -> usize {
        self.write(src)
    }

    pub fn write6(&self, src: &[u8]) -> usize {
        self.write(src)
    }

    pub async fn read<'a>(&self, dst: &'a mut [u8]) -> Result<&'a mut [u8]> {
        let reader_session = self.session.clone();

        let result = tokio::task::spawn_blocking(move || reader_session.receive_blocking()).await;
        match result.unwrap() {
            Ok(packet) => {
                let bytes = packet.bytes();
                let len = bytes.len();

                let copy_len = std::cmp::min(len, dst.len());
                dst[..copy_len].copy_from_slice(&bytes[..copy_len]);

                Ok(&mut dst[..copy_len])
            }
            Err(err) => Err(Error::IfaceRead(std::io::Error::new(
                std::io::ErrorKind::Other,
                err,
            ))),
        }
    }
}

impl IfaceDevice {
    pub async fn new(
        config: &InterfaceConfig,
        _: &CallbackErrorFacade<impl Callbacks>,
    ) -> Result<(Self, Arc<IfaceStream>)> {
        //Copy the wintun.dll in C:\Windows\System32 & run as Administrator to create network adapters
        let wt = unsafe {
            wintun::load_from_path("wintun.dll")
                .map_err(|err| OnSetInterfaceConfigFailed(err.to_string()))
        }?;

        let adapter = match wintun::Adapter::open(&wt, IFACE_NAME) {
            Ok(a) => a,
            Err(_) => wintun::Adapter::create(&wt, IFACE_NAME, "vpn", None)
                .map_err(|err| OnSetInterfaceConfigFailed(err.to_string()))?,
        };
        let session = Arc::new(adapter.start_session(wintun::MAX_RING_CAPACITY).unwrap());

        let adapter_index = adapter.get_adapter_index().unwrap();
        let stream = Arc::new(IfaceStream { session });
        let mut this = Self {
            adapter_index,
            mtu: MTU,
            ipv4_address: 0,
            ip_context: 0,
            ip_instance: 0,
        };
        this.set_iface_config(config)?;
        Ok((this, stream))
    }

    fn set_iface_config(&mut self, config: &InterfaceConfig) -> Result<()> {
        // Delete all existing assigned addresses
        unsafe {
            let mut table: *mut MIB_UNICASTIPADDRESS_TABLE = std::ptr::null_mut();
            let table_ptr: *mut *mut MIB_UNICASTIPADDRESS_TABLE = &mut table;
            let ret = GetUnicastIpAddressTable(AF_INET, table_ptr);

            if ret.is_ok() && !table.is_null() {
                let num_entries = (*table).NumEntries;
                let table_slice: &mut [MIB_UNICASTIPADDRESS_ROW] =
                    std::slice::from_raw_parts_mut(&mut (*table).Table[0], num_entries as usize);

                for entry in table_slice.iter_mut() {
                    let interface_index = entry.InterfaceIndex;
                    if interface_index == self.adapter_index {
                        let _ = DeleteUnicastIpAddressEntry(entry);
                    }
                }
                let _ = FreeMibTable(table as *const _);
            }
        }
        // TODO: Need to support IPv6 address assignment
        return self.set_iface_ipv4(config);
    }

    fn set_iface_ipv4(&mut self, config: &InterfaceConfig) -> Result<()> {
        // Change the interface metric to lowest, ignore error if it fails
        unsafe {
            let mut row: MIB_IPINTERFACE_ROW = Default::default();
            row.InterfaceIndex = self.adapter_index;
            row.Family = AF_INET; // IPv4
            let ret = GetIpInterfaceEntry(&mut row);
            if ret.is_ok() {
                if row.SitePrefixLength > 32 {
                    row.SitePrefixLength = 0
                }
                row.RouterDiscoveryBehavior = RouterDiscoveryDisabled;
                row.DadTransmits = 0;
                row.ManagedAddressConfigurationSupported = BOOLEAN(0);
                row.OtherStatefulConfigurationSupported = BOOLEAN(0);
                row.NlMtu = self.mtu;
                row.UseAutomaticMetric = BOOLEAN(0);
                row.Metric = 0;
                let _ = SetIpInterfaceEntry(&mut row);
            }
        }

        // Assign IPv4 address to the interface
        unsafe {
            const IPV4_NETMASK_32: u32 = 0xFFFFFFFF;
            self.ipv4_address = htonl(config.ipv4.into());
            let result = AddIPAddress(
                htonl(config.ipv4.into()),
                IPV4_NETMASK_32,
                self.adapter_index,
                &mut self.ip_context,
                &mut self.ip_instance,
            );
            if result != NO_ERROR.0 {
                return Err(OnSetInterfaceConfigFailed(format!(
                    "AddIPAddress failed with error code: {}",
                    result
                )));
            }
            Ok(())
        }
    }

    /// Get the current MTU value
    pub async fn mtu(&self) -> Result<usize> {
        Ok(self.mtu as usize)
    }

    pub async fn add_route(
        &self,
        route: IpNetwork,
        _callbacks: &CallbackErrorFacade<impl Callbacks>,
    ) -> Result<Option<(Self, Arc<IfaceStream>)>> {
        match route {
            IpNetwork::V4(ipnet) => {
                let mut route: MIB_IPFORWARD_ROW2 = Default::default();

                // Fill in the route entry fields
                route.ValidLifetime = u32::MAX;
                route.PreferredLifetime = u32::MAX;
                route.Protocol = MIB_IPPROTO_NETMGMT;
                route.Metric = 0;
                route.InterfaceIndex = self.adapter_index;

                let mut sockaddr_inet: SOCKADDR_INET = Default::default();
                sockaddr_inet.si_family = AF_INET;
                sockaddr_inet.Ipv4.sin_addr.S_un.S_addr =
                    unsafe { htonl(ipnet.network_address().into()) };
                route.DestinationPrefix.Prefix = sockaddr_inet;
                route.DestinationPrefix.PrefixLength = ipnet.netmask().into();

                // Create the route entry
                unsafe {
                    CreateIpForwardEntry2(&mut route)
                        .map_err(|err| OnAddRouteFailed(err.to_string()))?
                };
                Ok(None)
            }
            IpNetwork::V6(_) => Err(OnAddRouteFailed(format!("Not implemented"))),
        }
    }

    pub async fn up(&self) -> Result<()> {
        // Adapter is UP after creation
        Ok(())
    }
}
