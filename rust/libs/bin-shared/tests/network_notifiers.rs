#![allow(clippy::unwrap_used)]

use bin_shared::{DnsControlMethod, new_dns_notifier, new_network_notifier, new_resume_notifier};
use futures::{StreamExt as _, future::FutureExt as _};
use std::time::Duration;
use tokio::time::timeout;

/// Smoke test for the DNS, network change and resume notifiers
///
/// Turn them on, wait a second, turn them off.
/// This tests that the threads quit gracefully when the notifiers are dropped, and they don't crash on startup.
#[tokio::test]
#[cfg_attr(target_os = "macos", ignore = "Notifiers not implemented on macOS")]
async fn notifiers() {
    logging::test_global("debug");
    let tokio_handle = tokio::runtime::Handle::current();

    let mut dns = new_dns_notifier(tokio_handle.clone(), DnsControlMethod::default())
        .await
        .unwrap();
    let mut net = new_network_notifier().await.unwrap();
    let mut resume = new_resume_notifier().await.unwrap();

    tokio::time::sleep(std::time::Duration::from_secs(1)).await;

    // The DNS notifier always notifies once it starts listening, to avoid gaps during startup.
    timeout(Duration::from_secs(1), dns.next())
        .await
        .unwrap()
        .unwrap()
        .unwrap();

    // After that first DNS notification, we shouldn't get any further notifications during a normal unit test.
    // The network notifier should never have fired, since nothing changed about the primary egress path.
    // Likewise the resume notifier, since we never suspended.
    assert!(dns.next().now_or_never().is_none());
    assert!(net.next().now_or_never().is_none());
    assert!(resume.next().now_or_never().is_none());
}
