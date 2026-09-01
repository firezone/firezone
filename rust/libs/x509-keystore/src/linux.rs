//! X.509 client identities held by a PKCS#11 token.

mod rpc;
#[cfg(test)]
mod tests;

use std::{
    fs::File,
    io::Read as _,
    os::unix::fs::MetadataExt as _,
    path::{Path, PathBuf},
    sync::Arc,
    time::SystemTime,
};

use anyhow::{Context as _, Result, bail};
use rustls::{SignatureScheme, pki_types::CertificateDer};
use secrecy::{ExposeSecret as _, SecretString};
use sha2::{Digest as _, Sha256, Sha384, Sha512};
use x509_claims::{ParsedCertificate, SigningAlgorithm, parse_certificate};
use x509_credential::SigningError;

use crate::{
    CandidateCertificate, Error, Identity, Loaded, UnusableCause, selected_certificate, sign,
};
use rpc::{Attribute, Mechanism, ReturnValue};

/// The directories p11-kit module configuration is read from, the administrator's first.
///
/// Whichever driver an administrator installed for their token registers itself here, so it is
/// reachable without Firezone being told about it.
const MODULE_CONFIGURATION_DIRECTORIES: [&str; 2] =
    ["/etc/pkcs11/modules", "/usr/share/p11-kit/modules"];

/// The file a token's PIN is read from.
const PIN_FILE: &str = "/etc/firezone/pkcs11-pin";

pub(crate) fn load(subject_cn: &str) -> Result<Loaded, Error> {
    let Some(p11_kit) = p11_kit_command() else {
        return Err(Error::MissingP11Kit);
    };
    let modules = registered_modules();

    if modules.is_empty() {
        return Err(Error::MissingP11Kit);
    }

    load_on(&p11_kit, &modules, Path::new(PIN_FILE), subject_cn)
}

fn load_on(
    p11_kit: &Path,
    modules: &[PathBuf],
    pin_file: &Path,
    subject_cn: &str,
) -> Result<Loaded, Error> {
    let mut failures = Vec::new();

    for module in modules {
        // A module that cannot be read leaves its tokens out of reach, the same as holding
        // none: it may fail to serve, as when its driver is broken, or fail to enumerate,
        // as when the service behind it is not running. One broken module must not hide
        // the tokens of the others.
        let candidate = match find_token(p11_kit, module, subject_cn) {
            Ok(Some(candidate)) => candidate,
            Ok(None) => continue,
            Err(error) => {
                tracing::debug!(module = %module.display(), "Skipping a PKCS#11 module: {error:#}");
                // Only the short top-level cause: the raw child and driver messages behind it
                // are long, and the log carries the full chain.
                failures.push(format!("{}: {error}", module.display()));

                continue;
            }
        };

        // A matching token's verdict is final: a certificate that was provisioned for Firezone
        // and cannot be used is reported rather than falling through to another module.
        return select_identity(candidate, pin_file);
    }

    // A machine whose every module failed has an unreadable keystore, not a missing
    // certificate, and which of the two the administrator reads decides what they fix.
    if failures.len() == modules.len() {
        return Err(Error::UnreadablePkcs11Keystore { modules: failures });
    }

    tracing::debug!("No PKCS#11 token holds a Firezone client identity");

    Ok(Loaded::default())
}

/// Unlocks the candidate's token and selects the certificate it presents for mutual TLS.
fn select_identity(candidate: Candidate, pin_file: &Path) -> Result<Loaded, Error> {
    let Token {
        session,
        objects,
        mut certificates,
        ..
    } = unlock_token(candidate, pin_file).map_err(Error::identity_unavailable)?;

    let Some(index) = selected_certificate(&certificates) else {
        return Ok(Loaded::default());
    };
    let certificate = certificates.swap_remove(index);

    // Skipping a certificate that was provisioned for Firezone reads to an administrator as
    // if none had been, so say which rule it failed instead of connecting without it.
    if let Some(cause) = certificate.unusable() {
        return Err(Error::IdentityUnavailable {
            message: format!("The PKCS#11 token holds no usable Firezone client identity: {cause}"),
        });
    }

    let Some(algorithm) = certificate.metadata.signing_algorithm else {
        return Err(Error::IdentityUnavailable {
            message: "The selected PKCS#11 certificate uses an unsupported key algorithm"
                .to_owned(),
        });
    };
    let Some(private_key) = certificate.key else {
        return Err(Error::IdentityUnavailable {
            message: "The PKCS#11 token holds no private key for the selected certificate"
                .to_owned(),
        });
    };
    let chain = certificate_chain(&certificate.der, &objects)
        .into_iter()
        .map(CertificateDer::from)
        .collect();
    let key = Arc::new(sign::Key::new(
        algorithm,
        Pkcs11Key {
            session,
            key: private_key,
        },
    ));

    tracing::info!(
        fingerprint = %certificate.metadata.fingerprint,
        "Selected a PKCS#11 X.509 identity for mutual TLS"
    );

    Ok(Loaded {
        certificate: None,
        identity: Some(Identity { chain, key }),
    })
}

/// A private key on a PKCS#11 token, reached through the session that unlocked it.
///
/// The session is opened and logged into once, while the identity is discovered, and lives as
/// long as the identity does. A token that wants a PIN would otherwise want one for every
/// handshake signature, including the ones a reconnect or a change of network makes. Holding
/// the session also keeps the `p11-kit remote` child hosting the module running, which is what
/// keeps the module from being finalized underneath it.
#[derive(Debug)]
struct Pkcs11Key {
    session: rpc::Session,
    key: u64,
}

impl sign::Signer for Pkcs11Key {
    fn sign(&self, scheme: SignatureScheme, message: &[u8]) -> Result<Vec<u8>, SigningError> {
        let signature = sign_with_key(&self.session, self.key, scheme, message)?;

        Ok(signature)
    }
}

#[expect(
    clippy::wildcard_enum_match_arm,
    reason = "rustls only ever asks for a scheme we advertised in `supported_schemes`"
)]
fn sign_with_key(
    session: &rpc::Session,
    key: u64,
    scheme: SignatureScheme,
    message: &[u8],
) -> Result<Vec<u8>, SigningError> {
    let signature = match scheme {
        SignatureScheme::RSA_PSS_SHA256 => session.sign(&Mechanism::Sha256RsaPkcsPss, key, message),
        SignatureScheme::RSA_PSS_SHA384 => session.sign(&Mechanism::Sha384RsaPkcsPss, key, message),
        SignatureScheme::RSA_PSS_SHA512 => session.sign(&Mechanism::Sha512RsaPkcsPss, key, message),
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
fn pkcs11_error(error: rpc::Error) -> SigningError {
    let reason = error.to_string();
    let rpc::Error::Token(value) = error else {
        return SigningError::Keystore(reason);
    };

    classify_return_value(value, reason)
}

/// Tells a token that lost the key from one that refuses to use it.
///
/// A PIN the token rejected and a key whose attributes forbid signing are both refusals: the
/// token is present and answers, it just will not sign for us.
fn classify_return_value(value: ReturnValue, reason: String) -> SigningError {
    match value.0 {
        rpc::CKR_DEVICE_REMOVED => SigningError::KeyUnavailable(reason),
        rpc::CKR_TOKEN_NOT_PRESENT => SigningError::KeyUnavailable(reason),
        rpc::CKR_KEY_HANDLE_INVALID => SigningError::KeyUnavailable(reason),
        rpc::CKR_OBJECT_HANDLE_INVALID => SigningError::KeyUnavailable(reason),
        rpc::CKR_SESSION_HANDLE_INVALID => SigningError::KeyUnavailable(reason),
        rpc::CKR_SESSION_CLOSED => SigningError::KeyUnavailable(reason),
        rpc::CKR_PIN_INCORRECT => SigningError::AccessDenied(reason),
        rpc::CKR_PIN_EXPIRED => SigningError::AccessDenied(reason),
        rpc::CKR_PIN_LOCKED => SigningError::AccessDenied(reason),
        rpc::CKR_USER_NOT_LOGGED_IN => SigningError::AccessDenied(reason),
        rpc::CKR_KEY_FUNCTION_NOT_PERMITTED => SigningError::AccessDenied(reason),
        rpc::CKR_FUNCTION_CANCELED => SigningError::AccessDenied(reason),
        _ => SigningError::Keystore(reason),
    }
}

/// Returns the p11-kit command the registered modules are served through.
fn p11_kit_command() -> Option<PathBuf> {
    std::env::var_os("PATH")
        .map(|path| std::env::split_paths(&path).collect::<Vec<_>>())
        .unwrap_or_default()
        .into_iter()
        .chain([PathBuf::from("/usr/bin")])
        .map(|directory| directory.join("p11-kit"))
        .find(|candidate| candidate.is_file())
}

/// Returns every PKCS#11 module registered on this machine, most preferred first.
///
/// The modules are read from p11-kit's configuration rather than through its proxy: the proxy
/// collapses every module into one `C_GetSlotList`, so a single broken module would take the
/// tokens of all the others down with it. Serving each module through its own child keeps
/// them independent.
fn registered_modules() -> Vec<PathBuf> {
    let directories = module_directories(multiarch_directories());
    let program = program_name();

    configured_modules(
        configuration_files_by_name(),
        &directories,
        &|module| module.is_file(),
        program.as_deref(),
    )
}

/// Returns the contents of every module configuration file, each under the name that the
/// administrator's directory overrides the packaged one by.
fn configuration_files_by_name() -> Vec<(String, String)> {
    MODULE_CONFIGURATION_DIRECTORIES
        .into_iter()
        .flat_map(|directory| configuration_files(Path::new(directory)))
        .filter_map(|file| {
            let name = file.file_stem()?.to_str()?.to_owned();
            let contents = std::fs::read_to_string(&file)
                .inspect_err(|error| {
                    tracing::debug!(
                        file = %file.display(),
                        "Skipping an unreadable p11-kit module configuration: {error}"
                    );
                })
                .ok()?;

            Some((name, contents))
        })
        .collect()
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

/// Returns the modules `files` register, resolved and deduplicated, most preferred first.
///
/// p11-kit's own rules are mirrored: the first configuration under a given name wins, so an
/// administrator's copy of a packaged file replaces it; a module named by two surviving
/// configurations is loaded once; a module stays out unless it is enabled for `program`; and
/// the modules are ordered by descending `priority:`, ties by configuration name.
fn configured_modules(
    files: impl IntoIterator<Item = (String, String)>,
    directories: &[PathBuf],
    installed: &dyn Fn(&Path) -> bool,
    program: Option<&str>,
) -> Vec<PathBuf> {
    let mut configurations = Vec::<(String, ModuleConfiguration)>::new();
    for (name, contents) in files {
        if configurations.iter().any(|(seen, _)| *seen == name) {
            continue;
        }

        configurations.push((name, parse_configuration(&contents)));
    }

    let mut registered = configurations
        .into_iter()
        .filter_map(|(name, configuration)| {
            if !is_enabled(&configuration, program) {
                tracing::debug!(module = name, "Skipping a disabled PKCS#11 module");

                return None;
            }
            let value = configuration.module?;
            if value.is_empty() {
                return None;
            }
            let module = resolve_module(&value, directories, installed)?;

            Some((name, configuration.priority, module))
        })
        .collect::<Vec<_>>();
    registered.sort_by(|(name_a, priority_a, _), (name_b, priority_b, _)| {
        priority_b.cmp(priority_a).then_with(|| name_a.cmp(name_b))
    });

    let mut modules = Vec::new();
    for (_, _, module) in registered {
        if !modules.contains(&module) {
            modules.push(module);
        }
    }

    modules
}

/// The settings of one p11-kit module configuration file that bear on loading its module.
#[derive(Default)]
struct ModuleConfiguration {
    module: Option<String>,
    enable_in: Option<String>,
    disable_in: Option<String>,
    priority: i64,
}

/// Reads the `key: value` lines of a configuration file, the last mention of a key winning.
fn parse_configuration(contents: &str) -> ModuleConfiguration {
    let mut configuration = ModuleConfiguration::default();

    for line in contents.lines() {
        let line = line.trim();
        if line.starts_with('#') {
            continue;
        }
        let Some((key, value)) = line.split_once(':') else {
            continue;
        };
        let value = value.trim();

        match key.trim() {
            "module" => configuration.module = Some(value.to_owned()),
            "enable-in" => configuration.enable_in = Some(value.to_owned()),
            "disable-in" => configuration.disable_in = Some(value.to_owned()),
            "priority" => configuration.priority = leading_integer(value),
            _ => {}
        }
    }

    configuration
}

/// Says whether the configuration enables its module for the program `program`.
///
/// `enable-in` lists the only programs that may load the module and `disable-in` the programs
/// that may not, either naming us by our executable's name. In particular, the common
/// `disable-in: p11-kit-proxy` hides a module from the proxy, which we are not, so it stays
/// loaded.
fn is_enabled(configuration: &ModuleConfiguration, program: Option<&str>) -> bool {
    if let Some(enable_in) = &configuration.enable_in {
        return program.is_some_and(|name| list_contains(enable_in, name));
    }
    if let Some(disable_in) = &configuration.disable_in {
        return program.is_none_or(|name| !list_contains(disable_in, name));
    }

    true
}

/// Says whether a comma or whitespace separated list has `name` as an entry.
fn list_contains(list: &str, name: &str) -> bool {
    list.split(|character: char| character == ',' || character.is_whitespace())
        .any(|entry| entry == name)
}

/// Reads the integer a value begins with, 0 when it begins with none.
///
/// p11-kit reads `priority:` with `atoi`, which stops at the first character that is not part
/// of a number, so a value that goes on after the number still counts.
fn leading_integer(value: &str) -> i64 {
    let sign = usize::from(value.starts_with(['+', '-']));
    let digits = value[sign..]
        .bytes()
        .take_while(|byte| byte.is_ascii_digit())
        .count();

    value[..sign + digits].parse().unwrap_or(0)
}

/// The name p11-kit's `enable-in` and `disable-in` settings know a program by.
fn program_name() -> Option<String> {
    let executable = std::env::current_exe().ok()?;
    let name = executable.file_name()?.to_str()?.to_owned();

    Some(name)
}

/// Returns the path a `module:` setting names, as a path to load.
///
/// A relative value is looked up in `directories`, most preferred first; one that is nowhere
/// `installed` resolves against the most preferred directory, so that loading it fails under
/// the path the configuration meant.
fn resolve_module(
    value: &str,
    directories: &[PathBuf],
    installed: &dyn Fn(&Path) -> bool,
) -> Option<PathBuf> {
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

/// The token Firezone authenticates with, and everything it holds that bears on that.
struct Token {
    /// The unlocked session every signature made with this token goes through.
    session: rpc::Session,
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
fn find_token(p11_kit: &Path, module: &Path, subject_cn: &str) -> Result<Option<Candidate>> {
    let pkcs11 = rpc::Module::load(p11_kit, module)
        .with_context(|| format!("Failed to load {}", module.display()))?;
    let slots = pkcs11
        .slots_with_tokens()
        .context("Failed to enumerate PKCS#11 tokens")?;

    for slot in slots {
        let Some(candidate) = search_slot(&pkcs11, slot, subject_cn)
            .inspect_err(|error| tracing::debug!(slot, "Skipping a PKCS#11 token: {error:#}"))
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
        flags,
        session,
        objects,
        matches,
    } = candidate;

    unlock(&session, flags, pin_file)?;

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
    flags: LoginFlags,
    session: rpc::Session,
    objects: Vec<CertificateObject>,
    /// The index of each matching object in `objects`, alongside what its certificate says.
    matches: Vec<(usize, ParsedCertificate)>,
}

/// Reads the certificates on `slot`, before any login, to see whether the token is one of ours.
fn search_slot(pkcs11: &rpc::Module, slot: u64, subject_cn: &str) -> Result<Option<Candidate>> {
    let flags = pkcs11
        .token_flags(slot)
        .context("Failed to read the token information")?;
    let flags = LoginFlags::from_bits(flags);
    let session = pkcs11
        .open_session(slot)
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
        flags,
        session,
        objects,
        matches,
    }))
}

/// Unlocks the token, if it asks to be, with the PIN Firezone keeps on disk.
fn unlock(session: &rpc::Session, flags: LoginFlags, pin_file: &Path) -> Result<()> {
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

impl LoginFlags {
    fn from_bits(flags: u64) -> Self {
        Self {
            login_required: flags & rpc::TOKEN_FLAG_LOGIN_REQUIRED != 0,
            protected_authentication_path: flags & rpc::TOKEN_FLAG_PROTECTED_AUTHENTICATION_PATH
                != 0,
            user_pin_locked: flags & rpc::TOKEN_FLAG_USER_PIN_LOCKED != 0,
            user_pin_final_try: flags & rpc::TOKEN_FLAG_USER_PIN_FINAL_TRY != 0,
            user_pin_count_low: flags & rpc::TOKEN_FLAG_USER_PIN_COUNT_LOW != 0,
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
/// PKCS#11 tracks the login per token rather than per session, so a token that another session
/// on this module unlocked is unlocked for this one too, and logging in again is refused.
fn log_in(session: &rpc::Session, pin: &SecretString) -> Result<()> {
    let Err(error) = session.login_user(pin.expose_secret().as_bytes()) else {
        return Ok(());
    };

    if matches!(
        error,
        rpc::Error::Token(ReturnValue(rpc::CKR_USER_ALREADY_LOGGED_IN))
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
fn read_pin(path: &Path) -> Result<SecretString> {
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
    Ok(SecretString::from(contents.trim_end_matches(['\n', '\r'])))
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
    key: Option<u64>,
}

/// Says whether the token can sign with a certificate it holds, and how it describes it.
fn describe_certificate(
    session: &rpc::Session,
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
        metadata,
        key,
    })
}

impl CandidateCertificate for Certificate {
    fn unusable(&self) -> Option<UnusableCause> {
        // A key algorithm we cannot sign with is why no key was looked for, so it is not the
        // same as a token that simply holds none.
        match (&self.key, self.metadata.signing_algorithm) {
            (Some(_), _) => None,
            (None, Some(_)) => Some(UnusableCause::KeyMissing),
            (None, None) => Some(UnusableCause::UnsupportedKeyAlgorithm),
        }
    }

    fn not_before_timestamp(&self) -> i64 {
        self.metadata.not_before_timestamp
    }
}

struct CertificateObject {
    der: Vec<u8>,
    id: Option<Vec<u8>>,
    label: Option<String>,
}

fn certificate_objects(session: &rpc::Session) -> Result<Vec<CertificateObject>> {
    let handles = session
        .find_objects(&[
            Attribute::ulong(rpc::ATTRIBUTE_CLASS, rpc::OBJECT_CLASS_CERTIFICATE),
            Attribute::ulong(rpc::ATTRIBUTE_CERTIFICATE_TYPE, rpc::CERTIFICATE_TYPE_X_509),
        ])
        .context("Failed to enumerate PKCS#11 certificates")?;
    let mut certificates = Vec::new();

    for handle in handles {
        let attributes = match session.byte_array_attributes(
            handle,
            &[
                rpc::ATTRIBUTE_VALUE,
                rpc::ATTRIBUTE_ID,
                rpc::ATTRIBUTE_LABEL,
            ],
        ) {
            Ok(attributes) => attributes,
            Err(error) => {
                tracing::warn!(?error, "Failed to read a PKCS#11 certificate object");
                continue;
            }
        };

        let Ok([der, id, label]) = <[Option<Vec<u8>>; 3]>::try_from(attributes) else {
            continue;
        };
        let Some(der) = der else {
            continue;
        };

        certificates.push(CertificateObject {
            der,
            id,
            label: label.and_then(|bytes| String::from_utf8(bytes).ok()),
        });
    }

    Ok(certificates)
}

fn find_private_key(
    session: &rpc::Session,
    id: Option<&[u8]>,
    label: Option<&str>,
    algorithm: Option<SigningAlgorithm>,
) -> Result<Option<u64>> {
    let key_type = match algorithm {
        Some(SigningAlgorithm::RsaSha256) => rpc::KEY_TYPE_RSA,
        Some(SigningAlgorithm::EcdsaSha256) => rpc::KEY_TYPE_EC,
        Some(SigningAlgorithm::EcdsaSha384) => rpc::KEY_TYPE_EC,
        Some(SigningAlgorithm::EcdsaSha512) => rpc::KEY_TYPE_EC,
        None => return Ok(None),
    };
    let mut template = vec![
        Attribute::ulong(rpc::ATTRIBUTE_CLASS, rpc::OBJECT_CLASS_PRIVATE_KEY),
        Attribute::ulong(rpc::ATTRIBUTE_KEY_TYPE, key_type),
    ];
    match (id, label) {
        (Some(id), _) => template.push(Attribute::bytes(rpc::ATTRIBUTE_ID, id.to_vec())),
        (None, Some(label)) => {
            template.push(Attribute::bytes(
                rpc::ATTRIBUTE_LABEL,
                label.as_bytes().to_vec(),
            ));
        }
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
