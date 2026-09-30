//! Integration tests for the batched TUN I/O against a real `utun` device.
//!
//! Creating a `utun` requires root, so these are `#[ignore]`d and run under `sudo`
//! in CI (the `CARGO_TARGET_AARCH64_APPLE_DARWIN_RUNNER` in `_rust.yml`).

use std::ffi::c_void;
use std::io;
use std::net::{IpAddr, Ipv4Addr, UdpSocket};
use std::os::fd::{FromRawFd as _, RawFd};
use std::time::Duration;

/// From XNU's `bsd/net/if_utun.h`.
const UTUN_OPT_MAX_PENDING_PACKETS: libc::c_int = 16;

const LOCAL: Ipv4Addr = Ipv4Addr::new(169, 254, 33, 1);
const PEER: Ipv4Addr = Ipv4Addr::new(169, 254, 33, 2);

/// Datagrams sent to [`PEER`] route out the utun and must come back through `recv`.
#[test]
#[ignore = "Needs root to create a utun device"]
fn recv_reads_packets_routed_through_the_interface() {
    let (fd, name) = create_utun();
    set_nonblocking(fd);
    raise_max_pending_packets(fd, 64);
    configure(&name);

    // The kernel routes datagrams addressed to the point-to-point peer out the utun,
    // where they queue (we raised the pending limit) for `recv` to read as a batch.
    const COUNT: usize = 8;
    let socket = UdpSocket::bind((Ipv4Addr::UNSPECIFIED, 0)).expect("bind UDP socket");
    for i in 0..COUNT {
        socket
            .send_to(&[i as u8; 64], (PEER, 9999))
            .expect("send datagram");
    }

    // Count only our datagrams; a freshly-created interface also emits other traffic
    // (e.g. IPv6 link-local setup) that we must ignore.
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap();
    runtime.block_on(async {
        // SAFETY: create_utun returns a new descriptor owned by this test.
        let fd = unsafe { std::os::fd::OwnedFd::from_raw_fd(fd) };
        let tun = super::Tun::from_fd(fd).unwrap();
        assert!(tun.syscalls.is_some());
        let mut sequences = Vec::new();
        tokio::time::timeout(Duration::from_secs(5), async {
            while sequences.len() < COUNT {
                let batch = tun.read().await.unwrap();
                for packet in batch.iter().filter(|p| p.destination() == IpAddr::V4(PEER)) {
                    if let Some(udp) = packet.as_udp() {
                        sequences.push(udp.payload()[0]);
                    }
                }
            }
        })
        .await
        .unwrap();
        assert_eq!(sequences, (0..COUNT as u8).collect::<Vec<_>>());
    });
}

/// Creates a `utun` interface and returns its fd and name (e.g. `utun7`). Requires root.
fn create_utun() -> (RawFd, String) {
    const CTL_NAME: &[u8] = b"com.apple.net.utun_control";

    // Safety: a standard `SYSPROTO_CONTROL` utun creation; all pointers are valid and
    // sized, and we assert on every syscall's result.
    unsafe {
        let fd = libc::socket(libc::PF_SYSTEM, libc::SOCK_DGRAM, libc::SYSPROTO_CONTROL);
        assert!(fd >= 0, "socket(PF_SYSTEM): {}", io::Error::last_os_error());

        let mut info = libc::ctl_info {
            ctl_id: 0,
            ctl_name: [0; 96],
        };
        for (dst, &src) in info.ctl_name.iter_mut().zip(CTL_NAME) {
            *dst = src as libc::c_char;
        }
        assert_eq!(
            libc::ioctl(fd, libc::CTLIOCGINFO, &mut info),
            0,
            "CTLIOCGINFO: {}",
            io::Error::last_os_error()
        );

        let addr = libc::sockaddr_ctl {
            sc_len: size_of::<libc::sockaddr_ctl>() as u8,
            sc_family: libc::AF_SYSTEM as u8,
            ss_sysaddr: libc::AF_SYS_CONTROL as u16,
            sc_id: info.ctl_id,
            sc_unit: 0, // 0 => the kernel picks the next free utun unit
            sc_reserved: [0; 5],
        };
        assert_eq!(
            libc::connect(
                fd,
                &addr as *const libc::sockaddr_ctl as *const libc::sockaddr,
                size_of::<libc::sockaddr_ctl>() as libc::socklen_t,
            ),
            0,
            "connect(utun_control): {}",
            io::Error::last_os_error()
        );

        let mut name = [0u8; libc::IF_NAMESIZE];
        let mut len = name.len() as libc::socklen_t;
        assert_eq!(
            libc::getsockopt(
                fd,
                libc::SYSPROTO_CONTROL,
                libc::UTUN_OPT_IFNAME,
                name.as_mut_ptr() as *mut c_void,
                &mut len,
            ),
            0,
            "getsockopt(UTUN_OPT_IFNAME): {}",
            io::Error::last_os_error()
        );
        let name = String::from_utf8_lossy(&name[..len as usize - 1]).into_owned();

        (fd, name)
    }
}

fn set_nonblocking(fd: RawFd) {
    // Safety: `fd` is a valid, open socket.
    unsafe {
        let flags = libc::fcntl(fd, libc::F_GETFL);
        assert_eq!(
            libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK),
            0,
            "fcntl(O_NONBLOCK): {}",
            io::Error::last_os_error()
        );
    }
}

fn raise_max_pending_packets(fd: RawFd, packets: u32) {
    // Safety: `fd` is valid; the option's value is a `u32`.
    let ret = unsafe {
        libc::setsockopt(
            fd,
            libc::SYSPROTO_CONTROL,
            UTUN_OPT_MAX_PENDING_PACKETS,
            &packets as *const u32 as *const c_void,
            size_of::<u32>() as libc::socklen_t,
        )
    };
    assert_eq!(
        ret,
        0,
        "setsockopt(UTUN_OPT_MAX_PENDING_PACKETS): {}",
        io::Error::last_os_error()
    );
}

/// Brings the interface up with a point-to-point address so traffic to [`PEER`] routes out it.
fn configure(name: &str) {
    let status = std::process::Command::new("ifconfig")
        .args([name, &LOCAL.to_string(), &PEER.to_string(), "up"])
        .status()
        .expect("run ifconfig");
    assert!(status.success(), "`ifconfig {name}` failed");
}
