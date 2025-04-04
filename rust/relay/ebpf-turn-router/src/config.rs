use core::ops::RangeInclusive;

use aya_ebpf::{macros::map, maps::Array};
use ebpf_shared::Config;

/// Dynamic configuration of the eBPF program.
#[map]
static CONFIG: Array<Config> = Array::with_max_entries(1, 0);

pub fn udp_checksum_enabled() -> bool {
    config().udp_checksum_enabled
}

pub fn relaying_enabled() -> bool {
    config().relaying_enabled
}

pub fn allocation_range() -> RangeInclusive<u16> {
    let config = config();

    config.lowest_allocation_port..=(config.highest_allocation_port)
}

fn config() -> Config {
    CONFIG.get(0).copied().unwrap_or_default()
}
