//! The [`MeterProvider`] that mirrors the allow-listed counters for the portal.

use std::sync::Arc;

use opentelemetry::{
    InstrumentationScope, KeyValue,
    metrics::{
        AsyncInstrumentBuilder, Counter, Gauge, Histogram, HistogramBuilder, InstrumentBuilder,
        InstrumentProvider, Meter, MeterProvider, ObservableCounter, ObservableGauge,
        ObservableUpDownCounter, SyncInstrument, UpDownCounter,
    },
};

use crate::{
    ALLOW_LIST,
    registry::{InstrumentMeta, Registry},
};

/// A [`MeterProvider`] that records the allow-listed counters into a [`Registry`].
///
/// Every instrument is created on the inner provider, so whichever metrics
/// pipeline is configured keeps receiving all measurements. Counters on
/// [`ALLOW_LIST`] additionally record into the registry the portal is reported
/// from.
pub struct RecordingMeterProvider {
    inner: Box<dyn MeterProvider + Send + Sync>,
    registry: Arc<Registry>,
}

impl RecordingMeterProvider {
    pub(crate) fn new(inner: Box<dyn MeterProvider + Send + Sync>, registry: Arc<Registry>) -> Self {
        Self { inner, registry }
    }
}

impl MeterProvider for RecordingMeterProvider {
    fn meter_with_scope(&self, scope: InstrumentationScope) -> Meter {
        Meter::new(Arc::new(RecordingInstrumentProvider {
            inner: self.inner.meter_with_scope(scope),
            registry: self.registry.clone(),
        }))
    }
}

struct RecordingInstrumentProvider {
    inner: Meter,
    registry: Arc<Registry>,
}

/// Rebuilds an instrument on the inner meter, carrying over its configuration.
macro_rules! delegate {
    ($method:ident, $instrument:ty) => {
        fn $method(&self, builder: InstrumentBuilder<'_, $instrument>) -> $instrument {
            let mut inner = self.inner.$method(builder.name);
            inner.description = builder.description;
            inner.unit = builder.unit;

            inner.build()
        }
    };
}

macro_rules! delegate_histogram {
    ($method:ident, $instrument:ty) => {
        fn $method(&self, builder: HistogramBuilder<'_, $instrument>) -> $instrument {
            let mut inner = self.inner.$method(builder.name);
            inner.description = builder.description;
            inner.unit = builder.unit;
            inner.boundaries = builder.boundaries;

            inner.build()
        }
    };
}

macro_rules! delegate_observable {
    ($method:ident, $instrument:ty, $measurement:ty) => {
        fn $method(
            &self,
            builder: AsyncInstrumentBuilder<'_, $instrument, $measurement>,
        ) -> $instrument {
            let mut inner = self.inner.$method(builder.name);
            inner.description = builder.description;
            inner.unit = builder.unit;
            inner.callbacks = builder.callbacks;

            inner.build()
        }
    };
}

impl InstrumentProvider for RecordingInstrumentProvider {
    fn u64_counter(&self, builder: InstrumentBuilder<'_, Counter<u64>>) -> Counter<u64> {
        let instrument = InstrumentMeta {
            name: builder.name.clone(),
            description: builder.description.clone().unwrap_or_default(),
            unit: builder.unit.clone().unwrap_or_default(),
        };

        let mut inner = self.inner.u64_counter(builder.name);
        inner.description = builder.description;
        inner.unit = builder.unit;
        let inner = inner.build();

        if !ALLOW_LIST.contains(&instrument.name.as_ref()) {
            return inner;
        }

        Counter::new(Arc::new(RecordingCounter {
            instrument,
            inner,
            registry: self.registry.clone(),
        }))
    }

    delegate!(f64_counter, Counter<f64>);
    delegate!(u64_gauge, Gauge<u64>);
    delegate!(f64_gauge, Gauge<f64>);
    delegate!(i64_gauge, Gauge<i64>);
    delegate!(i64_up_down_counter, UpDownCounter<i64>);
    delegate!(f64_up_down_counter, UpDownCounter<f64>);

    delegate_histogram!(u64_histogram, Histogram<u64>);
    delegate_histogram!(f64_histogram, Histogram<f64>);

    delegate_observable!(u64_observable_counter, ObservableCounter<u64>, u64);
    delegate_observable!(f64_observable_counter, ObservableCounter<f64>, f64);
    delegate_observable!(u64_observable_gauge, ObservableGauge<u64>, u64);
    delegate_observable!(i64_observable_gauge, ObservableGauge<i64>, i64);
    delegate_observable!(f64_observable_gauge, ObservableGauge<f64>, f64);
    delegate_observable!(
        i64_observable_up_down_counter,
        ObservableUpDownCounter<i64>,
        i64
    );
    delegate_observable!(
        f64_observable_up_down_counter,
        ObservableUpDownCounter<f64>,
        f64
    );
}

struct RecordingCounter {
    instrument: InstrumentMeta,
    inner: Counter<u64>,
    registry: Arc<Registry>,
}

impl SyncInstrument<u64> for RecordingCounter {
    fn measure(&self, measurement: u64, attributes: &[KeyValue]) {
        self.inner.add(measurement, attributes);
        self.registry
            .record(&self.instrument, measurement, attributes);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use parking_lot::Mutex;

    #[test]
    fn allow_listed_counter_records_to_registry_and_inner_provider() {
        let registry = Arc::new(Registry::default());
        let inner = FakeMeterProvider::default();
        let measurements = inner.measurements.clone();
        let provider = RecordingMeterProvider::new(Box::new(inner), registry.clone());

        provider
            .meter("test")
            .u64_counter(otel_instruments::FLOW_LOG_ERRORS)
            .build()
            .add(2, &[KeyValue::new("error.type", "spool_full")]);

        assert_eq!(
            measurements.lock().as_slice(),
            [(otel_instruments::FLOW_LOG_ERRORS.to_owned(), 2)]
        );
        let samples = registry.drain();
        assert_eq!(samples.len(), 1);
        assert_eq!(samples[0].value, 2);
    }

    #[test]
    fn other_counter_only_reaches_the_inner_provider() {
        let registry = Arc::new(Registry::default());
        let inner = FakeMeterProvider::default();
        let measurements = inner.measurements.clone();
        let provider = RecordingMeterProvider::new(Box::new(inner), registry.clone());

        provider
            .meter("test")
            .u64_counter("connlib.network.packets")
            .build()
            .add(7, &[]);

        assert_eq!(
            measurements.lock().as_slice(),
            [("connlib.network.packets".to_owned(), 7)]
        );
        assert!(registry.drain().is_empty());
    }

    type Measurements = Arc<Mutex<Vec<(String, u64)>>>;

    #[derive(Default)]
    struct FakeMeterProvider {
        measurements: Measurements,
    }

    impl MeterProvider for FakeMeterProvider {
        fn meter_with_scope(&self, _: InstrumentationScope) -> Meter {
            Meter::new(Arc::new(FakeInstrumentProvider {
                measurements: self.measurements.clone(),
            }))
        }
    }

    struct FakeInstrumentProvider {
        measurements: Measurements,
    }

    impl InstrumentProvider for FakeInstrumentProvider {
        fn u64_counter(&self, builder: InstrumentBuilder<'_, Counter<u64>>) -> Counter<u64> {
            Counter::new(Arc::new(FakeCounter {
                name: builder.name.into_owned(),
                measurements: self.measurements.clone(),
            }))
        }
    }

    struct FakeCounter {
        name: String,
        measurements: Measurements,
    }

    impl SyncInstrument<u64> for FakeCounter {
        fn measure(&self, measurement: u64, _: &[KeyValue]) {
            self.measurements
                .lock()
                .push((self.name.clone(), measurement));
        }
    }
}
