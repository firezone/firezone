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

/// Attaching to a TUN device that another process still holds must fail
/// instead of exchanging packets on a shared device.
#[tokio::test] // Needs a runtime.
#[ignore = "Needs admin / sudo"]
async fn refuses_tun_device_held_by_another_process() {
    let mut tun_device_manager = TunDeviceManager::new(1280).unwrap();

    // A multi-queue device, as created by older versions.
    {
        let _foreign_device = create_foreign_device(libc::IFF_MULTI_QUEUE | libc::IFF_VNET_HDR);

        assert_make_tun_fails(&mut tun_device_manager);
    }

    // A single-queue device.
    {
        let _foreign_device = create_foreign_device(0);

        assert_make_tun_fails(&mut tun_device_manager);
    }
}

fn assert_make_tun_fails(tun_device_manager: &mut TunDeviceManager) {
    let error = match tun_device_manager.make_tun() {
        Ok(_) => panic!("Expected `make_tun` to fail"),
        Err(e) => e,
    };

    assert!(
        format!("{error:#}").contains("Failed to set flags on TUN device"),
        "{error:#}"
    );
}

fn create_foreign_device(extra_flags: libc::c_int) -> OwnedFd {
    let fd = unsafe { libc::open(c"/dev/net/tun".as_ptr(), libc::O_RDWR) };
    assert!(fd >= 0, "{}", std::io::Error::last_os_error());

    let name = TunDeviceManager::IFACE_NAME.as_bytes();
    let mut request = IfReq {
        name: [0; libc::IF_NAMESIZE],
        flags: (libc::IFF_TUN | libc::IFF_NO_PI | extra_flags) as libc::c_short,
        _padding: [0; 22],
    };
    request.name[..name.len()].copy_from_slice(name);

    let ret = unsafe { libc::ioctl(fd, TUNSETIFF as _, &mut request) };
    assert!(ret >= 0, "{}", std::io::Error::last_os_error());

    // Safety: We just opened the FD.
    unsafe { OwnedFd::from_raw_fd(fd) }
}
