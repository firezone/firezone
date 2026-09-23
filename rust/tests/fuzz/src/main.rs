//! Runs the protocol fuzz targets and replays their saved inputs.
#![allow(clippy::print_stdout, clippy::print_stderr)]

use std::{path::PathBuf, sync::LazyLock, time::Instant};

use anyhow::Context as _;
use arbitrary::{Arbitrary, Unstructured};
use clap::{Parser, ValueEnum};

mod clock;
mod seeded_rng;
mod targets;

static START_TIME: LazyLock<Instant> = LazyLock::new(clock::start_time);

fn main() -> anyhow::Result<()> {
    let cli = Cli::parse();
    seeded_rng::reset(0);
    // Forked inputs inherit the same clock anchor, including its subsecond offset.
    LazyLock::force(&START_TIME);

    let target: fn(&[u8]) = match cli.target {
        Target::IpPacket => |data| with_input(data, targets::ip_packet::test),
        Target::RelayProto => |data| with_input(data, targets::relay_proto::test),
        Target::TunnelProto => targets::tunnel_proto::test,
        Target::X509Claims => |data| with_input(data, targets::x509_claims::test),
    };
    if cli.replay.is_empty() {
        cfg_select! {
            fuzzing => {
                afl::fuzz(true, target);

                return Ok(());
            }
            _ => {
                anyhow::bail!("build with `cargo afl build` to fuzz, or pass --replay PATH...");
            }
        }
    }

    let inputs = load_inputs(cli.replay)?;

    let started = Instant::now();
    for _ in 0..cli.repeat {
        for (path, data) in &inputs {
            if let Err(panic) = std::panic::catch_unwind(|| target(data)) {
                eprintln!("Replay failed for {}", path.display());
                std::panic::resume_unwind(panic);
            }
        }
    }
    let elapsed = started.elapsed().as_secs_f64();
    let iterations = inputs.len() as u64 * cli.repeat;
    println!(
        "Replayed {iterations} inputs in {elapsed:.6}s ({:.2} iterations/sec)",
        iterations as f64 / elapsed
    );

    Ok(())
}

fn with_input<'a, T: Arbitrary<'a>>(data: &'a [u8], test: fn(T)) {
    if data.len() < T::size_hint(0).0 {
        return;
    }

    let Ok(input) = T::arbitrary_take_rest(Unstructured::new(data)) else {
        return;
    };

    test(input);
}

#[derive(Parser)]
#[command(about = "Runs an AFL++ target or replays saved inputs")]
struct Cli {
    /// Protocol or parser to exercise.
    #[arg(value_enum)]
    target: Target,

    /// Replays input files or corpus directories in one process.
    #[arg(long, value_name = "PATH", num_args = 1..)]
    replay: Vec<PathBuf>,

    /// Replays the entire corpus this many times.
    #[arg(long, default_value_t = 1, requires = "replay", value_parser = clap::value_parser!(u64).range(1..))]
    repeat: u64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, ValueEnum)]
enum Target {
    IpPacket,
    RelayProto,
    TunnelProto,
    X509Claims,
}

fn load_inputs(paths: Vec<PathBuf>) -> anyhow::Result<Vec<(PathBuf, Vec<u8>)>> {
    let mut files = Vec::new();
    for path in paths {
        if path.is_dir() {
            for entry in std::fs::read_dir(&path)
                .with_context(|| format!("failed to read {}", path.display()))?
            {
                let entry = entry?;
                if entry.file_type()?.is_file() {
                    files.push(entry.path());
                }
            }
        } else {
            files.push(path);
        }
    }
    files.sort();
    files.dedup();
    anyhow::ensure!(!files.is_empty(), "no corpus files found");

    let inputs = files
        .into_iter()
        .map(|path| {
            let data = std::fs::read(&path)
                .with_context(|| format!("failed to read {}", path.display()))?;

            Ok((path, data))
        })
        .collect::<anyhow::Result<Vec<_>>>()?;

    Ok(inputs)
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used)]

    use super::*;

    #[test]
    fn target_without_replay_selects_fuzzing() {
        let cli = Cli::try_parse_from(["fuzz", "tunnel-proto"]).unwrap();

        assert_eq!(cli.target, Target::TunnelProto);
        assert!(cli.replay.is_empty());
        assert_eq!(cli.repeat, 1);
    }

    #[test]
    fn replay_requires_inputs_and_positive_repeats() {
        for args in [
            vec!["fuzz"],
            vec!["fuzz", "unknown"],
            vec!["fuzz", "ip-packet", "--replay"],
            vec!["fuzz", "ip-packet", "--replay", "corpus", "--repeat", "0"],
            vec!["fuzz", "ip-packet", "--repeat", "3"],
        ] {
            assert!(Cli::try_parse_from(args).is_err());
        }
        let cli = Cli::try_parse_from(["fuzz", "ip-packet", "--replay", "corpus", "--repeat", "3"])
            .unwrap();

        assert_eq!(cli.target, Target::IpPacket);
        assert_eq!(cli.repeat, 3);
        assert_eq!(cli.replay, vec![PathBuf::from("corpus")]);
    }

    #[test]
    fn inputs_are_sorted_and_deduplicated() {
        let directory = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
        let manifest = directory.join("Cargo.toml");
        let build = directory.join("build.rs");

        let inputs = load_inputs(vec![build.clone(), manifest.clone(), build.clone()]).unwrap();

        assert_eq!(
            inputs.iter().map(|(path, _)| path).collect::<Vec<_>>(),
            vec![&manifest, &build]
        );
        assert!(inputs.iter().all(|(_, data)| !data.is_empty()));
    }
}
