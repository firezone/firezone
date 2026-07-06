//! Message types that are used by both the gateway and client.
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};

use chrono::{DateTime, Utc, serde::ts_seconds};
use connlib_model::RelayId;
use dns_types::{DoHUrl, DomainName};
use ip_network::IpNetwork;
use serde::{Deserialize, Serialize};
use std::fmt;

pub mod client;
pub mod gateway;
mod key;

pub use key::{Key, SecretKey};

/// Represents a wireguard peer.
#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct Peer {
    /// Keepalive: How often to send a keep alive message.
    pub persistent_keepalive: Option<u16>,
    /// Peer's public key.
    pub public_key: Key,
    /// Peer's Ipv4 (only 1 ipv4 per peer for now and mandatory).
    pub ipv4: Ipv4Addr,
    /// Peer's Ipv6 (only 1 ipv6 per peer for now and mandatory).
    pub ipv6: Ipv6Addr,
    /// Preshared key for the given peer.
    pub preshared_key: SecretKey,
}

impl Peer {
    pub fn ips(&self) -> Vec<IpNetwork> {
        vec![self.ipv4.into(), self.ipv6.into()]
    }
}

impl PartialEq for Peer {
    fn eq(&self, other: &Self) -> bool {
        self.persistent_keepalive.eq(&other.persistent_keepalive)
            && self.public_key.eq(&other.public_key)
            && self.ipv4.eq(&other.ipv4)
            && self.ipv6.eq(&other.ipv6)
    }
}

#[derive(Debug, Deserialize, Serialize, Clone, PartialEq, Eq)]
pub struct ResolveRequest {
    pub name: DomainName,
    pub proxy_ips: Vec<IpAddr>,
}

#[derive(Debug, Deserialize, Serialize, Clone, Hash, PartialEq, Eq)]
pub struct DomainResponse {
    pub domain: DomainName,
    pub address: Vec<IpAddr>,
}

#[derive(Debug, Deserialize, Serialize, Clone, PartialEq, Eq, Hash)]
pub struct IceCredentials {
    pub username: String,
    pub password: String,
}

impl From<IceCredentials> for snownet::Credentials {
    fn from(value: IceCredentials) -> Self {
        Self {
            username: value.username,
            password: value.password,
        }
    }
}

#[derive(Debug, Deserialize, Serialize, Clone, Copy, PartialEq, Eq, Hash)]
#[serde(rename_all = "lowercase")]
pub enum IceRole {
    Controlling,
    Controlled,
}

impl From<IceRole> for snownet::IceRole {
    fn from(value: IceRole) -> snownet::IceRole {
        match value {
            IceRole::Controlling => snownet::IceRole::Controlling,
            IceRole::Controlled => snownet::IceRole::Controlled,
        }
    }
}

/// Capabilities of a snownet implementation.
///
/// Reported by clients and gateways to the portal on connect. The portal
/// intersects capabilities across both sides of each connection and re-emits
/// the negotiated set with each `authorize_flow` / `flow_created` /
/// `client_device_access_authorized` message.
///
/// New fields must always be added with a `false`-equivalent default so older
/// peers that don't send them deserialize as "feature not supported", and
/// existing fields must never be repurposed.
#[derive(Debug, Default, Copy, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct SnownetCapabilities {
    /// The implementation can negotiate connections without ICE.
    pub iceless: bool,
}

impl SnownetCapabilities {
    /// Capabilities of the local snownet implementation, hard-coded at compile time.
    pub const LOCAL: Self = Self { iceless: true };
}

#[derive(Deserialize, Serialize, Clone, Copy, PartialEq, Eq, Hash)]
#[serde(tag = "protocol", rename_all = "snake_case")]
pub enum DnsServer {
    IpPort(IpDnsServer),
}

impl fmt::Debug for DnsServer {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::IpPort(IpDnsServer { address }) => address.fmt(f),
        }
    }
}

impl DnsServer {
    pub fn ip(&self) -> IpAddr {
        match self {
            DnsServer::IpPort(s) => s.address.ip(),
        }
    }

    pub fn address(&self) -> SocketAddr {
        match self {
            DnsServer::IpPort(s) => s.address,
        }
    }
}

impl<T> From<T> for DnsServer
where
    T: Into<SocketAddr>,
{
    fn from(addr: T) -> Self {
        Self::IpPort(IpDnsServer {
            address: addr.into(),
        })
    }
}

#[derive(Debug, Deserialize, Serialize, Clone, Copy, PartialEq, Eq, Hash)]
pub struct IpDnsServer {
    pub address: SocketAddr,
}

/// Represents a wireguard interface configuration.
///
/// Note that the ips are /32 for ipv4 and /128 for ipv6.
/// This is done to minimize collisions and we update the routing table manually.
#[derive(Debug, Deserialize, Serialize, Clone, PartialEq, Eq)]
pub struct Interface {
    /// Interface's Ipv4.
    pub ipv4: Ipv4Addr,
    /// Interface's Ipv6.
    pub ipv6: Ipv6Addr,
    /// DNS that will be used to query for DNS that aren't within our resource list.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    #[serde(default)]
    pub upstream_dns: Vec<DnsServer>, // TODO: Remove once portal with `upstream_do53` support has been deployed.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    #[serde(default)]
    pub upstream_do53: Vec<UpstreamDo53>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    #[serde(default)]
    pub upstream_doh: Vec<UpstreamDoH>,
    #[serde(default)]
    pub search_domain: Option<DomainName>,
}

impl Interface {
    pub fn upstream_do53(&self) -> Vec<IpAddr> {
        if !self.upstream_do53.is_empty() {
            return self.upstream_do53.iter().map(|u| u.ip).collect();
        }

        // Fallback whilst the portal does not send `upstream_do53`.
        self.upstream_dns
            .iter()
            .map(|u| match u {
                DnsServer::IpPort(ip_dns_server) => ip_dns_server.address.ip(),
            })
            .collect()
    }

    pub fn upstream_doh(&self) -> Vec<DoHUrl> {
        self.upstream_doh.iter().map(|u| u.url.clone()).collect()
    }
}

#[derive(Debug, Deserialize, Serialize, Clone, PartialEq, Eq)]
pub struct UpstreamDo53 {
    pub ip: IpAddr,
}

/// Flow-log upload configuration the portal always sends as part of `init`.
///
/// Uploads are driven entirely by the portal: an upload interval > 0 plus an
/// API URL enables them, anything else disables them. [`IngestToken`]s arrive
/// regardless, because their claims also attribute local flow-log output.
#[derive(Debug, Deserialize, Clone)]
pub struct FlowLogsConfig {
    /// Base URL flow logs are POSTed to.
    pub api_url: String,
    /// How often, in seconds, to upload batched flow logs. `0` disables uploads.
    pub upload_interval_secs: u64,
    /// Maximum flow-log records per upload request. `0` uses the default.
    pub upload_batch_size: u64,
}

impl FlowLogsConfig {
    /// The upload interval to persist.
    ///
    /// `0` unless uploads are enabled; persisting `0` removes a previously
    /// persisted config.
    pub fn effective_upload_interval_secs(&self) -> u64 {
        if self.upload_enabled() {
            self.upload_interval_secs
        } else {
            0
        }
    }

    /// Whether the portal enabled flow-log uploads.
    pub fn upload_enabled(&self) -> bool {
        self.upload_interval_secs > 0 && !self.api_url.trim().is_empty()
    }
}

/// A per-authorization flow-log ingest token minted by the portal.
///
/// An HS256 JWT: it carries the authorization's attribution claims and is the
/// `Bearer` credential when uploading that authorization's flow logs.
///
/// Deserializing validates the token's structure and the claims the portal
/// guarantees; only the portal mints these, so a malformed token is a contract
/// violation worth failing loudly on, not an input to tolerate. The signature
/// is not verified because only the portal and the ingest API hold the key.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct IngestToken(String);

impl IngestToken {
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl<'de> Deserialize<'de> for IngestToken {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        let token = String::deserialize(deserializer)?;

        validate_ingest_token(&token).map_err(serde::de::Error::custom)?;

        Ok(Self(token))
    }
}

fn validate_ingest_token(token: &str) -> Result<(), String> {
    use base64::Engine as _;
    use base64::engine::general_purpose::URL_SAFE_NO_PAD;

    let [header, payload, signature]: [&str; 3] =
        token
            .split('.')
            .collect::<Vec<_>>()
            .try_into()
            .map_err(|_| "ingest token is not made of three JWT segments".to_owned())?;

    let header = URL_SAFE_NO_PAD
        .decode(header)
        .map_err(|e| format!("ingest token header is not base64url: {e}"))?;
    let header = serde_json::from_slice::<JwtHeader>(&header)
        .map_err(|e| format!("ingest token header is invalid: {e}"))?;

    if header.alg != "HS256" {
        return Err(format!("ingest token alg is not HS256: {}", header.alg));
    }

    let payload = URL_SAFE_NO_PAD
        .decode(payload)
        .map_err(|e| format!("ingest token payload is not base64url: {e}"))?;
    serde_json::from_slice::<IngestTokenClaims>(&payload)
        .map_err(|e| format!("ingest token claims are invalid: {e}"))?;

    let signature = URL_SAFE_NO_PAD
        .decode(signature)
        .map_err(|e| format!("ingest token signature is not base64url: {e}"))?;

    if signature.is_empty() {
        return Err("ingest token signature is empty".to_owned());
    }

    Ok(())
}

#[derive(Deserialize)]
struct JwtHeader {
    alg: String,
}

/// The claims the portal stamps into every ingest token.
///
/// Deserialized only to validate a received token: the required fields are the
/// claims the portal guarantees, the `Option`s are the nullable attribution
/// claims it omits when absent. Unknown claims are tolerated so the portal can
/// add attribution without breaking deployed clients.
#[expect(dead_code, reason = "deserialized only to validate the token")]
#[derive(Deserialize)]
struct IngestTokenClaims {
    account_id: String,
    iat: u64,
    exp: u64,
    role: IngestTokenRole,
    device_id: String,
    policy_authorization_id: String,
    policy_id: String,
    resource_id: String,
    resource_name: String,
    actor_id: String,
    actor_name: String,
    authorized_at: String,
    authorization_expires_at: String,
    resource_address: Option<String>,
    actor_email: Option<String>,
    auth_provider_id: Option<String>,
    client_version: Option<String>,
    device_os_name: Option<String>,
    device_os_version: Option<String>,
    device_serial: Option<String>,
    device_uuid: Option<String>,
    device_identifier_for_vendor: Option<String>,
    device_firebase_installation_id: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "lowercase")]
enum IngestTokenRole {
    Initiator,
    Responder,
}

/// A portal-minted ingest token for tests, signed with a throwaway key.
#[cfg(test)]
pub(crate) const TEST_INGEST_TOKEN: &str = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJhY2NvdW50X2lkIjoiMTJmMjA3ZTAtM2I2Yy00ZjBmLTlkMGYtY2MyMmNmOWZiZjNjIiwiaWF0IjoxNzgyNzU2MDAwLCJleHAiOjE3ODU0MzQ0MDAsInJvbGUiOiJpbml0aWF0b3IiLCJkZXZpY2VfaWQiOiJkMjYzZDQ5MC1hMGJiLTQ1MmEtODk5MC0wMWQyN2ExZjExNDQiLCJwb2xpY3lfYXV0aG9yaXphdGlvbl9pZCI6ImVlYjY2MjA1LTVmNTMtNGY2NC1hY2JjLWRlZWQ0NzI5M2YwNCIsInBvbGljeV9pZCI6IjQ0ZjE5YzM3LWNmNjItNGIxOS1iMTU4LTZmODZiZGNkMmI1NyIsInJlc291cmNlX2lkIjoiNzMzZThkMTQtYzE4ZC00OTMxLWFmMzAtMzYzOWZhMDljMGMwIiwicmVzb3VyY2VfbmFtZSI6IkdpdExhYiIsImFjdG9yX2lkIjoiMjRlYjYzMWUtYzUyOS00MTgyLWE3NDYtZDk5ZWU2NmY3NDI2IiwiYWN0b3JfbmFtZSI6IkphbmUgRG9lIiwiYXV0aG9yaXplZF9hdCI6IjIwMjYtMDctMDZUMTI6MDA6MDAuMDAwMDAwWiIsImF1dGhvcml6YXRpb25fZXhwaXJlc19hdCI6IjIwMjYtMDctMDdUMTI6MDA6MDAuMDAwMDAwWiIsInJlc291cmNlX2FkZHJlc3MiOiJnaXRsYWIubXljb3JwLmNvbSIsImFjdG9yX2VtYWlsIjoiamFuZUBteWNvcnAuY29tIiwiYXV0aF9wcm92aWRlcl9pZCI6ImY5NWVmMWE1LWI3NmItNGQ1OS05YjRiLTZiMGMyZDQ3ZTEyOCIsImNsaWVudF92ZXJzaW9uIjoiMS41LjExIiwiZGV2aWNlX29zX25hbWUiOiJtYWNPUyIsImRldmljZV9vc192ZXJzaW9uIjoiMTUuNSIsImRldmljZV9zZXJpYWwiOiJDMDJYTDBHWUpHSDUiLCJkZXZpY2VfdXVpZCI6IjBmMGMyMmIxLTY0ZmEtNGEwNC1hMWMxLTViNGI2YzBjMmQ0NyIsImRldmljZV9pZGVudGlmaWVyX2Zvcl92ZW5kb3IiOiI1YWMzNDdmOC1jYmI2LTRiMGYtOGYwZS0xZjRkNDdhMWMxNWIiLCJkZXZpY2VfZmlyZWJhc2VfaW5zdGFsbGF0aW9uX2lkIjoiY0FtcDFlRjFyZUJhc2VJZCJ9.aHR1FGQ-cqGS2PZQP5iePtTSUc1kRI6Xj9RWvpqIw_A";

#[derive(Debug, Deserialize, Serialize, Clone, PartialEq, Eq)]
pub struct UpstreamDoH {
    pub url: DoHUrl,
}

/// A single relay
#[derive(Debug, Deserialize, Clone, PartialEq, Eq)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Relay {
    /// STUN type of relay
    Stun(Stun),
    /// TURN type of relay
    Turn(Turn),
}

/// Represent a TURN relay
#[derive(Debug, Deserialize, Clone, PartialEq, Eq)]
pub struct Turn {
    pub id: RelayId,
    //// Expire time of the username/password in unix millisecond timestamp UTC
    #[serde(with = "ts_seconds")]
    pub expires_at: DateTime<Utc>,
    /// Address of the relay
    pub addr: SocketAddr,
    /// Username for the relay
    pub username: String,
    // TODO: SecretString
    /// Password for the relay
    pub password: String,
}

/// Stun kind of relay
#[derive(Debug, Deserialize, Clone, PartialEq, Eq)]
pub struct Stun {
    pub id: RelayId,

    /// Address for the relay
    pub addr: SocketAddr,
}

/// A update to the presence of several relays.
#[derive(Debug, Deserialize, Clone, PartialEq, Eq)]
pub struct RelaysPresence {
    /// These relays have disconnected from the portal. We need to stop using them.
    pub disconnected_ids: Vec<RelayId>,
    /// These relays are still online. We can/should use these.
    pub connected: Vec<Relay>,
}

#[derive(Debug, Deserialize, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
#[serde(tag = "protocol", rename_all = "snake_case")]
pub enum Filter {
    Udp(PortRange),
    Tcp(PortRange),
    Icmp,
}

#[derive(Debug, Deserialize, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct PortRange {
    // TODO: we can use a custom deserializer
    // or maybe change the control plane to use start and end would suffice
    #[serde(default = "min_port")]
    pub port_range_start: u16,
    #[serde(default = "max_port")]
    pub port_range_end: u16,
}

// Note: these 2 functions are needed since serde doesn't yet support default_value
// see serde-rs/serde#368
fn min_port() -> u16 {
    0
}

fn max_port() -> u16 {
    u16::MAX
}

#[cfg(test)]
mod tests {
    use super::*;

    const MINIMAL_INGEST_TOKEN: &str = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJhY2NvdW50X2lkIjoiMTJmMjA3ZTAtM2I2Yy00ZjBmLTlkMGYtY2MyMmNmOWZiZjNjIiwiaWF0IjoxNzgyNzU2MDAwLCJleHAiOjE3ODU0MzQ0MDAsInJvbGUiOiJpbml0aWF0b3IiLCJkZXZpY2VfaWQiOiJkMjYzZDQ5MC1hMGJiLTQ1MmEtODk5MC0wMWQyN2ExZjExNDQiLCJwb2xpY3lfYXV0aG9yaXphdGlvbl9pZCI6ImVlYjY2MjA1LTVmNTMtNGY2NC1hY2JjLWRlZWQ0NzI5M2YwNCIsInBvbGljeV9pZCI6IjQ0ZjE5YzM3LWNmNjItNGIxOS1iMTU4LTZmODZiZGNkMmI1NyIsInJlc291cmNlX2lkIjoiNzMzZThkMTQtYzE4ZC00OTMxLWFmMzAtMzYzOWZhMDljMGMwIiwicmVzb3VyY2VfbmFtZSI6IkdpdExhYiIsImFjdG9yX2lkIjoiMjRlYjYzMWUtYzUyOS00MTgyLWE3NDYtZDk5ZWU2NmY3NDI2IiwiYWN0b3JfbmFtZSI6IkphbmUgRG9lIiwiYXV0aG9yaXplZF9hdCI6IjIwMjYtMDctMDZUMTI6MDA6MDAuMDAwMDAwWiIsImF1dGhvcml6YXRpb25fZXhwaXJlc19hdCI6IjIwMjYtMDctMDdUMTI6MDA6MDAuMDAwMDAwWiJ9.9kV77S1jxTqOo8xLjwxS0eBWOPR1lI68DlGK9eC_80g";
    const UNKNOWN_CLAIM_INGEST_TOKEN: &str = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJhY2NvdW50X2lkIjoiMTJmMjA3ZTAtM2I2Yy00ZjBmLTlkMGYtY2MyMmNmOWZiZjNjIiwiaWF0IjoxNzgyNzU2MDAwLCJleHAiOjE3ODU0MzQ0MDAsInJvbGUiOiJpbml0aWF0b3IiLCJkZXZpY2VfaWQiOiJkMjYzZDQ5MC1hMGJiLTQ1MmEtODk5MC0wMWQyN2ExZjExNDQiLCJwb2xpY3lfYXV0aG9yaXphdGlvbl9pZCI6ImVlYjY2MjA1LTVmNTMtNGY2NC1hY2JjLWRlZWQ0NzI5M2YwNCIsInBvbGljeV9pZCI6IjQ0ZjE5YzM3LWNmNjItNGIxOS1iMTU4LTZmODZiZGNkMmI1NyIsInJlc291cmNlX2lkIjoiNzMzZThkMTQtYzE4ZC00OTMxLWFmMzAtMzYzOWZhMDljMGMwIiwicmVzb3VyY2VfbmFtZSI6IkdpdExhYiIsImFjdG9yX2lkIjoiMjRlYjYzMWUtYzUyOS00MTgyLWE3NDYtZDk5ZWU2NmY3NDI2IiwiYWN0b3JfbmFtZSI6IkphbmUgRG9lIiwiYXV0aG9yaXplZF9hdCI6IjIwMjYtMDctMDZUMTI6MDA6MDAuMDAwMDAwWiIsImF1dGhvcml6YXRpb25fZXhwaXJlc19hdCI6IjIwMjYtMDctMDdUMTI6MDA6MDAuMDAwMDAwWiIsImJyYW5kX25ld19jbGFpbSI6InRvbGVyYXRlZCJ9.qwJhdnQviEc6oj2iAlPVDZvJwgShU_KuCpCfJhacmeA";
    const MISSING_POLICY_ID_INGEST_TOKEN: &str = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJhY2NvdW50X2lkIjoiMTJmMjA3ZTAtM2I2Yy00ZjBmLTlkMGYtY2MyMmNmOWZiZjNjIiwiaWF0IjoxNzgyNzU2MDAwLCJleHAiOjE3ODU0MzQ0MDAsInJvbGUiOiJpbml0aWF0b3IiLCJkZXZpY2VfaWQiOiJkMjYzZDQ5MC1hMGJiLTQ1MmEtODk5MC0wMWQyN2ExZjExNDQiLCJwb2xpY3lfYXV0aG9yaXphdGlvbl9pZCI6ImVlYjY2MjA1LTVmNTMtNGY2NC1hY2JjLWRlZWQ0NzI5M2YwNCIsInJlc291cmNlX2lkIjoiNzMzZThkMTQtYzE4ZC00OTMxLWFmMzAtMzYzOWZhMDljMGMwIiwicmVzb3VyY2VfbmFtZSI6IkdpdExhYiIsImFjdG9yX2lkIjoiMjRlYjYzMWUtYzUyOS00MTgyLWE3NDYtZDk5ZWU2NmY3NDI2IiwiYWN0b3JfbmFtZSI6IkphbmUgRG9lIiwiYXV0aG9yaXplZF9hdCI6IjIwMjYtMDctMDZUMTI6MDA6MDAuMDAwMDAwWiIsImF1dGhvcml6YXRpb25fZXhwaXJlc19hdCI6IjIwMjYtMDctMDdUMTI6MDA6MDAuMDAwMDAwWiJ9.M_OCjGvDSQPvdMN3kwFePSTMhocxzakwIz_PrvWPdsU";

    fn parse_ingest_token(token: &str) -> Result<IngestToken, serde_json::Error> {
        serde_json::from_str::<IngestToken>(&format!("\"{token}\""))
    }

    #[test]
    fn accepts_portal_minted_ingest_token() {
        let token = parse_ingest_token(TEST_INGEST_TOKEN).unwrap();

        assert_eq!(token.as_str(), TEST_INGEST_TOKEN);
    }

    #[test]
    fn accepts_ingest_token_without_nullable_claims() {
        parse_ingest_token(MINIMAL_INGEST_TOKEN).unwrap();
    }

    #[test]
    fn accepts_ingest_token_with_unknown_claims() {
        parse_ingest_token(UNKNOWN_CLAIM_INGEST_TOKEN).unwrap();
    }

    #[test]
    fn rejects_ingest_token_missing_a_guaranteed_claim() {
        parse_ingest_token(MISSING_POLICY_ID_INGEST_TOKEN).unwrap_err();
    }

    #[test]
    fn rejects_structurally_invalid_ingest_token() {
        parse_ingest_token("header.payload.signature").unwrap_err();
        parse_ingest_token("not-a-jwt").unwrap_err();
    }

    #[test]
    fn snownet_capabilities_default_is_all_false() {
        assert_eq!(
            SnownetCapabilities::default(),
            SnownetCapabilities { iceless: false }
        );
    }

    // Compile-time guard so future edits to `LOCAL` don't accidentally turn
    // off iceless support without us noticing.
    const _: () = assert!(SnownetCapabilities::LOCAL.iceless);

    #[test]
    fn snownet_capabilities_deserialize_empty_object_is_default() {
        let caps: SnownetCapabilities = serde_json::from_str("{}").unwrap();
        assert_eq!(caps, SnownetCapabilities::default());
    }

    #[test]
    fn snownet_capabilities_ignores_unknown_fields() {
        let json = r#"{ "iceless": true, "future_feature": true }"#;
        let caps: SnownetCapabilities = serde_json::from_str(json).unwrap();
        assert!(caps.iceless);
    }
}
