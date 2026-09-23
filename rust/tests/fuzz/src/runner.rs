use std::{ffi::OsString, path::PathBuf, time::Instant};

use anyhow::Context as _;

/// Runs an AFL++ target or replays saved inputs in the current process.
pub fn run(target: fn(&[u8])) -> anyhow::Result<()> {
    let mut args = std::env::args_os().skip(1);
    let Some(mode) = args.next() else {
        seeded_rng::reset(0);

        #[cfg(fuzzing)]
        {
            afl::fuzz(true, target);

            return Ok(());
        }

        #[cfg(not(fuzzing))]
        anyhow::bail!("build with `cargo afl build` to fuzz, or pass --replay PATH...");
    };

    anyhow::ensure!(mode == "--replay", "expected --replay [--repeat N] PATH...");
    let (repeats, paths) = replay_args(args)?;
    let inputs = load_inputs(paths)?;
    seeded_rng::reset(0);

    let started = Instant::now();
    for _ in 0..repeats {
        for (path, data) in &inputs {
            if let Err(panic) = std::panic::catch_unwind(|| target(data)) {
                eprintln!("Replay failed for {}", path.display());
                std::panic::resume_unwind(panic);
            }
        }
    }
    let elapsed = started.elapsed().as_secs_f64();
    let iterations = inputs.len() as u64 * repeats;
    println!(
        "Replayed {iterations} inputs in {elapsed:.6}s ({:.2} iterations/sec)",
        iterations as f64 / elapsed
    );

    Ok(())
}

fn replay_args(args: impl Iterator<Item = OsString>) -> anyhow::Result<(u64, Vec<PathBuf>)> {
    let mut args = args.peekable();
    let repeats = if args.peek().is_some_and(|arg| arg == "--repeat") {
        args.next();
        let repeats = args.next().context("--repeat requires a count")?;
        let repeats = repeats.to_str().context("invalid repeat count")?.parse()?;
        anyhow::ensure!(repeats > 0, "repeat count must be positive");

        repeats
    } else {
        1
    };
    let paths = args.map(PathBuf::from).collect::<Vec<_>>();
    anyhow::ensure!(!paths.is_empty(), "--replay requires at least one path");

    Ok((repeats, paths))
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
    use super::*;

    #[test]
    fn replay_requires_inputs_and_positive_repeats() {
        assert!(replay_args([].into_iter()).is_err());
        assert!(replay_args(["--repeat", "0", "corpus"].map(OsString::from).into_iter()).is_err());
        assert_eq!(
            replay_args(["--repeat", "3", "corpus"].map(OsString::from).into_iter()).unwrap(),
            (3, vec![PathBuf::from("corpus")])
        );
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
