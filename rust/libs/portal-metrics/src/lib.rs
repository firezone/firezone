//! Reports the OpenTelemetry counters the portal asks for to the portal.
//!
//! [`spawn`] returns a [`Reader`] to install on the process' meter provider and
//! a thread that collects from it on the portal's cadence, POSTing the deltas of
//! the [`Config::reported_metrics`] as OTLP/HTTP with JSON encoding.
//!
//! The portal's config arrives long after start-up and only ever lives in
//! memory. Until it does, nothing is collected, so the SDK keeps accumulating
//! and counts recorded before the first [`Reporter::configure`] are still
//! reported afterwards.

#![cfg_attr(test, allow(clippy::unwrap_used))]

use std::{
    collections::BTreeSet,
    pin::pin,
    sync::{Arc, Weak},
    time::Duration,
};

use anyhow::{Context as _, Result};
use bytes::Bytes;
use futures::future;
use opentelemetry_proto::tonic::{
    collector::metrics::v1::ExportMetricsServiceRequest, metrics::v1::ResourceMetrics,
};
use opentelemetry_sdk::{
    error::OTelSdkResult,
    metrics::{InstrumentKind, ManualReader, Pipeline, Temporality, data, reader::MetricReader},
};
use parking_lot::Mutex;
use secrecy::SecretString;
use socket_factory::{SocketFactory, TcpSocket};
use tokio::sync::Notify;
use url::Url;

mod ingest;

/// How often to re-check for a config while reporting is unconfigured.
const DISABLED_POLL: Duration = Duration::from_secs(60);

/// How many undelivered collections to carry into the next report.
const MAX_RETAINED: usize = 6;

/// Spawns the thread reporting to the portal what is collected from the returned
/// [`Reader`].
///
/// Installing the reader on the process' meter provider is up to the caller.
pub fn spawn(socket_factory: Arc<dyn SocketFactory<TcpSocket>>) -> (Reader, Reporter) {
    let reader = Reader::default();
    let reporter = Reporter {
        endpoint: Arc::new(Mutex::new(None)),
        wakeups: Arc::new(Notify::new()),
    };

    std::thread::Builder::new()
        .name("portal-metrics".to_owned())
        .spawn({
            let reporter = reporter.clone();
            let reader = reader.clone();

            move || {
                let runtime = match tokio::runtime::Builder::new_current_thread()
                    .enable_all()
                    .build()
                {
                    Ok(runtime) => runtime,
                    Err(e) => {
                        tracing::error!("Failed to build portal metrics runtime: {e:#}");

                        return;
                    }
                };

                runtime.block_on(run(&reporter, &reader, &socket_factory));
            }
        })
        .expect("Failed to spawn portal metrics thread");

    (reader, reporter)
}

/// What, where, and how often, to report metrics to the portal.
#[derive(Clone)]
pub struct Config {
    /// Base URL metrics are POSTed to.
    pub api_url: Url,
    /// Authorizes the reports; sent as-is in the `Authorization` header.
    pub token: SecretString,
    /// How often to report.
    pub interval: Duration,
    /// Names of the metrics that may be reported.
    pub reported_metrics: BTreeSet<String>,
}

/// Handle to the spawned reporter thread.
///
/// Dropping it detaches the thread; it keeps running until the process exits, so
/// counts keep accumulating across portal reconnects.
#[derive(Clone)]
pub struct Reporter {
    endpoint: Arc<Mutex<Option<Config>>>,
    wakeups: Arc<Notify>,
}

impl Reporter {
    /// Starts or re-seeds reporting with the portal's config.
    ///
    /// Takes effect immediately rather than after the current interval elapses.
    /// Already accumulated counts are kept.
    ///
    /// # Errors
    ///
    /// Errs if `config` does not describe an endpoint we can report to.
    pub fn configure(&self, config: &Config) -> Result<()> {
        anyhow::ensure!(
            !config.interval.is_zero(),
            "Metrics report interval must not be zero"
        );
        anyhow::ensure!(
            !config.reported_metrics.is_empty(),
            "Metrics report must cover at least one metric"
        );

        *self.endpoint.lock() = Some(config.clone());
        self.wakeups.notify_one();

        Ok(())
    }

    /// Stops reporting until the next [`Reporter::configure`].
    pub fn disable(&self) {
        *self.endpoint.lock() = None;
    }
}

/// The [`MetricReader`] the portal is reported from.
///
/// Collecting yields the counts since the previous collection, which is what a
/// report carries.
#[derive(Clone, Debug)]
pub struct Reader(Arc<ManualReader>);

impl Default for Reader {
    fn default() -> Self {
        Self(Arc::new(
            ManualReader::builder()
                .with_temporality(Temporality::Delta)
                .build(),
        ))
    }
}

impl MetricReader for Reader {
    fn register_pipeline(&self, pipeline: Weak<Pipeline>) {
        self.0.register_pipeline(pipeline);
    }

    fn collect(&self, rm: &mut data::ResourceMetrics) -> OTelSdkResult {
        self.0.collect(rm)
    }

    fn force_flush(&self) -> OTelSdkResult {
        self.0.force_flush()
    }

    fn shutdown_with_timeout(&self, timeout: Duration) -> OTelSdkResult {
        self.0.shutdown_with_timeout(timeout)
    }

    fn temporality(&self, kind: InstrumentKind) -> Temporality {
        self.0.temporality(kind)
    }
}

/// The reporter's event loop: waits for the next report to fall due or for a
/// new config to arrive, whichever comes first.
async fn run(
    reporter: &Reporter,
    reader: &Reader,
    socket_factory: &Arc<dyn SocketFactory<TcpSocket>>,
) {
    tracing::info!("Portal metrics reporter started");

    let mut retained = Vec::new();
    let mut delay = DISABLED_POLL;

    loop {
        let configured = pin!(reporter.wakeups.notified());
        let due = pin!(tokio::time::sleep(delay));

        future::select(configured, due).await;

        delay = report_pass(reporter, reader, socket_factory, &mut retained).await;
    }
}

/// Runs one report pass; returns how long to wait before the next.
///
/// Nothing is collected until there is somewhere to report to, and a pass that
/// fails to deliver retains its collection for the next one to send along.
async fn report_pass(
    reporter: &Reporter,
    reader: &Reader,
    socket_factory: &Arc<dyn SocketFactory<TcpSocket>>,
    retained: &mut Vec<ResourceMetrics>,
) -> Duration {
    let Some(endpoint) = reporter.endpoint.lock().clone() else {
        return DISABLED_POLL;
    };

    let mut request = match export_request(reader, &endpoint.reported_metrics) {
        Ok(request) => request,
        Err(e) => {
            tracing::warn!("Failed to collect metrics: {e:#}");

            return endpoint.interval;
        }
    };

    request.resource_metrics.splice(..0, retained.drain(..));

    if request.resource_metrics.is_empty() {
        return endpoint.interval;
    }

    match report(&endpoint, &request, socket_factory.clone()).await {
        Ok(()) => {}
        Err(e) => {
            tracing::warn!("Failed to report metrics to portal: {e:#}");

            *retained = request.resource_metrics;
            let excess = retained.len().saturating_sub(MAX_RETAINED);

            if excess > 0 {
                tracing::debug!(%excess, "Dropping undelivered metrics");
                retained.drain(..excess);
            }
        }
    }

    endpoint.interval
}

async fn report(
    endpoint: &Config,
    request: &ExportMetricsServiceRequest,
    socket_factory: Arc<dyn SocketFactory<TcpSocket>>,
) -> Result<()> {
    let body = serde_json::to_vec(request).context("Failed to serialize metrics report")?;

    ingest::report(
        &endpoint.api_url,
        &endpoint.token,
        Bytes::from(body),
        socket_factory,
    )
    .await?;

    tracing::debug!(
        collections = request.resource_metrics.len(),
        "Reported metrics to portal"
    );

    Ok(())
}

/// Collects the deltas since the previous pass as an OTLP request of the
/// `reported_metrics`, stripped of the resource describing us.
///
/// Collecting drains the SDK's deltas, so with nothing to report we must not
/// collect at all: the counts would be discarded rather than carried into the
/// next pass.
fn export_request(
    reader: &Reader,
    reported_metrics: &BTreeSet<String>,
) -> Result<ExportMetricsServiceRequest> {
    if reported_metrics.is_empty() {
        return Ok(ExportMetricsServiceRequest::default());
    }

    let mut collected = data::ResourceMetrics::default();
    reader
        .collect(&mut collected)
        .context("Failed to collect metrics")?;

    let mut request = ExportMetricsServiceRequest::from(&collected);

    for resource_metrics in &mut request.resource_metrics {
        // The portal identifies the reporting gateway from the token the report is
        // authorized with, so the payload must not repeat it.
        resource_metrics.resource = None;

        for scope_metrics in &mut resource_metrics.scope_metrics {
            scope_metrics
                .metrics
                .retain(|metric| reported_metrics.contains(&metric.name));
        }

        resource_metrics
            .scope_metrics
            .retain(|scope_metrics| !scope_metrics.metrics.is_empty());
    }

    request
        .resource_metrics
        .retain(|resource_metrics| !resource_metrics.scope_metrics.is_empty());

    Ok(request)
}

#[cfg(test)]
mod tests {
    use opentelemetry::{KeyValue, metrics::MeterProvider as _};
    use opentelemetry_proto::tonic::metrics::v1::metric::Data;
    use opentelemetry_sdk::{Resource, metrics::SdkMeterProvider};
    use serde_json::json;

    use super::*;

    #[test]
    fn exports_the_reported_counters_as_otlp_json() {
        let reader = Reader::default();
        let provider = meter_provider(&reader);
        let meter = provider.meter("connlib");

        meter
            .u64_counter(otel_instruments::FLOW_LOG_REPORT_ERRORS)
            .with_description("Number of failures to spool a flow-log report.")
            .with_unit("{error}")
            .build()
            .add(
                3,
                &[KeyValue::new(
                    "error.type",
                    "io::ErrorKind::PermissionDenied",
                )],
            );
        meter
            .u64_counter("connlib.network.packets")
            .build()
            .add(7, &[]);

        let mut request = export_request(
            &reader,
            &reported_metrics(&[otel_instruments::FLOW_LOG_REPORT_ERRORS]),
        )
        .unwrap();
        fix_timestamps(&mut request);

        assert_eq!(
            serde_json::to_value(&request).unwrap(),
            json!({
                "resourceMetrics": [{
                    "resource": null,
                    "scopeMetrics": [{
                        "scope": {
                            "name": "connlib",
                            "version": "",
                            "attributes": [],
                            "droppedAttributesCount": 0
                        },
                        "metrics": [{
                            "name": "flow_logs.report.errors",
                            "description": "Number of failures to spool a flow-log report.",
                            "unit": "{error}",
                            "metadata": [],
                            "sum": {
                                "dataPoints": [{
                                    "attributes": [{
                                        "key": "error.type",
                                        "value": { "stringValue": "io::ErrorKind::PermissionDenied" }
                                    }],
                                    "startTimeUnixNano": "1000000000",
                                    "timeUnixNano": "2000000000",
                                    "exemplars": [],
                                    "flags": 0,
                                    "asInt": 3
                                }],
                                "aggregationTemporality": 1,
                                "isMonotonic": true
                            }
                        }],
                        "schemaUrl": ""
                    }],
                    "schemaUrl": ""
                }]
            })
        );
    }

    #[test]
    fn a_collection_reports_only_what_was_recorded_since_the_previous_one() {
        let reader = Reader::default();
        let provider = meter_provider(&reader);
        let counter = provider
            .meter("connlib")
            .u64_counter(otel_instruments::FLOW_LOG_REPORT_ERRORS)
            .build();

        let reported = reported_metrics(&[otel_instruments::FLOW_LOG_REPORT_ERRORS]);

        counter.add(3, &[]);
        export_request(&reader, &reported).unwrap();
        counter.add(1, &[]);

        let request = serde_json::to_value(export_request(&reader, &reported).unwrap()).unwrap();

        assert_eq!(
            request
                .pointer("/resourceMetrics/0/scopeMetrics/0/metrics/0/sum/dataPoints/0/asInt")
                .unwrap(),
            1
        );
    }

    #[test]
    fn an_empty_report_does_not_drain_the_recorded_counts() {
        let reader = Reader::default();
        let provider = meter_provider(&reader);
        let counter = provider
            .meter("connlib")
            .u64_counter(otel_instruments::FLOW_LOG_REPORT_ERRORS)
            .build();
        let reported = reported_metrics(&[otel_instruments::FLOW_LOG_REPORT_ERRORS]);

        counter.add(3, &[]);
        export_request(&reader, &BTreeSet::default()).unwrap();

        let request = serde_json::to_value(export_request(&reader, &reported).unwrap()).unwrap();

        assert_eq!(
            request
                .pointer("/resourceMetrics/0/scopeMetrics/0/metrics/0/sum/dataPoints/0/asInt")
                .unwrap(),
            3
        );
    }

    #[test]
    fn a_config_that_can_never_report_is_rejected() {
        let (_reader, reporter) = (Reader::default(), test_reporter());

        reporter
            .configure(&test_config(Duration::from_secs(60), &[]))
            .unwrap_err();
        reporter
            .configure(&test_config(
                Duration::ZERO,
                &[otel_instruments::FLOW_LOG_REPORT_ERRORS],
            ))
            .unwrap_err();
    }

    fn test_reporter() -> Reporter {
        Reporter {
            endpoint: Arc::new(Mutex::new(None)),
            wakeups: Arc::new(Notify::new()),
        }
    }

    fn test_config(interval: Duration, reported: &[&str]) -> Config {
        Config {
            api_url: "https://metrics.firezone.dev/".parse().unwrap(),
            token: SecretString::from("token"),
            interval,
            reported_metrics: reported_metrics(reported),
        }
    }

    fn reported_metrics(names: &[&str]) -> BTreeSet<String> {
        names.iter().map(|name| (*name).to_owned()).collect()
    }

    fn meter_provider(reader: &Reader) -> SdkMeterProvider {
        SdkMeterProvider::builder()
            .with_reader(reader.clone())
            .with_resource(
                Resource::builder_empty()
                    .with_attribute(KeyValue::new("service.name", "firezone-gateway"))
                    .build(),
            )
            .build()
    }

    fn fix_timestamps(request: &mut ExportMetricsServiceRequest) {
        for resource_metrics in &mut request.resource_metrics {
            for scope_metrics in &mut resource_metrics.scope_metrics {
                for metric in &mut scope_metrics.metrics {
                    let Some(Data::Sum(sum)) = metric.data.as_mut() else {
                        continue;
                    };

                    for data_point in &mut sum.data_points {
                        data_point.start_time_unix_nano = 1_000_000_000;
                        data_point.time_unix_nano = 2_000_000_000;
                    }
                }
            }
        }
    }
}
