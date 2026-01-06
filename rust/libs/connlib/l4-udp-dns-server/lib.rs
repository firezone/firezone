//! A UDP-based DNS server that operates on layer 4, i.e. uses user-space sockets to send and receive packets.

#![cfg_attr(test, allow(clippy::unwrap_used))]

use anyhow::{Context as _, Result};
use futures::{
    FutureExt, StreamExt as _,
    future::BoxFuture,
    stream::{self, BoxStream, FuturesUnordered},
    task::AtomicWaker,
};
use std::{
    io,
    net::SocketAddr,
    sync::{Arc, Weak},
    task::{Context, Poll},
};
use tokio::net::UdpSocket;

pub struct Server {
    // Strong references to the UDP socket.
    socket: Option<Arc<UdpSocket>>,

    // Stream that read incoming queries from the UDP sockets.
    reading_udp_queries: BoxStream<'static, Result<(SocketAddr, dns_types::Query)>>,

    // Futures that send responses on the UDP socket.
    sending_udp_responses: FuturesUnordered<BoxFuture<'static, Result<()>>>,

    waker: AtomicWaker,
}

impl Server {
    pub fn rebind(&mut self, socket: SocketAddr) -> Result<()> {
        self.socket = None;
        self.reading_udp_queries = stream::empty().boxed();
        self.sending_udp_responses.clear();

        let udp_socket = Arc::new(make_udp_socket(socket)?);

        self.reading_udp_queries = udp_dns_query_stream(Arc::downgrade(&udp_socket));
        self.socket = Some(udp_socket);

        self.waker.wake();

        tracing::debug!(%socket, "Listening for UDP DNS queries");

        Ok(())
    }

    pub fn send_response(
        &mut self,
        to: SocketAddr,
        response: dns_types::Response,
    ) -> io::Result<()> {
        let udp_socket = self
            .socket
            .clone()
            .ok_or(io::Error::other("No UDP socket"))?;

        self.sending_udp_responses.push(
            async move {
                // TODO: Make this limit configurable.
                // The current 1200 are conservative and should be safe for the public Internet and our WireGuard tunnel.
                // Worst-case, the client will re-query over TCP.
                let payload = response.into_bytes(1200);

                udp_socket
                    .send_to(&payload, to)
                    .await
                    .context("Failed to send UDP response")?;

                Ok(())
            }
            .boxed(),
        );

        Ok(())
    }

    pub fn poll(&mut self, cx: &mut Context<'_>) -> Poll<io::Result<Query>> {
        loop {
            if let Poll::Ready(Some(result)) = self.sending_udp_responses.poll_next_unpin(cx) {
                result
                    .context("Failed to send UDP DNS response")
                    .map_err(anyhow_to_io)?;

                continue;
            }

            if let Poll::Ready(Some(result)) = self.reading_udp_queries.poll_next_unpin(cx) {
                let (remote, message) = result
                    .context("Failed to read UDP DNS query")
                    .map_err(anyhow_to_io)?;

                let local = self
                    .socket
                    .as_ref()
                    .context("No UDP socket")
                    .map_err(anyhow_to_io)?
                    .local_addr()?;

                return Poll::Ready(Ok(Query {
                    local,
                    remote,
                    message,
                }));
            }

            self.waker.register(cx.waker());
            return Poll::Pending;
        }
    }
}

/// Produces a stream of incoming DNS queries from a UDP socket for as long as there is at least one strong reference to the socket.
fn udp_dns_query_stream(
    udp_socket: Weak<UdpSocket>,
) -> BoxStream<'static, Result<(SocketAddr, dns_types::Query)>> {
    stream::repeat(udp_socket) // We start with an infinite stream of weak references to the UDP socket.
        .filter_map(|udp_socket| async move { udp_socket.upgrade() }) // For each item pulled from the stream, we first try to upgrade to a strong reference.
        .then(read_udp_query) // And then read single DNS query from the socket.
        .boxed()
}

fn anyhow_to_io(e: anyhow::Error) -> io::Error {
    io::Error::other(format!("{e:#}"))
}

async fn read_udp_query(socket: Arc<UdpSocket>) -> Result<(SocketAddr, dns_types::Query)> {
    let mut buffer = vec![0u8; 2000]; // On the public Internet, any MTU > 1500 is very unlikely so 2000 is a safe bet.

    let (len, from) = socket
        .recv_from(&mut buffer)
        .await
        .context("Failed to receive UDP packet")?;

    buffer.truncate(len);

    let message = dns_types::Query::parse(&buffer).context("Failed to parse DNS message")?;

    Ok((from, message))
}

pub struct Query {
    pub local: SocketAddr,
    pub remote: SocketAddr,
    pub message: dns_types::Query,
}

fn make_udp_socket(socket: SocketAddr) -> Result<UdpSocket> {
    let udp_socket = std::net::UdpSocket::bind(socket)
        .with_context(|| format!("Failed to bind UDP socket on {socket}"))?;
    udp_socket
        .set_nonblocking(true)
        .context("Failed to set socket as non-blocking")?;

    let udp_socket =
        UdpSocket::from_std(udp_socket).context("Failed to convert std to tokio socket")?;

    Ok(udp_socket)
}

impl Default for Server {
    fn default() -> Self {
        Self {
            socket: None,
            reading_udp_queries: stream::empty().boxed(),
            sending_udp_responses: FuturesUnordered::new(),
            waker: AtomicWaker::new(),
        }
    }
}

#[cfg(all(test, unix))]
mod tests {
    use std::future::poll_fn;
    use std::net::{Ipv4Addr, Ipv6Addr, SocketAddrV4, SocketAddrV6};
    use std::process::ExitStatus;

    use super::*;

    #[tokio::test]
    async fn smoke_ipv4() {
        let mut server = Server::default();

        let socket = SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::new(127, 0, 0, 1), 8080));

        let server_task = tokio::spawn(async move {
            server.rebind(socket).unwrap();

            loop {
                let query = poll_fn(|cx| server.poll(cx)).await.unwrap();

                server
                    .send_response(query.remote, dns_types::Response::no_error(&query.message))
                    .unwrap();
            }
        });

        assert!(dig(socket).await.success());
        assert!(dig(socket).await.success());
        assert!(dig(socket).await.success());

        assert!(!server_task.is_finished());

        server_task.abort();
    }

    #[tokio::test]
    async fn smoke_ipv6() {
        let mut server = Server::default();

        let socket = SocketAddr::V6(SocketAddrV6::new(
            Ipv6Addr::new(0, 0, 0, 0, 0, 0, 0, 1),
            8080,
            0,
            0,
        ));

        let server_task = tokio::spawn(async move {
            server.rebind(socket).unwrap();

            loop {
                let query = poll_fn(|cx| server.poll(cx)).await.unwrap();

                server
                    .send_response(query.remote, dns_types::Response::no_error(&query.message))
                    .unwrap();
            }
        });

        assert!(dig(socket).await.success());
        assert!(dig(socket).await.success());
        assert!(dig(socket).await.success());

        assert!(!server_task.is_finished());

        server_task.abort();
    }

    async fn dig(server: SocketAddr) -> ExitStatus {
        tokio::process::Command::new("dig")
            .arg(format!("@{}", server.ip()))
            .arg("+notcp")
            .arg("-p")
            .arg(server.port().to_string())
            .arg("foobar.com")
            .status()
            .await
            .unwrap()
    }
}
