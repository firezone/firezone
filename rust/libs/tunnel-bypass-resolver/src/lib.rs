//! DNS resolution for connections that bypass the tunnel.
//!
//! Firezone processes make connections of their own — telemetry ingest,
//! flow-log upload — over tunnel-bypassing sockets so they never loop through
//! connlib. Resolving the names for those connections needs the same care:
//! connlib hijacks the system resolver for the lifetime of a session, so a
//! plain `getaddrinfo` would route the lookup back through connlib's stub and
//! into the tunnel. While a session owns the system resolver, lookups
//! therefore go directly to the upstream resolvers captured from the system
//! (see [`SystemResolvers`]); otherwise they use the system resolver.

use std::{
    net::{IpAddr, ToSocketAddrs as _},
    sync::{Arc, LazyLock},
};

use anyhow::{Context as _, Result};
use bootstrap_dns_client::BootstrapDnsClient;
use parking_lot::Mutex;
use socket_factory::{SocketFactory, TcpSocket, UdpSocket};
use tokio::sync::watch;

type SocketFactories = (
    Arc<dyn SocketFactory<TcpSocket>>,
    Arc<dyn SocketFactory<UdpSocket>>,
);

/// Socket factories for queries against the captured upstreams.
///
/// connlib processes configure tunnel-bypassing factories so lookups never
/// loop back through connlib.
static SOCKETS: LazyLock<Mutex<Option<SocketFactories>>> = LazyLock::new(|| Mutex::new(None));

/// How names are currently resolved.
///
/// Defaults to the system resolver and is swapped for connlib's upstreams while a
/// session owns the system resolver (see [`SystemResolvers`]).
static RESOLVER: LazyLock<Mutex<Resolver>> =
    LazyLock::new(|| Mutex::new(Resolver::System(LibcDnsClient)));

/// Notifies subscribers whenever the active resolver is swapped.
static CHANGES: LazyLock<watch::Sender<()>> = LazyLock::new(|| watch::Sender::new(()));

/// Configures the socket factories used for lookups against captured upstreams.
///
/// Call once at process start, before any session captures resolvers: without
/// socket factories, [`SystemResolvers::capture`] cannot build the bypass and
/// lookups keep using the system resolver.
pub fn configure(tcp: Arc<dyn SocketFactory<TcpSocket>>, udp: Arc<dyn SocketFactory<UdpSocket>>) {
    *SOCKETS.lock() = Some((tcp, udp));
}

/// Resolves a host through the active resolver: connlib's captured upstreams
/// while a session owns the system resolver, the system resolver otherwise.
pub async fn resolve(host: &str) -> Result<Vec<IpAddr>> {
    let resolver = RESOLVER.lock().clone();
    let addresses = resolver.resolve(host).await?;
    anyhow::ensure!(!addresses.is_empty(), "No addresses for {host}");

    Ok(addresses)
}

/// Resets the shared socket factories so the next connection rebinds.
pub fn reset_sockets() {
    let sockets = SOCKETS.lock().clone();
    if let Some((tcp, udp)) = sockets {
        tcp.reset();
        udp.reset();
    }
}

/// Subscribes to resolver swaps, e.g. to refresh state that could not be
/// fetched while (working) resolvers were missing.
pub fn changes() -> watch::Receiver<()> {
    CHANGES.subscribe()
}

/// Routes lookups through connlib's upstream resolvers while a connlib session
/// owns the system resolver.
///
/// connlib hijacks the system resolver for the lifetime of a session, so a plain
/// `getaddrinfo` would loop lookups back through connlib's stub. While the
/// guard is held, lookups go through a [`BootstrapDnsClient`] against the captured
/// upstreams. Dropping it restores resolution via the system resolver, tying the
/// bypass to the session's lifetime.
#[must_use = "dropping the guard restores system-resolver lookups"]
pub struct SystemResolvers {
    _private: (),
}

impl SystemResolvers {
    /// Captures `servers` as the upstream resolvers, bypassing the system resolver
    /// until the guard is dropped. Requires [`configure`] to have been called.
    pub fn capture(servers: Vec<IpAddr>) -> Self {
        set_resolver(upstream(servers));

        Self { _private: () }
    }

    /// Replaces the captured upstreams, e.g. when connlib learns updated resolvers.
    pub fn set(&self, servers: Vec<IpAddr>) {
        set_resolver(upstream(servers));
    }
}

impl Drop for SystemResolvers {
    fn drop(&mut self) {
        set_resolver(Resolver::System(LibcDnsClient));
    }
}

/// Swaps the active resolver and notifies subscribers.
fn set_resolver(resolver: Resolver) {
    *RESOLVER.lock() = resolver;
    CHANGES.send_replace(());
}

/// Builds an upstream resolver from `servers` and the configured socket factories.
fn upstream(servers: Vec<IpAddr>) -> Resolver {
    let Some((tcp, udp)) = SOCKETS.lock().clone() else {
        // `configure` runs before any session captures resolvers; without socket
        // factories consumers cannot connect at all, so the resolver is moot.
        return Resolver::System(LibcDnsClient);
    };

    Resolver::Upstream(BootstrapDnsClient::new(udp, tcp, servers))
}

/// Resolves hosts, either through connlib's upstreams or the system resolver.
#[derive(Clone)]
enum Resolver {
    /// A connlib session owns the system resolver, so resolve via the captured
    /// upstreams directly; `getaddrinfo` would loop back through connlib's stub.
    Upstream(BootstrapDnsClient),
    /// No session owns the system resolver, so resolve via libc (`getaddrinfo`).
    System(LibcDnsClient),
}

impl Resolver {
    async fn resolve(&self, host: &str) -> Result<Vec<IpAddr>> {
        match self {
            Resolver::Upstream(client) => client
                .resolve(host.to_owned())
                .await
                .with_context(|| format!("Failed to resolve {host} via upstream resolvers")),
            Resolver::System(client) => client.resolve(host).await,
        }
    }
}

/// Resolves host names via the system resolver, i.e. libc's `getaddrinfo`.
///
/// Only safe when no connlib session owns the system resolver; otherwise the lookup
/// would route through connlib's stub resolver and loop back into the tunnel.
#[derive(Clone, Copy)]
struct LibcDnsClient;

impl LibcDnsClient {
    async fn resolve(&self, host: &str) -> Result<Vec<IpAddr>> {
        let host = host.to_owned();

        tokio::task::spawn_blocking(move || {
            let addresses = (host.as_str(), 443u16)
                .to_socket_addrs()
                .with_context(|| format!("Failed to resolve {host} via system resolver"))?
                .map(|addr| addr.ip())
                .collect::<Vec<_>>();

            Ok(addresses)
        })
        .await
        .context("System resolver task panicked")?
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // Exercises the shared `SOCKETS`/`RESOLVER` statics, so it stays a single test
    // to avoid racing against parallel test threads.
    #[test]
    fn capture_switches_to_upstream_and_drop_restores_system() {
        configure(Arc::new(socket_factory::tcp), Arc::new(socket_factory::udp));

        {
            let _guard = SystemResolvers::capture(vec![IpAddr::from([1, 1, 1, 1])]);
            assert!(matches!(*RESOLVER.lock(), Resolver::Upstream(_)));
        }

        assert!(matches!(*RESOLVER.lock(), Resolver::System(_)));
    }
}
