use crate::Cli;
use anyhow::{Context as _, Result};
use clap::Parser;
use connlib_client_shared::file_logger;
use std::{
    ffi::OsString,
    net::IpAddr,
    path::{Path, PathBuf},
    str::FromStr,
    task::{Context, Poll},
    time::Duration,
};
use tokio::sync::mpsc;
use tracing::subscriber::set_global_default;
use tracing_subscriber::{layer::SubscriberExt as _, EnvFilter, Layer, Registry};
use windows_service::{
    service::{
        ServiceControl, ServiceControlAccept, ServiceExitCode, ServiceState, ServiceStatus,
        ServiceType,
    },
    service_control_handler::{self, ServiceControlHandlerResult},
};

const SERVICE_NAME: &str = "firezone_client_ipc";
const SERVICE_TYPE: ServiceType = ServiceType::OWN_PROCESS;

pub(crate) struct Signals {
    sigint: tokio::signal::windows::CtrlC,
}

impl Signals {
    pub(crate) fn new() -> Result<Self> {
        let sigint = tokio::signal::windows::ctrl_c()?;
        Ok(Self { sigint })
    }

    pub(crate) fn poll(&mut self, cx: &mut Context) -> Poll<super::SignalKind> {
        if self.sigint.poll_recv(cx).is_ready() {
            return Poll::Ready(super::SignalKind::Interrupt);
        }
        Poll::Pending
    }
}

// The return value is useful on Linux
#[allow(clippy::unnecessary_wraps)]
pub(crate) fn check_token_permissions(_path: &Path) -> Result<()> {
    // TODO: Make sure the token is only readable by admin / our service user on Windows
    Ok(())
}

pub(crate) fn default_token_path() -> std::path::PathBuf {
    // TODO: System-wide default token path for Windows
    PathBuf::from("token.txt")
}

/// Only called from the GUI Client's build of the IPC service
///
/// On Windows, this is wrapped specially so that Windows' service controller
/// can launch it.
pub fn run_only_ipc_service() -> Result<()> {
    windows_service::service_dispatcher::start(SERVICE_NAME, ffi_service_run)?;
    Ok(())
}

// Generates `ffi_service_run` from `service_run`
windows_service::define_windows_service!(ffi_service_run, windows_service_run);

fn windows_service_run(_arguments: Vec<OsString>) {
    if let Err(_e) = fallible_windows_service_run() {
        todo!();
    }
}

#[cfg(debug_assertions)]
const SERVICE_RUST_LOG: &str = "debug";

#[cfg(not(debug_assertions))]
const SERVICE_RUST_LOG: &str = "info";

// Most of the Windows-specific service stuff should go here
fn fallible_windows_service_run() -> Result<()> {
    let cli = Cli::parse();
    let log_path =
        crate::known_dirs::ipc_service_logs().context("Can't compute IPC service logs dir")?;
    std::fs::create_dir_all(&log_path)?;
    let (layer, _handle) = file_logger::layer(&log_path);
    let filter = EnvFilter::from_str(SERVICE_RUST_LOG)?;
    let subscriber = Registry::default().with(layer.with_filter(filter));
    set_global_default(subscriber)?;
    tracing::info!(git_version = crate::GIT_VERSION);

    let rt = tokio::runtime::Runtime::new()?;
    let (shutdown_tx, shutdown_rx) = mpsc::channel(1);

    let event_handler = move |control_event| -> ServiceControlHandlerResult {
        tracing::debug!(?control_event);
        match control_event {
            // TODO
            ServiceControl::Interrogate => ServiceControlHandlerResult::NoError,
            ServiceControl::Stop => {
                tracing::info!("Got stop signal from service controller");
                shutdown_tx.blocking_send(()).unwrap();
                ServiceControlHandlerResult::NoError
            }
            ServiceControl::UserEvent(_) => ServiceControlHandlerResult::NoError,
            ServiceControl::Continue => ServiceControlHandlerResult::NotImplemented,
            ServiceControl::NetBindAdd => ServiceControlHandlerResult::NotImplemented,
            ServiceControl::NetBindDisable => ServiceControlHandlerResult::NotImplemented,
            ServiceControl::NetBindEnable => ServiceControlHandlerResult::NotImplemented,
            ServiceControl::NetBindRemove => ServiceControlHandlerResult::NotImplemented,
            ServiceControl::ParamChange => ServiceControlHandlerResult::NotImplemented,
            ServiceControl::Pause => ServiceControlHandlerResult::NotImplemented,
            ServiceControl::Preshutdown => ServiceControlHandlerResult::NotImplemented,
            ServiceControl::Shutdown => ServiceControlHandlerResult::NotImplemented,
            ServiceControl::HardwareProfileChange(_) => ServiceControlHandlerResult::NotImplemented,
            ServiceControl::PowerEvent(_) => ServiceControlHandlerResult::NotImplemented,
            ServiceControl::SessionChange(_) => ServiceControlHandlerResult::NotImplemented,
            ServiceControl::TimeChange => ServiceControlHandlerResult::NotImplemented,
            ServiceControl::TriggerEvent => ServiceControlHandlerResult::NotImplemented,
            _ => todo!(),
        }
    };

    // Tell Windows that we're running (equivalent to sd_notify in systemd)
    let status_handle = service_control_handler::register(SERVICE_NAME, event_handler)?;
    status_handle.set_service_status(ServiceStatus {
        service_type: SERVICE_TYPE,
        current_state: ServiceState::Running,
        controls_accepted: ServiceControlAccept::STOP | ServiceControlAccept::SHUTDOWN,
        exit_code: ServiceExitCode::Win32(0),
        checkpoint: 0,
        wait_hint: Duration::default(),
        process_id: None,
    })?;

    run_ipc_service(cli, rt, shutdown_rx)?;

    // Tell Windows that we're stopping
    status_handle.set_service_status(ServiceStatus {
        service_type: SERVICE_TYPE,
        current_state: ServiceState::Stopped,
        controls_accepted: ServiceControlAccept::empty(),
        exit_code: ServiceExitCode::Win32(0),
        checkpoint: 0,
        wait_hint: Duration::default(),
        process_id: None,
    })?;
    Ok(())
}

/// Common entry point for both the Windows-wrapped IPC service and the debug IPC service
///
/// Running as a Windows service is complicated, so to make debugging easier
/// we'll have a dev-only mode that runs all the IPC code as a normal process
/// in an admin console.
pub(crate) fn run_ipc_service(
    cli: Cli,
    rt: tokio::runtime::Runtime,
    shutdown_rx: mpsc::Receiver<()>,
) -> Result<()> {
    tracing::info!("run_ipc_service");
    rt.block_on(async { ipc_listen(cli, shutdown_rx).await })
}

async fn ipc_listen(_cli: Cli, mut shutdown_rx: mpsc::Receiver<()>) -> Result<()> {
    shutdown_rx.recv().await;

    Ok(())
}

pub fn system_resolvers() -> Result<Vec<IpAddr>> {
    let resolvers = ipconfig::get_adapters()?
        .iter()
        .flat_map(|adapter| adapter.dns_servers())
        .filter(|ip| match ip {
            IpAddr::V4(_) => true,
            // Filter out bogus DNS resolvers on my dev laptop that start with fec0:
            IpAddr::V6(ip) => !ip.octets().starts_with(&[0xfe, 0xc0]),
        })
        .copied()
        .collect();
    // This is private, so keep it at `debug` or `trace`
    tracing::debug!(?resolvers);
    Ok(resolvers)
}
