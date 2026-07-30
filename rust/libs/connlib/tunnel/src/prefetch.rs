//! An experiment in prefetching packet payloads ahead of processing.
//!
//! Packets arrive on the main thread with their payload bytes last written by an IO
//! thread on another core, so the first access during en- / decryption stalls on a
//! cache miss per line. Processing one packet takes several times longer than fetching
//! one from another core's cache, so a lookahead of two items is enough to hide that
//! latency entirely.
//!
//! Disabled by default; enable per process with `FIREZONE_PREFETCH_PACKETS=1` so
//! identical builds can be benchmarked with and without it.

use std::sync::LazyLock;

use ip_packet::IpPacket;
use socket_factory::DatagramIn;

static ENABLED: LazyLock<bool> = LazyLock::new(|| {
    matches!(
        std::env::var("FIREZONE_PREFETCH_PACKETS").as_deref(),
        Ok("1") | Ok("true")
    )
});

/// An item whose backing memory can be pulled into cache ahead of use.
pub(crate) trait Prefetch {
    /// Requests the item's payload to be loaded into cache; returns without waiting.
    fn prefetch(&self);
}

impl Prefetch for IpPacket {
    fn prefetch(&self) {
        prefetch_slice(self.packet());
    }
}

impl Prefetch for DatagramIn<'_> {
    fn prefetch(&self) {
        prefetch_slice(self.packet);
    }
}

pub(crate) trait PrefetchExt: Iterator + Sized {
    /// Pulls up to `K` items ahead of consumption, prefetching each item's payload as
    /// it enters the lookahead window.
    fn prefetch_ahead<const K: usize>(self) -> PrefetchAhead<Self, K>
    where
        Self::Item: Prefetch,
    {
        PrefetchAhead::new(self, *ENABLED)
    }
}

impl<I> PrefetchExt for I where I: Iterator + Sized {}

pub(crate) struct PrefetchAhead<I: Iterator, const K: usize> {
    inner: I,
    /// FIFO of items pulled ahead of consumption; `head` is the oldest slot.
    ///
    /// Stays empty (and unused) while the experiment is disabled.
    lookahead: [Option<I::Item>; K],
    head: usize,
    enabled: bool,
}

impl<I, const K: usize> PrefetchAhead<I, K>
where
    I: Iterator,
    I::Item: Prefetch,
{
    fn new(mut inner: I, enabled: bool) -> Self {
        let lookahead = std::array::from_fn(|_| {
            if !enabled {
                return None;
            }

            let item = inner.next();

            if let Some(item) = &item {
                item.prefetch();
            }

            item
        });

        Self {
            inner,
            lookahead,
            head: 0,
            enabled,
        }
    }
}

impl<I, const K: usize> Iterator for PrefetchAhead<I, K>
where
    I: Iterator,
    I::Item: Prefetch,
{
    type Item = I::Item;

    fn next(&mut self) -> Option<I::Item> {
        if !self.enabled {
            return self.inner.next();
        }

        let fresh = self.inner.next();

        if let Some(item) = &fresh {
            item.prefetch();
        }

        let item = std::mem::replace(&mut self.lookahead[self.head], fresh);
        self.head = (self.head + 1) % K;

        item
    }
}

/// Issues a prefetch for every cacheline of `bytes`.
///
/// A 64-byte stride is correct on x86-64 and common ARM cores; Apple Silicon uses
/// 128-byte lines, where it merely issues one redundant hint per line.
fn prefetch_slice(bytes: &[u8]) {
    const CACHE_LINE: usize = 64;

    for line_start in (0..bytes.len()).step_by(CACHE_LINE) {
        prefetch_addr(&bytes[line_start]);
    }
}

#[cfg(target_arch = "x86_64")]
fn prefetch_addr(byte: &u8) {
    use std::arch::x86_64::{_MM_HINT_T0, _mm_prefetch};

    // SAFETY: `_mm_prefetch` is a hint and cannot fault, regardless of the address.
    unsafe { _mm_prefetch::<_MM_HINT_T0>(std::ptr::from_ref(byte).cast()) }
}

#[cfg(target_arch = "aarch64")]
fn prefetch_addr(byte: &u8) {
    // SAFETY: `prfm` is a hint and cannot fault, regardless of the address.
    unsafe {
        std::arch::asm!(
            "prfm pldl1keep, [{p}]",
            p = in(reg) byte,
            options(nostack, preserves_flags, readonly)
        );
    }
}

#[cfg(not(any(target_arch = "x86_64", target_arch = "aarch64")))]
fn prefetch_addr(_byte: &u8) {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn yields_all_items_in_order() {
        let items = (0..5).map(Plain);

        let result = PrefetchAhead::<_, 2>::new(items, true)
            .map(|p| p.0)
            .collect::<Vec<_>>();

        assert_eq!(result, vec![0, 1, 2, 3, 4]);
    }

    #[test]
    fn yields_fewer_items_than_lookahead() {
        let items = std::iter::once(Plain(7));

        let result = PrefetchAhead::<_, 2>::new(items, true)
            .map(|p| p.0)
            .collect::<Vec<_>>();

        assert_eq!(result, vec![7]);
    }

    struct Plain(u32);

    impl Prefetch for Plain {
        fn prefetch(&self) {}
    }
}
