use aya_ebpf::{
    macros::map,
    maps::{PerCpuArray, PerfEventArray},
    programs::XdpContext,
};
use ebpf_shared::{PacketCounter, STATS_SAMPLING_INTERVAL, StatsEvent};

use super::per_cpu;
use crate::time::KernelInstant;

#[map]
static STATS: PerfEventArray<StatsEvent> = PerfEventArray::new(0);

/// State of a per-CPU pseudo-random number generator that decides which packets to sample.
///
/// Calling the `bpf_get_prandom_u32` helper instead is noticeably more expensive.
#[map]
static SAMPLING_RNG: PerCpuArray<u32> = PerCpuArray::with_max_entries(1, 0);

#[map]
static PACKET_COUNTERS: PerCpuArray<u64> =
    PerCpuArray::with_max_entries(PacketCounter::NUM_ENTRIES, 0);

/// Decides whether to report the current packet in detail and if so, starts timing its processing.
///
/// Only a random sample of packets is reported, so we only need to read the clock for those.
#[inline(always)]
pub fn start_sample() -> Option<KernelInstant> {
    let random = per_cpu::update(&SAMPLING_RNG, 0, |state| {
        // A linear congruential generator; its high bits are uniformly distributed.
        *state = state.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
        *state
    })?;

    if random >= u32::MAX / STATS_SAMPLING_INTERVAL {
        return None;
    }

    Some(KernelInstant::now())
}

/// Counts a relayed packet and reports it in detail if it is part of the sample.
#[inline(always)]
pub fn record(
    ctx: &XdpContext,
    sample: Option<KernelInstant>,
    bytes: u16,
    ip_version: u8,
    ecn: u8,
) {
    per_cpu::increment(&PACKET_COUNTERS, PacketCounter::index(ip_version, ecn));

    let Some(start) = sample else {
        return;
    };

    STATS.output(
        ctx,
        &StatsEvent::new(bytes, start.elapsed(), ip_version, ecn),
        0,
    );
}
