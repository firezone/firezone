//! A TCP-based DNS server that operates on layer 4, i.e. uses user-space sockets to send and receive packets.

#![cfg_attr(test, allow(clippy::unwrap_used))]

use anyhow::{Context as _, Result};
use futures::{
    FutureExt, StreamExt as _, future::BoxFuture, stream::FuturesUnordered, task::AtomicWaker,
};
use std::{
    collections::HashMap,
    io,
    net::{IpAddr, SocketAddr},
    pin::Pin,
    task::{Context, Poll},
    time::Duration,
};
use tokio::{
    io::{AsyncReadExt as _, AsyncWriteExt as _},
    net::{TcpListener, TcpStream},
};

/// How long we wait for a client to send a query or to accept a response before we close the connection.
const TIMEOUT: Duration = Duration::from_secs(10);

/// How many TCP connections one [`Server`] keeps open at most.
///
/// A client keeps one connection open to each server it sends queries to, and a Gateway supports up to 1000 clients.
///
/// When this limit is hit, the server accepts each new connection and closes it at once, without reading a query.
/// Open connections are not affected.
const MAX_CONNECTIONS: usize = 1024;

/// How many TCP connections one remote IP can keep open at most.
///
/// A client needs one, and a second one for a short time while it reconnects.
///
/// When this limit is hit, the server accepts each new connection from that IP and closes it at once, without reading a query.
/// Other IPs and open connections are not affected.
const MAX_CONNECTIONS_PER_IP: usize = 4;

#[derive(Default)]
pub struct Server {
    listener: Option<TcpListener>,

    /// Tracks open TCP streams by their remote address.
    ///
    /// After reading a query from the stream, we keep the stream around in here to send a response back.
    tcp_streams_by_remote: HashMap<SocketAddr, TcpStream>,

    /// A set of futures that read DNS queries from TCP streams.
    reading_tcp_queries: FuturesUnordered<
        WithRemote<BoxFuture<'static, Result<Option<(SocketAddr, dns_types::Query, TcpStream)>>>>,
    >,
    /// A set of futures that send DNS responses over TCP streams.
    sending_tcp_responses:
        FuturesUnordered<WithRemote<BoxFuture<'static, Result<(TcpStream, SocketAddr)>>>>,

    waker: AtomicWaker,
}

impl Server {
    pub fn rebind(&mut self, socket: SocketAddr) -> Result<()> {
        self.listener = None;

        let tcp_listener = make_tcp_listener(socket)?;

        self.listener = Some(tcp_listener);

        self.waker.wake();

        tracing::debug!(%socket, "Listening for TCP DNS queries");

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

        self.sending_tcp_responses.push(WithRemote {
            remote: to,
            future: async move {
                let response = response.into_bytes(u16::MAX); // DNS over TCP has a 16-bit length field, we can't encode anything bigger than that.

                let len = response.len() as u16;
                let len = len.to_be_bytes();

                tokio::time::timeout(TIMEOUT, async {
                    stream
                        .write_all(&len)
                        .await
                        .context("Failed to write TCP DNS header")?;
                    stream
                        .write_all(&response)
                        .await
                        .context("Failed to write TCP DNS message")?;

                    anyhow::Ok(())
                })
                .await
                .context("Timed out writing TCP DNS response")??;

                Ok((stream, to))
            }
            .boxed(),
        });

        Ok(())
    }

    pub fn poll(&mut self, cx: &mut Context<'_>) -> Poll<io::Result<Query>> {
        loop {
            if let Poll::Ready(Some(result)) = self.sending_tcp_responses.poll_next_unpin(cx) {
                let (stream, from) = result
                    .context("Failed to send TCP DNS response")
                    .map_err(anyhow_to_io)?;

                // We've successfully sent a response back, try to read another query. (Clients may reuse TCP streams for multiple queries.)
                self.reading_tcp_queries.push(WithRemote {
                    remote: from,
                    future: read_tcp_query(stream, from).boxed(),
                });

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

            if let Some(tcp) = self.listener.as_mut()
                && let Poll::Ready((stream, from)) = tcp.poll_accept(cx)?
            {
                if self.num_connections() >= MAX_CONNECTIONS {
                    tracing::debug!(%from, "Too many TCP DNS connections; closing new connection");
                    continue;
                }

                if self.num_connections_from(from.ip()) >= MAX_CONNECTIONS_PER_IP {
                    tracing::debug!(%from, "Too many TCP DNS connections from IP; closing new connection");
                    continue;
                }

                self.reading_tcp_queries.push(WithRemote {
                    remote: from,
                    future: read_tcp_query(stream, from).boxed(),
                });
                continue;
            }

            self.waker.register(cx.waker());
            return Poll::Pending;
        }
    }

    fn num_connections(&self) -> usize {
        self.reading_tcp_queries.len()
            + self.tcp_streams_by_remote.len()
            + self.sending_tcp_responses.len()
    }

    fn num_connections_from(&self, ip: IpAddr) -> usize {
        self.reading_tcp_queries
            .iter()
            .map(|f| f.remote)
            .chain(self.tcp_streams_by_remote.keys().copied())
            .chain(self.sending_tcp_responses.iter().map(|f| f.remote))
            .filter(|remote| remote.ip() == ip)
            .count()
    }
}

/// A future that owns the TCP stream of the given remote.
struct WithRemote<F> {
    remote: SocketAddr,
    future: F,
}

impl<F> Future for WithRemote<F>
where
    F: Future + Unpin,
{
    type Output = F::Output;

    fn poll(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output> {
        self.future.poll_unpin(cx)
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
    let Ok(message) = tokio::time::timeout(TIMEOUT, read_message(&mut stream)).await else {
        tracing::debug!(%from, "Closing idle TCP DNS connection");

        return Ok(None);
    };

    Ok(message?.map(|message| (from, message, stream)))
}

async fn read_message(stream: &mut TcpStream) -> Result<Option<dns_types::Query>> {
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

    Ok(Some(message))
}

pub struct Query {
    pub local: SocketAddr,
    pub remote: SocketAddr,
    pub message: dns_types::Query,
}

fn make_tcp_listener(socket: SocketAddr) -> Result<TcpListener> {
    let tcp_listener = std::net::TcpListener::bind(socket)
        .with_context(|| format!("Failed to bind TCP listener on {socket}"))?;
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
    use std::net::{Ipv4Addr, Ipv6Addr, SocketAddrV4, SocketAddrV6};
    use std::process::ExitStatus;

    use super::*;

    #[tokio::test]
    #[cfg_attr(
        any(target_os = "android", target_os = "ios"),
        ignore = "Needs the `dig` binary"
    )]
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
    #[cfg_attr(
        any(target_os = "android", target_os = "ios"),
        ignore = "Needs the `dig` binary"
    )]
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

    #[tokio::test(start_paused = true)]
    async fn idle_connection_times_out() {
        let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).await.unwrap();
        let _client = TcpStream::connect(listener.local_addr().unwrap())
            .await
            .unwrap();
        let (stream, from) = listener.accept().await.unwrap();

        let start = tokio::time::Instant::now();
        let query = tokio::time::timeout(TIMEOUT * 2, read_tcp_query(stream, from))
            .await
            .expect("Reading from an idle connection should time out")
            .unwrap();

        assert!(query.is_none());
        assert!(start.elapsed() >= TIMEOUT);
    }

    #[tokio::test]
    async fn closes_connections_over_limit() {
        let mut server = Server::default();
        server
            .rebind(SocketAddr::from((Ipv4Addr::LOCALHOST, 0)))
            .unwrap();
        let socket = server.listener.as_ref().unwrap().local_addr().unwrap();

        for port in 0..MAX_CONNECTIONS as u16 {
            server.reading_tcp_queries.push(WithRemote {
                remote: SocketAddr::from((Ipv4Addr::new(10, 0, 0, 1), port)),
                future: futures::future::pending().boxed(),
            });
        }

        assert_connection_closed(server, socket).await;
    }

    #[tokio::test]
    async fn closes_connections_over_per_ip_limit() {
        let mut server = Server::default();
        server
            .rebind(SocketAddr::from((Ipv4Addr::LOCALHOST, 0)))
            .unwrap();
        let socket = server.listener.as_ref().unwrap().local_addr().unwrap();

        for port in 0..MAX_CONNECTIONS_PER_IP as u16 {
            server.reading_tcp_queries.push(WithRemote {
                remote: SocketAddr::from((Ipv4Addr::LOCALHOST, port)),
                future: futures::future::pending().boxed(),
            });
        }

        assert_connection_closed(server, socket).await;
    }

    async fn assert_connection_closed(mut server: Server, socket: SocketAddr) {
        let server_task = tokio::spawn(async move {
            loop {
                let _ = poll_fn(|cx| server.poll(cx)).await;
            }
        });

        let mut client = TcpStream::connect(socket).await.unwrap();

        let read = tokio::time::timeout(Duration::from_secs(5), client.read(&mut [0; 1]))
            .await
            .expect("Server should close the connection")
            .unwrap();

        assert_eq!(read, 0);

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
