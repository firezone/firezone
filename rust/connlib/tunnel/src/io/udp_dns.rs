use std::{
    io,
    net::{Ipv4Addr, Ipv6Addr, SocketAddr},
    sync::Arc,
};

use domain::base::{Message, ToName as _};
use socket_factory::{SocketFactory, UdpSocket};

pub async fn send(
    factory: Arc<dyn SocketFactory<UdpSocket>>,
    server: SocketAddr,
    query: Message<Vec<u8>>,
) -> io::Result<Message<Vec<u8>>> {
    let domain = query
        .sole_question()
        .expect("all queries should be for a single name")
        .qname()
        .to_vec();
    let bind_addr = match server {
        SocketAddr::V4(_) => SocketAddr::new(Ipv4Addr::UNSPECIFIED.into(), 0),
        SocketAddr::V6(_) => SocketAddr::new(Ipv6Addr::UNSPECIFIED.into(), 0),
    };

    tracing::trace!(target: "wire::dns::recursive::udp", %server, %domain);

    // To avoid fragmentation, IP and thus also UDP packets can only reliably sent with an MTU of <= 1500 on the public Internet.
    const BUF_SIZE: usize = 1500;

    let udp_socket = factory(&bind_addr)?;

    let response = udp_socket
        .handshake::<BUF_SIZE>(server, query.as_slice())
        .await?;

    let message = Message::from_octets(response)
        .map_err(|_| io::Error::other("Failed to parse DNS message"))?;

    Ok(message)
}
