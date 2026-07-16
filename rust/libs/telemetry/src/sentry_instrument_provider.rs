use std::{
    borrow::Cow,
    collections::HashMap,
    sync::{Arc, Weak},
    time::Duration,
};

use opentelemetry::{
    InstrumentationScope, KeyValue, Value as OtelValue,
    metrics::{
        Counter, Gauge, Histogram, HistogramBuilder, InstrumentBuilder, InstrumentProvider, Meter,
        MeterProvider, SyncInstrument, UpDownCounter,
    },
};
use parking_lot::Mutex;
use rand::RngExt;
use sentry::protocol::{LogAttribute, Unit};

/// How often the aggregated metrics are flushed to Sentry.
const FLUSH_INTERVAL: Duration = Duration::from_secs(60);

/// A [`MeterProvider`] that aggregates metrics locally and periodically flushes
/// them to Sentry.
///
/// Counters and gauges are aggregated exactly. Distributions keep a fair random
/// sample (plus the observed maximum) of their raw values, so Sentry can still
/// compute meaningful percentiles without us shipping every measurement.
///
/// Ideally this would be an OpenTelemetry `PushMetricExporter` fed by the SDK's
/// aggregation pipeline, reading raw distribution samples from histogram
/// exemplars. Exemplar collection is unimplemented upstream, so we intercept at
/// the instrument level and keep our own reservoir and flush thread instead.
/// See <https://github.com/open-telemetry/opentelemetry-rust/issues/3369> and the
/// migration tracking issue <https://github.com/firezone/firezone/issues/13713>.
///
/// Recording is gated on the `stream_metrics` feature flag.
pub struct SentryMeterProvider {
    registry: Arc<Registry>,
}

impl Default for SentryMeterProvider {
    fn default() -> Self {
        Self::new()
    }
}

impl SentryMeterProvider {
    pub fn new() -> Self {
        let registry = Arc::new(Registry::default());
        spawn_flush_thread(Arc::downgrade(&registry));

        Self { registry }
    }
}

impl MeterProvider for SentryMeterProvider {
    fn meter_with_scope(&self, _scope: InstrumentationScope) -> Meter {
        Meter::new(Arc::new(SentryInstrumentProvider {
            registry: self.registry.clone(),
        }))
    }
}

struct SentryInstrumentProvider {
    registry: Arc<Registry>,
}

impl SentryInstrumentProvider {
    fn instrument(
        &self,
        name: Cow<'static, str>,
        unit: Option<Cow<'static, str>>,
        kind: MetricKind,
    ) -> Arc<SentryMetricInstrument> {
        Arc::new(SentryMetricInstrument {
            name,
            unit: Unit::from(unit.unwrap_or(Cow::Borrowed(""))),
            kind,
            registry: self.registry.clone(),
        })
    }
}

impl InstrumentProvider for SentryInstrumentProvider {
    fn u64_counter(&self, builder: InstrumentBuilder<'_, Counter<u64>>) -> Counter<u64> {
        Counter::new(self.instrument(builder.name, builder.unit, MetricKind::Counter))
    }

    fn f64_counter(&self, builder: InstrumentBuilder<'_, Counter<f64>>) -> Counter<f64> {
        Counter::new(self.instrument(builder.name, builder.unit, MetricKind::Counter))
    }

    fn u64_gauge(&self, builder: InstrumentBuilder<'_, Gauge<u64>>) -> Gauge<u64> {
        Gauge::new(self.instrument(builder.name, builder.unit, MetricKind::Gauge))
    }

    fn f64_gauge(&self, builder: InstrumentBuilder<'_, Gauge<f64>>) -> Gauge<f64> {
        Gauge::new(self.instrument(builder.name, builder.unit, MetricKind::Gauge))
    }

    fn i64_gauge(&self, builder: InstrumentBuilder<'_, Gauge<i64>>) -> Gauge<i64> {
        Gauge::new(self.instrument(builder.name, builder.unit, MetricKind::Gauge))
    }

    fn i64_up_down_counter(
        &self,
        builder: InstrumentBuilder<'_, UpDownCounter<i64>>,
    ) -> UpDownCounter<i64> {
        UpDownCounter::new(self.instrument(builder.name, builder.unit, MetricKind::UpDownCounter))
    }

    fn f64_up_down_counter(
        &self,
        builder: InstrumentBuilder<'_, UpDownCounter<f64>>,
    ) -> UpDownCounter<f64> {
        UpDownCounter::new(self.instrument(builder.name, builder.unit, MetricKind::UpDownCounter))
    }

    fn f64_histogram(&self, builder: HistogramBuilder<'_, Histogram<f64>>) -> Histogram<f64> {
        Histogram::new(self.instrument(builder.name, builder.unit, MetricKind::Distribution))
    }

    fn u64_histogram(&self, builder: HistogramBuilder<'_, Histogram<u64>>) -> Histogram<u64> {
        Histogram::new(self.instrument(builder.name, builder.unit, MetricKind::Distribution))
    }
}

#[derive(Clone, Copy)]
enum MetricKind {
    Counter,
    Gauge,
    UpDownCounter,
    Distribution,
}

struct SentryMetricInstrument {
    name: Cow<'static, str>,
    unit: Unit,
    kind: MetricKind,
    registry: Arc<Registry>,
}

impl<T: ToF64> SyncInstrument<T> for SentryMetricInstrument {
    fn measure(&self, measurement: T, attrs: &[KeyValue]) {
        if !crate::feature_flags::stream_metrics() {
            return;
        }

        let key = SeriesKey::new(self.name.clone(), attrs);

        self.registry
            .lock()
            .entry(key)
            .or_insert_with(|| Series::new(self.unit.clone(), self.kind))
            .record(measurement.to_f64());
    }
}

/// In-memory aggregation state, keyed by metric name and attributes.
///
/// The set of series is bounded by the instruments defined in the binary and
/// their attribute combinations, so this map does not grow unboundedly.
type Registry = Mutex<HashMap<SeriesKey, Series>>;

/// Identifies a single time series by metric name and attributes.
#[derive(PartialEq, Eq, Hash)]
struct SeriesKey {
    name: Cow<'static, str>,
    attributes: Box<[KeyValue]>,
}

impl SeriesKey {
    fn new(name: Cow<'static, str>, attrs: &[KeyValue]) -> Self {
        let mut attributes = attrs.to_vec();
        // Sort so the same attribute set always maps to one series, regardless of
        // the order in which the call site happened to list the attributes.
        attributes.sort_by(|a, b| a.key.as_str().cmp(b.key.as_str()));

        Self {
            name,
            attributes: attributes.into_boxed_slice(),
        }
    }
}

struct Series {
    unit: Unit,
    data: SeriesData,
}

enum SeriesData {
    /// Monotonic counter: accumulates the per-interval delta, reset on flush.
    Counter { delta: f64 },
    /// Gauge: most recent value, emitted only in intervals where it was recorded.
    Gauge { value: f64, recorded: bool },
    /// Up/down counter: running total, emitted as a gauge only when it changed in the interval.
    UpDown { total: f64, recorded: bool },
    /// Distribution: a fair random sample of the raw values plus the observed maximum.
    Distribution { reservoir: Reservoir, max: f64 },
}

impl Series {
    fn new(unit: Unit, kind: MetricKind) -> Self {
        let data = match kind {
            MetricKind::Counter => SeriesData::Counter { delta: 0.0 },
            MetricKind::Gauge => SeriesData::Gauge {
                value: 0.0,
                recorded: false,
            },
            MetricKind::UpDownCounter => SeriesData::UpDown {
                total: 0.0,
                recorded: false,
            },
            MetricKind::Distribution => SeriesData::Distribution {
                reservoir: Reservoir::new(crate::feature_flags::metrics_reservoir_size()),
                max: f64::NEG_INFINITY,
            },
        };

        Self { unit, data }
    }

    fn record(&mut self, value: f64) {
        match &mut self.data {
            SeriesData::Counter { delta } => *delta += value,
            SeriesData::Gauge {
                value: latest,
                recorded,
            } => {
                *latest = value;
                *recorded = true;
            }
            SeriesData::UpDown { total, recorded } => {
                *total += value;
                *recorded = true;
            }
            SeriesData::Distribution { reservoir, max } => {
                reservoir.observe(value);
                *max = max.max(value);
            }
        }
    }
}

/// A bounded uniform random sample of a stream of values (Vitter's Algorithm R).
///
/// Every observed value is equally likely to be retained, so percentiles computed
/// over the sample are unbiased estimates of the full population's percentiles.
struct Reservoir {
    samples: Vec<f64>,
    capacity: usize,
    seen: u64,
}

impl Reservoir {
    fn new(capacity: usize) -> Self {
        Self {
            samples: Vec::with_capacity(capacity),
            capacity,
            seen: 0,
        }
    }

    fn observe(&mut self, value: f64) {
        self.seen += 1;

        if self.samples.len() < self.capacity {
            self.samples.push(value);
            return;
        }

        // Replace a uniformly chosen sample with probability `capacity / seen`,
        // which keeps every observed value equally likely to be retained.
        let index = rand::rng().random_range(0..self.seen);
        if let Some(slot) = self.samples.get_mut(index as usize) {
            *slot = value;
        }
    }

    /// Returns the retained samples and resets the reservoir for the next interval.
    fn take(&mut self) -> Vec<f64> {
        self.seen = 0;

        std::mem::replace(&mut self.samples, Vec::with_capacity(self.capacity))
    }

    /// Re-arms the reservoir with `capacity` for the next interval, so a runtime
    /// change to the configured size takes effect.
    fn set_capacity(&mut self, capacity: usize) {
        self.capacity = capacity;
    }
}

fn spawn_flush_thread(registry: Weak<Registry>) {
    let result = std::thread::Builder::new()
        .name("sentry-metrics-flush".to_owned())
        .spawn(move || {
            loop {
                std::thread::sleep(FLUSH_INTERVAL);

                let Some(registry) = registry.upgrade() else {
                    return; // The provider has been dropped; nothing left to flush.
                };

                let pending = drain(&registry);

                // Drain every interval to reset per-interval state, but only send
                // while streaming is enabled so disabling the flag stops emission.
                if !crate::feature_flags::stream_metrics() {
                    continue;
                }

                tracing::debug!(count = pending.len(), "Flushing metrics to Sentry");

                for metric in pending {
                    metric.capture();
                }
            }
        });

    if let Err(e) = result {
        tracing::warn!("Failed to spawn Sentry metrics flush thread: {e}");
    }
}

/// Snapshots the registry into a list of metrics to send, resetting per-interval
/// state. Sentry is not touched while the lock is held.
///
/// Series are drained and re-inserted rather than iterated in place, because the
/// codebase forbids non-deterministic `HashMap` iteration. Re-inserting preserves
/// the running state of gauges and up/down counters across intervals.
fn drain(registry: &Registry) -> Vec<Emit> {
    let mut registry = registry.lock();
    let mut pending = Vec::new();
    let mut retained = Vec::new();

    for (key, mut series) in registry.drain() {
        match &mut series.data {
            SeriesData::Counter { delta } => {
                if *delta != 0.0 {
                    pending.push(Emit {
                        kind: MetricKind::Counter,
                        name: key.name.clone(),
                        unit: series.unit.clone(),
                        attributes: key.attributes.clone(),
                        value: *delta,
                    });
                    *delta = 0.0;
                }
            }
            SeriesData::Gauge { value, recorded } => {
                if *recorded {
                    pending.push(Emit {
                        kind: MetricKind::Gauge,
                        name: key.name.clone(),
                        unit: series.unit.clone(),
                        attributes: key.attributes.clone(),
                        value: *value,
                    });
                    *recorded = false;
                }
            }
            SeriesData::UpDown { total, recorded } => {
                if *recorded {
                    pending.push(Emit {
                        kind: MetricKind::UpDownCounter,
                        name: key.name.clone(),
                        unit: series.unit.clone(),
                        attributes: key.attributes.clone(),
                        value: *total,
                    });
                    *recorded = false;
                }
            }
            SeriesData::Distribution { reservoir, max } => {
                let samples = reservoir.take();
                reservoir.set_capacity(crate::feature_flags::metrics_reservoir_size());
                // Append the observed maximum so sampling never drops the worst case,
                // unless it was already retained (which would double-count it).
                let observed_max = std::mem::replace(max, f64::NEG_INFINITY);
                let extra_max = (observed_max.is_finite() && !samples.contains(&observed_max))
                    .then_some(observed_max);

                pending.extend(samples.into_iter().chain(extra_max).map(|value| Emit {
                    kind: MetricKind::Distribution,
                    name: key.name.clone(),
                    unit: series.unit.clone(),
                    attributes: key.attributes.clone(),
                    value,
                }));
            }
        }

        retained.push((key, series));
    }

    registry.extend(retained);

    pending
}

/// A single data point captured to Sentry once the registry lock is released.
struct Emit {
    kind: MetricKind,
    name: Cow<'static, str>,
    unit: Unit,
    attributes: Box<[KeyValue]>,
    value: f64,
}

impl Emit {
    fn capture(self) {
        let Self {
            kind,
            name,
            unit,
            attributes,
            value,
        } = self;

        // `counter`, `gauge` and `distribution` are distinct builder types with no
        // shared trait, so a local macro applies the attributes and sends each.
        macro_rules! send {
            ($builder:expr) => {{
                let mut metric = $builder;
                for kv in attributes.iter() {
                    metric = metric.attribute(kv.key.as_str().to_owned(), to_log_attr(&kv.value));
                }
                metric.capture();
            }};
        }

        match kind {
            MetricKind::Counter => send!(sentry::metrics::counter(name, value)),
            MetricKind::Gauge | MetricKind::UpDownCounter => {
                send!(sentry::metrics::gauge(name, value).unit(unit))
            }
            MetricKind::Distribution => {
                send!(sentry::metrics::distribution(name, value).unit(unit))
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn counter_accumulates_delta_and_resets_on_drain() {
        let registry = Registry::default();
        let key = SeriesKey::new(Cow::Borrowed("requests"), &[]);

        record(&registry, &key, MetricKind::Counter, &[1.0, 1.0, 1.0]);

        assert_eq!(counter_values(drain(&registry)), vec![3.0]);
        // A second drain without new measurements emits nothing.
        assert!(drain(&registry).is_empty());
    }

    #[test]
    fn gauge_reports_last_value_only_when_recorded() {
        let registry = Registry::default();
        let key = SeriesKey::new(Cow::Borrowed("queue.length"), &[]);

        record(&registry, &key, MetricKind::Gauge, &[5.0, 2.0]);

        assert_eq!(gauge_values(drain(&registry)), vec![2.0]);
        // An idle interval emits nothing rather than replaying the stale value.
        assert!(gauge_values(drain(&registry)).is_empty());
    }

    #[test]
    fn up_down_counter_reports_running_total() {
        let registry = Registry::default();
        let key = SeriesKey::new(Cow::Borrowed("buffers"), &[]);

        record(
            &registry,
            &key,
            MetricKind::UpDownCounter,
            &[1.0, 1.0, -1.0],
        );

        assert_eq!(gauge_values(drain(&registry)), vec![1.0]);
    }

    #[test]
    fn distribution_below_capacity_keeps_every_value() {
        let mut reservoir = Reservoir::new(4);

        for value in [10.0, 30.0, 20.0] {
            reservoir.observe(value);
        }

        let mut samples = reservoir.take();
        samples.sort_by(|a, b| a.total_cmp(b));

        assert_eq!(samples, vec![10.0, 20.0, 30.0]);
    }

    #[test]
    fn distribution_caps_at_capacity_and_resets() {
        let mut reservoir = Reservoir::new(8);

        for value in 0..1_000 {
            reservoir.observe(value as f64);
        }

        let samples = reservoir.take();
        assert_eq!(samples.len(), 8);
        assert!(samples.iter().all(|s| (0.0..1_000.0).contains(s)));

        // Taking resets the reservoir.
        assert!(reservoir.take().is_empty());
    }

    #[test]
    fn distribution_keeps_each_value_once_when_all_are_retained() {
        let registry = Registry::default();
        let key = SeriesKey::new(Cow::Borrowed("dns.lookup.duration"), &[]);

        record(&registry, &key, MetricKind::Distribution, &[1.0, 9.0, 3.0]);

        let mut values = distribution_values(drain(&registry));
        values.sort_by(|a, b| a.total_cmp(b));

        // The max (9.0) is already in the sample, so it must not be appended again.
        assert_eq!(values, vec![1.0, 3.0, 9.0]);
    }

    fn record(registry: &Registry, key: &SeriesKey, kind: MetricKind, values: &[f64]) {
        for value in values {
            registry
                .lock()
                .entry(SeriesKey::new(key.name.clone(), &key.attributes))
                .or_insert_with(|| Series::new(Unit::from(Cow::Borrowed("")), kind))
                .record(*value);
        }
    }

    fn counter_values(pending: Vec<Emit>) -> Vec<f64> {
        values_of(pending, |kind| matches!(kind, MetricKind::Counter))
    }

    fn gauge_values(pending: Vec<Emit>) -> Vec<f64> {
        values_of(pending, |kind| {
            matches!(kind, MetricKind::Gauge | MetricKind::UpDownCounter)
        })
    }

    fn distribution_values(pending: Vec<Emit>) -> Vec<f64> {
        values_of(pending, |kind| matches!(kind, MetricKind::Distribution))
    }

    fn values_of(pending: Vec<Emit>, want: impl Fn(MetricKind) -> bool) -> Vec<f64> {
        pending
            .into_iter()
            .filter(|e| want(e.kind))
            .map(|e| e.value)
            .collect()
    }
}
