use anyhow::{Context as _, Result};
use opentelemetry_otlp::{Protocol, WithExportConfig as _};
use opentelemetry_sdk::metrics::{
    Aggregation, Instrument, InstrumentKind, MeterProviderBuilder, Stream, Temporality,
};
use url::Url;

#[derive(clap::ValueEnum, Debug, Clone, Copy, PartialEq, Eq)]
pub enum OtlpAuth {
    AzureManagedIdentity,
}

pub fn with_exporter(
    builder: MeterProviderBuilder,
    endpoint: &Url,
    auth: Option<OtlpAuth>,
) -> Result<MeterProviderBuilder> {
    match auth {
        Some(OtlpAuth::AzureManagedIdentity) => otel_azure_export::with_exporter(builder, endpoint),
        None => {
            let exporter = opentelemetry_otlp::MetricExporter::builder()
                .with_http()
                .with_endpoint(endpoint.as_str())
                .with_protocol(Protocol::HttpBinary)
                .with_temporality(Temporality::Delta)
                .build()
                .context("Failed to build OTLP metrics exporter")?;

            Ok(builder
                .with_periodic_exporter(exporter)
                .with_view(exponential_histograms))
        }
    }
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
