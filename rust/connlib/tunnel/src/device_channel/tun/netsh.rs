// netsh interface ipv6 add address 11 2001:db8:face::1/64

use connlib_shared::Result;
use std::net::Ipv6Addr;

use tokio::process::Command;

// :( I wish we could use win32 but alas, that doesn't exist
pub(super) async fn set_ipv6_addr(idx: u32, addr: Ipv6Addr) -> Result<()> {
    Command::new("netsh")
        .args([
            "interface",
            "ipv6",
            "add",
            "address",
            &idx.to_string(),
            &addr.to_string(),
        ])
        .status()
        .await?;
    Ok(())
}
