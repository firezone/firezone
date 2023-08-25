use futures::TryStreamExt;
use ip_network::IpNetwork;
use libc::{
    close, fcntl, ioctl, open, read, sockaddr, sockaddr_in, write, F_GETFL, F_SETFL,
    IFF_MULTI_QUEUE, IFF_NO_PI, IFF_TUN, IFNAMSIZ, O_NONBLOCK, O_RDWR,
};
use libs_common::{CallbackErrorFacade, Callbacks, Error, Result};
use netlink_packet_route::{rtnl::link::nlas::Nla, RT_SCOPE_UNIVERSE};
use rtnetlink::{new_connection, Handle};
use std::{
    ffi::{c_int, c_short, c_uchar},
    io,
    os::fd::{AsRawFd, RawFd},
    sync::Arc,
};

use super::InterfaceConfig;

#[derive(Debug)]
pub(crate) struct IfaceConfig(pub(crate) Arc<IfaceDevice>);

const IFACE_NAME: &str = "tun-firezone";
const TUNSETIFF: u64 = 0x4004_54ca;
const TUN_FILE: &[u8] = b"/dev/net/tun\0";
const RT_PROT_STATIC: u8 = 4;

#[repr(C)]
union IfrIfru {
    ifru_addr: sockaddr,
    ifru_addr_v4: sockaddr_in,
    ifru_addr_v6: sockaddr_in,
    ifru_dstaddr: sockaddr,
    ifru_broadaddr: sockaddr,
    ifru_flags: c_short,
    ifru_metric: c_int,
    ifru_mtu: c_int,
    ifru_phys: c_int,
    ifru_media: c_int,
    ifru_intval: c_int,
    ifru_wake_flags: u32,
    ifru_route_refcnt: u32,
    ifru_cap: [c_int; 2],
    ifru_functional_type: u32,
}

#[repr(C)]
pub struct ifreq {
    ifr_name: [c_uchar; IFNAMSIZ],
    ifr_ifru: IfrIfru,
}

#[derive(Debug)]
pub struct IfaceDevice {
    fd: RawFd,
    handle: Handle,
    connection: tokio::task::JoinHandle<()>,
    interface_index: u32,
}

impl Drop for IfaceDevice {
    fn drop(&mut self) {
        self.connection.abort();
        unsafe { close(self.fd) };
    }
}

impl AsRawFd for IfaceDevice {
    fn as_raw_fd(&self) -> RawFd {
        self.fd
    }
}

impl IfaceDevice {
    fn write(&self, buf: &[u8]) -> usize {
        match unsafe { write(self.fd, buf.as_ptr() as _, buf.len() as _) } {
            -1 => 0,
            n => n as usize,
        }
    }

    pub async fn new(
        config: &InterfaceConfig,
        _: &CallbackErrorFacade<impl Callbacks>,
    ) -> Result<IfaceDevice> {
        debug_assert!(IFACE_NAME.as_bytes().len() < IFNAMSIZ);

        let fd = match unsafe { open(TUN_FILE.as_ptr() as _, O_RDWR) } {
            -1 => return Err(get_last_error()),
            fd => fd,
        };

        let mut ifr = ifreq {
            ifr_name: [0; IFNAMSIZ],
            ifr_ifru: IfrIfru {
                ifru_flags: (IFF_TUN | IFF_NO_PI | IFF_MULTI_QUEUE) as _,
            },
        };

        ifr.ifr_name[..IFACE_NAME.as_bytes().len()].copy_from_slice(IFACE_NAME.as_bytes());

        if unsafe { ioctl(fd, TUNSETIFF as _, &ifr) } < 0 {
            return Err(get_last_error());
        }

        let (connection, handle, _) = new_connection()?;
        let join_handle = tokio::spawn(connection);
        let interface_index = handle
            .link()
            .get()
            .match_name(IFACE_NAME.to_string())
            .execute()
            .try_next()
            .await?
            .ok_or(Error::NoIface)?
            .header
            .index;

        let mut this = Self {
            fd,
            handle,
            connection: join_handle,
            interface_index,
        };

        this.set_iface_config(config).await?;
        this.set_non_blocking()?;

        Ok(this)
    }

    async fn set_iface_config(&mut self, config: &InterfaceConfig) -> Result<()> {
        let ips = self
            .handle
            .address()
            .get()
            .set_link_index_filter(self.interface_index)
            .execute();

        ips.try_for_each(|ip| self.handle.address().del(ip).execute())
            .await?;

        self.handle
            .address()
            .add(self.interface_index, config.ipv4.into(), 32)
            .execute()
            .await?;

        // TODO: Disable this when ipv6 is disabled
        self.handle
            .address()
            .add(self.interface_index, config.ipv6.into(), 128)
            .execute()
            .await?;

        Ok(())
    }

    fn set_non_blocking(&self) -> Result<()> {
        match unsafe { fcntl(self.fd, F_GETFL) } {
            -1 => Err(get_last_error()),
            flags => match unsafe { fcntl(self.fd, F_SETFL, flags | O_NONBLOCK) } {
                -1 => Err(get_last_error()),
                _ => Ok(()),
            },
        }
    }

    /// Get the current MTU value
    pub async fn mtu(&self) -> Result<usize> {
        while let Ok(Some(msg)) = self
            .handle
            .link()
            .get()
            .match_index(self.interface_index)
            .execute()
            .try_next()
            .await
        {
            for nla in msg.nlas {
                if let Nla::Mtu(mtu) = nla {
                    return Ok(mtu as usize);
                }
            }
        }

        Err(Error::NoMtu)
    }

    pub fn write4(&self, src: &[u8]) -> usize {
        self.write(src)
    }

    pub fn write6(&self, src: &[u8]) -> usize {
        self.write(src)
    }

    pub fn read<'a>(&self, dst: &'a mut [u8]) -> Result<&'a mut [u8]> {
        match unsafe { read(self.fd, dst.as_mut_ptr() as _, dst.len()) } {
            -1 => Err(Error::IfaceRead(io::Error::last_os_error())),
            n => Ok(&mut dst[..n as usize]),
        }
    }
}

fn get_last_error() -> Error {
    Error::Io(io::Error::last_os_error())
}

impl IfaceConfig {
    pub async fn add_route(
        &mut self,
        route: IpNetwork,
        _callbacks: &CallbackErrorFacade<impl Callbacks>,
    ) -> Result<()> {
        let req = self
            .0
            .handle
            .route()
            .add()
            .output_interface(self.0.interface_index)
            .protocol(RT_PROT_STATIC)
            .scope(RT_SCOPE_UNIVERSE);
        match route {
            IpNetwork::V4(ipnet) => {
                req.v4()
                    .destination_prefix(ipnet.network_address(), ipnet.netmask())
                    .execute()
                    .await?
            }
            IpNetwork::V6(ipnet) => {
                req.v6()
                    .destination_prefix(ipnet.network_address(), ipnet.netmask())
                    .execute()
                    .await?
            }
        }
        /*
        TODO: This works for ignoring the error but the route isn't added afterwards
        let's try removing all routes on init for the given interface I think that will work.
        match res {
            Ok(_)
            | Err(rtnetlink::Error::NetlinkError(netlink_packet_core::error::ErrorMessage {
                code: NETLINK_ERROR_FILE_EXISTS,
                ..
            })) => Ok(()),

            Err(err) => Err(err.into()),
        }
        */

        Ok(())
    }

    #[tracing::instrument(level = "trace", skip(self, _callbacks))]
    pub async fn set_iface_config(
        &mut self,
        config: &InterfaceConfig,
        _callbacks: &CallbackErrorFacade<impl Callbacks>,
    ) -> Result<()> {
        let ips = self
            .0
            .handle
            .address()
            .get()
            .set_link_index_filter(self.0.interface_index)
            .execute();

        ips.try_for_each(|ip| self.0.handle.address().del(ip).execute())
            .await?;

        self.0
            .handle
            .address()
            .add(self.0.interface_index, config.ipv4.into(), 32)
            .execute()
            .await?;

        // TODO: Disable this when ipv6 is disabled
        self.0
            .handle
            .address()
            .add(self.0.interface_index, config.ipv6.into(), 128)
            .execute()
            .await?;

        Ok(())
    }

    pub async fn up(&mut self) -> Result<()> {
        self.0
            .handle
            .link()
            .set(self.0.interface_index)
            .up()
            .execute()
            .await?;
        Ok(())
    }
}
