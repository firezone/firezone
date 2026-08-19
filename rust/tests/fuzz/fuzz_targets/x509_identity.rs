#![no_main]

//! Exercises the X.509 client identity parser with arbitrary DER.

use std::time::{Duration, UNIX_EPOCH};

use arbitrary::Arbitrary;
use libfuzzer_sys::fuzz_target;
use x509_identity::{ParsedCertificate, parse_certificate};

fuzz_target!(|input: Input| {
    // `SystemTime` is not `Arbitrary` and adding a `Duration` to it panics on overflow,
    // so the offset is applied to the epoch with `checked_add`.
    let now = UNIX_EPOCH
        .checked_add(Duration::from_secs(input.seconds_since_epoch))
        .unwrap_or(UNIX_EPOCH);

    let Some(certificate) = parse_certificate(input.der, now) else {
        return;
    };

    test_all_getters(&certificate, input.expected_subject_cn);
});

/// The certificate comes last so that it takes the rest of the input: libFuzzer's
/// mutations then apply to the DER instead of to the parameters in front of it.
#[derive(Arbitrary, Debug)]
struct Input<'a> {
    seconds_since_epoch: u64,
    expected_subject_cn: &'a str,
    der: &'a [u8],
}

fn test_all_getters(certificate: &ParsedCertificate, expected_subject_cn: &str) {
    let _ = certificate.is_usable(expected_subject_cn);
    // An arbitrary common name almost never matches, which short-circuits the checks
    // behind it. The certificate's own one reaches all of them.
    let _ = certificate.is_usable(certificate.subject_cn.as_deref().unwrap_or_default());
    let _ = certificate.detail_fields();
    let _ = certificate.user_identity();

    let _ = format!("{certificate:?}"); // Debug printing also reads every field.
}
