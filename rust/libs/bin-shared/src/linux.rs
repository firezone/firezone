use std::os::fd::{AsFd, AsRawFd};
use std::{io, net::SocketAddr};

use crate::FIREZONE_MARK;
use nix::sys::socket::{setsockopt, sockopt};
use socket_factory::{SocketFactory, TcpSocket, UdpSocket};

pub fn tcp_socket_factory(socket_addr: SocketAddr) -> io::Result<TcpSocket> {
    let socket = socket_factory::tcp(socket_addr)?;
    setsockopt(&socket, sockopt::Mark, &FIREZONE_MARK)?;
    prefer_public_ipv6_source(&socket, socket_addr);
    Ok(socket)
}

#[derive(Default)]
pub struct UdpSocketFactory {}

impl SocketFactory<UdpSocket> for UdpSocketFactory {
    fn bind(&self, local: SocketAddr) -> io::Result<UdpSocket> {
        let socket = socket_factory::udp(local)?;
        setsockopt(&socket, sockopt::Mark, &FIREZONE_MARK)?;
        prefer_public_ipv6_source(&socket, local);
        Ok(socket)
    }

    fn reset(&self) {}
}

/// Pins source-address selection to stable, public IPv6 addresses (RFC 5014).
///
/// We stamp a per-packet source IP onto the wildcard socket (via `IPV6_PKTINFO`) to honour the
/// address we advertised as our ICE host candidate. SLAAC privacy extensions rotate temporary
/// addresses out from under that pin, after which `sendmsg` rejects the now-unassigned source
/// with `EINVAL`. Preferring public addresses keeps the kernel's chosen source stable for the
/// lifetime of the candidate, so the pin stays valid.
fn prefer_public_ipv6_source(socket: &impl AsFd, local: SocketAddr) {
    if !local.is_ipv6() {
        return;
    }

    // Not exposed by `libc` or `nix`; see `include/uapi/linux/in6.h`.
    const IPV6_ADDR_PREFERENCES: libc::c_int = 72;
    const IPV6_PREFER_SRC_PUBLIC: libc::c_int = 0x0002;

    let preference = IPV6_PREFER_SRC_PUBLIC;

    // SAFETY: `preference` outlives the call and its size matches the `c_int` option value.
    let ret = unsafe {
        libc::setsockopt(
            socket.as_fd().as_raw_fd(),
            libc::IPPROTO_IPV6,
            IPV6_ADDR_PREFERENCES,
            std::ptr::from_ref(&preference).cast(),
            std::mem::size_of::<libc::c_int>() as libc::socklen_t,
        )
    };

    if ret != 0 {
        tracing::debug!(
            "Failed to prefer public IPv6 source address: {}",
            io::Error::last_os_error()
        );
    }
}
