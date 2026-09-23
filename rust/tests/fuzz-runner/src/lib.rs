//! Runs AFL++ targets and replays their saved inputs.
#![allow(clippy::print_stdout, clippy::print_stderr)]

use std::{path::PathBuf, time::Instant};

use anyhow::Context as _;
use clap::Parser;

/// Runs an AFL++ target or replays saved inputs in the current process.
pub fn run(target: impl Fn(&[u8]) + std::panic::RefUnwindSafe) -> anyhow::Result<()> {
    let cli = Cli::parse();
    if !cli.replay {
        seeded_rng::reset(0);

        #[cfg(fuzzing)]
        {
            afl::fuzz(true, target);

            return Ok(());
        }

        #[cfg(not(fuzzing))]
        anyhow::bail!("build with `cargo afl build` to fuzz, or pass --replay PATH...");
    }

    let inputs = load_inputs(cli.paths)?;
    seeded_rng::reset(0);

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

#[derive(Parser)]
#[command(about = "Runs an AFL++ target or replays saved inputs")]
struct Cli {
    /// Replays saved inputs in one process rather than starting the forkserver.
    #[arg(long, requires = "paths")]
    replay: bool,

    /// Replays the entire corpus this many times.
    #[arg(long, default_value_t = 1, requires = "replay", value_parser = clap::value_parser!(u64).range(1..))]
    repeat: u64,

    /// Input files or directories containing corpus files.
    #[arg(value_name = "PATH", requires = "replay")]
    paths: Vec<PathBuf>,
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
    fn no_arguments_selects_fuzzing() {
        let cli = Cli::try_parse_from(["target"]).unwrap();

        assert!(!cli.replay);
        assert_eq!(cli.repeat, 1);
        assert!(cli.paths.is_empty());
    }

    #[test]
    fn replay_requires_inputs_and_positive_repeats() {
        for args in [
            vec!["target", "--replay"],
            vec!["target", "--replay", "--repeat", "0", "corpus"],
            vec!["target", "--repeat", "3"],
            vec!["target", "corpus"],
        ] {
            assert!(Cli::try_parse_from(args).is_err());
        }
        let cli = Cli::try_parse_from(["target", "--replay", "--repeat", "3", "corpus"]).unwrap();

        assert!(cli.replay);
        assert_eq!(cli.repeat, 3);
        assert_eq!(cli.paths, vec![PathBuf::from("corpus")]);
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
