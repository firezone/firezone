//! A TCP-based DNS server that operates on layer 4, i.e. uses user-space sockets to send and receive packets.

#![cfg_attr(test, allow(clippy::unwrap_used))]

use anyhow::{Context as _, Result};
use futures::{
    FutureExt, StreamExt as _, future::BoxFuture, stream::FuturesUnordered, task::AtomicWaker,
};
use parking_lot::Mutex;
use std::{
    collections::{HashMap, hash_map::Entry},
    io,
    net::{IpAddr, SocketAddr},
    sync::Arc,
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
    tcp_streams_by_remote: HashMap<SocketAddr, Connection>,

    /// A set of futures that read DNS queries from TCP streams.
    reading_tcp_queries: FuturesUnordered<
        BoxFuture<'static, Result<Option<(SocketAddr, dns_types::Query, Connection)>>>,
    >,
    /// A set of futures that send DNS responses over TCP streams.
    sending_tcp_responses: FuturesUnordered<BoxFuture<'static, Result<(Connection, SocketAddr)>>>,

    /// How many connections are open for each remote IP.
    connections_by_ip: Arc<Mutex<HashMap<IpAddr, usize>>>,

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
        let mut connection = self
            .tcp_streams_by_remote
            .remove(&to)
            .ok_or_else(|| io::Error::other("No TCP stream"))?;

        self.sending_tcp_responses.push(
            async move {
                let response = response.into_bytes(u16::MAX); // DNS over TCP has a 16-bit length field, we can't encode anything bigger than that.

                let len = response.len() as u16;
                let len = len.to_be_bytes();

                tokio::time::timeout(TIMEOUT, async {
                    connection
                        .stream
                        .write_all(&len)
                        .await
                        .context("Failed to write TCP DNS header")?;
                    connection
                        .stream
                        .write_all(&response)
                        .await
                        .context("Failed to write TCP DNS message")?;

                    anyhow::Ok(())
                })
                .await
                .context("Timed out writing TCP DNS response")??;

                Ok((connection, to))
            }
            .boxed(),
        );

        Ok(())
    }

    pub fn poll(&mut self, cx: &mut Context<'_>) -> Poll<io::Result<Query>> {
        loop {
            if let Poll::Ready(Some(result)) = self.sending_tcp_responses.poll_next_unpin(cx) {
                let (connection, from) = result
                    .context("Failed to send TCP DNS response")
                    .map_err(anyhow_to_io)?;

                // We've successfully sent a response back, try to read another query. (Clients may reuse TCP streams for multiple queries.)
                self.reading_tcp_queries
                    .push(read_tcp_query(connection, from).boxed());

                continue;
            }

            if let Poll::Ready(Some(result)) = self.reading_tcp_queries.poll_next_unpin(cx) {
                let Some((from, message, connection)) = result
                    .context("Failed to read TCP DNS query")
                    .map_err(anyhow_to_io)?
                else {
                    continue;
                };

                let local = connection.stream.local_addr()?;

                // Store the stream so we can send a response back later.
                // We don't need to index by the local address because we only ever listen on a single socket.
                self.tcp_streams_by_remote.insert(from, connection);

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

                let Some(permit) = self.try_acquire_permit(from.ip()) else {
                    tracing::debug!(%from, "Too many TCP DNS connections from IP; closing new connection");
                    continue;
                };

                self.reading_tcp_queries.push(
                    read_tcp_query(
                        Connection {
                            stream,
                            _permit: permit,
                        },
                        from,
                    )
                    .boxed(),
                );
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

    fn try_acquire_permit(&self, ip: IpAddr) -> Option<Permit> {
        let mut connections_by_ip = self.connections_by_ip.lock();
        let count = connections_by_ip.entry(ip).or_default();

        if *count >= MAX_CONNECTIONS_PER_IP {
            return None;
        }

        *count += 1;

        Some(Permit {
            ip,
            connections_by_ip: self.connections_by_ip.clone(),
        })
    }
}

/// An open TCP connection, counted against the limit for its remote IP until it is dropped.
struct Connection {
    stream: TcpStream,
    _permit: Permit,
}

struct Permit {
    ip: IpAddr,
    connections_by_ip: Arc<Mutex<HashMap<IpAddr, usize>>>,
}

impl Drop for Permit {
    fn drop(&mut self) {
        let mut connections_by_ip = self.connections_by_ip.lock();

        let Entry::Occupied(mut entry) = connections_by_ip.entry(self.ip) else {
            return;
        };

        *entry.get_mut() -= 1;

        if *entry.get() == 0 {
            entry.remove();
        }
    }
}

fn anyhow_to_io(e: anyhow::Error) -> io::Error {
    io::Error::other(format!("{e:#}"))
}

/// Read a TCP query from a stream, returning the source address, the message and stream so we can later send a response back.
async fn read_tcp_query(
    mut connection: Connection,
    from: SocketAddr,
) -> Result<Option<(SocketAddr, dns_types::Query, Connection)>> {
    let Ok(message) = tokio::time::timeout(TIMEOUT, read_message(&mut connection.stream)).await
    else {
        tracing::debug!(%from, "Closing idle TCP DNS connection");

        return Ok(None);
    };

    Ok(message?.map(|message| (from, message, connection)))
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
        let server = Server::default();
        let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).await.unwrap();
        let _client = TcpStream::connect(listener.local_addr().unwrap())
            .await
            .unwrap();
        let (stream, from) = listener.accept().await.unwrap();
        let connection = Connection {
            stream,
            _permit: server.try_acquire_permit(from.ip()).unwrap(),
        };

        let start = tokio::time::Instant::now();
        let query = tokio::time::timeout(TIMEOUT * 2, read_tcp_query(connection, from))
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

        for _ in 0..MAX_CONNECTIONS {
            server
                .reading_tcp_queries
                .push(futures::future::pending().boxed());
        }

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

    #[tokio::test]
    async fn closes_connections_over_per_ip_limit() {
        let mut server = Server::default();
        server
            .rebind(SocketAddr::from((Ipv4Addr::LOCALHOST, 0)))
            .unwrap();
        let socket = server.listener.as_ref().unwrap().local_addr().unwrap();

        let permits = (0..MAX_CONNECTIONS_PER_IP)
            .map(|_| {
                server
                    .try_acquire_permit(Ipv4Addr::LOCALHOST.into())
                    .unwrap()
            })
            .collect::<Vec<_>>();

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

        drop(permits);
        server_task.abort();
    }

    #[test]
    fn dropping_permits_frees_connections_for_ip() {
        let server = Server::default();
        let ip = IpAddr::from(Ipv4Addr::LOCALHOST);

        let permits = (0..MAX_CONNECTIONS_PER_IP)
            .map(|_| server.try_acquire_permit(ip).unwrap())
            .collect::<Vec<_>>();

        assert!(server.try_acquire_permit(ip).is_none());
        assert!(
            server
                .try_acquire_permit(Ipv4Addr::new(127, 0, 0, 2).into())
                .is_some()
        );

        drop(permits);

        assert!(server.connections_by_ip.lock().is_empty());
        assert!(server.try_acquire_permit(ip).is_some());
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
