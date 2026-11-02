use aya_ebpf::{
    macros::map,
    maps::{PerCpuArray, PerfEventArray},
    programs::XdpContext,
};
use ebpf_shared::{PacketCounter, StatsEvent};

use super::per_cpu;
use crate::time::KernelInstant;

#[map]
static STATS: PerfEventArray<StatsEvent> = PerfEventArray::new(0);

#[map]
static PACKET_COUNTERS: PerCpuArray<u64> =
    PerCpuArray::with_max_entries(PacketCounter::NUM_ENTRIES, 0);

/// Counts a relayed packet and reports its size and processing duration.
#[inline(always)]
pub fn record(ctx: &XdpContext, start: KernelInstant, bytes: u16, ip_version: u8, ecn: u8) {
    per_cpu::increment(&PACKET_COUNTERS, PacketCounter::index(ip_version, ecn));

    STATS.output(
        ctx,
        &StatsEvent::new(bytes, start.elapsed(), ip_version, ecn),
        0,
    );
}
