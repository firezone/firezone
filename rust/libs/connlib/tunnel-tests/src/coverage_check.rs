//! Marker-based coverage check for the `tunnel_test` proptest suite.
//!
//! Coverage is recorded by `coverage::cov!` markers compiled into the
//! data-plane crates and this harness (see the `coverage` crate). Each
//! marker bumps a process-global counter keyed by its label. This module
//! owns the list of [`REQUIRED_MARKERS`] every run must hit and the two
//! env-var-driven modes layered on top:
//!
//! - `TUNNEL_TEST_ENFORCE_COVERAGE=1` asserts, once the run finishes, that
//!   every required marker fired at least once.
//! - `TUNNEL_TEST_HARVEST_TARGET=<label>` hunts a regression seed for a
//!   single marker: each case resets the counters and fails as soon as the
//!   hunted marker fires, so proptest shrinks and persists the seed.

use std::fmt;
use std::io::{self, Write as _};

use proptest::test_runner::{FailurePersistence, PersistedSeed};

/// Coverage markers that every `tunnel_test` run must hit.
///
/// Each entry is a `coverage::cov!` label emitted somewhere in the
/// data-plane crates or this harness. `TUNNEL_TEST_ENFORCE_COVERAGE=1`
/// fails the run if any of them is never hit.
pub(crate) const REQUIRED_MARKERS: &[&str] = &[
    "transition.icmp",
    "transition.udp",
    "transition.tcp",
    "transition.dns_queries",
    "client.packet_dns_resource",
    "client.packet_cidr_resource",
    "client.packet_internet_resource",
    "dns.response_truncated",
    "icmp_error.v4_unreachable",
    "icmp_error.v6_unreachable",
    "icmp_error.v4_time_exceeded",
    "icmp_error.v6_time_exceeded",
    "dns.forward_query_to_site",
    "gateway.revoke_authorization",
    "dns.reseed_resource_records",
    "client.resource_addressability_changed",
    "gateway.no_a_aaaa_records",
    "tunnel.graceful_shutdown",
    "snownet.closed_with_goodbye",
    "snownet.iceless_path_agent",
    "snownet.ice_agent",
    "client.device_access_authorized",
    "client.malicious_ignore_filter",
    "dns.device_fqdn_resolved",
];

const ENFORCE_ENV_VAR: &str = "TUNNEL_TEST_ENFORCE_COVERAGE";
const HARVEST_TARGET_ENV_VAR: &str = "TUNNEL_TEST_HARVEST_TARGET";
const MISSING_BEGIN: &str = "TUNNEL_TEST_MISSING_PATTERNS_BEGIN";
const MISSING_END: &str = "TUNNEL_TEST_MISSING_PATTERNS_END";

/// Stderr marker prefixing each harvested seed. The driver script
/// extracts seeds from worker logs by grepping for this prefix and
/// assembles the final `tests.txt` block using the harvest target
/// that was passed in via `TUNNEL_TEST_HARVEST_TARGET`.
const HARVESTED_SEED_MARKER: &str = "TUNNEL_TEST_HARVESTED_SEED";

/// `true` iff `TUNNEL_TEST_ENFORCE_COVERAGE=1`.
pub(crate) fn enforce_coverage() -> bool {
    std::env::var_os(ENFORCE_ENV_VAR).is_some_and(|v| v == "1")
}

/// Resolve the harvest target from `TUNNEL_TEST_HARVEST_TARGET`, once, at
/// the top of the test runner. Panics if the env var is set to a value
/// that does not match any entry in [`REQUIRED_MARKERS`] — almost always
/// a typo in the driver script.
pub(crate) fn harvest_target() -> Option<&'static str> {
    let raw = std::env::var(HARVEST_TARGET_ENV_VAR).ok()?;
    let matched = REQUIRED_MARKERS.iter().find(|m| **m == raw).copied();
    if matched.is_none() {
        panic!(
            "{HARVEST_TARGET_ENV_VAR}={raw:?} does not match any entry \
             in `REQUIRED_MARKERS`. Pass one of: {:?}",
            REQUIRED_MARKERS,
        );
    }
    matched
}

/// Clear the global marker counters before a harvest case so that
/// [`marker_hit`] reflects only the case currently executing. Called for
/// every case, including each shrink re-run.
pub(crate) fn reset_markers() {
    ::coverage::reset();
}

/// `true` iff `marker` has been hit since the last [`reset_markers`].
pub(crate) fn marker_hit(marker: &str) -> bool {
    ::coverage::count(marker) > 0
}

/// Panic listing every [`REQUIRED_MARKERS`] entry that was not hit during
/// the run.
pub(crate) fn assert_all_markers_hit() {
    let missing = REQUIRED_MARKERS
        .iter()
        .copied()
        .filter(|m| ::coverage::count(m) == 0)
        .collect::<Vec<_>>();

    if missing.is_empty() {
        return;
    }

    // Machine-readable block consumed by `tunnel-proptest-harvester`.
    // Emit before the panic message so it always reaches stderr.
    eprintln!("{MISSING_BEGIN}");
    for marker in &missing {
        eprintln!("{marker}");
    }
    eprintln!("{MISSING_END}");

    let list = missing
        .iter()
        .map(|m| format!("  - {m}"))
        .collect::<Vec<_>>()
        .join("\n");

    panic!(
        "Coverage check failed: the following markers were not hit \
         during the proptest run:\n{list}\n\n\
         Run the `tunnel-proptest-harvester` binary to generate regression seeds \
         for the missing markers and append them to \
         `proptest-regressions/lib.txt`.",
    );
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
        // The driver already knows which marker this worker hunted
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
