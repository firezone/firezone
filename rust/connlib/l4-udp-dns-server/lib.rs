//! A UDP-based DNS server that operates on layer 4, i.e. uses user-space sockets to send and receive packets.

#![cfg_attr(test, allow(clippy::unwrap_used))]

use anyhow::{Context as _, Result};
use futures::{
    future::BoxFuture,
    stream::{self, BoxStream, FuturesUnordered},
    task::AtomicWaker,
    FutureExt, StreamExt as _,
};
use std::{
    io,
    net::{SocketAddr, SocketAddrV4, SocketAddrV6, ToSocketAddrs},
    sync::{Arc, Weak},
    task::{Context, Poll},
};
use tokio::net::UdpSocket;

pub struct Server {
    // Strong references to the UDP sockets.
    udp_v4: Option<Arc<UdpSocket>>,
    udp_v6: Option<Arc<UdpSocket>>,

    // Streams that read incoming queries from the UDP sockets.
    reading_udp_v4_queries: BoxStream<'static, Result<(SocketAddr, dns_types::Query)>>,
    reading_udp_v6_queries: BoxStream<'static, Result<(SocketAddr, dns_types::Query)>>,

    // Futures that send responses on the UDP sockets.
    sending_udp_v4_responses: FuturesUnordered<BoxFuture<'static, Result<()>>>,
    sending_udp_v6_responses: FuturesUnordered<BoxFuture<'static, Result<()>>>,

    waker: AtomicWaker,
}

impl Server {
    pub fn rebind_ipv4(&mut self, socket: SocketAddrV4) -> Result<()> {
        self.udp_v4 = None;
        self.reading_udp_v4_queries = stream::empty().boxed();
        self.sending_udp_v4_responses.clear();

        let udp_socket = Arc::new(make_udp_socket(socket)?);

        self.reading_udp_v4_queries = udp_dns_query_stream(Arc::downgrade(&udp_socket));
        self.udp_v4 = Some(udp_socket);

        self.waker.wake();

        tracing::info!(%socket, "Listening for UDP DNS queries");

        Ok(())
    }

    pub fn rebind_ipv6(&mut self, socket: SocketAddrV6) -> Result<()> {
        self.udp_v6 = None;
        self.reading_udp_v6_queries = stream::empty().boxed();
        self.sending_udp_v6_responses.clear();

        let udp_socket = Arc::new(make_udp_socket(socket)?);

        self.reading_udp_v6_queries = udp_dns_query_stream(Arc::downgrade(&udp_socket));
        self.udp_v6 = Some(udp_socket);

        self.waker.wake();

        tracing::info!(%socket, "Listening for UDP DNS queries");

        Ok(())
    }

    pub fn send_response(
        &mut self,
        to: SocketAddr,
        response: dns_types::Response,
    ) -> io::Result<()> {
        let (udp_socket, workers) = match (to, self.udp_v4.clone(), self.udp_v6.clone()) {
            (SocketAddr::V4(_), Some(socket), _) => (socket, &mut self.sending_udp_v4_responses),
            (SocketAddr::V6(_), _, Some(socket)) => (socket, &mut self.sending_udp_v6_responses),
            (SocketAddr::V4(_), None, _) => return Err(io::Error::other("No UDPv4 socket")),
            (SocketAddr::V6(_), _, None) => return Err(io::Error::other("No UDPv6 socket")),
        };

        workers.push(
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
            if let Poll::Ready(Some(result)) = self.sending_udp_v4_responses.poll_next_unpin(cx) {
                result
                    .context("Failed to send UDPv4 DNS response")
                    .map_err(anyhow_to_io)?;

                continue;
            }

            if let Poll::Ready(Some(result)) = self.sending_udp_v6_responses.poll_next_unpin(cx) {
                result
                    .context("Failed to send UDPv6 DNS response")
                    .map_err(anyhow_to_io)?;

                continue;
            }

            if let Poll::Ready(Some(result)) = self.reading_udp_v4_queries.poll_next_unpin(cx) {
                let (from, message) = result
                    .context("Failed to read UDPv4 DNS query")
                    .map_err(anyhow_to_io)?;

                return Poll::Ready(Ok(Query {
                    source: from,
                    message,
                }));
            }

            if let Poll::Ready(Some(result)) = self.reading_udp_v6_queries.poll_next_unpin(cx) {
                let (from, message) = result
                    .context("Failed to read UDPv6 DNS query")
                    .map_err(anyhow_to_io)?;

                return Poll::Ready(Ok(Query {
                    source: from,
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
    pub source: SocketAddr,
    pub message: dns_types::Query,
}

fn make_udp_socket(socket: impl ToSocketAddrs) -> Result<UdpSocket> {
    let udp_socket = std::net::UdpSocket::bind(socket).context("Failed to bind UDP socket")?;
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
            udp_v4: None,
            udp_v6: None,
            reading_udp_v4_queries: stream::empty().boxed(),
            reading_udp_v6_queries: stream::empty().boxed(),
            sending_udp_v4_responses: FuturesUnordered::new(),
            sending_udp_v6_responses: FuturesUnordered::new(),
            waker: AtomicWaker::new(),
        }
    }
}

#[cfg(all(test, unix))]
mod tests {
    use std::future::poll_fn;
    use std::net::{Ipv4Addr, Ipv6Addr};
    use std::process::ExitStatus;

    use super::*;

    #[tokio::test]
    async fn smoke() {
        let mut server = Server::default();

        let v4_socket = SocketAddrV4::new(Ipv4Addr::new(127, 0, 0, 127), 8080);
        let v6_socket = SocketAddrV6::new(Ipv6Addr::new(0, 0, 0, 0, 0, 0, 0, 1), 8080, 0, 0);

        let server_task = tokio::spawn(async move {
            server.rebind_ipv4(v4_socket).unwrap();
            server.rebind_ipv6(v6_socket).unwrap();

            loop {
                let query = poll_fn(|cx| server.poll(cx)).await.unwrap();

                server
                    .send_response(query.source, dns_types::Response::no_error(&query.message))
                    .unwrap();
            }
        });

        assert!(dig(v4_socket.into()).await.success());
        assert!(dig(v4_socket.into()).await.success());
        assert!(dig(v4_socket.into()).await.success());

        assert!(dig(v6_socket.into()).await.success());
        assert!(dig(v6_socket.into()).await.success());
        assert!(dig(v6_socket.into()).await.success());

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
