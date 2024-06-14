//! Implementation of headless Client and IPC service for Windows
//!
//! Try not to panic in the IPC service. Windows doesn't consider the
//! service to be stopped even if its only process ends, for some reason.
//! We must tell Windows explicitly when our service is stopping.

use crate::{CliCommon, SignalKind};
use anyhow::{Context as _, Result};
use connlib_client_shared::file_logger;
use std::{
    ffi::OsString,
    path::{Path, PathBuf},
    time::Duration,
};
use windows_service::{
    service::{
        ServiceAccess, ServiceControl, ServiceControlAccept, ServiceErrorControl, ServiceExitCode,
        ServiceInfo, ServiceStartType, ServiceState, ServiceStatus, ServiceType,
    },
    service_control_handler::{self, ServiceControlHandlerResult},
    service_manager::{ServiceManager, ServiceManagerAccess},
};

mod wintun_install;

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

pub(crate) fn install_ipc_service() -> Result<()> {
    let manager_access = ServiceManagerAccess::CONNECT | ServiceManagerAccess::CREATE_SERVICE;
    let service_manager = ServiceManager::local_computer(None::<&str>, manager_access)?;

    let name = OsString::from("FirezoneClientIpcServiceDebug");

    // Un-install existing one first if needed
    {
        let service_access = ServiceAccess::DELETE;
        let service = service_manager.open_service(&name, service_access)?;
        service.delete()?;
    }

    let executable_path = std::env::current_exe()?;
    let service_info = ServiceInfo {
        name,
        display_name: OsString::from("Firezone Client IPC (Debug)"),
        service_type: ServiceType::OWN_PROCESS,
        start_type: ServiceStartType::AutoStart,
        error_control: ServiceErrorControl::Normal,
        executable_path,
        launch_arguments: vec!["run".into()],
        dependencies: vec![],
        account_name: None,
        account_password: None,
    };
    let service = service_manager.create_service(&service_info, ServiceAccess::CHANGE_CONFIG)?;
    service.set_description("Description")?;
    Ok(())
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
    // `arguments` doesn't seem to work right when running as a Windows service
    // (even though it's meant for that) so just use the default log dir.
    let handle = crate::setup_ipc_service_logging(None).expect("Should be able to set up logging");
    if let Err(error) = fallible_windows_service_run(arguments, handle) {
        tracing::error!(?error, "`fallible_windows_service_run` returned an error");
    }
}

// Most of the Windows-specific service stuff should go here
//
// The arguments don't seem to match the ones passed to the main thread at all.
//
// If Windows stops us gracefully, this function may never return.
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
        Ok(Err(error)) => Err(error.context("`ipc_listen` threw an error")),
        Ok(Ok(impossible)) => match impossible {},
    };
    if let Err(error) = &result {
        tracing::error!(?error, "`ipc_listen` failed");
    }

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
    // Generally unreachable
    Ok(())
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
