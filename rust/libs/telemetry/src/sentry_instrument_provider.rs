use std::{borrow::Cow, sync::Arc};

use opentelemetry::{
    InstrumentationScope, KeyValue, Value as OtelValue,
    metrics::{
        Counter, Gauge, Histogram, HistogramBuilder, InstrumentBuilder, InstrumentProvider, Meter,
        MeterProvider, SyncInstrument, UpDownCounter,
    },
};
use sentry::protocol::{LogAttribute, Unit};

/// A [`MeterProvider`] that intercepts every metric recording and forwards it
/// directly to Sentry, bypassing the SDK's aggregation pipeline.
///
/// This gives Sentry exact raw values instead of bucket-midpoint approximations.
/// Export is gated on the `stream_metrics` feature flag.
pub struct SentryMeterProvider;

impl MeterProvider for SentryMeterProvider {
    fn meter_with_scope(&self, _scope: InstrumentationScope) -> Meter {
        Meter::new(Arc::new(SentryInstrumentProvider))
    }
}

struct SentryInstrumentProvider;

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
        UpDownCounter::new(self.instrument(builder.name, builder.unit, SentryMetricKind::Gauge))
    }

    fn f64_up_down_counter(
        &self,
        builder: InstrumentBuilder<'_, UpDownCounter<f64>>,
    ) -> UpDownCounter<f64> {
        UpDownCounter::new(self.instrument(builder.name, builder.unit, SentryMetricKind::Gauge))
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
    Distribution,
}

struct SentryMetricInstrument {
    name: Cow<'static, str>,
    unit: Unit,
    kind: SentryMetricKind,
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
