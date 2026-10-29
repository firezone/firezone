//! Enforces the verdicts of the per-channel rate limiters stored in the routing maps.

use aya_ebpf::{macros::map, maps::PerCpuArray};
use ebpf_shared::{RateLimitCounter, Verdict};
use network_types::ip::{Ipv4Hdr, Ipv6Hdr};

use crate::try_handle_turn::{Error, checksum::ChecksumUpdate, per_cpu};

const ECN_ECT1: u8 = 0b01;
const ECN_ECT0: u8 = 0b10;
const ECN_CE: u8 = 0b11;

#[map]
static RATE_LIMIT_COUNTERS: PerCpuArray<u64> =
    PerCpuArray::with_max_entries(RateLimitCounter::NUM_ENTRIES, 0);

/// Fails with [`Error::ThroughputLimitExceeded`] if the packet must be dropped.
#[inline(always)]
pub fn ensure_not_dropped(verdict: Verdict) -> Result<Verdict, Error> {
    if verdict == Verdict::Drop {
        return Err(Error::ThroughputLimitExceeded);
    }

    Ok(verdict)
}

/// Sets ECN Congestion Experienced on an ECN-capable IPv4 packet.
#[inline(always)]
pub fn mark_ipv4(ipv4: &mut Ipv4Hdr) {
    if !is_ect(ipv4.ecn()) {
        return;
    }

    let old_word = u16::from_be_bytes([ipv4.vihl, ipv4.tos]);
    ipv4.set_tos(ipv4.dscp(), ECN_CE);
    let new_word = u16::from_be_bytes([ipv4.vihl, ipv4.tos]);

    ipv4.set_checksum(
        ChecksumUpdate::new(ipv4.checksum())
            .remove_u16(old_word)
            .add_u16(new_word)
            .into_ip_checksum(),
    );

    count(RateLimitCounter::Marked);
}

/// Sets ECN Congestion Experienced on an ECN-capable IPv6 packet.
#[inline(always)]
pub fn mark_ipv6(ipv6: &mut Ipv6Hdr) {
    if !is_ect(ipv6.ecn()) {
        return;
    }

    ipv6.set_dscp_ecn(ipv6.dscp(), ECN_CE);

    count(RateLimitCounter::Marked);
}

#[inline(always)]
pub fn count(counter: RateLimitCounter) {
    per_cpu::increment(&RATE_LIMIT_COUNTERS, counter as u32);
}

#[inline(always)]
fn is_ect(ecn: u8) -> bool {
    ecn == ECN_ECT0 || ecn == ECN_ECT1
}
