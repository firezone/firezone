//! Integration tests for the batched TUN I/O against a real `utun` device.
//!
//! Creating a `utun` requires root, so these are `#[ignore]`d and run under `sudo`
//! in CI (the `CARGO_TARGET_AARCH64_APPLE_DARWIN_RUNNER` in `_rust.yml`).

use std::ffi::c_void;
use std::io;
use std::net::{IpAddr, Ipv4Addr, UdpSocket};
use std::os::fd::RawFd;
use std::time::{Duration, Instant};

use ip_packet::IpPacket;

/// From XNU's `bsd/net/if_utun.h`.
const UTUN_OPT_MAX_PENDING_PACKETS: libc::c_int = 16;

const LOCAL: Ipv4Addr = Ipv4Addr::new(169, 254, 33, 1);
const PEER: Ipv4Addr = Ipv4Addr::new(169, 254, 33, 2);

/// Datagrams sent to [`PEER`] route out the utun and must come back through `recv`.
#[test]
#[ignore = "Needs root to create a utun device"]
fn recv_reads_packets_routed_through_the_interface() {
    let syscalls = super::sys::batch_syscalls().expect("recvmsg_x/sendmsg_x to resolve on macOS");

    let (fd, name) = create_utun();
    set_nonblocking(fd);
    raise_max_pending_packets(fd, 64);
    configure(&name);

    let (tx, mut rx) = tokio::sync::mpsc::channel::<IpPacket>(1024);
    std::thread::Builder::new()
        .name("test TUN recv".to_owned())
        .spawn(move || {
            let _ = super::bulk::recv(fd, syscalls, tx);
        })
        .expect("spawn recv thread");

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
    let mut matched = 0;
    let deadline = Instant::now() + Duration::from_secs(5);
    while matched < COUNT && Instant::now() < deadline {
        match rx.try_recv() {
            Ok(packet) => {
                if packet.destination() == IpAddr::V4(PEER) && packet.as_udp().is_some() {
                    matched += 1;
                }
            }
            Err(tokio::sync::mpsc::error::TryRecvError::Empty) => {
                std::thread::sleep(Duration::from_millis(10));
            }
            Err(tokio::sync::mpsc::error::TryRecvError::Disconnected) => break,
        }
    }

    assert_eq!(
        matched, COUNT,
        "expected to read back every datagram routed through the utun"
    );
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
