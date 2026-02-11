#![allow(clippy::unwrap_used)]

use bin_shared::{DnsControlMethod, new_dns_notifier, new_network_notifier};
use futures::future::FutureExt as _;
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
    let mut net = new_network_notifier(tokio_handle, DnsControlMethod::default())
        .await
        .unwrap();

    tokio::time::sleep(std::time::Duration::from_secs(1)).await;

    // The notifiers always notify once they start listening for changes, to avoid gaps during startup.
    timeout(Duration::from_secs(1), dns.notified())
        .await
        .unwrap()
        .unwrap();
    timeout(Duration::from_secs(1), net.notified())
        .await
        .unwrap()
        .unwrap();

    // After that first notification, we shouldn't get any other notifications during a normal unit test.

    assert!(dns.notified().now_or_never().is_none());
    assert!(net.notified().now_or_never().is_none());

    // `close` consumes the notifiers, so we can catch errors and can't call any methods on a closed notifier. If the notifier is dropped, we internally call the same code that `close` calls.

    dns.close().unwrap();
    net.close().unwrap();
}
