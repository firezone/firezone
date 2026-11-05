use std::{
    sync::{Arc, LazyLock, Weak},
    time::Duration,
};

use anyhow::{Context as _, Result};
use bytes::Bytes;
use opentelemetry_proto::tonic::collector::metrics::v1::ExportMetricsServiceRequest;
use opentelemetry_sdk::{
    error::OTelSdkResult,
    metrics::{
        InstrumentKind, ManualReader, MeterProviderBuilder, Pipeline, SdkMeterProvider,
        Temporality, data::ResourceMetrics, reader::MetricReader,
    },
};
use prost::Message as _;

static READER: LazyLock<Arc<ManualReader>> = LazyLock::new(|| {
    Arc::new(
        ManualReader::builder()
            .with_temporality(Temporality::Delta)
            .build(),
    )
});

/// Starts building the process-wide meter provider, with the reader that the [`Exporter`](crate::Exporter) collects from.
///
/// Build at most one provider from this per process.
pub fn meter_provider_builder() -> MeterProviderBuilder {
    SdkMeterProvider::builder().with_reader(SharedReader(READER.clone()))
}

/// Discards everything recorded since the last collection.
pub(crate) fn discard() {
    let _ = READER.collect(&mut ResourceMetrics::default());
}

/// Collects everything recorded since the last collection as an encoded `ExportMetricsServiceRequest`,
/// keeping only the metrics whose name matches one of `patterns`.
///
/// Returns `None` if nothing is left.
pub(crate) fn collect(patterns: &[String]) -> Result<Option<Bytes>> {
    let mut metrics = ResourceMetrics::default();
    READER
        .collect(&mut metrics)
        .context("Failed to collect metrics")?;

    let Some(request) = filter(ExportMetricsServiceRequest::from(&metrics), patterns) else {
        return Ok(None);
    };

    Ok(Some(Bytes::from(request.encode_to_vec())))
}

fn filter(
    mut request: ExportMetricsServiceRequest,
    patterns: &[String],
) -> Option<ExportMetricsServiceRequest> {
    for resource_metrics in &mut request.resource_metrics {
        for scope_metrics in &mut resource_metrics.scope_metrics {
            for _ in scope_metrics
                .metrics
                .extract_if(.., |metric| !is_allowed(&metric.name, patterns))
            {}
        }

        for _ in resource_metrics
            .scope_metrics
            .extract_if(.., |scope_metrics| scope_metrics.metrics.is_empty())
        {}
    }

    for _ in request.resource_metrics.extract_if(.., |resource_metrics| {
        resource_metrics.scope_metrics.is_empty()
    }) {}

    (!request.resource_metrics.is_empty()).then_some(request)
}

fn is_allowed(name: &str, patterns: &[String]) -> bool {
    patterns.iter().any(|pattern| matches(pattern, name))
}

/// Matches `name` against `pattern`, in which `*` stands for any run of characters.
fn matches(pattern: &str, name: &str) -> bool {
    let mut parts = pattern.split('*');
    let first = parts.next().unwrap_or_default();

    let Some(mut rest) = name.strip_prefix(first) else {
        return false;
    };
    let Some(last) = parts.next_back() else {
        return rest.is_empty();
    };

    for part in parts {
        let Some(start) = rest.find(part) else {
            return false;
        };

        rest = &rest[start + part.len()..];
    }

    rest.ends_with(last)
}

/// Lets us collect from the [`ManualReader`] that the [`SdkMeterProvider`] owns.
#[derive(Debug)]
struct SharedReader(Arc<ManualReader>);

impl MetricReader for SharedReader {
    fn register_pipeline(&self, pipeline: Weak<Pipeline>) {
        self.0.register_pipeline(pipeline)
    }

    fn collect(&self, rm: &mut ResourceMetrics) -> OTelSdkResult {
        self.0.collect(rm)
    }

    fn force_flush(&self) -> OTelSdkResult {
        self.0.force_flush()
    }

    fn shutdown_with_timeout(&self, timeout: Duration) -> OTelSdkResult {
        self.0.shutdown_with_timeout(timeout)
    }

    fn temporality(&self, kind: InstrumentKind) -> Temporality {
        self.0.temporality(kind)
    }
}

#[cfg(test)]
mod tests {
    use opentelemetry::{KeyValue, metrics::MeterProvider as _};
    use opentelemetry_proto::tonic::metrics::v1::{
        Metric, ResourceMetrics as ProtoResourceMetrics, ScopeMetrics, metric::Data,
        number_data_point::Value,
    };
    use opentelemetry_sdk::Resource;

    use super::*;

    #[test]
    fn collects_deltas_with_the_provider_resource() {
        let provider = meter_provider_builder()
            .with_resource(
                Resource::builder_empty()
                    .with_attribute(KeyValue::new("service.name", "test"))
                    .build(),
            )
            .build();
        let counter = provider.meter("test").u64_counter("test.counter").build();

        counter.add(1, &[]);
        discard();
        counter.add(2, &[]);

        let request =
            ExportMetricsServiceRequest::decode(collect(&patterns(&["test.*"])).unwrap().unwrap())
                .unwrap();
        let resource_metrics = &request.resource_metrics[0];
        let metric = &resource_metrics.scope_metrics[0].metrics[0];
        let Some(Data::Sum(sum)) = &metric.data else {
            panic!("expected a sum");
        };
        assert_eq!(
            resource_metrics.resource.as_ref().unwrap().attributes[0].key,
            "service.name"
        );
        assert_eq!(metric.name, "test.counter");
        assert_eq!(sum.data_points.len(), 1);
        assert_eq!(sum.data_points[0].value, Some(Value::AsInt(2)));
    }

    #[test]
    fn matches_like_the_portal() {
        let allowed = patterns(&["connlib.*", "tunnel.error", "*.duration", "a*b*c"]);

        for name in [
            "connlib.network.packets",
            "connlib.",
            "tunnel.error",
            "dns.duration",
            "abc",
            "aXbYc",
        ] {
            assert!(is_allowed(name, &allowed), "{name} should be allowed");
        }
        for name in ["tunnel.errors", "connlib", "duration", "acb", "abcd"] {
            assert!(!is_allowed(name, &allowed), "{name} should be rejected");
        }
        assert!(is_allowed("anything", &patterns(&["*"])));
        assert!(!is_allowed("anything", &[]));
    }

    #[test]
    fn filter_drops_disallowed_metrics_and_empty_scopes() {
        let request = request(&[&["connlib.a", "tunnel.b"], &["tunnel.c"]]);

        let filtered = filter(request, &patterns(&["connlib.*"])).unwrap();

        let scopes = &filtered.resource_metrics[0].scope_metrics;
        assert_eq!(scopes.len(), 1);
        assert_eq!(scopes[0].metrics.len(), 1);
        assert_eq!(scopes[0].metrics[0].name, "connlib.a");
    }

    #[test]
    fn filter_returns_none_if_nothing_is_allowed() {
        let request = request(&[&["connlib.a"]]);

        assert!(filter(request.clone(), &patterns(&["tunnel.*"])).is_none());
        assert!(filter(request, &[]).is_none());
    }

    fn patterns(patterns: &[&str]) -> Vec<String> {
        patterns.iter().map(|p| (*p).to_owned()).collect()
    }

    fn request(scopes: &[&[&str]]) -> ExportMetricsServiceRequest {
        ExportMetricsServiceRequest {
            resource_metrics: vec![ProtoResourceMetrics {
                scope_metrics: scopes
                    .iter()
                    .map(|names| ScopeMetrics {
                        metrics: names
                            .iter()
                            .map(|name| Metric {
                                name: (*name).to_owned(),
                                ..Default::default()
                            })
                            .collect(),
                        ..Default::default()
                    })
                    .collect(),
                ..Default::default()
            }],
        }
    }
}
