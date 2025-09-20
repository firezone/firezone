use firezone_telemetry::otel;
use futures::SinkExt as _;
use ip_packet::{IpPacket, IpPacketBuf, IpVersion};
use libc::{AF_INET, AF_INET6, F_GETFL, F_SETFL, O_NONBLOCK, fcntl, iovec, msghdr, recvmsg};
use std::sync::Arc;
use std::task::{Context, Poll};
use std::{
    io,
    os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd},
};
use tokio::sync::mpsc;
use tokio_util::sync::PollSender;

const QUEUE_SIZE: usize = 10_000;

#[derive(Debug)]
pub struct Tun {
    name: String,
    outbound_tx: PollSender<IpPacket>,
    inbound_rx: mpsc::Receiver<IpPacket>,
    _fd: Arc<OwnedFd>, // Keep FD alive and allow safe sharing
}

impl Tun {
    /// Create a new Tun device from an existing file descriptor.
    ///
    /// # Safety
    /// The file descriptor must be valid and open.
    pub unsafe fn from_fd(fd: RawFd) -> io::Result<Self> {
        set_non_blocking(fd)?;
        let name = name(fd)?;

        tracing::info!("Creating TUN device from fd {} ({})", fd, name);

        let (inbound_tx, inbound_rx) = mpsc::channel(QUEUE_SIZE);
        let (outbound_tx, outbound_rx) = mpsc::channel(QUEUE_SIZE);

        tokio::spawn(otel::metrics::periodic_system_queue_length(
            outbound_tx.downgrade(),
            [
                otel::attr::queue_item_ip_packet(),
                otel::attr::network_io_direction_transmit(),
            ],
        ));
        tokio::spawn(otel::metrics::periodic_system_queue_length(
            inbound_tx.downgrade(),
            [
                otel::attr::queue_item_ip_packet(),
                otel::attr::network_io_direction_receive(),
            ],
        ));

        // Create an Arc<OwnedFd> that can be safely shared across threads
        // SAFETY: The caller guarantees that fd is valid and open
        // Note: The threads hold strong references to the FD, but this is OK because:
        // 1. When Tun is dropped, the channels (outbound_rx/inbound_tx) are dropped
        // 2. This causes tun_send/tun_recv to exit when they can't receive/send
        // 3. When threads exit, Arc refcount goes to 0 and FD is properly closed
        let owned_fd = Arc::new(unsafe { OwnedFd::from_raw_fd(fd) });
        let fd_send = Arc::clone(&owned_fd);
        let fd_recv = Arc::clone(&owned_fd);

        std::thread::Builder::new()
            .name("TUN send".to_owned())
            .spawn(move || {
                tracing::info!("TUN send thread started for fd {}", fd_send.as_raw_fd());
                firezone_logging::unwrap_or_warn!(
                    tun::unix::tun_send(fd_send, outbound_rx, write),
                    "Failed to send to TUN device: {}"
                );
                tracing::error!("TUN send thread exited unexpectedly!");
            })
            .map_err(io::Error::other)?;
        std::thread::Builder::new()
            .name("TUN recv".to_owned())
            .spawn(move || {
                tracing::info!("TUN recv thread started for fd {}", fd_recv.as_raw_fd());
                firezone_logging::unwrap_or_warn!(
                    tun::unix::tun_recv(fd_recv, inbound_tx, read),
                    "Failed to recv from TUN device: {}"
                );
                tracing::error!("TUN recv thread exited unexpectedly!");
            })
            .map_err(io::Error::other)?;

        Ok(Tun {
            name,
            outbound_tx: PollSender::new(outbound_tx),
            inbound_rx,
            _fd: owned_fd,
        })
    }

    /// Create a new Tun device by searching for the file descriptor.
    /// This is used when the NetworkExtension has already created the utun interface.
    pub fn new() -> io::Result<Self> {
        tracing::info!("Searching for TUN file descriptor...");
        let fd = search_for_tun_fd()?;
        tracing::info!("Found TUN file descriptor: {}", fd);

        // Verify the FD is actually valid before using it
        let name = name(fd)?;
        tracing::info!("FD {} corresponds to interface: {}", fd, name);

        // SAFETY: We just obtained and verified a valid file descriptor
        unsafe { Self::from_fd(fd) }
    }
}

impl tun::Tun for Tun {
    fn name(&self) -> &str {
        self.name.as_str()
    }

    fn poll_send_ready(&mut self, cx: &mut Context) -> Poll<io::Result<()>> {
        self.outbound_tx
            .poll_ready_unpin(cx)
            .map_err(io::Error::other)
    }

    fn send(&mut self, packet: IpPacket) -> io::Result<()> {
        self.outbound_tx
            .start_send_unpin(packet)
            .map_err(io::Error::other)?;

        Ok(())
    }

    fn poll_recv_many(
        &mut self,
        cx: &mut Context,
        buf: &mut Vec<IpPacket>,
        max: usize,
    ) -> Poll<usize> {
        self.inbound_rx.poll_recv_many(cx, buf, max)
    }
}

fn get_last_error() -> io::Error {
    io::Error::last_os_error()
}

fn set_non_blocking(fd: RawFd) -> io::Result<()> {
    match unsafe { fcntl(fd, F_GETFL) } {
        -1 => Err(get_last_error()),
        flags => match unsafe { fcntl(fd, F_SETFL, flags | O_NONBLOCK) } {
            -1 => Err(get_last_error()),
            _ => Ok(()),
        },
    }
}

fn read(fd: RawFd, dst: &mut IpPacketBuf) -> io::Result<usize> {
    let dst = dst.buf();

    let mut hdr = [0u8; 4];

    let mut iov = [
        iovec {
            iov_base: hdr.as_mut_ptr() as _,
            iov_len: hdr.len(),
        },
        iovec {
            iov_base: dst.as_mut_ptr() as _,
            iov_len: dst.len(),
        },
    ];

    let mut msg_hdr = msghdr {
        msg_name: std::ptr::null_mut(),
        msg_namelen: 0,
        msg_iov: &mut iov[0],
        msg_iovlen: iov.len() as _,
        msg_control: std::ptr::null_mut(),
        msg_controllen: 0,
        msg_flags: 0,
    };

    // Safety: Within this module, the file descriptor is always valid.
    match unsafe { recvmsg(fd, &mut msg_hdr, 0) } {
        -1 => Err(io::Error::last_os_error()),
        0..=4 => Ok(0),
        n => Ok((n - 4) as usize),
    }
}

fn write(fd: RawFd, src: &IpPacket) -> io::Result<usize> {
    let af = match src.version() {
        IpVersion::V4 => AF_INET,
        IpVersion::V6 => AF_INET6,
    };
    let src = src.packet();

    let mut hdr = [0, 0, 0, af];
    let mut iov = [
        iovec {
            iov_base: hdr.as_mut_ptr() as _,
            iov_len: hdr.len(),
        },
        iovec {
            iov_base: src.as_ptr() as _,
            iov_len: src.len(),
        },
    ];

    let msg_hdr = msghdr {
        msg_name: std::ptr::null_mut(),
        msg_namelen: 0,
        msg_iov: &mut iov[0],
        msg_iovlen: iov.len() as _,
        msg_control: std::ptr::null_mut(),
        msg_controllen: 0,
        msg_flags: 0,
    };

    match unsafe { libc::sendmsg(fd, &msg_hdr, 0) } {
        -1 => Err(io::Error::last_os_error()),
        n => Ok(n as usize),
    }
}

#[cfg(any(target_os = "macos", target_os = "ios"))]
fn name(fd: RawFd) -> io::Result<String> {
    use libc::{IF_NAMESIZE, SYSPROTO_CONTROL, UTUN_OPT_IFNAME, getsockopt, socklen_t};

    let mut tunnel_name = [0u8; IF_NAMESIZE];
    let mut tunnel_name_len = tunnel_name.len() as socklen_t;
    if unsafe {
        getsockopt(
            fd,
            SYSPROTO_CONTROL,
            UTUN_OPT_IFNAME,
            tunnel_name.as_mut_ptr() as _,
            &mut tunnel_name_len,
        )
    } < 0
        || tunnel_name_len == 0
    {
        return Err(get_last_error());
    }

    Ok(String::from_utf8_lossy(&tunnel_name[..(tunnel_name_len - 1) as usize]).to_string())
}

#[cfg(any(target_os = "macos", target_os = "ios"))]
fn search_for_tun_fd() -> io::Result<RawFd> {
    const CTL_NAME: &[u8] = b"com.apple.net.utun_control";

    use libc::{AF_SYSTEM, CTLIOCGINFO, ctl_info, getpeername, ioctl, sockaddr_ctl, socklen_t};
    use std::mem::size_of;

    let mut info = ctl_info {
        ctl_id: 0,
        ctl_name: [0; 96],
    };
    info.ctl_name[..CTL_NAME.len()]
        // SAFETY: We only care about maintaining the same byte value not the same value,
        // meaning that the slice &[u8] here is just a blob of bytes for us, we need this conversion
        // just because `c_char` is i8 (for some reason).
        // One thing I don't like about this is that `ctl_name` is actually a nul-terminated string,
        // which we are only getting because `CTRL_NAME` is less than 96 bytes long and we are 0-value
        // initializing the array we should be using a CStr to be explicit... but this is slightly easier.
        .copy_from_slice(unsafe { &*(CTL_NAME as *const [u8] as *const [i8]) });

    // On Apple platforms, we must use a NetworkExtension for reading and writing
    // packets if we want to be allowed in the iOS and macOS App Stores. This has the
    // unfortunate side effect that we're not allowed to create or destroy the tunnel
    // interface ourselves. The file descriptor should already be opened by the NetworkExtension for us
    // by this point. So instead, we iterate through all file descriptors looking for the one corresponding
    // to the utun interface we have access to read and write from.
    //
    // Credit to Jason Donenfeld (@zx2c4) for this technique. See docs/NOTICE.txt for attribution.
    // https://github.com/WireGuard/wireguard-apple/blob/master/Sources/WireGuardKit/WireGuardAdapter.swift
    const MAX_FD_SEARCH: RawFd = 1024;
    tracing::info!("Starting TUN FD search (checking FDs 0-{})", MAX_FD_SEARCH);
    for fd in 0..MAX_FD_SEARCH {
        tracing::trace!("Checking fd {}", fd);

        // initialize empty sockaddr_ctl to be populated by getpeername
        let mut addr = sockaddr_ctl {
            sc_len: size_of::<sockaddr_ctl>() as u8,
            sc_family: 0,
            ss_sysaddr: 0,
            sc_id: info.ctl_id,
            sc_unit: 0,
            sc_reserved: Default::default(),
        };

        let mut len = size_of::<sockaddr_ctl>() as u32;
        let ret = unsafe {
            getpeername(
                fd,
                &mut addr as *mut sockaddr_ctl as _,
                &mut len as *mut socklen_t,
            )
        };
        if ret != 0 || addr.sc_family != AF_SYSTEM as u8 {
            continue;
        }

        if info.ctl_id == 0 {
            let ret = unsafe { ioctl(fd, CTLIOCGINFO, &mut info as *mut ctl_info) };

            if ret != 0 {
                continue;
            }
        }

        if addr.sc_id == info.ctl_id {
            tracing::info!("Found utun control socket at fd {}", fd);

            // Get the interface name to verify it's the right one
            let interface_name = name(fd)?;
            tracing::info!("FD {} corresponds to interface: {}", fd, interface_name);

            // Verify this is actually utun7 or the expected interface
            if !interface_name.starts_with("utun") {
                tracing::warn!(
                    "FD {} is not a utun interface ({}), skipping",
                    fd,
                    interface_name
                );
                continue;
            }

            set_non_blocking(fd)?;
            tracing::info!(
                "Successfully configured {} (fd {}) for packet I/O",
                interface_name,
                fd
            );

            return Ok(fd);
        }
    }

    tracing::error!("Failed to find TUN file descriptor after checking all FDs");
    Err(io::Error::new(
        io::ErrorKind::NotFound,
        "Could not find utun control socket file descriptor",
    ))
}

#[cfg(not(any(target_os = "macos", target_os = "ios")))]
fn search_for_tun_fd() -> io::Result<RawFd> {
    unimplemented!("search_for_tun_fd is only available on macOS/iOS")
}

#[cfg(not(any(target_os = "macos", target_os = "ios")))]
fn name(_: RawFd) -> io::Result<String> {
    unimplemented!("name is only available on macOS/iOS")
}
