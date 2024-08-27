use firezone_bin_shared::windows::DnsControlMethod;
use firezone_headless_client::dns_control::system_resolvers;
use std::time::Duration;

fn main() {
    loop {
        let dns = system_resolvers(DnsControlMethod::Nrpt).unwrap();
        dbg!(dns);
        std::thread::sleep(Duration::from_millis(500));
    }
}
