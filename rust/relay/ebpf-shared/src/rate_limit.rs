//! Per-channel throughput limiting, shared by the eBPF and the userspace datapath.
//!
//! [`RateLimiter`] is a two-rate three-color marker (RFC 2698) built from two instances of the
//! Generic Cell Rate Algorithm (GCRA). GCRA is a token bucket that only needs a single timestamp
//! of state: the "theoretical arrival time" (TAT) of the next packet. Every packet pushes the TAT
//! into the future by the time it takes to transmit it at the bucket's rate.
//!
//! - Packets within [`MARK_RATE_PERCENT`] of the limit pass unchanged.
//! - Packets above that should be marked with ECN Congestion Experienced.
//! - Packets above the limit are dropped.
//!
//! Marking before dropping lets ECN-capable senders back off without suffering loss.
//! Marked packets do not count against the marking rate, so marking stops as soon as the sender
//! slows down instead of lingering until the burst allowance has refilled.
//! All forwarded packets count against the limit, so senders that ignore ECN are still limited.

use core::num::NonZeroU64;
use core::ptr::{read_volatile, write_volatile};
use core::time::Duration;

/// How far a channel may run ahead of a rate before its packets exceed it.
///
/// At the configured rate, this is equivalent to a burst of `rate * BURST_TOLERANCE` bytes.
/// Packets are never delayed, so this does not add latency. It should cover typical round-trip
/// times so TCP can probe for bandwidth without loss.
pub const BURST_TOLERANCE: Duration = Duration::from_millis(250);

/// The share of the limit above which ECN-capable packets are marked.
pub const MARK_RATE_PERCENT: u64 = 80;

/// How far a channel may run ahead of the marking rate before its packets are marked.
///
/// Much shorter than [`BURST_TOLERANCE`] so that senders get the signal before they hit the limit.
pub const MARK_BURST_TOLERANCE: Duration = Duration::from_millis(100);

const BURST_TOLERANCE_NS: u64 = BURST_TOLERANCE.as_nanos() as u64;
const MARK_BURST_TOLERANCE_NS: u64 = MARK_BURST_TOLERANCE.as_nanos() as u64;

/// Fractional bits of [`RateLimiter::ns_per_byte`].
const NS_PER_BYTE_FRAC_BITS: u32 = 8;

/// What to do with a packet that has been checked against a [`RateLimiter`].
///
/// Ordered by severity, so the verdict for a packet checked against several limiters is the maximum.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Verdict {
    Pass,
    /// Forward the packet but set ECN CE if the packet is ECN-capable.
    Mark,
    Drop,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct RateLimiter {
    /// Theoretical arrival time of the next packet at the limit, in nanoseconds on a monotonic clock.
    drop_tat_ns: u64,
    /// Theoretical arrival time of the next packet at the marking rate.
    mark_tat_ns: u64,
    /// The cost of a single byte at the limit in nanoseconds, as fixed-point with [`NS_PER_BYTE_FRAC_BITS`].
    ///
    /// Zero means unlimited.
    ns_per_byte: u64,
}

impl RateLimiter {
    pub const fn unlimited() -> Self {
        Self {
            drop_tat_ns: 0,
            mark_tat_ns: 0,
            ns_per_byte: 0,
        }
    }

    pub const fn new(bytes_per_second: NonZeroU64) -> Self {
        Self {
            drop_tat_ns: 0,
            mark_tat_ns: 0,
            ns_per_byte: (1_000_000_000 << NS_PER_BYTE_FRAC_BITS) / bytes_per_second.get(),
        }
    }

    /// Charges a packet of `num_bytes` against the limit at time `now_ns`.
    #[inline(always)]
    pub fn check(&mut self, now_ns: u64, num_bytes: u16) -> Verdict {
        // SAFETY: A mutable reference is valid for reads and writes and aligned.
        unsafe { Self::check_shared(self, || now_ns, num_bytes) }
    }

    /// Like [`RateLimiter::check`], but for a limiter that other threads may charge at the same time.
    ///
    /// Concurrent charges can overwrite each other's updates, which lets a packet through without
    /// being charged. The current time is only read if the limiter is limited.
    ///
    /// # Safety
    ///
    /// `limiter` must be valid for reads and writes and properly aligned.
    #[inline(always)]
    pub unsafe fn check_shared(
        limiter: *mut Self,
        now_ns: impl FnOnce() -> u64,
        num_bytes: u16,
    ) -> Verdict {
        // eBPF cannot load atomically, so like the kernel's `READ_ONCE` and `WRITE_ONCE`, we use volatile accesses
        // through raw pointers, which the compiler won't tear, merge or repeat.
        // SAFETY: The caller guarantees that the limiter is valid for reads and writes and aligned.
        let (drop_tat_ns, mark_tat_ns, ns_per_byte) = unsafe {
            (
                &raw mut (*limiter).drop_tat_ns,
                &raw mut (*limiter).mark_tat_ns,
                read_volatile(&raw const (*limiter).ns_per_byte),
            )
        };

        if ns_per_byte == 0 {
            return Verdict::Pass;
        }

        let now_ns = now_ns();
        // SAFETY: See above.
        let drop_tat = max(unsafe { read_volatile(drop_tat_ns) }, now_ns);

        // Dropped packets are not charged, so a sender exceeding the limit still gets its fair share.
        if drop_tat - now_ns > BURST_TOLERANCE_NS {
            return Verdict::Drop;
        }

        let cost_ns = (num_bytes as u64 * ns_per_byte) >> NS_PER_BYTE_FRAC_BITS;
        // SAFETY: See above.
        unsafe { write_volatile(drop_tat_ns, drop_tat + cost_ns) };

        // SAFETY: See above.
        let mark_tat = max(unsafe { read_volatile(mark_tat_ns) }, now_ns);

        if mark_tat - now_ns > MARK_BURST_TOLERANCE_NS {
            return Verdict::Mark;
        }

        // SAFETY: See above.
        unsafe { write_volatile(mark_tat_ns, mark_tat + cost_ns * 100 / MARK_RATE_PERCENT) };

        Verdict::Pass
    }
}

/// An idle channel's TAT lies in the past; it starts over with the full burst allowance.
#[inline(always)]
fn max(tat_ns: u64, now_ns: u64) -> u64 {
    if tat_ns > now_ns { tat_ns } else { now_ns }
}

/// The value of a routing map entry: where to send the packet and how fast.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct Route<T> {
    pub limiter: RateLimiter,
    pub dst: T,
}

impl<T> Route<T> {
    pub const fn new(dst: T, limiter: RateLimiter) -> Self {
        Self { limiter, dst }
    }
}

/// Indices into the per-CPU array that counts packets affected by rate limiting.
#[repr(u32)]
#[derive(Clone, Copy)]
pub enum RateLimitCounter {
    /// ECN-capable packets that were marked with CE.
    Marked = 0,
    Dropped = 1,
}

impl RateLimitCounter {
    pub const NUM_ENTRIES: u32 = 2;
}

#[cfg(all(test, feature = "std"))]
mod tests {
    use super::*;

    const SECOND_NS: u64 = 1_000_000_000;
    const PACKET_SIZE: u16 = 1250;
    const LIMIT: u64 = 625_000; // 5 Mbps

    #[test]
    fn unlimited_passes_everything() {
        let mut limiter = RateLimiter::unlimited();

        for _ in 0..100_000 {
            assert_eq!(limiter.check(0, u16::MAX), Verdict::Pass);
        }
    }

    #[test]
    fn traffic_below_marking_rate_is_untouched() {
        let mut limiter = limiter(LIMIT);

        let verdicts = offer(&mut limiter, 0, 10, LIMIT * 75 / 100);

        assert!(verdicts.iter().all(|v| *v == Verdict::Pass));
    }

    #[test]
    fn traffic_between_marking_rate_and_limit_is_marked_but_not_dropped() {
        let mut limiter = limiter(LIMIT);

        let verdicts = offer(&mut limiter, 0, 10, LIMIT * 95 / 100);

        assert!(verdicts.contains(&Verdict::Mark));
        assert!(!verdicts.contains(&Verdict::Drop));
    }

    #[test]
    fn forwarded_throughput_converges_to_limit_even_if_sender_ignores_marks() {
        let mut limiter = limiter(LIMIT);

        let verdicts = offer(&mut limiter, 0, 10, 4 * LIMIT);

        let forwarded_bytes =
            verdicts.iter().filter(|v| **v != Verdict::Drop).count() as u64 * PACKET_SIZE as u64;
        let expected = 10 * LIMIT + LIMIT * BURST_TOLERANCE_NS / SECOND_NS;
        assert!(
            forwarded_bytes.abs_diff(expected) <= PACKET_SIZE as u64,
            "forwarded {forwarded_bytes} bytes but expected {expected}"
        );
    }

    #[test]
    fn marks_before_dropping() {
        let mut limiter = limiter(LIMIT);

        let verdicts = offer(&mut limiter, 0, 1, 2 * LIMIT);

        let first_mark = verdicts.iter().position(|v| *v == Verdict::Mark).unwrap();
        let first_drop = verdicts.iter().position(|v| *v == Verdict::Drop).unwrap();
        assert!(verdicts[..first_mark].iter().all(|v| *v == Verdict::Pass));
        assert!(first_mark < first_drop);
    }

    #[test]
    fn stops_marking_as_soon_as_sender_slows_down() {
        let mut limiter = limiter(LIMIT);
        let marked = offer(&mut limiter, 0, 2, LIMIT * 95 / 100);
        assert_eq!(marked.last(), Some(&Verdict::Mark));

        let verdicts = offer(&mut limiter, 2, 3, LIMIT * 70 / 100);

        // Only the packet straddling the change in rate may still be marked.
        assert!(verdicts[1..].iter().all(|v| *v == Verdict::Pass));
    }

    #[test]
    fn recovers_burst_allowance_when_idle() {
        let mut limiter = limiter(LIMIT);
        let exhausted = offer(&mut limiter, 0, 1, 4 * LIMIT);
        assert_eq!(exhausted.last(), Some(&Verdict::Drop));

        let verdict = limiter.check(2 * SECOND_NS, PACKET_SIZE);

        assert_eq!(verdict, Verdict::Pass);
    }

    #[test]
    fn route_layout_has_no_surprises() {
        assert_eq!(core::mem::size_of::<RateLimiter>(), 24);
        assert_eq!(core::mem::size_of::<Route<crate::PortAndPeerV4>>(), 32);
        assert_eq!(core::mem::size_of::<Route<crate::ClientAndChannelV6>>(), 48);
    }

    fn limiter(bytes_per_second: u64) -> RateLimiter {
        RateLimiter::new(NonZeroU64::new(bytes_per_second).unwrap())
    }

    /// Offers `PACKET_SIZE` packets at a constant `bytes_per_second` from second `start` until second `end`.
    fn offer(
        limiter: &mut RateLimiter,
        start: u64,
        end: u64,
        bytes_per_second: u64,
    ) -> Vec<Verdict> {
        let interval_ns = PACKET_SIZE as u64 * SECOND_NS / bytes_per_second;

        (start * SECOND_NS..end * SECOND_NS)
            .step_by(interval_ns as usize)
            .map(|now_ns| limiter.check(now_ns, PACKET_SIZE))
            .collect()
    }
}
