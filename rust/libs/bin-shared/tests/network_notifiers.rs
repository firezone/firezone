#![allow(clippy::unwrap_used)]

use anyhow::Result;
use bin_shared::{DnsControlMethod, new_dns_notifier, new_network_notifier};
use futures::{Stream, StreamExt as _, future::FutureExt as _};
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
    let mut net = new_network_notifier().await.unwrap();

    tokio::time::sleep(std::time::Duration::from_secs(1)).await;

    // The DNS notifier always notifies once it starts listening, to avoid gaps during startup.
    timeout(Duration::from_secs(1), dns.next())
        .await
        .unwrap()
        .unwrap()
        .unwrap();

    // Other tests and the host itself change addresses and DNS settings under us, so any further
    // notifications are fine as long as none of them is an error.
    drain(&mut dns);
    drain(&mut net);
}

fn drain(stream: &mut (impl Stream<Item = Result<()>> + Unpin)) {
    while let Some(item) = stream.next().now_or_never().flatten() {
        item.unwrap();
    }
}
