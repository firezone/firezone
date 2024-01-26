//! Test driver for subzone's multi-process test, which are difficult to run
//! inside Cargo's test harness.

fn main() -> anyhow::Result<()> {
    subzone::run_multi_process_tests()
}
