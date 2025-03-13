//! A TCP-based DNS server that operates on layer 4, i.e. uses user-space sockets to send and receive packets.

#![cfg_attr(test, allow(clippy::unwrap_used))]

use anyhow::{Context as _, Result};
use futures::{
    future::BoxFuture, stream::FuturesUnordered, task::AtomicWaker, FutureExt, StreamExt as _,
};
use std::{
    collections::HashMap,
    io,
    net::{SocketAddr, SocketAddrV4, SocketAddrV6, ToSocketAddrs},
    task::{Context, Poll},
};
use tokio::{
    io::{AsyncReadExt as _, AsyncWriteExt as _},
    net::{TcpListener, TcpStream},
};

#[derive(Default)]
pub struct Server {
    tcp_v4: Option<TcpListener>,
    tcp_v6: Option<TcpListener>,

    /// Tracks open TCP streams by their remote address.
    ///
    /// After reading a query from the stream, we keep the stream around in here to send a response back.
    tcp_streams_by_remote: HashMap<SocketAddr, TcpStream>,

    /// A set of futures that read DNS queries from TCP streams.
    #[expect(clippy::type_complexity, reason = "We don't care.")]
    reading_tcp_queries: FuturesUnordered<
        BoxFuture<'static, Result<Option<(SocketAddr, dns_types::Query, TcpStream)>>>,
    >,
    /// A set of futures that send DNS responses over TCP streams.
    sending_tcp_responses: FuturesUnordered<BoxFuture<'static, Result<(TcpStream, SocketAddr)>>>,

    waker: AtomicWaker,
}

impl Server {
    pub fn rebind_ipv4(&mut self, socket: SocketAddrV4) -> Result<()> {
        self.tcp_v4 = None;

        let tcp_listener = make_tcp_listener(socket)?;

        self.tcp_v4 = Some(tcp_listener);

        self.waker.wake();

        tracing::info!(%socket, "Listening for TCP DNS queries");

        Ok(())
    }

    pub fn rebind_ipv6(&mut self, socket: SocketAddrV6) -> Result<()> {
        self.tcp_v6 = None;

        let tcp_listener = make_tcp_listener(socket)?;

        self.tcp_v6 = Some(tcp_listener);

        self.waker.wake();

        tracing::info!(%socket, "Listening for TCP DNS queries");

        Ok(())
    }

    pub fn send_response(
        &mut self,
        to: SocketAddr,
        response: dns_types::Response,
    ) -> io::Result<()> {
        let mut stream = self
            .tcp_streams_by_remote
            .remove(&to)
            .ok_or_else(|| io::Error::other("No TCP stream"))?;

        self.sending_tcp_responses.push(
            async move {
                let response = response.into_bytes(u16::MAX); // DNS over TCP has a 16-bit length field, we can't encode anything bigger than that.

                let len = response.len() as u16;
                let len = len.to_be_bytes();

                stream
                    .write_all(&len)
                    .await
                    .context("Failed to write TCP DNS header")?;
                stream
                    .write_all(&response)
                    .await
                    .context("Failed to write TCP DNS message")?;

                Ok((stream, to))
            }
            .boxed(),
        );

        Ok(())
    }

    pub fn poll(&mut self, cx: &mut Context<'_>) -> Poll<io::Result<Query>> {
        loop {
            if let Poll::Ready(Some(result)) = self.sending_tcp_responses.poll_next_unpin(cx) {
                let (stream, from) = result
                    .context("Failed to send TCP DNS response")
                    .map_err(anyhow_to_io)?;

                // We've successfully sent a response back, try to read another query. (Clients may reuse TCP streams for multiple queries.)
                self.reading_tcp_queries
                    .push(read_tcp_query(stream, from).boxed());

                continue;
            }

            if let Poll::Ready(Some(result)) = self.reading_tcp_queries.poll_next_unpin(cx) {
                let Some((from, message, stream)) = result
                    .context("Failed to read TCP DNS query")
                    .map_err(anyhow_to_io)?
                else {
                    continue;
                };

                let local = stream.local_addr()?;

                // Store the stream so we can send a response back later.
                // We don't need to index by the local address because we only ever listen on a single socket.
                self.tcp_streams_by_remote.insert(from, stream);

                return Poll::Ready(Ok(Query {
                    local,
                    remote: from,
                    message,
                }));
            }

            if let Some(tcp_v4) = self.tcp_v4.as_mut() {
                if let Poll::Ready((stream, from)) = tcp_v4.poll_accept(cx)? {
                    self.reading_tcp_queries
                        .push(read_tcp_query(stream, from).boxed());
                    continue;
                }
            }

            if let Some(tcp_v6) = self.tcp_v6.as_mut() {
                if let Poll::Ready((stream, from)) = tcp_v6.poll_accept(cx)? {
                    self.reading_tcp_queries
                        .push(read_tcp_query(stream, from).boxed());
                    continue;
                }
            }

            self.waker.register(cx.waker());
            return Poll::Pending;
        }
    }
}

fn anyhow_to_io(e: anyhow::Error) -> io::Error {
    io::Error::other(format!("{e:#}"))
}

/// Read a TCP query from a stream, returning the source address, the message and stream so we can later send a response back.
async fn read_tcp_query(
    mut stream: TcpStream,
    from: SocketAddr,
) -> Result<Option<(SocketAddr, dns_types::Query, TcpStream)>> {
    let mut buf = [0; 2];
    match stream.read_exact(&mut buf).await {
        Ok(2) => {}
        Ok(_) => return Ok(None),
        Err(e) if e.kind() == io::ErrorKind::UnexpectedEof => return Ok(None),
        Err(e) => return Err(anyhow::Error::new(e).context("Failed to read TCP DNS header")),
    }

    let len = u16::from_be_bytes(buf) as usize;

    let mut buf = vec![0; len];
    stream
        .read_exact(&mut buf)
        .await
        .context("Failed to read TCP DNS message")?;

    let message = dns_types::Query::parse(&buf).context("Failed to parse DNS message")?;

    Ok(Some((from, message, stream)))
}

pub struct Query {
    pub local: SocketAddr,
    pub remote: SocketAddr,
    pub message: dns_types::Query,
}

fn make_tcp_listener(socket: impl ToSocketAddrs) -> Result<TcpListener> {
    let tcp_listener =
        std::net::TcpListener::bind(socket).context("Failed to bind TCP listener")?;
    tcp_listener
        .set_nonblocking(true)
        .context("Failed to set listener to non-blocking")?;

    let tcp_listener =
        TcpListener::from_std(tcp_listener).context("Failed to convert std to tokio listener")?;

    Ok(tcp_listener)
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
                    .send_response(query.remote, dns_types::Response::no_error(&query.message))
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
            .arg("+tcp")
            .arg("-p")
            .arg(server.port().to_string())
            .arg("foobar.com")
            .status()
            .await
            .unwrap()
    }
}
