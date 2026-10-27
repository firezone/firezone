use std::{
    net::{Ipv4Addr, Ipv6Addr, SocketAddr},
    sync::Arc,
};

use anyhow::Result;
use socket_factory::{SocketFactory, UdpSocket};

use crate::dns;

pub async fn send(
    factory: Arc<dyn SocketFactory<UdpSocket>>,
    server: SocketAddr,
    query: dns_types::Query,
) -> Result<dns_types::Response> {
    let domain = query.domain();
    let qtype = query.qtype();

    tracing::trace!(target: "wire::dns::recursive::qry", %server, transport = %dns::Transport::Udp, "{qtype} {domain}");

    let bind_addr = match server {
        SocketAddr::V4(_) => SocketAddr::new(Ipv4Addr::UNSPECIFIED.into(), 0),
        SocketAddr::V6(_) => SocketAddr::new(Ipv6Addr::UNSPECIFIED.into(), 0),
    };

    // To avoid fragmentation, IP and thus also UDP packets can only reliably sent with an MTU of <= 1500 on the public Internet.
    const BUF_SIZE: usize = 1500;

    let udp_socket = factory.bind(bind_addr)?;

    let response = udp_socket
        .handshake::<BUF_SIZE>(server, &query.into_bytes())
        .await?;

    let response = dns_types::Response::parse(&response)?;

    tracing::trace!(target: "wire::dns::recursive::res", %server, transport = %dns::Transport::Udp, "{qtype} {domain} => {}", response.response_code());

    Ok(response)
}
