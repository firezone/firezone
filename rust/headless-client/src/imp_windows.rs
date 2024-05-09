//! Implementation of headless Client and IPC service for Windows
//!
//! Try not to panic in the IPC service. Windows doesn't seem to accept
//! the process ending as a signal that the service is stopped, we have to
//! explicitly tell it. I am not sure why.

use crate::{Cli, Cmd, IpcClientMsg, IpcServerMsg, SignalKind};
use anyhow::{Context as _, Result};
use clap::Parser;
use connlib_client_shared::file_logger;
use connlib_shared::BUNDLE_ID;
use futures::{Future, SinkExt, StreamExt};
use std::{
    ffi::{c_void, OsString},
    net::IpAddr,
    path::{Path, PathBuf},
    pin::pin,
    str::FromStr,
    task::{Context, Poll},
    time::Duration,
};
use tokio::{net::windows::named_pipe, sync::mpsc};
use tokio_util::codec::{Framed, LengthDelimitedCodec};
use tracing::subscriber::set_global_default;
use tracing_subscriber::{layer::SubscriberExt as _, EnvFilter, Layer, Registry};
use windows::Win32::Security as WinSec;
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

    pub(crate) fn poll(&mut self, cx: &mut Context) -> Poll<SignalKind> {
        if self.sigint.poll_recv(cx).is_ready() {
            return Poll::Ready(SignalKind::Interrupt);
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
/// However, this is shared between the debug mode (running interactively)
/// and the Windows service
pub fn run_only_ipc_service() -> Result<()> {
    let cli = Cli::parse();
    match cli.command {
        Cmd::DebugIpcService => run_debug_ipc_service(cli),
        Cmd::IpcService => run_ipc_service(cli),
        Cmd::Standalone => {
            anyhow::bail!("Standlone should not be used from the IPC service binary")
        }
    }
}

fn run_debug_ipc_service(cli: Cli) -> Result<()> {
    crate::debug_command_setup()?;
    let rt = tokio::runtime::Runtime::new()?;
    let mut ipc_service = pin!(ipc_listen(cli));
    let mut signals = Signals::new()?;
    rt.block_on(async {
        std::future::poll_fn(|cx| {
            match signals.poll(cx) {
                Poll::Ready(SignalKind::Hangup) => {
                    return Poll::Ready(Err(anyhow::anyhow!(
                        "Impossible, we don't catch Hangup on Windows"
                    )))
                }
                Poll::Ready(SignalKind::Interrupt) => {
                    tracing::info!("Caught Interrupt signal");
                    return Poll::Ready(Ok(()));
                }
                Poll::Pending => {}
            }

            match ipc_service.as_mut().poll(cx) {
                Poll::Ready(Ok(())) => {
                    return Poll::Ready(Err(anyhow::anyhow!(
                        "Impossible, ipc_listen can't return Ok"
                    )))
                }
                Poll::Ready(Err(error)) => {
                    tracing::error!(?error, "error from ipc_listen");
                    return Poll::Ready(Err(error));
                }
                Poll::Pending => {}
            }

            Poll::Pending
        })
        .await
    })
}

pub(crate) fn run_ipc_service(_cli: Cli) -> Result<()> {
    windows_service::service_dispatcher::start(SERVICE_NAME, ffi_service_run).context("windows_service::service_dispatcher::start failed. This is running from the service controller, not from an interactive terminal, right?")?;
    Ok(())
}

// Generates `ffi_service_run` from `service_run`
windows_service::define_windows_service!(ffi_service_run, infallible_windows_service_run);

// At this point we are definitely running as a Windows service.
// However, `windows_service` doesn't handle `Result` values, so we have
// to decide what to do with those.
fn infallible_windows_service_run(arguments: Vec<OsString>) {
    if let Err(error) = windows_service_run(arguments) {
        tracing::error!(?error, "Error from windows_service_run");
    }
}

#[cfg(debug_assertions)]
const SERVICE_RUST_LOG: &str = "debug";

#[cfg(not(debug_assertions))]
const SERVICE_RUST_LOG: &str = "info";

// Now we have error handling set up and we're definitely a Windows service.
// Keep all the Window service-specific code in here.
fn windows_service_run(arguments: Vec<OsString>) -> Result<()> {
    let cli = Cli::parse_from(arguments);

    // Set up file-only logging for Window services. AFAIK they don't have consoles.
    // I don't think their stdout and stderr goes anywhere.
    let log_path =
        crate::known_dirs::ipc_service_logs().context("Can't compute IPC service logs dir")?;
    std::fs::create_dir_all(&log_path)?;
    let (layer, _handle) = file_logger::layer(&log_path);
    let filter = EnvFilter::from_str(SERVICE_RUST_LOG)?;
    let subscriber = Registry::default().with(layer.with_filter(filter));
    set_global_default(subscriber)?;
    tracing::info!(git_version = crate::GIT_VERSION);

    let (shutdown_tx, mut shutdown_rx) = mpsc::channel(1);

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

    // Fixes <https://github.com/firezone/firezone/issues/4899>,
    // DNS rules persisting after reboot
    connlib_shared::deactivate_dns_control().ok();

    // Tell Windows that we're running (equivalent to sd_notify in systemd)
    let status_handle = service_control_handler::register(SERVICE_NAME, event_handler)
        .context("Couldn't register with Windows service controller")?;
    status_handle.set_service_status(ServiceStatus {
        service_type: SERVICE_TYPE,
        current_state: ServiceState::Running,
        controls_accepted: ServiceControlAccept::STOP | ServiceControlAccept::SHUTDOWN,
        exit_code: ServiceExitCode::Win32(0),
        checkpoint: 0,
        wait_hint: Duration::default(),
        process_id: None,
    })?;

    let rt = tokio::runtime::Runtime::new()?;
    let mut ipc_service = pin!(ipc_listen(cli));
    rt.block_on(async {
        std::future::poll_fn(|cx| {
            match shutdown_rx.poll_recv(cx) {
                Poll::Ready(Some(())) => {
                    tracing::info!("Got shutdown signal");
                    return Poll::Ready(());
                }
                Poll::Ready(None) => {
                    tracing::warn!("shutdown channel unexpectedly dropped, shutting down");
                    return Poll::Ready(());
                }
                Poll::Pending => {}
            }

            match ipc_service.as_mut().poll(cx) {
                Poll::Ready(Ok(())) => {
                    tracing::error!("Impossible, ipc_listen can't return Ok");
                    return Poll::Ready(());
                }
                Poll::Ready(Err(error)) => {
                    tracing::error!(?error, "error from ipc_listen");
                    return Poll::Ready(());
                }
                Poll::Pending => {}
            }

            Poll::Pending
        })
        .await
    });

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
/// Params:
/// * `_cli` - Will be needed later for max partition time and stuff
pub(crate) async fn ipc_listen(_cli: Cli) -> Result<()> {
    loop {
        connlib_shared::deactivate_dns_control()?;
        let server = create_pipe_server()?;
        tracing::info!("Listening for GUI to connect over IPC...");
        server
            .connect()
            .await
            .context("Couldn't accept IPC connection from GUI")?;
        if let Err(error) = handle_ipc_client(server).await {
            tracing::error!(?error, "Error while handling IPC client");
        }
    }
}

fn create_pipe_server() -> Result<named_pipe::NamedPipeServer> {
    let mut server_options = named_pipe::ServerOptions::new();
    server_options.first_pipe_instance(true);

    // This will allow non-admin clients to connect to us even though we're running with privilege
    let mut sd = WinSec::SECURITY_DESCRIPTOR::default();
    let psd = WinSec::PSECURITY_DESCRIPTOR(&mut sd as *mut _ as *mut c_void);
    // SAFETY: Unsafe needed to call Win32 API. There shouldn't be any threading
    // or lifetime problems because we only pass pointers to our local vars to
    // Win32, and Win32 shouldn't save them anywhere.
    unsafe {
        // ChatGPT pointed me to these functions, it's better than the official MS docs
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
    // SAFETY: Unsafe needed to call Win32 API. There shouldn't be any threading
    // or lifetime problems because we only pass pointers to our local vars to
    // Win32, and Win32 shouldn't save them anywhere.
    let server = unsafe { server_options.create_with_security_attributes_raw(pipe_path(), sa_ptr) }
        .context("Failed to listen on named pipe")?;
    Ok(server)
}

/// Named pipe for IPC between a non-privileged GUI and the privileged IPC service
pub fn pipe_path() -> String {
    named_pipe_path(format!("{BUNDLE_ID}.ipc_service"))
}

async fn handle_ipc_client(server: named_pipe::NamedPipeServer) -> Result<()> {
    let mut framed = Framed::new(server, LengthDelimitedCodec::new());
    let msg = framed
        .next()
        .await
        .context("expected a message from the IPC client")??;
    let _msg: IpcClientMsg = serde_json::from_slice(&msg)?;
    let response = IpcServerMsg::Ok;
    framed
        .send(serde_json::to_string(&response)?.into())
        .await?;
    todo!()
}

/// Get the underlying system resolvers, e.g. the LAN gateway or Cloudflare
///
/// pub because it's shared between the headless and GUI Clients
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

/// Returns a valid name for a Windows named pipe
///
/// # Arguments
///
/// * `id` - BUNDLE_ID, e.g. `dev.firezone.client`
pub fn named_pipe_path<S: AsRef<str>>(id: S) -> String {
    format!(r"\\.\pipe\{}", id.as_ref())
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
}
