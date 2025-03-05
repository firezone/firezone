use std::{io, net::SocketAddr, sync::Arc};

use domain::base::{Message, ToName as _};
use socket_factory::{SocketFactory, TcpSocket};
use tokio::io::{AsyncReadExt as _, AsyncWriteExt as _};

pub async fn send(
    factory: Arc<dyn SocketFactory<TcpSocket>>,
    server: SocketAddr,
    query: Message<Vec<u8>>,
) -> io::Result<Message<Vec<u8>>> {
    let domain = query
        .sole_question()
        .expect("all queries should be for a single name")
        .qname()
        .to_vec();

    tracing::trace!(target: "wire::dns::recursive::tcp", %server, %domain);

    let tcp_socket = factory(&server)?; // TODO: Optimise this to reuse a TCP socket to the same resolver.
    let mut tcp_stream = tcp_socket.connect(server).await?;

    let query = query.into_octets();
    let dns_message_length = (query.len() as u16).to_be_bytes();

    tcp_stream.write_all(&dns_message_length).await?;
    tcp_stream.write_all(&query).await?;

    let mut response_length = [0u8; 2];
    tcp_stream.read_exact(&mut response_length).await?;
    let response_length = u16::from_be_bytes(response_length) as usize;

    // A u16 is at most 65k, meaning we are okay to allocate here based on what the remote is sending.
    let mut response = vec![0u8; response_length];
    tcp_stream.read_exact(&mut response).await?;

    let message = Message::from_octets(response)
        .map_err(|_| io::Error::other("Failed to parse DNS message"))?;

    Ok(message)
}
