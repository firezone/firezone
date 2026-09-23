use std::{cell::UnsafeCell, sync::LazyLock};

use bufferpool::{Buffer, BufferPool};

use crate::MAX_FZ_PAYLOAD;

pub(super) static BUFFER_POOL: IpPacketPool = IpPacketPool::new();

pub(super) struct IpPacketPool(UnsafeCell<LazyLock<BufferPool<Vec<u8>>>>);

// SAFETY: Shared access only borrows the thread-safe LazyLock and BufferPool.
// Reset requires exclusive access to their storage, enforced by its caller.
unsafe impl Sync for IpPacketPool {}

/// Resets the global IP packet buffer pool and its lazy initialization state.
///
/// Outstanding packets keep their original pool alive and return buffers to it.
/// Subsequent allocations use a fresh pool.
///
/// # Safety
///
/// The caller must ensure that no IP packet buffer allocations or other resets
/// overlap this call, including reentrant calls. Accesses on other threads must
/// be synchronized with the reset, even when those threads are temporarily idle.
pub unsafe fn reset_buffer_pool() {
    // SAFETY: The caller guarantees exclusive access to the pool's storage.
    unsafe { BUFFER_POOL.reset() };
}

impl IpPacketPool {
    const fn new() -> Self {
        Self(UnsafeCell::new(LazyLock::new(|| {
            BufferPool::new(MAX_FZ_PAYLOAD, "ip-packet")
        })))
    }

    pub(super) fn pull(&self) -> Buffer<Vec<u8>> {
        // SAFETY: Reset cannot overlap this borrow. Only the returned buffer's
        // Arc escapes; it owns the pool state independently of the static.
        unsafe { &*self.0.get() }.pull()
    }

    /// Requires that no calls to `pull` or `reset` overlap this call.
    unsafe fn reset(&self) {
        let fresh = Self::new().0.into_inner();
        // SAFETY: The caller guarantees there are no concurrent accesses or live
        // references to the LazyLock. Buffers hold Arcs to its heap allocation.
        let old = unsafe { self.0.get().replace(fresh) };
        drop(old);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reset_detaches_outstanding_buffers() {
        let pool = IpPacketPool::new();
        let mut old = pool.pull();
        old[0] = 42;
        let old_ptr = old.as_ptr();
        let old_clone = old.clone();

        // SAFETY: This local pool is accessed only by this test thread, and no
        // references to its LazyLock escape pull.
        unsafe { pool.reset() };

        let fresh = pool.pull();
        assert_eq!(fresh.len(), MAX_FZ_PAYLOAD);
        assert_eq!(fresh[0], 0);
        assert_ne!(fresh.as_ptr(), old_ptr);
        let fresh_ptr = fresh.as_ptr();
        drop(fresh);
        drop(old);

        let reused = pool.pull();
        assert_eq!(reused.as_ptr(), fresh_ptr);
        let extra = pool.pull();
        assert_ne!(extra.as_ptr(), old_ptr);
        assert_eq!(old_clone[0], 42);
    }

    #[test]
    fn buffers_can_be_allocated_and_returned_on_other_threads() {
        let pool = IpPacketPool::new();
        std::thread::scope(|scope| {
            let first = scope.spawn(|| pool.pull());
            let second = scope.spawn(|| pool.pull());
            let first = first.join().unwrap();
            let second = second.join().unwrap();
            assert_ne!(first.as_ptr(), second.as_ptr());
            let ptr = first.as_ptr();

            scope.spawn(move || drop(first)).join().unwrap();

            assert_eq!(pool.pull().as_ptr(), ptr);
            drop(second);
        });
    }
}
