#![allow(clippy::unwrap_used)]

use std::net::{IpAddr, Ipv4Addr};

use divan::Bencher;
use ip_network::IpNetwork;
use ip_network_table::IpNetworkTable;
use network_table::NetworkTable;

fn main() {
    divan::main()
}

const HOSTS: u32 = 1_000;

#[divan::bench(types = [NetworkTable<u32>, IpNetworkTable<u32>])]
fn longest_match_hosts<T: Table>(bencher: Bencher) {
    let table = T::from_networks(hosts());

    bencher.bench_local(|| table.longest_match(divan::black_box(host(HOSTS - 1))));
}

#[divan::bench(types = [NetworkTable<u32>, IpNetworkTable<u32>])]
fn longest_match_cidrs<T: Table>(bencher: Bencher) {
    let table = T::from_networks(cidrs());

    bencher.bench_local(|| table.longest_match(divan::black_box(ip("172.16.1.1"))));
}

#[divan::bench(types = [NetworkTable<u32>, IpNetworkTable<u32>], args = ["10.0.3.231", "172.16.1.1"])]
fn longest_match_mixed<T: Table>(bencher: Bencher, probe: &str) {
    let table = T::from_networks(mixed());
    let probe = ip(probe);

    bencher.bench_local(|| table.longest_match(divan::black_box(probe)));
}

#[divan::bench(types = [NetworkTable<u32>, IpNetworkTable<u32>], args = ["10.0.3.231", "172.16.1.1"])]
fn matches_mixed<T: Table>(bencher: Bencher, probe: &str) {
    let table = T::from_networks(mixed());
    let probe = ip(probe);

    bencher.bench_local(|| table.count_matches(divan::black_box(probe)));
}

trait Table {
    fn from_networks(networks: impl Iterator<Item = IpNetwork>) -> Self;
    fn longest_match(&self, ip: IpAddr) -> Option<u32>;
    fn count_matches(&self, ip: IpAddr) -> usize;
}

impl Table for NetworkTable<u32> {
    fn from_networks(networks: impl Iterator<Item = IpNetwork>) -> Self {
        let mut table = Self::new();
        for (value, network) in (0..).zip(networks) {
            table.insert(network, value);
        }
        table
    }

    fn longest_match(&self, ip: IpAddr) -> Option<u32> {
        self.longest_match(ip).map(|(_, v)| *v)
    }

    fn count_matches(&self, ip: IpAddr) -> usize {
        self.matches(ip).count()
    }
}

impl Table for IpNetworkTable<u32> {
    fn from_networks(networks: impl Iterator<Item = IpNetwork>) -> Self {
        let mut table = Self::new();
        for (value, network) in (0..).zip(networks) {
            table.insert(network, value);
        }
        table
    }

    fn longest_match(&self, ip: IpAddr) -> Option<u32> {
        self.longest_match(ip).map(|(_, v)| *v)
    }

    fn count_matches(&self, ip: IpAddr) -> usize {
        self.matches(ip).count()
    }
}

fn mixed() -> impl Iterator<Item = IpNetwork> {
    hosts()
        .chain(cidrs())
        .chain([net("0.0.0.0/0"), net("10.0.0.0/8")])
}

fn hosts() -> impl Iterator<Item = IpNetwork> {
    (0..HOSTS).map(|i| IpNetwork::from(host(i)))
}

fn cidrs() -> impl Iterator<Item = IpNetwork> {
    [
        "172.16.0.0/16",
        "172.16.1.0/24",
        "192.168.0.0/16",
        "100.64.0.0/10",
    ]
    .into_iter()
    .map(net)
}

fn host(i: u32) -> IpAddr {
    IpAddr::V4(Ipv4Addr::from(u32::from(Ipv4Addr::new(10, 0, 0, 0)) + i))
}

fn net(s: &str) -> IpNetwork {
    s.parse().unwrap()
}

fn ip(s: &str) -> IpAddr {
    s.parse().unwrap()
}
