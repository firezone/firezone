#![allow(clippy::unwrap_used)]

use firezone_otel_ingest_proxy::{Claims, DeviceType, sanitize};
use opentelemetry_proto::tonic::collector::metrics::v1::ExportMetricsServiceRequest;
use opentelemetry_proto::tonic::common::v1::{AnyValue, KeyValue, any_value};
use opentelemetry_proto::tonic::metrics::v1::{
    Exemplar, Metric, NumberDataPoint, ResourceMetrics, ScopeMetrics, Sum, metric::Data,
};
use opentelemetry_proto::tonic::resource::v1::Resource;

#[test]
fn keeps_only_allowed_metrics_and_drops_empty_scopes() {
    let request = request(&[&["connlib.a", "tunnel.b"], &["tunnel.c"]]);

    let request = sanitize(request, &claims(&["connlib.*"])).unwrap();

    let scopes = &request.resource_metrics[0].scope_metrics;
    assert_eq!(scopes.len(), 1);
    assert_eq!(scopes[0].metrics.len(), 1);
    assert_eq!(scopes[0].metrics[0].name, "connlib.a");
}

#[test]
fn returns_none_if_nothing_is_allowed() {
    let request = request(&[&["connlib.a"]]);

    assert!(sanitize(request.clone(), &claims(&["tunnel.*"])).is_none());
    assert!(sanitize(request, &claims(&[])).is_none());
}

#[test]
fn rebuilds_resource_from_claims() {
    let mut request = request(&[&["connlib.a"]]);
    request.resource_metrics[0].resource = Some(Resource {
        attributes: vec![
            string_attribute("service.name", "spoofed"),
            string_attribute("service.version", "9.9.9"),
            string_attribute("os.type", "linux"),
            string_attribute("firezone.account.id", "spoofed"),
            string_attribute("host.name", "laptop"),
        ],
        dropped_attributes_count: 3,
        ..Default::default()
    });

    let request = sanitize(request, &claims(&["*"])).unwrap();

    assert_eq!(
        request.resource_metrics[0].resource,
        Some(Resource {
            attributes: vec![
                string_attribute("service.name", "client"),
                string_attribute("service.version", "1.5.0"),
                string_attribute("os.type", "linux"),
                string_attribute("firezone.account.id", "account"),
                string_attribute("firezone.account.slug", "slug"),
            ],
            ..Default::default()
        })
    );
}

#[test]
fn drops_firezone_data_point_attributes_and_exemplars() {
    let mut request = request(&[&["connlib.a"]]);
    let Some(Data::Sum(sum)) = &mut request.resource_metrics[0].scope_metrics[0].metrics[0].data
    else {
        panic!("Expected a sum");
    };
    sum.data_points[0].attributes = vec![
        string_attribute("network.type", "ipv4"),
        string_attribute("firezone.account.id", "spoofed"),
        string_attribute("FireZone.device", "spoofed"),
    ];
    sum.data_points[0].exemplars = vec![Exemplar::default()];

    let request = sanitize(request, &claims(&["*"])).unwrap();

    let Some(Data::Sum(sum)) = &request.resource_metrics[0].scope_metrics[0].metrics[0].data else {
        panic!("Expected a sum");
    };
    assert_eq!(
        sum.data_points[0].attributes,
        vec![string_attribute("network.type", "ipv4")]
    );
    assert!(sum.data_points[0].exemplars.is_empty());
}

fn request(scopes: &[&[&str]]) -> ExportMetricsServiceRequest {
    ExportMetricsServiceRequest {
        resource_metrics: vec![ResourceMetrics {
            scope_metrics: scopes
                .iter()
                .map(|names| ScopeMetrics {
                    metrics: names
                        .iter()
                        .map(|name| Metric {
                            name: name.to_string(),
                            data: Some(Data::Sum(Sum {
                                data_points: vec![NumberDataPoint::default()],
                                ..Default::default()
                            })),
                            ..Default::default()
                        })
                        .collect(),
                    ..Default::default()
                })
                .collect(),
            ..Default::default()
        }],
    }
}

fn claims(metrics: &[&str]) -> Claims {
    Claims {
        account_id: "account".to_owned(),
        account_slug: "slug".to_owned(),
        device_id: "device".to_owned(),
        device_type: DeviceType::Client,
        device_version: Some("1.5.0".to_owned()),
        metrics: metrics.iter().map(|m| m.to_string()).collect(),
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
