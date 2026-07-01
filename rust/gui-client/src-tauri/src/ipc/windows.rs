use super::{NotFound, SocketId, WrongUser};
use anyhow::{Context as _, Result, bail};
#[cfg(debug_assertions)]
use std::sync::atomic::{AtomicBool, Ordering};
use std::{ffi::c_void, io::ErrorKind, os::windows::io::AsRawHandle, time::Duration};
use tokio::net::windows::named_pipe;
use windows::Win32::{
    Foundation::{HANDLE, HLOCAL},
    Security::{
        Authorization::{GetSecurityInfo, SE_KERNEL_OBJECT},
        IsWellKnownSid, OWNER_SECURITY_INFORMATION, PSECURITY_DESCRIPTOR, PSID,
        SECURITY_ATTRIBUTES, WinLocalSystemSid,
    },
    System::{
        Pipes::{
            GetNamedPipeClientProcessId, GetNamedPipeClientSessionId, GetNamedPipeServerProcessId,
            GetNamedPipeServerSessionId,
        },
        RemoteDesktop::ProcessIdToSessionId,
        Threading::GetCurrentProcessId,
    },
};
use windows::core::Owned;
use windows_security::pipe_dacl::{FileRights, PipeDacl, Trustee};

/// Security descriptor for the Tunnel pipe.
///
/// - Owner is pinned to `LocalSystem`. Without that the kernel fills
///   in the owner from the creating token's `TokenOwner`; for the
///   LocalSystem token that is `BUILTIN\Administrators`
///   (S-1-5-32-544, not S-1-5-18), which would cause the client-side
///   check in [`is_pipe_owned_by_local_system`] to reject the
///   legitimate pipe.
/// - ACEs: Full Access for `LocalSystem` (the account the service
///   runs as); read/write for any process carrying the Firezone
///   package's `WIN://SYSAPPID` identity attribute (a conditional
///   ACE keyed on [`crate::PACKAGE_FAMILY_NAME`]). No
///   `BUILTIN\Administrators` grant: only the package-identity'd GUI
///   should drive the tunnel, not arbitrary elevated processes.
///
/// We match `WIN://SYSAPPID` rather than the AppContainer package SID
/// because the GUI is a *full-trust* packaged app: it runs as the
/// user with no AppContainer, so its token never carries the
/// `S-1-15-2-…` package SID, but the kernel does stamp every packaged
/// process with the `SYSAPPID` attribute.
///
/// In debug builds the Tunnel pipe may also be opened without the
/// `Owner` pin — see [`skip_tunnel_pipe_owner_check`] — so the
/// `gui-smoke-test`, which launches the Tunnel binary as a
/// subprocess of the test runner (not as a service running under
/// LocalSystem), doesn't fail `CreateNamedPipeW` with
/// `ERROR_INVALID_OWNER` (1307). Smoke tests fall back to
/// [`test_pipe_dacl`] for that reason.
fn tunnel_pipe_dacl() -> PipeDacl {
    PipeDacl::new()
        .owner(Trustee::local_system())
        .allow(FileRights::FullAccess, Trustee::local_system())
        .allow_packaged(FileRights::ReadWrite, crate::PACKAGE_FAMILY_NAME)
}

/// Security descriptor for the GUI pipe.
///
/// Same ACEs as [`tunnel_pipe_dacl`], but no `Owner` clause: the
/// non-admin GUI lacks `SeRestorePrivilege` and cannot pin an owner
/// outside its own token. The GUI pipe's owner isn't validated by
/// clients, so leaving it at the token default is fine.
fn gui_pipe_dacl() -> PipeDacl {
    PipeDacl::new()
        .allow(FileRights::FullAccess, Trustee::local_system())
        .allow_packaged(FileRights::ReadWrite, crate::PACKAGE_FAMILY_NAME)
}

/// Relaxed DACL for test contexts (gui-smoke-test, `SocketId::Test`
/// unit tests). The production DACLs grant read/write only to
/// processes carrying the Firezone package identity -- but a `cargo
/// run` / `cargo test` process has no MSIX identity, so opening
/// either pipe would fail with `ERROR_ACCESS_DENIED`. Grant
/// `BUILTIN\Users` instead so the test process can act as both server
/// and client.
#[cfg(any(debug_assertions, test))]
fn test_pipe_dacl() -> PipeDacl {
    PipeDacl::new()
        .allow(FileRights::FullAccess, Trustee::local_system())
        .allow(FileRights::FullAccess, Trustee::builtin_administrators())
        .allow(FileRights::ReadWrite, Trustee::builtin_users())
}

/// Whether to skip the tunnel pipe owner check.
#[cfg(debug_assertions)]
static SKIP_TUNNEL_PIPE_OWNER_CHECK: AtomicBool = AtomicBool::new(false);

/// Set [`SKIP_TUNNEL_PIPE_OWNER_CHECK`].
///
/// Call once at process startup, before any `Server::new(SocketId::Tunnel)` or `connect_to_socket`.
#[cfg(debug_assertions)]
pub fn skip_tunnel_pipe_owner_check() {
    SKIP_TUNNEL_PIPE_OWNER_CHECK.store(true, Ordering::Relaxed);
}

pub struct Server {
    socket_id: SocketId,
    pipe_path: String,
    dacl: PipeDacl,
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

    enforce_pipe_ownership(id, handle)?;

    tracing::debug!(server_pid = pipe_server_pid(handle)?, "Made IPC connection");
    Ok(stream)
}

fn enforce_pipe_ownership(id: SocketId, handle: HANDLE) -> Result<()> {
    match id {
        #[cfg(test)]
        SocketId::Test(_) => Ok(()),
        #[cfg(debug_assertions)]
        SocketId::Tunnel if SKIP_TUNNEL_PIPE_OWNER_CHECK.load(Ordering::Relaxed) => Ok(()),
        // Refuse to connect to tunnel pipes not owned by local system
        SocketId::Tunnel if !is_pipe_owned_by_local_system(handle)? => {
            bail!("Tunnel pipe owner is not LocalSystem; possible pipe-squatting attack")
        }
        // Refuse to connect to GUI pipes owned by a different logon session
        SocketId::Gui if !is_pipe_server_owned_by_current_session(handle)? => {
            bail!(WrongUser)
        }
        SocketId::Tunnel | SocketId::Gui => Ok(()),
    }
}

impl Server {
    /// Platform-specific setup
    #[expect(clippy::unnecessary_wraps, reason = "Linux impl is fallible")]
    pub(crate) fn new(id: SocketId) -> Result<Self> {
        let pipe_path = ipc_path(id);
        let dacl = match id {
            // `gui-smoke-test` runs debug GUI / Tunnel binaries that
            // carry no MSIX identity, so they can't open a
            // package-SID-pinned pipe. The smoke test sets the skip
            // flag, so reuse it to fall back to the relaxed test DACL
            // for both pipes.
            #[cfg(debug_assertions)]
            SocketId::Tunnel | SocketId::Gui
                if SKIP_TUNNEL_PIPE_OWNER_CHECK.load(Ordering::Relaxed) =>
            {
                test_pipe_dacl()
            }
            SocketId::Tunnel => tunnel_pipe_dacl(),
            SocketId::Gui => gui_pipe_dacl(),
            #[cfg(test)]
            SocketId::Test(_) => test_pipe_dacl(),
        };
        Ok(Self {
            socket_id: id,
            pipe_path,
            dacl,
        })
    }

    // `&mut self` needed to match the Linux signature
    pub(crate) async fn next_client(&mut self) -> Result<(ServerStream, u32)> {
        // Fixes #5143. In the Tunnel service, if we close the pipe and immediately re-open
        // it, Tokio may not get a chance to clean up the pipe. Yielding seems to fix
        // this in tests, but `yield_now` doesn't make any such guarantees, so
        // `bind_to_pipe` also runs its own retry loop.
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
        let client_pid = pipe_client_pid(handle)?;

        // GUI pipe: refuse a client running in a different logon
        // session (cross-user FUS/RDP). Caller-side
        // (`controller::eventloop`) calls `next_client` again on the
        // next iteration, so we just return an error here -- no
        // internal retry loop.
        if matches!(self.socket_id, SocketId::Gui)
            && !is_pipe_client_owned_by_current_session(handle)?
        {
            bail!("Dropped IPC connection from PID {client_pid} -- different logon session");
        }

        tracing::debug!(?client_pid, "Accepted IPC connection");
        Ok((server, client_pid))
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
            match create_pipe_server(&self.pipe_path, &self.dacl) {
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
    dacl: &PipeDacl,
) -> Result<named_pipe::NamedPipeServer, PipeError> {
    let mut server_options = named_pipe::ServerOptions::new();
    server_options.first_pipe_instance(true);

    // Build a `SECURITY_ATTRIBUTES` that grants the non-admin GUI (running as
    // `BUILTIN\Users`) read/write access to the pipe while keeping it shut to
    // `NETWORK SERVICE`, anonymous logons, and other unintended principals.
    let sd = dacl.build().map_err(PipeError::Other)?;
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

fn ipc_path(id: SocketId) -> String {
    let name = match id {
        SocketId::Tunnel => format!("{}_tunnel.ipc", crate::BUNDLE_ID),
        SocketId::Gui => format!("{}_gui.ipc", crate::BUNDLE_ID),
        #[cfg(test)]
        SocketId::Test(id) => format!("{}_test_{id}.ipc", crate::BUNDLE_ID),
    };
    named_pipe_path(&name)
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

/// Checks if the connected named pipe was created by `LocalSystem`, the
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
fn is_pipe_owned_by_local_system(handle: HANDLE) -> Result<bool> {
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
    // SAFETY: `sd` was allocated by `GetSecurityInfo` via `LocalAlloc`;
    // wrap the underlying pointer as `HLOCAL` so `LocalFree` runs on
    // scope exit. `owner_sid` points into this allocation.
    let _sd_owned = unsafe { Owned::new(HLOCAL(sd.0)) };

    // SAFETY: `owner_sid` is a non-NULL pointer into `sd`'s buffer (still
    // alive for this call) and `IsWellKnownSid` does not retain it.
    let is_local_system = unsafe { IsWellKnownSid(owner_sid, WinLocalSystemSid) }.as_bool();

    Ok(is_local_system)
}

/// Whether the pipe was *created* in this process's logon session.
/// The kernel snapshots the value at `CreateNamedPipeW` time, so
/// this is TOCTOU-safe.
fn is_pipe_server_owned_by_current_session(handle: HANDLE) -> Result<bool> {
    let mut server = 0u32;
    // SAFETY: `handle` is a live pipe handle from Tokio; the kernel
    // writes only to `&mut server` and doesn't retain the pointer.
    unsafe { GetNamedPipeServerSessionId(handle, &mut server) }
        .context("GetNamedPipeServerSessionId failed")?;

    Ok(server == current_session_id()?)
}

/// Whether the pipe was *connected* by a process in this process's
/// logon session. Snapshotted at connection time by the kernel.
fn is_pipe_client_owned_by_current_session(handle: HANDLE) -> Result<bool> {
    let mut client = 0u32;
    // SAFETY: `handle` is a live pipe handle from Tokio; the kernel
    // writes only to `&mut client` and doesn't retain the pointer.
    unsafe { GetNamedPipeClientSessionId(handle, &mut client) }
        .context("GetNamedPipeClientSessionId failed")?;

    Ok(client == current_session_id()?)
}

/// The current process's logon-session ID, via
/// `ProcessIdToSessionId(GetCurrentProcessId(), …)`.
fn current_session_id() -> Result<u32> {
    let mut session = 0u32;
    // SAFETY: `GetCurrentProcessId` is infallible; `&mut session` is a
    // valid out-pointer.
    unsafe { ProcessIdToSessionId(GetCurrentProcessId(), &mut session) }
        .context("ProcessIdToSessionId failed")?;

    Ok(session)
}

/// Wraps `GetNamedPipeClientProcessId`. Used only for tracing.
fn pipe_client_pid(handle: HANDLE) -> Result<u32> {
    let mut pid = 0u32;
    // SAFETY: `handle` is a live pipe handle from Tokio.
    unsafe { GetNamedPipeClientProcessId(handle, &mut pid) }
        .context("GetNamedPipeClientProcessId failed")?;

    Ok(pid)
}

/// Wraps `GetNamedPipeServerProcessId`. Used only for tracing.
fn pipe_server_pid(handle: HANDLE) -> Result<u32> {
    let mut pid = 0u32;
    // SAFETY: `handle` is a live pipe handle from Tokio.
    unsafe { GetNamedPipeServerProcessId(handle, &mut pid) }
        .context("GetNamedPipeServerProcessId failed")?;

    Ok(pid)
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

    #[tokio::test]
    async fn single_instance() -> anyhow::Result<()> {
        let _guard = logging::test("trace");
        const ID: SocketId = SocketId::Test(0x1A6FE1F6);
        let mut server_1 = Server::new(ID)?;
        let pipe_path = server_1.pipe_path.clone();

        tokio::spawn(async move {
            let (mut rx, _tx, _pid) = server_1.next_client_split::<(), ()>().await?;
            rx.next().await;
            Ok::<_, anyhow::Error>(())
        });

        let (_rx, _tx) =
            crate::ipc::connect::<(), ()>(ID, crate::ipc::ConnectOptions::default()).await?;

        match super::create_pipe_server(&pipe_path, &super::gui_pipe_dacl()) {
            Err(super::PipeError::AccessDenied) => {}
            Err(error) => {
                Err(error).context("Expected `PipeError::AccessDenied` but got another error")?
            }
            Ok(_) => anyhow::bail!("Expected `PipeError::AccessDenied` but got `Ok`"),
        }
        Ok(())
    }
}
