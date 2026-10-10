//! TUN device backed by the (experimental) Tundra driver, see [`tun_windows::tundra`].

use super::set_iface_config;
use crate::TUNNEL_NAME;
use crate::network_changes::TunnelInterfaceIndexGuard;
use crate::windows::TUNNEL_UUID;
use anyhow::{Context as _, Result};
use std::path::{Path, PathBuf};
use windows::Win32::NetworkManagement::Ndis::NET_LUID_LH;

pub struct Tundra {
    iface_idx: u32,
    luid: u64,

    /// Removed before `io` is dropped (see [`Drop`]), so the workers see the session
    /// end even if they are waiting on the driver.
    adapter: Option<tundra::Adapter>,
    io: tun_windows::tundra::Io,
    /// Drop after the adapter so address-removal callbacks remain filtered during teardown.
    _interface_index_guard: TunnelInterfaceIndexGuard,
}

impl Drop for Tundra {
    fn drop(&mut self) {
        drop(self.adapter.take());
    }
}

impl Tundra {
    pub fn new(mtu: u32) -> Result<Self> {
        let inf = ensure_driver_package().context("Failed to extract Tundra driver package")?;
        tundra::install_driver(&inf)
            .with_context(|| format!("Failed to install Tundra driver from {}", inf.display()))?;

        let adapter = tundra::Adapter::create(TUNNEL_NAME, TUNNEL_UUID.as_u128())
            .context("Failed to create Tundra adapter")?;
        let luid = adapter.luid();

        let device = adapter.open().context("Failed to open Tundra device")?;
        let info = device
            .set_offloads(tundra::abi::OFFLOAD_ALL)
            .context("Failed to configure Tundra offloads")?;

        tracing::info!(
            ndis = format!("{}.{}", info.ndis_version >> 16, info.ndis_version & 0xFFFF),
            active_offloads = format!("{:#06x}", info.active_offloads),
            "Created Tundra adapter"
        );

        let iface_idx = info.if_index;
        let interface_index_guard = TunnelInterfaceIndexGuard::new(iface_idx);

        set_iface_config(NET_LUID_LH { Value: luid }, mtu)
            .context("Failed to set interface config")?;

        // The adapter's link comes up with the session.
        let session = tundra::Session::start(device, tun_windows::tundra::Io::session_config())
            .context("Failed to start Tundra session")?;
        let io =
            tun_windows::tundra::Io::new(TUNNEL_NAME, session, &tokio::runtime::Handle::current())?;

        Ok(Self {
            iface_idx,
            luid,
            adapter: Some(adapter),
            io,
            _interface_index_guard: interface_index_guard,
        })
    }

    pub fn iface_idx(&self) -> u32 {
        self.iface_idx
    }

    pub fn luid(&self) -> u64 {
        self.luid
    }
}

impl tun::Tun for Tundra {
    fn sender(&self) -> &tun::OutboundTx {
        self.io.sender()
    }

    fn receiver(&mut self) -> &mut tun::InboundRx {
        self.io.receiver()
    }

    fn name(&self) -> &str {
        TUNNEL_NAME
    }
}

/// Writes the embedded driver package to `%LOCALAPPDATA%\...\data\tundra` (if needed)
/// and returns the path of its INF.
fn ensure_driver_package() -> Result<PathBuf> {
    let dir = known_dirs::platform::app_local_data_dir()?
        .join("data")
        .join("tundra");
    std::fs::create_dir_all(&dir).context("Failed to create driver package directory")?;

    for (name, bytes) in DRIVER_PACKAGE {
        write_if_changed(&dir.join(name), bytes)?;
    }

    Ok(dir.join("tundra.inf"))
}

fn write_if_changed(path: &Path, bytes: &[u8]) -> Result<()> {
    if std::fs::read(path).is_ok_and(|existing| existing == bytes) {
        return Ok(());
    }

    std::fs::write(path, bytes).with_context(|| format!("Failed to write {}", path.display()))
}

/// The package directory for the architecture we're built for (the driver must match it).
#[cfg(target_arch = "x86_64")]
macro_rules! package_dir {
    () => {
        "../../tundra/bin/amd64/"
    };
}
#[cfg(target_arch = "aarch64")]
macro_rules! package_dir {
    () => {
        "../../tundra/bin/arm64/"
    };
}

const DRIVER_PACKAGE: [(&str, &[u8]); 3] = [
    (
        "tundra.sys",
        include_bytes!(concat!(package_dir!(), "tundra.sys")),
    ),
    (
        "tundra.inf",
        include_bytes!(concat!(package_dir!(), "tundra.inf")),
    ),
    (
        "tundra.cat",
        include_bytes!(concat!(package_dir!(), "tundra.cat")),
    ),
];
