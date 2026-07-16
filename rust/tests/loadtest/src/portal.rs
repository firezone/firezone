//! Fetching TURN relay credentials from the Firezone portal.
//!
//! Connects to the portal as a client over [`phoenix_channel`], joins the
//! `client` channel and reads the relay list from the `init` message, returning
//! the first TURN relay's address and credentials.
//!
//! The portal message types are replicated locally (only the fields we need) so
//! the loadtest does not need to depend on the connlib data plane. They mirror
//! the real `IngressMessages` / `Relay` serde representation.

use anyhow::{Context as _, Result, anyhow, bail};
use backoff::ExponentialBackoffBuilder;
use phoenix_channel::{
    DeviceInfo, Event, LoginUrl, PhoenixChannel, PublicKeyParam, get_user_agent, http_error_body,
};
use secrecy::SecretString;
use serde::Deserialize;
use socket_factory::{SocketFactory, TcpSocket};
use std::future::poll_fn;
use std::net::{IpAddr, SocketAddr};
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;
use url::Url;

/// Overall deadline for the fetch (connect + join + receive the relay list).
const FETCH_TIMEOUT: Duration = Duration::from_secs(30);

/// TURN credentials obtained from the portal, scoped to a single relay.
pub struct RelayCredentials {
    pub server: SocketAddr,
    pub username: String,
    pub password: String,
}

/// Preferred IP family for the relay address.
#[derive(Clone, Copy)]
pub enum IpFamily {
    V4,
    V6,
}

impl IpFamily {
    fn matches(self, addr: SocketAddr) -> bool {
        match self {
            IpFamily::V4 => addr.is_ipv4(),
            IpFamily::V6 => addr.is_ipv6(),
        }
    }
}

/// Connect to the portal as a client and fetch a TURN relay's credentials,
/// preferring the given IP family if any relays match it.
pub async fn fetch_relay(
    portal_url: &Url,
    token_path: &Path,
    prefer: Option<IpFamily>,
) -> Result<RelayCredentials> {
    let token = load_token(token_path)?;

    let device_id = uuid::Uuid::new_v4().to_string();
    let url = LoginUrl::client(portal_url.clone(), device_id, None, DeviceInfo::default())
        .map_err(|e| anyhow!("invalid portal URL: {e:?}"))?;

    let socket_factory = Arc::new(socket_factory::tcp) as Arc<dyn SocketFactory<TcpSocket>>;

    let mut channel = PhoenixChannel::<(), NoEgress, IngressMessages, PublicKeyParam>::disconnected(
        url,
        token,
        // The portal only accepts connections from recognised clients, so we
        // present the loadtest as a headless-client.
        get_user_agent("headless-client", env!("CARGO_PKG_VERSION")),
        "client",
        (),
        || ExponentialBackoffBuilder::default().build(),
        socket_factory,
    );

    let host = channel.host();

    channel.connect(
        resolve(&host).await?,
        Duration::ZERO,
        PublicKeyParam(rand::random()),
    );

    tracing::info!(%host, "Connecting to portal to fetch relay credentials");

    let credentials = tokio::time::timeout(FETCH_TIMEOUT, drive(&mut channel, prefer))
        .await
        .context("Timed out fetching relay credentials from the portal")?
        .map_err(with_http_body)?;

    tracing::info!(relay = %credentials.server, "Fetched TURN relay from portal");

    Ok(credentials)
}

/// Drive the channel until the `init` message yields a TURN relay.
async fn drive(
    channel: &mut PhoenixChannel<(), NoEgress, IngressMessages, PublicKeyParam>,
    prefer: Option<IpFamily>,
) -> Result<RelayCredentials> {
    loop {
        let event = poll_fn(|cx| channel.poll(cx))
            .await
            .map_err(|e| anyhow!("portal connection failed: {e}"))?;

        match event {
            Event::Connected => tracing::info!("Joined portal client channel"),
            Event::Message {
                msg: IngressMessages::Init(init),
                ..
            } => {
                let relay =
                    select_relay(init.relays, prefer).context("portal returned no TURN relays")?;

                return Ok(RelayCredentials {
                    server: relay.addr,
                    username: relay.username,
                    password: relay.password,
                });
            }
            Event::Hiccup { error, .. } => {
                return Err(error.context("portal connection hiccup"));
            }
            Event::Closed => bail!("portal closed the connection before sending the relay list"),
        }
    }
}

/// Select the first TURN relay matching `prefer`'s IP family (any family if no
/// preference is given).
fn select_relay(relays: Vec<Relay>, prefer: Option<IpFamily>) -> Option<TurnRelay> {
    relays
        .into_iter()
        .filter_map(|relay| match relay {
            Relay::Turn(turn) => Some(turn),
            Relay::Other => None,
        })
        .find(|turn| prefer.is_none_or(|family| family.matches(turn.addr)))
}

/// Resolve the portal host to IP addresses. The port is irrelevant here; the
/// channel pairs the resolved IPs with its own port when connecting.
async fn resolve(host: &str) -> Result<Vec<IpAddr>> {
    let addresses = tokio::net::lookup_host((host, 0))
        .await
        .with_context(|| format!("failed to resolve portal host '{host}'"))?
        .map(|addr| addr.ip())
        .collect::<Vec<_>>();

    if addresses.is_empty() {
        bail!("portal host '{host}' resolved to no addresses");
    }

    Ok(addresses)
}

/// Load the portal token from the token file.
fn load_token(path: &Path) -> Result<SecretString> {
    let contents = std::fs::read_to_string(path)
        .with_context(|| format!("failed to read token from '{}'", path.display()))?;
    let token = contents.trim().to_owned();

    if token.is_empty() {
        bail!("token file '{}' is empty", path.display());
    }

    Ok(SecretString::from(token))
}

/// Append the HTTP response body to a portal error, if it carries one (e.g. the
/// body of a rejected WebSocket upgrade).
fn with_http_body(error: anyhow::Error) -> anyhow::Error {
    match http_error_body(&error) {
        Some(body) => error.context(format!("portal responded with: {body}")),
        None => error,
    }
}

/// Outbound message type for the channel. We never send custom messages, so this
/// is uninhabited in practice; it only exists to satisfy the type parameter.
#[derive(Debug, PartialEq, serde::Serialize)]
struct NoEgress;

/// The one portal client-bound message we care about.
///
/// Mirrors the real `IngressMessages` serde representation (`event` tag,
/// `payload` content). Any other event fails to deserialize and is skipped by
/// the phoenix channel, which is fine since we only need the `init` message.
#[derive(Deserialize)]
#[serde(rename_all = "snake_case", tag = "event", content = "payload")]
enum IngressMessages {
    Init(InitClient),
}

#[derive(Deserialize)]
struct InitClient {
    #[serde(default)]
    relays: Vec<Relay>,
}

#[derive(Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum Relay {
    Turn(TurnRelay),
    #[serde(other)]
    Other,
}

#[derive(Deserialize)]
struct TurnRelay {
    addr: SocketAddr,
    username: String,
    password: String,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_init_message_and_extracts_turn_relay() {
        // A realistic `init` payload with both a TURN and a STUN relay.
        let json = r#"{
            "event": "init",
            "payload": {
                "interface": { "upstream_dns": [] },
                "resources": [],
                "relays": [
                    { "type": "stun", "id": "a", "addr": "9.9.9.9:3478" },
                    {
                        "type": "turn",
                        "id": "b",
                        "expires_at": 1700000000,
                        "addr": "1.2.3.4:3478",
                        "username": "user",
                        "password": "pass"
                    }
                ]
            }
        }"#;

        let message: IngressMessages = serde_json::from_str(json).unwrap();
        let IngressMessages::Init(init) = message;

        let turn = init
            .relays
            .into_iter()
            .find_map(|relay| match relay {
                Relay::Turn(turn) => Some(turn),
                Relay::Other => None,
            })
            .unwrap();

        assert_eq!(turn.addr, "1.2.3.4:3478".parse().unwrap());
        assert_eq!(turn.username, "user");
        assert_eq!(turn.password, "pass");
    }

    #[test]
    fn rejects_non_init_messages() {
        // Non-init events fail to deserialize; the phoenix channel skips them.
        let json = r#"{ "event": "relays_presence", "payload": { "connected": [] } }"#;
        assert!(serde_json::from_str::<IngressMessages>(json).is_err());
    }

    fn turn_relay(addr: &str, username: &str) -> Relay {
        Relay::Turn(TurnRelay {
            addr: addr.parse().unwrap(),
            username: username.to_owned(),
            password: "p".to_owned(),
        })
    }

    #[test]
    fn select_relay_prefers_requested_family() {
        let relays = || {
            vec![
                turn_relay("1.2.3.4:3478", "v4"),
                turn_relay("[2001:db8::1]:3478", "v6"),
            ]
        };

        assert_eq!(
            select_relay(relays(), Some(IpFamily::V6)).unwrap().username,
            "v6"
        );
        assert_eq!(
            select_relay(relays(), Some(IpFamily::V4)).unwrap().username,
            "v4"
        );
        assert_eq!(select_relay(relays(), None).unwrap().username, "v4"); // first
    }

    #[test]
    fn select_relay_returns_none_when_preferred_family_absent() {
        let relays = vec![turn_relay("1.2.3.4:3478", "v4")];

        assert!(select_relay(relays, Some(IpFamily::V6)).is_none());
    }
}
