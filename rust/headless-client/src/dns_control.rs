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
    /// True if DNS control is definitely active or might be active.
    ///
    /// In case the IPC service has crashed or something, we always assume that DNS control
    /// is active when we start. Deactivating Firezone's DNS control is safe, but it takes
    /// a lot of time on Windows, so we'd like to avoid redundant de-activations.
    control_may_be_active: bool,

    inner: platform::DnsController,
}

impl Default for DnsController {
    fn default() -> Self {
        Self {
            control_may_be_active: true,
            inner: Default::default(),
        }
    }
}

impl Drop for DnsController {
    fn drop(&mut self) {
        if self.control_may_be_active {
            if let Err(error) = self.deactivate() {
                tracing::error!(?error, "Failed to deactivate DNS control");
            }
        }
    }
}

impl DnsController {
    pub(crate) fn deactivate(&mut self) -> Result<()> {
        if self.control_may_be_active {
            self.inner
                .deactivate()
                .context("Failed to deactivate DNS control")?;
            self.control_may_be_active = false;
        } else {
            tracing::debug!("Skipping redundant DNS deactivation");
        }
        Ok(())
    }

    pub(crate) fn flush(&self) -> Result<()> {
        self.inner.flush()
    }

    pub(crate) async fn set_dns(&mut self, dns_config: &[IpAddr]) -> Result<()> {
        self.control_may_be_active = true;
        self.inner.set_dns(dns_config).await
    }
}
