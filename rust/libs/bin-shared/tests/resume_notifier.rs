#![allow(clippy::unwrap_used)]

use bin_shared::new_resume_notifier;
use futures::{StreamExt as _, future::FutureExt as _};

/// Smoke test for the resume notifier.
///
/// Subscribing to the OS is the only part that can fail at runtime, so check that it succeeds and
/// that we don't claim to have resumed when the system never slept.
///
/// Windows registers once per process and fans the notifications out, so the second notifier
/// exercises a different path than the first. Both the Tunnel service and the headless client
/// create one per connected client, meaning the second path is the common one in practice.
#[tokio::test]
#[cfg_attr(
    target_os = "macos",
    ignore = "Resume notifier not implemented on macOS"
)]
async fn resume_notifier() {
    logging::test_global("debug");

    let mut first = new_resume_notifier().await.unwrap();
    let mut second = new_resume_notifier().await.unwrap();

    assert!(first.next().now_or_never().is_none());
    assert!(second.next().now_or_never().is_none());
}
