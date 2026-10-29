use anyhow::{Context as _, Result};
use opentelemetry_otlp::WithExportConfig as _;
use opentelemetry_sdk::metrics::{MeterProviderBuilder, Temporality};

pub fn with_exporter(
    builder: MeterProviderBuilder,
    endpoint: &str,
) -> Result<MeterProviderBuilder> {
    // Delta histograms keep Azure Monitor's min/max and averages scoped to each export window.
    let exporter = opentelemetry_otlp::MetricExporter::builder()
        .with_tonic()
        .with_endpoint(endpoint)
        .with_temporality(Temporality::LowMemory)
        .build()
        .context("Failed to build OTLP metric exporter")?;
    let builder = builder.with_periodic_exporter(exporter);

    Ok(builder)
}
