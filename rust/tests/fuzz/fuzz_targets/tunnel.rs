#![no_main]

//! Coverage-guided fuzz target for the connlib tunnel state machine.
//!
//! Each input seeds one run of the same reference-model/system-under-test
//! harness that backs the `tunnel-tests` proptest suite. See
//! [`tunnel_tests::run_fuzz_case`] for how the bytes map to a scenario.

use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    tunnel_tests::run_fuzz_case(data);
});
