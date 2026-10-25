use std::net::{IpAddr, Ipv4Addr};

use super::*;

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

impl Io {
    fn for_test() -> Io {
        let (resolver, _) = resolver::channels();

        Io::new(
            resolver,
            Arc::new(socket_factory::tcp),
            Arc::new(socket_factory::udp),
        )
    }
}
