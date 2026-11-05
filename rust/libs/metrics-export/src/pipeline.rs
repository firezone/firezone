use std::{
    sync::{
        Arc, LazyLock, Weak,
        atomic::{AtomicBool, Ordering},
    },
    time::Duration,
};

use anyhow::{Context as _, Result};
use bytes::Bytes;
use opentelemetry::{
    InstrumentationScope, KeyValue,
    metrics::{
        Counter, Gauge, Histogram, HistogramBuilder, InstrumentBuilder, InstrumentProvider, Meter,
        MeterProvider, SyncInstrument, UpDownCounter,
    },
};
use opentelemetry_proto::tonic::collector::metrics::v1::ExportMetricsServiceRequest;
use opentelemetry_sdk::{
    Resource,
    error::OTelSdkResult,
    metrics::{
        InstrumentKind, ManualReader, Pipeline, SdkMeterProvider, Temporality,
        data::ResourceMetrics, reader::MetricReader,
    },
};
use prost::Message as _;

static PIPELINE: LazyLock<ExportPipeline> = LazyLock::new(ExportPipeline::new);

/// Wraps `inner` so that its instruments also record into the export pipeline.
///
/// Measurements reach the export pipeline only while an [`Exporter`](crate::Exporter) is configured with a token.
pub fn meter_provider<P>(inner: P) -> TeeMeterProvider<P>
where
    P: MeterProvider,
{
    TeeMeterProvider { inner }
}

pub struct TeeMeterProvider<P> {
    inner: P,
}

impl<P> MeterProvider for TeeMeterProvider<P>
where
    P: MeterProvider,
{
    fn meter_with_scope(&self, scope: InstrumentationScope) -> Meter {
        Meter::new(Arc::new(TeeInstrumentProvider {
            inner: self.inner.meter_with_scope(scope.clone()),
            export: PIPELINE.provider.meter_with_scope(scope),
        }))
    }
}

pub(crate) fn set_recording(recording: bool) {
    PIPELINE.recording.store(recording, Ordering::Relaxed);
}

/// Discards everything recorded since the last collection.
pub(crate) fn discard() {
    let _ = PIPELINE.reader.collect(&mut ResourceMetrics::default());
}

/// Collects everything recorded since the last collection as an encoded `ExportMetricsServiceRequest`.
///
/// Returns `None` if nothing was recorded.
pub(crate) fn collect(resource: &Resource) -> Result<Option<Bytes>> {
    let mut metrics = ResourceMetrics::default();
    PIPELINE
        .reader
        .collect(&mut metrics)
        .context("Failed to collect metrics")?;

    if metrics.scope_metrics().next().is_none() {
        return Ok(None);
    }

    let mut request = ExportMetricsServiceRequest::from(&metrics);
    for resource_metrics in &mut request.resource_metrics {
        resource_metrics.resource = Some(resource.into());
        resource_metrics.schema_url = resource.schema_url().unwrap_or_default().to_owned();
    }

    Ok(Some(Bytes::from(request.encode_to_vec())))
}

struct ExportPipeline {
    provider: SdkMeterProvider,
    reader: Arc<ManualReader>,
    recording: AtomicBool,
}

impl ExportPipeline {
    fn new() -> Self {
        let reader = Arc::new(
            ManualReader::builder()
                .with_temporality(Temporality::Delta)
                .build(),
        );
        let provider = SdkMeterProvider::builder()
            .with_reader(SharedReader(reader.clone()))
            .build();

        Self {
            provider,
            reader,
            recording: AtomicBool::new(false),
        }
    }

    fn is_recording(&self) -> bool {
        self.recording.load(Ordering::Relaxed)
    }
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

struct TeeInstrumentProvider {
    inner: Meter,
    export: Meter,
}

macro_rules! tee_instrument {
    ($method:ident, $instrument:ident<$value:ty>) => {
        fn $method(
            &self,
            builder: InstrumentBuilder<'_, $instrument<$value>>,
        ) -> $instrument<$value> {
            let build = |meter: &Meter| {
                let mut instrument = meter.$method(builder.name.clone());
                if let Some(description) = builder.description.clone() {
                    instrument = instrument.with_description(description);
                }
                if let Some(unit) = builder.unit.clone() {
                    instrument = instrument.with_unit(unit);
                }
                instrument.build()
            };

            $instrument::new(Arc::new(Tee {
                inner: build(&self.inner),
                export: build(&self.export),
            }))
        }
    };
}

macro_rules! tee_histogram {
    ($method:ident, $value:ty) => {
        fn $method(&self, builder: HistogramBuilder<'_, Histogram<$value>>) -> Histogram<$value> {
            let build = |meter: &Meter| {
                let mut histogram = meter.$method(builder.name.clone());
                if let Some(description) = builder.description.clone() {
                    histogram = histogram.with_description(description);
                }
                if let Some(unit) = builder.unit.clone() {
                    histogram = histogram.with_unit(unit);
                }
                if let Some(boundaries) = builder.boundaries.clone() {
                    histogram = histogram.with_boundaries(boundaries);
                }
                histogram.build()
            };

            Histogram::new(Arc::new(Tee {
                inner: build(&self.inner),
                export: build(&self.export),
            }))
        }
    };
}

impl InstrumentProvider for TeeInstrumentProvider {
    tee_instrument!(u64_counter, Counter<u64>);
    tee_instrument!(f64_counter, Counter<f64>);
    tee_instrument!(i64_up_down_counter, UpDownCounter<i64>);
    tee_instrument!(f64_up_down_counter, UpDownCounter<f64>);
    tee_instrument!(u64_gauge, Gauge<u64>);
    tee_instrument!(i64_gauge, Gauge<i64>);
    tee_instrument!(f64_gauge, Gauge<f64>);
    tee_histogram!(u64_histogram, u64);
    tee_histogram!(f64_histogram, f64);
}

struct Tee<I> {
    inner: I,
    export: I,
}

macro_rules! tee_measure {
    ($instrument:ident, $record:ident) => {
        impl<T> SyncInstrument<T> for Tee<$instrument<T>>
        where
            T: Copy + Send + Sync,
        {
            fn measure(&self, measurement: T, attributes: &[KeyValue]) {
                self.inner.$record(measurement, attributes);

                if PIPELINE.is_recording() {
                    self.export.$record(measurement, attributes);
                }
            }
        }
    };
}

tee_measure!(Counter, add);
tee_measure!(UpDownCounter, add);
tee_measure!(Gauge, record);
tee_measure!(Histogram, record);

#[cfg(test)]
mod tests {
    use opentelemetry_proto::tonic::metrics::v1::{metric::Data, number_data_point::Value};

    use super::*;

    #[test]
    fn records_into_the_export_pipeline_only_while_recording() {
        let counter = meter_provider(SdkMeterProvider::default())
            .meter("test")
            .u64_counter("test.counter")
            .build();

        counter.add(1, &[]);
        set_recording(true);
        counter.add(2, &[]);
        set_recording(false);
        counter.add(4, &[]);

        let request = ExportMetricsServiceRequest::decode(
            collect(&Resource::builder_empty().build())
                .unwrap()
                .unwrap(),
        )
        .unwrap();
        let metric = &request.resource_metrics[0].scope_metrics[0].metrics[0];
        let Some(Data::Sum(sum)) = &metric.data else {
            panic!("expected a sum");
        };
        assert_eq!(metric.name, "test.counter");
        assert_eq!(sum.data_points.len(), 1);
        assert_eq!(sum.data_points[0].value, Some(Value::AsInt(2)));
    }
}
