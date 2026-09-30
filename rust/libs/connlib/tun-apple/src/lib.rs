#![cfg(any(target_os = "macos", target_os = "ios"))]
#![cfg_attr(test, allow(clippy::unwrap_used))]

//! Apple-specific TUN I/O on the `utun` file descriptor handed to us by the
//! NetworkExtension.
//!
//! [`Io`] owns worker threads that use Apple's batched `recvmsg_x` / `sendmsg_x` syscalls (see [`sys`] / [`bulk`])
//! when available and fall back to per-packet I/O ([`per_packet`]) otherwise.

mod bulk;
mod per_packet;
mod per_packet_io;
mod sys;

#[cfg(test)]
mod tests;

use anyhow::Result;
use libc::{F_GETFL, F_SETFL, O_NONBLOCK, fcntl};
use std::{io, os::fd::RawFd};

/// Receive buffer we request for the utun control socket via `SO_RCVBUF`.
///
/// The kernel default (`ctl_recvsize`) is 512 KiB, only a few hundred MTU-sized
/// packets, after which inbound packets are backpressured. A larger buffer lets the kernel
/// queue more while we drain it. 8 MiB matches the default `kern.ipc.maxsockbuf`
/// ceiling, the most the kernel grants without raising that system-wide limit.
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

pub struct Io {
    name: String,
    workers: tun::Workers,
}

impl Io {
    /// Starts IO on a borrowed NetworkExtension descriptor.
    ///
    /// # Safety
    ///
    /// The descriptor must remain open until this IO and its workers have stopped.
    pub unsafe fn new(
        name: String,
        fd: RawFd,
        runtime: &tokio::runtime::Handle,
    ) -> io::Result<Self> {
        set_non_blocking(fd)?;
        raise_recv_buffer(fd);
        raise_max_pending_packets(fd);
        let (inbound_tx, inbound_rx) = tun::inbound_channel();
        let (outbound_tx, outbound_rx) = tun::outbound_channel();

        runtime.spawn(otel_instruments::periodic_queue_length(
            outbound_tx.downgrade(),
            [
                otel_attributes::queue_item_ip_packet_batch(),
                otel_attributes::network_io_direction_transmit(),
            ],
        ));
        runtime.spawn(otel_instruments::periodic_queue_length(
            inbound_tx.downgrade(),
            [
                otel_attributes::queue_item_ip_packet_batch(),
                otel_attributes::network_io_direction_receive(),
            ],
        ));

        let workers = tun::Workers::spawn(
            outbound_tx,
            inbound_rx,
            move || {
                logging::unwrap_or_warn!(
                    crate::send(fd, outbound_rx),
                    "Failed to send to TUN device: {}"
                )
            },
            move || {
                logging::unwrap_or_warn!(
                    crate::recv(fd, inbound_tx),
                    "Failed to recv from TUN device: {}"
                )
            },
        )?;

        Ok(Self { name, workers })
    }
}

impl tun::Tun for Io {
    fn sender(&self) -> &tun::OutboundTx {
        self.workers.sender()
    }

    fn receiver(&mut self) -> &mut tun::InboundRx {
        self.workers.receiver()
    }

    fn name(&self) -> &str {
        self.name.as_str()
    }
}

/// Sends packets from `outbound_rx` to the TUN `fd` until the channel closes.
fn send(fd: RawFd, outbound_rx: tun::OutboundRx) -> Result<()> {
    match sys::batch_syscalls() {
        Some(syscalls) => bulk::send(fd, syscalls, outbound_rx),
        None => crate::per_packet_io::tun_send(fd, outbound_rx, per_packet::write),
    }
}

/// Receives packets from the TUN `fd` into `inbound_tx` until the fd or the channel closes.
fn recv(fd: RawFd, inbound_tx: tun::InboundTx) -> Result<()> {
    match sys::batch_syscalls() {
        Some(syscalls) => bulk::recv(fd, syscalls, inbound_tx),
        None => crate::per_packet_io::tun_recv(fd, inbound_tx, per_packet::read),
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
