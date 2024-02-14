use crate::device_channel::ioctl;
use connlib_shared::{
    linux::{DnsControlMethod, ETC_RESOLV_CONF, ETC_RESOLV_CONF_BACKUP},
    messages::Interface as InterfaceConfig,
    Callbacks, Error, Result,
};
use futures::TryStreamExt;
use futures_util::future::BoxFuture;
use futures_util::FutureExt;
use ip_network::IpNetwork;
use libc::{
    close, fcntl, makedev, mknod, open, F_GETFL, F_SETFL, IFF_MULTI_QUEUE, IFF_NO_PI, IFF_TUN,
    O_NONBLOCK, O_RDWR, S_IFCHR,
};
use netlink_packet_route::RT_SCOPE_UNIVERSE;
use parking_lot::Mutex;
use rtnetlink::{new_connection, Error::NetlinkError, Handle};
use std::net::IpAddr;
use std::path::Path;
use std::task::{Context, Poll};
use std::{
    ffi::CStr,
    fmt, fs, io,
    os::{
        fd::{AsRawFd, RawFd},
        unix::fs::PermissionsExt,
    },
};
use tokio::io::{unix::AsyncFd, AsyncWriteExt};

mod utils;

pub(crate) const SIOCGIFMTU: libc::c_ulong = libc::SIOCGIFMTU;

const IFACE_NAME: &str = "tun-firezone";
const TUNSETIFF: libc::c_ulong = 0x4004_54ca;
const TUN_DEV_MAJOR: u32 = 10;
const TUN_DEV_MINOR: u32 = 200;
const RT_PROT_STATIC: u8 = 4;
const DEFAULT_MTU: u32 = 1280;
const FILE_ALREADY_EXISTS: i32 = -17;

// Safety: We know that this is a valid C string.
const TUN_FILE: &CStr = unsafe { CStr::from_bytes_with_nul_unchecked(b"/dev/net/tun\0") };

pub struct Tun {
    handle: Handle,
    connection: tokio::task::JoinHandle<()>,
    fd: AsyncFd<RawFd>,

    worker: Mutex<Option<BoxFuture<'static, Result<()>>>>,
}

impl fmt::Debug for Tun {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Tun")
            .field("handle", &self.handle)
            .field("connection", &self.connection)
            .field("fd", &self.fd)
            .finish_non_exhaustive()
    }
}

impl Drop for Tun {
    fn drop(&mut self) {
        unsafe { close(self.fd.as_raw_fd()) };
        self.connection.abort();
    }
}

impl Tun {
    pub fn write4(&self, buf: &[u8]) -> io::Result<usize> {
        write(self.fd.as_raw_fd(), buf)
    }

    pub fn write6(&self, buf: &[u8]) -> io::Result<usize> {
        write(self.fd.as_raw_fd(), buf)
    }

    pub fn poll_read(&self, buf: &mut [u8], cx: &mut Context<'_>) -> Poll<io::Result<usize>> {
        let mut guard = self.worker.lock();
        if let Some(worker) = guard.as_mut() {
            match worker.poll_unpin(cx) {
                Poll::Ready(Ok(())) => {
                    *guard = None;
                }
                Poll::Ready(Err(e)) => {
                    *guard = None;
                    return Poll::Ready(Err(io::Error::new(io::ErrorKind::Other, e)));
                }
                Poll::Pending => return Poll::Pending,
            }
        }

        utils::poll_raw_fd(&self.fd, |fd| read(fd, buf), cx)
    }

    pub fn new(
        config: &InterfaceConfig,
        dns_config: Vec<IpAddr>,
        _: &impl Callbacks,
    ) -> Result<Self> {
        // TODO: Tech debt: <https://github.com/firezone/firezone/issues/3636>
        // TODO: Gateways shouldn't set up DNS, right? Only clients?
        let dns_control_method = connlib_shared::linux::get_dns_control_from_env();
        tracing::info!(?dns_control_method);

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
                &mut ioctl::Request::<SetTunFlagsPayload>::new(),
            )?;
        }

        set_non_blocking(fd)?;

        let (connection, handle, _) = new_connection()?;
        let join_handle = tokio::spawn(connection);

        Ok(Self {
            handle: handle.clone(),
            connection: join_handle,
            fd: AsyncFd::new(fd)?,
            worker: Mutex::new(Some(
                set_iface_config(config.clone(), dns_config, handle, dns_control_method).boxed(),
            )),
        })
    }

    pub fn add_route(&self, route: IpNetwork, _: &impl Callbacks) -> Result<Option<Self>> {
        let handle = self.handle.clone();

        let add_route_worker = async move {
            let index = handle
                .link()
                .get()
                .match_name(IFACE_NAME.to_string())
                .execute()
                .try_next()
                .await?
                .ok_or(Error::NoIface)?
                .header
                .index;

            let req = handle
                .route()
                .add()
                .output_interface(index)
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
                Ok(_) => Ok(()),
                Err(NetlinkError(err)) if err.raw_code() == FILE_ALREADY_EXISTS => Ok(()),
                // TODO: we should be able to surface this error and handle it depending on
                // if any of the added routes succeeded.
                Err(err) => {
                    tracing::error!(%route, "failed to add route: {err:#?}");
                    Ok(())
                }
            }
        };

        let mut guard = self.worker.lock();
        match guard.take() {
            None => *guard = Some(add_route_worker.boxed()),
            Some(current_worker) => {
                *guard = Some(
                    async move {
                        current_worker.await?;
                        add_route_worker.await?;

                        Ok(())
                    }
                    .boxed(),
                )
            }
        }

        Ok(None)
    }

    pub fn name(&self) -> &str {
        IFACE_NAME
    }
}

#[tracing::instrument(level = "trace", skip(handle))]
async fn set_iface_config(
    config: InterfaceConfig,
    dns_config: Vec<IpAddr>,
    handle: Handle,
    dns_control_method: Option<DnsControlMethod>,
) -> Result<()> {
    let index = handle
        .link()
        .get()
        .match_name(IFACE_NAME.to_string())
        .execute()
        .try_next()
        .await?
        .ok_or(Error::NoIface)?
        .header
        .index;

    let ips = handle
        .address()
        .get()
        .set_link_index_filter(index)
        .execute();

    ips.try_for_each(|ip| handle.address().del(ip).execute())
        .await?;

    handle.link().set(index).mtu(DEFAULT_MTU).execute().await?;

    let res_v4 = handle
        .address()
        .add(index, config.ipv4.into(), 32)
        .execute()
        .await;
    let res_v6 = handle
        .address()
        .add(index, config.ipv6.into(), 128)
        .execute()
        .await;

    handle.link().set(index).up().execute().await?;
    res_v4.or(res_v6)?;

    match dns_control_method {
        None => {}
        Some(DnsControlMethod::EtcResolvConf) => {
            configure_resolv_conf(
                &dns_config,
                Path::new(ETC_RESOLV_CONF),
                Path::new(ETC_RESOLV_CONF_BACKUP),
            )
            .await?
        }
        Some(DnsControlMethod::NetworkManager) => configure_network_manager(&dns_config).await?,
        Some(DnsControlMethod::Systemd) => configure_systemd_resolved(&dns_config).await?,
    }

    Ok(())
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

async fn configure_resolv_conf(
    dns_config: &[IpAddr],
    resolv_path: &Path,
    backup_path: &Path,
) -> Result<()> {
    let text = tokio::fs::read_to_string(resolv_path)
        .await
        .map_err(Error::ReadResolvConf)?;
    let parsed = resolv_conf::Config::parse(&text).map_err(|_| Error::ParseResolvConf)?;

    // Back up the original resolv.conf. If there's already a backup, don't modify it
    match tokio::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(backup_path)
        .await
    {
        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
            tracing::info!(?backup_path, "Backup path already exists, won't overwrite");
        }
        Err(error) => return Err(Error::WriteResolvConfBackup(error)),
        // TODO: Would do a rename-into-place here if the contents of the file mattered more
        Ok(mut f) => f.write_all(text.as_bytes()).await?,
    }

    // TODO: Would do an fsync here if resolv.conf was important and not
    // auto-generated by Docker on every run.

    let mut new_resolv_conf = parsed.clone();
    new_resolv_conf.nameservers = vec![];
    for addr in dns_config {
        new_resolv_conf.nameservers.push((*addr).into());
    }

    // Over-writing `/etc/resolv.conf` actually violates Docker's plan for handling DNS
    // https://docs.docker.com/network/#dns-services
    // But this is just a hack to get a smoke test working in CI for now.
    //
    // Because Docker bind-mounts resolv.conf into the container, (visible in `mount`) we can't
    // use the rename trick to safely update it, nor can we delete it. The best
    // we can do is rewrite it in-place.
    let new_text = format!(
        r"
# Generated by the Firezone client
# The original is at {backup_path:?}
{}
",
        new_resolv_conf
    );

    tokio::fs::write(resolv_path, new_text)
        .await
        .map_err(Error::RewriteResolvConf)?;

    Ok(())
}

async fn configure_network_manager(_dns_config: &[IpAddr]) -> Result<()> {
    Err(Error::Other(
        "DNS control with NetworkManager is not implemented yet",
    ))
}

async fn configure_systemd_resolved(_dns_config: &[IpAddr]) -> Result<()> {
    Err(Error::Other(
        "DNS control with `systemd-resolved` is not implemented yet",
    ))
}

#[repr(C)]
struct SetTunFlagsPayload {
    flags: std::ffi::c_short,
}

#[cfg(test)]
mod tests {
    use std::{
        net::{IpAddr, Ipv4Addr, Ipv6Addr},
        str::FromStr,
    };

    const DEBIAN_VM_RESOLV_CONF: &str = r#"
# This is /run/systemd/resolve/stub-resolv.conf managed by man:systemd-resolved(8).
# Do not edit.
#
# This file might be symlinked as /etc/resolv.conf. If you're looking at
# /etc/resolv.conf and seeing this text, you have followed the symlink.
#
# This is a dynamic resolv.conf file for connecting local clients to the
# internal DNS stub resolver of systemd-resolved. This file lists all
# configured search domains.
#
# Run "resolvectl status" to see details about the uplink DNS servers
# currently in use.
#
# Third party programs should typically not access this file directly, but only
# through the symlink at /etc/resolv.conf. To manage man:resolv.conf(5) in a
# different way, replace this symlink by a static file or a different symlink.
#
# See man:systemd-resolved.service(8) for details about the supported modes of
# operation for /etc/resolv.conf.
nameserver 127.0.0.53
options edns0 trust-ad
search .
"#;

    // Docker seems to have injected the WSL host's resolv.conf into the Alpine container
    // Also the nameserver is changed for privacy
    const ALPINE_CONTAINER_RESOLV_CONF: &str = r#"
# This file was automatically generated by WSL. To stop automatic generation of this file, add the following entry to /etc/wsl.conf:
# [network]
# generateResolvConf = false
nameserver 9.9.9.9
"#;

    // From a Debian desktop
    const NETWORK_MANAGER_RESOLV_CONF: &str = r"
# Generated by NetworkManager
nameserver 192.168.1.1
nameserver 2001:db8::%eno1
";

    #[test]
    fn parse_resolv_conf() {
        let parsed = resolv_conf::Config::parse(DEBIAN_VM_RESOLV_CONF).unwrap();
        let mut config = resolv_conf::Config::new();
        config
            .nameservers
            .push(resolv_conf::ScopedIp::V4(Ipv4Addr::new(127, 0, 0, 53)));
        config.set_search(vec![".".into()]);
        config.edns0 = true;
        config.trust_ad = true;

        assert_eq!(parsed, config);

        let parsed = resolv_conf::Config::parse(ALPINE_CONTAINER_RESOLV_CONF).unwrap();
        let mut config = resolv_conf::Config::new();
        config
            .nameservers
            .push(resolv_conf::ScopedIp::V4(Ipv4Addr::new(9, 9, 9, 9)));

        assert_eq!(parsed, config);

        let parsed = resolv_conf::Config::parse(NETWORK_MANAGER_RESOLV_CONF).unwrap();
        let mut config = resolv_conf::Config::new();
        config
            .nameservers
            .push(resolv_conf::ScopedIp::V4(Ipv4Addr::new(192, 168, 1, 1)));
        config.nameservers.push(resolv_conf::ScopedIp::V6(
            Ipv6Addr::new(
                0x2001, 0x0db8, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000,
            ),
            Some("eno1".into()),
        ));

        assert_eq!(parsed, config);
    }

    #[test]
    fn print_resolv_conf() {
        let mut new_resolv_conf = resolv_conf::Config::new();
        for addr in ["100.100.111.1", "100.100.111.2"] {
            new_resolv_conf
                .nameservers
                .push(IpAddr::from_str(addr).unwrap().into());
        }

        let actual = new_resolv_conf.to_string();
        assert_eq!(
            actual,
            r"nameserver 100.100.111.1
nameserver 100.100.111.2
"
        );
    }
}
