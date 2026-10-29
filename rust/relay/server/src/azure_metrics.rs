use anyhow::{Context as _, Result, bail};
use opentelemetry_http::{Bytes, HttpClient, HttpError, Request, Response};
use opentelemetry_otlp::{Protocol, WithExportConfig as _, WithHttpConfig as _};
use opentelemetry_sdk::Resource;
use opentelemetry_sdk::metrics::{
    Aggregation, Instrument, InstrumentKind, SdkMeterProvider, Stream, Temporality,
};
use reqwest::header::{AUTHORIZATION, HeaderValue};
use serde::Deserialize;
use std::fmt;
use std::io::Read as _;
use std::sync::Mutex;
use std::time::{Duration, SystemTime};
use url::Url;

pub fn meter_provider(endpoint: &Url, resource: Resource) -> Result<SdkMeterProvider> {
    if endpoint.scheme() != "https"
        || !endpoint.username().is_empty()
        || endpoint.password().is_some()
        || endpoint.fragment().is_some()
    {
        bail!("Azure metrics endpoint must be an HTTPS URL without credentials or a fragment");
    }

    let client = AzureHttpClient::new(endpoint)?;
    let exporter = opentelemetry_otlp::MetricExporter::builder()
        .with_http()
        .with_endpoint(endpoint.as_str())
        .with_protocol(Protocol::HttpBinary)
        .with_http_client(client)
        .with_temporality(Temporality::Delta)
        .build()
        .context("Failed to build Azure metrics exporter")?;

    let provider = SdkMeterProvider::builder()
        .with_resource(resource)
        .with_periodic_exporter(exporter)
        .with_view(exponential_histograms)
        .build();

    Ok(provider)
}

fn exponential_histograms(instrument: &Instrument) -> Option<Stream> {
    if instrument.kind() != InstrumentKind::Histogram {
        return None;
    }

    Stream::builder()
        .with_aggregation(Aggregation::Base2ExponentialHistogram {
            max_size: 160,
            max_scale: 20,
            record_min_max: true,
        })
        .build()
        .ok()
}

struct AzureHttpClient {
    endpoint: Url,
    imds_endpoint: Url,
    client: reqwest::blocking::Client,
    token: Mutex<Option<Token>>,
}

impl fmt::Debug for AzureHttpClient {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("AzureHttpClient")
            .field("endpoint", &self.endpoint)
            .finish_non_exhaustive()
    }
}

#[async_trait::async_trait]
impl HttpClient for AzureHttpClient {
    async fn send_bytes(&self, mut request: Request<Bytes>) -> Result<Response<Bytes>, HttpError> {
        if request.uri() != self.endpoint.as_str() {
            return Err("Azure metrics export destination changed".into());
        }

        let authorization = self.authorization()?;
        request.headers_mut().insert(AUTHORIZATION, authorization);
        let response = self.client.send_bytes(request).await?;

        if response.status() == reqwest::StatusCode::UNAUTHORIZED {
            let mut token = self.token.lock().map_err(|_| "Azure token lock poisoned")?;
            *token = None;
        }

        Ok(response)
    }
}

impl AzureHttpClient {
    fn new(endpoint: &Url) -> Result<Self> {
        let client = reqwest::blocking::Client::builder()
            .timeout(Duration::from_secs(5))
            .no_proxy()
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .context("Failed to build Azure metrics HTTP client")?;

        Ok(Self {
            endpoint: endpoint.clone(),
            imds_endpoint: Url::parse("http://169.254.169.254/metadata/identity/oauth2/token")?,
            client,
            token: Mutex::new(None),
        })
    }

    fn authorization(&self) -> Result<HeaderValue> {
        let mut token = self
            .token
            .lock()
            .map_err(|_| anyhow::anyhow!("Azure token lock poisoned"))?;
        let now = SystemTime::now();

        if let Some(token) = token.as_ref()
            && token.expires_at > now + Duration::from_secs(60)
        {
            return Ok(token.authorization.clone());
        }

        let response = self
            .client
            .get(self.imds_endpoint.clone())
            .query(&[
                ("api-version", "2018-02-01"),
                ("resource", "https://monitor.azure.com/"),
            ])
            .header("Metadata", "true")
            .send()
            .context("Failed to request Azure managed identity token")?
            .error_for_status()
            .context("Azure managed identity token request failed")?;
        let response: TokenResponse = serde_json::from_reader(response.take(64 * 1024))
            .context("Invalid Azure managed identity token response")?;
        let expires_at = SystemTime::UNIX_EPOCH
            .checked_add(Duration::from_secs(response.expires_on.parse()?))
            .context("Invalid Azure token expiration")?;
        if expires_at <= SystemTime::now() {
            bail!("Azure managed identity returned an expired token");
        }

        let mut authorization =
            HeaderValue::from_str(&format!("Bearer {}", response.access_token))?;
        authorization.set_sensitive(true);
        *token = Some(Token {
            authorization: authorization.clone(),
            expires_at,
        });

        Ok(authorization)
    }
}

struct Token {
    authorization: HeaderValue,
    expires_at: SystemTime,
}

#[derive(Deserialize)]
struct TokenResponse {
    access_token: String,
    expires_on: String,
}

#[cfg(test)]
mod tests {
    use super::*;
    use opentelemetry::metrics::MeterProvider as _;
    use opentelemetry_sdk::metrics::InMemoryMetricExporterBuilder;
    use opentelemetry_sdk::metrics::data::{AggregatedMetrics, MetricData};
    use std::io::{BufRead as _, BufReader, Write as _};
    use std::net::TcpListener;
    use std::thread;

    #[test]
    fn caches_tokens_and_refreshes_after_rejection() {
        let expires_at = SystemTime::now() + Duration::from_secs(3600);
        let (endpoint, server) = mock_server(vec![
            (200, token_response("first", expires_at)),
            (200, String::new()),
            (401, String::new()),
            (200, token_response("second", expires_at)),
            (200, String::new()),
        ]);
        let client = test_client(&endpoint);

        for status in [200, 401, 200] {
            let request = Request::post(endpoint.as_str())
                .body(Bytes::from_static(b"metrics"))
                .unwrap();
            let response = futures::executor::block_on(client.send_bytes(request)).unwrap();
            assert_eq!(response.status(), status);
        }

        let requests = server.join().unwrap();
        assert!(requests[0].starts_with("GET /metadata/identity/oauth2/token?"));
        assert!(requests[0].contains("api-version=2018-02-01"));
        assert!(requests[0].contains("resource=https%3A%2F%2Fmonitor.azure.com%2F"));
        assert!(requests[0].contains("metadata: true"));
        assert!(!requests[0].contains("client_id"));
        assert!(requests[1].starts_with("POST /datacollectionRules/test/otlp/v1/metrics "));
        assert!(requests[1].contains("authorization: Bearer first"));
        assert!(requests[2].contains("authorization: Bearer first"));
        assert!(requests[4].contains("authorization: Bearer second"));
        assert!(!format!("{client:?}").contains("second"));
    }

    #[test]
    fn refreshes_tokens_before_expiry() {
        let (endpoint, server) = mock_server(vec![
            (
                200,
                token_response("expiring", SystemTime::now() + Duration::from_secs(30)),
            ),
            (
                200,
                token_response("fresh", SystemTime::now() + Duration::from_secs(3600)),
            ),
        ]);
        let client = test_client(&endpoint);

        assert_eq!(client.authorization().unwrap(), "Bearer expiring");
        assert_eq!(client.authorization().unwrap(), "Bearer fresh");
        assert_eq!(client.authorization().unwrap(), "Bearer fresh");
        assert_eq!(server.join().unwrap().len(), 2);
    }

    #[test]
    fn rejects_changed_export_destinations_before_requesting_credentials() {
        let endpoint = Url::parse("http://127.0.0.1:1/metrics").unwrap();
        let client = test_client(&endpoint);
        let request = Request::post("http://127.0.0.1:2/metrics")
            .body(Bytes::new())
            .unwrap();

        let error = futures::executor::block_on(client.send_bytes(request)).unwrap_err();

        assert_eq!(
            error.to_string(),
            "Azure metrics export destination changed"
        );
    }

    #[test]
    fn preserves_histogram_buckets_and_exports_interval_deltas() {
        let exporter = InMemoryMetricExporterBuilder::new()
            .with_temporality(Temporality::Delta)
            .build();
        let provider = SdkMeterProvider::builder()
            .with_periodic_exporter(exporter.clone())
            .with_view(exponential_histograms)
            .build();
        let histogram = provider.meter("test").f64_histogram("latency").build();

        for value in [1.0, 2.0, 2.0, 4.0] {
            histogram.record(value, &[]);
        }
        provider.force_flush().unwrap();
        histogram.record(8.0, &[]);
        provider.force_flush().unwrap();

        let exports = exporter.get_finished_metrics().unwrap();
        for (export, (count, sum)) in exports.iter().zip([(4, 9.0), (1, 8.0)]) {
            let metric = export
                .scope_metrics()
                .next()
                .unwrap()
                .metrics()
                .next()
                .unwrap();
            let AggregatedMetrics::F64(MetricData::ExponentialHistogram(histogram)) = metric.data()
            else {
                panic!("Expected exponential histogram");
            };
            let point = histogram.data_points().next().unwrap();

            assert_eq!(histogram.temporality(), Temporality::Delta);
            assert_eq!(point.count(), count);
            assert_eq!(point.sum(), sum);
            assert_eq!(point.positive_bucket().counts().sum::<u64>(), count as u64);
        }
        assert_eq!(exports.len(), 2);
        provider.shutdown().unwrap();
    }

    fn test_client(endpoint: &Url) -> AzureHttpClient {
        let mut client = AzureHttpClient::new(endpoint).unwrap();
        client.imds_endpoint = endpoint.join("/metadata/identity/oauth2/token").unwrap();
        client
    }

    fn token_response(token: &str, expires_at: SystemTime) -> String {
        serde_json::json!({
            "access_token": token,
            "expires_on": expires_at.duration_since(SystemTime::UNIX_EPOCH).unwrap().as_secs().to_string(),
        })
        .to_string()
    }

    fn mock_server(responses: Vec<(u16, String)>) -> (Url, thread::JoinHandle<Vec<String>>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let endpoint = Url::parse(&format!(
            "http://{}/datacollectionRules/test/otlp/v1/metrics",
            listener.local_addr().unwrap()
        ))
        .unwrap();
        let handle = thread::spawn(move || {
            let mut requests = Vec::new();
            for (status, body) in responses {
                let (stream, _) = listener.accept().unwrap();
                stream
                    .set_read_timeout(Some(Duration::from_secs(5)))
                    .unwrap();
                let mut stream = BufReader::new(stream);
                let mut request = String::new();
                loop {
                    let mut line = String::new();
                    assert_ne!(stream.read_line(&mut line).unwrap(), 0);
                    if line == "\r\n" {
                        break;
                    }
                    request.push_str(&line);
                }
                requests.push(request);
                write!(
                    stream.get_mut(),
                    "HTTP/1.1 {status} Response\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                )
                .unwrap();
            }
            requests
        });

        (endpoint, handle)
    }
}
