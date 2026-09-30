//! Reusable portal transport and reconnect policy.

use crate::PHOENIX_TOPIC;
use anyhow::Context as _;
use bootstrap_dns_client::BootstrapDnsClient;
use phoenix_channel::{PhoenixChannel, PublicKeyParam};
use socket_factory::{SocketFactory, TcpSocket, UdpSocket};
use std::{iter, net::IpAddr, pin::pin, sync::Arc, time::Duration};
use tokio::sync::mpsc;
use tunnel::messages::{
    SnownetCapabilities,
    client::{EgressMessages, IngressMessages},
};

pub enum PortalCommand {
    Connect(PublicKeyParam),
    Send(EgressMessages),
    UpdateDnsServers(Vec<IpAddr>),
}

/// An update from the portal connection task to the main event-loop.
pub enum PortalEvent {
    Message(IngressMessages),
    /// The portal connection (re)established.
    Connected,
    /// The portal connection dropped and is being re-established.
    Disconnected,
}

pub async fn run(
    mut portal: PhoenixChannel<(), EgressMessages, IngressMessages, PublicKeyParam>,
    mut public_key: PublicKeyParam,
    event_tx: mpsc::Sender<Result<PortalEvent, phoenix_channel::Error>>,
    mut cmd_rx: mpsc::Receiver<PortalCommand>,
    udp_socket_factory: Arc<dyn SocketFactory<UdpSocket>>,
    tcp_socket_factory: Arc<dyn SocketFactory<TcpSocket>>,
    dns_servers: Vec<IpAddr>,
) {
    use futures::future::Either;
    use futures::future::select;
    use std::future::poll_fn;

    let mut bootstrap_dns_client = BootstrapDnsClient::new(
        udp_socket_factory.clone(),
        tcp_socket_factory.clone(),
        dns_servers,
    );

    let ips = resolve_portal_host_ips(&bootstrap_dns_client, portal.host()).await;
    portal.connect(ips, Duration::ZERO, public_key.clone());

    let hiccups = otel_instruments::portal_connection_hiccups();

    loop {
        // We process commands from the channel first (i.e. it is polled first) to update the DNS servers as quickly as possible.
        // This allows `Hiccup` events to use the updated `BootstrapDnsClient` to resolve the domain.
        match select(pin!(cmd_rx.recv()), poll_fn(|cx| portal.poll(cx))).await {
            Either::Left((Some(PortalCommand::Send(msg)), _)) => {
                match portal.send(PHOENIX_TOPIC, msg) {
                    Ok(()) => {}
                    Err(phoenix_channel::NotConnected(msg)) => {
                        tracing::debug!(?msg, "Failed to send message to portal: Not connected")
                    }
                }
            }
            Either::Left((Some(PortalCommand::Connect(new_public_key)), _)) => {
                public_key = new_public_key; // Important! Update the current public key so we can reuse on connection hiccups!

                let ips = resolve_portal_host_ips(&bootstrap_dns_client, portal.host()).await;
                portal.connect(ips, Duration::ZERO, public_key.clone());
            }
            Either::Left((Some(PortalCommand::UpdateDnsServers(servers)), _)) => {
                bootstrap_dns_client = BootstrapDnsClient::new(
                    udp_socket_factory.clone(),
                    tcp_socket_factory.clone(),
                    servers,
                );
            }
            Either::Left((None, _)) => {
                tracing::debug!("Command channel closed: exiting phoenix-channel event-loop");

                break;
            }
            Either::Right((Ok(phoenix_channel::Event::Message { msg, .. }), _)) => {
                if event_tx.send(Ok(PortalEvent::Message(msg))).await.is_err() {
                    tracing::debug!("Event channel closed: exiting phoenix-channel event-loop");

                    break;
                }
            }
            Either::Right((Ok(phoenix_channel::Event::Closed), _)) => {
                unimplemented!("Client never actively closes the portal connection")
            }
            Either::Right((
                Ok(phoenix_channel::Event::Hiccup {
                    backoff,
                    max_elapsed_time,
                    error,
                }),
                _,
            )) => {
                tracing::info!(
                    ?backoff,
                    ?max_elapsed_time,
                    body = phoenix_channel::http_error_body(&error).map(tracing::field::display),
                    "Hiccup in portal connection: {error:#}"
                );
                hiccups.add(1, &otel_attributes::error_layers(&error));

                let _ = event_tx.send(Ok(PortalEvent::Disconnected)).await;

                let ips = resolve_portal_host_ips(&bootstrap_dns_client, portal.host()).await;
                portal.connect(ips, backoff, public_key.clone());
            }
            Either::Right((Ok(phoenix_channel::Event::Connected), _)) => {
                if let Err(phoenix_channel::NotConnected(msg)) = portal.send(
                    PHOENIX_TOPIC,
                    EgressMessages::SetSnownetCapabilities(SnownetCapabilities::LOCAL),
                ) {
                    tracing::debug!(?msg, "Failed to send snownet capabilities: Not connected");
                }

                let _ = event_tx.send(Ok(PortalEvent::Connected)).await;
            }
            Either::Right((Err(e), _)) => {
                let _ = event_tx.send(Err(e)).await; // We don't care about the result because we are exiting anyway.

                break;
            }
        }
    }
}

/// Re-resolves the IPs of the portal hostname.
///
/// We combine the result of two sources here:
///
/// - We make DNS queries to our configured system resolvers.
/// - We read `/etc/hosts`.
///
/// If any of these fail, we simply default to an empty list of IPs.
/// This is fine as this routine will be triggered again if we ever run out of IPs to use.
async fn resolve_portal_host_ips(
    bootstrap_dns_client: &BootstrapDnsClient,
    host: String,
) -> Vec<IpAddr> {
    let dns_ips = bootstrap_dns_client
        .resolve(host.clone())
        .await
        .context("Failed to lookup portal host via DNS")
        .inspect_err(|e| tracing::debug!(%host, "{e:#}"))
        .unwrap_or_default();

    let etc_hosts_ips = etc_hosts_dns_client::resolve(host.clone())
        .await
        .context("Failed to lookup portal host from `/etc/hosts`")
        .inspect_err(|e| tracing::debug!(%host, "{e:#}"))
        .unwrap_or_default();

    iter::empty().chain(dns_ips).chain(etc_hosts_ips).collect()
}
