use aya_ebpf::{macros::map, maps::PerfEventArray, programs::XdpContext};
use core::time::Duration;
use ebpf_shared::StatsEvent;

#[map]
static STATS: PerfEventArray<StatsEvent> = PerfEventArray::new(0);

pub fn emit(ctx: &XdpContext, bytes: impl Into<u64>, processing_duration: Duration) {
    STATS.output(
        ctx,
        StatsEvent {
            relayed_data: bytes.into(),
            processing_duration_ns: duration_as_nanos_u64(processing_duration),
        },
        0,
    );
}

#[inline]
fn duration_as_nanos_u64(d: Duration) -> u64 {
    // Stays in u64; avoids `Duration::as_nanos`'s u128 path for the BPF target.
    d.as_secs() * 1_000_000_000 + d.subsec_nanos() as u64
}
