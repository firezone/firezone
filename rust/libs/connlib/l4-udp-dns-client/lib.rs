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
use socket_factory::{SocketFactory, UdpSocket};

/// A UDP DNS client, specialised for resolving host names to IP addresses.
///
/// The implementation uses a multi-shot approach where all configured upstream servers are contacted in parallel.
/// All successful responses are merged together.
pub struct UdpDnsClient {
    socket_factory: Arc<dyn SocketFactory<UdpSocket>>,
    servers: Vec<IpAddr>,
}

impl UdpDnsClient {
    const TIMEOUT: Duration = Duration::from_secs(2);

    pub fn new(socket_factory: Arc<dyn SocketFactory<UdpSocket>>, servers: Vec<IpAddr>) -> Self {
        Self {
            socket_factory,
            servers,
        }
    }

    pub fn resolve<H>(&self, host: H) -> impl Future<Output = Result<Vec<IpAddr>>> + use<H>
    where
        H: Into<Cow<'static, str>>,
    {
        let servers = self.servers.clone();
        let socket_factory = self.socket_factory.clone();
        let host = host.into();

        async move {
            anyhow::ensure!(!servers.is_empty(), "No servers specified");

            let domain =
                DomainName::vec_from_str(host.as_ref()).context("Failed to parse domain name")?;

            let ips = servers
                .iter()
                .flat_map(|socket| {
                    let socket = SocketAddr::new(*socket, 53);

                    [
                        send_query(
                            socket_factory.clone(),
                            socket,
                            dns_types::Query::new(domain.clone(), dns_types::RecordType::A),
                        ),
                        send_query(
                            socket_factory.clone(),
                            socket,
                            dns_types::Query::new(domain.clone(), dns_types::RecordType::AAAA),
                        ),
                    ]
                })
                .collect::<FuturesUnordered<_>>()
                .collect::<Vec<_>>()
                .await
                .into_iter()
                .flat_map(|result| result.inspect_err(|e| tracing::debug!("{e:#}")).ok())
                .filter(|response| response.response_code() == dns_types::ResponseCode::NOERROR)
                .flat_map(|response| {
                    response
                        .records()
                        .filter_map(dns_types::records::extract_ip)
                        .collect::<Vec<_>>()
                })
                .collect::<BTreeSet<_>>() // Make them unique.
                .into_iter()
                .collect();

            Ok(ips)
        }
    }
}

async fn send_query(
    socket_factory: Arc<dyn SocketFactory<UdpSocket>>,
    server: SocketAddr,
    query: dns_types::Query,
) -> Result<dns_types::Response> {
    let bind_addr = match server {
        SocketAddr::V4(_) => SocketAddr::new(Ipv4Addr::UNSPECIFIED.into(), 0),
        SocketAddr::V6(_) => SocketAddr::new(Ipv6Addr::UNSPECIFIED.into(), 0),
    };

    // To avoid fragmentation, IP and thus also UDP packets can only reliably sent with an MTU of <= 1500 on the public Internet.
    const BUF_SIZE: usize = 1500;

    let udp_socket = socket_factory
        .bind(bind_addr)
        .context("Failed to bind UDP socket")?;

    let response = tokio::time::timeout(
        UdpDnsClient::TIMEOUT,
        udp_socket.handshake::<BUF_SIZE>(server, &query.into_bytes()),
    )
    .await
    .with_context(|| format!("DNS query to host {server} timed out"))??;

    let response = dns_types::Response::parse(&response).context("Failed to parse DNS response")?;

    Ok(response)
}

#[cfg(test)]
mod tests {
    use std::time::Instant;

    use super::*;

    #[tokio::test]
    #[ignore = "Requires Internet"]
    async fn can_resolve_host() {
        let client = UdpDnsClient::new(
            Arc::new(socket_factory::udp),
            vec![IpAddr::from([1, 1, 1, 1])],
        );

        let ips = client.resolve("example.com").await.unwrap();

        assert!(!ips.is_empty())
    }

    #[tokio::test]
    #[ignore = "Requires Internet"]
    async fn times_out_unreachable_host() {
        let client = UdpDnsClient::new(
            Arc::new(socket_factory::udp),
            vec![IpAddr::from([2, 2, 2, 2])],
        );

        let now = Instant::now();

        let ips = client.resolve("example.com").await.unwrap();

        assert!(ips.is_empty());
        assert!(now.elapsed() >= UdpDnsClient::TIMEOUT)
    }

    #[tokio::test]
    #[ignore = "Requires Internet"]
    async fn returns_all_valid_records() {
        let client = UdpDnsClient::new(
            Arc::new(socket_factory::udp),
            vec![IpAddr::from([1, 1, 1, 1]), IpAddr::from([2, 2, 2, 2])],
        );

        let now = Instant::now();

        let ips = client.resolve("example.com").await.unwrap();

        assert!(!ips.is_empty());
        assert!(now.elapsed() >= UdpDnsClient::TIMEOUT) // Still need to wait for the unreachable server.
    }

    #[tokio::test]
    async fn fails_without_servers() {
        let client = UdpDnsClient::new(Arc::new(socket_factory::udp), vec![]);

        let ips = client.resolve("example.com").await;

        assert_eq!(ips.unwrap_err().to_string(), "No servers specified")
    }
}
