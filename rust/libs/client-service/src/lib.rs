//! The tunnel service: runs connlib for a user's session and serves the IPC
//! socket the GUI and the CLI talk to.
//!
//! This used to live inside the Tauri package, which meant building the
//! daemon compiled Tauri. It is its own crate so the `firezone` binary and
//! the GUI can both link it.

#![cfg_attr(test, allow(clippy::unwrap_used))]
#![cfg_attr(test, allow(clippy::unwrap_in_result))]

/// One-shot migration of MDM policy from the per-user registry hive into the
/// machine-scope hive, owned by the Tunnel service.
// TODO: remove once all clients have migrated.
#[cfg(target_os = "windows")]
mod mdm_migration;

pub mod logging;
pub mod service;
pub mod settings;

/// The version of the binary serving the IPC socket, as told to the GUI in
/// `Hello`. Set once by the binary; the crate's own version stands in when
/// nothing set it.
static DAEMON_VERSION: std::sync::OnceLock<&'static str> = std::sync::OnceLock::new();
static USER_AGENT_PRODUCT: std::sync::OnceLock<&'static str> = std::sync::OnceLock::new();

/// Names the product in the user agent the daemon presents to the portal.
///
/// The GUI's own tunnel service keeps `gui-client`; the `firezone` binary
/// says so, in every role, so the portal can tell the unified binary apart.
pub fn set_user_agent_product(product: &'static str) {
    let _ = USER_AGENT_PRODUCT.set(product);
}

pub fn user_agent_product() -> &'static str {
    USER_AGENT_PRODUCT.get().copied().unwrap_or("gui-client")
}

/// Records the version of the binary that runs the service, for `Hello`.
pub fn set_daemon_version(version: &'static str) {
    let _ = DAEMON_VERSION.set(version);
}

/// The version of the binary that runs the service.
pub fn daemon_version() -> &'static str {
    DAEMON_VERSION
        .get()
        .copied()
        .unwrap_or(env!("CARGO_PKG_VERSION"))
}

/// Whether `FIREZONE_NO_TELEMETRY` was set when this binary was built.
///
/// CI stamps it into every build that is not a release, so the smoke test, the
/// install test and any artifact from a pull request stay silent even where nothing
/// sets the variable at run time.
pub const NO_TELEMETRY: bool = cfg!(no_telemetry);

/// The group whose members may control the tunnel service over its socket.
pub const FIREZONE_CLIENT_GROUP: &str = "firezone-client";

#[cfg(target_os = "linux")]
pub fn firezone_client_group() -> anyhow::Result<nix::unistd::Group> {
    use anyhow::Context as _;

    let group = nix::unistd::Group::from_name(FIREZONE_CLIENT_GROUP)
        .context("can't get group by name")?
        .with_context(|| format!("`{FIREZONE_CLIENT_GROUP}` group must exist on the system"))?;

    Ok(group)
}

/// The kernel forwarder for served traffic on this host, unless disabled or unavailable.
///
/// Without one, served traffic is forwarded in userspace.
pub fn kernel_forwarding(disabled: bool) -> Option<Box<dyn client_shared::KernelForwarding>> {
    if disabled {
        tracing::info!("Kernel forwarding disabled, served traffic is forwarded in userspace");
        return None;
    }

    if !bin_shared::forwarding::is_available() {
        tracing::info!(
            "Kernel forwarding unavailable on this host, served traffic is forwarded in userspace"
        );
        return None;
    }

    Some(Box::new(HostForwarding))
}

/// Whether `FIREZONE_NO_KERNEL_FORWARDING` asks for userspace forwarding only.
pub fn kernel_forwarding_disabled_by_env() -> bool {
    std::env::var("FIREZONE_NO_KERNEL_FORWARDING").is_ok_and(|v| matches!(v.as_str(), "1" | "true"))
}

struct HostForwarding;

impl client_shared::KernelForwarding for HostForwarding {
    fn enable(&mut self) -> anyhow::Result<Box<dyn std::any::Any + Send>> {
        Ok(Box::new(bin_shared::forwarding::enable()?))
    }
}
