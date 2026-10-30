//! What criterion measures per iteration: wall time, or the CPU time of one stage's threads.

use std::time::{Duration, Instant};

use criterion::Throughput;
use criterion::measurement::{Measurement, ValueFormatter, WallTime};

use crate::thread_cpu::thread_cpu_times;

/// How the measurement is selected; `event-loop` when unset.
const ENV: &str = "TUNNEL_BENCH_MEASURE";

/// A stage of the pipeline, named by the prefix its threads share.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Stage {
    EventLoop,
    Udp,
    Crypto,
    Tun,
}

impl Stage {
    pub(crate) const ALL: [Stage; 4] = [Stage::EventLoop, Stage::Udp, Stage::Crypto, Stage::Tun];

    pub(crate) fn name(self) -> &'static str {
        match self {
            Stage::EventLoop => "event-loop",
            Stage::Udp => "udp",
            Stage::Crypto => "crypto",
            Stage::Tun => "tun",
        }
    }

    pub(crate) fn thread_prefix(self) -> &'static str {
        match self {
            Stage::EventLoop => "event-loop",
            Stage::Udp => "UDP",
            Stage::Crypto => "wg-crypto",
            Stage::Tun => "TUN",
        }
    }

    /// The CPU time all threads of this stage have used so far.
    fn cpu(self) -> Duration {
        thread_cpu_times()
            .into_iter()
            .filter(|(name, _)| name.starts_with(self.thread_prefix()))
            .map(|(_, cpu)| cpu)
            .sum()
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Measure {
    Wall,
    Cpu(Stage),
}

impl Measure {
    pub fn from_env() -> Self {
        let Some(name) = std::env::var_os(ENV) else {
            return Measure::Cpu(Stage::EventLoop);
        };
        let name = name.to_string_lossy();

        if name == "wall" {
            return Measure::Wall;
        }

        Stage::ALL
            .into_iter()
            .find(|stage| stage.name() == name)
            .map(Measure::Cpu)
            .unwrap_or_else(|| {
                panic!("{ENV} must be `wall` or one of event-loop, udp, crypto, tun; got `{name}`")
            })
    }

    /// The criterion group every benchmark goes in, so each measure keeps its own baselines.
    pub fn name(self) -> &'static str {
        match self {
            Measure::Wall => "wall",
            Measure::Cpu(stage) => stage.name(),
        }
    }
}

/// Criterion's wall-clock measurement, as a `Copy` type the harness can hand around.
#[derive(Clone, Copy)]
pub struct Wall;

impl Measurement for Wall {
    type Intermediate = Instant;
    type Value = Duration;

    fn start(&self) -> Instant {
        WallTime.start()
    }

    fn end(&self, start: Instant) -> Duration {
        WallTime.end(start)
    }

    fn add(&self, a: &Duration, b: &Duration) -> Duration {
        WallTime.add(a, b)
    }

    fn zero(&self) -> Duration {
        WallTime.zero()
    }

    fn to_f64(&self, value: &Duration) -> f64 {
        WallTime.to_f64(value)
    }

    fn formatter(&self) -> &dyn ValueFormatter {
        WallTime.formatter()
    }
}

/// Measures the CPU time of one stage's threads, summed over all of them.
#[derive(Clone, Copy)]
pub struct StageCpu(pub Stage);

impl Measurement for StageCpu {
    type Intermediate = Duration;
    type Value = Duration;

    fn start(&self) -> Duration {
        self.0.cpu()
    }

    fn end(&self, start: Duration) -> Duration {
        self.0.cpu().saturating_sub(start)
    }

    fn add(&self, a: &Duration, b: &Duration) -> Duration {
        *a + *b
    }

    fn zero(&self) -> Duration {
        Duration::ZERO
    }

    fn to_f64(&self, value: &Duration) -> f64 {
        value.as_nanos() as f64
    }

    fn formatter(&self) -> &dyn ValueFormatter {
        &CpuFormatter
    }
}

/// Formats CPU nanoseconds like criterion formats wall time, with throughput per CPU-second.
struct CpuFormatter;

impl ValueFormatter for CpuFormatter {
    fn scale_values(&self, typical: f64, values: &mut [f64]) -> &'static str {
        let (factor, unit) = match typical {
            t if t < 1e3 => (1.0, "ns"),
            t if t < 1e6 => (1e-3, "µs"),
            t if t < 1e9 => (1e-6, "ms"),
            _ => (1e-9, "s"),
        };
        for value in values {
            *value *= factor;
        }

        unit
    }

    fn scale_throughputs(
        &self,
        typical: f64,
        throughput: &Throughput,
        values: &mut [f64],
    ) -> &'static str {
        let (per_iter, kind) = match throughput {
            Throughput::Bits(bits) => (*bits as f64, "b/s"),
            Throughput::Bytes(bytes) | Throughput::BytesDecimal(bytes) => (*bytes as f64, "B/s"),
            Throughput::Elements(elements) | Throughput::ElementsAndBytes { elements, .. } => {
                (*elements as f64, "elem/s")
            }
        };
        let typical_per_second = per_iter * 1e9 / typical;
        let (factor, prefix) = match typical_per_second {
            t if t < 1e3 => (1.0, ""),
            t if t < 1e6 => (1e-3, "K"),
            t if t < 1e9 => (1e-6, "M"),
            _ => (1e-9, "G"),
        };
        for value in values {
            *value = per_iter * 1e9 / *value * factor;
        }

        match (prefix, kind) {
            ("", "b/s") => "b/s",
            ("K", "b/s") => "Kb/s",
            ("M", "b/s") => "Mb/s",
            ("G", "b/s") => "Gb/s",
            ("", "B/s") => "B/s",
            ("K", "B/s") => "KB/s",
            ("M", "B/s") => "MB/s",
            ("G", "B/s") => "GB/s",
            ("", _) => "elem/s",
            ("K", _) => "Kelem/s",
            ("M", _) => "Melem/s",
            (_, _) => "Gelem/s",
        }
    }

    fn scale_for_machines(&self, _values: &mut [f64]) -> &'static str {
        "ns"
    }
}
