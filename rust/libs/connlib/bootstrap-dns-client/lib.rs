#![cfg_attr(test, allow(clippy::unwrap_used))]

use std::{
    borrow::Cow,
    collections::BTreeSet,
    net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr},
    sync::Arc,
    time::Duration,
};

use anyhow::{Context as _, Result};
use dns_types::DomainName;
use futures::stream::FuturesUnordered;
use futures::stream::StreamExt as _;
use socket_factory::{SocketFactory, TcpSocket, UdpSocket};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

/// A DNS client for bootstrapping: resolving host names to IP addresses before
/// any tunnel exists (e.g. the portal host, or a DoH server's hostname).
///
/// All configured upstream servers are contacted in parallel over UDP and all
/// successful responses are merged together. If no usable IPs come back and no
/// upstream returned a definitive NXDOMAIN, the same set of queries is retried
/// over TCP (RFC 7766 §5) — this recovers from middleboxes that mangle or drop
/// UDP DNS responses, and from networks that block UDP/53 outright. NXDOMAIN
/// suppresses the retry because TCP cannot change a "name does not exist"
/// answer.
pub struct BootstrapDnsClient {
    udp_socket_factory: Arc<dyn SocketFactory<UdpSocket>>,
    tcp_socket_factory: Arc<dyn SocketFactory<TcpSocket>>,
    servers: Vec<SocketAddr>,
}

impl BootstrapDnsClient {
    const TIMEOUT: Duration = Duration::from_secs(2);
    const DNS_PORT: u16 = 53;

    pub fn new(
        udp_socket_factory: Arc<dyn SocketFactory<UdpSocket>>,
        tcp_socket_factory: Arc<dyn SocketFactory<TcpSocket>>,
        servers: Vec<IpAddr>,
    ) -> Self {
        Self {
            udp_socket_factory,
            tcp_socket_factory,
            servers: servers
                .into_iter()
                .map(|ip| SocketAddr::new(ip, Self::DNS_PORT))
                .collect(),
        }
    }

    #[cfg(test)]
    fn with_servers(
        udp_socket_factory: Arc<dyn SocketFactory<UdpSocket>>,
        tcp_socket_factory: Arc<dyn SocketFactory<TcpSocket>>,
        servers: Vec<SocketAddr>,
    ) -> Self {
        Self {
            udp_socket_factory,
            tcp_socket_factory,
            servers,
        }
    }

    pub fn resolve<H>(&self, host: H) -> impl Future<Output = Result<Vec<IpAddr>>> + use<H>
    where
        H: Into<Cow<'static, str>>,
    {
        let servers = self.servers.clone();
        let udp_socket_factory = self.udp_socket_factory.clone();
        let tcp_socket_factory = self.tcp_socket_factory.clone();
        let host = host.into();

        async move {
            anyhow::ensure!(!servers.is_empty(), "No servers specified");

            let domain =
                DomainName::vec_from_str(host.as_ref()).context("Failed to parse domain name")?;

            let build_queries = || {
                servers.iter().flat_map(|server| {
                    [
                        (
                            *server,
                            dns_types::Query::new(domain.clone(), dns_types::RecordType::A),
                        ),
                        (
                            *server,
                            dns_types::Query::new(domain.clone(), dns_types::RecordType::AAAA),
                        ),
                    ]
                })
            };

            let udp_responses = dispatch_all(build_queries(), |server, query| {
                send_query_udp(udp_socket_factory.clone(), server, query)
            })
            .await;

            let saw_nxdomain = udp_responses.iter().any(|response| {
                response.as_ref().is_ok_and(|response| {
                    response.response_code() == dns_types::ResponseCode::NXDOMAIN
                })
            });
            let ips = extract_ips(udp_responses);

            if !ips.is_empty() || saw_nxdomain {
                return Ok(ips);
            }

            tracing::debug!(
                %host,
                "UDP DNS yielded no usable IPs; retrying over TCP (RFC 7766 §5)"
            );

            let tcp_responses = dispatch_all(build_queries(), |server, query| {
                send_query_tcp(tcp_socket_factory.clone(), server, query)
            })
            .await;

            Ok(extract_ips(tcp_responses))
        }
    }
}

/// Dispatches each `(server, query)` pair concurrently and collects every response.
async fn dispatch_all<Fut>(
    queries: impl Iterator<Item = (SocketAddr, dns_types::Query)>,
    send: impl Fn(SocketAddr, dns_types::Query) -> Fut,
) -> Vec<Result<dns_types::Response>>
where
    Fut: Future<Output = Result<dns_types::Response>>,
{
    queries
        .map(|(server, query)| send(server, query))
        .collect::<FuturesUnordered<_>>()
        .collect()
        .await
}

fn extract_ips(responses: Vec<Result<dns_types::Response>>) -> Vec<IpAddr> {
    responses
        .into_iter()
        .flat_map(|result| result.inspect_err(|e| tracing::debug!("{e:#}")).ok())
        .filter(|response| response.response_code() == dns_types::ResponseCode::NOERROR)
        .flat_map(|response| {
            response
                .records()
                .filter_map(dns_types::records::extract_ip)
                .collect::<Vec<_>>()
        })
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect()
}

/// Sends a single DNS query over TCP per [RFC 1035 §4.2.2](https://datatracker.ietf.org/doc/html/rfc1035#section-4.2.2):
/// the message is preceded by a two-byte big-endian length, in both directions.
async fn send_query_tcp(
    socket_factory: Arc<dyn SocketFactory<TcpSocket>>,
    server: SocketAddr,
    query: dns_types::Query,
) -> Result<dns_types::Response> {
    let socket = socket_factory
        .bind(unspecified_bind_addr(server))
        .context("Failed to create TCP socket")?;

    let response = tokio::time::timeout(BootstrapDnsClient::TIMEOUT, async move {
        let mut stream = socket
            .connect(server)
            .await
            .context("Failed to connect TCP socket")?;

        let payload = query.into_bytes();
        let len: u16 = payload
            .len()
            .try_into()
            .context("DNS query exceeds 65535 bytes")?;

        stream
            .write_all(&len.to_be_bytes())
            .await
            .context("Failed to write TCP DNS length prefix")?;
        stream
            .write_all(&payload)
            .await
            .context("Failed to write TCP DNS payload")?;

        let mut len_buf = [0u8; 2];
        stream
            .read_exact(&mut len_buf)
            .await
            .context("Failed to read TCP DNS length prefix")?;
        let response_len = usize::from(u16::from_be_bytes(len_buf));

        let mut response_buf = vec![0u8; response_len];
        stream
            .read_exact(&mut response_buf)
            .await
            .context("Failed to read TCP DNS payload")?;

        anyhow::Ok(response_buf)
    })
    .await
    .with_context(|| format!("DNS query to host {server} timed out"))??;

    let response = dns_types::Response::parse(&response).context("Failed to parse DNS response")?;

    Ok(response)
}

async fn send_query_udp(
    socket_factory: Arc<dyn SocketFactory<UdpSocket>>,
    server: SocketAddr,
    query: dns_types::Query,
) -> Result<dns_types::Response> {
    // To avoid fragmentation, IP and thus also UDP packets can only reliably be sent with an MTU of <= 1500 on the public Internet.
    const BUF_SIZE: usize = 1500;

    let udp_socket = socket_factory
        .bind(unspecified_bind_addr(server))
        .context("Failed to bind UDP socket")?;

    let response = tokio::time::timeout(
        BootstrapDnsClient::TIMEOUT,
        udp_socket.handshake::<BUF_SIZE>(server, &query.into_bytes()),
    )
    .await
    .with_context(|| format!("DNS query to host {server} timed out"))??;

    let response = dns_types::Response::parse(&response).context("Failed to parse DNS response")?;

    Ok(response)
}

fn unspecified_bind_addr(server: SocketAddr) -> SocketAddr {
    match server {
        SocketAddr::V4(_) => SocketAddr::new(Ipv4Addr::UNSPECIFIED.into(), 0),
        SocketAddr::V6(_) => SocketAddr::new(Ipv6Addr::UNSPECIFIED.into(), 0),
    }
}

#[cfg(test)]
mod tests {
    use std::time::Instant;

    use super::*;

    #[tokio::test]
    #[ignore = "Requires Internet"]
    async fn can_resolve_host() {
        let client = BootstrapDnsClient::new(
            Arc::new(socket_factory::udp),
            Arc::new(socket_factory::tcp),
            vec![IpAddr::from([1, 1, 1, 1])],
        );

        let ips = client.resolve("example.com").await.unwrap();

        assert!(!ips.is_empty())
    }

    #[tokio::test]
    #[ignore = "Requires Internet"]
    async fn times_out_unreachable_host() {
        let client = BootstrapDnsClient::new(
            Arc::new(socket_factory::udp),
            Arc::new(socket_factory::tcp),
            vec![IpAddr::from([2, 2, 2, 2])],
        );

        let now = Instant::now();

        let ips = client.resolve("example.com").await.unwrap();

        assert!(ips.is_empty());
        assert!(now.elapsed() >= BootstrapDnsClient::TIMEOUT)
    }

    #[tokio::test]
    #[ignore = "Requires Internet"]
    async fn returns_all_valid_records() {
        let client = BootstrapDnsClient::new(
            Arc::new(socket_factory::udp),
            Arc::new(socket_factory::tcp),
            vec![IpAddr::from([1, 1, 1, 1]), IpAddr::from([2, 2, 2, 2])],
        );

        let now = Instant::now();

        let ips = client.resolve("example.com").await.unwrap();

        assert!(!ips.is_empty());
        assert!(now.elapsed() >= BootstrapDnsClient::TIMEOUT) // Still need to wait for the unreachable server.
    }

    #[tokio::test]
    async fn fails_without_servers() {
        let client = BootstrapDnsClient::new(
            Arc::new(socket_factory::udp),
            Arc::new(socket_factory::tcp),
            vec![],
        );

        let ips = client.resolve("example.com").await;

        assert_eq!(ips.unwrap_err().to_string(), "No servers specified")
    }

    #[tokio::test]
    async fn falls_back_to_tcp_when_udp_returns_lame_response() {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};

        // Reserve a TCP listener first so we can pin both servers to the same
        // port.
        let tcp = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let server_addr = tcp.local_addr().unwrap();
        let udp = tokio::net::UdpSocket::bind(server_addr).await.unwrap();

        // UDP stub: every query gets an empty NOERROR (no records) — the lame
        // answer we observed from a misbehaving home router.
        tokio::spawn(async move {
            let mut buf = vec![0u8; 1500];
            loop {
                let (n, peer) = udp.recv_from(&mut buf).await.unwrap();
                let query = dns_types::Query::parse(&buf[..n]).unwrap();
                let bytes =
                    dns_types::ResponseBuilder::for_query(&query, dns_types::ResponseCode::NOERROR)
                        .build()
                        .into_bytes(4096);
                udp.send_to(&bytes, peer).await.unwrap();
            }
        });

        // TCP stub: A queries get a real A record, AAAA queries an empty
        // NOERROR (no v6 mapping in this fixture).
        tokio::spawn(async move {
            loop {
                let (mut sock, _) = tcp.accept().await.unwrap();
                tokio::spawn(async move {
                    let mut len_buf = [0u8; 2];
                    sock.read_exact(&mut len_buf).await.unwrap();
                    let qlen = u16::from_be_bytes(len_buf) as usize;
                    let mut qbuf = vec![0u8; qlen];
                    sock.read_exact(&mut qbuf).await.unwrap();
                    let query = dns_types::Query::parse(&qbuf).unwrap();

                    let mut builder = dns_types::ResponseBuilder::for_query(
                        &query,
                        dns_types::ResponseCode::NOERROR,
                    );
                    if query.qtype() == dns_types::RecordType::A {
                        builder = builder.with_records([(
                            query.domain(),
                            60,
                            dns_types::records::a(Ipv4Addr::new(20, 40, 122, 20)),
                        )]);
                    }
                    let bytes = builder.build().into_bytes(4096);

                    sock.write_all(&(bytes.len() as u16).to_be_bytes())
                        .await
                        .unwrap();
                    sock.write_all(&bytes).await.unwrap();
                });
            }
        });

        let client = BootstrapDnsClient::with_servers(
            Arc::new(socket_factory::udp),
            Arc::new(socket_factory::tcp),
            vec![server_addr],
        );

        let ips = client.resolve("api.firez.one").await.unwrap();

        assert_eq!(ips, vec![IpAddr::from(Ipv4Addr::new(20, 40, 122, 20))]);
    }

    #[tokio::test]
    async fn skips_tcp_fallback_when_udp_already_returned_ips() {
        // UDP server returns a real answer; TCP socket is closed instantly so
        // any TCP connect attempt would fail immediately. The fact that
        // resolve() returns the UDP-side IP (and not an error) proves no TCP
        // fallback was attempted.
        let tcp = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let server_addr = tcp.local_addr().unwrap();
        drop(tcp); // Free the port so a TCP connect would get RST.
        let udp = tokio::net::UdpSocket::bind(server_addr).await.unwrap();

        tokio::spawn(async move {
            let mut buf = vec![0u8; 1500];
            loop {
                let (n, peer) = udp.recv_from(&mut buf).await.unwrap();
                let query = dns_types::Query::parse(&buf[..n]).unwrap();
                let mut builder =
                    dns_types::ResponseBuilder::for_query(&query, dns_types::ResponseCode::NOERROR);
                if query.qtype() == dns_types::RecordType::A {
                    builder = builder.with_records([(
                        query.domain(),
                        60,
                        dns_types::records::a(Ipv4Addr::new(127, 0, 0, 99)),
                    )]);
                }
                let bytes = builder.build().into_bytes(4096);
                udp.send_to(&bytes, peer).await.unwrap();
            }
        });

        let client = BootstrapDnsClient::with_servers(
            Arc::new(socket_factory::udp),
            Arc::new(socket_factory::tcp),
            vec![server_addr],
        );

        let ips = client.resolve("example.com").await.unwrap();

        assert_eq!(ips, vec![IpAddr::from(Ipv4Addr::new(127, 0, 0, 99))]);
    }

    #[tokio::test]
    async fn nxdomain_does_not_trigger_tcp_fallback() {
        use std::sync::atomic::{AtomicUsize, Ordering};

        let tcp = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let server_addr = tcp.local_addr().unwrap();
        let udp = tokio::net::UdpSocket::bind(server_addr).await.unwrap();

        let tcp_connects = Arc::new(AtomicUsize::new(0));
        let tcp_connects_for_task = tcp_connects.clone();

        tokio::spawn(async move {
            loop {
                let _ = tcp.accept().await.unwrap();
                tcp_connects_for_task.fetch_add(1, Ordering::SeqCst);
            }
        });

        tokio::spawn(async move {
            let mut buf = vec![0u8; 1500];
            loop {
                let (n, peer) = udp.recv_from(&mut buf).await.unwrap();
                let query = dns_types::Query::parse(&buf[..n]).unwrap();
                let bytes = dns_types::ResponseBuilder::for_query(
                    &query,
                    dns_types::ResponseCode::NXDOMAIN,
                )
                .build()
                .into_bytes(4096);
                udp.send_to(&bytes, peer).await.unwrap();
            }
        });

        let client = BootstrapDnsClient::with_servers(
            Arc::new(socket_factory::udp),
            Arc::new(socket_factory::tcp),
            vec![server_addr],
        );

        let ips = client.resolve("does-not-exist.example").await.unwrap();

        assert!(ips.is_empty());
        assert_eq!(tcp_connects.load(Ordering::SeqCst), 0);
    }

    #[tokio::test]
    async fn send_query_tcp_round_trips_a_record() {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        use tokio::net::TcpListener;

        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let server_addr = listener.local_addr().unwrap();

        tokio::spawn(async move {
            let (mut sock, _) = listener.accept().await.unwrap();
            let mut len_buf = [0u8; 2];
            sock.read_exact(&mut len_buf).await.unwrap();
            let qlen = u16::from_be_bytes(len_buf) as usize;
            let mut qbuf = vec![0u8; qlen];
            sock.read_exact(&mut qbuf).await.unwrap();
            let query = dns_types::Query::parse(&qbuf).unwrap();

            let response =
                dns_types::ResponseBuilder::for_query(&query, dns_types::ResponseCode::NOERROR)
                    .with_records([(
                        query.domain(),
                        60,
                        dns_types::records::a(Ipv4Addr::new(20, 40, 122, 20)),
                    )])
                    .build();
            let bytes = response.into_bytes(4096);

            sock.write_all(&(bytes.len() as u16).to_be_bytes())
                .await
                .unwrap();
            sock.write_all(&bytes).await.unwrap();
        });

        let domain = dns_types::DomainName::vec_from_str("api.firez.one").unwrap();
        let query = dns_types::Query::new(domain, dns_types::RecordType::A);

        let response = send_query_tcp(Arc::new(socket_factory::tcp), server_addr, query)
            .await
            .unwrap();

        let ips = response
            .records()
            .filter_map(dns_types::records::extract_ip)
            .collect::<Vec<_>>();

        assert_eq!(ips, vec![IpAddr::from(Ipv4Addr::new(20, 40, 122, 20))]);
    }
}
