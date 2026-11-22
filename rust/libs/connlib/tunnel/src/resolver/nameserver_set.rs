use std::{
    collections::{BTreeMap, BTreeSet},
    net::{IpAddr, SocketAddr},
    sync::Arc,
    task::{Context, Poll, ready},
    time::{Duration, Instant},
};

use anyhow::Result;
use dns_types::{DomainNameRef, Query, RecordType, ResponseCode, prelude::*};
use futures_bounded::FuturesTupleSet;
use socket_factory::{SocketFactory, TcpSocket, UdpSocket};

use super::{tcp_dns, udp_dns};

const MAX_DNS_SERVERS: usize = 20; // We don't bother selecting from more than 10 servers over UDP and TCP.
const DNS_TIMEOUT: Duration = Duration::from_secs(2); // Every sensible DNS servers should respond within 2s.

pub const FIREZONE_DEV: DomainNameRef =
    unsafe { DomainNameRef::from_octets_unchecked(b"\x08firezone\x03dev\x00") };

pub struct NameserverSet {
    inner: BTreeSet<IpAddr>,
    nameserver_by_rtt: BTreeMap<Duration, IpAddr>,

    tcp_socket_factory: Arc<dyn SocketFactory<TcpSocket>>,
    udp_socket_factory: Arc<dyn SocketFactory<UdpSocket>>,
    queries: FuturesTupleSet<Result<dns_types::Response>, QueryMetaData>,
}

struct QueryMetaData {
    nameserver: IpAddr,
    start: Instant,
}

impl NameserverSet {
    pub fn new(
        inner: BTreeSet<IpAddr>,
        tcp_socket_factory: Arc<dyn SocketFactory<TcpSocket>>,
        udp_socket_factory: Arc<dyn SocketFactory<UdpSocket>>,
    ) -> Self {
        Self {
            queries: FuturesTupleSet::new(
                || futures_bounded::Delay::tokio(DNS_TIMEOUT),
                MAX_DNS_SERVERS,
            ),
            inner,
            tcp_socket_factory,
            udp_socket_factory,
            nameserver_by_rtt: Default::default(),
        }
    }

    /// Replaces the nameservers and evaluates the new ones.
    ///
    /// Measurements of nameservers that stay in the set are kept, so queries
    /// do not fail while the new ones are evaluated.
    pub fn replace(&mut self, nameservers: BTreeSet<IpAddr>) {
        if self.inner == nameservers {
            return;
        }

        self.nameserver_by_rtt
            .retain(|_, nameserver| nameservers.contains(nameserver));
        self.inner = nameservers;
        self.evaluate();
    }

    pub fn evaluate(&mut self) {
        if self.inner.is_empty() {
            return;
        }

        tracing::debug!(ips = ?self.inner, "Evaluating fastest nameserver");

        let start = Instant::now();

        for nameserver in self.inner.iter().copied() {
            if self
                .queries
                .try_push(
                    udp_dns::send(
                        self.udp_socket_factory.clone(),
                        SocketAddr::new(nameserver, crate::dns::DNS_PORT),
                        Query::new(FIREZONE_DEV.to_vec(), RecordType::A),
                    ),
                    QueryMetaData { nameserver, start },
                )
                .is_err()
            {
                tracing::debug!(%nameserver, "Failed to queue another UDP DNS query");
            }

            if self
                .queries
                .try_push(
                    tcp_dns::send(
                        self.tcp_socket_factory.clone(),
                        SocketAddr::new(nameserver, crate::dns::DNS_PORT),
                        Query::new(FIREZONE_DEV.to_vec(), RecordType::A),
                    ),
                    QueryMetaData { nameserver, start },
                )
                .is_err()
            {
                tracing::debug!(%nameserver, "Failed to queue another TCP DNS query");
            }
        }
    }

    pub fn fastest(&self) -> Option<IpAddr> {
        let (_, ns) = self.nameserver_by_rtt.first_key_value()?;

        Some(*ns)
    }

    pub fn poll(&mut self, cx: &mut Context<'_>) -> Poll<()> {
        if self.queries.is_empty() {
            return Poll::Ready(());
        }

        loop {
            match ready!(self.queries.poll_unpin(cx)) {
                (Ok(Ok(response)), meta) if response.response_code() == ResponseCode::NOERROR => {
                    let rtt = meta.start.elapsed();

                    tracing::debug!(nameserver = %meta.nameserver, ?rtt, ?response, "DNS query completed");

                    self.nameserver_by_rtt.insert(rtt, meta.nameserver);
                }
                (Ok(Ok(response)), meta) => {
                    tracing::debug!(nameserver = %meta.nameserver, ?response, "DNS query failed");
                }
                (Ok(Err(e)), meta) => {
                    tracing::debug!(nameserver = %meta.nameserver, "DNS query failed: {e}");
                }
                (Err(_), meta) => {
                    tracing::debug!(nameserver = %meta.nameserver, "DNS query timed out after {DNS_TIMEOUT:?}");
                }
            }

            let Some(fastest) = self.fastest() else {
                continue;
            };

            if self.queries.is_empty() {
                tracing::debug!(%fastest, "Evaluated fastest nameserver");

                return Poll::Ready(());
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use std::net::Ipv4Addr;

    use dns_types::DomainName;

    use super::*;

    #[test]
    fn const_domain_is_correct() {
        assert_eq!(
            FIREZONE_DEV,
            DomainName::vec_from_str("firezone.dev").unwrap()
        )
    }

    #[tokio::test]
    #[ignore = "Needs Internet"]
    async fn can_evaluate_fastest_nameserver() {
        let _guard = logging::test("debug");

        let mut set = NameserverSet::new(
            BTreeSet::from([
                Ipv4Addr::new(1, 1, 1, 1).into(),
                Ipv4Addr::new(8, 8, 8, 8).into(),
                Ipv4Addr::new(8, 8, 4, 4).into(),
                Ipv4Addr::new(9, 9, 9, 9).into(),
                Ipv4Addr::new(100, 100, 100, 100).into(), // Also include an unreachable server.
            ]),
            Arc::new(socket_factory::tcp),
            Arc::new(socket_factory::udp),
        );
        set.evaluate();

        std::future::poll_fn(|cx| set.poll(cx)).await;

        assert!(set.fastest().is_some());
    }

    #[tokio::test]
    async fn replace_keeps_measurements_of_remaining_nameservers() {
        let kept = IpAddr::from(Ipv4Addr::new(192, 0, 2, 1));
        let removed = IpAddr::from(Ipv4Addr::new(192, 0, 2, 2));
        let mut set = NameserverSet::new(
            BTreeSet::from([kept, removed]),
            Arc::new(socket_factory::tcp),
            Arc::new(socket_factory::udp),
        );
        set.nameserver_by_rtt
            .insert(Duration::from_millis(1), removed);
        set.nameserver_by_rtt.insert(Duration::from_millis(2), kept);

        set.replace(BTreeSet::from([kept, Ipv4Addr::new(192, 0, 2, 3).into()]));

        assert_eq!(set.fastest(), Some(kept));
    }

    #[tokio::test]
    async fn replace_with_same_nameservers_does_not_evaluate() {
        let nameserver = IpAddr::from(Ipv4Addr::new(192, 0, 2, 1));
        let mut set = NameserverSet::new(
            BTreeSet::from([nameserver]),
            Arc::new(socket_factory::tcp),
            Arc::new(socket_factory::udp),
        );

        set.replace(BTreeSet::from([nameserver]));

        assert!(set.queries.is_empty());
    }

    #[tokio::test]
    async fn replace_with_no_nameservers_clears_fastest() {
        let nameserver = IpAddr::from(Ipv4Addr::new(192, 0, 2, 1));
        let mut set = NameserverSet::new(
            BTreeSet::from([nameserver]),
            Arc::new(socket_factory::tcp),
            Arc::new(socket_factory::udp),
        );
        set.nameserver_by_rtt
            .insert(Duration::from_millis(1), nameserver);

        set.replace(BTreeSet::new());

        assert!(set.fastest().is_none());
    }

    #[tokio::test]
    async fn can_handle_no_servers() {
        let _guard = logging::test("debug");

        let mut set = NameserverSet::new(
            BTreeSet::default(),
            Arc::new(socket_factory::tcp),
            Arc::new(socket_factory::udp),
        );

        std::future::poll_fn(|cx| set.poll(cx)).await;

        assert!(set.fastest().is_none());
    }
}
