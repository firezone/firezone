//! The subset of the OTLP schema we emit, in its protobuf JSON mapping.
//!
//! The mapping encodes every 64-bit integer as a JSON string, which is why the
//! timestamps and counts below are typed as such.

use std::time::{SystemTime, UNIX_EPOCH};

use opentelemetry::{KeyValue, Value};
use serde::Serialize;

use crate::registry::Sample;

/// `AGGREGATION_TEMPORALITY_DELTA`: each report carries the counts since the previous one.
const DELTA: u8 = 1;

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ExportMetricsServiceRequest {
    resource_metrics: [ResourceMetrics; 1],
}

impl ExportMetricsServiceRequest {
    /// Encodes the samples drained for the interval between `start` and `end`.
    pub fn new(
        resource: &[KeyValue],
        samples: &[Sample],
        start: SystemTime,
        end: SystemTime,
    ) -> Self {
        let start_time_unix_nano = unix_nanos(start);
        let time_unix_nano = unix_nanos(end);

        let metrics = samples
            .chunk_by(|a, b| a.name == b.name)
            .filter_map(|series| {
                let first = series.first()?;

                Some(Metric {
                    name: first.name.to_string(),
                    description: first.description.to_string(),
                    unit: first.unit.to_string(),
                    sum: Sum {
                        data_points: series
                            .iter()
                            .map(|sample| DataPoint {
                                attributes: sample.attributes.iter().map(Attribute::from).collect(),
                                start_time_unix_nano: start_time_unix_nano.clone(),
                                time_unix_nano: time_unix_nano.clone(),
                                as_int: sample.value.to_string(),
                            })
                            .collect(),
                        aggregation_temporality: DELTA,
                        is_monotonic: true,
                    },
                })
            })
            .collect();

        Self {
            resource_metrics: [ResourceMetrics {
                resource: Resource {
                    attributes: resource.iter().map(Attribute::from).collect(),
                },
                scope_metrics: [ScopeMetrics {
                    scope: Scope {
                        name: env!("CARGO_PKG_NAME"),
                        version: env!("CARGO_PKG_VERSION"),
                    },
                    metrics,
                }],
            }],
        }
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ResourceMetrics {
    resource: Resource,
    scope_metrics: [ScopeMetrics; 1],
}

#[derive(Serialize)]
struct Resource {
    attributes: Vec<Attribute>,
}

#[derive(Serialize)]
struct ScopeMetrics {
    scope: Scope,
    metrics: Vec<Metric>,
}

#[derive(Serialize)]
struct Scope {
    name: &'static str,
    version: &'static str,
}

#[derive(Serialize)]
struct Metric {
    name: String,
    description: String,
    unit: String,
    sum: Sum,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Sum {
    data_points: Vec<DataPoint>,
    aggregation_temporality: u8,
    is_monotonic: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct DataPoint {
    attributes: Vec<Attribute>,
    start_time_unix_nano: String,
    time_unix_nano: String,
    as_int: String,
}

#[derive(Serialize)]
struct Attribute {
    key: String,
    value: AnyValue,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
enum AnyValue {
    StringValue(String),
    IntValue(String),
    BoolValue(bool),
    DoubleValue(f64),
}

impl From<&KeyValue> for Attribute {
    fn from(attribute: &KeyValue) -> Self {
        let value = match &attribute.value {
            Value::Bool(bool) => AnyValue::BoolValue(*bool),
            Value::I64(int) => AnyValue::IntValue(int.to_string()),
            Value::F64(double) => AnyValue::DoubleValue(*double),
            Value::String(string) => AnyValue::StringValue(string.as_str().to_owned()),
            Value::Array(_) | _ => AnyValue::StringValue(attribute.value.to_string()),
        };

        Self {
            key: attribute.key.as_str().to_owned(),
            value,
        }
    }
}

fn unix_nanos(time: SystemTime) -> String {
    time.duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos()
        .to_string()
}

#[cfg(test)]
mod tests {
    use std::{borrow::Cow, time::Duration};

    use super::*;

    #[test]
    fn a_single_counter_serialises_to_otlp_json() {
        let samples = [Sample {
            name: Cow::Borrowed("flow_logs.errors"),
            description: Cow::Borrowed("Number of flow-log errors."),
            unit: Cow::Borrowed("{error}"),
            attributes: Box::new([KeyValue::new("error.type", "spool_full")]),
            value: 3,
        }];

        let request = ExportMetricsServiceRequest::new(
            &[KeyValue::new("service.name", "firezone-gateway")],
            &samples,
            UNIX_EPOCH + Duration::from_secs(1),
            UNIX_EPOCH + Duration::from_secs(2),
        );

        assert_eq!(
            serde_json::to_value(&request).unwrap(),
            serde_json::json!({
                "resourceMetrics": [{
                    "resource": {
                        "attributes": [{
                            "key": "service.name",
                            "value": { "stringValue": "firezone-gateway" }
                        }]
                    },
                    "scopeMetrics": [{
                        "scope": {
                            "name": "portal-metrics",
                            "version": env!("CARGO_PKG_VERSION")
                        },
                        "metrics": [{
                            "name": "flow_logs.errors",
                            "description": "Number of flow-log errors.",
                            "unit": "{error}",
                            "sum": {
                                "dataPoints": [{
                                    "attributes": [{
                                        "key": "error.type",
                                        "value": { "stringValue": "spool_full" }
                                    }],
                                    "startTimeUnixNano": "1000000000",
                                    "timeUnixNano": "2000000000",
                                    "asInt": "3"
                                }],
                                "aggregationTemporality": 1,
                                "isMonotonic": true
                            }
                        }]
                    }]
                }]
            })
        );
    }
}
