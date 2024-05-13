//! Implementation of headless Client and IPC service for Windows
//!
//! Try not to panic in the IPC service. Windows doesn't consider the
//! service to be stopped even if its only process ends, for some reason.
//! We must tell Windows explicitly when our service is stopping.

use crate::{IpcClientMsg, IpcServerMsg, SignalKind};
use anyhow::{bail, Context as _, Result};
use clap::Parser;
use connlib_client_shared::file_logger;
use connlib_shared::BUNDLE_ID;
use futures::{SinkExt, StreamExt};
use std::{
    ffi::{c_void, OsString},
    future::Future,
    net::IpAddr,
    path::{Path, PathBuf},
    pin::pin,
    str::FromStr,
    task::{Context, Poll},
    time::Duration,
};
use tokio::{
    net::windows::named_pipe::self,
    sync::mpsc,
};
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

#[derive(clap::Parser, Default)]
#[command(author, version, about, long_about = None)]
struct CliIpcService {
    #[command(subcommand)]
    command: CmdIpc,
}

#[derive(clap::Subcommand)]
enum CmdIpc {
    #[command(hide = true)]
    DebugIpcService,
    IpcService,
}

impl Default for CmdIpc {
    fn default() -> Self {
        Self::IpcService
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
    let cli = CliIpcService::parse();
    match cli.command {
        CmdIpc::DebugIpcService => run_debug_ipc_service(cli),
        CmdIpc::IpcService => windows_service::service_dispatcher::start(SERVICE_NAME, ffi_service_run).context("windows_service::service_dispatcher failed. This isn't running in an interactive terminal, right?"),
    }
}

fn run_debug_ipc_service(cli: CliIpcService) -> Result<()> {
    crate::debug_command_setup()?;
    let rt = tokio::runtime::Runtime::new()?;
    let mut ipc_service = pin!(ipc_listen(cli));
    let mut signals = Signals::new()?;
    rt.block_on(async {
        std::future::poll_fn(|cx| {
            match signals.poll(cx) {
                Poll::Ready(SignalKind::Hangup) => {
                    return Poll::Ready(Err(anyhow::anyhow!("Impossible, we don't catch Hangup on Windows")));
                }
                Poll::Ready(SignalKind::Interrupt) => {
                    tracing::info!("Caught Interrupt signal");
                    return Poll::Ready(Ok(()));
                }
                Poll::Pending => {}
            }

            match ipc_service.as_mut().poll(cx) {
                Poll::Ready(Ok(())) => {
                    return Poll::Ready(Err(anyhow::anyhow!("Impossible, ipc_listencan't return Ok")));
                }
                Poll::Ready(Err(error)) => {
                    return Poll::Ready(Err(error).context("ipc_listen failed"));
                }
                Poll::Pending => {}
            }

            Poll::Pending
        }).await
    })
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
    let log_path =
        crate::known_dirs::imp::ipc_service_logs().context("Can't compute IPC service logs dir")?;
    std::fs::create_dir_all(&log_path)?;
    let (layer, _handle) = file_logger::layer(&log_path);
    let filter = EnvFilter::from_str(SERVICE_RUST_LOG)?;
    let subscriber = Registry::default().with(layer.with_filter(filter));
    set_global_default(subscriber)?;
    tracing::info!(git_version = crate::GIT_VERSION);

    let rt = tokio::runtime::Runtime::new()?;
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
            ServiceControl::Continue
            | ServiceControl::NetBindAdd
            | ServiceControl::NetBindDisable
            | ServiceControl::NetBindEnable
            | ServiceControl::NetBindRemove
            | ServiceControl::ParamChange
            | ServiceControl::Pause
            | ServiceControl::Preshutdown
            | ServiceControl::Shutdown
            | ServiceControl::HardwareProfileChange(_)
            | ServiceControl::PowerEvent(_)
            | ServiceControl::SessionChange(_)
            | ServiceControl::TimeChange
            | ServiceControl::TriggerEvent => ServiceControlHandlerResult::NotImplemented,
            _ => ServiceControlHandlerResult::NotImplemented,
        }
    };

    // Fixes <https://github.com/firezone/firezone/issues/4899>,
    // DNS rules persisting after reboot
    connlib_shared::deactivate_dns_control().ok();

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

    let mut ipc_service = pin!(ipc_listen(CliIpcService::default()));
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

async fn ipc_listen(_cli: CliIpcService) -> Result<()> {
    loop {
        // This is redundant on the first loop. After that it clears the rules
        // between GUI instances.
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
    // SAFETY: Unsafe needed to call Win32 API. There shouldn't be any threading or lifetime problems, because we only pass pointers to our local vars to Win32, and Win32 shouldn't sae them anywhere.
    unsafe {
        // ChatGPT pointed me to these functions
        WinSec::InitializeSecurityDescriptor(psd, windows::Win32::System::SystemServices::SECURITY_DESCRIPTOR_REVISION).context("InitializeSecurityDescriptor failed")?;
        WinSec::SetSecurityDescriptorDacl(psd, true, None, false).context("SetSecurityDescriptorDacl failed")?;
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
    let server = unsafe {
        server_options.create_with_security_attributes_raw(pipe_path(), sa_ptr)
    }.context("Failed to listen on named pipe")?;
    Ok(server)
}

/// Named pipe for IPC between GUI client and IPC service
pub fn pipe_path() -> String {
    named_pipe_path(&format!("{BUNDLE_ID}.ipc_service"))
}

async fn handle_ipc_client(server: named_pipe::NamedPipeServer) -> Result<()> {
    let mut framed = Framed::new(server, LengthDelimitedCodec::new());
    let msg = framed.next().await.context("Didn't get any message from the IPC client")??;
    let _msg: IpcClientMsg = serde_json::from_slice(&msg)?;
    let response = IpcServerMsg::Ok;
    framed.send(serde_json::to_string(&response)?.into()).await?;
    bail!("Not implemented yet");
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


/// Returns a valid name for a Windows named pipe
///
/// # Arguments
///
/// * `id` - BUNDLE_ID, e.g. `dev.firezone.client`
pub fn named_pipe_path(id: &str) -> String {
    format!(r"\\.\pipe\{}", id)
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
