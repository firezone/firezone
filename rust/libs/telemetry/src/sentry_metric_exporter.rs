use std::{
    collections::HashMap,
    future::Future,
    sync::Mutex,
    time::Duration,
};

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
use smallvec::SmallVec;

/// Derived metric names for a histogram, cached to avoid repeated `format!` calls.
struct HistogramNames {
    count: Box<str>,
    sum: Box<str>,
    min: Box<str>,
    max: Box<str>,
}

impl HistogramNames {
    fn new(base: &str) -> Self {
        Self {
            count: format!("{base}.count").into_boxed_str(),
            sum: format!("{base}.sum").into_boxed_str(),
            min: format!("{base}.min").into_boxed_str(),
            max: format!("{base}.max").into_boxed_str(),
        }
    }
}

/// A [`PushMetricExporter`] that re-emits OpenTelemetry metrics as Sentry metrics
/// via the currently-initialised Sentry client on the main hub.
///
/// Histograms are emitted as:
/// - `<name>.count`, `<name>.sum`, `<name>.min`, `<name>.max` (summary)
/// - `<name>` distribution with one sample per observation at the bucket midpoint,
///   allowing Sentry to compute percentiles. The overflow bucket uses `last_bound * 1.5`
///   as a heuristic upper bound.
#[derive(Default)]
pub struct SentryMetricExporter {
    histogram_names: Mutex<HashMap<Box<str>, HistogramNames>>,
}

impl PushMetricExporter for SentryMetricExporter {
    fn export(&self, metrics: &ResourceMetrics) -> impl Future<Output = OTelSdkResult> + Send {
        let mut cache = self.histogram_names.lock().unwrap();
        for scope in metrics.scope_metrics() {
            for metric in scope.metrics() {
                emit_metric(metric, &mut cache);
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

fn emit_metric(metric: &Metric, cache: &mut HashMap<Box<str>, HistogramNames>) {
    let name = metric.name();
    let unit = metric.unit();

    match metric.data() {
        AggregatedMetrics::F64(d) => emit_data(name, unit, d, |v| v, cache),
        AggregatedMetrics::U64(d) => emit_data(name, unit, d, |v| v as f64, cache),
        AggregatedMetrics::I64(d) => emit_data(name, unit, d, |v| v as f64, cache),
    }
}

fn emit_data<T: Copy>(
    name: &str,
    unit: &str,
    data: &MetricData<T>,
    to_f64: impl Fn(T) -> f64,
    cache: &mut HashMap<Box<str>, HistogramNames>,
) {
    match data {
        MetricData::Gauge(g) => {
            for dp in g.data_points() {
                let attrs = to_sentry_attrs(dp.attributes());
                emit_gauge(name, unit, to_f64(dp.value()), &attrs);
            }
        }
        MetricData::Sum(s) => {
            let monotonic = s.is_monotonic();
            for dp in s.data_points() {
                let attrs = to_sentry_attrs(dp.attributes());
                if monotonic {
                    emit_counter(name, to_f64(dp.value()), &attrs);
                } else {
                    emit_gauge(name, unit, to_f64(dp.value()), &attrs);
                }
            }
        }
        MetricData::Histogram(h) => {
            let names = get_histogram_names(cache, name);
            for dp in h.data_points() {
                let attrs = to_sentry_attrs(dp.attributes());
                emit_histogram(name, unit, dp, &to_f64, &attrs, names);
            }
        }
        MetricData::ExponentialHistogram(h) => {
            let names = get_histogram_names(cache, name);
            for dp in h.data_points() {
                let attrs = to_sentry_attrs(dp.attributes());
                emit_exp_histogram(unit, dp, &to_f64, &attrs, names);
            }
        }
    }
}

fn get_histogram_names<'a>(
    cache: &'a mut HashMap<Box<str>, HistogramNames>,
    name: &str,
) -> &'a HistogramNames {
    if !cache.contains_key(name) {
        cache.insert(Box::from(name), HistogramNames::new(name));
    }
    cache.get(name).unwrap()
}

type SentryAttrs = SmallVec<[(String, LogAttribute); 8]>;

fn to_sentry_attrs<'a>(iter: impl Iterator<Item = &'a KeyValue>) -> SentryAttrs {
    iter.map(|kv| (kv.key.as_str().to_owned(), to_log_attr(&kv.value)))
        .collect()
}

fn emit_counter(name: &str, value: f64, attrs: &SentryAttrs) {
    let mut metric = sentry::metrics::counter(name.to_owned(), value);
    for (k, v) in attrs {
        metric = metric.attribute(k.clone(), v.clone());
    }
    metric.capture();
}

fn emit_gauge(name: &str, unit: &str, value: f64, attrs: &SentryAttrs) {
    let mut metric = sentry::metrics::gauge(name.to_owned(), value);
    if !unit.is_empty() {
        metric = metric.unit(unit.to_owned());
    }
    for (k, v) in attrs {
        metric = metric.attribute(k.clone(), v.clone());
    }
    metric.capture();
}

fn emit_distribution(name: &str, unit: &str, value: f64, attrs: &SentryAttrs) {
    let mut metric = sentry::metrics::distribution(name.to_owned(), value);
    if !unit.is_empty() {
        metric = metric.unit(unit.to_owned());
    }
    for (k, v) in attrs {
        metric = metric.attribute(k.clone(), v.clone());
    }
    metric.capture();
}

fn emit_histogram<T: Copy>(
    name: &str,
    unit: &str,
    dp: &HistogramDataPoint<T>,
    to_f64: &impl Fn(T) -> f64,
    attrs: &SentryAttrs,
    names: &HistogramNames,
) {
    emit_counter(&names.count, dp.count() as f64, attrs);
    emit_distribution(&names.sum, unit, to_f64(dp.sum()), attrs);
    if let Some(min) = dp.min() {
        emit_gauge(&names.min, unit, to_f64(min), attrs);
    }
    if let Some(max) = dp.max() {
        emit_gauge(&names.max, unit, to_f64(max), attrs);
    }

    let bounds: SmallVec<[f64; 16]> = dp.bounds().collect();
    if bounds.is_empty() {
        return;
    }

    for (i, count) in dp.bucket_counts().enumerate() {
        if count == 0 {
            continue;
        }
        let midpoint = match i {
            0 => bounds[0] / 2.0,
            i if i < bounds.len() => (bounds[i - 1] + bounds[i]) / 2.0,
            _ => bounds[bounds.len() - 1] * 1.5,
        };
        for _ in 0..count {
            emit_distribution(name, unit, midpoint, attrs);
        }
    }
}

fn emit_exp_histogram<T: Copy>(
    unit: &str,
    dp: &ExponentialHistogramDataPoint<T>,
    to_f64: &impl Fn(T) -> f64,
    attrs: &SentryAttrs,
    names: &HistogramNames,
) {
    emit_counter(&names.count, dp.count() as f64, attrs);
    emit_distribution(&names.sum, unit, to_f64(dp.sum()), attrs);
    if let Some(min) = dp.min() {
        emit_gauge(&names.min, unit, to_f64(min), attrs);
    }
    if let Some(max) = dp.max() {
        emit_gauge(&names.max, unit, to_f64(max), attrs);
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
