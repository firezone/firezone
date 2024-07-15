use anyhow::{Context as _, Result};
use std::net::IpAddr;

#[cfg(target_os = "linux")]
mod linux;
#[cfg(target_os = "linux")]
use linux as platform;

#[cfg(target_os = "windows")]
mod windows;
#[cfg(target_os = "windows")]
use windows as platform;

pub(crate) use platform::system_resolvers;

// TODO: Move DNS and network change listening to the IPC service, so this won't
// need to be public.
pub use platform::system_resolvers_for_gui;

pub(crate) struct DnsController {
    /// True if we might be controlling DNS, false if we are definitely not.
    ///
    /// In case the IPC service has crashed or something, we always assume that DNS control
    /// is active when we start. Deactivating Firezone's DNS control is safe, but it takes
    /// a lot of time on Windows, so we'd like to avoid redundant de-activations.
    in_control: bool,

    inner: platform::DnsController,
}

impl Default for DnsController {
    fn default() -> Self {
        Self {
            in_control: true,
            inner: Default::default(),
        }
    }
}

impl Drop for DnsController {
    fn drop(&mut self) {
        if !self.in_control {
            return;
        }
        if let Err(error) = self.deactivate() {
            tracing::error!(?error, "Failed to deactivate DNS control");
        }
    }
}

impl DnsController {
    pub(crate) fn deactivate(&mut self) -> Result<()> {
        if !self.in_control {
            tracing::debug!("Skipping redundant DNS deactivation");
            return Ok(());
        }

        self.inner
            .deactivate()
            .context("Failed to deactivate DNS control")?;
        self.in_control = false;
        Ok(())
    }

    pub(crate) fn flush(&self) -> Result<()> {
        self.inner.flush()
    }

    pub(crate) async fn set_dns(&mut self, dns_config: &[IpAddr]) -> Result<()> {
        self.in_control = true;
        self.inner.set_dns(dns_config).await
    }
}
