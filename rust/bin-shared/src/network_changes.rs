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
    use crate::platform::DnsControlMethod;
    use super::*;

    /// Smoke test for the DNS and network change notifiers
    ///
    /// Turn them on, wait a second, turn them off.
    #[tokio::test]
    async fn notifiers() {
        let tokio_handle = tokio::runtime::Handle::current();

        let mut dns = new_dns_notifier(tokio_handle.clone(), DnsControlMethod::default()).await.unwrap();
        let mut net = new_network_notifier(tokio_handle, DnsControlMethod::default()).await.unwrap();

        tokio::time::sleep(std::time::Duration::from_secs(1)).await;

        dns.close().unwrap();
        net.close().unwrap();
    }
}
