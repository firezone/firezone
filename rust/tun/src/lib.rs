use std::{
    io,
    task::{Context, Poll},
};

pub mod ioctl;
#[cfg(target_family = "unix")]
pub mod unix;

pub trait TunTrait: Send + Sync + 'static {
    fn write4(&self, buf: &[u8]) -> io::Result<usize>;
    fn write6(&self, buf: &[u8]) -> io::Result<usize>;
    fn poll_read(&mut self, buf: &mut [u8], cx: &mut Context<'_>) -> Poll<io::Result<usize>>;
    fn name(&self) -> &str;
}
