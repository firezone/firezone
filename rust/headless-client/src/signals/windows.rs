use anyhow::Result;
use futures::{
    future::poll_fn,
    task::{Context, Poll},
};

// This looks like a pointless wrapper around `CtrlC`, because it must match
// the Linux signatures
pub(crate) struct Terminate {
    sigint: tokio::signal::windows::CtrlC,
}

// SIGHUP is used on Linux but not on Windows
pub(crate) struct Hangup {}

impl Terminate {
    pub(crate) fn new() -> Result<Self> {
        let sigint = tokio::signal::windows::ctrl_c()?;
        Ok(Self { sigint })
    }

    pub(crate) fn poll_recv(&mut self, cx: &mut Context<'_>) -> Poll<()> {
        self.sigint.poll_recv(cx).map(|_| ())
    }

    /// Waits for Ctrl+C
    pub(crate) async fn recv(&mut self) {
        poll_fn(|cx| self.poll_recv(cx)).await
    }
}

impl Hangup {
    #[allow(clippy::unnecessary_wraps)]
    pub(crate) fn new() -> Result<Self> {
        Ok(Self {})
    }

    /// Waits forever - Only implemented for Linux
    pub(crate) async fn recv(&mut self) {
        let () = std::future::pending().await;
        unreachable!()
    }
}
