#![expect(
    clippy::print_stdout,
    clippy::print_stderr,
    reason = "CLI tool streams worker output and the final seed block"
)]

//! Hunt for regression seeds that cover tunnel-proptest log patterns
//! missing from `proptest-regressions/tests.txt`. With no args, a dry
//! pass first discovers which patterns the current suite misses.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::Arc;
use std::time::Duration;

use anyhow::{Context, Result, bail};
use clap::Parser;
use futures::future::{Either, select};
use tokio::io::AsyncWriteExt;
use tokio::process::Command;
use tokio::task::{AbortHandle, JoinSet};
use tokio_stream::StreamExt as _;

use crate::process_group::ProcessGroup;
use crate::slot_pool::{Slot, SlotPool};

mod process_group;
mod slot_pool;

/// Resolved at compile time so the binary runs from anywhere.
const TUNNEL_DIR: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../../libs/connlib/tunnel");

const HARVESTED_SEED_MARKER: &str = "TUNNEL_TEST_HARVESTED_SEED";
const MISSING_BEGIN: &str = "TUNNEL_TEST_MISSING_PATTERNS_BEGIN";
const MISSING_END: &str = "TUNNEL_TEST_MISSING_PATTERNS_END";
const OUT_DIR: &str = "harvest-output";
const WORKER_TIMEOUT: Duration = Duration::from_secs(15 * 60);

/// Safety net for impossible / mistyped patterns; never reached in practice.
const MAX_ATTEMPTS_PER_PATTERN: usize = 20;

const PROPTEST_CASES: u64 = 100_000;
const PROPTEST_MAX_SHRINK_ITERS: u64 = 100;

#[derive(Parser, Debug)]
#[command(
    about = "Harvest regression seeds for missing tunnel-proptest coverage patterns",
    long_about = None,
)]
struct Args {
    /// Patterns to hunt for. Omit to auto-discover via a dry pass.
    patterns: Vec<Pattern>,
}

#[tokio::main(flavor = "multi_thread")]
async fn main() -> Result<()> {
    let args = Args::parse();

    // On Ctrl-C, dropping `harvest` cascades Drop through `Pool` → tasks
    // → `ProcessGroup` → SIGKILL; no cancellation tokens needed.
    let harvest = std::pin::pin!(harvest(args.patterns));
    let ctrl_c = std::pin::pin!(tokio::signal::ctrl_c());
    match select(harvest, ctrl_c).await {
        Either::Left((result, _)) => result?,
        Either::Right((_, _)) => eprintln!("\nreceived Ctrl-C, shutting down..."),
    }

    Ok(())
}

async fn harvest(patterns: Vec<Pattern>) -> Result<()> {
    let tunnel_dir = Path::new(TUNNEL_DIR)
        .canonicalize()
        .with_context(|| format!("resolving tunnel crate at {TUNNEL_DIR}"))?;
    std::env::set_current_dir(&tunnel_dir)
        .with_context(|| format!("cd {}", tunnel_dir.display()))?;

    let max_workers = num_cpus::get().saturating_sub(1).max(1);

    let patterns = if patterns.is_empty() {
        let discovered = dry_pass().await?;
        if discovered.is_empty() {
            eprintln!("All coverage patterns are already hit by the existing suite.");
            return Ok(());
        }
        discovered
    } else {
        patterns
    };

    eprintln!("Patterns to harvest ({}):", patterns.len());
    for p in &patterns {
        eprintln!("  - {p}");
    }

    eprintln!("Building test binary...");
    let mut build = Command::new("cargo");
    build.args(["test", "tunnel_test", "--features", "proptest", "--no-run"]);
    run_passthrough(build)
        .await
        .context("cargo test --no-run failed")?;

    let config = Arc::new(PoolConfig {
        max_workers,
        max_pattern_len: patterns.iter().map(|p| p.as_str().len()).max().unwrap_or(0),
        max_slot_digits: max_workers.saturating_sub(1).to_string().len().max(1),
    });

    let seeds = Pool::new(patterns, config).run().await;
    print_summary(&seeds);
    Ok(())
}

async fn dry_pass() -> Result<Vec<Pattern>> {
    eprintln!("Running dry pass to discover missing patterns...");

    let mut cmd = Command::new("cargo");
    cmd.args([
        "test",
        "tunnel_test",
        "--features",
        "proptest",
        "--",
        "--nocapture",
    ])
    .env("TUNNEL_TEST_ENFORCE_COVERAGE", "1")
    // Regression seeds only; novel case generation is the worker's job.
    .env("PROPTEST_CASES", "0")
    .env("CARGO_PROFILE_TEST_OPT_LEVEL", "1")
    .stdout(Stdio::null())
    .stderr(Stdio::piped());

    let mut child = ProcessGroup::spawn(cmd).context("spawn cargo (dry pass)")?;
    let mut lines = child.stderr();

    let mut in_marker_block = false;
    let mut missing = Vec::new();

    while let Some(line) = lines.next().await {
        let Ok(line) = line else { continue };
        if line == MISSING_BEGIN {
            in_marker_block = true;
            continue;
        }
        if line == MISSING_END {
            in_marker_block = false;
            continue;
        }
        if in_marker_block {
            missing.push(Pattern::from(line));
            continue;
        }
        if line.starts_with("Running test case") {
            eprintln!("[dry] {line}");
        }
    }

    let _ = child.wait().await;
    Ok(missing)
}

async fn run_passthrough(mut cmd: Command) -> Result<()> {
    cmd.stdout(Stdio::inherit()).stderr(Stdio::inherit());
    let mut child = ProcessGroup::spawn(cmd).context("spawn")?;
    let status = child.wait().await?;
    if !status.success() {
        bail!("command exited with {status}");
    }
    Ok(())
}

struct Pool {
    patterns: Vec<Pattern>,
    config: Arc<PoolConfig>,
    pattern_states: BTreeMap<Pattern, PatternState>,
    slots: SlotPool,
    tasks: JoinSet<TaskReport>,
}

struct PoolConfig {
    max_workers: usize,
    max_pattern_len: usize,
    max_slot_digits: usize,
}

impl Pool {
    fn new(patterns: Vec<Pattern>, config: Arc<PoolConfig>) -> Self {
        let slots = SlotPool::new(config.max_workers);
        let pattern_states = patterns
            .iter()
            .map(|p| (p.clone(), PatternState::default()))
            .collect();

        Self {
            patterns,
            config,
            pattern_states,
            slots,
            tasks: JoinSet::new(),
        }
    }

    async fn run(mut self) -> BTreeMap<Pattern, Seed> {
        let _ = tokio::fs::remove_dir_all(OUT_DIR).await;
        let _ = tokio::fs::create_dir_all(OUT_DIR).await;

        eprintln!(
            "Keeping up to {} workers busy across {} pattern(s) (per-worker timeout: {}, max {MAX_ATTEMPTS_PER_PATTERN} attempts per pattern)...",
            self.config.max_workers,
            self.patterns.len(),
            humantime::format_duration(WORKER_TIMEOUT),
        );

        self.refill();

        while let Some(reap) = self.tasks.join_next_with_id().await {
            self.handle_reap(reap);
            self.refill();
        }

        self.pattern_states
            .into_iter()
            .filter_map(|(k, v)| v.seed.map(|s| (k, s)))
            .collect()
    }

    fn pick_next_pattern(&self) -> Option<Pattern> {
        self.patterns
            .iter()
            .filter(|p| self.pattern_states[*p].can_spawn())
            .min_by_key(|p| self.pattern_states[*p].active())
            .cloned()
    }

    fn refill(&mut self) {
        while let Some(pattern) = self.pick_next_pattern() {
            let Some(slot) = self.slots.try_take() else {
                break;
            };
            let state = self
                .pattern_states
                .get_mut(&pattern)
                .expect("state entry exists for every pattern");
            let attempt = state.attempts;
            state.attempts += 1;

            let abort = self.tasks.spawn(run_worker(
                slot,
                pattern.clone(),
                attempt,
                self.config.clone(),
            ));
            state.handles.push(abort);
        }
    }

    fn handle_reap(&mut self, reap: Result<(tokio::task::Id, TaskReport), tokio::task::JoinError>) {
        let report = match reap {
            Ok((_, r)) => r,
            Err(e) if e.is_cancelled() => return,
            Err(e) => {
                eprintln!("[panic ] task {:?}: {e}", e.id());
                return;
            }
        };
        let state = self
            .pattern_states
            .get_mut(&report.pattern)
            .expect("state entry exists for every pattern");
        // Keep `active()` honest.
        state.handles.retain(|h| !h.is_finished());

        let p = self.config.max_pattern_len;
        match report.outcome {
            TaskOutcome::Found(seed) => {
                eprintln!(
                    "[found ] {:<p$} (cases={})",
                    report.pattern.as_str(),
                    report.cases,
                );
                if state.seed.is_none() {
                    state.seed = Some(seed);
                    for abort in state.handles.drain(..) {
                        abort.abort();
                    }
                }
            }
            TaskOutcome::Missed => {
                eprintln!(
                    "[missed] {:<p$} (cases={})",
                    report.pattern.as_str(),
                    report.cases,
                );
            }
        }
    }
}

#[derive(Default)]
struct PatternState {
    /// Doubles as the next worker's log-file index.
    attempts: usize,
    /// Live worker count (after `retain(!is_finished)`); drained to
    /// abort siblings when a seed arrives.
    handles: Vec<AbortHandle>,
    seed: Option<Seed>,
}

impl PatternState {
    fn active(&self) -> usize {
        self.handles.len()
    }

    fn is_done(&self) -> bool {
        self.seed.is_some()
    }

    fn can_spawn(&self) -> bool {
        !self.is_done() && self.attempts < MAX_ATTEMPTS_PER_PATTERN
    }
}

async fn run_worker(
    slot: Slot,
    pattern: Pattern,
    attempt: usize,
    config: Arc<PoolConfig>,
) -> TaskReport {
    let p = config.max_pattern_len;
    eprintln!("[start ] {:<p$} (slot {slot})", pattern.as_str());

    let log_path =
        PathBuf::from(OUT_DIR).join(format!("{}.{attempt}.log", sanitize(pattern.as_str())));
    let mut log_file = tokio::fs::File::create(&log_path).await.ok();

    let prefix = format!("[{slot:0>w$}]: {pattern:<p$} |", w = config.max_slot_digits);

    let mut cmd = Command::new("cargo");
    cmd.args([
        "test",
        "tunnel_test",
        "--features",
        "proptest",
        "--",
        "--nocapture",
    ])
    .env("TUNNEL_TEST_HARVEST_TARGET", pattern.as_str())
    .env("PROPTEST_CASES", PROPTEST_CASES.to_string())
    .env(
        "PROPTEST_MAX_SHRINK_ITERS",
        PROPTEST_MAX_SHRINK_ITERS.to_string(),
    )
    .env("CARGO_PROFILE_TEST_OPT_LEVEL", "1")
    .stdout(Stdio::piped())
    .stderr(Stdio::piped());

    let mut child = match ProcessGroup::spawn(cmd) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("[error ] {:<p$} (slot {slot}): {e}", pattern.as_str());
            return TaskReport {
                pattern,
                outcome: TaskOutcome::Missed,
                cases: 0,
            };
        }
    };

    let mut lines = child.stdout_stderr();

    let mut cases = 0;
    let seed = tokio::time::timeout(WORKER_TIMEOUT, async {
        while let Some(next) = lines.next().await {
            let Ok(line) = next else { continue };
            eprintln!("{prefix} {line}");
            if let Some(file) = log_file.as_mut() {
                let _ = file.write_all(line.as_bytes()).await;
                let _ = file.write_all(b"\n").await;
            }
            if line.starts_with("Running test case") {
                cases += 1;
            }
            if let Some(rest) = line.strip_prefix(HARVESTED_SEED_MARKER) {
                let s = rest.trim();
                if !s.is_empty() {
                    return Some(Seed(s.to_owned()));
                }
            }
        }
        None
    })
    .await
    .ok()
    .flatten();

    let outcome = match seed {
        Some(s) => TaskOutcome::Found(s),
        None => TaskOutcome::Missed,
    };

    TaskReport {
        pattern,
        outcome,
        cases,
    }
}

enum TaskOutcome {
    Found(Seed),
    Missed,
}

struct TaskReport {
    pattern: Pattern,
    outcome: TaskOutcome,
    cases: usize,
}

fn print_summary(seeds: &BTreeMap<Pattern, Seed>) {
    if seeds.is_empty() {
        eprintln!("\nNo seeds harvested.");
        return;
    }

    eprintln!("\nHarvested seeds (append to proptest-regressions/tests.txt):");
    eprintln!("===========================================================");
    for seed in seeds.values() {
        println!("{seed}");
    }
    eprintln!("===========================================================");
}

#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
struct Pattern(String);

impl Pattern {
    fn as_str(&self) -> &str {
        &self.0
    }
}

impl From<String> for Pattern {
    fn from(s: String) -> Self {
        Self(s)
    }
}

impl std::str::FromStr for Pattern {
    type Err = std::convert::Infallible;
    fn from_str(s: &str) -> Result<Self, Self::Err> {
        Ok(Self(s.to_owned()))
    }
}

impl std::fmt::Display for Pattern {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.pad(&self.0)
    }
}

/// Verbatim `cc <hex>` line, ready to paste into `tests.txt`.
#[derive(Clone, Debug)]
struct Seed(String);

impl std::fmt::Display for Seed {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

fn sanitize(s: &str) -> String {
    s.chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '_' || c == '-' {
                c
            } else {
                '_'
            }
        })
        .collect()
}
