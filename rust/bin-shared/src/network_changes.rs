#[cfg(target_os = "linux")]
#[path = "network_changes/linux.rs"]
#[allow(clippy::unnecessary_wraps)]
mod imp;

#[cfg(target_os = "windows")]
#[path = "network_changes/windows.rs"]
#[allow(clippy::unnecessary_wraps)]
mod imp;

#[cfg(any(target_os = "windows", target_os = "linux"))]
pub use imp::{new_dns_notifier, new_network_notifier};

#[cfg(test)]
mod tests {
    use super::*;
    use crate::platform::DnsControlMethod;
    use futures::{task::noop_waker, Future};
    use std::{
        pin::pin,
        task::{Context, Poll},
        time::Duration,
    };
    use tokio::time::timeout;

    /// Smoke test for the DNS and network change notifiers
    ///
    /// Turn them on, wait a second, turn them off.
    /// This tests that the threads quit gracefully when we call `close`, and they don't crash on startup.
    #[tokio::test]
    async fn notifiers() {
        firezone_logging::test_global("debug");
        let tokio_handle = tokio::runtime::Handle::current();

        let mut dns = new_dns_notifier(tokio_handle.clone(), DnsControlMethod::default())
            .await
            .unwrap();
        let mut net = new_network_notifier(tokio_handle, DnsControlMethod::default())
            .await
            .unwrap();

        tokio::time::sleep(std::time::Duration::from_secs(1)).await;

        // The notifiers always notify once they starts listening for changes, to avoid gaps during startup.
        timeout(Duration::from_secs(1), dns.notified()).await.unwrap().unwrap();
        timeout(Duration::from_secs(1), net.notified()).await.unwrap().unwrap();

        // After that first notification, we shouldn't get any other notifications during a normal unit test.

        let waker = noop_waker();
        let mut ctx = Context::from_waker(&waker);

        assert!(matches!(pin!(dns.notified()).poll(&mut ctx), Poll::Pending));
        assert!(matches!(pin!(net.notified()).poll(&mut ctx), Poll::Pending));

        // `close` consumes the notifiers, so we can catch errors and can't call any methods on a closed notifier. If the notifier is dropped, we internally call the same code that `close` calls.

        dns.close().unwrap();
        net.close().unwrap();
    }
}
