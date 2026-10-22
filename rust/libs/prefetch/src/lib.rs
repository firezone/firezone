//! Hints the CPU to fetch data another thread wrote before it is read.
//!
//! A thread's first read of a line that another core wrote waits for the line to travel between
//! the caches. Items that cross threads in batches can be fetched one item ahead instead, with
//! [`IteratorExt::prefetching`], so the transfer overlaps the work on the current item.

use std::iter::Peekable;

/// Something whose memory another thread may have written.
pub trait Prefetch {
    /// Hints the CPU to fetch the memory read first when this is processed.
    fn prefetch(&self);
}

impl Prefetch for [u8] {
    fn prefetch(&self) {
        prefetch_line(self.as_ptr());
    }
}

/// Hints the CPU to fetch the cache line at `ptr`.
///
/// A prefetch never faults, so `ptr` need not be valid.
#[inline]
pub fn prefetch_line<T>(ptr: *const T) {
    std::cfg_select! {
        target_arch = "x86_64" => {
            // SAFETY: `sse` is part of the x86_64 baseline and a prefetch never faults.
            unsafe {
                std::arch::x86_64::_mm_prefetch::<{ std::arch::x86_64::_MM_HINT_T0 }>(ptr.cast());
            }
        }
        target_arch = "aarch64" => {
            // SAFETY: a prefetch never faults and touches no register the compiler relies on.
            unsafe {
                std::arch::asm!(
                    "prfm pldl1keep, [{ptr}]",
                    ptr = in(reg) ptr,
                    options(nostack, preserves_flags, readonly)
                );
            }
        }
        _ => {
            let _ = ptr;
        }
    }
}

pub trait IteratorExt: Iterator + Sized {
    /// Prefetches each item one item ahead of yielding it.
    fn prefetching(self) -> Prefetching<Self, fn(&Self::Item) -> &Self::Item>
    where
        Self::Item: Prefetch,
    {
        self.prefetching_with(|item| item)
    }

    /// Prefetches the part of each item that `project` selects, one item ahead of yielding it.
    fn prefetching_with<F, P>(self, mut project: F) -> Prefetching<Self, F>
    where
        F: FnMut(&Self::Item) -> &P,
        P: Prefetch + ?Sized,
    {
        let mut inner = self.peekable();

        if let Some(first) = inner.peek() {
            project(first).prefetch();
        }

        Prefetching { inner, project }
    }
}

impl<I: Iterator> IteratorExt for I {}

/// An iterator that prefetches the item after the one it yields.
pub struct Prefetching<I: Iterator, F> {
    inner: Peekable<I>,
    project: F,
}

impl<I, F, P> Iterator for Prefetching<I, F>
where
    I: Iterator,
    F: FnMut(&I::Item) -> &P,
    P: Prefetch + ?Sized,
{
    type Item = I::Item;

    fn next(&mut self) -> Option<Self::Item> {
        let item = self.inner.next()?;

        if let Some(next) = self.inner.peek() {
            (self.project)(next).prefetch();
        }

        Some(item)
    }

    fn size_hint(&self) -> (usize, Option<usize>) {
        self.inner.size_hint()
    }
}
