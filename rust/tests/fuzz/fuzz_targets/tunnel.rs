#![no_main]

//! Coverage-guided fuzz target for the connlib tunnel state machine.
//!
//! Each input drives one run of the tunnel reference-model/system-under-test
//! harness. The bytes are decoded positionally through
//! `arbitrary::Unstructured` so that libFuzzer mutations and minimization map
//! to individual scenario decisions. See
//! [`fuzz::run_fuzz_case_structured`].

use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    fuzz::run_fuzz_case_structured(data);
});
