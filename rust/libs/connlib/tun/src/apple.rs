//! Apple-specific TUN I/O on the `utun` file descriptor handed to us by the
//! NetworkExtension.
//!
//! [`send`] / [`recv`] are the entry points the caller spawns as tasks.
//! They use Apple's batched `recvmsg_x` / `sendmsg_x` syscalls (see [`sys`] / [`bulk`])
//! when available and fall back to per-packet I/O ([`per_packet`]) otherwise.
//!
//! This lives here (next to [`crate::unix`]) so it can also back a future macOS
//! `TunDeviceManager` and be exercised by integration tests.

mod bulk;
mod per_packet;
mod sys;

#[cfg(test)]
mod tests;

use anyhow::Result;
use std::os::fd::RawFd;

/// Sends packets from `outbound_rx` to the TUN `fd` until the channel closes.
pub async fn send(fd: RawFd, outbound_rx: crate::OutboundRx) -> Result<()> {
    match sys::batch_syscalls() {
        Some(syscalls) => bulk::send(fd, syscalls, outbound_rx).await?,
        None => crate::unix::tun_send(fd, outbound_rx, per_packet::write).await?,
    }

    Ok(())
}

/// Receives packets from the TUN `fd` into `inbound_tx` until the fd or the channel closes.
pub async fn recv(fd: RawFd, inbound_tx: crate::InboundTx) -> Result<()> {
    match sys::batch_syscalls() {
        Some(syscalls) => bulk::recv(fd, syscalls, inbound_tx).await?,
        None => crate::unix::tun_recv(fd, inbound_tx, per_packet::read).await?,
    }

    Ok(())
}
