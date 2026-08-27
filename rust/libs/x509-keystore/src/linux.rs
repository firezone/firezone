//! X.509 client identities held by a PKCS#11 token.

#[cfg(test)]
mod tests;

use std::{
    collections::BTreeMap,
    fs::File,
    io::Read as _,
    os::unix::fs::MetadataExt as _,
    path::{Path, PathBuf},
    sync::{Arc, Mutex, PoisonError},
    time::SystemTime,
};

use anyhow::{Context as _, Result, bail};
use cryptoki::{
    context::{CInitializeArgs, CInitializeFlags, Pkcs11},
    error::RvError,
    mechanism::{
        Mechanism, MechanismType,
        rsa::{PkcsMgfType, PkcsPssParams},
    },
    object::{Attribute, AttributeType, CertificateType, KeyType, ObjectClass, ObjectHandle},
    session::{Session, UserType},
    slot::{Slot, TokenInfo},
    types::AuthPin,
};
use rustls::{SignatureScheme, pki_types::CertificateDer};
use sha2::{Digest as _, Sha256, Sha384, Sha512};
use x509_claims::{ParsedCertificate, SigningAlgorithm, parse_certificate};
use x509_credential::SigningError;

use crate::{
    CandidateCertificate, ClientIdentity, DetailField, DetailSection, Identity, Package, Problem,
    Status, UnusableCause, UnusableCertificate, field, join, selected_certificate, sign,
    unusable_certificates,
};

/// The directories p11-kit module configuration is read from, the administrator's first.
///
/// Whichever driver an administrator installed for their token registers itself here, so it is
/// reachable without Firezone being told about it.
const MODULE_CONFIGURATION_DIRECTORIES: [&str; 2] =
    ["/etc/pkcs11/modules", "/usr/share/p11-kit/modules"];

/// The file a token's PIN is read from.
const PIN_FILE: &str = "/etc/firezone/pkcs11-pin";

pub(crate) fn status(subject_cn: &str) -> Result<Status> {
    let modules = registered_modules();

    if modules.is_empty() {
        return Ok(Status {
            problems: vec![Problem::MissingPackage {
                package: Package::P11Kit,
            }],
            sections: Vec::new(),
            identity: ClientIdentity::Absent,
        });
    }

    status_on(&modules, Path::new(PIN_FILE), subject_cn)
}

pub(crate) fn identity(subject_cn: &str) -> Result<Option<Identity>> {
    // A machine with no PKCS#11 stack has nowhere to hold a client identity, which is how most
    // of them are set up rather than a misconfiguration. A token that does hold a certificate
    // and cannot sign with it still fails the connect.
    let modules = registered_modules();

    if modules.is_empty() {
        return Ok(None);
    }

    identity_on(&modules, Path::new(PIN_FILE), subject_cn)
}

fn status_on(modules: &[PathBuf], pin_file: &Path, subject_cn: &str) -> Result<Status> {
    let mut sections = Vec::new();
    let mut failures = 0;

    for module in modules {
        // A module that cannot be read leaves its tokens out of reach, the same as holding
        // none: it may be unloadable, as for a statically linked client, or fail to enumerate,
        // as when the service behind a driver is not running. One broken module must not hide
        // the tokens of the others.
        let found = match find_token(module, subject_cn) {
            Ok(found) => found,
            Err(error) => {
                tracing::debug!(module = %module.display(), "Skipping a PKCS#11 module: {error:#}");
                sections.push(module_section(module, &error));
                failures += 1;

                continue;
            }
        };

        let Some(candidate) = found else {
            continue;
        };

        let token = unlock_token(candidate, pin_file)?;

        return Ok(token_status(token));
    }

    // A machine whose every module failed has an unreadable keystore, not a missing
    // certificate, and which of the two the administrator reads decides what they fix.
    let problem = if failures == modules.len() {
        Problem::UnreadablePkcs11Keystore
    } else {
        Problem::NoPkcs11Certificate {
            subject_cn: subject_cn.to_owned(),
        }
    };

    Ok(Status {
        problems: vec![problem],
        sections,
        identity: ClientIdentity::Absent,
    })
}

/// The diagnostics for the token that holds a matching certificate.
fn token_status(token: Token) -> Status {
    let selected = selected_certificate(&token.certificates);

    let mut sections = Vec::new();
    sections.extend(selected.map(|index| DetailSection {
        title: "Certificate".to_owned(),
        fields: token.certificates[index].detail_fields(),
    }));
    sections.extend(
        token
            .certificates
            .iter()
            .enumerate()
            .filter(|(index, _)| Some(*index) != selected)
            .map(|(_, certificate)| DetailSection {
                title: "Unused Certificate".to_owned(),
                fields: certificate.detail_fields(),
            }),
    );

    let problem = selected
        .is_none()
        .then(|| Problem::NoUsablePkcs11Certificate {
            certificates: unusable_certificates(&token.certificates),
        });

    Status {
        problems: problem.into_iter().collect(),
        sections,
        identity: selected
            .map(|index| token.certificates[index].metadata.identity())
            .unwrap_or(ClientIdentity::Absent),
    }
}

/// The diagnostics section for a module that could not be read.
///
/// The error row shows only the short top-level cause: the raw loader and driver messages
/// behind it are long, and the log carries the full chain.
fn module_section(module: &Path, error: &anyhow::Error) -> DetailSection {
    let fields = vec![
        field("Module Path", module.display().to_string()),
        field("Error", error.to_string()),
    ];

    DetailSection {
        title: "PKCS#11 Module".to_owned(),
        fields,
    }
}

fn identity_on(modules: &[PathBuf], pin_file: &Path, subject_cn: &str) -> Result<Option<Identity>> {
    for module in modules {
        let candidate = match find_token(module, subject_cn) {
            Ok(Some(candidate)) => candidate,
            Ok(None) => continue,
            Err(error) => {
                tracing::debug!(module = %module.display(), "Skipping a PKCS#11 module: {error:#}");

                continue;
            }
        };

        // A matching token's verdict is final: a certificate that was provisioned for Firezone
        // and cannot be used fails the connect rather than falling through to another module.
        let identity = select_identity(candidate, pin_file)?;

        return Ok(Some(identity));
    }

    tracing::debug!("No PKCS#11 token holds a Firezone client identity");

    Ok(None)
}

/// Unlocks the candidate's token and selects the certificate it presents for mutual TLS.
fn select_identity(candidate: Candidate, pin_file: &Path) -> Result<Identity> {
    let Token {
        session,
        objects,
        mut certificates,
        ..
    } = unlock_token(candidate, pin_file)?;
    let unusable = unusable_certificates(&certificates);

    let Some(index) = selected_certificate(&certificates) else {
        // Skipping a certificate that was provisioned for Firezone reads to an administrator as if
        // none had been, so say which rule it failed instead of connecting without it.
        bail!(
            "The PKCS#11 token holds no usable Firezone client identity: {}",
            join(&unusable, "; ")
        );
    };
    let certificate = certificates.swap_remove(index);

    let algorithm = certificate
        .metadata
        .signing_algorithm
        .context("The selected PKCS#11 certificate uses an unsupported key algorithm")?;
    let private_key = certificate
        .key
        .context("The PKCS#11 token holds no private key for the selected certificate")?;
    let chain = certificate_chain(&certificate.der, &objects)
        .into_iter()
        .map(CertificateDer::from)
        .collect();
    let key = Arc::new(sign::Key::new(
        algorithm,
        Pkcs11Key {
            session: Mutex::new(session),
            key: private_key,
        },
    ));

    tracing::info!(
        fingerprint = %certificate.metadata.fingerprint,
        "Selected a PKCS#11 X.509 identity for mutual TLS"
    );

    Ok(Identity { chain, key })
}

/// A private key on a PKCS#11 token, reached through the session that unlocked it.
///
/// The session is opened and logged into once, while the identity is discovered, and lives as long
/// as the identity does. A token that wants a PIN would otherwise want one for every handshake
/// signature, including the ones a reconnect or a change of network makes. `Session` is `Send` but
/// not `Sync`, so the mutex is what lets rustls sign from whichever thread drives the handshake.
/// Holding a session also holds the module's context open, which is what keeps `C_Finalize` from
/// running underneath it.
#[derive(Debug)]
struct Pkcs11Key {
    session: Mutex<Session>,
    key: ObjectHandle,
}

impl sign::Signer for Pkcs11Key {
    fn sign(&self, scheme: SignatureScheme, message: &[u8]) -> Result<Vec<u8>, SigningError> {
        let session = self.session.lock().unwrap_or_else(PoisonError::into_inner);
        let signature = sign_with_key(&session, self.key, scheme, message)?;

        Ok(signature)
    }
}

#[expect(
    clippy::wildcard_enum_match_arm,
    reason = "rustls only ever asks for a scheme we advertised in `supported_schemes`"
)]
fn sign_with_key(
    session: &Session,
    key: ObjectHandle,
    scheme: SignatureScheme,
    message: &[u8],
) -> Result<Vec<u8>, SigningError> {
    let signature = match scheme {
        SignatureScheme::RSA_PSS_SHA256 => session.sign(
            &Mechanism::Sha256RsaPkcsPss(PkcsPssParams {
                hash_alg: MechanismType::SHA256,
                mgf: PkcsMgfType::MGF1_SHA256,
                s_len: 32.into(),
            }),
            key,
            message,
        ),
        SignatureScheme::RSA_PSS_SHA384 => session.sign(
            &Mechanism::Sha384RsaPkcsPss(PkcsPssParams {
                hash_alg: MechanismType::SHA384,
                mgf: PkcsMgfType::MGF1_SHA384,
                s_len: 48.into(),
            }),
            key,
            message,
        ),
        SignatureScheme::RSA_PSS_SHA512 => session.sign(
            &Mechanism::Sha512RsaPkcsPss(PkcsPssParams {
                hash_alg: MechanismType::SHA512,
                mgf: PkcsMgfType::MGF1_SHA512,
                s_len: 64.into(),
            }),
            key,
            message,
        ),
        SignatureScheme::RSA_PKCS1_SHA256 => session.sign(&Mechanism::Sha256RsaPkcs, key, message),
        SignatureScheme::RSA_PKCS1_SHA384 => session.sign(&Mechanism::Sha384RsaPkcs, key, message),
        SignatureScheme::RSA_PKCS1_SHA512 => session.sign(&Mechanism::Sha512RsaPkcs, key, message),
        SignatureScheme::ECDSA_NISTP256_SHA256 => {
            session.sign(&Mechanism::Ecdsa, key, &Sha256::digest(message))
        }
        SignatureScheme::ECDSA_NISTP384_SHA384 => {
            session.sign(&Mechanism::Ecdsa, key, &Sha384::digest(message))
        }
        SignatureScheme::ECDSA_NISTP521_SHA512 => {
            session.sign(&Mechanism::Ecdsa, key, &Sha512::digest(message))
        }
        _ => return Err(SigningError::UnsupportedScheme(scheme)),
    }
    .map_err(pkcs11_error)?;

    Ok(signature)
}

/// Names the cause behind a failure that carries a PKCS#11 return value.
fn pkcs11_error(error: cryptoki::error::Error) -> SigningError {
    let reason = error.to_string();
    let cryptoki::error::Error::Pkcs11(value, _) = error else {
        return SigningError::Keystore(reason);
    };

    classify_return_value(value, reason)
}

/// Tells a token that lost the key from one that refuses to use it.
///
/// A PIN the token rejected and a key whose attributes forbid signing are both refusals: the
/// token is present and answers, it just will not sign for us.
#[expect(
    clippy::wildcard_enum_match_arm,
    reason = "PKCS#11 defines far more return values than the ones we can act on"
)]
fn classify_return_value(value: RvError, reason: String) -> SigningError {
    match value {
        RvError::DeviceRemoved => SigningError::KeyUnavailable(reason),
        RvError::TokenNotPresent => SigningError::KeyUnavailable(reason),
        RvError::KeyHandleInvalid => SigningError::KeyUnavailable(reason),
        RvError::ObjectHandleInvalid => SigningError::KeyUnavailable(reason),
        RvError::SessionHandleInvalid => SigningError::KeyUnavailable(reason),
        RvError::SessionClosed => SigningError::KeyUnavailable(reason),
        RvError::PinIncorrect => SigningError::AccessDenied(reason),
        RvError::PinExpired => SigningError::AccessDenied(reason),
        RvError::PinLocked => SigningError::AccessDenied(reason),
        RvError::UserNotLoggedIn => SigningError::AccessDenied(reason),
        RvError::KeyFunctionNotPermitted => SigningError::AccessDenied(reason),
        RvError::FunctionCanceled => SigningError::AccessDenied(reason),
        _ => SigningError::Keystore(reason),
    }
}

/// Returns every PKCS#11 module registered on this machine, most preferred first.
///
/// The modules are read from p11-kit's configuration rather than through its proxy: the proxy
/// collapses every module into one `C_GetSlotList`, so a single broken module would take the
/// tokens of all the others down with it. Loading each module individually keeps them
/// independent.
fn registered_modules() -> Vec<PathBuf> {
    let directories = module_directories(multiarch_directories());
    let files = MODULE_CONFIGURATION_DIRECTORIES
        .into_iter()
        .flat_map(|directory| configuration_files(Path::new(directory)))
        .filter_map(|file| {
            std::fs::read_to_string(&file)
                .inspect_err(|error| {
                    tracing::debug!(
                        file = %file.display(),
                        "Skipping an unreadable p11-kit module configuration: {error}"
                    );
                })
                .ok()
        });

    configured_modules(files, &directories, &|module| module.is_file())
}

/// Returns the `*.module` files below `directory` in name order, none for a missing directory.
fn configuration_files(directory: &Path) -> Vec<PathBuf> {
    let mut files = std::fs::read_dir(directory)
        .into_iter()
        .flatten()
        .flatten()
        .map(|entry| entry.path())
        .filter(|path| {
            path.extension()
                .is_some_and(|extension| extension == "module")
        })
        .collect::<Vec<_>>();

    files.sort();

    files
}

/// Returns the modules `files` register, resolved and deduplicated, in the order given.
///
/// Two configuration files may name one module, e.g. the administrator's copy of a packaged
/// file; the first mention wins.
fn configured_modules(
    files: impl IntoIterator<Item = String>,
    directories: &[PathBuf],
    installed: &dyn Fn(&Path) -> bool,
) -> Vec<PathBuf> {
    let mut modules = Vec::new();

    for contents in files {
        let Some(module) = configured_module(&contents, directories, installed) else {
            continue;
        };

        if !modules.contains(&module) {
            modules.push(module);
        }
    }

    modules
}

/// Returns the module one p11-kit configuration file names, as a path to load.
///
/// Only the `module:` setting matters here. In particular, `disable-in: p11-kit-proxy` hides a
/// module from the proxy, which we are not, so it stays loaded. A relative value is looked up in
/// `directories`, most preferred first; one that is nowhere `installed` resolves against the most
/// preferred directory, so that loading it fails under the path the configuration meant.
fn configured_module(
    contents: &str,
    directories: &[PathBuf],
    installed: &dyn Fn(&Path) -> bool,
) -> Option<PathBuf> {
    let value = contents.lines().find_map(|line| {
        let (key, value) = line.split_once(':')?;

        (key.trim() == "module").then(|| value.trim())
    })?;

    if value.is_empty() {
        return None;
    }

    let module = Path::new(value);

    if module.is_absolute() {
        return Some(module.to_owned());
    }

    directories
        .iter()
        .map(|directory| directory.join(module))
        .find(|candidate| installed(candidate))
        .or_else(|| Some(directories.first()?.join(module)))
}

/// The directories a registered PKCS#11 module may be installed into, most preferred first.
///
/// Distributions keep driver modules below a `pkcs11` subdirectory of the library directory:
/// `/usr/lib64/pkcs11` on Fedora and RHEL, below the multiarch directory on Debian and Ubuntu.
/// `/usr/lib64` has to come before `/usr/lib`, whose modules are the 32-bit builds on a machine
/// with the i686 packages installed.
fn module_directories(multiarch_directories: Vec<PathBuf>) -> Vec<PathBuf> {
    let mut directories = vec![PathBuf::from("/usr/lib64")];
    directories.extend(multiarch_directories);
    directories.push(PathBuf::from("/usr/lib"));

    directories
        .into_iter()
        .map(|directory| directory.join("pkcs11"))
        .collect()
}

/// Debian keeps libraries below a directory named after the architecture triplet, e.g.
/// `/usr/lib/x86_64-linux-gnu`.
fn multiarch_directories() -> Vec<PathBuf> {
    std::fs::read_dir("/usr/lib")
        .into_iter()
        .flatten()
        .flatten()
        .map(|entry| entry.path())
        .collect()
}

/// The PKCS#11 context each module is used through, kept for the life of the process.
///
/// A module may only be initialized once: a second `C_Initialize` answers that it already is, so
/// two contexts for one module would cut each other off whenever they overlap, as a diagnostics
/// read and a handshake signature do. Holding on to the context is also what keeps the module
/// loaded for the sessions still using it.
static CONTEXTS: Mutex<BTreeMap<PathBuf, Pkcs11>> = Mutex::new(BTreeMap::new());

/// Returns the context for `module_path`, loading and initializing the module on first use.
fn context(module_path: &Path) -> Result<Pkcs11> {
    let mut contexts = CONTEXTS.lock().unwrap_or_else(PoisonError::into_inner);

    if let Some(context) = contexts.get(module_path) {
        return Ok(context.clone());
    }

    let context = Pkcs11::new(module_path)
        .with_context(|| format!("Failed to load {}", module_path.display()))?;
    context
        .initialize(CInitializeArgs::new(CInitializeFlags::OS_LOCKING_OK))
        .context("PKCS#11 initialization failed")?;
    // Only a context that initialized is remembered, so a module that failed to load can be
    // retried once whatever kept it from loading is fixed.
    contexts.insert(module_path.to_owned(), context.clone());

    Ok(context)
}

/// The token Firezone authenticates with, and everything it holds that bears on that.
struct Token {
    /// The unlocked session every signature made with this token goes through.
    session: Session,
    /// Every X.509 object on the token, which is what the chain of a certificate is built from.
    objects: Vec<CertificateObject>,
    /// The objects whose subject common name is the one Firezone looks for.
    certificates: Vec<Certificate>,
}

/// Returns the first token holding a certificate for `subject_cn`, not yet unlocked.
///
/// Certificates are public objects, so every token can be searched without logging in, and
/// [`unlock_token`] then unlocks only the one that turns out to hold ours. Logging into each
/// token in turn would instead spend the PIN attempts of tokens that have nothing to do with
/// Firezone.
fn find_token(module: &Path, subject_cn: &str) -> Result<Option<Candidate>> {
    let pkcs11 = context(module)?;
    let slots = pkcs11
        .get_slots_with_token()
        .context("Failed to enumerate PKCS#11 tokens")?;

    for slot in slots {
        let Some(candidate) = search_slot(&pkcs11, slot, subject_cn)
            .inspect_err(|error| tracing::debug!(?slot, "Skipping a PKCS#11 token: {error:#}"))
            .ok()
            .flatten()
        else {
            continue;
        };

        return Ok(Some(candidate));
    }

    Ok(None)
}

/// Unlocks the candidate's token and reads how each matching certificate can be used.
fn unlock_token(candidate: Candidate, pin_file: &Path) -> Result<Token> {
    let Candidate {
        info,
        session,
        objects,
        matches,
    } = candidate;

    unlock(&session, &info, pin_file)?;

    let certificates = matches
        .into_iter()
        .map(|(object, metadata)| describe_certificate(&session, &objects[object], metadata))
        .collect::<Result<Vec<_>>>()?;

    Ok(Token {
        session,
        objects,
        certificates,
    })
}

/// A token that holds at least one certificate for the subject common name we look for.
struct Candidate {
    info: TokenInfo,
    session: Session,
    objects: Vec<CertificateObject>,
    /// The index of each matching object in `objects`, alongside what its certificate says.
    matches: Vec<(usize, ParsedCertificate)>,
}

/// Reads the certificates on `slot`, before any login, to see whether the token is one of ours.
fn search_slot(pkcs11: &Pkcs11, slot: Slot, subject_cn: &str) -> Result<Option<Candidate>> {
    let info = pkcs11
        .get_token_info(slot)
        .context("Failed to read the token information")?;
    let session = pkcs11
        .open_ro_session(slot)
        .context("Failed to open the token")?;
    let objects = certificate_objects(&session)?;
    let now = SystemTime::now();
    let matches = objects
        .iter()
        .enumerate()
        .filter_map(|(index, object)| {
            let Some(metadata) = parse_certificate(&object.der, now) else {
                tracing::debug!(
                    object_label = ?object.label,
                    "Ignoring an invalid PKCS#11 X.509 certificate"
                );

                return None;
            };

            (metadata.subject_cn.as_deref() == Some(subject_cn)).then_some((index, metadata))
        })
        .collect::<Vec<_>>();

    if matches.is_empty() {
        return Ok(None);
    }

    Ok(Some(Candidate {
        info,
        session,
        objects,
        matches,
    }))
}

/// Unlocks the token, if it asks to be, with the PIN Firezone keeps on disk.
fn unlock(session: &Session, info: &TokenInfo, pin_file: &Path) -> Result<()> {
    let flags = LoginFlags::from(info);

    match login_requirement(flags)? {
        Login::NotRequired => {
            tracing::debug!("The PKCS#11 token hands out its keys without a login");
        }
        Login::Pin => {
            let pin = read_pin(pin_file)?;

            log_in(session, &pin).with_context(|| rejected_pin_reason(flags))?;
        }
    }

    Ok(())
}

/// What a token asks for before it hands out the private key of an identity.
#[derive(Debug)]
enum Login {
    /// The token's keys are usable as they are.
    NotRequired,
    /// The token wants the PIN Firezone keeps on disk.
    Pin,
}

/// The `C_GetTokenInfo` flags that decide whether and how Firezone logs into a token.
#[derive(Clone, Copy)]
struct LoginFlags {
    login_required: bool,
    protected_authentication_path: bool,
    user_pin_locked: bool,
    user_pin_final_try: bool,
    user_pin_count_low: bool,
}

impl From<&TokenInfo> for LoginFlags {
    fn from(info: &TokenInfo) -> Self {
        Self {
            login_required: info.login_required(),
            protected_authentication_path: info.protected_authentication_path(),
            user_pin_locked: info.user_pin_locked(),
            user_pin_final_try: info.user_pin_final_try(),
            user_pin_count_low: info.user_pin_count_low(),
        }
    }
}

/// Decides how Firezone logs into a token from what the token says about itself.
///
/// # Errors
///
/// Returns an error for a token Firezone cannot log into at all: one that wants its PIN typed on
/// the reader's own keypad, or one that has already locked its user PIN.
fn login_requirement(flags: LoginFlags) -> Result<Login> {
    if !flags.login_required {
        return Ok(Login::NotRequired);
    }

    if flags.protected_authentication_path {
        bail!(
            "The PKCS#11 token wants its PIN typed on the reader's own keypad, which Firezone cannot do: the Tunnel service runs in the background and prompts nobody"
        );
    }

    if flags.user_pin_locked {
        bail!(
            "The PKCS#11 token has locked its user PIN, which has to be unblocked with the token's PUK before Firezone can use it"
        );
    }

    Ok(Login::Pin)
}

/// Says how much of the token's patience the PIN it just rejected used up.
fn rejected_pin_reason(flags: LoginFlags) -> String {
    if flags.user_pin_final_try {
        return "Failed to unlock the PKCS#11 token, which had one attempt left before locking its user PIN".to_owned();
    }

    if flags.user_pin_count_low {
        return "Failed to unlock the PKCS#11 token, which was already counting down to locking its user PIN".to_owned();
    }

    "Failed to unlock the PKCS#11 token".to_owned()
}

/// Logs into the token, treating a login an overlapping session already did as success.
///
/// PKCS#11 tracks the login per token rather than per session, so a token that another session of
/// this process unlocked is unlocked for this one too, and logging in again is refused.
fn log_in(session: &Session, pin: &AuthPin) -> Result<()> {
    let Err(error) = session.login(UserType::User, Some(pin)) else {
        return Ok(());
    };

    if matches!(
        error,
        cryptoki::error::Error::Pkcs11(RvError::UserAlreadyLoggedIn, _)
    ) {
        return Ok(());
    }

    Err(error.into())
}

/// Reads the token's PIN from `path`.
///
/// Ownership and permissions are checked on the open file rather than on its path, so that a file
/// swapped in between the check and the read cannot get its contents used.
///
/// # Errors
///
/// Returns an error if the file is missing or unreadable, or if it is not root's alone.
fn read_pin(path: &Path) -> Result<AuthPin> {
    let mut file = File::open(path)
        .with_context(|| format!("Failed to open the PKCS#11 PIN file '{}'", path.display()))?;
    let metadata = file
        .metadata()
        .with_context(|| format!("Failed to read the metadata of '{}'", path.display()))?;

    ensure_root_only(metadata.mode(), metadata.uid(), path)?;

    let mut contents = String::new();
    file.read_to_string(&mut contents)
        .with_context(|| format!("Failed to read '{}'", path.display()))?;

    // A PIN may deliberately begin or end with a space, so only the line ending is stripped.
    Ok(AuthPin::from(contents.trim_end_matches(['\n', '\r'])))
}

/// Refuses a PIN file that any account other than root can get at.
///
/// The Tunnel service runs as root, so a PIN file another account owns or can read is one a
/// compromised account could use to authenticate the device.
fn ensure_root_only(mode: u32, uid: u32, path: &Path) -> Result<()> {
    if mode & 0o077 != 0 {
        bail!(
            "Permissions 0{:o} for '{}' are too open; the PKCS#11 PIN file must not be accessible by group or others",
            mode & 0o777,
            path.display()
        );
    }

    if uid != 0 {
        bail!(
            "'{}' is owned by uid {uid} rather than by root; only root may hold the PKCS#11 PIN",
            path.display()
        );
    }

    Ok(())
}

/// A certificate on the token whose subject CN is the one we look for.
struct Certificate {
    der: Vec<u8>,
    metadata: ParsedCertificate,
    key: Option<ObjectHandle>,
    usable: bool,
}

/// Says whether the token can sign with a certificate it holds, and how it describes it.
fn describe_certificate(
    session: &Session,
    object: &CertificateObject,
    metadata: ParsedCertificate,
) -> Result<Certificate> {
    let key = find_private_key(
        session,
        object.id.as_deref(),
        object.label.as_deref(),
        metadata.signing_algorithm,
    )?;

    Ok(Certificate {
        der: object.der.clone(),
        usable: key.is_some(),
        metadata,
        key,
    })
}

impl Certificate {
    fn detail_fields(&self) -> Vec<DetailField> {
        self.metadata
            .detail_fields()
            .into_iter()
            .map(DetailField::from)
            .collect()
    }
}

impl CandidateCertificate for Certificate {
    fn usable(&self) -> bool {
        self.usable
    }

    fn not_before_timestamp(&self) -> i64 {
        self.metadata.not_before_timestamp
    }

    fn unusable(&self) -> UnusableCertificate {
        // A key algorithm we cannot sign with is why no key was looked for, so it is not the
        // same as a token that simply holds none.
        let cause = match self.metadata.signing_algorithm {
            Some(_) => UnusableCause::Pkcs11KeyMissing,
            None => UnusableCause::UnsupportedKeyAlgorithm,
        };

        UnusableCertificate {
            fingerprint: self.metadata.fingerprint.clone(),
            cause,
        }
    }
}

struct CertificateObject {
    der: Vec<u8>,
    id: Option<Vec<u8>>,
    label: Option<String>,
}

fn certificate_objects(session: &Session) -> Result<Vec<CertificateObject>> {
    let handles = session
        .find_objects(&[
            Attribute::Class(ObjectClass::CERTIFICATE),
            Attribute::CertificateType(CertificateType::X_509),
        ])
        .context("Failed to enumerate PKCS#11 certificates")?;
    let mut certificates = Vec::new();

    for handle in handles {
        let attributes = match session.get_attributes(
            handle,
            &[
                AttributeType::Value,
                AttributeType::Id,
                AttributeType::Label,
            ],
        ) {
            Ok(attributes) => attributes,
            Err(error) => {
                tracing::warn!(?error, "Failed to read a PKCS#11 certificate object");
                continue;
            }
        };

        let mut der = None;
        let mut id = None;
        let mut label = None;
        for attribute in attributes {
            #[expect(
                clippy::wildcard_enum_match_arm,
                reason = "PKCS#11 may return attributes we did not ask for"
            )]
            match attribute {
                Attribute::Value(value) => der = Some(value),
                Attribute::Id(value) => id = Some(value),
                Attribute::Label(value) => label = String::from_utf8(value).ok(),
                _ => {}
            }
        }

        if let Some(der) = der {
            certificates.push(CertificateObject { der, id, label });
        }
    }

    Ok(certificates)
}

fn find_private_key(
    session: &Session,
    id: Option<&[u8]>,
    label: Option<&str>,
    algorithm: Option<SigningAlgorithm>,
) -> Result<Option<ObjectHandle>> {
    let key_type = match algorithm {
        Some(SigningAlgorithm::RsaSha256) => KeyType::RSA,
        Some(SigningAlgorithm::EcdsaSha256) => KeyType::EC,
        Some(SigningAlgorithm::EcdsaSha384) => KeyType::EC,
        Some(SigningAlgorithm::EcdsaSha512) => KeyType::EC,
        None => return Ok(None),
    };
    let mut template = vec![
        Attribute::Class(ObjectClass::PRIVATE_KEY),
        Attribute::KeyType(key_type),
    ];
    match (id, label) {
        (Some(id), _) => template.push(Attribute::Id(id.to_vec())),
        (None, Some(label)) => template.push(Attribute::Label(label.as_bytes().to_vec())),
        (None, None) => return Ok(None),
    }

    let key = session
        .find_objects(&template)
        .context("Failed to locate the PKCS#11 private key")?
        .into_iter()
        .next();

    Ok(key)
}

/// Walks up from the leaf, collecting the issuers the token holds.
///
/// Stops at the first issuer the token does not have, leaving the portal to complete the chain
/// from its own trust store.
fn certificate_chain(leaf: &[u8], issuers: &[CertificateObject]) -> Vec<Vec<u8>> {
    let now = SystemTime::now();
    let mut chain = vec![leaf.to_vec()];
    let Some(mut current) = parse_certificate(leaf, now) else {
        return chain;
    };

    while current.subject != current.issuer {
        let Some((der, metadata)) = issuers.iter().find_map(|candidate| {
            if chain.contains(&candidate.der) {
                return None;
            }
            let metadata = parse_certificate(&candidate.der, now)?;

            (metadata.subject == current.issuer).then_some((&candidate.der, metadata))
        }) else {
            break;
        };

        chain.push(der.clone());
        current = metadata;
    }

    chain
}
