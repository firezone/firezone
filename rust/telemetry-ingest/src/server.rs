//! The HTTP surface: OTLP/HTTP JSON in, OTLP protobuf out.

use std::sync::Arc;

use axum::Json;
use axum::extract::{FromRef, FromRequestParts, State};
use axum::http::{StatusCode, request::Parts};
use axum::routing::{get, post};
use opentelemetry_proto::tonic::collector::metrics::v1::ExportMetricsServiceRequest;
use prost::Message as _;

use crate::auth::{self, Claims, PublicKeys};
use crate::forward::Sink;

#[derive(Clone)]
pub struct AppState {
    pub keys: Arc<PublicKeys>,
    pub sink: Arc<dyn Sink>,
    /// When set, only requests carrying this Azure Front Door id are served, so
    /// the origin cannot be reached by bypassing the front door.
    pub expected_front_door_id: Option<Arc<str>>,
}

pub fn router(state: AppState) -> axum::Router {
    axum::Router::new()
        .route("/v1/metrics", post(export_metrics))
        .route("/healthz", get(healthz))
        .with_state(state)
}

async fn export_metrics(
    State(state): State<AppState>,
    _: FromFrontDoor,
    Verified(claims): Verified,
    Json(mut request): Json<ExportMetricsServiceRequest>,
) -> Result<Json<serde_json::Value>, StatusCode> {
    // Gateways do not know their own identity and send `"resource": null`, but
    // nothing stops a token holder from sending one. Attribution comes from the
    // signed claims alone, so whatever the client sent is replaced.
    let resource = claims.resource();

    for resource_metrics in &mut request.resource_metrics {
        resource_metrics.resource = Some(resource.clone());
    }

    state
        .sink
        .forward(request.encode_to_vec())
        .await
        .map_err(|e| {
            tracing::warn!(
                account_id = %claims.account_id,
                gateway_id = %claims.gateway_id,
                "Failed to forward metrics report: {e:#}"
            );

            StatusCode::BAD_GATEWAY
        })?;

    Ok(Json(serde_json::json!({})))
}

async fn healthz() -> StatusCode {
    StatusCode::OK
}

/// The claims of a verified `Authorization: Bearer` token.
///
/// Extracting from the request parts rather than the body means an unauthorized
/// request is rejected before its body is buffered.
struct Verified(Claims);

impl<S> FromRequestParts<S> for Verified
where
    AppState: FromRef<S>,
    S: Send + Sync,
{
    type Rejection = StatusCode;

    async fn from_request_parts(parts: &mut Parts, state: &S) -> Result<Self, Self::Rejection> {
        let state = AppState::from_ref(state);

        let token = parts
            .headers
            .get(axum::http::header::AUTHORIZATION)
            .and_then(|value| value.to_str().ok())
            .and_then(|value| value.strip_prefix("Bearer "))
            .ok_or(StatusCode::UNAUTHORIZED)?;

        let claims =
            auth::verify(token, &state.keys, std::time::SystemTime::now()).map_err(|rejected| {
                tracing::debug!("Rejected metrics report: token is {rejected}");

                StatusCode::UNAUTHORIZED
            })?;

        Ok(Self(claims))
    }
}

struct FromFrontDoor;

impl<S> FromRequestParts<S> for FromFrontDoor
where
    AppState: FromRef<S>,
    S: Send + Sync,
{
    type Rejection = StatusCode;

    async fn from_request_parts(parts: &mut Parts, state: &S) -> Result<Self, Self::Rejection> {
        let Some(expected) = AppState::from_ref(state).expected_front_door_id else {
            return Ok(Self);
        };

        let presented = parts
            .headers
            .get("x-azure-fdid")
            .and_then(|value| value.to_str().ok())
            .ok_or(StatusCode::FORBIDDEN)?;

        if presented != &*expected {
            return Err(StatusCode::FORBIDDEN);
        }

        Ok(Self)
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Mutex;
    use std::time::{Duration, SystemTime, UNIX_EPOCH};

    use anyhow::Result;
    use axum::body::Body;
    use axum::http::{Request, header};
    use futures::future::BoxFuture;
    use opentelemetry_proto::tonic::common::v1::any_value;
    use tower::ServiceExt as _;

    use crate::auth::tests::Signer;

    use super::*;

    const KID: &str = "test-key";

    #[derive(Default)]
    struct Collected(Mutex<Vec<Vec<u8>>>);

    impl Sink for Arc<Collected> {
        fn forward(&self, report: Vec<u8>) -> BoxFuture<'_, Result<()>> {
            self.0.lock().expect("not poisoned").push(report);

            Box::pin(std::future::ready(Ok(())))
        }
    }

    #[tokio::test]
    async fn accepts_a_report_and_forwards_it_as_protobuf() {
        let (router, signer, forwarded) = fixture(None);

        let response = router
            .oneshot(export_request(&signer.token(valid_claims()), None))
            .await
            .unwrap();

        assert_eq!(response.status(), StatusCode::OK);

        let forwarded = forwarded.0.lock().unwrap().clone();
        let report = ExportMetricsServiceRequest::decode(forwarded[0].as_slice()).unwrap();

        let metric = &report.resource_metrics[0].scope_metrics[0].metrics[0];
        assert_eq!(metric.name, "flow_logs.report.errors");
    }

    #[tokio::test]
    async fn overwrites_client_supplied_resource_attributes() {
        let (router, signer, forwarded) = fixture(None);

        let impostor = serde_json::json!({
            "attributes": [{
                "key": "firezone.account.id",
                "value": { "stringValue": "00000000-0000-0000-0000-000000000000" }
            }, {
                "key": "service.name",
                "value": { "stringValue": "impostor" }
            }]
        });

        let response = router
            .oneshot(export_request(
                &signer.token(valid_claims()),
                Some(impostor),
            ))
            .await
            .unwrap();

        assert_eq!(response.status(), StatusCode::OK);

        let forwarded = forwarded.0.lock().unwrap().clone();
        let report = ExportMetricsServiceRequest::decode(forwarded[0].as_slice()).unwrap();
        let resource = report.resource_metrics[0].resource.clone().unwrap();

        let attributes = resource
            .attributes
            .iter()
            .map(|attribute| {
                let Some(any_value::Value::StringValue(value)) = attribute
                    .value
                    .as_ref()
                    .and_then(|value| value.value.clone())
                else {
                    panic!("expected a string attribute")
                };

                (attribute.key.clone(), value)
            })
            .collect::<Vec<_>>();

        assert_eq!(
            attributes,
            vec![
                ("firezone.account.id".to_owned(), "account".to_owned()),
                ("firezone.account.slug".to_owned(), "acme".to_owned()),
                ("firezone.gateway.id".to_owned(), "gateway".to_owned()),
                ("firezone.site.id".to_owned(), "site".to_owned()),
                ("firezone.site.name".to_owned(), "Production".to_owned()),
            ]
        );
    }

    #[tokio::test]
    async fn rejects_a_report_without_a_token() {
        let (router, _signer, _) = fixture(None);

        let request = Request::builder()
            .method("POST")
            .uri("/v1/metrics")
            .header(header::CONTENT_TYPE, "application/json")
            .body(Body::from(body(None)))
            .unwrap();

        let response = router.oneshot(request).await.unwrap();

        assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
    }

    #[tokio::test]
    async fn rejects_a_report_signed_by_another_key() {
        let (router, _signer, _) = fixture(None);
        let impostor = Signer::generate(KID);

        let response = router
            .oneshot(export_request(&impostor.token(valid_claims()), None))
            .await
            .unwrap();

        assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
    }

    #[tokio::test]
    async fn serves_healthz_without_a_token() {
        let (router, _signer, _) = fixture(None);

        let request = Request::builder()
            .uri("/healthz")
            .body(Body::empty())
            .unwrap();

        assert_eq!(
            router.oneshot(request).await.unwrap().status(),
            StatusCode::OK
        );
    }

    #[tokio::test]
    async fn requires_the_front_door_id_when_one_is_configured() {
        let (router, signer, _) = fixture(Some("front-door"));

        let response = router
            .clone()
            .oneshot(export_request(&signer.token(valid_claims()), None))
            .await
            .unwrap();

        assert_eq!(response.status(), StatusCode::FORBIDDEN);

        let mut request = export_request(&signer.token(valid_claims()), None);
        request
            .headers_mut()
            .insert("x-azure-fdid", "front-door".parse().unwrap());

        assert_eq!(
            router.oneshot(request).await.unwrap().status(),
            StatusCode::OK
        );
    }

    #[tokio::test]
    async fn rejects_the_wrong_front_door_id() {
        let (router, signer, _) = fixture(Some("front-door"));

        let mut request = export_request(&signer.token(valid_claims()), None);
        request
            .headers_mut()
            .insert("x-azure-fdid", "somebody-else".parse().unwrap());

        assert_eq!(
            router.oneshot(request).await.unwrap().status(),
            StatusCode::FORBIDDEN
        );
    }

    fn fixture(front_door_id: Option<&str>) -> (axum::Router, Signer, Arc<Collected>) {
        let signer = Signer::generate(KID);
        let forwarded = Arc::new(Collected::default());

        let router = router(AppState {
            keys: Arc::new(PublicKeys::parse(&signer.configured_public_key()).unwrap()),
            sink: Arc::new(forwarded.clone()),
            expected_front_door_id: front_door_id.map(Arc::from),
        });

        (router, signer, forwarded)
    }

    fn valid_claims() -> serde_json::Value {
        serde_json::json!({
            "account_id": "account",
            "account_slug": "acme",
            "gateway_id": "gateway",
            "site_id": "site",
            "site_name": "Production",
            "iat": unix_seconds(SystemTime::now()),
            "exp": unix_seconds(SystemTime::now() + Duration::from_secs(600)),
        })
    }

    fn export_request(token: &str, resource: Option<serde_json::Value>) -> Request<Body> {
        Request::builder()
            .method("POST")
            .uri("/v1/metrics")
            .header(header::AUTHORIZATION, format!("Bearer {token}"))
            .header(header::CONTENT_TYPE, "application/json")
            .body(Body::from(body(resource)))
            .unwrap()
    }

    /// An OTLP/JSON report shaped exactly like the ones gateways send.
    fn body(resource: Option<serde_json::Value>) -> String {
        serde_json::json!({
            "resourceMetrics": [{
                "resource": resource,
                "scopeMetrics": [{
                    "scope": { "name": "connlib", "version": "" },
                    "metrics": [{
                        "name": "flow_logs.report.errors",
                        "description": "Number of failures to spool a flow-log report.",
                        "unit": "{error}",
                        "sum": {
                            "dataPoints": [{
                                "attributes": [{
                                    "key": "error.type",
                                    "value": { "stringValue": "io::ErrorKind::PermissionDenied" }
                                }],
                                "startTimeUnixNano": "1000000000",
                                "timeUnixNano": "2000000000",
                                "asInt": 3
                            }],
                            "aggregationTemporality": 1,
                            "isMonotonic": true
                        }
                    }],
                    "schemaUrl": ""
                }],
                "schemaUrl": ""
            }]
        })
        .to_string()
    }

    fn unix_seconds(time: SystemTime) -> u64 {
        time.duration_since(UNIX_EPOCH).unwrap().as_secs()
    }
}
