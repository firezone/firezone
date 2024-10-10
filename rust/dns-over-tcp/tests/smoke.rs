use std::{
    net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr, SocketAddrV4},
    process::Stdio,
    task::{ready, Context, Poll},
    time::Instant,
};

use anyhow::{Context as _, Result};
use domain::base::{iana::Rcode, MessageBuilder};
use firezone_bin_shared::TunDeviceManager;
use ip_network::Ipv4Network;
use ip_packet::{IpPacket, IpPacketBuf};
use tokio::task::JoinSet;
use tun::Tun;

#[tokio::test]
#[ignore = "Requires root"]
async fn smoke() {
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
    dns_server.set_listen_addresses(vec![listen_addr]);
    let mut eventloop = Eventloop::new(Box::new(tun), dns_server);

    tokio::spawn(std::future::poll_fn(move |cx| eventloop.poll(cx)));

    let mut set = JoinSet::new();

    set.spawn(dig(listen_addr.ip()));
    set.spawn(dig(listen_addr.ip()));
    set.spawn(dig(listen_addr.ip()));
    set.spawn(dig(listen_addr.ip()));
    set.spawn(dig(listen_addr.ip()));

    let status = set
        .join_all()
        .await
        .into_iter()
        .collect::<Result<Vec<_>>>()
        .unwrap();

    assert_eq!(status, vec![0, 0, 0, 0, 0])
}

async fn dig(dns_server: IpAddr) -> Result<i32> {
    let exit_status = tokio::process::Command::new("dig")
        .args(["+tcp", "+tries=1", &format!("@{dns_server}"), "example.com"])
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
            if let Some(packet) = self.dns_server.poll_outbound() {
                match packet {
                    IpPacket::Ipv4(v4) => self.tun.write4(v4.packet()).unwrap(),
                    IpPacket::Ipv6(v6) => self.tun.write6(v6.packet()).unwrap(),
                };
                continue;
            }

            if let Some(query) = self.dns_server.poll_queries() {
                let response = MessageBuilder::new_vec()
                    .start_answer(&query.message, Rcode::NXDOMAIN)
                    .unwrap()
                    .into_message();

                self.dns_server
                    .send_message(query.socket, response)
                    .unwrap();
                continue;
            }

            let mut packet_buf = IpPacketBuf::default();
            let num_read = ready!(self.tun.poll_read(packet_buf.buf(), cx)).unwrap();
            let packet = IpPacket::new(packet_buf, num_read).unwrap();

            if self.dns_server.accepts(&packet) {
                self.dns_server.handle_inbound(packet);
                self.dns_server.handle_timeout(Instant::now());
            }
        }
    }
}
