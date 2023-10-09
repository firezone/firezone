use std::os::fd::{AsRawFd, RawFd};
use std::sync::atomic::{AtomicBool, Ordering};

#[derive(Debug)]
pub(crate) struct Closeable {
    closed: AtomicBool,
    value: RawFd,
}

impl AsRawFd for Closeable {
    fn as_raw_fd(&self) -> RawFd {
        self.value.as_raw_fd()
    }
}

impl Closeable {
    pub(crate) fn new(fd: RawFd) -> Self {
        Self {
            closed: AtomicBool::new(false),
            value: fd,
        }
    }

    pub(crate) fn with<U>(&self, f: impl FnOnce(RawFd) -> U) -> std::io::Result<U> {
        if self.closed.load(Ordering::Acquire) {
            return Err(std::io::Error::from_raw_os_error(9));
        }

        Ok(f(self.value))
    }

    pub(crate) fn close(&self) {
        self.closed.store(true, Ordering::Release);
    }
}
