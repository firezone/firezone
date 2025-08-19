use aya_ebpf::{macros::map, maps::Array};
use ebpf_shared::Config;

/// Dynamic configuration of the eBPF program.
#[map]
static CONFIG: Array<Config> = Array::with_max_entries(1, 0);

pub fn udp_checksum_enabled() -> bool {
    config().udp_checksum_enabled()
}

fn config() -> Config {
    CONFIG.get(0).copied().unwrap_or_default()
}
