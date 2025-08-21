use std::future::Future;

use futures::future::Either;
use opentelemetry_sdk::{
    error::OTelSdkResult,
    metrics::{Temporality, data::ResourceMetrics, exporter::PushMetricExporter},
};

pub struct MaybePushMetricsExporter<E, F> {
    pub inner: E,
    pub should_export: F,
}

impl<E, F> PushMetricExporter for MaybePushMetricsExporter<E, F>
where
    E: PushMetricExporter,
    F: Fn() -> bool + Send + Sync + 'static,
{
    fn export(&self, metrics: &ResourceMetrics) -> impl Future<Output = OTelSdkResult> + Send {
        if (self.should_export)() {
            return Either::Left(self.inner.export(metrics));
        }

        Either::Right(std::future::ready(Ok(())))
    }

    fn force_flush(&self) -> OTelSdkResult {
        self.inner.force_flush()
    }

    fn shutdown(&self) -> OTelSdkResult {
        self.inner.shutdown()
    }

    fn temporality(&self) -> Temporality {
        self.inner.temporality()
    }

    fn shutdown_with_timeout(&self, timeout: std::time::Duration) -> OTelSdkResult {
        self.inner.shutdown_with_timeout(timeout)
    }
}
