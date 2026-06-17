use ip_packet::{IpPacket, IpPacketBuf, IpVersion};
use libc::{AF_INET, AF_INET6, F_GETFL, F_SETFL, O_NONBLOCK, fcntl, iovec, msghdr, recvmsg};
use std::{
    io,
    os::fd::{AsRawFd as _, RawFd},
};
use telemetry::otel;
use tokio::sync::mpsc;

const QUEUE_SIZE: usize = 10_000;

/// Receive buffer we request for the utun control socket via `SO_RCVBUF`.
///
/// The kernel default (`ctl_recvsize`) is 512 KiB, only a few hundred MTU-sized
/// packets, after which inbound packets are backpressured. A larger buffer lets the kernel
/// queue more while we drain it. 8 MiB matches the default `kern.ipc.maxsockbuf`
/// ceiling — the most the kernel grants without raising that system-wide limit.
const RECV_BUFFER_SIZE: libc::c_int = if cfg!(target_os = "ios") {
    2 * 1024 * 1024
} else {
    8 * 1024 * 1024
};

/// How many packets the kernel may park in the socket receive buffer before it pauses
/// the interface's output queue until we read them.
///
/// XNU defaults this to 1, so every packet costs a full read + flow-control roundtrip
/// before the kernel hands us the next one. We size it to [`RECV_BUFFER_SIZE`] at the
/// TUN MTU ([`ip_packet::MAX_IP_SIZE`]), rounded up to a power of two, leaving the byte
/// buffer as the limit that actually governs how much is queued.
const MAX_PENDING_PACKETS: u32 =
    (RECV_BUFFER_SIZE as u32 / ip_packet::MAX_IP_SIZE as u32).next_power_of_two();

/// From XNU's `bsd/net/if_utun.h`.
const UTUN_OPT_MAX_PENDING_PACKETS: libc::c_int = 16;

pub struct Tun {
    name: String,
    outbound_tx: mpsc::Sender<IpPacket>,
    inbound_rx: mpsc::Receiver<IpPacket>,
}

impl Tun {
    pub fn new(runtime: &tokio::runtime::Handle) -> io::Result<Self> {
        let fd = search_for_tun_fd()?;
        set_non_blocking(fd)?;
        Self::from_fd_inner(fd, runtime)
    }

    /// Create a new [`Tun`] from a raw file descriptor.
    ///
    /// # Safety
    ///
    /// - The file descriptor must be open.
    /// - The file descriptor must not get closed by anyone else.
    /// - On iOS/macOS, the NetworkExtension owns the fd, so we don't take ownership.
    pub unsafe fn from_fd(fd: RawFd, runtime: &tokio::runtime::Handle) -> io::Result<Self> {
        set_non_blocking(fd)?;
        Self::from_fd_inner(fd, runtime)
    }

    fn from_fd_inner(fd: RawFd, runtime: &tokio::runtime::Handle) -> io::Result<Self> {
        let name = name(fd)?;

        raise_recv_buffer(fd);
        raise_max_pending_packets(fd);

        let (inbound_tx, inbound_rx) = mpsc::channel(QUEUE_SIZE);
        let (outbound_tx, outbound_rx) = mpsc::channel(QUEUE_SIZE);

        runtime.spawn(otel_instruments::periodic_system_queue_length(
            outbound_tx.downgrade(),
            [
                otel::attr::queue_item_ip_packet(),
                otel::attr::network_io_direction_transmit(),
            ],
        ));
        runtime.spawn(otel_instruments::periodic_system_queue_length(
            inbound_tx.downgrade(),
            [
                otel::attr::queue_item_ip_packet(),
                otel::attr::network_io_direction_receive(),
            ],
        ));

        // Use Apple's batched syscalls when available, falling back to the per-packet
        // path otherwise. They are present on all supported OS versions, so the fallback
        // is not expected to be taken.
        match super::sys::batch_syscalls() {
            Some(syscalls) => {
                tracing::info!("Using batched TUN I/O (recvmsg_x/sendmsg_x)");

                std::thread::Builder::new()
                    .name("TUN send".to_owned())
                    .spawn(move || {
                        logging::unwrap_or_warn!(
                            super::batched::tun_send_batched(fd, syscalls, outbound_rx),
                            "Failed to send to TUN device: {}"
                        )
                    })
                    .map_err(io::Error::other)?;
                std::thread::Builder::new()
                    .name("TUN recv".to_owned())
                    .spawn(move || {
                        logging::unwrap_or_warn!(
                            super::batched::tun_recv_batched(fd, syscalls, inbound_tx),
                            "Failed to recv from TUN device: {}"
                        )
                    })
                    .map_err(io::Error::other)?;
            }
            None => {
                tracing::info!("Batched TUN I/O unavailable; using per-packet I/O");

                std::thread::Builder::new()
                    .name("TUN send".to_owned())
                    .spawn(move || {
                        logging::unwrap_or_warn!(
                            tun::unix::tun_send(fd, outbound_rx, write),
                            "Failed to send to TUN device: {}"
                        )
                    })
                    .map_err(io::Error::other)?;
                std::thread::Builder::new()
                    .name("TUN recv".to_owned())
                    .spawn(move || {
                        logging::unwrap_or_warn!(
                            tun::unix::tun_recv(fd, inbound_tx, read),
                            "Failed to recv from TUN device: {}"
                        )
                    })
                    .map_err(io::Error::other)?;
            }
        }

        Ok(Tun {
            name,
            outbound_tx,
            inbound_rx,
        })
    }
}

impl tun::Tun for Tun {
    fn sender(&self) -> &mpsc::Sender<IpPacket> {
        &self.outbound_tx
    }

    fn receiver(&mut self) -> &mut mpsc::Receiver<IpPacket> {
        &mut self.inbound_rx
    }

    fn name(&self) -> &str {
        self.name.as_str()
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

/// Raises the limit of packets the kernel buffers on the utun socket so it can run
/// ahead of our reads instead of in lock-step.
fn raise_max_pending_packets(fd: RawFd) {
    let mut current = 0u32;
    let mut len = size_of::<u32>() as libc::socklen_t;

    // Safety: Within this module, the file descriptor is always valid.
    if unsafe {
        libc::getsockopt(
            fd,
            libc::SYSPROTO_CONTROL,
            UTUN_OPT_MAX_PENDING_PACKETS,
            &mut current as *mut u32 as _,
            &mut len,
        )
    } < 0
    {
        tracing::warn!(error = %get_last_error(), "Failed to get `UTUN_OPT_MAX_PENDING_PACKETS`");
        return;
    }

    tracing::debug!(current, "Queried `UTUN_OPT_MAX_PENDING_PACKETS`");

    if current >= MAX_PENDING_PACKETS {
        return;
    }

    // Safety: Within this module, the file descriptor is always valid.
    if unsafe {
        libc::setsockopt(
            fd,
            libc::SYSPROTO_CONTROL,
            UTUN_OPT_MAX_PENDING_PACKETS,
            &MAX_PENDING_PACKETS as *const u32 as _,
            size_of::<u32>() as libc::socklen_t,
        )
    } < 0
    {
        tracing::warn!(error = %get_last_error(), "Failed to set `UTUN_OPT_MAX_PENDING_PACKETS`");
        return;
    }

    tracing::debug!(
        previous = current,
        new = MAX_PENDING_PACKETS,
        "Raised `UTUN_OPT_MAX_PENDING_PACKETS`"
    );
}

/// Raises the utun socket's receive buffer so the kernel can queue more inbound
/// packets between our reads.
fn raise_recv_buffer(fd: RawFd) {
    // Safety: Within this module, the file descriptor is always valid.
    if unsafe {
        libc::setsockopt(
            fd,
            libc::SOL_SOCKET,
            libc::SO_RCVBUF,
            &RECV_BUFFER_SIZE as *const libc::c_int as _,
            size_of::<libc::c_int>() as libc::socklen_t,
        )
    } < 0
    {
        tracing::warn!(error = %get_last_error(), "Failed to set TUN socket receive buffer");
        return;
    }

    // The kernel clamps to `kern.ipc.maxsockbuf`; read back what it actually applied.
    let mut actual: libc::c_int = 0;
    let mut len = size_of::<libc::c_int>() as libc::socklen_t;
    if unsafe {
        libc::getsockopt(
            fd,
            libc::SOL_SOCKET,
            libc::SO_RCVBUF,
            &mut actual as *mut libc::c_int as _,
            &mut len,
        )
    } < 0
    {
        tracing::warn!(error = %get_last_error(), "Failed to read back TUN socket receive buffer");
        return;
    }

    tracing::debug!(
        requested = RECV_BUFFER_SIZE,
        actual,
        "Set TUN socket receive buffer"
    );
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

    match unsafe { libc::sendmsg(fd.as_raw_fd(), &msg_hdr, 0) } {
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
    for fd in 0..1024 {
        tracing::debug!("Checking fd {}", fd);

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
            set_non_blocking(fd)?;

            return Ok(fd);
        }
    }

    Err(get_last_error())
}

#[cfg(not(any(target_os = "macos", target_os = "ios")))]
fn search_for_tun_fd() -> io::Result<RawFd> {
    unimplemented!("Stub")
}

#[cfg(not(any(target_os = "macos", target_os = "ios")))]
fn name(_: RawFd) -> io::Result<String> {
    unimplemented!("Stub")
}
