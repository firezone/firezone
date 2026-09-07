//! A PKCS#11 client that reaches each module through a `p11-kit remote` child process.
//!
//! PKCS#11 driver modules are shared libraries, which a statically linked client cannot
//! load. The system's own p11-kit can host any module in a child process instead, speaking
//! its RPC protocol on the child's standard streams, so the modules stay loadable however
//! the client itself is built. This is the client side of that protocol, covering only the
//! calls the keystore walk makes; the reference implementation lives in p11-kit's
//! `rpc-message.c` and `rpc-client.c`.

use std::{
    io::{Read as _, Write as _},
    path::Path,
    process::{Child, ChildStdin, ChildStdout, Command, Stdio},
    sync::{Arc, Mutex, MutexGuard, PoisonError},
};

/// `CKO_CERTIFICATE`, the class of certificate objects.
pub(crate) const OBJECT_CLASS_CERTIFICATE: u64 = 0x0000_0001;
/// `CKO_PRIVATE_KEY`, the class of private-key objects.
pub(crate) const OBJECT_CLASS_PRIVATE_KEY: u64 = 0x0000_0003;
/// `CKC_X_509`, the certificate type of X.509 certificates.
pub(crate) const CERTIFICATE_TYPE_X_509: u64 = 0x0000_0000;
/// `CKK_RSA`, the key type of RSA keys.
pub(crate) const KEY_TYPE_RSA: u64 = 0x0000_0000;
/// `CKK_EC`, the key type of elliptic-curve keys.
pub(crate) const KEY_TYPE_EC: u64 = 0x0000_0003;

/// `CKA_CLASS`, the attribute holding an object's class.
pub(crate) const ATTRIBUTE_CLASS: u64 = 0x0000_0000;
/// `CKA_LABEL`, the attribute holding an object's label.
pub(crate) const ATTRIBUTE_LABEL: u64 = 0x0000_0003;
/// `CKA_VALUE`, the attribute holding a certificate's DER encoding.
pub(crate) const ATTRIBUTE_VALUE: u64 = 0x0000_0011;
/// `CKA_CERTIFICATE_TYPE`, the attribute holding a certificate object's type.
pub(crate) const ATTRIBUTE_CERTIFICATE_TYPE: u64 = 0x0000_0080;
/// `CKA_KEY_TYPE`, the attribute holding a key object's type.
pub(crate) const ATTRIBUTE_KEY_TYPE: u64 = 0x0000_0100;
/// `CKA_ID`, the attribute pairing a certificate with its key.
pub(crate) const ATTRIBUTE_ID: u64 = 0x0000_0102;

/// `CKF_LOGIN_REQUIRED` of `CK_TOKEN_INFO.flags`.
pub(crate) const TOKEN_FLAG_LOGIN_REQUIRED: u64 = 0x0000_0004;
/// `CKF_PROTECTED_AUTHENTICATION_PATH` of `CK_TOKEN_INFO.flags`.
pub(crate) const TOKEN_FLAG_PROTECTED_AUTHENTICATION_PATH: u64 = 0x0000_0100;
/// `CKF_USER_PIN_COUNT_LOW` of `CK_TOKEN_INFO.flags`.
pub(crate) const TOKEN_FLAG_USER_PIN_COUNT_LOW: u64 = 0x0001_0000;
/// `CKF_USER_PIN_FINAL_TRY` of `CK_TOKEN_INFO.flags`.
pub(crate) const TOKEN_FLAG_USER_PIN_FINAL_TRY: u64 = 0x0002_0000;
/// `CKF_USER_PIN_LOCKED` of `CK_TOKEN_INFO.flags`.
pub(crate) const TOKEN_FLAG_USER_PIN_LOCKED: u64 = 0x0004_0000;

pub(crate) const CKR_ATTRIBUTE_SENSITIVE: u64 = 0x0000_0011;
pub(crate) const CKR_ATTRIBUTE_TYPE_INVALID: u64 = 0x0000_0012;
pub(crate) const CKR_DEVICE_REMOVED: u64 = 0x0000_0032;
pub(crate) const CKR_FUNCTION_CANCELED: u64 = 0x0000_0050;
pub(crate) const CKR_KEY_HANDLE_INVALID: u64 = 0x0000_0060;
pub(crate) const CKR_KEY_FUNCTION_NOT_PERMITTED: u64 = 0x0000_0068;
pub(crate) const CKR_OBJECT_HANDLE_INVALID: u64 = 0x0000_0082;
pub(crate) const CKR_PIN_INCORRECT: u64 = 0x0000_00a0;
pub(crate) const CKR_PIN_EXPIRED: u64 = 0x0000_00a3;
pub(crate) const CKR_PIN_LOCKED: u64 = 0x0000_00a4;
pub(crate) const CKR_SESSION_CLOSED: u64 = 0x0000_00b0;
pub(crate) const CKR_SESSION_HANDLE_INVALID: u64 = 0x0000_00b3;
pub(crate) const CKR_TOKEN_NOT_PRESENT: u64 = 0x0000_00e0;
pub(crate) const CKR_USER_ALREADY_LOGGED_IN: u64 = 0x0000_0100;
pub(crate) const CKR_USER_NOT_LOGGED_IN: u64 = 0x0000_0101;
pub(crate) const CKR_BUFFER_TOO_SMALL: u64 = 0x0000_0150;

/// Why a call into the module did not produce its answer.
#[derive(Debug)]
pub(crate) enum Error {
    /// The module answered with a PKCS#11 return value other than `CKR_OK`.
    Token(ReturnValue),
    /// The child could not be spawned or reached, e.g. because it exited.
    Transport(std::io::Error),
    /// The child answered outside the protocol, e.g. with a version we do not speak.
    Protocol(String),
}

impl std::fmt::Display for Error {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Token(value) => write!(formatter, "The PKCS#11 module answered {value}"),
            Self::Transport(error) => {
                write!(formatter, "The p11-kit child could not be reached: {error}")
            }
            Self::Protocol(message) => formatter.write_str(message),
        }
    }
}

impl std::error::Error for Error {}

/// A `CK_RV` as the module reported it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct ReturnValue(pub(crate) u64);

impl std::fmt::Display for ReturnValue {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let name = match self.0 {
            0x0000_0005 => "CKR_GENERAL_ERROR",
            0x0000_0006 => "CKR_FUNCTION_FAILED",
            0x0000_0007 => "CKR_ARGUMENTS_BAD",
            CKR_ATTRIBUTE_SENSITIVE => "CKR_ATTRIBUTE_SENSITIVE",
            CKR_ATTRIBUTE_TYPE_INVALID => "CKR_ATTRIBUTE_TYPE_INVALID",
            0x0000_0030 => "CKR_DEVICE_ERROR",
            CKR_DEVICE_REMOVED => "CKR_DEVICE_REMOVED",
            CKR_FUNCTION_CANCELED => "CKR_FUNCTION_CANCELED",
            0x0000_0054 => "CKR_FUNCTION_NOT_SUPPORTED",
            CKR_KEY_HANDLE_INVALID => "CKR_KEY_HANDLE_INVALID",
            CKR_KEY_FUNCTION_NOT_PERMITTED => "CKR_KEY_FUNCTION_NOT_PERMITTED",
            0x0000_0070 => "CKR_MECHANISM_INVALID",
            CKR_OBJECT_HANDLE_INVALID => "CKR_OBJECT_HANDLE_INVALID",
            0x0000_0090 => "CKR_OPERATION_NOT_INITIALIZED",
            CKR_PIN_INCORRECT => "CKR_PIN_INCORRECT",
            CKR_PIN_EXPIRED => "CKR_PIN_EXPIRED",
            CKR_PIN_LOCKED => "CKR_PIN_LOCKED",
            CKR_SESSION_CLOSED => "CKR_SESSION_CLOSED",
            CKR_SESSION_HANDLE_INVALID => "CKR_SESSION_HANDLE_INVALID",
            CKR_TOKEN_NOT_PRESENT => "CKR_TOKEN_NOT_PRESENT",
            CKR_USER_ALREADY_LOGGED_IN => "CKR_USER_ALREADY_LOGGED_IN",
            CKR_USER_NOT_LOGGED_IN => "CKR_USER_NOT_LOGGED_IN",
            CKR_BUFFER_TOO_SMALL => "CKR_BUFFER_TOO_SMALL",
            other => return write!(formatter, "CKR 0x{other:08X}"),
        };

        formatter.write_str(name)
    }
}

/// A PKCS#11 module, hosted by the `p11-kit remote` child that loaded it.
pub(crate) struct Module {
    connection: Arc<Connection>,
}

impl Module {
    /// Spawns `p11-kit remote <module>` and initializes the module behind it.
    ///
    /// # Errors
    ///
    /// Returns an error if the child cannot be spawned, exits before serving, offers a
    /// protocol version we do not speak, or fails `C_Initialize`.
    pub(crate) fn load(p11_kit: &Path, module: &Path) -> Result<Self, Error> {
        let mut child = Command::new(p11_kit)
            .arg("remote")
            .arg(module)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(Error::Transport)?;
        let (Some(stdin), Some(stdout)) = (child.stdin.take(), child.stdout.take()) else {
            let _ = child.kill();
            let _ = child.wait();

            return Err(Error::Protocol(
                "The spawned p11-kit child is missing its piped streams".to_owned(),
            ));
        };

        let mut transport = Transport {
            child,
            stdin,
            stdout,
            next_code: FIRST_MESSAGE_CODE,
        };

        let protocol_version = match negotiate_and_initialize(&mut transport) {
            Ok(protocol_version) => protocol_version,
            Err(error) => return Err(transport.abort(error)),
        };

        Ok(Self {
            connection: Arc::new(Connection {
                transport: Mutex::new(transport),
                protocol_version,
            }),
        })
    }

    /// Returns the ID of every slot that holds a token.
    pub(crate) fn slots_with_tokens(&self) -> Result<Vec<u64>, Error> {
        let mut probe = Request::new(&GET_SLOT_LIST);
        probe.byte(1);
        probe.buffer_size(0);
        let count = match self.connection.call(&GET_SLOT_LIST, probe)?.ulong_array()? {
            UlongArray::Values(slots) => return Ok(slots),
            UlongArray::Length(count) => count,
        };
        if count == 0 {
            return Ok(Vec::new());
        }

        let mut fetch = Request::new(&GET_SLOT_LIST);
        fetch.byte(1);
        fetch.buffer_size(count);
        let slots = match self.connection.call(&GET_SLOT_LIST, fetch)?.ulong_array()? {
            UlongArray::Values(slots) => slots,
            UlongArray::Length(_) => {
                return Err(Error::Protocol(
                    "The slot list is missing from the response".to_owned(),
                ));
            }
        };

        Ok(slots)
    }

    /// Returns the `CK_TOKEN_INFO.flags` of the token in `slot`.
    pub(crate) fn token_flags(&self, slot: u64) -> Result<u64, Error> {
        let mut request = Request::new(&GET_TOKEN_INFO);
        request.ulong(slot);
        let mut response = self.connection.call(&GET_TOKEN_INFO, request)?;

        // The label, manufacturer, model and serial number precede the flags.
        response.space_string(32)?;
        response.space_string(32)?;
        response.space_string(16)?;
        response.space_string(16)?;
        let flags = response.ulong()?;

        Ok(flags)
    }

    /// Opens a read-only session on the token in `slot`.
    pub(crate) fn open_session(&self, slot: u64) -> Result<Session, Error> {
        /// `CKF_SERIAL_SESSION`, which every session must set; read-only is its absence of
        /// `CKF_RW_SESSION`.
        const SERIAL_SESSION: u64 = 0x0000_0004;

        let mut request = Request::new(&OPEN_SESSION);
        request.ulong(slot);
        request.ulong(SERIAL_SESSION);
        let handle = self.connection.call(&OPEN_SESSION, request)?.ulong()?;

        Ok(Session {
            connection: Arc::clone(&self.connection),
            handle,
        })
    }
}

/// A session on one token, usable from any thread.
///
/// The session keeps the `p11-kit remote` child hosting its module alive, so a held
/// session, and with it the identity's private key, survives the walk that found it.
#[derive(Debug)]
pub(crate) struct Session {
    connection: Arc<Connection>,
    handle: u64,
}

impl Session {
    /// Logs the token's user in with `pin`.
    pub(crate) fn login_user(&self, pin: &[u8]) -> Result<(), Error> {
        /// `CKU_USER`, the ordinary user of a token.
        const USER: u64 = 0x0000_0001;

        let mut request = Request::new(&LOGIN);
        request.ulong(self.handle);
        request.ulong(USER);
        request.byte_array(pin);
        self.connection.call(&LOGIN, request)?;

        Ok(())
    }

    /// Returns the handle of every object matching `template`.
    pub(crate) fn find_objects(&self, template: &[Attribute]) -> Result<Vec<u64>, Error> {
        let mut init = Request::new(&FIND_OBJECTS_INIT);
        init.ulong(self.handle);
        init.attributes(template);
        self.connection.call(&FIND_OBJECTS_INIT, init)?;

        let mut handles = Vec::new();
        loop {
            const BATCH: u32 = 16;

            let mut next = Request::new(&FIND_OBJECTS);
            next.ulong(self.handle);
            next.buffer_size(BATCH);
            let batch = match self.connection.call(&FIND_OBJECTS, next)?.ulong_array()? {
                UlongArray::Values(handles) => handles,
                UlongArray::Length(_) => {
                    return Err(Error::Protocol(
                        "The object handles are missing from the response".to_owned(),
                    ));
                }
            };

            if batch.is_empty() {
                break;
            }
            handles.extend(batch);
        }

        let mut done = Request::new(&FIND_OBJECTS_FINAL);
        done.ulong(self.handle);
        self.connection.call(&FIND_OBJECTS_FINAL, done)?;

        Ok(handles)
    }

    /// Reads byte-array attributes of `object`, [`None`] where the object does not carry one.
    ///
    /// Every type asked for must be one PKCS#11 defines as a byte array, such as `CKA_VALUE`
    /// or `CKA_ID`: the protocol encodes each attribute after its type, so this cannot
    /// decode e.g. a `CK_ULONG` attribute.
    pub(crate) fn byte_array_attributes(
        &self,
        object: u64,
        types: &[u64],
    ) -> Result<Vec<Option<Vec<u8>>>, Error> {
        let sizes = types.iter().map(|&attribute| (attribute, 0)).collect();
        let lengths = self.attribute_values(object, sizes, |response, length| {
            response.skipped_byte_array()?;

            Ok(length)
        })?;

        let known = lengths
            .iter()
            .zip(types)
            .filter_map(|(length, &attribute)| Some((attribute, (*length)?)))
            .filter(|(_, length)| *length > 0)
            .collect::<Vec<_>>();
        let fetched = if known.is_empty() {
            Vec::new()
        } else {
            self.attribute_values(object, known, |response, _| {
                response.raw_byte_array().map(Option::unwrap_or_default)
            })?
        };
        let mut fetched = fetched.into_iter();

        let values = lengths
            .into_iter()
            .map(|length| match length {
                Some(0) => Some(Vec::new()),
                Some(_) => fetched.next().flatten(),
                None => None,
            })
            .collect();

        Ok(values)
    }

    /// Runs one `C_GetAttributeValue` call, reading each answered value with `value`.
    ///
    /// `sizes` names the attributes and the value buffer offered for each; a probe offers
    /// zero-length buffers and learns the lengths to offer next time.
    fn attribute_values<T>(
        &self,
        object: u64,
        sizes: Vec<(u64, u32)>,
        value: impl Fn(&mut Response, u32) -> Result<T, Error>,
    ) -> Result<Vec<Option<T>>, Error> {
        /// Larger than any attribute a certificate or key object carries.
        const MAX_ATTRIBUTE_LENGTH: u32 = 1024 * 1024;

        let mut request = Request::new(&GET_ATTRIBUTE_VALUE);
        request.ulong(self.handle);
        request.ulong(object);
        request.attribute_buffer(&sizes);
        let mut response = self.connection.call(&GET_ATTRIBUTE_VALUE, request)?;

        let count = response.u32()?;
        if count as usize != sizes.len() {
            return Err(Error::Protocol(format!(
                "The response answers {count} attributes where {} were asked for",
                sizes.len()
            )));
        }

        let mut values = Vec::with_capacity(sizes.len());
        for (attribute, _) in sizes {
            let answered = response.u32()?;
            if u64::from(answered) != attribute {
                return Err(Error::Protocol(format!(
                    "The response answers attribute {answered} where {attribute} was asked for"
                )));
            }

            let available = response.byte()? != 0;
            if !available {
                values.push(None);
                continue;
            }

            let length = response.u32()?;
            if length > MAX_ATTRIBUTE_LENGTH {
                return Err(Error::Protocol(format!(
                    "The response carries an implausibly large attribute of {length} bytes"
                )));
            }

            values.push(Some(value(&mut response, length)?));
        }

        // The verdict of the call follows the attributes; the codes below say some
        // attributes are missing, which the validity of each already told us.
        let verdict = response.ulong()?;
        match verdict {
            0 => {}
            CKR_ATTRIBUTE_SENSITIVE => {}
            CKR_ATTRIBUTE_TYPE_INVALID => {}
            CKR_BUFFER_TOO_SMALL => {}
            other => return Err(Error::Token(ReturnValue(other))),
        }

        Ok(values)
    }

    /// Signs `data` with `key` in one go.
    pub(crate) fn sign(
        &self,
        mechanism: &Mechanism,
        key: u64,
        data: &[u8],
    ) -> Result<Vec<u8>, Error> {
        /// Larger than any signature a TLS client key produces.
        const SIGNATURE_CAPACITY: u32 = 16 * 1024;

        // One lock spans both calls: `C_SignInit` starts an operation that `C_Sign`
        // consumes, so another thread's pair interleaving here would corrupt both.
        let mut transport = self.connection.lock();

        let mut init = Request::new(&SIGN_INIT);
        init.ulong(self.handle);
        init.mechanism(mechanism, self.connection.protocol_version);
        init.ulong(key);
        call(&mut transport, &SIGN_INIT, init)?;

        let mut request = Request::new(&SIGN);
        request.ulong(self.handle);
        request.byte_array(data);
        request.buffer_size(SIGNATURE_CAPACITY);
        let signature = call(&mut transport, &SIGN, request)?.byte_array()?;

        Ok(signature)
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        let mut request = Request::new(&CLOSE_SESSION);
        request.ulong(self.handle);
        let _ = self.connection.call(&CLOSE_SESSION, request);
    }
}

/// The signing mechanisms the keystore uses, with the parameters each carries.
#[derive(Debug)]
pub(crate) enum Mechanism {
    Sha256RsaPkcs,
    Sha256RsaPkcsPss,
    Ecdsa,
}

impl Mechanism {
    /// Writes the mechanism the way a server speaking `protocol_version` reads one.
    ///
    /// Version 2 of the protocol, p11-kit 0.26, reframed mechanisms: under it a
    /// parameterless mechanism ends after its type and parameters follow a presence byte,
    /// while versions 0 and 1 follow a parameterless type with the null byte-array marker
    /// and parameters directly. A server decodes by its own build's framing, which the
    /// version it negotiated names.
    fn encode(&self, buffer: &mut Vec<u8>, protocol_version: u8) {
        const CKM_SHA256_RSA_PKCS: u32 = 0x0000_0040;
        const CKM_SHA256_RSA_PKCS_PSS: u32 = 0x0000_0043;
        const CKM_ECDSA: u32 = 0x0000_1041;
        const CKM_SHA256: u64 = 0x0000_0250;
        const MGF1_SHA256: u64 = 0x0000_0002;

        let (mechanism, pss) = match self {
            Self::Sha256RsaPkcs => (CKM_SHA256_RSA_PKCS, None),
            Self::Sha256RsaPkcsPss => {
                (CKM_SHA256_RSA_PKCS_PSS, Some((CKM_SHA256, MGF1_SHA256, 32)))
            }
            Self::Ecdsa => (CKM_ECDSA, None),
        };

        const NULL_MARKER: u32 = 0xffff_ffff;

        let reframed = protocol_version >= 2;

        push_u32(buffer, mechanism);
        let Some((hash, mask_generation_function, salt_length)) = pss else {
            if !reframed {
                push_u32(buffer, NULL_MARKER);
            }

            return;
        };
        if reframed {
            buffer.push(1);
        }
        push_u64(buffer, hash);
        push_u64(buffer, mask_generation_function);
        push_u64(buffer, salt_length);
    }
}

/// One attribute of a search template.
#[derive(Debug, Clone)]
pub(crate) struct Attribute {
    attribute_type: u64,
    value: AttributeValue,
}

#[derive(Debug, Clone)]
enum AttributeValue {
    Ulong(u64),
    Bytes(Vec<u8>),
}

impl Attribute {
    pub(crate) fn ulong(attribute_type: u64, value: u64) -> Self {
        Self {
            attribute_type,
            value: AttributeValue::Ulong(value),
        }
    }

    pub(crate) fn bytes(attribute_type: u64, value: Vec<u8>) -> Self {
        Self {
            attribute_type,
            value: AttributeValue::Bytes(value),
        }
    }

    fn encode(&self, buffer: &mut Vec<u8>) {
        /// What a native client reports as `ulValueLen` of a `CK_ULONG` attribute; the
        /// server checks it against its own `CK_ULONG`, so it has to be ours.
        const ULONG_LENGTH: u32 = size_of::<std::ffi::c_ulong>() as u32;

        push_u32(buffer, self.attribute_type as u32);
        buffer.push(1);
        match &self.value {
            AttributeValue::Ulong(value) => {
                push_u32(buffer, ULONG_LENGTH);
                push_u64(buffer, *value);
            }
            AttributeValue::Bytes(bytes) => {
                push_u32(buffer, bytes.len() as u32);
                push_u32(buffer, bytes.len() as u32);
                buffer.extend_from_slice(bytes);
            }
        }
    }
}

/// One call of the protocol: its numeric ID and the argument signatures both sides verify.
struct Call {
    id: u32,
    request: &'static str,
    response: &'static str,
}

const ERROR_CALL_ID: u32 = 0;
const INITIALIZE: Call = Call {
    id: 1,
    request: "ayyay",
    response: "",
};
const FINALIZE: Call = Call {
    id: 2,
    request: "",
    response: "",
};
const GET_SLOT_LIST: Call = Call {
    id: 4,
    request: "yfu",
    response: "au",
};
const GET_TOKEN_INFO: Call = Call {
    id: 6,
    request: "u",
    response: "ssssuuuuuuuuuuuvvs",
};
const OPEN_SESSION: Call = Call {
    id: 10,
    request: "uu",
    response: "u",
};
const CLOSE_SESSION: Call = Call {
    id: 11,
    request: "u",
    response: "",
};
const LOGIN: Call = Call {
    id: 18,
    request: "uuay",
    response: "",
};
const GET_ATTRIBUTE_VALUE: Call = Call {
    id: 24,
    request: "uufA",
    response: "aAu",
};
const FIND_OBJECTS_INIT: Call = Call {
    id: 26,
    request: "uaA",
    response: "",
};
const FIND_OBJECTS: Call = Call {
    id: 27,
    request: "ufu",
    response: "au",
};
const FIND_OBJECTS_FINAL: Call = Call {
    id: 28,
    request: "u",
    response: "",
};
const SIGN_INIT: Call = Call {
    id: 42,
    request: "uMu",
    response: "",
};
const SIGN: Call = Call {
    id: 43,
    request: "uayfy",
    response: "ay",
};

/// The newest protocol version we offer the child.
///
/// The child answers with the version it will speak, at most what was offered. Any answer up
/// to our offer is usable: the calls the versions added, the PKCS#11 3.0 calls at 1 and
/// `C_DeriveKey2` at 2, lie outside our subset, and [`Mechanism::encode`] follows the framing
/// the answered version names.
const OFFERED_PROTOCOL_VERSION: u8 = 2;

/// What p11-kit's `C_Initialize` sends in place of the reserved arguments.
const INITIALIZE_HANDSHAKE: &[u8] = b"PRIVATE-GNOME-KEYRING-PKCS11-PROTOCOL-V-1";

/// Where p11-kit starts numbering the messages on a connection.
const FIRST_MESSAGE_CODE: u32 = 0x10;

/// Longer than any response the calls we make can produce.
const MAX_RESPONSE_LENGTH: u32 = 8 * 1024 * 1024;

/// Negotiates the protocol version and initializes the module.
///
/// Returns the version the child answered with.
fn negotiate_and_initialize(transport: &mut Transport) -> Result<u8, Error> {
    transport
        .stdin
        .write_all(&[OFFERED_PROTOCOL_VERSION])
        .map_err(Error::Transport)?;
    transport.stdin.flush().map_err(Error::Transport)?;

    let mut version = [0u8];
    transport
        .stdout
        .read_exact(&mut version)
        .map_err(Error::Transport)?;
    let [version] = version;
    if version > OFFERED_PROTOCOL_VERSION {
        return Err(Error::Protocol(format!(
            "The p11-kit child wants to speak RPC protocol version {version}, and we only speak up to {OFFERED_PROTOCOL_VERSION}"
        )));
    }

    let mut request = Request::new(&INITIALIZE);
    request.byte_array(INITIALIZE_HANDSHAKE);
    request.byte(0);
    request.byte_array(&[0]);
    call(transport, &INITIALIZE, request)?;

    Ok(version)
}

/// The child process and the streams the protocol runs on.
#[derive(Debug)]
struct Transport {
    child: Child,
    stdin: ChildStdin,
    stdout: ChildStdout,
    next_code: u32,
}

impl Transport {
    /// Sends one framed message and returns the payload of the answer to it.
    ///
    /// A frame is three big-endian `u32`s, the message code, options length and payload
    /// length, followed by the options and the payload. The options ride along unused in
    /// either direction.
    fn roundtrip(&mut self, request: &[u8]) -> Result<Vec<u8>, Error> {
        let code = self.next_code;
        self.next_code = self.next_code.wrapping_add(1);

        let mut header = [0u8; 12];
        header[0..4].copy_from_slice(&code.to_be_bytes());
        header[8..12].copy_from_slice(&(request.len() as u32).to_be_bytes());
        self.stdin.write_all(&header).map_err(Error::Transport)?;
        self.stdin.write_all(request).map_err(Error::Transport)?;
        self.stdin.flush().map_err(Error::Transport)?;

        let mut header = [0u8; 12];
        self.stdout
            .read_exact(&mut header)
            .map_err(Error::Transport)?;
        let answered = u32::from_be_bytes([header[0], header[1], header[2], header[3]]);
        let options_length = u32::from_be_bytes([header[4], header[5], header[6], header[7]]);
        let payload_length = u32::from_be_bytes([header[8], header[9], header[10], header[11]]);
        if answered != code {
            return Err(Error::Protocol(format!(
                "The child answered message {answered} where {code} was awaited"
            )));
        }
        if options_length > MAX_RESPONSE_LENGTH || payload_length > MAX_RESPONSE_LENGTH {
            return Err(Error::Protocol(format!(
                "The child answered with an implausibly long message of {options_length}+{payload_length} bytes"
            )));
        }

        let mut options = vec![0u8; options_length as usize];
        self.stdout
            .read_exact(&mut options)
            .map_err(Error::Transport)?;
        let mut payload = vec![0u8; payload_length as usize];
        self.stdout
            .read_exact(&mut payload)
            .map_err(Error::Transport)?;

        Ok(payload)
    }

    /// Ends a connection that never became usable, naming what the child said on stderr.
    fn abort(mut self, error: Error) -> Error {
        let _ = self.child.kill();
        let _ = self.child.wait();

        // The child has exited, so the read cannot block on it.
        let Some(mut stderr) = self.child.stderr.take() else {
            return error;
        };
        let mut complaint = String::new();
        if stderr.read_to_string(&mut complaint).is_err() {
            return error;
        }
        let complaint = complaint.split_whitespace().collect::<Vec<_>>().join(" ");
        if complaint.is_empty() {
            return error;
        }

        Error::Protocol(format!("{error} ({complaint})"))
    }
}

/// The transport, shared by the module and its sessions for as long as either lives.
#[derive(Debug)]
struct Connection {
    transport: Mutex<Transport>,
    protocol_version: u8,
}

impl Connection {
    fn call(&self, of: &Call, request: Request) -> Result<Response, Error> {
        let mut transport = self.lock();

        call(&mut transport, of, request)
    }

    fn lock(&self) -> MutexGuard<'_, Transport> {
        self.transport
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
    }
}

impl Drop for Connection {
    fn drop(&mut self) {
        let transport = self
            .transport
            .get_mut()
            .unwrap_or_else(PoisonError::into_inner);

        // Finalizing lets the module flush its state; the kill then only reaps a child
        // with nothing left to do, or one that stopped answering.
        let _ = call(transport, &FINALIZE, Request::new(&FINALIZE));
        let _ = transport.child.kill();
        let _ = transport.child.wait();
    }
}

fn call(transport: &mut Transport, of: &Call, request: Request) -> Result<Response, Error> {
    let payload = transport.roundtrip(&request.buffer)?;

    Response::parse(of, payload)
}

/// A request payload under construction: the call ID and signature, then the arguments.
struct Request {
    buffer: Vec<u8>,
}

impl Request {
    fn new(call: &Call) -> Self {
        let mut buffer = Vec::new();
        push_u32(&mut buffer, call.id);
        push_u32(&mut buffer, call.request.len() as u32);
        buffer.extend_from_slice(call.request.as_bytes());

        Self { buffer }
    }

    /// Writes a `y` argument.
    fn byte(&mut self, value: u8) {
        self.buffer.push(value);
    }

    /// Writes a `u` argument.
    fn ulong(&mut self, value: u64) {
        push_u64(&mut self.buffer, value);
    }

    /// Writes an `ay` argument.
    fn byte_array(&mut self, bytes: &[u8]) {
        self.buffer.push(1);
        push_u32(&mut self.buffer, bytes.len() as u32);
        self.buffer.extend_from_slice(bytes);
    }

    /// Writes an `fy` or `fu` argument: how many items the response may carry.
    fn buffer_size(&mut self, count: u32) {
        push_u32(&mut self.buffer, count);
    }

    /// Writes an `aA` argument.
    fn attributes(&mut self, template: &[Attribute]) {
        push_u32(&mut self.buffer, template.len() as u32);
        for attribute in template {
            attribute.encode(&mut self.buffer);
        }
    }

    /// Writes an `fA` argument: the attribute types asked for and the bytes offered to each.
    fn attribute_buffer(&mut self, sizes: &[(u64, u32)]) {
        push_u32(&mut self.buffer, sizes.len() as u32);
        for (attribute, length) in sizes {
            push_u32(&mut self.buffer, *attribute as u32);
            push_u32(&mut self.buffer, *length);
        }
    }

    /// Writes an `M` argument.
    fn mechanism(&mut self, mechanism: &Mechanism, protocol_version: u8) {
        mechanism.encode(&mut self.buffer, protocol_version);
    }
}

fn push_u32(buffer: &mut Vec<u8>, value: u32) {
    buffer.extend_from_slice(&value.to_be_bytes());
}

fn push_u64(buffer: &mut Vec<u8>, value: u64) {
    buffer.extend_from_slice(&value.to_be_bytes());
}

/// A `CK_ULONG` array of a response, or only its length when the response holds no items.
enum UlongArray {
    Values(Vec<u64>),
    Length(u32),
}

/// A response payload, verified to answer the sent call, read argument by argument.
struct Response {
    payload: Vec<u8>,
    offset: usize,
}

impl Response {
    fn parse(call: &Call, payload: Vec<u8>) -> Result<Self, Error> {
        let mut response = Self { payload, offset: 0 };

        let answered = response.u32()?;
        let signature = response.signature()?;
        if answered == ERROR_CALL_ID {
            if signature != "u" {
                return Err(Error::Protocol(
                    "The error response does not carry a return value".to_owned(),
                ));
            }
            let value = response.ulong()?;
            if value == 0 {
                return Err(Error::Protocol(
                    "The error response answers that nothing is wrong".to_owned(),
                ));
            }

            return Err(Error::Token(ReturnValue(value)));
        }
        if answered != call.id {
            return Err(Error::Protocol(format!(
                "The child answered call {answered} where {} was awaited",
                call.id
            )));
        }
        if signature != call.response {
            return Err(Error::Protocol(format!(
                "The child answered with signature '{signature}' where '{}' was awaited",
                call.response
            )));
        }

        Ok(response)
    }

    fn signature(&mut self) -> Result<String, Error> {
        let length = self.u32()?;
        let bytes = self.take(length as usize)?;

        Ok(String::from_utf8_lossy(bytes).into_owned())
    }

    /// Reads a `y` value.
    fn byte(&mut self) -> Result<u8, Error> {
        let bytes = self.take(1)?;

        Ok(bytes[0])
    }

    /// Reads a `u` value.
    fn ulong(&mut self) -> Result<u64, Error> {
        let bytes = self.take(8)?;
        let mut value = [0u8; 8];
        value.copy_from_slice(bytes);

        Ok(u64::from_be_bytes(value))
    }

    fn u32(&mut self) -> Result<u32, Error> {
        let bytes = self.take(4)?;
        let mut value = [0u8; 4];
        value.copy_from_slice(bytes);

        Ok(u32::from_be_bytes(value))
    }

    /// Reads an `s` value, which must be exactly `length` bytes of padded text.
    fn space_string(&mut self, length: usize) -> Result<(), Error> {
        let carried = self.u32()?;
        if carried as usize != length {
            return Err(Error::Protocol(format!(
                "The response carries a string of {carried} bytes where {length} were awaited"
            )));
        }
        self.take(length)?;

        Ok(())
    }

    /// Reads an `ay` value.
    fn byte_array(&mut self) -> Result<Vec<u8>, Error> {
        let present = self.byte()? != 0;
        if !present {
            // Only the needed length follows: the buffer we offered was too small.
            let _needed = self.u32()?;

            return Err(Error::Token(ReturnValue(CKR_BUFFER_TOO_SMALL)));
        }

        let bytes = self.raw_byte_array()?.unwrap_or_default();

        Ok(bytes)
    }

    /// Reads a bare length-prefixed byte array, [`None`] for the null marker.
    fn raw_byte_array(&mut self) -> Result<Option<Vec<u8>>, Error> {
        const NULL_MARKER: u32 = 0xffff_ffff;

        let length = self.u32()?;
        if length == NULL_MARKER {
            return Ok(None);
        }
        let bytes = self.take(length as usize)?;

        Ok(Some(bytes.to_vec()))
    }

    /// Reads and discards a bare length-prefixed byte array.
    fn skipped_byte_array(&mut self) -> Result<(), Error> {
        self.raw_byte_array()?;

        Ok(())
    }

    /// Reads an `au` value.
    fn ulong_array(&mut self) -> Result<UlongArray, Error> {
        let present = self.byte()? != 0;
        let count = self.u32()?;
        if !present {
            return Ok(UlongArray::Length(count));
        }
        if count > MAX_RESPONSE_LENGTH / 8 {
            return Err(Error::Protocol(format!(
                "The response carries an implausibly long array of {count} items"
            )));
        }

        let values = (0..count)
            .map(|_| self.ulong())
            .collect::<Result<Vec<_>, _>>()?;

        Ok(UlongArray::Values(values))
    }

    fn take(&mut self, length: usize) -> Result<&[u8], Error> {
        let remaining = self.payload.len() - self.offset;
        if remaining < length {
            return Err(Error::Protocol(format!(
                "The response ends after {remaining} bytes where {length} more were awaited"
            )));
        }

        let bytes = &self.payload[self.offset..self.offset + length];
        self.offset += length;

        Ok(bytes)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encodes_a_search_template_the_way_p11_kit_does() {
        let mut request = Request::new(&FIND_OBJECTS_INIT);
        request.ulong(0x11);
        request.attributes(&[
            Attribute::ulong(ATTRIBUTE_CLASS, OBJECT_CLASS_CERTIFICATE),
            Attribute::bytes(ATTRIBUTE_ID, vec![0xab, 0xcd]),
        ]);

        #[rustfmt::skip]
        let expected = [
            0, 0, 0, 26, // The call ID of C_FindObjectsInit.
            0, 0, 0, 3, b'u', b'a', b'A', // Its request signature.
            0, 0, 0, 0, 0, 0, 0, 0x11, // The session handle.
            0, 0, 0, 2, // Two attributes follow.
            0, 0, 0, 0, // CKA_CLASS.
            1, // Valid.
            0, 0, 0, 8, // The length of a CK_ULONG.
            0, 0, 0, 0, 0, 0, 0, 1, // CKO_CERTIFICATE.
            0, 0, 1, 2, // CKA_ID.
            1, // Valid.
            0, 0, 0, 2, // Two bytes of value.
            0, 0, 0, 2, 0xab, 0xcd, // The value, a length-prefixed byte array.
        ];
        assert_eq!(request.buffer, expected);
    }

    #[test]
    fn frames_a_mechanism_by_the_negotiated_version() {
        let framed = |mechanism: &Mechanism, protocol_version| {
            let mut buffer = Vec::new();
            mechanism.encode(&mut buffer, protocol_version);

            buffer
        };

        assert_eq!(
            framed(&Mechanism::Ecdsa, 1),
            [0, 0, 0x10, 0x41, 0xff, 0xff, 0xff, 0xff],
            "before version 2, a parameterless mechanism ends with the null marker"
        );
        assert_eq!(
            framed(&Mechanism::Ecdsa, 2),
            [0, 0, 0x10, 0x41],
            "under version 2, a parameterless mechanism ends after its type"
        );
        #[rustfmt::skip]
        let old_pss = [
            0, 0, 0, 0x43, // CKM_SHA256_RSA_PKCS_PSS.
            0, 0, 0, 0, 0, 0, 0x02, 0x50, // CKM_SHA256.
            0, 0, 0, 0, 0, 0, 0, 2, // MGF1 with SHA-256.
            0, 0, 0, 0, 0, 0, 0, 32, // The salt length.
        ];
        assert_eq!(
            framed(&Mechanism::Sha256RsaPkcsPss, 1),
            old_pss,
            "before version 2, the parameters follow the type directly"
        );
        let mut new_pss = old_pss.to_vec();
        new_pss.insert(4, 1);
        assert_eq!(
            framed(&Mechanism::Sha256RsaPkcsPss, 2),
            new_pss,
            "under version 2, a presence byte leads the parameters"
        );
    }

    #[test]
    fn an_error_response_carries_the_return_value() {
        let mut payload = Vec::new();
        push_u32(&mut payload, ERROR_CALL_ID);
        push_u32(&mut payload, 1);
        payload.push(b'u');
        push_u64(&mut payload, CKR_PIN_INCORRECT);

        let Err(Error::Token(value)) = Response::parse(&LOGIN, payload) else {
            panic!("an error response should surface as a token error");
        };

        assert_eq!(value, ReturnValue(CKR_PIN_INCORRECT));
        assert_eq!(value.to_string(), "CKR_PIN_INCORRECT");
    }

    #[test]
    fn a_probed_slot_list_answers_with_its_length() {
        let mut payload = Vec::new();
        push_u32(&mut payload, GET_SLOT_LIST.id);
        push_u32(&mut payload, 2);
        payload.extend_from_slice(b"au");
        payload.push(0);
        push_u32(&mut payload, 3);

        let mut response =
            Response::parse(&GET_SLOT_LIST, payload).expect("the response should parse");

        let UlongArray::Length(count) = response.ulong_array().expect("the array should parse")
        else {
            panic!("a probe response should carry only the length");
        };
        assert_eq!(count, 3);
    }

    #[test]
    fn a_truncated_response_is_refused() {
        let mut payload = Vec::new();
        push_u32(&mut payload, OPEN_SESSION.id);
        push_u32(&mut payload, 1);
        payload.push(b'u');
        push_u32(&mut payload, 7); // Half of the session handle is missing.

        let mut response =
            Response::parse(&OPEN_SESSION, payload).expect("the envelope should parse");

        assert!(matches!(response.ulong(), Err(Error::Protocol(_))));
    }
}
