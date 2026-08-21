//! Micro-benchmarks for reading a client identity certificate.
//!
//! These exist for one question: can a hostile certificate push the work past roughly 1 ms?
//! That is the threshold at which a `rustler` NIF has to move off a normal BEAM scheduler
//! onto a dirty CPU one, and the portal is a candidate caller of this crate. Parsing happens
//! once per client connect and is dwarfed by the TLS handshake in front of it, so absolute
//! speed is not the point. The adversarial cases therefore spend the portal's own
//! `@max_cert_bytes` bound (16 KiB) on whatever the parser loops over the most.
//!
//! Every case is measured in three parts, because a caller would not need all of them:
//! `parse` is the parser itself, `claims` is what the portal reads off the result, and
//! `detail_fields` is the diagnostics table only the clients render.

use std::time::{Duration, SystemTime};

use rcgen::{
    CertificateParams, DnType, ExtendedKeyUsagePurpose, KeyPair, KeyUsagePurpose, SanType,
    SerialNumber, string::Ia5String,
};
use x509_claims::{ParsedCertificate, parse_certificate};

fn main() {
    divan::main()
}

/// The portal's `@max_cert_bytes`: the largest certificate that ever reaches the parser.
const MAX_CERT_BYTES: usize = 16_384;

/// The certificates we benchmark.
#[derive(Clone, Copy)]
enum Case {
    /// The certificate `mise-tasks/x509/gen-certificate.sh` issues.
    Typical,
    /// The cap spent on separately encoded, fully percent-encoded `firezone://` URI SANs,
    /// so every extractor decodes, lower-cases and re-splits as many values as possible.
    ManyUriSans,
    /// The cap spent on one Intune-style comma-joined URI SAN, the shape
    /// `split_comma_joined_uris` walks once per name and then once more per extracted value.
    CommaJoinedUris,
    /// The cap spent on distinguished name attributes, which a self-signed certificate
    /// carries as both its subject and its issuer, and the parser formats as both.
    ManyDnAttributes,
    /// The cap spent on the serial number, which RFC 5280 bounds to 20 octets but the
    /// parser accepts at any length and formats one byte at a time.
    LongSerial,
    /// The most expensive certificate with its signature cut off, so the parser walks
    /// everything before rejecting it.
    TruncatedSignature,
    /// Bytes that are not DER, rejected on the first tag.
    NotDer,
}

const CASES: [Case; 7] = [
    Case::Typical,
    Case::ManyUriSans,
    Case::CommaJoinedUris,
    Case::ManyDnAttributes,
    Case::LongSerial,
    Case::TruncatedSignature,
    Case::NotDer,
];

const ACCEPTED_CASES: [Case; 5] = [
    Case::Typical,
    Case::ManyUriSans,
    Case::CommaJoinedUris,
    Case::ManyDnAttributes,
    Case::LongSerial,
];

/// Turns DER into a [`ParsedCertificate`], the one entry point this crate has.
#[divan::bench(args = CASES)]
fn parse(bencher: divan::Bencher, case: Case) {
    let der = case.der();
    let now = now();

    bencher.bench_local(|| parse_certificate(divan::black_box(&der), now));
}

/// Reads the claims the portal acts on.
///
/// They are cloned because a caller across an FFI boundary has to copy them out; the
/// certificate is black-boxed inside the timed closure so the optimizer cannot hoist the
/// reads out of the loop.
#[divan::bench(args = ACCEPTED_CASES)]
fn claims(bencher: divan::Bencher, case: Case) {
    let certificate = case.parsed();

    bencher.bench_local(|| {
        let certificate = divan::black_box(&certificate);

        (
            divan::black_box(certificate.user_identity()),
            divan::black_box(certificate.actor_email.clone()),
            divan::black_box(certificate.account_id.clone()),
            divan::black_box(certificate.mdm_device_id.clone()),
            divan::black_box(certificate.device_serial.clone()),
        )
    });
}

/// Formats the label-value rows for the clients' diagnostics screens, which a portal caller
/// would discard.
///
/// The certificate is black-boxed inside the timed closure, see [`claims`].
#[divan::bench(args = ACCEPTED_CASES)]
fn detail_fields(bencher: divan::Bencher, case: Case) {
    let certificate = case.parsed();

    bencher.bench_local(|| divan::black_box(divan::black_box(&certificate).detail_fields()));
}

impl Case {
    fn parsed(self) -> ParsedCertificate {
        parse_certificate(&self.der(), now()).expect("case should be an accepted certificate")
    }

    fn der(self) -> Vec<u8> {
        match self {
            Case::Typical => typical(),
            Case::ManyUriSans => many_uri_sans(),
            Case::CommaJoinedUris => comma_joined_uris(),
            Case::ManyDnAttributes => many_dn_attributes(),
            Case::LongSerial => long_serial(),
            Case::TruncatedSignature => truncated_signature(),
            Case::NotDer => not_der(),
        }
    }
}

impl std::fmt::Display for Case {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let name = match self {
            Case::Typical => "typical",
            Case::ManyUriSans => "many_uri_sans",
            Case::CommaJoinedUris => "comma_joined_uris",
            Case::ManyDnAttributes => "many_dn_attributes",
            Case::LongSerial => "long_serial",
            Case::TruncatedSignature => "truncated_signature",
            Case::NotDer => "not_der",
        };

        f.write_str(name)
    }
}

fn typical() -> Vec<u8> {
    let uris = [
        "firezone://serial/C02XK1ZGJGH5",
        "firezone://email/alice@example.com",
        "firezone://account-id/5f2e7b7a-9d54-4bd2-9d4f-8f6c2a01f9d3",
    ];

    let mut params = client_params();
    params.subject_alt_names = uris.iter().map(|uri| uri_san(uri)).collect();

    self_signed(params)
}

fn many_uri_sans() -> Vec<u8> {
    largest_accepted(|count| {
        let mut params = client_params();
        params.subject_alt_names = (0..count)
            .map(|index| uri_san(&percent_encoded_firezone_uri(index)))
            .collect();

        self_signed(params)
    })
}

fn comma_joined_uris() -> Vec<u8> {
    largest_accepted(|count| {
        // Intune joins every configured SAN row into this one value, keeping the comma in
        // its own SID URI, so the parser cannot simply split on every comma.
        let joined = std::iter::once("tag:microsoft.com,2022-09-14:sid:S-1-12-1-1".to_owned())
            .chain((0..count).map(firezone_uri))
            .collect::<Vec<_>>()
            .join(", ");

        let mut params = client_params();
        params.subject_alt_names = vec![uri_san(&joined)];

        self_signed(params)
    })
}

fn many_dn_attributes() -> Vec<u8> {
    largest_accepted(|count| {
        let mut params = client_params();
        for index in 0..count {
            // Only an unused attribute type adds another attribute: `rcgen` keys the
            // distinguished name by type, and the parser prints unregistered ones as an OID.
            let oid = vec![2, 5, 4, 1000 + index as u64];

            params
                .distinguished_name
                .push(DnType::CustomDnType(oid), "firezone");
        }

        self_signed(params)
    })
}

fn long_serial() -> Vec<u8> {
    largest_accepted(|bytes| {
        let mut params = client_params();
        // A leading byte below 0x80 keeps the integer positive without a padding byte.
        params.serial_number = Some(SerialNumber::from_slice(&vec![0x7f; bytes]));

        self_signed(params)
    })
}

fn truncated_signature() -> Vec<u8> {
    // Shorter than any ECDSA P-256 signature, so what is left of the signature is always
    // less than its own header promises.
    const CUT_BYTES: usize = 64;

    let mut der = many_uri_sans();
    der.truncate(der.len() - CUT_BYTES);

    // Certificates this size carry their length in two bytes, which has to keep covering
    // the rest for the parser to walk past it.
    let (header, body) = der.split_at_mut(4);
    assert_eq!(
        header[..2],
        [0x30, 0x82],
        "certificate should be a long DER sequence"
    );
    let length = u16::try_from(body.len()).expect("certificate should stay under 64 KiB");
    header[2..4].copy_from_slice(&length.to_be_bytes());

    der
}

fn not_der() -> Vec<u8> {
    vec![0xff; MAX_CERT_BYTES]
}

/// Returns the largest certificate `build` can produce that the portal would still accept.
///
/// How many SANs, attributes or serial bytes fit into [`MAX_CERT_BYTES`] depends on how they
/// encode, so search for the count rather than hard-coding one that silently drifts.
fn largest_accepted(build: impl Fn(usize) -> Vec<u8>) -> Vec<u8> {
    let mut rejected = 1;
    while build(rejected).len() <= MAX_CERT_BYTES {
        rejected *= 2;
    }

    let mut accepted = rejected / 2;
    while rejected - accepted > 1 {
        let midpoint = accepted + (rejected - accepted) / 2;

        if build(midpoint).len() <= MAX_CERT_BYTES {
            accepted = midpoint;
        } else {
            rejected = midpoint;
        }
    }

    build(accepted)
}

/// Returns the parameters `mise-tasks/x509/gen-certificate.sh` issues a certificate with.
fn client_params() -> CertificateParams {
    let mut params = CertificateParams::default();
    params.key_usages = vec![
        KeyUsagePurpose::DigitalSignature,
        KeyUsagePurpose::KeyEncipherment,
    ];
    params.extended_key_usages = vec![ExtendedKeyUsagePurpose::ClientAuth];
    params
        .distinguished_name
        .push(DnType::OrganizationName, "Firezone");
    params
        .distinguished_name
        .push(DnType::CommonName, "dev.firezone.device-trust");

    params
}

fn self_signed(params: CertificateParams) -> Vec<u8> {
    let key = KeyPair::generate().expect("should generate a key pair");
    let certificate = params
        .self_signed(&key)
        .expect("should self-sign the certificate");

    certificate.der().to_vec()
}

/// The `firezone://` attributes the parser looks for.
///
/// A hostile certificate names all of them so that no extractor gets to skip a value.
#[derive(Clone, Copy)]
enum Attribute {
    Email,
    AccountId,
    Serial,
    IntuneId,
}

const ATTRIBUTES: [Attribute; 4] = [
    Attribute::Email,
    Attribute::AccountId,
    Attribute::Serial,
    Attribute::IntuneId,
];

fn firezone_uri(index: usize) -> String {
    let attribute = ATTRIBUTES[index % ATTRIBUTES.len()];

    format!("firezone://{}/{}", attribute.name(), attribute.value(index))
}

/// Returns the same URI with every byte of its value percent-encoded, the most expensive
/// spelling of a value that still decodes to something the parser keeps.
fn percent_encoded_firezone_uri(index: usize) -> String {
    let attribute = ATTRIBUTES[index % ATTRIBUTES.len()];
    let value = attribute
        .value(index)
        .bytes()
        .map(|byte| format!("%{byte:02X}"))
        .collect::<String>();

    format!("firezone://{}/{value}", attribute.name())
}

impl Attribute {
    fn name(self) -> &'static str {
        match self {
            Attribute::Email => "email",
            Attribute::AccountId => "account-id",
            Attribute::Serial => "serial",
            Attribute::IntuneId => "intune-id",
        }
    }

    /// Returns a value the extractors accept, distinct per `index` so that de-duplicating
    /// them has to compare rather than collapse.
    fn value(self, index: usize) -> String {
        match self {
            Attribute::Email => format!("alice{index}@example.com"),
            Attribute::AccountId => format!("5f2e7b7a-9d54-4bd2-9d4f-{index:012x}"),
            Attribute::Serial => format!("C02XK1ZGJGH{index}"),
            Attribute::IntuneId => format!("9d4f8f6c-2a01-f9d3-5f2e-{index:012x}"),
        }
    }
}

fn uri_san(uri: &str) -> SanType {
    SanType::URI(Ia5String::try_from(uri).expect("SAN URI should be an IA5 string"))
}

fn now() -> SystemTime {
    SystemTime::UNIX_EPOCH + Duration::from_secs(1_798_761_600)
}
