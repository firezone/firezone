use crate::Cli;
use anyhow::Result;
use std::{
    net::IpAddr,
    path::{Path, PathBuf},
    task::{Context, Poll},
};

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

pub(crate) fn run_ipc_service(_cli: Cli) -> Result<()> {
    // TODO: Process split on Windows
    todo!()
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
