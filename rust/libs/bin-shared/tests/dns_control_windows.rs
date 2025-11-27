#![cfg(target_os = "windows")]
#![allow(clippy::unwrap_used)]

use bin_shared::{DnsControlMethod, DnsController};
use std::{collections::BTreeSet, net::IpAddr};

// Passes in CI but not locally. Maybe ReactorScram's dev system has IPv6 misconfigured. There it fails to pick up the IPv6 DNS servers.
#[ignore = "Needs admin, changes system state"]
#[tokio::test]
async fn dns_control() {
    let _guard = logging::test("debug");

    let mut tun_dev_manager = bin_shared::TunDeviceManager::new(1280).unwrap();
    let _tun = tun_dev_manager.make_tun().unwrap();

    tun_dev_manager
        .set_ips(
            [100, 92, 193, 137].into(),
            [0xfd00, 0x2021, 0x1111, 0x0, 0x0, 0x0, 0xa, 0x9db5].into(),
        )
        .await
        .unwrap();

    let mut dns_controller = DnsController {
        dns_control_method: DnsControlMethod::Nrpt,
    };

    let fz_dns_servers = vec![
        IpAddr::from([100, 100, 111, 1]),
        IpAddr::from([100, 100, 111, 2]),
        IpAddr::from([
            0xfd00, 0x2021, 0x1111, 0x8000, 0x0100, 0x0100, 0x0111, 0x0003,
        ]),
        IpAddr::from([
            0xfd00, 0x2021, 0x1111, 0x8000, 0x0100, 0x0100, 0x0111, 0x0004,
        ]),
    ];
    dns_controller
        .set_dns(fz_dns_servers.clone(), None)
        .await
        .unwrap();

    let adapter = ipconfig::get_adapters()
        .unwrap()
        .into_iter()
        .find(|a| a.friendly_name() == "Firezone")
        .unwrap();
    assert_eq!(
        BTreeSet::from_iter(adapter.dns_servers().iter().cloned()),
        BTreeSet::from_iter(fz_dns_servers.into_iter())
    );

    dns_controller.deactivate().unwrap();
}
