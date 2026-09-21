//! Reports an allow-listed set of OpenTelemetry counters to the portal.
//!
//! Which metrics pipeline a binary runs is a deployment choice, so reporting to
//! the portal cannot be another exporter on it. [`RecordingMeterProvider`]
//! decorates whichever [`MeterProvider`] is installed and mirrors the counters on
//! [`ALLOW_LIST`] into an in-process registry instead.
//!
//! [`spawn`] runs a thread that drains that registry on the portal's cadence and
//! POSTs the deltas as OTLP/HTTP with JSON encoding. The portal's config arrives
//! long after start-up, in its `init` message, and only ever lives in memory; the
//! registry accumulates until then, so counts recorded before the first
//! [`Reporter::configure`] are still reported afterwards.

#![cfg_attr(test, allow(clippy::unwrap_used))]

use std::{
    sync::{Arc, mpsc},
    time::{Duration, SystemTime},
};

use anyhow::{Context as _, Result};
use bytes::Bytes;
use opentelemetry::{KeyValue, metrics::MeterProvider};
use parking_lot::Mutex;
use secrecy::SecretString;
use socket_factory::{SocketFactory, TcpSocket};
use url::Url;

mod ingest;
mod otlp;
mod provider;
mod registry;

pub use provider::RecordingMeterProvider;

use otlp::ExportMetricsServiceRequest;
use registry::{Registry, Sample};

/// The counters the portal accepts.
const ALLOW_LIST: &[&str] = &[otel_instruments::FLOW_LOG_ERRORS];

/// How often to re-check for a config while reporting is unconfigured.
const DISABLED_POLL: Duration = Duration::from_secs(60);

/// Where, and how often, to report metrics to the portal.
pub struct Config {
    /// Base URL metrics are POSTed to.
    pub api_url: String,
    /// Authorizes the reports; sent as-is in the `Authorization` header.
    pub token: SecretString,
    /// How often to report.
    pub interval: Duration,
}

/// Handle to the spawned reporter thread.
///
/// Dropping it detaches the thread; it keeps running until the process exits, so
/// counts keep accumulating across portal reconnects.
#[derive(Clone)]
pub struct Reporter {
    endpoint: Arc<Mutex<Option<Endpoint>>>,
    wakeups: mpsc::Sender<()>,
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

        let url = ingest::metrics_endpoint(&config.api_url)?;

        *self.endpoint.lock() = Some(Endpoint {
            url,
            token: config.token.clone(),
            interval: config.interval,
        });
        let _ = self.wakeups.send(());

        Ok(())
    }

    /// Stops reporting until the next [`Reporter::configure`].
    pub fn disable(&self) {
        *self.endpoint.lock() = None;
    }
}

/// Wraps `inner` in a [`RecordingMeterProvider`] and spawns the thread reporting
/// what it records.
///
/// Installing the returned provider is up to the caller. `resource` are the OTLP
/// resource attributes every report carries.
pub fn spawn(
    inner: Box<dyn MeterProvider + Send + Sync>,
    resource: Vec<KeyValue>,
    socket_factory: Arc<dyn SocketFactory<TcpSocket>>,
) -> (RecordingMeterProvider, Reporter) {
    let registry = Arc::new(Registry::default());
    let (wakeups, inbox) = mpsc::channel();

    let reporter = Reporter {
        endpoint: Arc::new(Mutex::new(None)),
        wakeups,
    };

    std::thread::Builder::new()
        .name("portal-metrics".to_owned())
        .spawn({
            // The thread holds a handle too, so dropping the caller's detaches
            // rather than stops it.
            let reporter = reporter.clone();
            let registry = registry.clone();

            move || run(&reporter, &registry, &resource, &socket_factory, &inbox)
        })
        .expect("Failed to spawn portal metrics thread");

    (RecordingMeterProvider::new(inner, registry), reporter)
}

/// The reporter's event loop: sleeps until the next report is due or a new config
/// arrives, whichever comes first.
fn run(
    reporter: &Reporter,
    registry: &Registry,
    resource: &[KeyValue],
    socket_factory: &Arc<dyn SocketFactory<TcpSocket>>,
    wakeups: &mpsc::Receiver<()>,
) {
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

    tracing::info!("Portal metrics reporter started");

    let mut interval_start = SystemTime::now();
    let mut delay = DISABLED_POLL;

    loop {
        match wakeups.recv_timeout(delay) {
            Ok(()) => {}
            Err(mpsc::RecvTimeoutError::Timeout) => {}
            // Unreachable while the thread holds its own handle.
            Err(mpsc::RecvTimeoutError::Disconnected) => return,
        }

        delay = runtime.block_on(report_pass(
            reporter,
            registry,
            resource,
            socket_factory,
            &mut interval_start,
        ));
    }
}

/// Runs one report pass; returns how long to wait before the next.
///
/// The registry is only drained once there is somewhere to report to, and a pass
/// that fails to deliver folds its samples back in for the next one to retry.
async fn report_pass(
    reporter: &Reporter,
    registry: &Registry,
    resource: &[KeyValue],
    socket_factory: &Arc<dyn SocketFactory<TcpSocket>>,
    interval_start: &mut SystemTime,
) -> Duration {
    let Some(endpoint) = reporter.endpoint.lock().clone() else {
        return DISABLED_POLL;
    };

    let now = SystemTime::now();
    let samples = registry.drain();

    if samples.is_empty() {
        *interval_start = now;

        return endpoint.interval;
    }

    match report(
        &endpoint,
        resource,
        &samples,
        *interval_start,
        now,
        socket_factory.clone(),
    )
    .await
    {
        Ok(()) => *interval_start = now,
        Err(e) => {
            tracing::warn!("Failed to report metrics to portal: {e:#}");
            registry.fold_back(samples);
        }
    }

    endpoint.interval
}

async fn report(
    endpoint: &Endpoint,
    resource: &[KeyValue],
    samples: &[Sample],
    start: SystemTime,
    end: SystemTime,
    socket_factory: Arc<dyn SocketFactory<TcpSocket>>,
) -> Result<()> {
    let request = ExportMetricsServiceRequest::new(resource, samples, start, end);
    let body = serde_json::to_vec(&request).context("Failed to serialize metrics report")?;

    ingest::report(
        &endpoint.url,
        &endpoint.token,
        Bytes::from(body),
        socket_factory,
    )
    .await?;

    tracing::debug!(series = samples.len(), "Reported metrics to portal");

    Ok(())
}

/// The portal's config, with its endpoint already validated.
#[derive(Clone)]
struct Endpoint {
    url: Url,
    token: SecretString,
    interval: Duration,
}
