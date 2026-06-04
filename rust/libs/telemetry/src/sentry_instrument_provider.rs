use std::{borrow::Cow, collections::HashMap, sync::Arc};

use opentelemetry::{
    InstrumentationScope, KeyValue, Value as OtelValue,
    metrics::{
        Counter, Gauge, Histogram, HistogramBuilder, InstrumentBuilder, InstrumentProvider, Meter,
        MeterProvider, SyncInstrument, UpDownCounter,
    },
};
use parking_lot::Mutex;
use sentry::protocol::{LogAttribute, Unit};

/// A [`MeterProvider`] that intercepts every metric recording and forwards it
/// directly to Sentry, bypassing the SDK's aggregation pipeline.
///
/// This gives Sentry exact raw values instead of bucket-midpoint approximations.
/// Export is gated on the `stream_metrics` feature flag.
#[derive(Default)]
pub struct SentryMeterProvider {
    up_down_totals: Arc<Mutex<HashMap<UpDownKey, f64>>>,
}

impl MeterProvider for SentryMeterProvider {
    fn meter_with_scope(&self, _scope: InstrumentationScope) -> Meter {
        Meter::new(Arc::new(SentryInstrumentProvider {
            up_down_totals: self.up_down_totals.clone(),
        }))
    }
}

struct SentryInstrumentProvider {
    up_down_totals: Arc<Mutex<HashMap<UpDownKey, f64>>>,
}

impl SentryInstrumentProvider {
    fn instrument(
        &self,
        name: Cow<'static, str>,
        unit: Option<Cow<'static, str>>,
        kind: SentryMetricKind,
    ) -> Arc<SentryMetricInstrument> {
        Arc::new(SentryMetricInstrument {
            name,
            unit: Unit::from(unit.unwrap_or(Cow::Borrowed(""))),
            kind,
            up_down_totals: self.up_down_totals.clone(),
        })
    }
}

impl InstrumentProvider for SentryInstrumentProvider {
    fn u64_counter(&self, builder: InstrumentBuilder<'_, Counter<u64>>) -> Counter<u64> {
        Counter::new(self.instrument(builder.name, builder.unit, SentryMetricKind::Counter))
    }

    fn f64_counter(&self, builder: InstrumentBuilder<'_, Counter<f64>>) -> Counter<f64> {
        Counter::new(self.instrument(builder.name, builder.unit, SentryMetricKind::Counter))
    }

    fn u64_gauge(&self, builder: InstrumentBuilder<'_, Gauge<u64>>) -> Gauge<u64> {
        Gauge::new(self.instrument(builder.name, builder.unit, SentryMetricKind::Gauge))
    }

    fn f64_gauge(&self, builder: InstrumentBuilder<'_, Gauge<f64>>) -> Gauge<f64> {
        Gauge::new(self.instrument(builder.name, builder.unit, SentryMetricKind::Gauge))
    }

    fn i64_gauge(&self, builder: InstrumentBuilder<'_, Gauge<i64>>) -> Gauge<i64> {
        Gauge::new(self.instrument(builder.name, builder.unit, SentryMetricKind::Gauge))
    }

    fn i64_up_down_counter(
        &self,
        builder: InstrumentBuilder<'_, UpDownCounter<i64>>,
    ) -> UpDownCounter<i64> {
        UpDownCounter::new(self.instrument(
            builder.name,
            builder.unit,
            SentryMetricKind::UpDownCounter,
        ))
    }

    fn f64_up_down_counter(
        &self,
        builder: InstrumentBuilder<'_, UpDownCounter<f64>>,
    ) -> UpDownCounter<f64> {
        UpDownCounter::new(self.instrument(
            builder.name,
            builder.unit,
            SentryMetricKind::UpDownCounter,
        ))
    }

    fn f64_histogram(&self, builder: HistogramBuilder<'_, Histogram<f64>>) -> Histogram<f64> {
        Histogram::new(self.instrument(builder.name, builder.unit, SentryMetricKind::Distribution))
    }

    fn u64_histogram(&self, builder: HistogramBuilder<'_, Histogram<u64>>) -> Histogram<u64> {
        Histogram::new(self.instrument(builder.name, builder.unit, SentryMetricKind::Distribution))
    }
}

#[derive(Clone, Copy)]
enum SentryMetricKind {
    Counter,
    Gauge,
    UpDownCounter,
    Distribution,
}

struct SentryMetricInstrument {
    name: Cow<'static, str>,
    unit: Unit,
    kind: SentryMetricKind,
    up_down_totals: Arc<Mutex<HashMap<UpDownKey, f64>>>,
}

impl<T: ToF64> SyncInstrument<T> for SentryMetricInstrument {
    fn measure(&self, measurement: T, attrs: &[KeyValue]) {
        if !crate::feature_flags::stream_metrics() {
            return;
        }

        let value = measurement.to_f64();

        match self.kind {
            SentryMetricKind::Counter => {
                let mut metric = sentry::metrics::counter(self.name.clone(), value);
                for kv in attrs {
                    metric = metric.attribute(kv.key.as_str().to_owned(), to_log_attr(&kv.value));
                }
                metric.capture();
            }
            SentryMetricKind::Gauge => {
                let mut metric =
                    sentry::metrics::gauge(self.name.clone(), value).unit(self.unit.clone());
                for kv in attrs {
                    metric = metric.attribute(kv.key.as_str().to_owned(), to_log_attr(&kv.value));
                }
                metric.capture();
            }
            SentryMetricKind::UpDownCounter => {
                // `add()` reports a delta; accumulate it into the running total so the
                // Sentry gauge reflects the current count rather than the ±1 change.
                let total = accumulate(&self.up_down_totals, self.name.clone(), attrs, value);

                let mut metric =
                    sentry::metrics::gauge(self.name.clone(), total).unit(self.unit.clone());
                for kv in attrs {
                    metric = metric.attribute(kv.key.as_str().to_owned(), to_log_attr(&kv.value));
                }
                metric.capture();
            }
            SentryMetricKind::Distribution => {
                let mut metric =
                    sentry::metrics::distribution(self.name.clone(), value).unit(self.unit.clone());
                for kv in attrs {
                    metric = metric.attribute(kv.key.as_str().to_owned(), to_log_attr(&kv.value));
                }
                metric.capture();
            }
        }
    }
}

/// Identifies an up-down counter time series by metric name and attributes, so
/// we can keep a running total per series.
#[derive(PartialEq, Eq, Hash)]
struct UpDownKey {
    name: Cow<'static, str>,
    attributes: Box<[KeyValue]>,
}

/// Adds `delta` to the running total of the up-down counter series identified by
/// `name` + `attrs` and returns the new total.
///
/// The set of series is bounded by the metrics defined in the binary, so this
/// map does not grow unboundedly.
fn accumulate(
    totals: &Mutex<HashMap<UpDownKey, f64>>,
    name: Cow<'static, str>,
    attrs: &[KeyValue],
    delta: f64,
) -> f64 {
    let key = UpDownKey {
        name,
        attributes: Box::from(attrs),
    };

    let mut totals = totals.lock();
    let total = totals.entry(key).or_insert(0.0);
    *total += delta;

    *total
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

trait ToF64: Copy {
    fn to_f64(self) -> f64;
}

impl ToF64 for f64 {
    fn to_f64(self) -> f64 {
        self
    }
}

impl ToF64 for u64 {
    fn to_f64(self) -> f64 {
        self as f64
    }
}

impl ToF64 for i64 {
    fn to_f64(self) -> f64 {
        self as f64
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn up_down_counter_accumulates_running_total_per_series() {
        let totals = Mutex::new(HashMap::new());
        let name = Cow::Borrowed("system.buffer.count");
        let pool_a = [KeyValue::new("system.buffer.pool.name", "a")];
        let pool_b = [KeyValue::new("system.buffer.pool.name", "b")];

        assert_eq!(accumulate(&totals, name.clone(), &pool_a, 1.0), 1.0);
        assert_eq!(accumulate(&totals, name.clone(), &pool_a, 1.0), 2.0);
        assert_eq!(accumulate(&totals, name.clone(), &pool_a, -1.0), 1.0);

        // A different attribute set is tracked independently.
        assert_eq!(accumulate(&totals, name.clone(), &pool_b, 1.0), 1.0);

        assert_eq!(accumulate(&totals, name.clone(), &pool_a, -1.0), 0.0);
    }
}
