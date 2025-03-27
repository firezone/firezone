use aya_ebpf::{macros::map, maps::Array};
use ebpf_shared::Config;

/// Dynamic configuration of the eBPF program.
#[map]
static CONFIG: Array<Config> = Array::with_max_entries(1, 0);

pub fn udp_checksum_enabled() -> bool {
    CONFIG
        .get(0)
        .is_some_and(|config| config.udp_checksum_enabled)
}
