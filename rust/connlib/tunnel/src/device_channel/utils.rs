use std::io;
use std::os::fd::{AsRawFd, RawFd};
use std::task::{Context, Poll};
use tokio::io::Ready;

pub fn poll_raw_fd(
    fd: &tokio::io::unix::AsyncFd<RawFd>,
    mut read: impl FnMut(RawFd) -> io::Result<usize>,
    cx: &mut Context<'_>,
) -> Poll<io::Result<usize>> {
    loop {
        let mut guard = std::task::ready!(fd.poll_read_ready(cx))?;

        match read(guard.get_inner().as_raw_fd()) {
            Ok(n) => return Poll::Ready(Ok(n)),
            Err(ref e) if e.kind() == io::ErrorKind::WouldBlock => {
                // a read has blocked, but a write might still succeed.
                // clear only the read readiness.
                guard.clear_ready_matching(Ready::READABLE);
                continue;
            }
            Err(e) => return Poll::Ready(Err(e)),
        }
    }
}
