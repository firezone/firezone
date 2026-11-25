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

    let id = query.id();
    let upstream_query = query.with_random_id();

    let response = udp_socket
        .handshake::<BUF_SIZE, _>(server, upstream_query.as_bytes(), |reply| {
            dns_types::Response::parse(reply)
                .ok()
                .filter(|r| r.is_answer_to(&upstream_query))
        })
        .await?
        .with_id(id);

    tracing::trace!(target: "wire::dns::recursive::res", %server, transport = %dns::Transport::Udp, "{qtype} {domain} => {}", response.response_code());

    Ok(response)
}

#[cfg(test)]
mod tests {
    use dns_types::{DomainName, Query, RecordType, ResponseBuilder, ResponseCode};

    use super::*;

    #[tokio::test]
    async fn ignores_replies_that_do_not_answer_the_query() {
        let server = tokio::net::UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let server_addr = server.local_addr().unwrap();

        let query = Query::new(
            DomainName::vec_from_str("example.com").unwrap(),
            RecordType::A,
        )
        .with_id(1);

        let send = tokio::spawn(send(Arc::new(socket_factory::udp), server_addr, query));

        let mut buf = [0u8; 1500];
        let (len, client) = server.recv_from(&mut buf).await.unwrap();
        let upstream_query = Query::parse(&buf[..len]).unwrap();
        let other_query = Query::new(
            DomainName::vec_from_str("example.org").unwrap(),
            RecordType::A,
        )
        .with_id(upstream_query.id());

        let wrong_id = ResponseBuilder::for_query(&upstream_query, ResponseCode::NOERROR)
            .build()
            .with_id(upstream_query.id().wrapping_add(1));
        let wrong_question =
            ResponseBuilder::for_query(&other_query, ResponseCode::NOERROR).build();
        let answer = ResponseBuilder::for_query(&upstream_query, ResponseCode::NXDOMAIN).build();

        for response in [wrong_id, wrong_question, answer] {
            server
                .send_to(&response.into_bytes(u16::MAX), client)
                .await
                .unwrap();
        }

        let response = send.await.unwrap().unwrap();

        assert_eq!(response.response_code(), ResponseCode::NXDOMAIN);
        assert_eq!(response.id(), 1);
    }
}
