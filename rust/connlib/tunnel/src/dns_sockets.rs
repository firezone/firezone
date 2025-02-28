use anyhow::{anyhow, Context as _, Result};
use domain::base::Message;
use futures::{
    future::BoxFuture,
    stream::{self, BoxStream, FuturesUnordered},
    task::AtomicWaker,
    FutureExt, StreamExt as _,
};
use std::{
    collections::HashMap,
    io,
    net::{SocketAddr, SocketAddrV4, SocketAddrV6, ToSocketAddrs},
    process::ExitStatus,
    sync::Arc,
    task::{Context, Poll},
};
use tokio::{
    io::{AsyncReadExt as _, AsyncWriteExt as _},
    net::{TcpListener, TcpStream, UdpSocket},
};

pub struct DnsSockets {
    udp_v4: Option<Arc<UdpSocket>>,
    udp_v6: Option<Arc<UdpSocket>>,

    reading_udp_v4_queries: BoxStream<'static, Result<(SocketAddr, Message<Vec<u8>>)>>,
    reading_udp_v6_queries: BoxStream<'static, Result<(SocketAddr, Message<Vec<u8>>)>>,

    sending_udp_responses: FuturesUnordered<BoxFuture<'static, Result<()>>>,

    tcp_v4: Option<TcpListener>,
    tcp_v6: Option<TcpListener>,

    tcp_streams_by_remote: HashMap<SocketAddr, TcpStream>,

    reading_tcp_queries: FuturesUnordered<
        BoxFuture<'static, Result<Option<(SocketAddr, Message<Vec<u8>>, TcpStream)>>>,
    >,
    sending_tcp_responses: FuturesUnordered<BoxFuture<'static, Result<(TcpStream, SocketAddr)>>>,

    waker: AtomicWaker,
}

impl DnsSockets {
    pub fn rebind_ipv4(&mut self, socket: SocketAddrV4) -> Result<()> {
        let udp_socket = Arc::new(make_udp_socket(socket)?);
        let tcp_listener = make_tcp_listener(socket)?;

        self.reading_udp_v4_queries = stream::repeat(Arc::downgrade(&udp_socket))
            .filter_map(|udp_socket| async move { udp_socket.upgrade() })
            .then(read_udp_query)
            .boxed();
        self.udp_v4 = Some(udp_socket);
        self.tcp_v4 = Some(tcp_listener);

        self.waker.wake();

        Ok(())
    }

    pub fn rebind_ipv6(&mut self, socket: SocketAddrV6) -> Result<()> {
        let udp_socket = Arc::new(make_udp_socket(socket)?);
        let tcp_listener = make_tcp_listener(socket)?;

        self.reading_udp_v6_queries = stream::repeat(Arc::downgrade(&udp_socket))
            .filter_map(|udp_socket| async move { udp_socket.upgrade() })
            .then(read_udp_query)
            .boxed();
        self.udp_v6 = Some(udp_socket);
        self.tcp_v6 = Some(tcp_listener);

        self.waker.wake();

        Ok(())
    }

    pub fn queue_udp_response(
        &mut self,
        to: SocketAddr,
        response: Message<Vec<u8>>,
    ) -> io::Result<()> {
        let udp_socket = match (to, self.udp_v4.clone(), self.udp_v6.clone()) {
            (SocketAddr::V4(_), Some(socket), _) => socket,
            (SocketAddr::V6(_), _, Some(socket)) => socket,
            (SocketAddr::V4(_), None, _) => return Err(io::Error::other("No UDPv4 socket")),
            (SocketAddr::V6(_), _, None) => return Err(io::Error::other("No UDPv6 socket")),
        };

        self.sending_udp_responses.push(
            async move {
                udp_socket
                    .send_to(response.as_slice(), to)
                    .await
                    .context("Failed to send UDP response")?;

                Ok(())
            }
            .boxed(),
        );

        Ok(())
    }

    pub fn queue_tcp_response(
        &mut self,
        to: SocketAddr,
        response: Message<Vec<u8>>,
    ) -> io::Result<()> {
        let mut stream = self
            .tcp_streams_by_remote
            .remove(&to)
            .ok_or_else(|| io::Error::other("No TCP stream"))?;

        self.sending_tcp_responses.push(
            async move {
                let len = response.as_slice().len() as u16;
                let len = len.to_be_bytes();

                stream
                    .write_all(&len)
                    .await
                    .context("Failed to write TCP DNS header")?;
                stream
                    .write_all(response.as_slice())
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
            if let Poll::Ready(Some(result)) = self.sending_udp_responses.poll_next_unpin(cx) {
                result
                    .context("Failed to send UDP DNS response")
                    .map_err(anyhow_to_io)?;

                continue;
            }

            if let Poll::Ready(Some(result)) = self.sending_tcp_responses.poll_next_unpin(cx) {
                let (stream, from) = result
                    .context("Failed to send TCP DNS response")
                    .map_err(anyhow_to_io)?;
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

                self.tcp_streams_by_remote.insert(from, stream);
                return Poll::Ready(Ok(Query {
                    source: from,
                    transport: Transport::Tcp,
                    message,
                }));
            }

            if let Poll::Ready(Some(result)) = self.reading_udp_v4_queries.poll_next_unpin(cx) {
                let (from, message) = result
                    .context("Failed to read UDPv4 DNS query")
                    .map_err(anyhow_to_io)?;

                return Poll::Ready(Ok(Query {
                    source: from,
                    transport: Transport::Udp,
                    message,
                }));
            }

            if let Poll::Ready(Some(result)) = self.reading_udp_v6_queries.poll_next_unpin(cx) {
                let (from, message) = result
                    .context("Failed to read UDPv6 DNS query")
                    .map_err(anyhow_to_io)?;

                return Poll::Ready(Ok(Query {
                    source: from,
                    transport: Transport::Udp,
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

async fn read_udp_query(socket: Arc<UdpSocket>) -> Result<(SocketAddr, Message<Vec<u8>>)> {
    let mut buffer = vec![0u8; 2000];

    let (len, from) = socket
        .recv_from(&mut buffer)
        .await
        .context("Failed to receive UDP packet")?;

    buffer.truncate(len);

    let message =
        Message::try_from_octets(buffer).map_err(|_| anyhow!("Failed to parse DNS message"))?;

    Ok((from, message))
}

async fn read_tcp_query(
    mut stream: TcpStream,
    from: SocketAddr,
) -> Result<Option<(SocketAddr, Message<Vec<u8>>, TcpStream)>> {
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

    let message =
        Message::try_from_octets(buf).map_err(|_| anyhow!("Failed to parse DNS message"))?;

    Ok(Some((from, message, stream)))
}

pub struct Query {
    pub source: SocketAddr,
    pub transport: Transport,
    pub message: Message<Vec<u8>>,
}

pub enum Transport {
    Udp,
    Tcp,
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

impl Default for DnsSockets {
    fn default() -> Self {
        Self {
            udp_v4: None,
            udp_v6: None,
            tcp_v4: None,
            tcp_v6: None,
            tcp_streams_by_remote: HashMap::new(),
            reading_udp_v4_queries: stream::empty().boxed(),
            reading_udp_v6_queries: stream::empty().boxed(),
            reading_tcp_queries: FuturesUnordered::new(),
            sending_tcp_responses: FuturesUnordered::new(),
            sending_udp_responses: FuturesUnordered::new(),
            waker: AtomicWaker::new(),
        }
    }
}

#[cfg(all(test, unix))]
mod tests {
    use domain::base::{iana::Rcode, MessageBuilder};
    use std::future::poll_fn;
    use std::net::{Ipv4Addr, Ipv6Addr};

    use super::*;

    #[tokio::test]
    async fn smoke() {
        let mut dns_sockets = DnsSockets::default();

        let v4_socket = SocketAddrV4::new(Ipv4Addr::new(127, 0, 0, 127), 8080);
        let v6_socket = SocketAddrV6::new(Ipv6Addr::new(0, 0, 0, 0, 0, 0, 0, 1), 8080, 0, 0);

        let server_task = tokio::spawn(async move {
            dns_sockets.rebind_ipv4(v4_socket).unwrap();
            dns_sockets.rebind_ipv6(v6_socket).unwrap();

            loop {
                let query = poll_fn(|cx| dns_sockets.poll(cx)).await.unwrap();

                let response = MessageBuilder::new_vec()
                    .start_answer(&query.message, Rcode::NOERROR)
                    .unwrap()
                    .into_message();

                match query.transport {
                    Transport::Udp => {
                        dns_sockets
                            .queue_udp_response(query.source, response)
                            .unwrap();
                    }
                    Transport::Tcp => {
                        dns_sockets
                            .queue_tcp_response(query.source, response)
                            .unwrap();
                    }
                }
            }
        });

        assert!(dig_udp(v4_socket.into()).await.success());
        assert!(dig_tcp(v4_socket.into()).await.success());
        assert!(dig_udp(v4_socket.into()).await.success());
        assert!(dig_tcp(v4_socket.into()).await.success());
        assert!(dig_udp(v4_socket.into()).await.success());
        assert!(dig_tcp(v4_socket.into()).await.success());

        assert!(dig_udp(v6_socket.into()).await.success());
        assert!(dig_tcp(v6_socket.into()).await.success());
        assert!(dig_udp(v6_socket.into()).await.success());
        assert!(dig_tcp(v6_socket.into()).await.success());
        assert!(dig_udp(v6_socket.into()).await.success());
        assert!(dig_tcp(v6_socket.into()).await.success());

        assert!(!server_task.is_finished());

        server_task.abort();
    }
}

async fn dig_udp(server: SocketAddr) -> ExitStatus {
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

async fn dig_tcp(server: SocketAddr) -> ExitStatus {
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
