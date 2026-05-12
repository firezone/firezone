//! UDP DNS client used to resolve a small set of hosts (e.g. the portal) at
//! startup, before the tunnel is up.

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
                .filter(|response| {
                    if is_malformed(response) {
                        tracing::debug!(
                            domain = %response.domain(),
                            qtype = %response.qtype(),
                            "Dropping untrustworthy NOERROR response with no answers and no SOA in authority section (RFC 2308 §5)"
                        );
                        return false;
                    }
                    true
                })
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

/// Whether a `NOERROR` response is structurally malformed enough that it should
/// not be trusted as an authoritative empty answer.
///
/// Some consumer-grade DNS forwarders reply to certain UDP queries with a
/// `NOERROR` response that contains no answer records, no authority records,
/// and no additional records — i.e. the bare query echoed back. Our upstream
/// here is a recursive forwarder, so the strict authoritative-server
/// requirements in RFC 2308 §3 don't directly apply, but the spec still
/// gives us a clear basis for rejection:
///
/// - [RFC 2308 §2.2](https://datatracker.ietf.org/doc/html/rfc2308#section-2.2)
///   defines a NODATA response as `NOERROR` with no answers and either an SOA
///   in the authority section or no NS records.
/// - [RFC 2308 §5](https://datatracker.ietf.org/doc/html/rfc2308#section-5)
///   says negative responses without an SOA SHOULD NOT be cached, because
///   without an SOA there is no way to confirm the response is trustworthy.
///
/// A NOERROR with empty answer, authority, and additional sections satisfies
/// the §2.2 NODATA shape only in the most degenerate way and is explicitly
/// untrustworthy under §5. Treating it as an authoritative empty answer
/// hides the upstream's misbehavior and produces an empty `addresses` list at
/// the caller, which manifests as `phoenix_channel`'s "no IP addresses
/// available" retries until the budget expires. We instead drop the response
/// and let a sibling query (e.g. AAAA when the broken one was A) or a second
/// resolver supply the real answer.
///
/// Truncated (`TC=1`) responses are *not* classified as malformed by this
/// function: empty sections in a truncated response are a separate failure
/// mode (the resolver couldn't fit the answer in a UDP packet), not a buggy
/// upstream. They still produce no IPs because we don't currently retry over
/// TCP, but conflating them here would emit a misleading log line.
fn is_malformed(response: &dns_types::Response) -> bool {
    !response.truncated()
        && response.response_code() == dns_types::ResponseCode::NOERROR
        && response.records().next().is_none()
        && !response.has_authority()
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

    #[test]
    fn is_malformed_detects_buggy_router_empty_response() {
        // 31-byte NOERROR reply for `api.firez.one A` with all section counts
        // zeroed except QD — the exact shape we saw from a misbehaving consumer
        // router. RFC 2308 §5 marks such SOA-less negative responses as
        // untrustworthy, so we should refuse to treat it as an empty answer.
        let bytes =
            hex_literal::hex!("1234818000010000000000000361706905666972657a036f6e650000010001");
        let response = dns_types::Response::parse(&bytes).unwrap();

        assert!(is_malformed(&response));
    }

    #[test]
    fn is_malformed_returns_false_for_truncated_response() {
        // Same shape as the buggy-router case but with TC=1 (flags 0x8380).
        // Truncation is a different failure mode (UDP payload didn't fit) and
        // should not be reported via the malformed-response log line.
        let bytes =
            hex_literal::hex!("1234838000010000000000000361706905666972657a036f6e650000010001");
        let response = dns_types::Response::parse(&bytes).unwrap();

        assert!(response.truncated());
        assert!(!is_malformed(&response));
    }

    #[test]
    fn is_malformed_returns_false_for_valid_nodata_with_soa() {
        // A well-formed NODATA: NOERROR for `api.firez.one A` with no answer
        // records but an SOA record in the authority section. This is what a
        // real recursive resolver returns when the name exists but has no
        // records of the requested type, and `is_malformed` must let it pass.
        //
        // Wire layout (82 bytes):
        //   header     id=0x1234, flags=0x8180 (qr+rd+ra, rcode=NOERROR),
        //              qd=1, an=0, ns=1, ar=0
        //   question   `api.firez.one` A IN
        //   authority  SOA for `firez.one` (name compressed to offset 16),
        //              ttl=3600, mname=ns1.firez.one,
        //              rname=hostmaster.firez.one, serial=1, refresh=7200,
        //              retry=3600, expire=604800, minimum=3600
        let bytes = hex_literal::hex!(
            "1234818000010000000100000361706905666972657a036f6e650000010001\
             c0100006000100000e100027036e7331c0100a686f73746d6173746572c010\
             0000000100001c2000000e1000093a8000000e10"
        );
        let response = dns_types::Response::parse(&bytes).unwrap();

        assert_eq!(response.response_code(), dns_types::ResponseCode::NOERROR);
        assert_eq!(response.records().count(), 0);
        assert!(response.has_authority());
        assert!(!is_malformed(&response));
    }

    #[test]
    fn is_malformed_returns_false_for_response_with_answer() {
        let domain = dns_types::DomainName::vec_from_str("example.com").unwrap();
        let query = dns_types::Query::new(domain.clone(), dns_types::RecordType::A);
        let response =
            dns_types::ResponseBuilder::for_query(&query, dns_types::ResponseCode::NOERROR)
                .with_records([(domain, 60, dns_types::records::a(Ipv4Addr::LOCALHOST))])
                .build();
        let bytes = response.into_bytes(4096);
        let parsed = dns_types::Response::parse(&bytes).unwrap();

        assert!(!is_malformed(&parsed));
    }

    #[test]
    fn is_malformed_returns_false_for_nxdomain_with_no_records() {
        // NXDOMAIN response (rcode=3) with zero records in any section. The
        // structural shape matches the malformed case but the rcode tells us
        // the server *did* speak about the name (it doesn't exist), so this is
        // not a malformed NOERROR we should drop.
        let bytes =
            hex_literal::hex!("1234818300010000000000000361706905666972657a036f6e650000010001");
        let response = dns_types::Response::parse(&bytes).unwrap();

        assert_eq!(response.response_code(), dns_types::ResponseCode::NXDOMAIN);
        assert!(!is_malformed(&response));
    }
}
