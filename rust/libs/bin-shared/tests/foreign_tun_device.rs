#![cfg(target_os = "linux")]
#![allow(clippy::unwrap_used)]

use bin_shared::TunDeviceManager;
use std::os::fd::{FromRawFd as _, OwnedFd};

const TUNSETIFF: libc::c_ulong = 0x4004_54ca;

#[repr(C)]
struct IfReq {
    name: [u8; libc::IF_NAMESIZE],
    flags: libc::c_short,
    _padding: [u8; 22],
}

/// Attaching to a TUN device that another process created with different flags
/// must fail instead of exchanging packets in a format the kernel does not use.
#[tokio::test] // Needs a runtime.
#[ignore = "Needs admin / sudo"]
async fn refuses_foreign_tun_device_without_vnet_hdr() {
    let _foreign_device = create_device_without_vnet_hdr();

    let mut tun_device_manager = TunDeviceManager::new(1280).unwrap();
    let error = match tun_device_manager.make_tun() {
        Ok(_) => panic!("Expected `make_tun` to fail"),
        Err(e) => e,
    };

    assert!(
        format!("{error:#}").contains("missing required flags"),
        "{error:#}"
    );
}

fn create_device_without_vnet_hdr() -> OwnedFd {
    let fd = unsafe { libc::open(c"/dev/net/tun".as_ptr(), libc::O_RDWR) };
    assert!(fd >= 0, "{}", std::io::Error::last_os_error());

    let name = TunDeviceManager::IFACE_NAME.as_bytes();
    let mut request = IfReq {
        name: [0; libc::IF_NAMESIZE],
        flags: (libc::IFF_TUN | libc::IFF_NO_PI | libc::IFF_MULTI_QUEUE) as libc::c_short,
        _padding: [0; 22],
    };
    request.name[..name.len()].copy_from_slice(name);

    let ret = unsafe { libc::ioctl(fd, TUNSETIFF as _, &mut request) };
    assert!(ret >= 0, "{}", std::io::Error::last_os_error());

    // Safety: We just opened the FD.
    unsafe { OwnedFd::from_raw_fd(fd) }
}
