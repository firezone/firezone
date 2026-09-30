use aya_ebpf::{macros::map, maps::PerfEventArray, programs::XdpContext};
use core::time::Duration;
use ebpf_shared::StatsEvent;

#[map]
static STATS: PerfEventArray<StatsEvent> = PerfEventArray::new(0);

pub fn emit(
    ctx: &XdpContext,
    bytes: impl Into<u64>,
    processing_duration: Duration,
    ip_version: u8,
    ecn: u8,
) {
    STATS.output(
        ctx,
        &StatsEvent::new(bytes.into(), processing_duration, ip_version, ecn),
        0,
    );
}
