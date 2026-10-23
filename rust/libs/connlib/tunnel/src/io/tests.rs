use std::{future::poll_fn, net::Ipv4Addr};

use doh_test_server::DohTestServer;

use super::*;

#[tokio::test]
async fn bootstrap_doh() {
    let _guard = logging::test("debug");

    let answer = Ipv4Addr::new(192, 0, 2, 1);
    let server = DohTestServer::spawn(answer).await.unwrap();
    let mut io = Io::for_test();
    io.doh_tls_config = TlsConfig::new(server.root_cert_store());

    io.send_dns_query(example_com_recursive_query(server.url()), Instant::now());

    let response = io.next_dns_response().await.message.unwrap();

    assert_eq!(response.response_code(), dns_types::ResponseCode::NOERROR);
    assert_eq!(
        response
            .records()
            .filter_map(dns_types::records::extract_ip)
            .collect::<Vec<_>>(),
        vec![IpAddr::V4(answer)]
    );
}

#[tokio::test]
async fn failed_bootstrap_is_evicted() {
    let _guard = logging::test("debug");

    let mut io = Io::for_test();

    io.send_dns_query(
        example_com_recursive_query(DoHUrl::cloudflare()),
        Instant::now(),
    );
    let response = io.next_dns_response().await;

    assert!(response.message.is_err());
    assert!(io.doh_clients.is_empty());

    io.send_dns_query(
        example_com_recursive_query(DoHUrl::cloudflare()),
        Instant::now(),
    );

    assert!(matches!(
        io.doh_clients.get(&DoHUrl::cloudflare()),
        Some(DohClient::Connecting(_))
    ));
}

#[tokio::test]
async fn rebind_dns_clears_all_servers_on_failure() {
    let _guard = logging::test("debug");

    let mut io = Io::for_test();

    let result = io.rebind_dns(vec![
        SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 0), // This one will almost definitely work.
        SocketAddr::new(IpAddr::V4(Ipv4Addr::new(1, 1, 1, 1)), 40000), // This one will fail.
    ]);

    assert_eq!(
        result
            .unwrap_err()
            .drain()
            .map(|e| e.to_string())
            .collect::<Vec<_>>(),
        vec![
            "Failed to bind UDP socket on 1.1.1.1:40000",
            "Failed to bind TCP listener on 1.1.1.1:40000"
        ]
    );
    assert!(io.udp_dns_server.is_empty());
    assert!(io.tcp_dns_server.is_empty());
}

fn example_com_recursive_query(server: DoHUrl) -> dns::RecursiveQuery {
    dns::RecursiveQuery {
        server: dns::Upstream::DoH { server },
        local: SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 11111),
        remote: SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 22222),
        message: dns_types::Query::new("example.com".parse().unwrap(), dns_types::RecordType::A),
        transport: dns::Transport::Udp,
    }
}

/// Helper functions to make the test more concise.
impl Io {
    fn for_test() -> Io {
        Io::new(
            Arc::new(socket_factory::tcp),
            Arc::new(socket_factory::udp),
            BTreeSet::new(),
        )
    }

    async fn next_dns_response(&mut self) -> dns::RecursiveResponse {
        loop {
            let mut input = poll_fn(|cx| self.poll(cx)).await;

            for e in input.error.drain() {
                tracing::debug!("Ignoring error unrelated to DNS: {e:#}");
            }

            if let Some(response) = input.dns_responses.pop() {
                return response;
            }
        }
    }
}
