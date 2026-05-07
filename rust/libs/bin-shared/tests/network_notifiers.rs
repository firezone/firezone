#![allow(clippy::unwrap_used)]

use bin_shared::{DnsControlMethod, new_dns_notifier, new_network_notifier};
use futures::StreamExt as _;
use std::time::Duration;
use tokio::time::timeout;

/// Smoke test for the DNS and network change notifiers
///
/// Turn them on, wait a second, turn them off.
/// This tests that the threads quit gracefully when we call `close`, and they don't crash on startup.
#[tokio::test]
#[cfg_attr(
    target_os = "macos",
    ignore = "Network notifiers not implemented on macOS"
)]
async fn notifiers() {
    logging::test_global("debug");
    let tokio_handle = tokio::runtime::Handle::current();

    let mut dns = new_dns_notifier(tokio_handle.clone(), DnsControlMethod::default())
        .await
        .unwrap();
    let _net = new_network_notifier().await.unwrap();

    tokio::time::sleep(std::time::Duration::from_secs(1)).await;

    // The DNS notifier always notifies once it starts listening, to avoid gaps during startup.
    timeout(Duration::from_secs(1), dns.next())
        .await
        .unwrap()
        .unwrap()
        .unwrap();

    // We deliberately don't assert that no further notifications fire here.
    // On Windows, the DNS notifier watches `HKLM\SYSTEM\CurrentControlSet\Services\Tcpip[6]\Parameters\Interfaces`,
    // which the OS itself writes to for unrelated reasons (DHCP lease renewals, adapter PnP events, VM-agent
    // metadata updates). Likewise, the COM-based network notifier can fire spuriously while Windows re-evaluates
    // network connectivity level early in a fresh VM's lifetime. Asserting the absence of such events made this
    // test flaky on the `windows-2025` GitHub Actions runner.
}
