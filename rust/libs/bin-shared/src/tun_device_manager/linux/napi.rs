//! Setter for the `threaded` NAPI attribute of a netdev.
//!
//! There is no `ethtool` op for NAPI threading; the stable interface is the
//! per-device `threaded` sysfs attribute (available since kernel 5.12).

use anyhow::{Context as _, Result};

/// Moves the device's NAPI polling from softirq context into a dedicated kernel thread (`napi/<ifname>-<N>`).
///
/// With just `IFF_NAPI`, the poll runs on the writing thread's CPU as soon as the
/// `write` syscall re-enables bottom halves, i.e. with a single packet per poll,
/// which never gives GRO anything to coalesce (and bills the entire network stack
/// traversal to the writing thread). A threaded poll decouples producer and
/// consumer: batches - and thus GRO merges - build up whenever we write faster
/// than the poll thread drains.
pub(crate) fn enable_threaded(ifname: &str) -> Result<()> {
    let path = format!("/sys/class/net/{ifname}/threaded");

    std::fs::write(&path, "1").with_context(|| format!("Failed to write `{path}`"))?;

    Ok(())
}
