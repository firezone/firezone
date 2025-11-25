use anyhow::Result;
use futures::{
    StreamExt as _,
    channel::mpsc,
    future::poll_fn,
    stream::BoxStream,
    task::{Context, Poll},
};

pub struct Terminate {
    inner: BoxStream<'static, ()>,
}

// SIGHUP is used on Linux but not on Windows
pub struct Hangup {}

impl Terminate {
    pub fn new() -> Result<Self> {
        let sigint = tokio::signal::windows::ctrl_c()?;
        let inner = futures::stream::unfold(sigint, |mut sigint| async move {
            sigint.recv().await?;

            Some(((), sigint))
        })
        .boxed();

        Ok(Self { inner })
    }

    pub fn from_channel(rx: mpsc::Receiver<()>) -> Self {
        Self { inner: rx.boxed() }
    }

    pub fn poll_recv(&mut self, cx: &mut Context<'_>) -> Poll<()> {
        self.inner.poll_next_unpin(cx).map(|_| ())
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
