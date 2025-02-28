//! A UDP-based DNS server that operates on layer 4, i.e. uses user-space sockets to send and receive packets.

#![cfg_attr(test, allow(clippy::unwrap_used))]

use anyhow::{anyhow, Context as _, Result};
use domain::base::Message;
use futures::{
    future::BoxFuture,
    stream::{self, BoxStream, FuturesUnordered},
    task::AtomicWaker,
    FutureExt, StreamExt as _,
};
use std::{
    io,
    net::{SocketAddr, SocketAddrV4, SocketAddrV6, ToSocketAddrs},
    sync::Arc,
    task::{Context, Poll},
};
use tokio::net::UdpSocket;

pub struct Server {
    udp_v4: Option<Arc<UdpSocket>>,
    udp_v6: Option<Arc<UdpSocket>>,

    reading_udp_v4_queries: BoxStream<'static, Result<(SocketAddr, Message<Vec<u8>>)>>,
    reading_udp_v6_queries: BoxStream<'static, Result<(SocketAddr, Message<Vec<u8>>)>>,

    sending_udp_responses: FuturesUnordered<BoxFuture<'static, Result<()>>>,

    waker: AtomicWaker,
}

impl Server {
    pub fn rebind_ipv4(&mut self, socket: SocketAddrV4) -> Result<()> {
        let udp_socket = Arc::new(make_udp_socket(socket)?);

        self.reading_udp_v4_queries = stream::repeat(Arc::downgrade(&udp_socket))
            .filter_map(|udp_socket| async move { udp_socket.upgrade() })
            .then(read_udp_query)
            .boxed();
        self.udp_v4 = Some(udp_socket);

        self.waker.wake();

        Ok(())
    }

    pub fn rebind_ipv6(&mut self, socket: SocketAddrV6) -> Result<()> {
        let udp_socket = Arc::new(make_udp_socket(socket)?);

        self.reading_udp_v6_queries = stream::repeat(Arc::downgrade(&udp_socket))
            .filter_map(|udp_socket| async move { udp_socket.upgrade() })
            .then(read_udp_query)
            .boxed();
        self.udp_v6 = Some(udp_socket);

        self.waker.wake();

        Ok(())
    }

    pub fn send_response(&mut self, to: SocketAddr, response: Message<Vec<u8>>) -> io::Result<()> {
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

    pub fn poll(&mut self, cx: &mut Context<'_>) -> Poll<io::Result<Query>> {
        loop {
            if let Poll::Ready(Some(result)) = self.sending_udp_responses.poll_next_unpin(cx) {
                result
                    .context("Failed to send UDP DNS response")
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

pub struct Query {
    pub source: SocketAddr,
    pub message: Message<Vec<u8>>,
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
                    .send_response(query.source, empty_dns_response(query.message))
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

    fn empty_dns_response(message: Message<Vec<u8>>) -> Message<Vec<u8>> {
        MessageBuilder::new_vec()
            .start_answer(&message, Rcode::NOERROR)
            .unwrap()
            .into_message()
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
