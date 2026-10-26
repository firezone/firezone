/// The gateway's allocator, so the benchmark exercises the same one.
#[global_allocator]
static ALLOC: mimalloc::MiMalloc = mimalloc::MiMalloc;

use std::time::Duration;

use criterion::Criterion;
use criterion::measurement::Measurement;
use tunnel_bench::measure::{Measure, StageCpu, Wall};

fn main() {
    match Measure::from_env() {
        measure @ Measure::Wall => run(Wall, measure),
        measure @ Measure::Cpu(stage) => run(StageCpu(stage), measure),
    }
}

fn run<M: Measurement + Copy>(measurement: M, measure: Measure) {
    let mut criterion = Criterion::default()
        .with_measurement(measurement)
        .warm_up_time(Duration::from_millis(500))
        .measurement_time(Duration::from_millis(1500))
        .without_plots()
        .configure_from_args();

    tunnel_bench::throughput::bench(&mut criterion, measurement, measure.name());
    criterion.final_summary();
}
