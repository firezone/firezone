//! Log-pattern coverage check for the `tunnel_test` proptest suite.
//!
//! [`Coverage`] is a minimal observer: a bitmap of [`REQUIRED_PATTERNS`]
//! that flips bits as matching tracing events go by. Its [`MakeWriter`]
//! impl plugs into a standard `tracing_subscriber::fmt::layer()` so the
//! stock formatter does the rendering and we scan the resulting bytes
//! line by line.

use std::fmt;
use std::io::{self, Write as _};
use std::sync::{Arc, Mutex};

use proptest::test_runner::{FailurePersistence, PersistedSeed};
use tracing_subscriber::fmt::MakeWriter;

/// Log patterns that every `tunnel_test` run must cover.
///
/// Each entry is a substring that must appear in at least one formatted
/// event during the run.
pub(crate) const REQUIRED_PATTERNS: &[&str] = &[
    "SendIcmpPacket",
    "SendUdpPacket",
    "ConnectTcp",
    "SendDnsQueries",
    "Packet for DNS resource",
    "Packet for CIDR resource",
    "Packet for Internet resource",
    "Truncating DNS response",
    "ICMP Error error=V4Unreachable",
    "ICMP Error error=V6Unreachable",
    "ICMP Error error=V4TimeExceeded",
    "ICMP Error error=V6TimeExceeded",
    "Forwarding query for DNS resource to corresponding site",
    "Revoking resource authorization",
    "Re-seeding records for DNS resources",
    "Resource is known but its addressability changed",
    "No A / AAAA records for domain",
    "State change (got new possible): Disconnected -> Checking",
    "Initiating graceful shutdown",
    "Connection closed proactively (sent goodbye)",
    "New device access authorized",
    "Malicious client: ignoring resource filter",
];

const ENFORCE_ENV_VAR: &str = "TUNNEL_TEST_ENFORCE_COVERAGE";
const HARVEST_TARGET_ENV_VAR: &str = "TUNNEL_TEST_HARVEST_TARGET";
const MISSING_BEGIN: &str = "TUNNEL_TEST_MISSING_PATTERNS_BEGIN";
const MISSING_END: &str = "TUNNEL_TEST_MISSING_PATTERNS_END";

/// `Some(Coverage)` iff `TUNNEL_TEST_ENFORCE_COVERAGE=1`.
pub(crate) fn run_coverage() -> Option<Coverage> {
    std::env::var_os(ENFORCE_ENV_VAR)
        .is_some_and(|v| v == "1")
        .then(Coverage::new)
}

/// Stderr marker prefixing each harvested seed. The driver script
/// extracts seeds from worker logs by grepping for this prefix and
/// assembles the final `tests.txt` block using the harvest target
/// that was passed in via `TUNNEL_TEST_HARVEST_TARGET`.
const HARVESTED_SEED_MARKER: &str = "TUNNEL_TEST_HARVESTED_SEED";

/// Resolve the harvest target from `TUNNEL_TEST_HARVEST_TARGET`, once, at
/// the top of the test runner. Panics if the env var is set to a value
/// that does not match any entry in [`REQUIRED_PATTERNS`] — almost
/// always a typo in the driver script.
pub(crate) fn harvest_target() -> Option<&'static str> {
    let raw = std::env::var(HARVEST_TARGET_ENV_VAR).ok()?;
    let matched = REQUIRED_PATTERNS.iter().find(|p| **p == raw).copied();
    if matched.is_none() {
        panic!(
            "{HARVEST_TARGET_ENV_VAR}={raw:?} does not match any entry \
             in `REQUIRED_PATTERNS`. Pass one of: {:?}",
            REQUIRED_PATTERNS,
        );
    }
    matched
}

/// Shared pattern-observation bitmap.
#[derive(Clone)]
pub(crate) struct Coverage {
    seen: Arc<Mutex<[bool; REQUIRED_PATTERNS.len()]>>,
}

impl Coverage {
    pub(crate) fn new() -> Self {
        Self {
            seen: Arc::new(Mutex::new([false; REQUIRED_PATTERNS.len()])),
        }
    }

    /// `true` iff at least one tracing event observed by this `Coverage`
    /// contained `pattern` as a substring.
    pub(crate) fn seen(&self, pattern: &str) -> bool {
        let Some(idx) = index_of(pattern) else {
            return false;
        };
        self.seen.lock().unwrap()[idx]
    }

    /// Panic listing every [`REQUIRED_PATTERNS`] entry that was not
    /// observed through this `Coverage`.
    pub(crate) fn assert_all_patterns_seen(&self) {
        let missing = REQUIRED_PATTERNS
            .iter()
            .copied()
            .filter(|p| !self.seen(p))
            .collect::<Vec<_>>();

        if missing.is_empty() {
            return;
        }

        // Machine-readable block consumed by `tunnel-proptest-harvester`.
        // Emit before the panic message so it always reaches stderr.
        eprintln!("{MISSING_BEGIN}");
        for pattern in &missing {
            eprintln!("{pattern}");
        }
        eprintln!("{MISSING_END}");

        let list = missing
            .iter()
            .map(|p| format!("  - {p}"))
            .collect::<Vec<_>>()
            .join("\n");

        panic!(
            "Coverage check failed: the following log patterns were not observed \
             during the proptest run:\n{list}\n\n\
             Run the `tunnel-proptest-harvester` binary to generate regression seeds \
             for the missing patterns and append them to \
             `proptest-regressions/tests.txt`.",
        );
    }

    fn observe(&self, line: &str) {
        let mut seen = self.seen.lock().unwrap();
        for (i, pattern) in REQUIRED_PATTERNS.iter().enumerate() {
            if seen[i] {
                continue;
            }
            if line.contains(pattern) {
                seen[i] = true;
            }
        }
    }
}

fn index_of(pattern: &str) -> Option<usize> {
    REQUIRED_PATTERNS.iter().position(|p| *p == pattern)
}

// Plug `Coverage` into a `tracing_subscriber::fmt::layer()` so we reuse
// the stock event formatter. The fmt layer terminates each rendered
// event with a newline; the `Writer` buffers incoming bytes and flushes
// each complete line to `observe` as soon as it arrives.
impl<'a> MakeWriter<'a> for Coverage {
    type Writer = Writer;

    fn make_writer(&'a self) -> Self::Writer {
        Writer {
            coverage: self.clone(),
            pending: Vec::new(),
        }
    }
}

pub(crate) struct Writer {
    coverage: Coverage,
    /// Bytes from a partial line that haven't been terminated yet.
    pending: Vec<u8>,
}

impl io::Write for Writer {
    fn write(&mut self, data: &[u8]) -> io::Result<usize> {
        self.pending.extend_from_slice(data);

        let mut scan_start = 0;
        while let Some(nl_offset) = self.pending[scan_start..].iter().position(|b| *b == b'\n') {
            let line_end = scan_start + nl_offset + 1;
            if let Ok(line) = std::str::from_utf8(&self.pending[scan_start..line_end]) {
                self.coverage.observe(line);
            }
            scan_start = line_end;
        }
        self.pending.drain(..scan_start);

        Ok(data.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

/// Custom [`FailurePersistence`] used while harvesting regression seeds.
///
/// - `load_persisted_failures2` returns `[]` so the RNG is not biased by
///   replaying seeds that already pass the current test.
/// - `save_persisted_failure2` prints the shrunken seed to stderr
///   prefixed with [`HARVESTED_SEED_MARKER`]. The driver script reads
///   the seed out of the worker's captured log and pairs it up with the
///   harvest target it passed in, so no output-path coordination
///   between the runner and the driver is required.
#[derive(Debug, Clone)]
pub(crate) struct HarvestPersistence {
    target: &'static str,
}

impl HarvestPersistence {
    pub(crate) fn for_target(target: &'static str) -> Self {
        Self { target }
    }
}

impl FailurePersistence for HarvestPersistence {
    fn load_persisted_failures2(&self, _source_file: Option<&'static str>) -> Vec<PersistedSeed> {
        Vec::new()
    }

    fn save_persisted_failure2(
        &mut self,
        _source_file: Option<&'static str>,
        seed: PersistedSeed,
        _shrunken_value: &dyn fmt::Debug,
    ) {
        // The driver already knows which pattern this worker hunted
        // (it set `TUNNEL_TEST_HARVEST_TARGET`), so the marker line only
        // needs to carry the seed.
        let _ = writeln!(io::stderr().lock(), "{HARVESTED_SEED_MARKER} {seed}");
    }

    fn box_clone(&self) -> Box<dyn FailurePersistence> {
        Box::new(self.clone())
    }

    fn eq(&self, other: &dyn FailurePersistence) -> bool {
        other
            .as_any()
            .downcast_ref::<Self>()
            .is_some_and(|o| o.target == self.target)
    }

    fn as_any(&self) -> &dyn std::any::Any {
        self
    }
}
