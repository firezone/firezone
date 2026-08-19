//! Tests for the Windows certificate-store backend, including its calls into CNG.
//!
//! The tests that reach into CNG mint their own certificate in `CurrentUser\My`, which needs no
//! administrator rights, and look it up by a subject CN that is unique to the test process. That
//! keeps them off whatever real certificate the machine holds.

use std::{
    process::Command,
    sync::{Mutex, MutexGuard, PoisonError},
};

use base64::{Engine as _, engine::general_purpose::STANDARD as BASE64_STANDARD};
use ring::signature::{
    ECDSA_P256_SHA256_ASN1, RSA_PKCS1_2048_8192_SHA256, RSA_PKCS1_2048_8192_SHA384,
    RSA_PKCS1_2048_8192_SHA512, RSA_PSS_2048_8192_SHA256, RSA_PSS_2048_8192_SHA384,
    RSA_PSS_2048_8192_SHA512, UnparsedPublicKey, VerificationAlgorithm,
};
use x509_parser::prelude::{FromDer as _, X509Certificate};

use super::*;

#[test]
#[ignore = "Requires Windows and writes to the CurrentUser certificate store"]
fn signs_with_the_cng_key_of_an_rsa_certificate() {
    let _serialized = serialize_certificate_store_access();
    let subject_cn = unique_subject_cn("rsa");
    let minted = mint_certificate(&subject_cn, KeyAlgorithm::Rsa);

    let identity = super::identity(&subject_cn)
        .expect("the Windows certificate stores should be readable")
        .expect("the minted certificate should be selected as the client identity");

    assert_eq!(leaf_of(&identity), minted.der);
    assert_eq!(identity.key.algorithm(), SignatureAlgorithm::RSA);
    assert_signs_every_advertised_scheme(&identity, &minted.der);
}

#[test]
#[ignore = "Requires Windows and writes to the CurrentUser certificate store"]
fn signs_with_the_cng_key_of_an_ecdsa_certificate() {
    let _serialized = serialize_certificate_store_access();
    let subject_cn = unique_subject_cn("ecdsa");
    let minted = mint_certificate(&subject_cn, KeyAlgorithm::EcdsaP256);

    let identity = super::identity(&subject_cn)
        .expect("the Windows certificate stores should be readable")
        .expect("the minted certificate should be selected as the client identity");

    assert_eq!(leaf_of(&identity), minted.der);
    assert_eq!(identity.key.algorithm(), SignatureAlgorithm::ECDSA);
    assert_eq!(
        identity.key.supported_schemes(),
        vec![SignatureScheme::ECDSA_NISTP256_SHA256]
    );
    assert_signs_every_advertised_scheme(&identity, &minted.der);
}

#[test]
#[ignore = "Requires Windows and writes to the CurrentUser certificate store"]
fn describes_a_minted_certificate_in_the_diagnostics() {
    let _serialized = serialize_certificate_store_access();
    let subject_cn = unique_subject_cn("status");
    let _minted = mint_certificate(&subject_cn, KeyAlgorithm::Rsa);

    let status =
        super::status(&subject_cn).expect("the Windows certificate stores should be readable");

    assert_eq!(
        status.summary,
        "1 X.509 client identity certificate(s) are available for mutual TLS."
    );
    let section = status
        .sections
        .iter()
        .find(|section| section.title == "Matching Certificate 1")
        .expect("the diagnostics should describe the minted certificate");
    assert_eq!(field_value(section, "Store"), Some("CurrentUser\\My"));
    assert_eq!(
        field_value(section, "Private Key Access"),
        Some("Available through Windows CNG")
    );
    assert_eq!(
        field_value(section, "Usable as a Client Identity"),
        Some("Yes")
    );
    assert_eq!(
        field_value(section, "Private Key Provider"),
        Some("Microsoft Software Key Storage Provider")
    );
    assert_eq!(
        field_value(section, "Private Key Storage"),
        Some("Software keystore")
    );
    assert_eq!(
        field_value(section, "Common Name"),
        Some(subject_cn.as_str())
    );
    assert_eq!(field_value(section, "Private Key Error"), None);
    assert_eq!(field_value(section, "Certificate Chain Error"), None);
    assert_eq!(field_value(section, "Private Key Metadata Errors"), None);
}

#[test]
#[ignore = "Requires Windows and reads the CurrentUser certificate store"]
fn reports_no_identity_when_no_certificate_matches() {
    let _serialized = serialize_certificate_store_access();
    let subject_cn = unique_subject_cn("absent");

    let identity =
        super::identity(&subject_cn).expect("the Windows certificate stores should be readable");
    let status =
        super::status(&subject_cn).expect("the Windows certificate stores should be readable");

    assert!(identity.is_none());
    assert_eq!(
        status.summary,
        format!(
            "No X.509 certificate with subject CN '{subject_cn}' is in the Windows certificate stores."
        )
    );
}

#[test]
fn classifies_windows_key_storage() {
    assert_eq!(
        classify_private_key_storage(Some("Microsoft Platform Crypto Provider"), None),
        "TPM (hardware-backed keystore)"
    );
    assert_eq!(
        classify_private_key_storage(Some("Microsoft Software Key Storage Provider"), None),
        "Software keystore"
    );
    assert_eq!(
        classify_private_key_storage(Some("Third-party KSP"), Some(NCRYPT_IMPL_HARDWARE_FLAG)),
        "Hardware-backed keystore"
    );
}

#[test]
fn names_the_cause_behind_a_cng_failure() {
    assert!(matches!(
        classify_signing_error(NTE_NO_KEY.into()),
        SigningError::KeyUnavailable(_)
    ));
    assert!(matches!(
        classify_signing_error(NTE_SILENT_CONTEXT.into()),
        SigningError::AccessDenied(_)
    ));
    assert!(matches!(
        classify_signing_error(SCARD_W_CANCELLED_BY_USER.into()),
        SigningError::AccessDenied(_)
    ));
    assert!(matches!(
        classify_signing_error(windows::Win32::Foundation::E_UNEXPECTED.into()),
        SigningError::Keystore(_)
    ));
}

#[test]
fn ecdsa_signature_is_der_encoded() {
    let mut raw = vec![0; 64];
    raw[31] = 1;
    raw[63] = 2;

    assert_eq!(
        der_encode_ecdsa_signature(&raw).expect("signature should encode"),
        vec![0x30, 0x06, 0x02, 0x01, 0x01, 0x02, 0x01, 0x02]
    );
}

/// The bytes the tests ask CNG to sign, standing in for a TLS handshake transcript.
const MESSAGE: &[u8] = b"x509-keystore Windows CNG signing test";

/// Serialises the tests, which all add to and remove from the shared `CurrentUser\My` store.
///
/// [`enumerate_store`] walks that store while a concurrent test mints or removes its own
/// certificate in it, which makes both what the walk observes and what PowerShell reports depend
/// on the timing of the other test.
static CERTIFICATE_STORE: Mutex<()> = Mutex::new(());

/// Takes the [`CERTIFICATE_STORE`] lock for the rest of the current test.
///
/// Poisoning is ignored on purpose: one failing test would otherwise fail the others rather than
/// let them report their own result.
fn serialize_certificate_store_access() -> MutexGuard<'static, ()> {
    CERTIFICATE_STORE
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
}

/// Returns a subject CN that no other test and no real certificate uses.
fn unique_subject_cn(suffix: &str) -> String {
    format!("dev.firezone.test-{}-{suffix}", std::process::id())
}

/// Returns the end-entity certificate the backend put first in the chain.
fn leaf_of(identity: &Identity) -> Vec<u8> {
    let leaf = identity
        .chain
        .first()
        .expect("the identity should carry a certificate chain");

    leaf.to_vec()
}

/// Returns the value of the diagnostics row labelled `label`, if the section has one.
fn field_value<'a>(section: &'a DetailSection, label: &str) -> Option<&'a str> {
    let field = section.fields.iter().find(|field| field.label == label)?;

    Some(field.value.as_str())
}

/// Signs [`MESSAGE`] with every scheme the key advertises and verifies each signature against the
/// public key of the certificate it belongs to.
///
/// Verifying is what separates a signature that is merely well-formed from one a TLS peer accepts:
/// the padding mode, the hash and, for ECDSA, the DER encoding all have to match the scheme rustls
/// asked for. Covering every advertised scheme holds the backend to what it promised rustls it
/// could do.
fn assert_signs_every_advertised_scheme(identity: &Identity, certificate: &[u8]) {
    let (_, parsed) =
        X509Certificate::from_der(certificate).expect("the minted certificate should parse");
    let public_key = parsed.public_key().subject_public_key.data.as_ref();

    for scheme in identity.key.supported_schemes() {
        let signature = identity
            .key
            .sign(scheme, MESSAGE)
            .unwrap_or_else(|error| panic!("CNG should sign with {scheme:?}: {error}"));

        UnparsedPublicKey::new(verification_algorithm(scheme), public_key)
            .verify(MESSAGE, &signature)
            .unwrap_or_else(|_| {
                panic!(
                    "the {scheme:?} signature should verify against the certificate's public key"
                )
            });
    }
}

/// Returns the `ring` algorithm that verifies signatures made with `scheme`.
#[expect(
    clippy::wildcard_enum_match_arm,
    reason = "the tests only ever ask for a scheme `signature_schemes` advertises"
)]
fn verification_algorithm(scheme: SignatureScheme) -> &'static dyn VerificationAlgorithm {
    match scheme {
        SignatureScheme::RSA_PSS_SHA256 => &RSA_PSS_2048_8192_SHA256,
        SignatureScheme::RSA_PSS_SHA384 => &RSA_PSS_2048_8192_SHA384,
        SignatureScheme::RSA_PSS_SHA512 => &RSA_PSS_2048_8192_SHA512,
        SignatureScheme::RSA_PKCS1_SHA256 => &RSA_PKCS1_2048_8192_SHA256,
        SignatureScheme::RSA_PKCS1_SHA384 => &RSA_PKCS1_2048_8192_SHA384,
        SignatureScheme::RSA_PKCS1_SHA512 => &RSA_PKCS1_2048_8192_SHA512,
        SignatureScheme::ECDSA_NISTP256_SHA256 => &ECDSA_P256_SHA256_ASN1,
        unexpected => panic!("no `ring` verifier for {unexpected:?}"),
    }
}

/// A certificate in `CurrentUser\My` that is removed again when the test ends.
struct MintedCertificate {
    thumbprint: String,
    der: Vec<u8>,
}

/// The key algorithms whose signatures take different paths through [`sign_with_certificate`].
enum KeyAlgorithm {
    Rsa,
    EcdsaP256,
}

/// Creates a certificate for `subject_cn` that satisfies Firezone's rules for a client identity.
fn mint_certificate(subject_cn: &str, algorithm: KeyAlgorithm) -> MintedCertificate {
    let output = powershell(&format!(
        "$ErrorActionPreference = 'Stop'; \
         $certificate = New-SelfSignedCertificate \
         -Type Custom \
         -Subject 'CN={subject_cn}' \
         -CertStoreLocation 'Cert:\\CurrentUser\\My' \
         -Provider 'Microsoft Software Key Storage Provider' \
         -KeyExportPolicy NonExportable \
         -KeyUsage DigitalSignature \
         -TextExtension @('2.5.29.37={{text}}1.3.6.1.5.5.7.3.2') \
         {}; \
         [Console]::Out.WriteLine($certificate.Thumbprint); \
         [Console]::Out.WriteLine([Convert]::ToBase64String($certificate.RawData))",
        algorithm.parameters()
    ))
    .unwrap_or_else(|error| panic!("PowerShell should mint a certificate: {error:#}"));

    let mut lines = output.lines();
    let thumbprint = lines
        .next()
        .expect("New-SelfSignedCertificate should report a thumbprint")
        .trim()
        .to_owned();
    let der = BASE64_STANDARD
        .decode(
            lines
                .next()
                .expect("New-SelfSignedCertificate should report the certificate")
                .trim(),
        )
        .expect("the certificate should be Base64");

    MintedCertificate { thumbprint, der }
}

impl KeyAlgorithm {
    /// Returns the `New-SelfSignedCertificate` arguments that select this algorithm.
    ///
    /// `CurveExport CurveName` makes the certificate name its curve by OID instead of spelling out
    /// the curve parameters, which is the encoding `x509-claims` reads the key algorithm from.
    fn parameters(&self) -> &'static str {
        match self {
            Self::Rsa => "-KeyAlgorithm RSA -KeyLength 2048",
            Self::EcdsaP256 => "-KeyAlgorithm ECDSA_nistP256 -CurveExport CurveName",
        }
    }
}

impl Drop for MintedCertificate {
    fn drop(&mut self) {
        let _ = powershell(&format!(
            "Remove-Item -Path 'Cert:\\CurrentUser\\My\\{}' -DeleteKey -Confirm:$false",
            self.thumbprint
        ));
    }
}

/// Runs `script` through Windows PowerShell and returns what it wrote to standard output.
fn powershell(script: &str) -> Result<String> {
    let output = Command::new("powershell")
        .args(["-NoProfile", "-NonInteractive", "-Command", script])
        .output()
        .context("Failed to run PowerShell")?;
    anyhow::ensure!(
        output.status.success(),
        "PowerShell exited with {}: {}",
        output.status,
        String::from_utf8_lossy(&output.stderr).trim()
    );
    let stdout = String::from_utf8_lossy(&output.stdout).into_owned();

    Ok(stdout)
}
