#![allow(clippy::unwrap_used)]
#![cfg(target_os = "linux")] // The DNS-over-TCP server is sans-IO so it doesn't matter where the IP packets come from. Testing it only on Linux is therefore fine.

use std::{
    collections::BTreeSet,
    net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr, SocketAddrV4},
    process::Stdio,
    time::Instant,
};

use anyhow::{Context as _, Result};
use bin_shared::TunDeviceManager;
use dns_types::{ResponseBuilder, ResponseCode};
use ip_network::Ipv4Network;
use tokio::task::JoinSet;
use tun::TunIo;
use tunnel::packet_io::native::{OffloadedTun, PacketDevice};

const CLIENT_CONCURRENCY: usize = 3;

#[test]
#[ignore = "Requires root & IP forwarding"]
fn smoke() {
    firezone_runtime::Runtime::new()
        .unwrap()
        .block_on(smoke_test());
}

async fn smoke_test() {
    let _guard = logging::test("netlink_proto=off,wire::dns=trace,debug");

    let ipv4 = Ipv4Addr::from([100, 90, 215, 97]);
    let ipv6 = Ipv6Addr::from([0xfd00, 0x2021, 0x1111, 0x0, 0x0, 0x0, 0x0016, 0x588f]);

    let mut device_manager = TunDeviceManager::new(1280).unwrap();
    let tun = device_manager.make_tun().unwrap();
    device_manager.set_ips(ipv4, ipv6).await.unwrap();
    device_manager
        .set_routes(vec![
            Ipv4Network::new(Ipv4Addr::new(100, 100, 111, 0), 24)
                .unwrap()
                .into(),
        ])
        .await
        .unwrap();

    let listen_addr = SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::new(100, 100, 111, 1), 53));
    let mut dns_server = dns_over_tcp::Server::new(Instant::now());
    dns_server.set_listen_addresses::<CLIENT_CONCURRENCY>(BTreeSet::from([listen_addr]));
    let TunIo::Linux(fd) = tun.into_io() else {
        panic!("Expected a Linux TUN descriptor");
    };
    let eventloop = Eventloop {
        tun: OffloadedTun::from_fd(fd).unwrap(),
        dns_server,
    };
    tokio::select! {
        result = eventloop.run() => result.unwrap(),
        () = async {
            // Running the queries multiple times ensures we can reuse sockets.
            run_queries(listen_addr.ip()).await;
            run_queries(listen_addr.ip()).await;
        } => {},
    }
}

async fn run_queries(dns_server: IpAddr) {
    let mut set = JoinSet::new();

    for _ in 0..CLIENT_CONCURRENCY {
        set.spawn(dig(dns_server));
    }

    let exit_codes = set
        .join_all()
        .await
        .into_iter()
        .collect::<Result<Vec<_>>>()
        .unwrap();

    for status in exit_codes {
        assert_eq!(status, 0)
    }
}

async fn dig(dns_server: IpAddr) -> Result<i32> {
    let exit_status = tokio::process::Command::new("dig")
        .args([
            "+tcp",
            "+tries=1",
            "+keepopen", // Reuse the TCP socket
            &format!("@{dns_server}"),
            "example.com",
            "example.com", // Querying more than one domain ensures a client can reuse a TCP connection
            "example.com",
            "example.com",
        ])
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .status()
        .await?
        .code()
        .context("Missing code")?;

    Ok(exit_status)
}

struct Eventloop {
    tun: OffloadedTun,
    dns_server: dns_over_tcp::Server,
}

impl Eventloop {
    async fn run(mut self) -> Result<()> {
        loop {
            self.dns_server.handle_timeout(Instant::now());
            while let Some(query) = self.dns_server.poll_queries() {
                self.dns_server.send_message(
                    query.local,
                    query.remote,
                    ResponseBuilder::for_query(&query.message, ResponseCode::NXDOMAIN).build(),
                )?;
            }
            self.dns_server.handle_timeout(Instant::now());

            // Send all outbound DNS packets as one batch.
            let mut batch = tun::PacketBatch::default();

            while let Some(packet) = self.dns_server.poll_outbound() {
                if let Err(packet) = batch.try_push(packet) {
                    self.tun
                        .write(std::mem::replace(&mut batch, tun::PacketBatch::new(packet)))
                        .await?;
                }
            }

            if !batch.is_empty() {
                self.tun.write(batch).await?;
            }

            let deadline = self.dns_server.poll_timeout();
            let mut packets = tokio::select! {
                packets = self.tun.read() => packets?,
                () = async {
                    match deadline {
                        Some(deadline) => tokio::time::sleep_until(deadline.into()).await,
                        None => std::future::pending().await,
                    }
                } => continue,
            };

            for ip_packet in packets.drain() {
                if self.dns_server.accepts(&ip_packet) {
                    self.dns_server.handle_inbound(ip_packet);
                }
            }
        }
    }
}
