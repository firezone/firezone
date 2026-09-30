use anyhow::Result;
use compio::io::ancillary::{AncillaryBuf, AncillaryIter};
use ip_packet::Ecn;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};

pub type Control = AncillaryBuf<256>;

#[cfg(unix)]
pub fn encode(
    src: Option<SocketAddr>,
    dst: SocketAddr,
    ecn: Ecn,
    segment: Option<usize>,
) -> Result<Control> {
    let mut control = Control::new();
    let mut builder = control.builder();
    if let Some(src) = src {
        match src {
            SocketAddr::V4(src) => {
                let info = libc::in_pktinfo {
                    ipi_ifindex: 0,
                    ipi_spec_dst: libc::in_addr {
                        s_addr: u32::from_ne_bytes(src.ip().octets()),
                    },
                    ipi_addr: libc::in_addr { s_addr: 0 },
                };
                builder.push(libc::IPPROTO_IP, libc::IP_PKTINFO, &info)?;
            }
            SocketAddr::V6(src) => {
                let info = libc::in6_pktinfo {
                    ipi6_addr: libc::in6_addr {
                        s6_addr: src.ip().octets(),
                    },
                    ipi6_ifindex: src.scope_id() as _,
                };
                builder.push(libc::IPPROTO_IPV6, libc::IPV6_PKTINFO, &info)?;
            }
        }
    }
    if dst.is_ipv4() {
        builder.push(libc::IPPROTO_IP, libc::IP_TOS, &(ecn as i32))?;
    } else {
        builder.push(libc::IPPROTO_IPV6, libc::IPV6_TCLASS, &(ecn as i32))?;
    }
    if let Some(segment) = segment {
        builder.push(libc::SOL_UDP, libc::UDP_SEGMENT, &u16::try_from(segment)?)?;
    }
    Ok(control)
}

#[cfg(unix)]
pub fn decode(control: &[u8], port: u16, len: usize) -> Result<(SocketAddr, usize, Ecn)> {
    let mut local = None;
    let mut stride = len;
    let mut bits = 0;
    // Only kernel-produced messages from a completed recvmsg reach this decoder.
    for message in unsafe { AncillaryIter::new(control) } {
        match (message.level(), message.ty()) {
            (libc::IPPROTO_IP, libc::IP_PKTINFO) => {
                let info = message.data::<libc::in_pktinfo>()?;
                local = Some(SocketAddr::new(
                    IpAddr::V4(Ipv4Addr::from(info.ipi_addr.s_addr.to_ne_bytes())),
                    port,
                ));
            }
            (libc::IPPROTO_IPV6, libc::IPV6_PKTINFO) => {
                let info = message.data::<libc::in6_pktinfo>()?;
                local = Some(SocketAddr::V6(std::net::SocketAddrV6::new(
                    Ipv6Addr::from(info.ipi6_addr.s6_addr),
                    port,
                    0,
                    scope_index(info.ipi6_ifindex)?,
                )));
            }
            (libc::IPPROTO_IP, libc::IP_TOS) => bits = message.data::<u8>()?,
            (libc::IPPROTO_IPV6, libc::IPV6_TCLASS) => bits = message.data::<i32>()? as u8,
            (libc::SOL_UDP, libc::UDP_GRO) => stride = message.data::<i32>()? as usize,
            _ => {}
        }
    }
    let local = local.ok_or_else(|| anyhow::anyhow!("UDP receive missing destination address"))?;
    anyhow::ensure!(stride > 0 && stride <= len, "Invalid GRO stride");
    Ok((local, stride, ecn(bits)))
}

#[cfg(target_os = "linux")]
#[expect(
    clippy::unnecessary_wraps,
    reason = "Android has a signed interface index"
)]
fn scope_index(index: u32) -> Result<u32> {
    Ok(index)
}
#[cfg(target_os = "android")]
fn scope_index(index: i32) -> Result<u32> {
    let index = u32::try_from(index)?;
    Ok(index)
}

#[cfg(windows)]
pub fn encode(
    src: Option<SocketAddr>,
    dst: SocketAddr,
    ecn: Ecn,
    segment: Option<usize>,
) -> Result<Control> {
    use windows_sys::Win32::Networking::WinSock::*;
    let mut control = Control::new();
    let mut builder = control.builder();
    if let Some(src) = src {
        match src {
            SocketAddr::V4(src) => {
                let info = IN_PKTINFO {
                    ipi_addr: IN_ADDR {
                        S_un: IN_ADDR_0 {
                            S_addr: u32::from_ne_bytes(src.ip().octets()),
                        },
                    },
                    ipi_ifindex: 0,
                };
                builder.push(IPPROTO_IP, IP_PKTINFO, &info)?;
            }
            SocketAddr::V6(src) => {
                let info = IN6_PKTINFO {
                    ipi6_addr: IN6_ADDR {
                        u: IN6_ADDR_0 {
                            Byte: src.ip().octets(),
                        },
                    },
                    ipi6_ifindex: src.scope_id(),
                };
                builder.push(IPPROTO_IPV6, IPV6_PKTINFO, &info)?;
            }
        }
    }
    if dst.is_ipv4() {
        builder.push(IPPROTO_IP, IP_ECN, &(ecn as i32))?;
    } else {
        builder.push(IPPROTO_IPV6, IPV6_ECN, &(ecn as i32))?;
    }
    if let Some(segment) = segment {
        builder.push(
            IPPROTO_UDP,
            UDP_SEND_MSG_SIZE as i32,
            &u32::try_from(segment)?,
        )?;
    }
    Ok(control)
}

#[cfg(windows)]
pub fn decode(control: &[u8], port: u16, len: usize) -> Result<(SocketAddr, usize, Ecn)> {
    use windows_sys::Win32::Networking::WinSock::*;
    let mut local = None;
    let mut stride = len;
    let mut bits = 0;
    for message in unsafe { AncillaryIter::new(control) } {
        match (message.level(), message.ty()) {
            (IPPROTO_IP, IP_PKTINFO) => {
                let info = message.data::<IN_PKTINFO>()?;
                local = Some(SocketAddr::new(
                    Ipv4Addr::from(unsafe { info.ipi_addr.S_un.S_addr }.to_ne_bytes()).into(),
                    port,
                ));
            }
            (IPPROTO_IPV6, IPV6_PKTINFO) => {
                let info = message.data::<IN6_PKTINFO>()?;
                local = Some(SocketAddr::V6(std::net::SocketAddrV6::new(
                    Ipv6Addr::from(unsafe { info.ipi6_addr.u.Byte }),
                    port,
                    0,
                    info.ipi6_ifindex,
                )));
            }
            (IPPROTO_IP, IP_ECN) => bits = message.data::<i32>()? as u8,
            (IPPROTO_IPV6, IPV6_ECN) => bits = message.data::<i32>()? as u8,
            (IPPROTO_UDP, value) if value == UDP_COALESCED_INFO as i32 => {
                stride = message.data::<u32>()? as usize
            }
            _ => {}
        }
    }
    let local = local.ok_or_else(|| anyhow::anyhow!("UDP receive missing destination address"))?;
    anyhow::ensure!(stride > 0 && stride <= len, "Invalid URO stride");
    Ok((local, stride, ecn(bits)))
}

fn ecn(bits: u8) -> Ecn {
    match bits & 3 {
        0 => Ecn::NonEct,
        1 => Ecn::Ect1,
        2 => Ecn::Ect0,
        3 => Ecn::Ce,
        _ => unreachable!(),
    }
}
