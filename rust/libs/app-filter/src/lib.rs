//! Application-aware filtering of traffic that enters the Firezone tunnel.
//!
//! The filter answers one question per new flow: may the originating application
//! send to this destination? Routing stays with the tunnel. A destination is
//! *protected* when the tunnel routes it, so an allowed flow still goes through
//! the normal Resource authorization on the Gateway, and a flow to an unrouted
//! destination is never the filter's business.
//!
//! The tunnel's DNS servers are exempt because the system resolver, not the
//! application, sends those queries.
//!
//! Each platform enforces the same [`Policy`] with its own mechanism (WFP on
//! Windows, cgroup eBPF on Linux, content filters on Apple, VPN app lists on
//! Android). [`Filter::decide`] is the reference semantics those enforcers mirror.

#![cfg_attr(test, allow(clippy::unwrap_used))]

mod policy;

#[cfg(target_os = "linux")]
mod linux;
#[cfg(target_os = "windows")]
mod windows;

#[cfg(target_os = "linux")]
use linux as platform;
#[cfg(target_os = "windows")]
use windows as platform;
#[cfg(not(any(target_os = "linux", target_os = "windows")))]
mod platform {
    use crate::{Interface, Policy, ProtectedDestinations};
    use anyhow::Result;

    /// Apple enforces the policy in the Network Extension's content filter, so nothing happens here.
    pub struct Enforcer;

    impl Enforcer {
        #[expect(
            clippy::unnecessary_wraps,
            reason = "Signature must match the other platforms"
        )]
        pub fn new(_: &Policy) -> Result<Self> {
            Ok(Self)
        }

        #[expect(
            clippy::unnecessary_wraps,
            reason = "Signature must match the other platforms"
        )]
        pub fn apply(&mut self, _: &ProtectedDestinations, _: &Interface) -> Result<()> {
            Ok(())
        }

        pub fn clear(&mut self) {}
    }
}

use anyhow::Result;
pub use policy::{AppId, AppIdentity, Filter, Policy, ProtectedDestinations, Verdict};

/// What the enforcer needs to know about the tunnel interface.
#[derive(Clone, Copy, Debug, Default)]
pub struct Interface {
    /// The LUID of the tunnel adapter; Windows scopes its filters to it. Unused elsewhere.
    pub luid: Option<u64>,
}

/// Installs the policy into the operating system for the lifetime of a tunnel.
///
/// With a policy that is not enforcing, every method is a no-op, so callers can hold one unconditionally.
pub struct Enforcer {
    inner: Option<platform::Enforcer>,
}

impl Enforcer {
    pub fn new(policy: &Policy) -> Result<Self> {
        if !policy.is_enforcing() {
            return Ok(Self { inner: None });
        }

        tracing::info!(
            allowed_apps = ?policy.allowed_apps().map(AppId::as_str).collect::<Vec<_>>(),
            "Enforcing application filter"
        );

        let inner = platform::Enforcer::new(policy)?;

        Ok(Self { inner: Some(inner) })
    }

    /// Installs or refreshes the filter for the tunnel's current routes and DNS servers.
    ///
    /// Must be called after the routes are in place: until then, traffic to a new route is unfiltered.
    pub fn apply(
        &mut self,
        destinations: &ProtectedDestinations,
        interface: &Interface,
    ) -> Result<()> {
        let Some(inner) = self.inner.as_mut() else {
            return Ok(());
        };

        inner.apply(destinations, interface)?;

        Ok(())
    }

    /// Removes the filter; call when the tunnel goes down.
    pub fn clear(&mut self) {
        let Some(inner) = self.inner.as_mut() else {
            return;
        };

        inner.clear();
    }
}

impl Drop for Enforcer {
    fn drop(&mut self) {
        self.clear();
    }
}
