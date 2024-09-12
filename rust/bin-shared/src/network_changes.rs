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

    /// Smoke test for the DNS and network change notifiers
    ///
    /// Turn them on, wait a second, turn them off.
    /// This tests that the threads quit gracefully when we call `close`, and they don't crash on startup.
    #[tokio::test]
    async fn notifiers() {
        let _logs = firezone_logging::test("debug");
        let tokio_handle = tokio::runtime::Handle::current();

        let mut dns = new_dns_notifier(tokio_handle.clone(), DnsControlMethod::default())
            .await
            .unwrap();
        let mut net = new_network_notifier(tokio_handle, DnsControlMethod::default())
            .await
            .unwrap();

        tracing::debug!("Sleeping...");

        tokio::time::sleep(std::time::Duration::from_secs(1)).await;

        assert!(net.notified().await.is_ok());

        tracing::debug!("Closing DNS notifier...");
        dns.close().unwrap();
        tracing::debug!("Closing network notifier...");
        net.close().unwrap();

        // The network change notifier should not notify during that waiting period.
        tracing::debug!("Ensuring network notifier didn't notify");
        assert!(net.notified().await.is_err());
    }
}
