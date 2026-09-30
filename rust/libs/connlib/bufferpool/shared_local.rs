use crate::{Buf, Buffer, BufferPool, Local};
use std::thread::LocalKey;

/// Default ownership for pools on Linux, macOS and iOS.
pub type DefaultSharing = Local;

/// A static pool that keeps separate, unsynchronized storage on each thread.
pub struct SharedBufferPool<B: 'static> {
    pool: &'static LocalKey<BufferPool<B>>,
}

impl<B: 'static> SharedBufferPool<B> {
    #[doc(hidden)]
    pub const fn new(pool: &'static LocalKey<BufferPool<B>>) -> Self {
        Self { pool }
    }
}

impl<B: Buf + 'static> SharedBufferPool<B> {
    pub fn pull(&self) -> Buffer<B> {
        self.pool.with(|pool| pool.pull())
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
    ($buffer:ty, $capacity:expr, $tag:expr $(,)?) => {{
        ::std::thread_local! {
            static POOL: $crate::BufferPool<$buffer> = $crate::BufferPool::new($capacity, $tag);
        }
        $crate::SharedBufferPool::new(&POOL)
    }};
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn static_pool_recycles_separate_storage_on_each_thread() {
        static POOL: SharedBufferPool<Vec<u8>> = shared_buffer_pool!(Vec<u8>, 8, "test");

        let address = POOL.pull().as_ptr() as usize;
        let worker_address = std::thread::spawn(|| POOL.pull().as_ptr() as usize)
            .join()
            .unwrap();

        assert_ne!(address, worker_address);
        assert_eq!(POOL.pull().as_ptr() as usize, address);
    }
}
