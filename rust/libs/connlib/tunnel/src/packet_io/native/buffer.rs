use bufferpool::Buffer;
use compio::buf::{IoBuf, IoBufMut, SetLen};
use std::mem::MaybeUninit;

pub struct UdpBuffer {
    pub inner: Buffer<Vec<u8>>,
    pub len: usize,
}

impl IoBuf for UdpBuffer {
    fn as_init(&self) -> &[u8] {
        &self.inner[..self.len]
    }
}
impl SetLen for UdpBuffer {
    unsafe fn set_len(&mut self, len: usize) {
        assert!(len <= self.inner.len());
        self.len = len;
    }
}
impl IoBufMut for UdpBuffer {
    fn as_uninit(&mut self) -> &mut [MaybeUninit<u8>] {
        // The pool initializes its entire receive buffer before lending it to the kernel.
        unsafe { std::slice::from_raw_parts_mut(self.inner.as_mut_ptr().cast(), self.inner.len()) }
    }
}

impl AsRef<[u8]> for UdpBuffer {
    fn as_ref(&self) -> &[u8] {
        self.as_init()
    }
}
