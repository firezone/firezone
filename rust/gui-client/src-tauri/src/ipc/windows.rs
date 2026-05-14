use super::{NotFound, SocketId};
use anyhow::{Context as _, Result, bail, ensure};
use sha2::{Digest, Sha256};
use std::{ffi::c_void, io::ErrorKind, os::windows::io::AsRawHandle, sync::OnceLock, time::Duration};
use tokio::net::windows::named_pipe;
use windows::Win32::{
    Foundation::{HANDLE, HLOCAL, LocalFree},
    Security::{
        Authorization::{GetSecurityInfo, SE_KERNEL_OBJECT},
        IsWellKnownSid, OWNER_SECURITY_INFORMATION, PSECURITY_DESCRIPTOR, PSID,
        SECURITY_ATTRIBUTES, WinLocalSystemSid,
    },
    System::Pipes::{GetNamedPipeClientProcessId, GetNamedPipeServerProcessId},
};
use windows_security::{SecurityDescriptor, current_user_sid_string};

/// `kernel32!GetCurrentPackageFullName` returns this when the calling
/// process has no package identity. Any other return value (including
/// `ERROR_INSUFFICIENT_BUFFER` from the first sizing call) means the
/// process *is* part of a registered MSIX package and the kernel will
/// attach our [`crate::PACKAGE_SID`] to its token.
const APPMODEL_ERROR_NO_PACKAGE: u32 = 15700;

pub(crate) struct Server {
    pipe_path: String,
    socket_id: SocketId,
}

/// Alias for the client's half of a platform-specific IPC stream
pub type ClientStream = named_pipe::NamedPipeClient;

/// Alias for the server's half of a platform-specific IPC stream
pub(crate) type ServerStream = named_pipe::NamedPipeServer;

/// Connect to an IPC socket.
///
/// This is async on Linux
#[expect(clippy::unused_async)]
#[expect(clippy::wildcard_enum_match_arm)]
pub(crate) async fn connect_to_socket(id: SocketId) -> Result<ClientStream> {
    let path = ipc_path(id);
    let stream = named_pipe::ClientOptions::new()
        .open(&path)
        .map_err(|error| match error.kind() {
            ErrorKind::NotFound => anyhow::Error::new(NotFound(path)),
            _ => anyhow::Error::new(error),
        })
        .context("Couldn't connect to named pipe")?;
    let handle = HANDLE(stream.as_raw_handle());

    // Skip the owner check in debug builds so the `gui-smoke-test`, which
    // launches the Tunnel binary as a subprocess of the test runner (not as a
    // Windows service running under `LocalSystem`), can drive a real GUI
    // ↔ Tunnel handshake. Production builds are always release-mode (the
    // `gui-smoke-test` workflow explicitly skips release mode), so the check
    // is enforced there.
    if !cfg!(debug_assertions) && matches!(id, SocketId::Tunnel) {
        ensure_pipe_owner_is_local_system(handle)
            .context("Refusing to talk to non-LocalSystem Tunnel pipe server")?;
    }

    let mut server_pid: u32 = 0;
    // SAFETY: Windows doesn't store this pointer or handle, and we just got the handle
    // from Tokio, so it should be valid.
    unsafe { GetNamedPipeServerProcessId(handle, &mut server_pid) }
        .context("Couldn't get PID of named pipe server")?;

    tracing::debug!(?server_pid, "Made IPC connection");
    Ok(stream)
}

/// Verifies that the connected named pipe was created by `LocalSystem`, the
/// account the Tunnel service runs as.
///
/// `first_pipe_instance(true)` ensures nobody else can create another instance
/// of our pipe *while the legit server is bound*, but during the brief window
/// between teardown and re-bind (or before the service starts at all on a
/// just-booted machine) a local user-mode process can race to be the *first*
/// creator of the pipe name. The legit service then fails closed via
/// `ERROR_ACCESS_DENIED`, leaving the squatter as the only server. This check
/// catches that case before the GUI sends anything sensitive over the wire.
///
/// We inspect the *owner* of the kernel pipe object (set at creation time)
/// rather than the server's current process token. The latter is racy if the
/// server process exits and its PID is recycled between
/// `GetNamedPipeServerProcessId` and `OpenProcess`.
fn ensure_pipe_owner_is_local_system(handle: HANDLE) -> Result<()> {
    let mut owner_sid = PSID::default();
    let mut sd = PSECURITY_DESCRIPTOR::default();

    // SAFETY: All pointers below are out-pointers to stack locals. On success
    // the kernel allocates `sd` (which we release via `LocalFree`) and points
    // `owner_sid` into that allocation.
    let err = unsafe {
        GetSecurityInfo(
            handle,
            SE_KERNEL_OBJECT,
            OWNER_SECURITY_INFORMATION,
            Some(&mut owner_sid),
            None,
            None,
            None,
            Some(&mut sd),
        )
    };
    if err.0 != 0 {
        return Err(std::io::Error::from_raw_os_error(err.0 as i32))
            .context("GetSecurityInfo on pipe handle failed");
    }

    // SAFETY: `owner_sid` is a non-NULL pointer into `sd`'s buffer (still
    // alive for this call) and `IsWellKnownSid` does not retain it.
    let is_local_system = unsafe { IsWellKnownSid(owner_sid, WinLocalSystemSid) }.as_bool();

    // SAFETY: `sd` was allocated by `GetSecurityInfo` and must be released
    // with `LocalFree`. After this call no pointer derived from it is used.
    unsafe {
        let _ = LocalFree(Some(HLOCAL(sd.0)));
    }

    ensure!(
        is_local_system,
        "Tunnel pipe owner is not LocalSystem; possible pipe-squatting attack"
    );
    Ok(())
}

impl Server {
    /// Platform-specific setup
    #[expect(clippy::unnecessary_wraps, reason = "Linux impl is fallible")]
    pub(crate) fn new(id: SocketId) -> Result<Self> {
        let pipe_path = ipc_path(id);
        Ok(Self {
            pipe_path,
            socket_id: id,
        })
    }

    // `&mut self` needed to match the Linux signature
    pub(crate) async fn next_client(&mut self) -> Result<ServerStream> {
        // Fixes #5143. In the Tunnel service, if we close the pipe and immediately re-open
        // it, Tokio may not get a chance to clean up the pipe. Yielding seems to fix
        // this in tests, but `yield_now` doesn't make any such guarantees, so
        // we also do a loop.
        tokio::task::yield_now().await;

        let server = self
            .bind_to_pipe()
            .await
            .context("Couldn't bind to named pipe")?;
        // Note that Tokio has no `poll_connect`
        server
            .connect()
            .await
            .context("Couldn't accept IPC connection from GUI")?;
        let handle = HANDLE(server.as_raw_handle());
        let mut client_pid: u32 = 0;
        // SAFETY: Windows doesn't store this pointer or handle, and we just got the handle
        // from Tokio, so it should be valid.
        unsafe { GetNamedPipeClientProcessId(handle, &mut client_pid) }
            .context("Couldn't get PID of named pipe client")?;
        tracing::debug!(?client_pid, "Accepted IPC connection");
        Ok(server)
    }

    async fn bind_to_pipe(&self) -> Result<ServerStream> {
        // Defense-in-depth around #5143: when an IPC handler panics or otherwise
        // tears down the pipe and we immediately re-bind, Windows can briefly
        // return `AccessDenied` because the previous instance hasn't been fully
        // released yet. Polling on a short cadence is plenty — this typically
        // clears in tens of milliseconds. The previous 1s sleep was long enough
        // to make the `panic_inside_handler_doesnt_interrupt_service` unit test
        // race the test-side reconnect window on the `windows-2025` CI runner.
        const NUM_ITERS: usize = 100;
        const RETRY_INTERVAL: Duration = Duration::from_millis(100);
        for i in 0..NUM_ITERS {
            match create_pipe_server(&self.pipe_path, self.socket_id) {
                Ok(server) => return Ok(server),
                Err(PipeError::AccessDenied) => {
                    tracing::debug!("PipeError::AccessDenied, sleeping... (loop {i})");
                    tokio::time::sleep(RETRY_INTERVAL).await;
                }
                Err(error) => Err(error)?,
            }
        }
        bail!("Tried {NUM_ITERS} times to bind the pipe and failed");
    }
}

#[derive(Debug, thiserror::Error)]
enum PipeError {
    #[error("Access denied - Is another process using this pipe path?")]
    AccessDenied,
    #[error(transparent)]
    Other(#[from] anyhow::Error),
}

fn create_pipe_server(
    pipe_path: &str,
    id: SocketId,
) -> Result<named_pipe::NamedPipeServer, PipeError> {
    let mut server_options = named_pipe::ServerOptions::new();
    server_options.first_pipe_instance(true);

    let sddl = pipe_sddl(id).map_err(|e| PipeError::Other(e.context("Failed to build SDDL")))?;
    let sd = SecurityDescriptor::from_sddl(&sddl).map_err(PipeError::Other)?;
    let mut sa = SECURITY_ATTRIBUTES {
        nLength: std::mem::size_of::<SECURITY_ATTRIBUTES>() as u32,
        lpSecurityDescriptor: sd.as_raw().0,
        bInheritHandle: false.into(),
    };

    let sa_ptr = &mut sa as *mut _ as *mut c_void;
    // SAFETY: `sa_ptr` is a valid pointer to a fully-initialised
    // `SECURITY_ATTRIBUTES`. The kernel copies the security descriptor during
    // `CreateNamedPipeW`, so `sd` may be dropped after the call returns.
    match unsafe { server_options.create_with_security_attributes_raw(pipe_path, sa_ptr) } {
        Ok(x) => Ok(x),
        Err(err) if err.kind() == std::io::ErrorKind::PermissionDenied => {
            Err(PipeError::AccessDenied)
        }
        Err(err) => Err(anyhow::Error::from(err).into()),
    }
}

/// Builds the SDDL applied to a Firezone named pipe at creation time.
///
/// On Win10 21H2+ where the sparse MSIX has registered, both the Tunnel
/// and GUI pipes carry an `Allow` ACE keyed on the kernel-tracked
/// package SID, replacing the spoofable
/// `GetNamedPipeClientProcessId` -> `WinVerifyTrust` chain. The GUI pipe
/// additionally narrows access to the owning user via a conditional
/// ACE, so a same-machine attacker who somehow has the package SID
/// (e.g. another logged-in account running Firezone) still can't reach
/// a different user's GUI process.
///
/// On older Windows (build < 19044) the kernel won't attach the package
/// SID to our processes, so we fall back to the legacy `BU` ACE on the
/// Tunnel pipe and document the weaker security on those targets.
///
/// Debug builds always include `BU` so the smoke-test runner — which is
/// not registered as a package — can connect.
fn pipe_sddl(id: SocketId) -> Result<String> {
    let pkg_active = package_identity_active();
    let mut sddl = String::from("D:P(A;;FA;;;SY)(A;;FA;;;BA)");

    match id {
        SocketId::Tunnel => {
            if pkg_active {
                sddl.push_str(&format!("(A;;FRFW;;;{})", crate::PACKAGE_SID));
            }
            if !pkg_active || cfg!(debug_assertions) {
                sddl.push_str("(A;;FRFW;;;BU)");
            }
        }
        SocketId::Gui => {
            if pkg_active {
                let user_sid = cached_current_user_sid_string()
                    .context("Failed to obtain current user SID for GUI pipe DACL")?;
                sddl.push_str(&format!(
                    "(XA;;FRFW;;;{pkg};(Member_of {{SID({user})}}))",
                    pkg = crate::PACKAGE_SID,
                    user = user_sid,
                ));
            }
            if !pkg_active || cfg!(debug_assertions) {
                sddl.push_str("(A;;FRFW;;;BU)");
            }
        }
        #[cfg(test)]
        SocketId::Test(_) => {
            // Tests run as the test process; package identity isn't applicable.
            sddl.push_str("(A;;FRFW;;;BU)");
        }
    }

    Ok(sddl)
}

/// Returns true when the calling process is part of a registered MSIX
/// package and therefore carries a kernel-attested package SID we can
/// pin in pipe DACLs.
///
/// We ask the kernel directly (`GetCurrentPackageFullName`) rather than
/// inferring from the OS version + a registry flag: this is the only
/// source of truth that's resilient to MSIX-registration failures, OS
/// upgrades that disable AppX (some hardened images), and dev builds
/// run unwrapped.
fn package_identity_active() -> bool {
    static CACHE: OnceLock<bool> = OnceLock::new();
    *CACHE.get_or_init(|| {
        let mut len: u32 = 0;
        // SAFETY: Both pointers may be null; the API returns
        // `ERROR_INSUFFICIENT_BUFFER` (122) on success when the buffer is
        // too small (the typical first call), or
        // `APPMODEL_ERROR_NO_PACKAGE` (15700) if the process has no package
        // identity. Either is safe to read off the return value alone.
        let result = unsafe { GetCurrentPackageFullName(&mut len, std::ptr::null_mut()) };
        result != APPMODEL_ERROR_NO_PACKAGE
    })
}

// `GetCurrentPackageFullName` is exported from `kernel32.dll` (it
// dispatches to `apphelp.dll` internally). Linking it manually keeps
// the call site stable across `windows` crate version bumps and
// avoids pulling in the heavy
// `Win32_Storage_Packaging_Appx` feature for one symbol.
#[link(name = "kernel32")]
unsafe extern "system" {
    fn GetCurrentPackageFullName(
        package_full_name_length: *mut u32,
        package_full_name: *mut u16,
    ) -> u32;
}

/// Cached wrapper around [`windows_security::current_user_sid_string`].
///
/// The SID doesn't change for the life of the process, and we compose it
/// into the GUI-pipe filename + DACL builder on every `accept` cycle —
/// caching saves a `OpenProcessToken` round-trip per accept without
/// changing the underlying Win32 calls.
fn cached_current_user_sid_string() -> Result<String> {
    static CACHE: OnceLock<String> = OnceLock::new();
    if let Some(sid) = CACHE.get() {
        return Ok(sid.clone());
    }

    let sid = current_user_sid_string()?;
    let _ = CACHE.set(sid.clone());
    Ok(sid)
}

/// Named pipe for an IPC connection.
///
/// On Win10 21H2+ where package identity is active, the GUI socket name
/// embeds a hash of the user SID. This avoids cross-user pipe-name
/// collisions on multi-user RDP hosts; the conditional ACE in
/// [`pipe_sddl`] is what actually enforces the security boundary.
fn ipc_path(id: SocketId) -> String {
    let name = match id {
        SocketId::Tunnel => format!("{}_tunnel.ipc", crate::BUNDLE_ID),
        SocketId::Gui => {
            if package_identity_active() {
                let suffix = current_user_hash().unwrap_or_else(|_| "fallback".into());
                format!("{}_gui_{}.ipc", crate::BUNDLE_ID, suffix)
            } else {
                format!("{}_gui.ipc", crate::BUNDLE_ID)
            }
        }
        #[cfg(test)]
        SocketId::Test(id) => format!("{}_test_{id}.ipc", crate::BUNDLE_ID),
    };
    named_pipe_path(&name)
}

fn current_user_hash() -> Result<String> {
    let user = cached_current_user_sid_string()?;
    let digest = Sha256::digest(user.as_bytes());
    Ok(hex::encode(&digest[..8]))
}

/// Returns a valid name for a Windows named pipe
///
/// # Arguments
///
/// * `id` - BUNDLE_ID, e.g. `dev.firezone.client`
///
/// Public because the GUI Client reuses this for deep links. Eventually that code
/// will be de-duped into this code.
pub fn named_pipe_path(id: &str) -> String {
    format!(r"\\.\pipe\{id}")
}

#[cfg(test)]
mod tests {
    use super::{Server, SocketId};
    use anyhow::Context as _;
    use futures::StreamExt;

    #[test]
    fn named_pipe_path() {
        assert_eq!(
            super::named_pipe_path("dev.firezone.client"),
            r"\\.\pipe\dev.firezone.client"
        );
    }

    #[test]
    fn ipc_path() {
        assert!(super::ipc_path(SocketId::Tunnel).starts_with(r"\\.\pipe\"));
    }

    /// Even on a host where package identity isn't active, the SDDL builder
    /// must produce a string the kernel will parse.
    #[test]
    fn tunnel_sddl_parses() {
        let sddl = super::pipe_sddl(SocketId::Tunnel).unwrap();
        windows_security::SecurityDescriptor::from_sddl(&sddl).unwrap();
        assert!(sddl.starts_with("D:P(A;;FA;;;SY)(A;;FA;;;BA)"));
    }

    #[tokio::test]
    async fn single_instance() -> anyhow::Result<()> {
        let _guard = logging::test("trace");
        const ID: SocketId = SocketId::Test(0x1A6FE1F6);
        let mut server_1 = Server::new(ID)?;
        let pipe_path = server_1.pipe_path.clone();

        tokio::spawn(async move {
            let (mut rx, _tx) = server_1.next_client_split::<(), ()>().await?;
            rx.next().await;
            Ok::<_, anyhow::Error>(())
        });

        let (_rx, _tx) =
            crate::ipc::connect::<(), ()>(ID, crate::ipc::ConnectOptions::default()).await?;

        match super::create_pipe_server(&pipe_path, ID) {
            Err(super::PipeError::AccessDenied) => {}
            Err(error) => {
                Err(error).context("Expected `PipeError::AccessDenied` but got another error")?
            }
            Ok(_) => anyhow::bail!("Expected `PipeError::AccessDenied` but got `Ok`"),
        }
        Ok(())
    }
}
