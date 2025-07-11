use std::future::Future;

use opentelemetry_sdk::{
    error::OTelSdkResult,
    metrics::{Temporality, data::ResourceMetrics, exporter::PushMetricExporter},
};

pub struct NoopPushMetricsExporter;

impl PushMetricExporter for NoopPushMetricsExporter {
    fn export(&self, _: &mut ResourceMetrics) -> impl Future<Output = OTelSdkResult> + Send {
        std::future::ready(Ok(()))
    }

    fn force_flush(&self) -> OTelSdkResult {
        Ok(())
    }

    fn shutdown(&self) -> OTelSdkResult {
        Ok(())
    }

    fn temporality(&self) -> Temporality {
        Temporality::default()
    }
}
