use std::sync::Arc;

use serde::Deserialize;

/// A per-authorization flow-log ingest token minted by the portal: an HS256
/// JWT carrying the attribution claims, used as the `Bearer` credential when
/// uploading that authorization's flow logs.
///
/// Deserializing parses and retains the claims; the signature is not
/// verified because only the portal and the ingest API hold the key.
/// Internally reference-counted: cloning is a refcount bump, so the token can
/// be recorded into per-packet flow data without copying it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct IngestToken(Arc<IngestTokenInner>);

#[derive(Debug, PartialEq, Eq)]
struct IngestTokenInner {
    raw: String,
    claims: IngestTokenClaims,
}

impl IngestToken {
    pub fn as_str(&self) -> &str {
        &self.0.raw
    }

    pub fn claims(&self) -> &IngestTokenClaims {
        &self.0.claims
    }
}

impl<'de> Deserialize<'de> for IngestToken {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        let raw = String::deserialize(deserializer)?;

        let claims = parse_ingest_token_claims(&raw).map_err(serde::de::Error::custom)?;

        Ok(Self(Arc::new(IngestTokenInner { raw, claims })))
    }
}

fn parse_ingest_token_claims(token: &str) -> Result<IngestTokenClaims, String> {
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
    let claims = serde_json::from_slice::<IngestTokenClaims>(&payload)
        .map_err(|e| format!("ingest token claims are invalid: {e}"))?;

    let signature = URL_SAFE_NO_PAD
        .decode(signature)
        .map_err(|e| format!("ingest token signature is not base64url: {e}"))?;

    if signature.is_empty() {
        return Err("ingest token signature is empty".to_owned());
    }

    Ok(claims)
}

#[derive(Deserialize)]
struct JwtHeader {
    alg: String,
}

/// The claims the portal stamps into every ingest token. The `Option`s are
/// nullable attribution claims, and unknown claims are tolerated.
#[derive(Debug, Deserialize, Clone, PartialEq, Eq)]
pub struct IngestTokenClaims {
    pub account_id: String,
    pub iat: u64,
    pub exp: u64,
    /// Whether this authorization's flow logs (and this token) are spooled to
    /// disk for upload.
    pub uploads_enabled: bool,
    pub role: IngestTokenRole,
    pub device_id: String,
    pub policy_authorization_id: String,
    pub policy_id: String,
    pub resource_id: String,
    pub resource_name: String,
    pub actor_id: String,
    pub actor_name: String,
    pub authorized_at: String,
    pub authorization_expires_at: String,
    pub resource_address: Option<String>,
    pub actor_email: Option<String>,
    pub auth_provider_id: Option<String>,
    pub client_version: Option<String>,
    pub device_os_name: Option<String>,
    pub device_os_version: Option<String>,
    pub device_serial: Option<String>,
    pub device_uuid: Option<String>,
    pub device_identifier_for_vendor: Option<String>,
    pub device_firebase_installation_id: Option<String>,
}

#[derive(Debug, Deserialize, Clone, Copy, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum IngestTokenRole {
    Initiator,
    Responder,
}

impl IngestTokenRole {
    pub fn as_str(self) -> &'static str {
        match self {
            IngestTokenRole::Initiator => "initiator",
            IngestTokenRole::Responder => "responder",
        }
    }
}

/// A portal-minted ingest token for tests, signed with a throwaway key.
pub const TEST_INGEST_TOKEN: &str = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJhY2NvdW50X2lkIjoiMTJmMjA3ZTAtM2I2Yy00ZjBmLTlkMGYtY2MyMmNmOWZiZjNjIiwiaWF0IjoxNzgyNzU2MDAwLCJleHAiOjE3ODU0MzQ0MDAsInVwbG9hZHNfZW5hYmxlZCI6dHJ1ZSwicm9sZSI6ImluaXRpYXRvciIsImRldmljZV9pZCI6ImQyNjNkNDkwLWEwYmItNDUyYS04OTkwLTAxZDI3YTFmMTE0NCIsInBvbGljeV9hdXRob3JpemF0aW9uX2lkIjoiZWViNjYyMDUtNWY1My00ZjY0LWFjYmMtZGVlZDQ3MjkzZjA0IiwicG9saWN5X2lkIjoiNDRmMTljMzctY2Y2Mi00YjE5LWIxNTgtNmY4NmJkY2QyYjU3IiwicmVzb3VyY2VfaWQiOiI3MzNlOGQxNC1jMThkLTQ5MzEtYWYzMC0zNjM5ZmEwOWMwYzAiLCJyZXNvdXJjZV9uYW1lIjoiR2l0TGFiIiwiYWN0b3JfaWQiOiIyNGViNjMxZS1jNTI5LTQxODItYTc0Ni1kOTllZTY2Zjc0MjYiLCJhY3Rvcl9uYW1lIjoiSmFuZSBEb2UiLCJhdXRob3JpemVkX2F0IjoiMjAyNi0wNy0wNlQxMjowMDowMC4wMDAwMDBaIiwiYXV0aG9yaXphdGlvbl9leHBpcmVzX2F0IjoiMjAyNi0wNy0wN1QxMjowMDowMC4wMDAwMDBaIiwicmVzb3VyY2VfYWRkcmVzcyI6ImdpdGxhYi5teWNvcnAuY29tIiwiYWN0b3JfZW1haWwiOiJqYW5lQG15Y29ycC5jb20iLCJhdXRoX3Byb3ZpZGVyX2lkIjoiZjk1ZWYxYTUtYjc2Yi00ZDU5LTliNGItNmIwYzJkNDdlMTI4IiwiY2xpZW50X3ZlcnNpb24iOiIxLjUuMTEiLCJkZXZpY2Vfb3NfbmFtZSI6Im1hY09TIiwiZGV2aWNlX29zX3ZlcnNpb24iOiIxNS41IiwiZGV2aWNlX3NlcmlhbCI6IkMwMlhMMEdZSkdINSIsImRldmljZV91dWlkIjoiMGYwYzIyYjEtNjRmYS00YTA0LWExYzEtNWI0YjZjMGMyZDQ3IiwiZGV2aWNlX2lkZW50aWZpZXJfZm9yX3ZlbmRvciI6IjVhYzM0N2Y4LWNiYjYtNGIwZi04ZjBlLTFmNGQ0N2ExYzE1YiIsImRldmljZV9maXJlYmFzZV9pbnN0YWxsYXRpb25faWQiOiJjQW1wMWVGMXJlQmFzZUlkIn0.aHR1FGQ-cqGS2PZQP5iePtTSUc1kRI6Xj9RWvpqIw_A";

#[cfg(test)]
mod tests {
    use super::*;

    const MINIMAL_INGEST_TOKEN: &str = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJhY2NvdW50X2lkIjoiMTJmMjA3ZTAtM2I2Yy00ZjBmLTlkMGYtY2MyMmNmOWZiZjNjIiwiaWF0IjoxNzgyNzU2MDAwLCJleHAiOjE3ODU0MzQ0MDAsInVwbG9hZHNfZW5hYmxlZCI6dHJ1ZSwicm9sZSI6ImluaXRpYXRvciIsImRldmljZV9pZCI6ImQyNjNkNDkwLWEwYmItNDUyYS04OTkwLTAxZDI3YTFmMTE0NCIsInBvbGljeV9hdXRob3JpemF0aW9uX2lkIjoiZWViNjYyMDUtNWY1My00ZjY0LWFjYmMtZGVlZDQ3MjkzZjA0IiwicG9saWN5X2lkIjoiNDRmMTljMzctY2Y2Mi00YjE5LWIxNTgtNmY4NmJkY2QyYjU3IiwicmVzb3VyY2VfaWQiOiI3MzNlOGQxNC1jMThkLTQ5MzEtYWYzMC0zNjM5ZmEwOWMwYzAiLCJyZXNvdXJjZV9uYW1lIjoiR2l0TGFiIiwiYWN0b3JfaWQiOiIyNGViNjMxZS1jNTI5LTQxODItYTc0Ni1kOTllZTY2Zjc0MjYiLCJhY3Rvcl9uYW1lIjoiSmFuZSBEb2UiLCJhdXRob3JpemVkX2F0IjoiMjAyNi0wNy0wNlQxMjowMDowMC4wMDAwMDBaIiwiYXV0aG9yaXphdGlvbl9leHBpcmVzX2F0IjoiMjAyNi0wNy0wN1QxMjowMDowMC4wMDAwMDBaIn0.9kV77S1jxTqOo8xLjwxS0eBWOPR1lI68DlGK9eC_80g";
    const UNKNOWN_CLAIM_INGEST_TOKEN: &str = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJhY2NvdW50X2lkIjoiMTJmMjA3ZTAtM2I2Yy00ZjBmLTlkMGYtY2MyMmNmOWZiZjNjIiwiaWF0IjoxNzgyNzU2MDAwLCJleHAiOjE3ODU0MzQ0MDAsInVwbG9hZHNfZW5hYmxlZCI6dHJ1ZSwicm9sZSI6ImluaXRpYXRvciIsImRldmljZV9pZCI6ImQyNjNkNDkwLWEwYmItNDUyYS04OTkwLTAxZDI3YTFmMTE0NCIsInBvbGljeV9hdXRob3JpemF0aW9uX2lkIjoiZWViNjYyMDUtNWY1My00ZjY0LWFjYmMtZGVlZDQ3MjkzZjA0IiwicG9saWN5X2lkIjoiNDRmMTljMzctY2Y2Mi00YjE5LWIxNTgtNmY4NmJkY2QyYjU3IiwicmVzb3VyY2VfaWQiOiI3MzNlOGQxNC1jMThkLTQ5MzEtYWYzMC0zNjM5ZmEwOWMwYzAiLCJyZXNvdXJjZV9uYW1lIjoiR2l0TGFiIiwiYWN0b3JfaWQiOiIyNGViNjMxZS1jNTI5LTQxODItYTc0Ni1kOTllZTY2Zjc0MjYiLCJhY3Rvcl9uYW1lIjoiSmFuZSBEb2UiLCJhdXRob3JpemVkX2F0IjoiMjAyNi0wNy0wNlQxMjowMDowMC4wMDAwMDBaIiwiYXV0aG9yaXphdGlvbl9leHBpcmVzX2F0IjoiMjAyNi0wNy0wN1QxMjowMDowMC4wMDAwMDBaIiwiYnJhbmRfbmV3X2NsYWltIjoidG9sZXJhdGVkIn0.qwJhdnQviEc6oj2iAlPVDZvJwgShU_KuCpCfJhacmeA";
    const MISSING_POLICY_ID_INGEST_TOKEN: &str = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJhY2NvdW50X2lkIjoiMTJmMjA3ZTAtM2I2Yy00ZjBmLTlkMGYtY2MyMmNmOWZiZjNjIiwiaWF0IjoxNzgyNzU2MDAwLCJleHAiOjE3ODU0MzQ0MDAsInVwbG9hZHNfZW5hYmxlZCI6dHJ1ZSwicm9sZSI6ImluaXRpYXRvciIsImRldmljZV9pZCI6ImQyNjNkNDkwLWEwYmItNDUyYS04OTkwLTAxZDI3YTFmMTE0NCIsInBvbGljeV9hdXRob3JpemF0aW9uX2lkIjoiZWViNjYyMDUtNWY1My00ZjY0LWFjYmMtZGVlZDQ3MjkzZjA0IiwicmVzb3VyY2VfaWQiOiI3MzNlOGQxNC1jMThkLTQ5MzEtYWYzMC0zNjM5ZmEwOWMwYzAiLCJyZXNvdXJjZV9uYW1lIjoiR2l0TGFiIiwiYWN0b3JfaWQiOiIyNGViNjMxZS1jNTI5LTQxODItYTc0Ni1kOTllZTY2Zjc0MjYiLCJhY3Rvcl9uYW1lIjoiSmFuZSBEb2UiLCJhdXRob3JpemVkX2F0IjoiMjAyNi0wNy0wNlQxMjowMDowMC4wMDAwMDBaIiwiYXV0aG9yaXphdGlvbl9leHBpcmVzX2F0IjoiMjAyNi0wNy0wN1QxMjowMDowMC4wMDAwMDBaIn0.M_OCjGvDSQPvdMN3kwFePSTMhocxzakwIz_PrvWPdsU";

    fn parse_ingest_token(token: &str) -> Result<IngestToken, serde_json::Error> {
        serde_json::from_str::<IngestToken>(&format!("\"{token}\""))
    }

    #[test]
    fn accepts_portal_minted_ingest_token() {
        let token = parse_ingest_token(TEST_INGEST_TOKEN).unwrap();

        assert_eq!(token.as_str(), TEST_INGEST_TOKEN);
        assert_eq!(token.claims().role, IngestTokenRole::Initiator);
        assert!(token.claims().uploads_enabled);
        assert_eq!(token.claims().resource_name, "GitLab");
        assert_eq!(
            token.claims().actor_email.as_deref(),
            Some("jane@mycorp.com")
        );
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
}
