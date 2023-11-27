use connlib_shared::{
    messages::Interface as InterfaceConfig,
    CallbackErrorFacade, Callbacks,
    Error::{self, OnAddRouteFailed, OnSetInterfaceConfigFailed},
    Result,
};
use futures::task::AtomicWaker;
use ip_network::IpNetwork;
use std::{
    ffi::c_void,
    future::Future,
    iter,
    net::Ipv4Addr,
    pin::Pin,
    sync::Arc,
    task::{Context, Poll},
};
use windows::core::{HRESULT, PCWSTR};
use windows::Win32::{
    Foundation::BOOLEAN,
    Foundation::HANDLE,
    Foundation::NO_ERROR,
    NetworkManagement::IpHelper::{
        AddIPAddress, CreateIpForwardEntry2, DeleteUnicastIpAddressEntry, FreeMibTable,
        GetAdapterIndex, GetIpInterfaceEntry, GetUnicastIpAddressTable, SetIpInterfaceEntry,
        MIB_IPFORWARD_ROW2, MIB_IPINTERFACE_ROW, MIB_UNICASTIPADDRESS_ROW,
        MIB_UNICASTIPADDRESS_TABLE,
    },
    Networking::WinSock::{
        htonl, RouterDiscoveryDisabled, AF_INET, AF_INET6, MIB_IPPROTO_NETMGMT, SOCKADDR_INET,
    },
    System::Threading::{RegisterWaitForSingleObject, INFINITE, WT_EXECUTEINWAITTHREAD},
};

use netsh::set_ipv6_addr;

mod netsh;

const IFACE_NAME: &str = "tun-firezone";
const IFACE_TYPE: &str = "vpn";
// Using static vaue for MTU
const MTU: u32 = 1280;

pub struct IfaceDevice {
    adapter_index: u32,
    mtu: u32,
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

struct ReadFuture<'a> {
    dst: &'a mut [u8],
    waker: Arc<AtomicWaker>,
    // TODO: wintun's require us an `Arc` around `Session` to do a `try_recieve`
    // will get rid of `wintun` crate in a next PR.
    session: &'a Arc<wintun::Session>,
}

impl<'a> Future for ReadFuture<'a> {
    type Output = Result<()>;

    fn poll(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Result<&[u8]>> {
        let this = Pin::into_inner(self);
        // wintun's API require us here to copy a packet
        let recv = this.session.try_receive();
        match recv {
            Ok(None) => {} // No packet available yet
            Ok(Some(pkt)) => {
                this.dst.copy_from_slice(pkt.bytes());
                return Poll::Ready(Ok((this.dst)));
            }
            Err(err) => return Poll::Ready(Err(err.into())),
        };

        this.waker.register(cx.waker());
        let wait_handle = match this.session.get_read_wait_event() {
            Ok(handle) => handle,
            Err(err) => return Poll::Ready(Err(err.into())),
        };

        let mut obj = HANDLE(0isize);

        unsafe {
            RegisterWaitForSingleObject(
                &mut obj,
                // version mismatch :(
                HANDLE(wait_handle.0),
                Some(callback),
                Some(Arc::into_raw(this.waker.clone()) as *const _),
                INFINITE,
                WT_EXECUTEINWAITTHREAD,
            );
        }
        // TODO: CLEANUP!
        Poll::Pending
    }
}

unsafe extern "system" fn callback(ctx: *mut c_void, _: BOOLEAN) {
    Arc::from_raw(ctx as *const AtomicWaker).wake()
}

impl IfaceStream {
    fn write(&self, buf: &[u8]) -> usize {
        let mut packet = self.session.allocate_send_packet(buf.len() as u16).unwrap();
        packet.bytes_mut().copy_from_slice(buf.as_ref());

        // TODO: is this blocking?
        self.session.send_packet(packet);
        buf.len()
    }
    pub fn write4(&self, src: &[u8]) -> usize {
        self.write(src)
    }

    pub fn write6(&self, src: &[u8]) -> usize {
        self.write(src)
    }

    pub fn read(&self, dst: &mut [u8]) -> impl Future<Output = &[u8]> {
        ReadFuture {
            dst,
            waker: Arc::new(AtomicWaker::new()),
            session: &self.session,
        }
    }
}

impl IfaceDevice {
    pub async fn new(
        config: &InterfaceConfig,
        _: &CallbackErrorFacade<impl Callbacks>,
    ) -> Result<(Self, Arc<IfaceStream>)> {
        // Copy the wintun.dll in C:\Windows\System32 & run as Administrator to create network adapters
        // Note: We can use load
        // SAFETY: Safe as long as we have the correct DLL.
        let wt = unsafe { wintun::load()? };

        let adapter = wintun::Adapter::create(&wt, IFACE_NAME, IFACE_TYPE, None)?;
        let session = Arc::new(adapter.start_session(wintun::MAX_RING_CAPACITY)?);

        let mut adapter_index = 0u32;
        // Should we use OsString?
        let adapter_name: Vec<_> = IFACE_NAME.encode_utf16().chain(iter::once(0)).collect();
        // SAFETY: We just opened or created the iface, it must exists
        // We get the index instead of get_guid because then we don't need to rely on undocumented behaviour.
        unsafe {
            GetAdapterIndex(
                // TODO: from_raw vs using PCWSTR(*const _) ???
                PCWSTR::from_raw(adapter_name.as_ptr()),
                &mut adapter_index as *mut _,
            );
        }
        let stream = Arc::new(IfaceStream { session });
        let mut this = Self {
            adapter_index,
            mtu: MTU,
        };
        this.set_iface_config(config).await?;
        Ok((this, stream))
    }

    async fn set_iface_config(&mut self, config: &InterfaceConfig) -> Result<()> {
        // TODO: Need to support IPv6 address assignment
        // Change the interface metric to lowest, ignore error if it fails
        let mut row: MIB_IPINTERFACE_ROW = Default::default();
        row.InterfaceIndex = self.adapter_index;
        // We use this to get/set the MTU and metric, family should be irrelevant
        row.Family = AF_INET;
        unsafe { GetIpInterfaceEntry(&mut row)? };
        row.ManagedAddressConfigurationSupported = BOOLEAN(0);
        row.OtherStatefulConfigurationSupported = BOOLEAN(0);
        row.NlMtu = self.mtu;
        row.UseAutomaticMetric = BOOLEAN(0);
        row.Metric = 0;
        let _ = unsafe { SetIpInterfaceEntry(&mut row) };

        let ipv4_res = set_ipv4_addr(self.adapter_index, config.ipv4);
        let ipv6_res = set_ipv6_addr(self.adapter_index, config.ipv6).await;
        if ipv4_res.is_err() && ipv6_res.is_err() {
            ipv4_res?;
        }
        Ok(())
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
        let mut route_entry = MIB_IPFORWARD_ROW2::default();

        // Fill in the route entry fields
        route_entry.ValidLifetime = u32::MAX;
        route_entry.PreferredLifetime = u32::MAX;
        route_entry.Protocol = MIB_IPPROTO_NETMGMT;
        route_entry.Metric = 0;
        route_entry.InterfaceIndex = self.adapter_index;

        let mut sockaddr_inet: SOCKADDR_INET = Default::default();
        match route {
            IpNetwork::V4(ipnet) => {
                sockaddr_inet.si_family = AF_INET;
                sockaddr_inet.Ipv4.sin_addr.S_un.S_addr =
                    u32::from(ipnet.network_address()).to_be();
                route_entry.DestinationPrefix.Prefix = sockaddr_inet;
            }
            IpNetwork::V6(ipnet) => {
                sockaddr_inet.si_family = AF_INET6;
                sockaddr_inet.Ipv6.sin6_addr.u.Byte = ipnet.network_address().octets();
                route_entry.DestinationPrefix.Prefix = sockaddr_inet;
            }
        }

        route_entry.DestinationPrefix.PrefixLength = route.netmask().into();
        // Create the route entry
        unsafe {
            CreateIpForwardEntry2(&mut route_entry)?;
        }

        Ok(None)
    }

    pub async fn up(&self) -> Result<()> {
        // Adapter is UP after creation
        Ok(())
    }
}

fn set_ipv4_addr(idx: u32, addr: Ipv4Addr) -> Result<()> {
    // Assign IPv4 address to the interface
    const IPV4_NETMASK_32: u32 = 0xFFFFFFFF;
    let mut ip_context = 0u32;
    let mut ip_instance = 0u32;
    let res = unsafe {
        AddIPAddress(
            u32::from(addr).to_be(),
            IPV4_NETMASK_32.to_be(),
            idx,
            &mut ip_context as *mut _,
            &mut ip_instance as *mut _,
        )
    };
    HRESULT::from_win32(res).ok()?;
    Ok(())
}
