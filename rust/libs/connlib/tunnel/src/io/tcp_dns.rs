use std::{net::SocketAddr, sync::Arc};

use anyhow::Result;
use socket_factory::{SocketFactory, TcpSocket};
use tokio::io::{AsyncReadExt as _, AsyncWriteExt as _};

use crate::dns;

pub async fn send(
    factory: Arc<dyn SocketFactory<TcpSocket>>,
    server: SocketAddr,
    query: dns_types::Query,
) -> Result<dns_types::Response> {
    let domain = query.domain();
    let qtype = query.qtype();

    tracing::trace!(target: "wire::dns::recursive::qry", %server, transport = %dns::Transport::Tcp, "{qtype} {domain}");

    let tcp_socket = factory.bind(server)?; // TODO: Optimise this to reuse a TCP socket to the same resolver.
    let mut tcp_stream = tcp_socket.connect(server).await?;

    let query = query.into_bytes();
    let dns_message_length = (query.len() as u16).to_be_bytes();

    tcp_stream.write_all(&dns_message_length).await?;
    tcp_stream.write_all(&query).await?;

    let mut response_length = [0u8; 2];
    tcp_stream.read_exact(&mut response_length).await?;
    let response_length = u16::from_be_bytes(response_length) as usize;

    // A u16 is at most 65k, meaning we are okay to allocate here based on what the remote is sending.
    let mut response = vec![0u8; response_length];
    tcp_stream.read_exact(&mut response).await?;

    let response = dns_types::Response::parse(&response)?;

    tracing::trace!(target: "wire::dns::recursive::res", %server, transport = %dns::Transport::Tcp, "{qtype} {domain} => {}", response.response_code());

    Ok(response)
}
