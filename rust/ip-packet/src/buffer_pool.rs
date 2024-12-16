use std::{
    ops::{Deref, DerefMut},
    sync::{Arc, LazyLock},
};

use crate::MAX_DATAGRAM_PAYLOAD;

type BufferPool = Arc<lockfree_object_pool::MutexObjectPool<Vec<u8>>>;

static BUFFER_POOL: LazyLock<BufferPool> = LazyLock::new(|| {
    Arc::new(lockfree_object_pool::MutexObjectPool::new(
        || vec![0; MAX_DATAGRAM_PAYLOAD],
        |v| v.fill(0),
    ))
});

pub struct Buffer(lockfree_object_pool::MutexOwnedReusable<Vec<u8>>);

impl Clone for Buffer {
    fn clone(&self) -> Self {
        let mut copy = Buffer::default();

        copy.0.resize(self.len(), 0);
        copy.copy_from_slice(self);

        copy
    }
}

impl PartialEq for Buffer {
    fn eq(&self, other: &Self) -> bool {
        self.as_ref() == other.as_ref()
    }
}

impl std::fmt::Debug for Buffer {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_tuple("Buffer").finish()
    }
}

impl Deref for Buffer {
    type Target = [u8];

    fn deref(&self) -> &Self::Target {
        &self.0[..]
    }
}

impl DerefMut for Buffer {
    fn deref_mut(&mut self) -> &mut Self::Target {
        &mut self.0[..]
    }
}

impl Default for Buffer {
    fn default() -> Self {
        Self(BUFFER_POOL.pull_owned())
    }
}

impl Drop for Buffer {
    fn drop(&mut self) {
        debug_assert_eq!(
            self.0.capacity(),
            MAX_DATAGRAM_PAYLOAD,
            "Buffer should never re-allocate"
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn buffer_can_be_cloned() {
        let mut buffer = Buffer::default();
        buffer[..11].copy_from_slice(b"hello world");

        let buffer2 = buffer.clone();

        assert_eq!(&buffer2[..], &buffer[..]);
    }

    #[test]
    fn cloned_buffer_owns_its_own_memory() {
        let mut buffer = Buffer::default();
        buffer[..11].copy_from_slice(b"hello world");

        let buffer2 = buffer.clone();
        drop(buffer);

        assert_eq!(&buffer2[..11], b"hello world");
    }
}
