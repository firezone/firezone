use aya_ebpf::{
    helpers::bpf_get_prandom_u32,
    macros::map,
    maps::{PerCpuArray, PerfEventArray},
    programs::XdpContext,
};
use ebpf_shared::{PacketCounter, STATS_SAMPLING_INTERVAL, StatsEvent};

use crate::time::KernelInstant;

#[map]
static STATS: PerfEventArray<StatsEvent> = PerfEventArray::new(0);

#[map]
static PACKET_COUNTERS: PerCpuArray<u64> =
    PerCpuArray::with_max_entries(PacketCounter::NUM_ENTRIES, 0);

/// Counts a relayed packet and reports a random sample of packets in detail.
#[inline(always)]
pub fn record(ctx: &XdpContext, bytes: u16, start: KernelInstant, ip_version: u8, ecn: u8) {
    if let Some(counter) = PACKET_COUNTERS.get_ptr_mut(PacketCounter::index(ip_version, ecn)) {
        // SAFETY: Per-CPU values are only ever accessed from the current CPU.
        unsafe { *counter += 1 };
    }

    // SAFETY: `bpf_get_prandom_u32` is a parameterless helper that is safe to call from any BPF program.
    if unsafe { bpf_get_prandom_u32() } % STATS_SAMPLING_INTERVAL != 0 {
        return;
    }

    STATS.output(
        ctx,
        &StatsEvent::new(bytes, start.elapsed(), ip_version, ecn),
        0,
    );
}
