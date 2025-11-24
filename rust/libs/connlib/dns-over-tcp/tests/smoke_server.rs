#![allow(clippy::unwrap_used)]
#![cfg(not(any(target_os = "macos", target_os = "windows")))] // The DNS-over-TCP server is sans-IO so it doesn't matter where the IP packets come from. Testing it only on Linux is therefore fine.

use std::{
    collections::BTreeSet,
    net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr, SocketAddrV4},
    process::Stdio,
    task::{Context, Poll, ready},
    time::Instant,
};

use anyhow::{Context as _, Result};
use bin_shared::TunDeviceManager;
use dns_types::{ResponseBuilder, ResponseCode};
use ip_network::Ipv4Network;
use tokio::task::JoinSet;
use tun::Tun;

const CLIENT_CONCURRENCY: usize = 3;

#[tokio::test]
#[ignore = "Requires root & IP forwarding"]
async fn smoke() {
    let _guard = logging::test("netlink_proto=off,wire::dns=trace,debug");

    let ipv4 = Ipv4Addr::from([100, 90, 215, 97]);
    let ipv6 = Ipv6Addr::from([0xfd00, 0x2021, 0x1111, 0x0, 0x0, 0x0, 0x0016, 0x588f]);

    let mut device_manager = TunDeviceManager::new(1280).unwrap();
    let tun = device_manager.make_tun().unwrap();
    device_manager.set_ips(ipv4, ipv6).await.unwrap();
    device_manager
        .set_routes(
            vec![Ipv4Network::new(Ipv4Addr::new(100, 100, 111, 0), 24).unwrap()],
            vec![],
        )
        .await
        .unwrap();

    let listen_addr = SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::new(100, 100, 111, 1), 53));
    let mut dns_server = dns_over_tcp::Server::new(Instant::now());
    dns_server.set_listen_addresses::<CLIENT_CONCURRENCY>(BTreeSet::from([listen_addr]));
    let mut eventloop = Eventloop::new(tun, dns_server);

    tokio::spawn(std::future::poll_fn(move |cx| eventloop.poll(cx)));

    // Running the queries multiple times ensures we can reuse sockets.
    run_queries(listen_addr.ip()).await;
    run_queries(listen_addr.ip()).await;
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
    tun: Box<dyn Tun>,
    dns_server: dns_over_tcp::Server,
}

impl Eventloop {
    fn new(tun: Box<dyn Tun>, dns_server: dns_over_tcp::Server) -> Self {
        Self { tun, dns_server }
    }

    fn poll(&mut self, cx: &mut Context) -> Poll<()> {
        loop {
            ready!(self.tun.poll_send_ready(cx)).unwrap();

            if let Some(packet) = self.dns_server.poll_outbound() {
                self.tun.send(packet).unwrap();
                continue;
            }

            if let Some(query) = self.dns_server.poll_queries() {
                self.dns_server
                    .send_message(
                        query.local,
                        query.remote,
                        ResponseBuilder::for_query(&query.message, ResponseCode::NXDOMAIN).build(),
                    )
                    .unwrap();
                continue;
            }

            let mut buf = Vec::with_capacity(1);
            ready!(self.tun.poll_recv_many(cx, &mut buf, 1));
            let ip_packet = buf.remove(0);

            if self.dns_server.accepts(&ip_packet) {
                self.dns_server.handle_inbound(ip_packet);
                self.dns_server.handle_timeout(Instant::now());
            }
        }
    }
}
