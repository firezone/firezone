use std::{
    net::{Ipv4Addr, Ipv6Addr, SocketAddr},
    sync::Arc,
};

use anyhow::Result;
use socket_factory::{SocketFactory, UdpSocket};

use crate::dns;

pub async fn send(
    factory: Arc<dyn SocketFactory<UdpSocket>>,
    server: SocketAddr,
    query: dns_types::Query,
) -> Result<dns_types::Response> {
    let domain = query.domain();
    let qtype = query.qtype();

    tracing::trace!(target: "wire::dns::recursive::qry", %server, transport = %dns::Transport::Udp, "{qtype} {domain}");

    let bind_addr = match server {
        SocketAddr::V4(_) => SocketAddr::new(Ipv4Addr::UNSPECIFIED.into(), 0),
        SocketAddr::V6(_) => SocketAddr::new(Ipv6Addr::UNSPECIFIED.into(), 0),
    };

    // To avoid fragmentation, IP and thus also UDP packets can only reliably sent with an MTU of <= 1500 on the public Internet.
    const BUF_SIZE: usize = 1500;

    let udp_socket = factory.bind(bind_addr)?;

    let query = query.with_random_id();

    let socket = udp_socket.connect(server).await?;
    socket.send(query.as_bytes()).await?;

    let mut buffer = vec![0u8; BUF_SIZE];

    let response = loop {
        let len = socket.recv(&mut buffer).await?;

        match dns_types::Response::parse_answer(&buffer[..len], &query) {
            Ok(response) => break response,
            Err(e) => tracing::trace!(%server, "Ignoring UDP DNS reply: {e}"),
        }
    };

    tracing::trace!(target: "wire::dns::recursive::res", %server, transport = %dns::Transport::Udp, "{qtype} {domain} => {}", response.response_code());

    Ok(response)
}

#[cfg(test)]
mod tests {
    use dns_types::{DomainName, Query, RecordType, ResponseBuilder, ResponseCode};

    use super::*;

    #[tokio::test]
    async fn ignores_response_with_other_id() {
        let response = send_with_spoofed_response(|upstream_query| {
            ResponseBuilder::for_query(upstream_query, ResponseCode::NOERROR)
                .build()
                .with_id(upstream_query.id().wrapping_add(1))
        })
        .await;

        assert_eq!(response.response_code(), ResponseCode::NXDOMAIN);
    }

    #[tokio::test]
    async fn ignores_response_with_other_question() {
        let response = send_with_spoofed_response(|upstream_query| {
            let other_query = Query::new(
                DomainName::vec_from_str("example.org").unwrap(),
                RecordType::A,
            )
            .with_id(upstream_query.id());

            ResponseBuilder::for_query(&other_query, ResponseCode::NOERROR).build()
        })
        .await;

        assert_eq!(response.response_code(), ResponseCode::NXDOMAIN);
    }

    /// Sends a query and answers it with the spoofed response first, followed by an `NXDOMAIN` answer.
    async fn send_with_spoofed_response(
        spoofed_response: impl FnOnce(&Query) -> dns_types::Response,
    ) -> dns_types::Response {
        let server = tokio::net::UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let server_addr = server.local_addr().unwrap();
        let query = Query::new(
            DomainName::vec_from_str("example.com").unwrap(),
            RecordType::A,
        );

        let send = tokio::spawn(send(Arc::new(socket_factory::udp), server_addr, query));

        let mut buf = [0u8; 1500];
        let (len, client) = server.recv_from(&mut buf).await.unwrap();
        let upstream_query = Query::parse(&buf[..len]).unwrap();
        let answer = ResponseBuilder::for_query(&upstream_query, ResponseCode::NXDOMAIN).build();

        for response in [spoofed_response(&upstream_query), answer] {
            server
                .send_to(&response.into_bytes(u16::MAX), client)
                .await
                .unwrap();
        }

        send.await.unwrap().unwrap()
    }
}
