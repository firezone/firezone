#![expect(clippy::print_stdout)]

//! Manual test tool for the network-changes module.
//!
//! Prints a timestamped line to stdout whenever a DNS or network change is
//! detected.  Run with:
//!
//! ```
//! cargo run -p bin-shared --example network_changes_monitor
//! ```
//!
//! Then toggle a network interface, change DNS settings, etc. and watch the
//! output.

use anyhow::Result;
use bin_shared::{DnsControlMethod, new_dns_notifier, new_network_notifier};
use std::time::SystemTime;

#[tokio::main]
async fn main() -> Result<()> {
    // Default picks up whatever the system is configured for.
    let method = DnsControlMethod::default();
    println!("DNS control method: {method:?}");
    println!("Waiting for changes (Ctrl-C to stop)...\n");

    let handle = tokio::runtime::Handle::current();
    let mut dns = new_dns_notifier(handle.clone(), method).await?;
    let mut net = new_network_notifier(handle, method).await?;

    loop {
        tokio::select! {
            result = dns.notified() => {
                result?;
                println!("[{}] DNS changed", timestamp());
            }
            result = net.notified() => {
                result?;
                println!("[{}] Network (primary connection) changed", timestamp());
            }
        }
    }
}

fn timestamp() -> String {
    let secs = SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    // Format as HH:MM:SS for readability — no extra deps needed.
    format!(
        "{:02}:{:02}:{:02}",
        (secs / 3600) % 24,
        (secs / 60) % 60,
        secs % 60
    )
}
