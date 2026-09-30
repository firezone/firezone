use crate::{Buf, Buffer, BufferPool, ThreadSafe};
use std::sync::LazyLock;

/// Default ownership for pools shared with TUN workers.
pub type DefaultSharing = ThreadSafe;

/// A static, lazily initialized pool shared by every thread.
pub struct SharedBufferPool<B> {
    pool: LazyLock<BufferPool<B>>,
}

impl<B> SharedBufferPool<B> {
    #[doc(hidden)]
    pub const fn new(init: fn() -> BufferPool<B>) -> Self {
        Self {
            pool: LazyLock::new(init),
        }
    }
}

impl<B: Buf> SharedBufferPool<B> {
    pub fn pull(&self) -> Buffer<B> {
        self.pool.pull()
    }
}

/// Declares a [`SharedBufferPool`](crate::SharedBufferPool) with platform-selected ownership.
///
/// ```
/// use bufferpool::{SharedBufferPool, shared_buffer_pool};
///
/// static POOL: SharedBufferPool<Vec<u8>> = shared_buffer_pool!(Vec<u8>, 1024, "example");
/// let buffer = POOL.pull();
/// assert_eq!(buffer.len(), 1024);
/// ```
#[macro_export]
macro_rules! shared_buffer_pool {
    ($buffer:ty, $capacity:expr, $tag:expr $(,)?) => {
        $crate::SharedBufferPool::new(|| $crate::BufferPool::new($capacity, $tag))
    };
}
