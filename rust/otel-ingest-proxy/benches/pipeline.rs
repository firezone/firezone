//! Micro-benchmarks for decoding, sanitizing and encoding the OTLP metrics a device exports.

use axum::body::Bytes;
use firezone_otel_ingest_proxy::{Claims, DeviceType, sanitize};
use opentelemetry_proto::tonic::collector::metrics::v1::ExportMetricsServiceRequest;
use opentelemetry_proto::tonic::common::v1::{AnyValue, InstrumentationScope, KeyValue, any_value};
use opentelemetry_proto::tonic::metrics::v1::{
    ExponentialHistogram, ExponentialHistogramDataPoint, Gauge, Histogram, HistogramDataPoint,
    Metric, NumberDataPoint, ResourceMetrics, ScopeMetrics, Sum, exponential_histogram_data_point,
    metric::Data, number_data_point,
};
use opentelemetry_proto::tonic::resource::v1::Resource;
use prost::Message as _;

#[global_allocator]
static ALLOC: divan::AllocProfiler = divan::AllocProfiler::system();

fn main() {
    divan::main()
}

/// Decodes a request with the given number of metrics.
#[divan::bench(args = [8, 32, 64])]
fn decode_request(bencher: divan::Bencher, metrics: usize) {
    let body = Bytes::from(request(metrics).encode_to_vec());

    bencher.bench(|| ExportMetricsServiceRequest::decode(divan::black_box(body.clone())));
}

/// Sanitizes a request with the given number of metrics, of which the token allows half.
#[divan::bench(args = [8, 32, 64])]
fn sanitize_request(bencher: divan::Bencher, metrics: usize) {
    let request = request(metrics);
    let claims = claims();

    bencher
        .with_inputs(|| request.clone())
        .bench_values(|request| sanitize(request, divan::black_box(&claims)));
}

/// Encodes the sanitized request with the given number of metrics.
#[divan::bench(args = [8, 32, 64])]
fn encode_request(bencher: divan::Bencher, metrics: usize) {
    let request = sanitize(request(metrics), &claims()).expect("token allows half the metrics");

    bencher.bench(|| divan::black_box(&request).encode_to_vec());
}

fn request(metrics: usize) -> ExportMetricsServiceRequest {
    ExportMetricsServiceRequest {
        resource_metrics: vec![ResourceMetrics {
            resource: Some(Resource {
                attributes: vec![
                    string_attribute("service.name", "connlib"),
                    string_attribute("service.version", "1.5.0"),
                    string_attribute("os.type", "linux"),
                    string_attribute("host.name", "laptop"),
                    string_attribute("firezone.account.id", "spoofed"),
                ],
                ..Default::default()
            }),
            scope_metrics: vec![ScopeMetrics {
                scope: Some(InstrumentationScope {
                    name: "connlib".to_owned(),
                    ..Default::default()
                }),
                metrics: (0..metrics).map(metric).collect(),
                ..Default::default()
            }],
            ..Default::default()
        }],
    }
}

/// Returns an allowed metric for even and a disallowed one for odd `i`, cycling through all data types.
fn metric(i: usize) -> Metric {
    let prefix = if i.is_multiple_of(2) {
        "connlib"
    } else {
        "tunnel"
    };

    let data = match i / 2 % 4 {
        0 => Data::Sum(Sum {
            data_points: number_data_points(),
            aggregation_temporality: 1,
            is_monotonic: true,
        }),
        1 => Data::Gauge(Gauge {
            data_points: number_data_points(),
        }),
        2 => Data::Histogram(Histogram {
            data_points: (0..4)
                .map(|_| HistogramDataPoint {
                    attributes: data_point_attributes(),
                    count: 100,
                    sum: Some(1234.5),
                    bucket_counts: vec![10; 16],
                    explicit_bounds: (0..15).map(f64::from).collect(),
                    ..Default::default()
                })
                .collect(),
            aggregation_temporality: 1,
        }),
        _ => Data::ExponentialHistogram(ExponentialHistogram {
            data_points: (0..4)
                .map(|_| ExponentialHistogramDataPoint {
                    attributes: data_point_attributes(),
                    count: 100,
                    sum: Some(1234.5),
                    scale: 20,
                    positive: Some(exponential_histogram_data_point::Buckets {
                        offset: 0,
                        bucket_counts: vec![1; 160],
                    }),
                    ..Default::default()
                })
                .collect(),
            aggregation_temporality: 1,
        }),
    };

    Metric {
        name: format!("{prefix}.metric_{i}"),
        description: "A metric".to_owned(),
        unit: "s".to_owned(),
        data: Some(data),
        ..Default::default()
    }
}

fn number_data_points() -> Vec<NumberDataPoint> {
    (0..4)
        .map(|i| NumberDataPoint {
            attributes: data_point_attributes(),
            value: Some(number_data_point::Value::AsInt(i)),
            ..Default::default()
        })
        .collect()
}

fn data_point_attributes() -> Vec<KeyValue> {
    vec![
        string_attribute("network.type", "ipv4"),
        string_attribute("network.transport", "udp"),
        string_attribute("firezone.device", "spoofed"),
    ]
}

fn claims() -> Claims {
    Claims {
        account_id: "00000000-0000-0000-0000-000000000001".to_owned(),
        account_slug: "slug".to_owned(),
        device_id: "00000000-0000-0000-0000-000000000002".to_owned(),
        device_type: DeviceType::Client,
        device_version: Some("1.5.0".to_owned()),
        label_devices: false,
        actor_id: None,
        metrics: vec!["connlib.*".to_owned()],
        exp: 0,
    }
}

fn string_attribute(key: &str, value: &str) -> KeyValue {
    KeyValue {
        key: key.to_owned(),
        value: Some(AnyValue {
            value: Some(any_value::Value::StringValue(value.to_owned())),
        }),
        ..Default::default()
    }
}
