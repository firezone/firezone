use libc::{F_GETFL, F_SETFL, O_NONBLOCK, fcntl};
use std::{io, os::fd::RawFd};
use telemetry::otel;

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
    outbound_tx: tun::OutboundTx,
    inbound_rx: tun::InboundRx,
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

        let (inbound_tx, inbound_rx) = tun::inbound_channel();
        let (outbound_tx, outbound_rx) = tun::outbound_channel();

        runtime.spawn(otel_instruments::periodic_queue_length(
            outbound_tx.downgrade(),
            [
                otel::attr::queue_item_ip_packet(),
                otel::attr::network_io_direction_transmit(),
            ],
        ));
        runtime.spawn(otel_instruments::periodic_queue_length(
            inbound_tx.downgrade(),
            [
                otel::attr::queue_item_ip_packet(),
                otel::attr::network_io_direction_receive(),
            ],
        ));

        std::thread::Builder::new()
            .name("TUN send".to_owned())
            .spawn(move || {
                logging::unwrap_or_warn!(
                    tun::apple::send(fd, outbound_rx),
                    "Failed to send to TUN device: {}"
                )
            })
            .map_err(io::Error::other)?;
        std::thread::Builder::new()
            .name("TUN recv".to_owned())
            .spawn(move || {
                logging::unwrap_or_warn!(
                    tun::apple::recv(fd, inbound_tx),
                    "Failed to recv from TUN device: {}"
                )
            })
            .map_err(io::Error::other)?;

        Ok(Tun {
            name,
            outbound_tx,
            inbound_rx,
        })
    }
}

impl tun::Tun for Tun {
    fn sender(&self) -> &tun::OutboundTx {
        &self.outbound_tx
    }

    fn receiver(&mut self) -> &mut tun::InboundRx {
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
    let current = match get_sockopt::<u32>(fd, libc::SYSPROTO_CONTROL, UTUN_OPT_MAX_PENDING_PACKETS)
    {
        Ok(current) => current,
        Err(e) => {
            tracing::warn!(error = %e, "Failed to get `UTUN_OPT_MAX_PENDING_PACKETS`");
            return;
        }
    };

    tracing::debug!(current, "Queried `UTUN_OPT_MAX_PENDING_PACKETS`");

    if current >= MAX_PENDING_PACKETS {
        return;
    }

    if let Err(e) = set_sockopt(
        fd,
        libc::SYSPROTO_CONTROL,
        UTUN_OPT_MAX_PENDING_PACKETS,
        &MAX_PENDING_PACKETS,
    ) {
        tracing::warn!(error = %e, "Failed to set `UTUN_OPT_MAX_PENDING_PACKETS`");
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
    if let Err(e) = set_sockopt(fd, libc::SOL_SOCKET, libc::SO_RCVBUF, &RECV_BUFFER_SIZE) {
        tracing::warn!(error = %e, "Failed to set TUN socket receive buffer");
        return;
    }

    // The kernel clamps to `kern.ipc.maxsockbuf`; read back what it actually applied.
    match get_sockopt::<libc::c_int>(fd, libc::SOL_SOCKET, libc::SO_RCVBUF) {
        Ok(actual) => {
            tracing::debug!(
                requested = RECV_BUFFER_SIZE,
                actual,
                "Set TUN socket receive buffer"
            )
        }
        Err(e) => tracing::warn!(error = %e, "Failed to read back TUN socket receive buffer"),
    }
}

/// Sets an integer-valued socket option.
fn set_sockopt<T>(fd: RawFd, level: libc::c_int, name: libc::c_int, value: &T) -> io::Result<()> {
    // Safety: `value` points to a `T`, matching the `size_of::<T>()` length we pass.
    let ret = unsafe {
        libc::setsockopt(
            fd,
            level,
            name,
            (value as *const T).cast(),
            size_of::<T>() as libc::socklen_t,
        )
    };

    if ret < 0 {
        return Err(get_last_error());
    }

    Ok(())
}

/// Reads an integer-valued socket option.
fn get_sockopt<T>(fd: RawFd, level: libc::c_int, name: libc::c_int) -> io::Result<T> {
    let mut value = std::mem::MaybeUninit::<T>::uninit();
    let mut len = size_of::<T>() as libc::socklen_t;

    // Safety: `value` has room for the `size_of::<T>()` length we pass.
    let ret = unsafe { libc::getsockopt(fd, level, name, value.as_mut_ptr().cast(), &mut len) };

    if ret < 0 {
        return Err(get_last_error());
    }

    // Safety: `getsockopt` succeeded; these integer options return a fully-initialized `T`.
    Ok(unsafe { value.assume_init() })
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
