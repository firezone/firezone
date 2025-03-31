use aya_ebpf::{macros::map, maps::PerfEventArray, programs::XdpContext};
use ebpf_shared::StatsEvent;

#[map]
static STATS: PerfEventArray<StatsEvent> = PerfEventArray::new(0);

pub fn emit_data_relayed(ctx: &XdpContext, bytes: impl Into<u64>) {
    STATS.output(
        ctx,
        &StatsEvent {
            relayed_data: bytes.into(),
        },
        0,
    );
}
