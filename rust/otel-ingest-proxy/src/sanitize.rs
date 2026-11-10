use opentelemetry_proto::tonic::collector::metrics::v1::ExportMetricsServiceRequest;
use opentelemetry_proto::tonic::common::v1::{AnyValue, KeyValue, any_value};
use opentelemetry_proto::tonic::metrics::v1::{Metric, metric::Data};
use opentelemetry_proto::tonic::resource::v1::Resource;

use crate::auth::Claims;

/// Keeps only the metrics that `claims` allow and attributes them to the device in `claims`.
///
/// The resource is rebuilt from `claims`, keeping only `os.type` from the device. Data-point
/// attributes in the `firezone` namespace and exemplars are dropped.
///
/// Returns `None` if no metric is left.
pub fn sanitize(
    mut request: ExportMetricsServiceRequest,
    claims: &Claims,
) -> Option<ExportMetricsServiceRequest> {
    for resource_metrics in &mut request.resource_metrics {
        resource_metrics.resource = Some(resource(resource_metrics.resource.take(), claims));
        resource_metrics.schema_url.clear();

        for scope_metrics in &mut resource_metrics.scope_metrics {
            for _ in scope_metrics.metrics.extract_if(.., |metric| {
                !otel_metric_patterns::is_allowed(&metric.name, &claims.metrics)
            }) {}

            for metric in &mut scope_metrics.metrics {
                sanitize_data_points(metric);
            }
        }

        for _ in resource_metrics
            .scope_metrics
            .extract_if(.., |scope_metrics| scope_metrics.metrics.is_empty())
        {}
    }

    for _ in request.resource_metrics.extract_if(.., |resource_metrics| {
        resource_metrics.scope_metrics.is_empty()
    }) {}

    (!request.resource_metrics.is_empty()).then_some(request)
}

pub fn count_data_points(request: &ExportMetricsServiceRequest) -> u64 {
    request
        .resource_metrics
        .iter()
        .flat_map(|resource_metrics| &resource_metrics.scope_metrics)
        .flat_map(|scope_metrics| &scope_metrics.metrics)
        .filter_map(|metric| metric.data.as_ref())
        .map(|data| match data {
            Data::Gauge(gauge) => gauge.data_points.len(),
            Data::Sum(sum) => sum.data_points.len(),
            Data::Histogram(histogram) => histogram.data_points.len(),
            Data::ExponentialHistogram(histogram) => histogram.data_points.len(),
            Data::Summary(summary) => summary.data_points.len(),
        })
        .map(|len| len as u64)
        .sum()
}

fn resource(device_resource: Option<Resource>, claims: &Claims) -> Resource {
    let os_type = device_resource
        .into_iter()
        .flat_map(|resource| resource.attributes)
        .find(|attribute| attribute.key == "os.type");

    let attributes = [
        Some(string_attribute(
            "service.name",
            claims.device_type.as_str(),
        )),
        claims
            .device_version
            .as_deref()
            .map(|version| string_attribute("service.version", version)),
        os_type,
        Some(string_attribute("firezone.account.id", &claims.account_id)),
        Some(string_attribute(
            "firezone.account.slug",
            &claims.account_slug,
        )),
    ]
    .into_iter()
    .flatten()
    .collect();

    Resource {
        attributes,
        ..Default::default()
    }
}

fn sanitize_data_points(metric: &mut Metric) {
    let Some(data) = metric.data.as_mut() else {
        return;
    };

    match data {
        Data::Gauge(gauge) => {
            for point in &mut gauge.data_points {
                drop_firezone_attributes(&mut point.attributes);
                point.exemplars.clear();
            }
        }
        Data::Sum(sum) => {
            for point in &mut sum.data_points {
                drop_firezone_attributes(&mut point.attributes);
                point.exemplars.clear();
            }
        }
        Data::Histogram(histogram) => {
            for point in &mut histogram.data_points {
                drop_firezone_attributes(&mut point.attributes);
                point.exemplars.clear();
            }
        }
        Data::ExponentialHistogram(histogram) => {
            for point in &mut histogram.data_points {
                drop_firezone_attributes(&mut point.attributes);
                point.exemplars.clear();
            }
        }
        Data::Summary(summary) => {
            for point in &mut summary.data_points {
                drop_firezone_attributes(&mut point.attributes);
            }
        }
    }
}

fn drop_firezone_attributes(attributes: &mut Vec<KeyValue>) {
    for _ in attributes.extract_if(.., |attribute| {
        attribute
            .key
            .get(..8)
            .is_some_and(|prefix| prefix.eq_ignore_ascii_case("firezone"))
    }) {}
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

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::auth::DeviceType;
    use opentelemetry_proto::tonic::metrics::v1::{
        Exemplar, Gauge, NumberDataPoint, ResourceMetrics, ScopeMetrics, Sum,
    };

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
        let Some(Data::Sum(sum)) =
            &mut request.resource_metrics[0].scope_metrics[0].metrics[0].data
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

        let Some(Data::Sum(sum)) = &request.resource_metrics[0].scope_metrics[0].metrics[0].data
        else {
            panic!("Expected a sum");
        };
        assert_eq!(
            sum.data_points[0].attributes,
            vec![string_attribute("network.type", "ipv4")]
        );
        assert!(sum.data_points[0].exemplars.is_empty());
    }

    #[test]
    fn counts_data_points_of_all_metrics() {
        let mut request = request(&[&["a", "b"]]);
        request.resource_metrics[0].scope_metrics[0].metrics[1].data = Some(Data::Gauge(Gauge {
            data_points: vec![NumberDataPoint::default(); 3],
        }));

        assert_eq!(count_data_points(&request), 4);
    }

    pub(crate) fn request(scopes: &[&[&str]]) -> ExportMetricsServiceRequest {
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
            iat: 0,
            exp: 0,
        }
    }
}
