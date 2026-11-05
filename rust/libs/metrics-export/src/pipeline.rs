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

/// Collects everything recorded since the last collection as an encoded `ExportMetricsServiceRequest`.
///
/// Returns `None` if nothing was recorded.
pub(crate) fn collect() -> Result<Option<Bytes>> {
    let mut metrics = ResourceMetrics::default();
    READER
        .collect(&mut metrics)
        .context("Failed to collect metrics")?;

    if metrics.scope_metrics().next().is_none() {
        return Ok(None);
    }

    let request = ExportMetricsServiceRequest::from(&metrics);

    Ok(Some(Bytes::from(request.encode_to_vec())))
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
    use opentelemetry_proto::tonic::metrics::v1::{metric::Data, number_data_point::Value};
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

        let request = ExportMetricsServiceRequest::decode(collect().unwrap().unwrap()).unwrap();
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
}
