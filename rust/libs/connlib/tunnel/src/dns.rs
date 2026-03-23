pub(crate) mod pattern;
pub(crate) mod stub_resolver;

pub(crate) use pattern::Pattern;
pub(crate) use stub_resolver::{ResolveStrategy, StubResolver};

pub use stub_resolver::DnsResourceRecord;

use anyhow::Result;
use dns_types::DoHUrl;
use logging::err_with_src;
use std::net::SocketAddr;

use crate::dns::pattern::Candidate;

pub(crate) const DNS_PORT: u16 = 53;

/// A query that needs to be forwarded to an upstream DNS server for resolution.
#[derive(Debug)]
pub(crate) struct RecursiveQuery {
    /// The server we want to send the query to.
    pub server: Upstream,

    /// The local address we received the query on.
    pub local: SocketAddr,

    /// The client that sent us the query.
    pub remote: SocketAddr,

    /// The query we received from the client (and should forward).
    pub message: dns_types::Query,

    /// The transport we received the query on.
    pub transport: Transport,
}

/// A response to a [`RecursiveQuery`].
#[derive(Debug)]
pub(crate) struct RecursiveResponse {
    /// The server we sent the query to.
    pub server: Upstream,

    /// The local address we received the original query on.
    pub local: SocketAddr,

    /// The client that sent us the original query.
    pub remote: SocketAddr,

    /// The query we received from the client (and forwarded).
    pub query: dns_types::Query,

    /// The result of forwarding the DNS query.
    pub message: Result<dns_types::Response>,

    /// The transport we used.
    pub transport: Transport,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, derive_more::Display)]
pub(crate) enum Transport {
    #[display("UDP")]
    Udp,
    #[display("TCP")]
    Tcp,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord, derive_more::Display)]
pub enum Upstream {
    #[display("Do53({server})")]
    Do53 { server: SocketAddr },
    #[display("DoH({server})")]
    DoH { server: DoHUrl },
}

pub fn is_subdomain(name: &dns_types::DomainName, pattern: &str) -> bool {
    let pattern = match Pattern::new(pattern) {
        Ok(p) => p,
        Err(e) => {
            tracing::warn!(%pattern, "Unable to parse pattern: {}", err_with_src(&e));
            return false;
        }
    };

    let candidate = Candidate::from_domain(name);

    pattern.matches(&candidate)
}
