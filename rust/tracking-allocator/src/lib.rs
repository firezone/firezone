//! A proxy allocator that logs a warning when a certain threshold is reached.
//!
//! Inspired by <https://www.reddit.com/r/rust/comments/8z83wc/comment/e2h4dp9>.

use std::alloc::{GlobalAlloc, Layout};
use std::sync::atomic::{AtomicUsize, Ordering};

pub struct TrackingAllocator<A> {
    inner: A,
    current: AtomicUsize,
}

unsafe impl<A> GlobalAlloc for TrackingAllocator<A>
where
    A: GlobalAlloc,
{
    unsafe fn alloc(&self, l: Layout) -> *mut u8 {
        self.current.fetch_add(l.size(), Ordering::SeqCst);
        self.inner.alloc(l)
    }

    unsafe fn dealloc(&self, ptr: *mut u8, l: Layout) {
        self.current.fetch_sub(l.size(), Ordering::SeqCst);
        self.inner.dealloc(ptr, l);
    }
}

impl<A> TrackingAllocator<A> {
    pub const fn new(inner: A) -> Self {
        TrackingAllocator {
            inner,
            current: AtomicUsize::new(0),
        }
    }

    pub fn get(&self) -> usize {
        self.current.load(Ordering::SeqCst)
    }
}
