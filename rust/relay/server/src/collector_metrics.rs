use anyhow::{Context as _, Result};
use opentelemetry_otlp::WithExportConfig as _;
use opentelemetry_sdk::metrics::{MeterProviderBuilder, Temporality};

pub fn with_exporter(
    builder: MeterProviderBuilder,
    endpoint: &str,
) -> Result<MeterProviderBuilder> {
    // `LowMemory` ships observable counters as cumulative, but synchronous monotonic
    // counters and histograms as delta. Without delta, Azure Monitor pins Min/Max to
    // lifetime extremes after the first outlier and per-window averages can only be
    // reconstructed via fragile prev()-based KQL.
    let exporter = opentelemetry_otlp::MetricExporter::builder()
        .with_tonic()
        .with_endpoint(endpoint)
        .with_temporality(Temporality::LowMemory)
        .build()
        .context("Failed to build OTLP metric exporter")?;
    let builder = builder.with_periodic_exporter(exporter);

    tracing::trace!(target: "relay", "Successfully initialized collector metrics exporter");

    Ok(builder)
}
