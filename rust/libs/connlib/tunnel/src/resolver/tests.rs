use std::{future::poll_fn, net::Ipv4Addr};

use doh_test_server::DohTestServer;

use super::*;

#[tokio::test]
async fn bootstrap_doh() {
    let _guard = logging::test("debug");

    let answer = Ipv4Addr::new(192, 0, 2, 1);
    let server = DohTestServer::spawn(answer).await.unwrap();
    let (event_loop, mut resolver) = Resolver::for_test();
    resolver.doh_tls_config = TlsConfig::new(server.root_cert_store());

    event_loop.send_query(example_com_query(server.url()));

    let response = resolver.next_response().await.message.unwrap();

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

    let (event_loop, mut resolver) = Resolver::for_test();

    event_loop.send_query(example_com_query(DoHUrl::cloudflare()));
    let response = resolver.next_response().await;

    assert!(response.message.is_err());
    assert!(resolver.doh_clients.is_empty());

    resolver.send_query(example_com_query(DoHUrl::cloudflare()));

    assert!(matches!(
        resolver.doh_clients.get(&DoHUrl::cloudflare()),
        Some(DohClient::Connecting(_))
    ));
}

#[tokio::test]
async fn no_nameserver_fails_query() {
    let _guard = logging::test("debug");

    let (event_loop, mut resolver) = Resolver::for_test();

    event_loop.send_query(ResolverQuery {
        server: None,
        ..example_com_query(DoHUrl::cloudflare())
    });
    let response = resolver.next_response().await;

    assert!(response.message.is_err());
}

fn example_com_query(server: DoHUrl) -> ResolverQuery {
    ResolverQuery {
        server: Some(dns::Upstream::DoH { server }),
        local: SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 11111),
        remote: SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 22222),
        message: dns_types::Query::new("example.com".parse().unwrap(), dns_types::RecordType::A),
        transport: dns::Transport::Udp,
        started_at: Instant::now(),
    }
}

impl Resolver {
    fn for_test() -> (EventLoopEnds, Resolver) {
        let (event_loop, task) = channels();
        let resolver = Resolver::new(
            task,
            Arc::new(socket_factory::tcp),
            Arc::new(socket_factory::udp),
            BTreeSet::new(),
        );

        (event_loop, resolver)
    }

    async fn next_response(&mut self) -> dns::RecursiveResponse {
        poll_fn(|cx| self.poll_next_response(cx)).await.unwrap()
    }
}
