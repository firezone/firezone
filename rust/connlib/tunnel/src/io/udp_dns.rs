use std::{
    io,
    net::{Ipv4Addr, Ipv6Addr, SocketAddr},
    sync::Arc,
};

use socket_factory::{SocketFactory, UdpSocket};

pub async fn send(
    factory: Arc<dyn SocketFactory<UdpSocket>>,
    server: SocketAddr,
    query: dns_types::Query,
) -> io::Result<dns_types::Response> {
    tracing::trace!(target: "wire::dns::recursive::udp", %server, domain = %query.domain());

    let bind_addr = match server {
        SocketAddr::V4(_) => SocketAddr::new(Ipv4Addr::UNSPECIFIED.into(), 0),
        SocketAddr::V6(_) => SocketAddr::new(Ipv6Addr::UNSPECIFIED.into(), 0),
    };

    // To avoid fragmentation, IP and thus also UDP packets can only reliably sent with an MTU of <= 1500 on the public Internet.
    const BUF_SIZE: usize = 1500;

    let udp_socket = factory(&bind_addr)?;

    let response = udp_socket
        .handshake::<BUF_SIZE>(server, &query.into_bytes())
        .await?;

    let response = dns_types::Response::parse(&response).map_err(io::Error::other)?;

    Ok(response)
}
