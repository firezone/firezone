use crate::device_channel::ioctl;
use crate::DnsFallbackStrategy;
use connlib_shared::{messages::Interface as InterfaceConfig, Callbacks, Error, Result};
use futures::TryStreamExt;
use ip_network::IpNetwork;
use libc::{
    close, fcntl, open, read, write, F_GETFL, F_SETFL, IFF_MULTI_QUEUE, IFF_NO_PI, IFF_TUN,
    O_NONBLOCK, O_RDWR,
};
use netlink_packet_route::RT_SCOPE_UNIVERSE;
use rtnetlink::{new_connection, Error::NetlinkError, Handle};
use std::{
    io,
    os::fd::{AsRawFd, RawFd},
};

pub(crate) const SIOCGIFMTU: libc::c_ulong = libc::SIOCGIFMTU;

const IFACE_NAME: &str = "tun-firezone";
const TUNSETIFF: u64 = 0x4004_54ca;
const TUN_FILE: &[u8] = b"/dev/net/tun\0";
const RT_PROT_STATIC: u8 = 4;
const DEFAULT_MTU: u32 = 1280;
const FILE_ALREADY_EXISTS: i32 = -17;

#[derive(Debug)]
pub struct Tun {
    handle: Handle,
    connection: tokio::task::JoinHandle<()>,
    interface_index: u32,
    fd: RawFd,
}

impl AsRawFd for Tun {
    fn as_raw_fd(&self) -> RawFd {
        self.fd
    }
}

impl Drop for Tun {
    fn drop(&mut self) {
        unsafe { close(self.fd) };
        self.connection.abort();
    }
}

impl Tun {
    fn write(&self, buf: &[u8]) -> io::Result<usize> {
        match unsafe { write(self.fd, buf.as_ptr() as _, buf.len() as _) } {
            -1 => Err(io::Error::last_os_error()),
            n => Ok(n as usize),
        }
    }

    pub fn write4(&self, buf: &[u8]) -> std::io::Result<usize> {
        self.write(buf)
    }

    pub fn write6(&self, buf: &[u8]) -> io::Result<usize> {
        self.write(buf)
    }

    pub fn read(&self, dst: &mut [u8]) -> std::io::Result<usize> {
        match unsafe { read(self.fd, dst.as_mut_ptr() as _, dst.len()) } {
            -1 => Err(io::Error::last_os_error()),
            n => Ok(n as usize),
        }
    }

    pub async fn new(
        config: &InterfaceConfig,
        cb: &impl Callbacks,
        _: DnsFallbackStrategy,
    ) -> Result<Self> {
        let fd = match unsafe { open(TUN_FILE.as_ptr() as _, O_RDWR) } {
            -1 => return Err(get_last_error()),
            fd => fd,
        };

        // Safety: We just opened the file descriptor.
        unsafe {
            ioctl::exec(fd, TUNSETIFF, &ioctl::Request::<SetTunFlagsPayload>::new())?;
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
            fd,
        };

        this.set_iface_config(config, cb).await?;

        Ok(this)
    }

    pub async fn add_route(&self, route: IpNetwork, _: &impl Callbacks) -> Result<Option<Self>> {
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

    pub fn name(&self) -> &str {
        IFACE_NAME
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

impl ioctl::Request<SetTunFlagsPayload> {
    fn new() -> Self {
        let name_as_bytes = IFACE_NAME.as_bytes();
        debug_assert!(name_as_bytes.len() < libc::IF_NAMESIZE);

        let mut name = [0u8; libc::IF_NAMESIZE];
        name[..name_as_bytes.len()].copy_from_slice(name_as_bytes);

        Self {
            name,
            payload: SetTunFlagsPayload {
                flags: (IFF_TUN | IFF_NO_PI | IFF_MULTI_QUEUE) as _,
            },
        }
    }
}

#[repr(C)]
struct SetTunFlagsPayload {
    flags: std::ffi::c_short,
}
