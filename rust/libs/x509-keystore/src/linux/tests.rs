//! Tests for the PKCS#11 backend, including its calls into a token.
//!
//! The tests that reach into a token run against SoftHSM, loaded directly rather than found
//! through the p11-kit registration a deployment goes through. Each of them initialises its own
//! token below a temporary directory that `SOFTHSM2_CONF` names, so they never touch a
//! developer's real token store and cannot collide with one another.

use std::{
    fs,
    os::unix::fs::PermissionsExt as _,
    path::{Path, PathBuf},
    sync::{Mutex, MutexGuard, PoisonError},
};

use cryptoki::{slot::Slot, types::Ulong};
use ring::signature::{
    ECDSA_P256_SHA256_ASN1, RSA_PKCS1_2048_8192_SHA256, RSA_PKCS1_2048_8192_SHA384,
    RSA_PKCS1_2048_8192_SHA512, RSA_PSS_2048_8192_SHA256, RSA_PSS_2048_8192_SHA384,
    RSA_PSS_2048_8192_SHA512, UnparsedPublicKey, VerificationAlgorithm,
};
use rustls::SignatureAlgorithm;
use secrecy::ExposeSecret as _;
use x509_parser::prelude::{FromDer as _, X509Certificate};

use super::*;
use crate::sign::{der_encode_ecdsa_signature, der_integer, encode_der_length};

#[test]
fn an_unloadable_module_is_no_identity_rather_than_an_error() {
    let modules = [PathBuf::from("/nonexistent/example-pkcs11.so")];
    let pin_file = Path::new("/nonexistent/pkcs11-pin");

    let identity = identity_on(&modules, pin_file, "dev.firezone.device-trust")
        .expect("an unreadable keystore is a machine without one, not an error");
    assert!(identity.is_none());

    let status = status_on(&modules, pin_file, "dev.firezone.device-trust")
        .expect("an unreadable keystore is a machine without one, not an error");
    let warning = status
        .warning
        .as_deref()
        .expect("an unreadable keystore should be warned about");
    assert!(
        warning.contains("PKCS#11 keystore cannot be read"),
        "{warning}"
    );
    let section = section(&status, "PKCS#11 Module");
    assert_eq!(
        field_value(section, "Module Path"),
        Some("/nonexistent/example-pkcs11.so")
    );
    assert!(
        field_value(section, "Error").is_some_and(|error| error.contains("Failed to load")),
        "the diagnostics should carry the error chain"
    );
}

#[test]
fn reads_the_module_a_configuration_file_names() {
    let directories = [
        PathBuf::from("/usr/lib64/pkcs11"),
        PathBuf::from("/usr/lib/pkcs11"),
    ];
    let installed = |module: &Path| module == Path::new("/usr/lib/pkcs11/opensc-pkcs11.so");

    let resolved = configured_module(
        "# The OpenSC driver.\nmodule: opensc-pkcs11.so\ndisable-in: p11-kit-proxy\n",
        &directories,
        &installed,
    );

    assert_eq!(
        resolved,
        Some(PathBuf::from("/usr/lib/pkcs11/opensc-pkcs11.so")),
        "a relative module resolves against the directory that holds it, and `disable-in` \
         only disables a module for the proxy, which we are not"
    );
}

#[test]
fn an_absolute_module_is_loaded_from_where_the_configuration_says() {
    let resolved = configured_module(
        "module: /opt/example/example-pkcs11.so\n",
        &[PathBuf::from("/usr/lib64/pkcs11")],
        &|_: &Path| false,
    );

    assert_eq!(
        resolved,
        Some(PathBuf::from("/opt/example/example-pkcs11.so"))
    );
}

#[test]
fn registered_modules_are_deduplicated_by_resolved_path() {
    let directories = [PathBuf::from("/usr/lib64/pkcs11")];
    let files = [
        "module: libsofthsm2.so\n".to_owned(),
        "module: /usr/lib64/pkcs11/libsofthsm2.so\n".to_owned(),
        "trust-policy: yes\n".to_owned(),
        "module: p11-kit-trust.so\ndisable-in: p11-kit-proxy\n".to_owned(),
    ];

    let modules = configured_modules(files, &directories, &|_: &Path| false);

    assert_eq!(
        modules,
        [
            // A module that is nowhere keeps the most preferred guess, so its load failure
            // names the path the configuration meant.
            PathBuf::from("/usr/lib64/pkcs11/libsofthsm2.so"),
            PathBuf::from("/usr/lib64/pkcs11/p11-kit-trust.so"),
        ],
        "one file without a `module:` line and one duplicate should be dropped"
    );
}

#[test]
#[ignore = "Requires the SoftHSM PKCS#11 module and writes to a temporary token store"]
fn signs_with_the_token_key_of_an_rsa_certificate() {
    let _serialized = serialize_token_access();
    let token = provision_token("rsa", KeyAlgorithm::Rsa);

    let identity = token
        .identity()
        .expect("the SoftHSM token should be readable")
        .expect("the provisioned certificate should be selected as the client identity");

    assert_eq!(leaf_of(&identity), token.certificate);
    assert_eq!(identity.key.algorithm(), SignatureAlgorithm::RSA);
    assert_signs_every_advertised_scheme(&identity, &token.certificate);
}

#[test]
#[ignore = "Requires the SoftHSM PKCS#11 module and writes to a temporary token store"]
fn signs_with_the_token_key_of_an_ecdsa_certificate() {
    let _serialized = serialize_token_access();
    let token = provision_token("ecdsa", KeyAlgorithm::EcdsaP256);

    let identity = token
        .identity()
        .expect("the SoftHSM token should be readable")
        .expect("the provisioned certificate should be selected as the client identity");

    assert_eq!(leaf_of(&identity), token.certificate);
    assert_eq!(identity.key.algorithm(), SignatureAlgorithm::ECDSA);
    assert_eq!(
        identity.key.supported_schemes(),
        vec![SignatureScheme::ECDSA_NISTP256_SHA256]
    );
    assert_signs_every_advertised_scheme(&identity, &token.certificate);
}

#[test]
#[ignore = "Requires the SoftHSM PKCS#11 module and writes to a temporary token store"]
fn describes_a_provisioned_certificate_in_the_diagnostics() {
    let _serialized = serialize_token_access();
    let token = provision_token("status", KeyAlgorithm::Rsa);

    let status = token
        .status()
        .expect("the SoftHSM token should be readable");

    assert_eq!(status.warning, None);
    let certificate = section(&status, "Certificate");
    assert_eq!(
        field_value(certificate, "Object Label"),
        Some(token.label.as_str())
    );
    assert_eq!(
        field_value(certificate, "Private Key Access"),
        Some("Available")
    );
    assert_eq!(
        field_value(certificate, "Usable With Its Private Key"),
        Some("Yes")
    );
    assert_eq!(
        field_value(certificate, "Common Name"),
        Some(token.subject_cn.as_str())
    );
    assert_eq!(
        field_value(certificate, "Signing Algorithm"),
        Some("SHA256withRSA")
    );
    assert!(
        position(certificate, "SHA-256 Fingerprint") < position(certificate, "Object Label"),
        "what the certificate says should read before where the token keeps it"
    );
}

#[test]
#[ignore = "Requires the SoftHSM PKCS#11 module and writes to a temporary token store"]
fn reports_no_identity_when_no_certificate_matches() {
    let _serialized = serialize_token_access();
    let token = provision_token("absent", KeyAlgorithm::Rsa);
    let subject_cn = unique_subject_cn("absent-other");

    let identity = token
        .identity_of(&subject_cn)
        .expect("the SoftHSM token should be readable");
    let status = token
        .status_of(&subject_cn)
        .expect("the SoftHSM token should be readable");

    assert!(identity.is_none());
    assert_eq!(
        status.warning,
        Some(format!(
            "No PKCS#11 token holds an X.509 certificate with subject CN '{subject_cn}'."
        ))
    );
}

#[test]
#[ignore = "Requires the SoftHSM PKCS#11 module and writes to a temporary token store"]
fn signs_after_a_second_session_read_the_token() {
    let _serialized = serialize_token_access();
    let token = provision_token("overlapping", KeyAlgorithm::Rsa);

    let identity = token
        .identity()
        .expect("the SoftHSM token should be readable")
        .expect("the provisioned certificate should be selected as the client identity");
    // Stands in for the diagnostics screen, which opens and closes its own session on the token
    // the identity holds one on.
    token
        .status()
        .expect("the token should be readable while an identity holds a session on it");

    identity
        .key
        .sign(SignatureScheme::RSA_PKCS1_SHA256, MESSAGE)
        .expect("the token should still sign for the identity it unlocked");
}

/// Proves that the session an identity holds still satisfies the bounds rustls puts on a signer.
#[test]
fn the_key_can_be_shared_across_threads() {
    fn assert_send_and_sync<T: Send + Sync>() {}

    assert_send_and_sync::<Pkcs11Key>();
}

#[test]
#[ignore = "Requires the SoftHSM PKCS#11 module and writes to a temporary token store"]
fn refuses_an_identity_whose_token_it_cannot_unlock() {
    let _serialized = serialize_token_access();
    let token = provision_token("no-pin", KeyAlgorithm::Rsa);
    fs::remove_file(&token.pin_file).expect("the PIN file should be removable");

    let Err(refused) = token.identity() else {
        panic!("a token that wants a PIN it cannot read should not yield an identity");
    };

    assert!(
        format!("{refused:#}").contains(&token.pin_file.display().to_string()),
        "{refused:#} should name the PIN file it could not read"
    );
}

#[test]
#[ignore = "Requires the SoftHSM PKCS#11 module and writes to a temporary token store"]
fn refuses_an_identity_whose_pin_the_token_rejects() {
    let _serialized = serialize_token_access();
    let token = provision_token("wrong-pin", KeyAlgorithm::Rsa);
    write_pin_file(&token.pin_file, "not-the-pin");

    let Err(refused) = token.identity() else {
        panic!("a token that rejects the PIN should not yield an identity");
    };

    assert!(
        format!("{refused:#}").contains("Failed to unlock the PKCS#11 token"),
        "{refused:#} should say the token turned the PIN down"
    );
}

#[test]
fn reads_no_pin_for_a_token_that_wants_none() {
    let flags = LoginFlags {
        login_required: false,
        ..pin_protected()
    };

    assert!(matches!(
        login_requirement(flags).expect("a token without a login is usable"),
        Login::NotRequired
    ));
}

#[test]
fn refuses_a_token_that_asks_for_its_pin_on_a_keypad() {
    let flags = LoginFlags {
        protected_authentication_path: true,
        ..pin_protected()
    };

    let refused = login_requirement(flags).expect_err("Firezone prompts nobody for a PIN");

    assert!(
        refused.to_string().contains("keypad"),
        "{refused} should say why the reader cannot be used"
    );
}

#[test]
fn refuses_a_token_that_already_locked_its_pin() {
    let flags = LoginFlags {
        user_pin_locked: true,
        ..pin_protected()
    };

    let refused = login_requirement(flags).expect_err("a locked PIN cannot be spent again");

    assert!(
        refused.to_string().contains("PUK"),
        "{refused} should say how the token is unblocked"
    );
}

#[test]
fn counts_down_the_attempts_a_rejected_pin_leaves() {
    let final_try = rejected_pin_reason(LoginFlags {
        user_pin_final_try: true,
        ..pin_protected()
    });
    let count_low = rejected_pin_reason(LoginFlags {
        user_pin_count_low: true,
        ..pin_protected()
    });

    assert!(final_try.contains("one attempt left"), "{final_try}");
    assert!(count_low.contains("counting down"), "{count_low}");
}

#[test]
fn probes_the_64_bit_module_directory_before_the_32_bit_one() {
    let directories = module_directories(vec![PathBuf::from("/usr/lib/x86_64-linux-gnu")]);

    let position = |path: &str| {
        directories
            .iter()
            .position(|directory| directory == Path::new(path))
            .unwrap_or_else(|| panic!("{path} should be probed"))
    };

    assert!(
        position("/usr/lib64/pkcs11") < position("/usr/lib/pkcs11"),
        "an i686 package puts 32-bit modules into /usr/lib, which must not shadow /usr/lib64"
    );
    assert!(
        position("/usr/lib/x86_64-linux-gnu/pkcs11") < position("/usr/lib/pkcs11"),
        "the multiarch directory is where Debian installs modules"
    );
}

#[test]
fn refuses_a_pin_file_others_can_read() {
    let refused = ensure_root_only(0o640, 0, Path::new("/etc/firezone/pkcs11-pin"))
        .expect_err("a group-readable PIN file should be refused");

    assert!(
        refused.to_string().contains("Permissions 0640"),
        "{refused} should report the mode the way ssh does"
    );
}

#[test]
fn refuses_a_pin_file_root_does_not_own() {
    assert!(ensure_root_only(0o600, 1000, Path::new("/etc/firezone/pkcs11-pin")).is_err());
    assert!(ensure_root_only(0o600, 0, Path::new("/etc/firezone/pkcs11-pin")).is_ok());
    assert!(ensure_root_only(0o400, 0, Path::new("/etc/firezone/pkcs11-pin")).is_ok());
}

#[test]
fn strips_only_the_line_ending_of_a_pin() {
    let directory = std::env::temp_dir().join(format!("keystore-pin-{}", std::process::id()));
    fs::create_dir_all(&directory).expect("the PIN directory should be creatable");
    let path = directory.join("pin");
    write_pin_file(&path, " space \r\n");

    let pin = read_pin(&path).expect("the PIN file should be readable");

    assert_eq!(pin.expose_secret(), " space ");

    fs::remove_dir_all(&directory).expect("the PIN directory should be removable");
}

#[test]
fn names_the_cause_behind_a_token_failure() {
    assert!(matches!(
        classify_return_value(RvError::DeviceRemoved, String::new()),
        SigningError::KeyUnavailable(_)
    ));
    assert!(matches!(
        classify_return_value(RvError::SessionHandleInvalid, String::new()),
        SigningError::KeyUnavailable(_)
    ));
    assert!(matches!(
        classify_return_value(RvError::PinLocked, String::new()),
        SigningError::AccessDenied(_)
    ));
    assert!(matches!(
        classify_return_value(RvError::DeviceError, String::new()),
        SigningError::Keystore(_)
    ));
}

/// Returns the flags of a token that wants a PIN and has all of its attempts left.
fn pin_protected() -> LoginFlags {
    LoginFlags {
        login_required: true,
        protected_authentication_path: false,
        user_pin_locked: false,
        user_pin_final_try: false,
        user_pin_count_low: false,
    }
}

/// The bytes the tests ask the token to sign, standing in for a TLS handshake transcript.
const MESSAGE: &[u8] = b"x509-keystore PKCS#11 signing test";

/// The PIN the tests give the token, both for its security officer and for its user.
const PIN: &str = "firezone-test-pin";

/// Serialises the tests, which all point `SOFTHSM2_CONF` at their own temporary token store.
///
/// That variable is process-wide and SoftHSM reads it while the backend loads the module, so two
/// tests running at once would each see whichever store the other set up last.
static TOKEN_STORE: Mutex<()> = Mutex::new(());

/// Takes the [`TOKEN_STORE`] lock for the rest of the current test.
///
/// Poisoning is ignored on purpose: one failing test would otherwise fail the others rather than
/// let them report their own result.
fn serialize_token_access() -> MutexGuard<'static, ()> {
    TOKEN_STORE.lock().unwrap_or_else(PoisonError::into_inner)
}

/// Returns a subject CN that no other test uses.
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

/// Returns the diagnostics section titled `title`.
fn section<'a>(status: &'a Status, title: &str) -> &'a DetailSection {
    status
        .sections
        .iter()
        .find(|section| section.title == title)
        .unwrap_or_else(|| panic!("the diagnostics should have a '{title}' section"))
}

/// Returns the position of the diagnostics row labelled `label` in the section.
fn position(section: &DetailSection, label: &str) -> usize {
    section
        .fields
        .iter()
        .position(|field| field.label == label)
        .unwrap_or_else(|| panic!("the diagnostics should show {label}"))
}

/// Returns the value of the diagnostics row labelled `label`, if the section has one.
fn field_value<'a>(section: &'a DetailSection, label: &str) -> Option<&'a str> {
    let field = section.fields.iter().find(|field| field.label == label)?;

    Some(field.value.text())
}

/// Signs [`MESSAGE`] with every scheme the key advertises and verifies each signature against the
/// public key of the certificate it belongs to.
///
/// Verifying is what separates a signature that is merely well-formed from one a TLS peer accepts:
/// the padding mode, the hash, the PSS salt length and, for ECDSA, the DER encoding all have to
/// match the scheme rustls asked for. Covering every advertised scheme holds the backend to what it
/// promised rustls it could do.
fn assert_signs_every_advertised_scheme(identity: &Identity, certificate: &[u8]) {
    let (_, parsed) =
        X509Certificate::from_der(certificate).expect("the provisioned certificate should parse");
    let public_key = parsed.public_key().subject_public_key.data.as_ref();

    for scheme in identity.key.supported_schemes() {
        let signature = identity
            .key
            .sign(scheme, MESSAGE)
            .unwrap_or_else(|error| panic!("the token should sign with {scheme:?}: {error}"));

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

/// A SoftHSM token holding one key and the certificate that names it, erased when the test ends.
struct Token {
    directory: PathBuf,
    label: String,
    subject_cn: String,
    module: PathBuf,
    pin_file: PathBuf,
    certificate: Vec<u8>,
}

impl Token {
    fn identity(&self) -> Result<Option<Identity>> {
        self.identity_of(&self.subject_cn)
    }

    fn identity_of(&self, subject_cn: &str) -> Result<Option<Identity>> {
        super::identity_on(
            std::slice::from_ref(&self.module),
            &self.pin_file,
            subject_cn,
        )
    }

    fn status(&self) -> Result<Status> {
        self.status_of(&self.subject_cn)
    }

    fn status_of(&self, subject_cn: &str) -> Result<Status> {
        super::status_on(
            std::slice::from_ref(&self.module),
            &self.pin_file,
            subject_cn,
        )
    }
}

impl Drop for Token {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.directory);
    }
}

/// The key algorithms whose signatures take different paths through [`sign_with_key`].
#[derive(Clone, Copy)]
enum KeyAlgorithm {
    Rsa,
    EcdsaP256,
}

/// Initialises a token that holds one key pair and a certificate satisfying Firezone's rules.
///
/// The key never leaves the token: it is generated there and the certificate is built around the
/// public half the token reports, which is how a real PKCS#11 device is enrolled.
fn provision_token(suffix: &str, algorithm: KeyAlgorithm) -> Token {
    let module = softhsm_module();
    let label = format!("keystore-{}-{suffix}", std::process::id());
    let subject_cn = unique_subject_cn(suffix);
    let directory = std::env::temp_dir().join(&label);
    let configuration = directory.join("softhsm2.conf");
    let pin_file = directory.join("pin");

    let _ = fs::remove_dir_all(&directory);
    fs::create_dir_all(directory.join("tokens")).expect("the token store should be creatable");
    fs::write(
        &configuration,
        format!(
            "directories.tokendir = {}\nobjectstore.backend = file\n",
            directory.join("tokens").display()
        ),
    )
    .expect("the SoftHSM configuration should be writable");
    write_pin_file(&pin_file, PIN);

    // SAFETY: `serialize_token_access` holds off every other test that sets or reads this variable,
    // and the remaining tests in this binary are pure functions that never touch the environment.
    unsafe { std::env::set_var("SOFTHSM2_CONF", &configuration) };
    unload_module();

    let certificate = initialize_token(&module, &label, &subject_cn, algorithm);

    Token {
        directory,
        label,
        subject_cn,
        module,
        pin_file,
        certificate,
    }
}

/// Writes a PIN file the backend accepts, which means one only its owner can read.
///
/// The tests run as root, both here and in CI, so the file is root's as the backend demands.
fn write_pin_file(path: &Path, pin: &str) {
    fs::write(path, pin).expect("the PIN file should be writable");
    fs::set_permissions(path, fs::Permissions::from_mode(0o600))
        .expect("the PIN file should be lockable down");
}

/// Returns the SoftHSM module the tests load.
///
/// A missing module fails the test rather than skipping it: a skipped test reports coverage the run
/// does not have.
fn softhsm_module() -> PathBuf {
    const CANDIDATES: [&str; 2] = [
        "/usr/lib/softhsm/libsofthsm2.so",
        "/usr/lib/x86_64-linux-gnu/softhsm/libsofthsm2.so",
    ];

    CANDIDATES
        .into_iter()
        .map(PathBuf::from)
        .find(|candidate| candidate.exists())
        .unwrap_or_else(|| {
            panic!("None of {CANDIDATES:?} exist; install the `softhsm2` package to run this test")
        })
}

/// Drops the contexts the backend cached, which unloads the module along with the last of them.
///
/// SoftHSM reads `SOFTHSM2_CONF` while it initializes, so a context left over from an earlier test
/// would keep answering out of that test's token store. Unloading is also what lets the setup below
/// initialize the module itself.
fn unload_module() {
    CONTEXTS
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .clear();
}

/// Sets up the token's PINs, generates its key pair and stores a certificate for it.
///
/// Returns the certificate, having closed everything it opened, so that the module is unloaded
/// again by the time the backend initializes its own context against this store.
fn initialize_token(
    module: &Path,
    label: &str,
    subject_cn: &str,
    algorithm: KeyAlgorithm,
) -> Vec<u8> {
    let pkcs11 = Pkcs11::new(module).expect("SoftHSM should load");
    pkcs11
        .initialize(CInitializeArgs::new(CInitializeFlags::OS_LOCKING_OK))
        .expect("SoftHSM should initialize");

    let free = *pkcs11
        .get_all_slots()
        .expect("SoftHSM should report its slots")
        .first()
        .expect("a fresh token store should offer an uninitialized slot");
    pkcs11
        .init_token(free, &AuthPin::new(PIN.into()), label)
        .expect("SoftHSM should initialize the token");

    let slot = slot_of(&pkcs11, label);
    let session = pkcs11
        .open_rw_session(slot)
        .expect("the token should open a read-write session");
    session
        .login(UserType::So, Some(&AuthPin::new(PIN.into())))
        .expect("the security officer should be able to log in");
    session
        .init_pin(&AuthPin::new(PIN.into()))
        .expect("the security officer should be able to set the user PIN");
    session
        .logout()
        .expect("the security officer should log out");
    session
        .login(UserType::User, Some(&AuthPin::new(PIN.into())))
        .expect("the user should be able to log in");

    let certificate = store_identity(&session, label, subject_cn, algorithm);

    drop(session);

    certificate
}

/// Returns the slot of the token labelled `label`.
fn slot_of(pkcs11: &Pkcs11, label: &str) -> Slot {
    pkcs11
        .get_slots_with_token()
        .expect("SoftHSM should report its tokens")
        .into_iter()
        .find(|slot| {
            pkcs11
                .get_token_info(*slot)
                .is_ok_and(|info| info.label().trim() == label)
        })
        .unwrap_or_else(|| panic!("the token labelled '{label}' should be in a slot"))
}

/// Generates the key pair on the token and stores a certificate that addresses it.
fn store_identity(
    session: &Session,
    label: &str,
    subject_cn: &str,
    algorithm: KeyAlgorithm,
) -> Vec<u8> {
    let id = vec![0x01];
    let (public, private) = generate_key_pair(session, label, &id, algorithm);
    let public_key = read_public_key(session, public, algorithm);
    let certificate = self_signed_certificate(subject_cn, &public_key, |tbs| {
        sign_certificate(session, private, algorithm, tbs)
    });

    session
        .create_object(&[
            Attribute::Class(ObjectClass::CERTIFICATE),
            Attribute::CertificateType(CertificateType::X_509),
            Attribute::Token(true),
            Attribute::Label(label.as_bytes().to_vec()),
            Attribute::Id(id),
            Attribute::Subject(distinguished_name(subject_cn)),
            Attribute::Value(certificate.clone()),
        ])
        .expect("the token should store the certificate");

    certificate
}

fn generate_key_pair(
    session: &Session,
    label: &str,
    id: &[u8],
    algorithm: KeyAlgorithm,
) -> (ObjectHandle, ObjectHandle) {
    let mut public_template = vec![
        Attribute::Token(true),
        Attribute::Verify(true),
        Attribute::Label(label.as_bytes().to_vec()),
        Attribute::Id(id.to_vec()),
    ];
    let private_template = vec![
        Attribute::Token(true),
        Attribute::Private(true),
        Attribute::Sign(true),
        Attribute::Label(label.as_bytes().to_vec()),
        Attribute::Id(id.to_vec()),
    ];
    let mechanism = match algorithm {
        KeyAlgorithm::Rsa => {
            public_template.push(Attribute::ModulusBits(Ulong::new(2048)));
            public_template.push(Attribute::PublicExponent(vec![0x01, 0x00, 0x01]));

            Mechanism::RsaPkcsKeyPairGen
        }
        KeyAlgorithm::EcdsaP256 => {
            public_template.push(Attribute::EcParams(object_identifier(OID_PRIME256V1)));

            Mechanism::EccKeyPairGen
        }
    };

    session
        .generate_key_pair(&mechanism, &public_template, &private_template)
        .expect("the token should generate the key pair")
}

/// The public half of a generated key pair, as the token reports it.
enum PublicKey {
    Rsa { modulus: Vec<u8>, exponent: Vec<u8> },
    EcdsaP256 { point: Vec<u8> },
}

fn read_public_key(session: &Session, key: ObjectHandle, algorithm: KeyAlgorithm) -> PublicKey {
    match algorithm {
        KeyAlgorithm::Rsa => PublicKey::Rsa {
            modulus: byte_attribute(session, key, AttributeType::Modulus),
            exponent: byte_attribute(session, key, AttributeType::PublicExponent),
        },
        KeyAlgorithm::EcdsaP256 => PublicKey::EcdsaP256 {
            point: uncompressed_point(&byte_attribute(session, key, AttributeType::EcPoint)),
        },
    }
}

fn byte_attribute(session: &Session, key: ObjectHandle, attribute: AttributeType) -> Vec<u8> {
    let reported = session
        .get_attributes(key, &[attribute])
        .unwrap_or_else(|error| panic!("the token should report {attribute:?}: {error}"));

    match reported.as_slice() {
        [
            Attribute::Modulus(value)
            | Attribute::PublicExponent(value)
            | Attribute::EcPoint(value),
        ] => value.clone(),
        reported => panic!("the token reported {reported:?} instead of {attribute:?}"),
    }
}

/// Unwraps the DER octet string PKCS#11 puts around the uncompressed EC point.
fn uncompressed_point(attribute: &[u8]) -> Vec<u8> {
    let [0x04, length, point @ ..] = attribute else {
        panic!("the token should report the EC point as a DER octet string");
    };
    assert_eq!(
        usize::from(*length),
        point.len(),
        "the EC point should be as long as its DER header says"
    );

    point.to_vec()
}

fn sign_certificate(
    session: &Session,
    key: ObjectHandle,
    algorithm: KeyAlgorithm,
    tbs_certificate: &[u8],
) -> Vec<u8> {
    match algorithm {
        KeyAlgorithm::Rsa => session
            .sign(&Mechanism::Sha256RsaPkcs, key, tbs_certificate)
            .expect("the token should sign the certificate"),
        KeyAlgorithm::EcdsaP256 => {
            let raw = session
                .sign(&Mechanism::Ecdsa, key, &Sha256::digest(tbs_certificate))
                .expect("the token should sign the certificate");

            der_encode_ecdsa_signature(&raw).expect("the token's signature should encode")
        }
    }
}

/// `2.5.4.3`, the common name attribute.
const OID_COMMON_NAME: &[u8] = &[0x55, 0x04, 0x03];
/// `2.5.29.15`, the key usage extension.
const OID_KEY_USAGE: &[u8] = &[0x55, 0x1d, 0x0f];
/// `2.5.29.37`, the extended key usage extension.
const OID_EXTENDED_KEY_USAGE: &[u8] = &[0x55, 0x1d, 0x25];
/// `1.3.6.1.5.5.7.3.2`, the TLS client authentication purpose.
const OID_CLIENT_AUTH: &[u8] = &[0x2b, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x02];
/// `1.2.840.113549.1.1.1`, an RSA public key.
const OID_RSA_ENCRYPTION: &[u8] = &[0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01];
/// `1.2.840.113549.1.1.11`, an RSA signature over a SHA-256 digest.
const OID_SHA256_WITH_RSA: &[u8] = &[0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x0b];
/// `1.2.840.10045.2.1`, an elliptic curve public key.
const OID_EC_PUBLIC_KEY: &[u8] = &[0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01];
/// `1.2.840.10045.3.1.7`, the NIST P-256 curve.
const OID_PRIME256V1: &[u8] = &[0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07];
/// `1.2.840.10045.4.3.2`, an ECDSA signature over a SHA-256 digest.
const OID_ECDSA_WITH_SHA256: &[u8] = &[0x2a, 0x86, 0x48, 0xce, 0x3d, 0x04, 0x03, 0x02];

/// The validity the tests give their certificates, wide enough to never need a clock.
const NOT_BEFORE: &[u8] = b"200101000000Z";
const NOT_AFTER: &[u8] = b"491231235959Z";

/// Builds the certificate the token stores for `public_key`, signed by `sign`.
///
/// It carries the client authentication purpose, a key usage allowing digital signatures and a
/// subject CN, which is what [`ParsedCertificate::is_usable`] asks of a client identity.
fn self_signed_certificate(
    subject_cn: &str,
    public_key: &PublicKey,
    sign: impl FnOnce(&[u8]) -> Vec<u8>,
) -> Vec<u8> {
    let algorithm = signature_algorithm(public_key);
    let name = distinguished_name(subject_cn);
    let tbs_certificate = sequence(&[
        &der(0xa0, &der(0x02, &[2])), // Version v3.
        &der(0x02, &[1]),             // Serial number.
        &algorithm,
        &name,
        &sequence(&[&der(0x17, NOT_BEFORE), &der(0x17, NOT_AFTER)]),
        &name,
        &subject_public_key_info(public_key),
        &der(0xa3, &sequence(&[&key_usage(), &extended_key_usage()])),
    ]);
    let signature = sign(&tbs_certificate);

    sequence(&[&tbs_certificate, &algorithm, &bit_string(&signature)])
}

fn signature_algorithm(public_key: &PublicKey) -> Vec<u8> {
    match public_key {
        PublicKey::Rsa { .. } => sequence(&[
            &object_identifier(OID_SHA256_WITH_RSA),
            &der(0x05, &[]), // The NULL parameters RFC 4055 requires of RSA.
        ]),
        PublicKey::EcdsaP256 { .. } => sequence(&[&object_identifier(OID_ECDSA_WITH_SHA256)]),
    }
}

fn subject_public_key_info(public_key: &PublicKey) -> Vec<u8> {
    match public_key {
        PublicKey::Rsa { modulus, exponent } => sequence(&[
            &sequence(&[&object_identifier(OID_RSA_ENCRYPTION), &der(0x05, &[])]),
            &bit_string(&sequence(&[&der_integer(modulus), &der_integer(exponent)])),
        ]),
        PublicKey::EcdsaP256 { point } => sequence(&[
            &sequence(&[
                &object_identifier(OID_EC_PUBLIC_KEY),
                &object_identifier(OID_PRIME256V1),
            ]),
            &bit_string(point),
        ]),
    }
}

fn distinguished_name(common_name: &str) -> Vec<u8> {
    sequence(&[&der(
        0x31,
        &sequence(&[
            &object_identifier(OID_COMMON_NAME),
            &der(0x0c, common_name.as_bytes()),
        ]),
    )])
}

/// The critical key usage extension allowing only digital signatures.
fn key_usage() -> Vec<u8> {
    sequence(&[
        &object_identifier(OID_KEY_USAGE),
        &der(0x01, &[0xff]),
        &der(0x04, &der(0x03, &[7, 0x80])),
    ])
}

/// The extended key usage extension naming TLS client authentication.
fn extended_key_usage() -> Vec<u8> {
    sequence(&[
        &object_identifier(OID_EXTENDED_KEY_USAGE),
        &der(0x04, &sequence(&[&object_identifier(OID_CLIENT_AUTH)])),
    ])
}

/// Wraps `contents` in the DER tag-length-value of `tag`.
fn der(tag: u8, contents: &[u8]) -> Vec<u8> {
    let mut output = vec![tag];
    encode_der_length(&mut output, contents.len());
    output.extend_from_slice(contents);

    output
}

fn sequence(elements: &[&[u8]]) -> Vec<u8> {
    der(0x30, &elements.concat())
}

fn object_identifier(oid: &[u8]) -> Vec<u8> {
    der(0x06, oid)
}

fn bit_string(contents: &[u8]) -> Vec<u8> {
    let mut body = vec![0]; // No unused bits in the final byte.
    body.extend_from_slice(contents);

    der(0x03, &body)
}
