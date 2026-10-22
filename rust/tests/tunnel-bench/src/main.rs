/// The gateway's allocator, so the benchmark exercises the same one.
#[global_allocator]
static ALLOC: mimalloc::MiMalloc = mimalloc::MiMalloc;

mod event_loop;
mod fixture;
mod idle_connections;
mod measure;
mod thread_cpu;

use std::collections::BTreeMap;
use std::time::Duration;

use criterion::Criterion;
use criterion::measurement::Measurement;

use measure::{Measure, StageCpu, Wall};

/// The file to write the measures of all benchmarks to in Bencher Metric Format, if set.
///
/// An environment variable because criterion parses the whole command line itself.
const BENCHER_JSON_ENV: &str = "TUNNEL_BENCH_JSON";

fn main() -> anyhow::Result<()> {
    let mut report = match Measure::from_env() {
        measure @ Measure::Wall => event_loop(Wall, measure),
        measure @ Measure::Cpu(stage) => event_loop(StageCpu(stage), measure),
    };

    let mut criterion = criterion(Wall);
    report.extend(idle_connections::bench(&mut criterion));
    criterion.final_summary();

    if let Some(path) = std::env::var_os(BENCHER_JSON_ENV) {
        let json = serde_json::Map::from_iter(report);
        std::fs::write(path, serde_json::to_vec_pretty(&json)?)?;
    }

    Ok(())
}

fn event_loop<M: Measurement + Copy>(
    measurement: M,
    measure: Measure,
) -> BTreeMap<String, serde_json::Value> {
    let mut criterion = criterion(measurement);
    let report = event_loop::bench(&mut criterion, measurement, measure.name());
    criterion.final_summary();

    report
}

fn criterion<M: Measurement>(measurement: M) -> Criterion<M> {
    Criterion::default()
        .with_measurement(measurement)
        .warm_up_time(Duration::from_millis(500))
        .measurement_time(Duration::from_millis(1500))
        .without_plots()
        .configure_from_args()
}
