//! In-process aggregation of the counters reported to the portal.

use std::{borrow::Cow, collections::HashMap};

use opentelemetry::KeyValue;
use parking_lot::Mutex;

/// Delta sums of the recorded counters, keyed by metric name and attributes.
///
/// The set of series is bounded by the allow-listed instruments and their
/// attribute combinations, so this map does not grow unboundedly and a failed
/// report can fold its samples back in.
#[derive(Default)]
pub struct Registry {
    series: Mutex<HashMap<SeriesKey, Delta>>,
}

impl Registry {
    pub fn record(&self, instrument: &InstrumentMeta, measurement: u64, attributes: &[KeyValue]) {
        let mut series = self.series.lock();
        let delta = series
            .entry(SeriesKey::new(instrument.name.clone(), attributes))
            .or_insert_with(|| Delta {
                description: instrument.description.clone(),
                unit: instrument.unit.clone(),
                value: 0,
            });

        delta.value = delta.value.saturating_add(measurement);
    }

    /// Returns the deltas accumulated since the last drain, resetting them.
    ///
    /// Samples are ordered by metric name and attributes, so a report is
    /// reproducible regardless of the map's iteration order.
    pub fn drain(&self) -> Vec<Sample> {
        let mut samples = self
            .series
            .lock()
            .drain()
            .filter(|(_, delta)| delta.value > 0)
            .map(|(key, delta)| Sample {
                name: key.name,
                description: delta.description,
                unit: delta.unit,
                attributes: key.attributes,
                value: delta.value,
            })
            .collect::<Vec<_>>();

        samples.sort_by(|a, b| {
            a.name
                .cmp(&b.name)
                .then_with(|| attribute_order(a).cmp(attribute_order(b)))
        });

        samples
    }

    /// Adds drained samples back, so the next drain reports them again.
    pub fn fold_back(&self, samples: Vec<Sample>) {
        let mut series = self.series.lock();

        for Sample {
            name,
            description,
            unit,
            attributes,
            value,
        } in samples
        {
            let delta = series
                .entry(SeriesKey { name, attributes })
                .or_insert_with(|| Delta {
                    description,
                    unit,
                    value: 0,
                });

            delta.value = delta.value.saturating_add(value);
        }
    }
}

/// The identity an instrument records under.
pub struct InstrumentMeta {
    pub name: Cow<'static, str>,
    pub description: Cow<'static, str>,
    pub unit: Cow<'static, str>,
}

/// One time series' delta, drained for a single report.
pub struct Sample {
    pub name: Cow<'static, str>,
    pub description: Cow<'static, str>,
    pub unit: Cow<'static, str>,
    pub attributes: Box<[KeyValue]>,
    pub value: u64,
}

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

struct Delta {
    description: Cow<'static, str>,
    unit: Cow<'static, str>,
    value: u64,
}

fn attribute_order(sample: &Sample) -> impl Iterator<Item = (&str, String)> {
    sample
        .attributes
        .iter()
        .map(|kv| (kv.key.as_str(), kv.value.to_string()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn drain_sums_per_attribute_set_and_resets() {
        let registry = Registry::default();

        registry.record(&errors(), 1, &[KeyValue::new("error.type", "spool_full")]);
        registry.record(&errors(), 2, &[KeyValue::new("error.type", "spool_full")]);
        registry.record(
            &errors(),
            5,
            &[KeyValue::new("error.type", "upload_failed")],
        );

        let samples = registry.drain();

        assert_eq!(values(&samples), [3, 5]);
        assert!(registry.drain().is_empty());
    }

    #[test]
    fn fold_back_restores_drained_samples() {
        let registry = Registry::default();
        registry.record(&errors(), 3, &[KeyValue::new("error.type", "spool_full")]);
        let samples = registry.drain();

        registry.fold_back(samples);
        registry.record(&errors(), 1, &[KeyValue::new("error.type", "spool_full")]);

        assert_eq!(values(&registry.drain()), [4]);
    }

    fn errors() -> InstrumentMeta {
        InstrumentMeta {
            name: Cow::Borrowed(otel_instruments::FLOW_LOG_ERRORS),
            description: Cow::Borrowed("Number of flow-log errors."),
            unit: Cow::Borrowed("{error}"),
        }
    }

    fn values(samples: &[Sample]) -> Vec<u64> {
        samples.iter().map(|sample| sample.value).collect()
    }
}
