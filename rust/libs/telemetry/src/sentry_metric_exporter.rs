use std::{future::Future, time::Duration};

use opentelemetry::{KeyValue, Value as OtelValue};
use opentelemetry_sdk::{
    error::OTelSdkResult,
    metrics::{
        Temporality,
        data::{
            AggregatedMetrics, ExponentialHistogramDataPoint, HistogramDataPoint, Metric,
            MetricData, ResourceMetrics,
        },
        exporter::PushMetricExporter,
    },
};
use sentry::protocol::LogAttribute;

/// A [`PushMetricExporter`] that re-emits OpenTelemetry metrics as Sentry metrics
/// via the currently-initialised Sentry client on the main hub.
///
/// Histograms are summarised as `<name>.count`, `<name>.sum` and (when present)
/// `<name>.min` / `<name>.max`, since the Sentry metric protocol can only carry
/// a single value per metric.
pub struct SentryMetricExporter;

impl PushMetricExporter for SentryMetricExporter {
    fn export(&self, metrics: &ResourceMetrics) -> impl Future<Output = OTelSdkResult> + Send {
        // Snapshot the feature flags once per export and attach them to every metric.
        let flags = crate::feature_flags::metric_attributes();

        for scope in metrics.scope_metrics() {
            for metric in scope.metrics() {
                emit_metric(metric, &flags);
            }
        }

        std::future::ready(Ok(()))
    }

    fn force_flush(&self) -> OTelSdkResult {
        Ok(())
    }

    fn shutdown_with_timeout(&self, _: Duration) -> OTelSdkResult {
        Ok(())
    }

    fn temporality(&self) -> Temporality {
        // Each export gives us the change since the previous export, which maps
        // cleanly onto Sentry's increment-only counters.
        Temporality::Delta
    }
}

fn emit_metric(metric: &Metric, flags: &[KeyValue]) {
    let name = metric.name();
    let unit = metric.unit();

    match metric.data() {
        AggregatedMetrics::F64(d) => emit_data(name, unit, d, |v| v, flags),
        AggregatedMetrics::U64(d) => emit_data(name, unit, d, |v| v as f64, flags),
        AggregatedMetrics::I64(d) => emit_data(name, unit, d, |v| v as f64, flags),
    }
}

fn emit_data<T: Copy>(
    name: &str,
    unit: &str,
    data: &MetricData<T>,
    to_f64: impl Fn(T) -> f64,
    flags: &[KeyValue],
) {
    match data {
        MetricData::Gauge(g) => {
            for dp in g.data_points() {
                emit_gauge(name, unit, to_f64(dp.value()), dp.attributes(), flags);
            }
        }
        MetricData::Sum(s) => {
            let monotonic = s.is_monotonic();

            for dp in s.data_points() {
                if monotonic {
                    emit_counter(name, to_f64(dp.value()), dp.attributes(), flags);
                } else {
                    emit_gauge(name, unit, to_f64(dp.value()), dp.attributes(), flags);
                }
            }
        }
        MetricData::Histogram(h) => {
            for dp in h.data_points() {
                emit_histogram(name, unit, dp, &to_f64, flags);
            }
        }
        MetricData::ExponentialHistogram(h) => {
            for dp in h.data_points() {
                emit_exp_histogram(name, unit, dp, &to_f64, flags);
            }
        }
    }
}

fn emit_counter<'a>(
    name: &str,
    value: f64,
    attrs: impl Iterator<Item = &'a KeyValue>,
    flags: &'a [KeyValue],
) {
    let mut metric = sentry::metrics::counter(name.to_owned(), value);
    for attr in attrs.chain(flags) {
        metric = metric.attribute(String::from(attr.key.clone()), to_log_attr(&attr.value));
    }
    metric.capture();
}

fn emit_gauge<'a>(
    name: &str,
    unit: &str,
    value: f64,
    attrs: impl Iterator<Item = &'a KeyValue>,
    flags: &'a [KeyValue],
) {
    let mut metric = sentry::metrics::gauge(name.to_owned(), value);
    if !unit.is_empty() {
        metric = metric.unit(unit.to_owned());
    }
    for attr in attrs.chain(flags) {
        metric = metric.attribute(String::from(attr.key.clone()), to_log_attr(&attr.value));
    }
    metric.capture();
}

fn emit_distribution<'a>(
    name: &str,
    unit: &str,
    value: f64,
    attrs: impl Iterator<Item = &'a KeyValue>,
    flags: &'a [KeyValue],
) {
    let mut metric = sentry::metrics::distribution(name.to_owned(), value);
    if !unit.is_empty() {
        metric = metric.unit(unit.to_owned());
    }
    for attr in attrs.chain(flags) {
        metric = metric.attribute(String::from(attr.key.clone()), to_log_attr(&attr.value));
    }
    metric.capture();
}

fn emit_histogram<T: Copy>(
    name: &str,
    unit: &str,
    dp: &HistogramDataPoint<T>,
    to_f64: &impl Fn(T) -> f64,
    flags: &[KeyValue],
) {
    emit_counter(
        &format!("{name}.count"),
        dp.count() as f64,
        dp.attributes(),
        flags,
    );
    emit_distribution(
        &format!("{name}.sum"),
        unit,
        to_f64(dp.sum()),
        dp.attributes(),
        flags,
    );

    if let Some(min) = dp.min() {
        emit_gauge(
            &format!("{name}.min"),
            unit,
            to_f64(min),
            dp.attributes(),
            flags,
        );
    }
    if let Some(max) = dp.max() {
        emit_gauge(
            &format!("{name}.max"),
            unit,
            to_f64(max),
            dp.attributes(),
            flags,
        );
    }
}

fn emit_exp_histogram<T: Copy>(
    name: &str,
    unit: &str,
    dp: &ExponentialHistogramDataPoint<T>,
    to_f64: &impl Fn(T) -> f64,
    flags: &[KeyValue],
) {
    emit_counter(
        &format!("{name}.count"),
        dp.count() as f64,
        dp.attributes(),
        flags,
    );
    emit_distribution(
        &format!("{name}.sum"),
        unit,
        to_f64(dp.sum()),
        dp.attributes(),
        flags,
    );

    if let Some(min) = dp.min() {
        emit_gauge(
            &format!("{name}.min"),
            unit,
            to_f64(min),
            dp.attributes(),
            flags,
        );
    }
    if let Some(max) = dp.max() {
        emit_gauge(
            &format!("{name}.max"),
            unit,
            to_f64(max),
            dp.attributes(),
            flags,
        );
    }
}

fn to_log_attr(value: &OtelValue) -> LogAttribute {
    match value {
        OtelValue::Bool(b) => LogAttribute::from(*b),
        OtelValue::I64(i) => LogAttribute::from(*i),
        OtelValue::F64(f) => LogAttribute::from(*f),
        OtelValue::String(s) => LogAttribute::from(s.as_str().to_owned()),
        OtelValue::Array(_) | _ => LogAttribute::from(value.to_string()),
    }
}
