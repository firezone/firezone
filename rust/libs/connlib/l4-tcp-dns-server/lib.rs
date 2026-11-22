//! A TCP-based DNS server that operates on layer 4, i.e. uses user-space sockets to send and receive packets.

#![cfg_attr(test, allow(clippy::unwrap_used))]

use anyhow::{Context as _, Result};
use futures::{FutureExt as _, channel::oneshot, future::BoxFuture, task::AtomicWaker};
use futures_bounded::{Delay, FuturesMap, PushError};
use std::{
    collections::HashMap,
    io,
    net::{IpAddr, SocketAddr},
    task::{Context, Poll},
    time::Duration,
};
use tokio::{
    io::{AsyncReadExt as _, AsyncWriteExt as _},
    net::{TcpListener, TcpStream},
};

/// How long we wait for a client to send a query, or for a response to be sent to the client, before we close the connection.
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

pub struct Server {
    listener: Option<TcpListener>,

    /// One future for each open connection, either reading the next query or sending a response.
    connections: FuturesMap<SocketAddr, Result<Step>>,

    /// Where to send the response for a query we've read, by remote address.
    pending_responses: HashMap<SocketAddr, oneshot::Sender<dns_types::Response>>,

    waker: AtomicWaker,
}

/// The type of every future in [`Server::connections`], so [`FuturesMap::iter_of_type`] can find all of them.
type ConnectionStep = BoxFuture<'static, Result<Step>>;

enum Step {
    ReadQuery(Option<(dns_types::Query, TcpStream)>),
    SentResponse(TcpStream),
}

impl Default for Server {
    fn default() -> Self {
        Self {
            listener: None,
            connections: FuturesMap::new(|| Delay::tokio(TIMEOUT), MAX_CONNECTIONS),
            pending_responses: HashMap::default(),
            waker: AtomicWaker::default(),
        }
    }
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
        self.pending_responses
            .remove(&to)
            .ok_or_else(|| io::Error::other("No TCP stream"))?
            .send(response)
            .map_err(|_| io::Error::other("TCP stream closed"))
    }

    pub fn poll(&mut self, cx: &mut Context<'_>) -> Poll<io::Result<Query>> {
        loop {
            if let Poll::Ready((remote, result)) = self.connections.poll_unpin(cx) {
                let result = match result {
                    Ok(result) => result,
                    Err(_timeout) => {
                        tracing::debug!(%remote, "Closing idle TCP DNS connection");

                        self.pending_responses.remove(&remote);
                        continue;
                    }
                };

                match result {
                    Ok(Step::ReadQuery(Some((message, stream)))) => {
                        let local = stream.local_addr();

                        let (tx, rx) = oneshot::channel();
                        self.pending_responses.insert(remote, tx);
                        let _ = self.try_push(remote, send_response(stream, rx).boxed());

                        return Poll::Ready(local.map(|local| Query {
                            local,
                            remote,
                            message,
                        }));
                    }
                    Ok(Step::SentResponse(stream)) => {
                        // Clients may reuse TCP streams for multiple queries.
                        let _ = self.try_push(remote, read_query(stream).boxed());

                        continue;
                    }
                    Ok(Step::ReadQuery(None)) => continue,
                    Err(e) => {
                        self.pending_responses.remove(&remote);

                        return Poll::Ready(Err(anyhow_to_io(e)));
                    }
                }
            }

            if let Some(tcp) = self.listener.as_mut()
                && let Poll::Ready((stream, from)) = tcp.poll_accept(cx)?
            {
                if self.num_connections_from(from.ip()) >= MAX_CONNECTIONS_PER_IP {
                    tracing::debug!(%from, "Too many TCP DNS connections from IP; closing new connection");
                    continue;
                }

                match self.try_push(from, read_query(stream).boxed()) {
                    Ok(()) => {}
                    Err(PushError::BeyondCapacity(_)) => {
                        tracing::debug!(%from, "Too many TCP DNS connections; closing new connection");
                    }
                    Err(PushError::Replaced(_)) => {
                        self.pending_responses.remove(&from);
                    }
                }

                continue;
            }

            self.waker.register(cx.waker());
            return Poll::Pending;
        }
    }

    /// Pushes the next step of a connection.
    ///
    /// Pushing the step that follows a completed one can't fail: the completed step has freed its slot and its key.
    fn try_push(
        &mut self,
        remote: SocketAddr,
        step: ConnectionStep,
    ) -> Result<(), PushError<impl Sized + use<>>> {
        self.connections.try_push(remote, step)
    }

    fn num_connections_from(&self, ip: IpAddr) -> usize {
        self.connections
            .iter_of_type::<ConnectionStep>()
            .filter(|(remote, _)| remote.ip() == ip)
            .count()
    }
}

fn anyhow_to_io(e: anyhow::Error) -> io::Error {
    io::Error::other(format!("{e:#}"))
}

async fn read_query(mut stream: TcpStream) -> Result<Step> {
    let query = read_message(&mut stream)
        .await
        .context("Failed to read TCP DNS query")?;

    Ok(Step::ReadQuery(query.map(|query| (query, stream))))
}

async fn send_response(
    mut stream: TcpStream,
    response: oneshot::Receiver<dns_types::Response>,
) -> Result<Step> {
    let response = response.await.context("No response for TCP DNS query")?;
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

    Ok(Step::SentResponse(stream))
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

    #[tokio::test]
    async fn idle_connection_times_out() {
        let mut server = Server::default();
        server
            .rebind(SocketAddr::from((Ipv4Addr::LOCALHOST, 0)))
            .unwrap();
        let socket = server.listener.as_ref().unwrap().local_addr().unwrap();

        let start = tokio::time::Instant::now();
        assert_connection_closed(server, socket, TIMEOUT * 2).await;

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
            server
                .try_push(
                    SocketAddr::from((Ipv4Addr::new(10, 0, 0, 1), port)),
                    futures::future::pending().boxed(),
                )
                .unwrap();
        }

        assert_connection_closed(server, socket, Duration::from_secs(5)).await;
    }

    #[tokio::test]
    async fn closes_connections_over_per_ip_limit() {
        let mut server = Server::default();
        server
            .rebind(SocketAddr::from((Ipv4Addr::LOCALHOST, 0)))
            .unwrap();
        let socket = server.listener.as_ref().unwrap().local_addr().unwrap();

        for port in 0..MAX_CONNECTIONS_PER_IP as u16 {
            server
                .try_push(
                    SocketAddr::from((Ipv4Addr::LOCALHOST, port)),
                    futures::future::pending().boxed(),
                )
                .unwrap();
        }

        assert_connection_closed(server, socket, Duration::from_secs(5)).await;
    }

    async fn assert_connection_closed(mut server: Server, socket: SocketAddr, within: Duration) {
        let server_task = tokio::spawn(async move {
            loop {
                let _ = poll_fn(|cx| server.poll(cx)).await;
            }
        });

        let mut client = TcpStream::connect(socket).await.unwrap();

        let read = tokio::time::timeout(within, client.read(&mut [0; 1]))
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
