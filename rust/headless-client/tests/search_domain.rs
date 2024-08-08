use domain::base::Message;
use firezone_bin_shared::{DnsControlMethod, TunDeviceManager};
use firezone_headless_client::dns_control::DnsController;
use ip_packet::Packet;
use std::time::Duration;
use tun::Tun as _;

#[tokio::test]
#[ignore = "Needs admin / sudo"]
async fn setting_search_domain_triggers_dns_query() {
    let _guard = tracing_subscriber::fmt()
        .with_test_writer()
        .with_env_filter("debug")
        .try_init();

    let mut tun_device_manager = TunDeviceManager::new().unwrap();
    let mut dns_controller = DnsController {
        dns_control_method: DnsControlMethod::default(),
    };
    let mut tun = tun_device_manager.make_tun().unwrap();

    tun_device_manager
        .set_ips("100.100.100.1".parse().unwrap(), "fe80::1".parse().unwrap())
        .await
        .unwrap();
    tun_device_manager
        .set_routes(vec!["100.100.100.100/32".parse().unwrap()], vec![])
        .await
        .unwrap();
    dns_controller
        .set_dns(
            vec!["100.100.100.100".parse().unwrap()],
            vec!["foo.bar".parse().unwrap(), "example.com".parse().unwrap()],
        )
        .await
        .unwrap();

    #[cfg(windows)]
    let _handle = tokio::process::Command::new("powershell")
        .args(["Resolve-DnsName", "test"]) // `nslookup` doesn't respect NTRP rules so we need to test with `Resolve-DnsName`
        .spawn()
        .unwrap();

    #[cfg(unix)]
    let _handle = tokio::process::Command::new("host")
        .arg("test")
        .spawn()
        .unwrap();

    let wait_for_dns_query = async {
        loop {
            let mut buf = [0u8; 1000];
            let n = std::future::poll_fn(|cx| tun.poll_read(&mut buf, cx))
                .await
                .unwrap();

            let packet = ip_packet::IpPacket::new(&buf[..n]).unwrap();

            let Some(udp) = packet.as_udp() else {
                continue;
            };

            let Ok(dns) = Message::from_slice(udp.payload()) else {
                continue;
            };
            let Ok(question) = dns.sole_question() else {
                continue;
            };

            let domain = question.into_qname().to_string();

            tracing::debug!("Got DNS query for {domain}");

            if domain == "test.example.com" {
                break;
            }
        }
    };

    tokio::time::timeout(Duration::from_secs(5), wait_for_dns_query)
        .await
        .unwrap();

    // wait_for_dns_query.await;
}
