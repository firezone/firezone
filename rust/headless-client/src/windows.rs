//! Implementation of headless Client and IPC service for Windows
//!
//! Try not to panic in the IPC service. Windows doesn't consider the
//! service to be stopped even if its only process ends, for some reason.
//! We must tell Windows explicitly when our service is stopping.

use crate::{CliCommon, SignalKind};
use anyhow::{Context as _, Result};
use connlib_client_shared::file_logger;
use connlib_shared::BUNDLE_ID;
use std::{
    ffi::{c_void, OsString},
    os::windows::io::AsRawHandle,
    path::{Path, PathBuf},
    str::FromStr,
    time::Duration,
};
use tokio::net::windows::named_pipe;
use tracing::subscriber::set_global_default;
use tracing_subscriber::{layer::SubscriberExt as _, EnvFilter, Layer, Registry};
use windows::Win32::{
    Foundation::HANDLE, Security as WinSec, System::Pipes::GetNamedPipeClientProcessId,
};
use windows_service::{
    service::{
        ServiceControl, ServiceControlAccept, ServiceExitCode, ServiceState, ServiceStatus,
        ServiceType,
    },
    service_control_handler::{self, ServiceControlHandlerResult},
};

mod wintun_install;

#[cfg(debug_assertions)]
const SERVICE_RUST_LOG: &str = "firezone_headless_client=debug,firezone_tunnel=trace,phoenix_channel=debug,connlib_shared=debug,connlib_client_shared=debug,boringtun=debug,snownet=debug,str0m=info,info";

#[cfg(not(debug_assertions))]
const SERVICE_RUST_LOG: &str = "str0m=warn,info";

const SERVICE_NAME: &str = "firezone_client_ipc";
const SERVICE_TYPE: ServiceType = ServiceType::OWN_PROCESS;

// This looks like a pointless wrapper around `CtrlC`, because it must match
// the Linux signatures
pub(crate) struct Signals {
    sigint: tokio::signal::windows::CtrlC,
}

impl Signals {
    pub(crate) fn new() -> Result<Self> {
        let sigint = tokio::signal::windows::ctrl_c()?;
        Ok(Self { sigint })
    }

    pub(crate) async fn recv(&mut self) -> SignalKind {
        self.sigint.recv().await;
        SignalKind::Interrupt
    }
}

// The return value is useful on Linux
#[allow(clippy::unnecessary_wraps)]
pub(crate) fn check_token_permissions(_path: &Path) -> Result<()> {
    // TODO: For Headless Client, make sure the token is only readable by admin / our service user on Windows
    Ok(())
}

pub(crate) fn default_token_path() -> std::path::PathBuf {
    // TODO: For Headless Client, system-wide default token path for Windows
    PathBuf::from("token.txt")
}

/// Cross-platform entry point for systemd / Windows services
///
/// Linux uses the CLI args from here, Windows does not
pub(crate) fn run_ipc_service(_cli: CliCommon) -> Result<()> {
    windows_service::service_dispatcher::start(SERVICE_NAME, ffi_service_run).context("windows_service::service_dispatcher failed. This isn't running in an interactive terminal, right?")
}

// Generates `ffi_service_run` from `service_run`
windows_service::define_windows_service!(ffi_service_run, windows_service_run);

fn windows_service_run(arguments: Vec<OsString>) {
    let log_path = crate::known_dirs::ipc_service_logs()
        .expect("Should be able to compute IPC service logs dir");
    std::fs::create_dir_all(&log_path).expect("We should have permissions to create our log dir");
    let (layer, handle) = file_logger::layer(&log_path);
    let filter = EnvFilter::from_str(SERVICE_RUST_LOG)
        .expect("Hard-coded log filter should always be parsable");
    let subscriber = Registry::default().with(layer.with_filter(filter));
    set_global_default(subscriber).expect("`set_global_default` should always work)");
    tracing::info!(git_version = crate::GIT_VERSION);
    if let Err(error) = fallible_windows_service_run(arguments, handle) {
        tracing::error!(?error, "fallible_windows_service_run returned an error");
    }
    tracing::info!("Returning from `windows_service_run`");
}

// Most of the Windows-specific service stuff should go here
//
// The arguments don't seem to match the ones passed to the main thread at all.
fn fallible_windows_service_run(
    arguments: Vec<OsString>,
    logging_handle: file_logger::Handle,
) -> Result<()> {
    tracing::info!(?arguments, "fallible_windows_service_run");

    let rt = tokio::runtime::Runtime::new()?;
    rt.spawn(crate::heartbeat::heartbeat());

    let ipc_task = rt.spawn(super::ipc_listen());
    let ipc_task_ah = ipc_task.abort_handle();

    let event_handler = move |control_event| -> ServiceControlHandlerResult {
        tracing::debug!(?control_event);
        match control_event {
            // TODO
            ServiceControl::Interrogate => ServiceControlHandlerResult::NoError,
            ServiceControl::PowerEvent(event) => {
                tracing::info!(?event, "Power event");
                ServiceControlHandlerResult::NoError
            }
            ServiceControl::Shutdown | ServiceControl::Stop => {
                tracing::info!(?control_event, "Got stop signal from service controller");
                ipc_task_ah.abort();
                ServiceControlHandlerResult::NoError
            }
            ServiceControl::UserEvent(_) => ServiceControlHandlerResult::NoError,
            ServiceControl::Continue
            | ServiceControl::NetBindAdd
            | ServiceControl::NetBindDisable
            | ServiceControl::NetBindEnable
            | ServiceControl::NetBindRemove
            | ServiceControl::ParamChange
            | ServiceControl::Pause
            | ServiceControl::Preshutdown
            | ServiceControl::HardwareProfileChange(_)
            | ServiceControl::SessionChange(_)
            | ServiceControl::TimeChange
            | ServiceControl::TriggerEvent => {
                tracing::warn!(?control_event, "Unhandled service control event");
                ServiceControlHandlerResult::NotImplemented
            }
            _ => ServiceControlHandlerResult::NotImplemented,
        }
    };

    // Tell Windows that we're running (equivalent to sd_notify in systemd)
    let status_handle = service_control_handler::register(SERVICE_NAME, event_handler)?;
    status_handle.set_service_status(ServiceStatus {
        service_type: SERVICE_TYPE,
        current_state: ServiceState::Running,
        controls_accepted: ServiceControlAccept::POWER_EVENT
            | ServiceControlAccept::SHUTDOWN
            | ServiceControlAccept::STOP,
        exit_code: ServiceExitCode::Win32(0),
        checkpoint: 0,
        wait_hint: Duration::default(),
        process_id: None,
    })?;

    let result = match rt.block_on(ipc_task) {
        Err(join_error) if join_error.is_cancelled() => {
            // We cancelled because Windows asked us to shut down.
            Ok(())
        }
        Err(join_error) => Err(anyhow::Error::from(join_error).context("`ipc_listen` panicked")),
        Ok(Err(error)) => Err(error.context("`ipc_listen` failed")),
        Ok(Ok(impossible)) => match impossible {},
    };

    // Drop the logging handle so it flushes the logs before we let Windows kill our process.
    // There is no obvious and elegant way to do this, since the logging and `ServiceState`
    // changes are interleaved, not nested:
    // - Start logging
    // - ServiceState::Running
    // - Stop logging
    // - ServiceState::Stopped
    std::mem::drop(logging_handle);

    // Tell Windows that we're stopping
    // Per Windows docs, this will cause Windows to kill our process eventually.
    status_handle
        .set_service_status(ServiceStatus {
            service_type: SERVICE_TYPE,
            current_state: ServiceState::Stopped,
            controls_accepted: ServiceControlAccept::empty(),
            exit_code: ServiceExitCode::Win32(if result.is_ok() { 0 } else { 1 }),
            checkpoint: 0,
            wait_hint: Duration::default(),
            process_id: None,
        })
        .expect("Should be able to tell Windows we're stopping");
    result
}

pub(crate) struct IpcServer {
    // On Linux this has some fields
}

/// Opaque wrapper around platform-specific IPC stream
pub(crate) type IpcStream = named_pipe::NamedPipeServer;

impl IpcServer {
    /// Platform-specific setup
    ///
    /// This is async on Linux
    #[allow(clippy::unused_async)]
    pub(crate) async fn new() -> Result<Self> {
        setup_before_connlib()?;
        Ok(Self {})
    }

    pub(crate) async fn next_client(&mut self) -> Result<IpcStream> {
        let server = create_pipe_server()?;
        tracing::info!(
            server_pid = std::process::id(),
            "Listening for GUI to connect over IPC..."
        );
        server
            .connect()
            .await
            .context("Couldn't accept IPC connection from GUI")?;
        let handle = HANDLE(server.as_raw_handle() as isize);
        let mut client_pid: u32 = 0;
        // SAFETY: Windows doesn't store this pointer or handle, and we just got the handle
        // from Tokio, so it should be valid.
        unsafe { GetNamedPipeClientProcessId(handle, &mut client_pid) }
            .context("Couldn't get PID of named pipe client")?;
        tracing::info!(?client_pid, "Accepted IPC connection");
        Ok(server)
    }
}

fn create_pipe_server() -> Result<named_pipe::NamedPipeServer> {
    let mut server_options = named_pipe::ServerOptions::new();
    server_options.first_pipe_instance(true);

    // This will allow non-admin clients to connect to us even though we're running with privilege
    let mut sd = WinSec::SECURITY_DESCRIPTOR::default();
    let psd = WinSec::PSECURITY_DESCRIPTOR(&mut sd as *mut _ as *mut c_void);
    // SAFETY: Unsafe needed to call Win32 API. There shouldn't be any threading or lifetime problems, because we only pass pointers to our local vars to Win32, and Win32 shouldn't sae them anywhere.
    unsafe {
        // ChatGPT pointed me to these functions
        WinSec::InitializeSecurityDescriptor(
            psd,
            windows::Win32::System::SystemServices::SECURITY_DESCRIPTOR_REVISION,
        )
        .context("InitializeSecurityDescriptor failed")?;
        WinSec::SetSecurityDescriptorDacl(psd, true, None, false)
            .context("SetSecurityDescriptorDacl failed")?;
    }

    let mut sa = WinSec::SECURITY_ATTRIBUTES {
        nLength: 0,
        lpSecurityDescriptor: psd.0,
        bInheritHandle: false.into(),
    };
    sa.nLength = std::mem::size_of_val(&sa)
        .try_into()
        .context("Size of SECURITY_ATTRIBUTES struct is not right")?;

    let sa_ptr = &mut sa as *mut _ as *mut c_void;
    // SAFETY: Unsafe needed to call Win32 API. We only pass pointers to local vars, and Win32 shouldn't store them, so there shouldn't be any threading of lifetime problems.
    let server = unsafe { server_options.create_with_security_attributes_raw(pipe_path(), sa_ptr) }
        .context("Failed to listen on named pipe")?;
    Ok(server)
}

/// Named pipe for IPC between GUI client and IPC service
pub fn pipe_path() -> String {
    named_pipe_path(&format!("{BUNDLE_ID}.ipc_service"))
}

/// Returns a valid name for a Windows named pipe
///
/// # Arguments
///
/// * `id` - BUNDLE_ID, e.g. `dev.firezone.client`
pub fn named_pipe_path(id: &str) -> String {
    format!(r"\\.\pipe\{}", id)
}

// Does nothing on Windows. On Linux this notifies systemd that we're ready.
// When we eventually have a system service for the Windows Headless Client,
// this could notify the Windows service controller too.
#[allow(clippy::unnecessary_wraps)]
pub(crate) fn notify_service_controller() -> Result<()> {
    Ok(())
}

pub(crate) fn setup_before_connlib() -> Result<()> {
    wintun_install::ensure_dll()?;
    Ok(())
}

#[cfg(test)]
mod tests {
    #[test]
    fn named_pipe_path() {
        assert_eq!(
            super::named_pipe_path("dev.firezone.client"),
            r"\\.\pipe\dev.firezone.client"
        );
    }

    #[test]
    fn pipe_path() {
        assert!(super::pipe_path().starts_with(r"\\.\pipe\"));
    }
}
