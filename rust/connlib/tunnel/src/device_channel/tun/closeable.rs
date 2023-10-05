use std::os::fd::{AsRawFd, RawFd};
use std::sync::atomic::{AtomicBool, Ordering};

#[derive(Debug)]
pub(crate) struct Closeable<T> {
    closed: AtomicBool,
    value: T,
}

impl<T: AsRawFd> AsRawFd for Closeable<T> {
    fn as_raw_fd(&self) -> RawFd {
        self.value.as_raw_fd()
    }
}

impl<T: Copy> Closeable<T> {
    pub(crate) fn new(t: T) -> Self {
        Self {
            closed: AtomicBool::new(false),
            value: t,
        }
    }

    pub(crate) fn with<U>(&self, f: impl FnOnce(T) -> U) -> std::io::Result<U> {
        if self.closed.load(Ordering::Acquire) {
            return Err(std::io::Error::from_raw_os_error(9));
        }

        Ok(f(self.value))
    }

    pub(crate) fn close(&self) {
        self.closed.store(true, Ordering::Release);
    }
}
