use anyhow::Result;
use futures::{
    future::poll_fn,
    task::{Context, Poll},
};

// This looks like a pointless wrapper around `CtrlC`, because it must match
// the Linux signatures
pub struct Terminate {
    sigint: tokio::signal::windows::CtrlC,
}

// SIGHUP is used on Linux but not on Windows
pub struct Hangup {}

impl Terminate {
    pub fn new() -> Result<Self> {
        let sigint = tokio::signal::windows::ctrl_c()?;
        Ok(Self { sigint })
    }

    pub fn poll_recv(&mut self, cx: &mut Context<'_>) -> Poll<()> {
        self.sigint.poll_recv(cx).map(|_| ())
    }

    /// Waits for Ctrl+C
    pub async fn recv(&mut self) {
        poll_fn(|cx| self.poll_recv(cx)).await
    }
}

impl Hangup {
    #[expect(clippy::unnecessary_wraps)]
    pub fn new() -> Result<Self> {
        Ok(Self {})
    }

    /// Waits forever - Only implemented for Linux
    pub async fn recv(&mut self) {
        let () = std::future::pending().await;
        unreachable!()
    }
}
