use crate::Cli;
use anyhow::Result;
use clap::Parser;
use connlib_client_shared::file_logger;
use firezone_cli_utils::setup_global_subscriber;
use std::{
    ffi::OsString,
    net::IpAddr,
    path::{Path, PathBuf},
    task::{Context, Poll},
};

const SERVICE_NAME: &str = "firezone_client_ipc";

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
    let cli = Cli::parse();
    let (layer, _handle) = cli.log_dir.as_deref().map(file_logger::layer).unzip();
    setup_global_subscriber(layer);
    tracing::info!(git_version = crate::GIT_VERSION);

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

fn fallible_windows_service_run() -> Result<()> {
    run_ipc_service(Cli::parse())
}

pub(crate) fn run_ipc_service(cli: Cli) -> Result<()> {
    let rt = tokio::runtime::Runtime::new()?;
    tracing::info!("run_ipc_service");
    rt.block_on(async { ipc_listen(cli).await })
}

async fn ipc_listen(_cli: Cli) -> Result<()> {
    tokio::fs::write(
        "C:/ProgramData/dev.firezone.client/service.txt",
        b"test message\n",
    )
    .await?;
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
