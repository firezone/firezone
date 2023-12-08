use connlib_shared::{messages::Interface as InterfaceConfig, Callbacks, Error, Result};
use futures::TryStreamExt;
use ip_network::IpNetwork;
use libc::{
    close, fcntl, ioctl, open, read, sockaddr, sockaddr_in, write, F_GETFL, F_SETFL,
    IFF_MULTI_QUEUE, IFF_NO_PI, IFF_TUN, IFNAMSIZ, O_NONBLOCK, O_RDWR,
};
use netlink_packet_route::{rtnl::link::nlas::Nla, RT_SCOPE_UNIVERSE};
use rtnetlink::{new_connection, Error::NetlinkError, Handle};
use std::{
    ffi::{c_int, c_short, c_uchar},
    io,
    os::fd::{AsRawFd, RawFd},
    sync::Arc,
};
use tokio::io::unix::AsyncFd;

use crate::DnsFallbackStrategy;

const IFACE_NAME: &str = "tun-firezone";
const TUNSETIFF: u64 = 0x4004_54ca;
const TUN_FILE: &[u8] = b"/dev/net/tun\0";
const RT_PROT_STATIC: u8 = 4;
const DEFAULT_MTU: u32 = 1280;
const FILE_ALREADY_EXISTS: i32 = -17;

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
    handle: Handle,
    connection: tokio::task::JoinHandle<()>,
    interface_index: u32,
}

#[derive(Debug)]
pub struct IfaceStream(RawFd);

impl AsRawFd for IfaceStream {
    fn as_raw_fd(&self) -> RawFd {
        self.0
    }
}

impl Drop for IfaceStream {
    fn drop(&mut self) {
        unsafe { close(self.0) };
    }
}

impl Drop for IfaceDevice {
    fn drop(&mut self) {
        self.connection.abort();
    }
}

impl IfaceStream {
    fn write(&self, buf: &[u8]) -> std::io::Result<usize> {
        match unsafe { write(self.0, buf.as_ptr() as _, buf.len() as _) } {
            -1 => Err(io::Error::last_os_error()),
            n => Ok(n as usize),
        }
    }

    pub fn write4(&self, buf: &[u8]) -> std::io::Result<usize> {
        self.write(buf)
    }

    pub fn write6(&self, buf: &[u8]) -> std::io::Result<usize> {
        self.write(buf)
    }

    pub fn read(&self, dst: &mut [u8]) -> std::io::Result<usize> {
        match unsafe { read(self.0, dst.as_mut_ptr() as _, dst.len()) } {
            -1 => Err(io::Error::last_os_error()),
            n => Ok(n as usize),
        }
    }
}

impl IfaceDevice {
    pub async fn new(
        config: &InterfaceConfig,
        cb: &impl Callbacks,
        _: DnsFallbackStrategy,
    ) -> Result<(Self, Arc<AsyncFd<IfaceStream>>)> {
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

        set_non_blocking(fd)?;

        let this = Self {
            handle,
            connection: join_handle,
            interface_index,
        };

        this.set_iface_config(config, cb).await?;

        Ok((this, Arc::new(AsyncFd::new(IfaceStream(fd))?)))
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

    pub async fn add_route(
        &self,
        route: IpNetwork,
        _: &impl Callbacks,
    ) -> Result<Option<(Self, Arc<AsyncFd<IfaceStream>>)>> {
        let req = self
            .handle
            .route()
            .add()
            .output_interface(self.interface_index)
            .protocol(RT_PROT_STATIC)
            .scope(RT_SCOPE_UNIVERSE);
        let res = match route {
            IpNetwork::V4(ipnet) => {
                req.v4()
                    .destination_prefix(ipnet.network_address(), ipnet.netmask())
                    .execute()
                    .await
            }
            IpNetwork::V6(ipnet) => {
                req.v6()
                    .destination_prefix(ipnet.network_address(), ipnet.netmask())
                    .execute()
                    .await
            }
        };

        match res {
            Ok(_) => Ok(None),
            Err(NetlinkError(err)) if err.raw_code() == FILE_ALREADY_EXISTS => Ok(None),
            Err(err) => Err(err.into()),
        }
    }

    #[tracing::instrument(level = "trace", skip(self))]
    pub async fn set_iface_config(
        &self,
        config: &InterfaceConfig,
        _: &impl Callbacks,
    ) -> Result<()> {
        let ips = self
            .handle
            .address()
            .get()
            .set_link_index_filter(self.interface_index)
            .execute();

        ips.try_for_each(|ip| self.handle.address().del(ip).execute())
            .await?;

        self.handle
            .link()
            .set(self.interface_index)
            .mtu(DEFAULT_MTU)
            .execute()
            .await?;

        let res_v4 = self
            .handle
            .address()
            .add(self.interface_index, config.ipv4.into(), 32)
            .execute()
            .await;
        let res_v6 = self
            .handle
            .address()
            .add(self.interface_index, config.ipv6.into(), 128)
            .execute()
            .await;

        Ok(res_v4.or(res_v6)?)
    }

    pub async fn up(&self) -> Result<()> {
        self.handle
            .link()
            .set(self.interface_index)
            .up()
            .execute()
            .await?;
        Ok(())
    }
}

fn get_last_error() -> Error {
    Error::Io(io::Error::last_os_error())
}

fn set_non_blocking(fd: RawFd) -> Result<()> {
    match unsafe { fcntl(fd, F_GETFL) } {
        -1 => Err(get_last_error()),
        flags => match unsafe { fcntl(fd, F_SETFL, flags | O_NONBLOCK) } {
            -1 => Err(get_last_error()),
            _ => Ok(()),
        },
    }
}
