use crate::device_channel::ioctl;
use connlib_shared::{Error, Result};
use libc::{
    close, fcntl, makedev, mknod, open, F_GETFL, F_SETFL, IFF_MULTI_QUEUE, IFF_NO_PI, IFF_TUN,
    O_NONBLOCK, O_RDWR, S_IFCHR,
};
use std::path::Path;
use std::task::{Context, Poll};
use std::{
    ffi::CStr,
    fs, io,
    os::{
        fd::{AsRawFd, RawFd},
        unix::fs::PermissionsExt,
    },
};
use tokio::io::unix::AsyncFd;

mod utils;

pub(crate) const SIOCGIFMTU: libc::c_ulong = libc::SIOCGIFMTU;
const TUNSETIFF: libc::c_ulong = 0x4004_54ca;
const TUN_DEV_MAJOR: u32 = 10;
const TUN_DEV_MINOR: u32 = 200;

// Safety: We know that this is a valid C string.
const TUN_FILE: &CStr = unsafe { CStr::from_bytes_with_nul_unchecked(b"/dev/net/tun\0") };

#[derive(Debug)]
pub struct Tun {
    // dns_control_method: Option<DnsControlMethod>,
    fd: AsyncFd<RawFd>,
    name: String,
}

impl Drop for Tun {
    fn drop(&mut self) {
        unsafe { close(self.fd.as_raw_fd()) };
    }
}

impl Tun {
    pub fn write4(&self, buf: &[u8]) -> io::Result<usize> {
        write(self.fd.as_raw_fd(), buf)
    }

    pub fn write6(&self, buf: &[u8]) -> io::Result<usize> {
        write(self.fd.as_raw_fd(), buf)
    }

    pub fn poll_read(&mut self, buf: &mut [u8], cx: &mut Context<'_>) -> Poll<io::Result<usize>> {
        // if let Some(worker) = self.worker.as_mut() {
        //     match worker.poll_unpin(cx) {
        //         Poll::Ready(Ok(())) => {
        //             self.worker = None;
        //         }
        //         Poll::Ready(Err(e)) => {
        //             self.worker = None;
        //             return Poll::Ready(Err(io::Error::new(io::ErrorKind::Other, e)));
        //         }
        //         Poll::Pending => return Poll::Pending,
        //     }
        // }

        utils::poll_raw_fd(&self.fd, |fd| read(fd, buf), cx)
    }

    pub fn new(name: &str) -> Result<Self> {
        create_tun_device()?;

        let fd = match unsafe { open(TUN_FILE.as_ptr() as _, O_RDWR) } {
            -1 => return Err(get_last_error()),
            fd => fd,
        };

        // Safety: We just opened the file descriptor.
        unsafe {
            ioctl::exec(
                fd,
                TUNSETIFF,
                &mut ioctl::Request::<SetTunFlagsPayload>::new(name),
            )?;
        }

        set_non_blocking(fd)?;

        Ok(Self {
            name: name.to_owned(),
            fd: AsyncFd::new(fd)?,
        })
    }

    // pub fn set_routes(&mut self, new_routes: HashSet<IpNetwork>, _: &impl Callbacks) -> Result<()> {
    //     if new_routes == self.routes {
    //         return Ok(());
    //     }

    //     let handle = self.handle.clone();
    //     let current_routes = self.routes.clone();
    //     self.routes = new_routes.clone();

    //     let set_routes_worker = async move {
    //         let index = handle
    //             .link()
    //             .get()
    //             .match_name(IFACE_NAME.to_string())
    //             .execute()
    //             .try_next()
    //             .await?
    //             .ok_or(Error::NoIface)?
    //             .header
    //             .index;

    //         for route in new_routes.difference(&current_routes) {
    //             add_route(route, index, &handle).await;
    //         }

    //         for route in current_routes.difference(&new_routes) {
    //             delete_route(route, index, &handle).await;
    //         }

    //         Ok(())
    //     };

    //     // match self.worker.take() {
    //     //     None => self.worker = Some(set_routes_worker.boxed()),
    //     //     Some(current_worker) => {
    //     //         self.worker = Some(
    //     //             async move {
    //     //                 current_worker.await?;
    //     //                 set_routes_worker.await?;

    //     //                 Ok(())
    //     //             }
    //     //             .boxed(),
    //     //         )
    //     //     }
    //     // }

    //     Ok(())
    // }

    pub fn name(&self) -> &str {
        &self.name
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

fn create_tun_device() -> Result<()> {
    let path = Path::new(TUN_FILE.to_str().expect("path is valid utf-8"));

    if path.exists() {
        return Ok(());
    }

    let parent_dir = path.parent().unwrap();
    fs::create_dir_all(parent_dir)?;
    let permissions = fs::Permissions::from_mode(0o751);
    fs::set_permissions(parent_dir, permissions)?;
    if unsafe {
        mknod(
            TUN_FILE.as_ptr() as _,
            S_IFCHR,
            makedev(TUN_DEV_MAJOR, TUN_DEV_MINOR),
        )
    } != 0
    {
        return Err(get_last_error());
    }

    Ok(())
}

/// Read from the given file descriptor in the buffer.
fn read(fd: RawFd, dst: &mut [u8]) -> io::Result<usize> {
    // Safety: Within this module, the file descriptor is always valid.
    match unsafe { libc::read(fd, dst.as_mut_ptr() as _, dst.len()) } {
        -1 => Err(io::Error::last_os_error()),
        n => Ok(n as usize),
    }
}

/// Write the buffer to the given file descriptor.
fn write(fd: RawFd, buf: &[u8]) -> io::Result<usize> {
    // Safety: Within this module, the file descriptor is always valid.
    match unsafe { libc::write(fd, buf.as_ptr() as _, buf.len() as _) } {
        -1 => Err(io::Error::last_os_error()),
        n => Ok(n as usize),
    }
}

impl ioctl::Request<SetTunFlagsPayload> {
    fn new(name: &str) -> Self {
        let name_as_bytes = name.as_bytes();
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
