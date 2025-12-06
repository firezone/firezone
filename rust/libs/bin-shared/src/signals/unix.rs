use anyhow::Result;
use futures::{
    future::poll_fn,
    task::{Context, Poll},
};
use tokio::signal::unix::{Signal, SignalKind, signal};

pub struct Terminate {
    /// For Ctrl+C from a terminal
    sigint: Signal,
    /// For systemd service stopping
    sigterm: Signal,
}

pub struct Hangup {
    /// For reloading settings in the standalone Client
    sighup: Signal,
}

impl Terminate {
    pub fn new() -> Result<Self> {
        let sigint = signal(SignalKind::interrupt())?;
        let sigterm = signal(SignalKind::terminate())?;

        Ok(Self { sigint, sigterm })
    }

    pub fn poll_recv(&mut self, cx: &mut Context<'_>) -> Poll<()> {
        if self.sigint.poll_recv(cx).is_ready() || self.sigterm.poll_recv(cx).is_ready() {
            Poll::Ready(())
        } else {
            Poll::Pending
        }
    }

    /// Waits for SIGINT or SIGTERM
    pub async fn recv(&mut self) {
        poll_fn(|cx| self.poll_recv(cx)).await
    }
}

impl Hangup {
    pub fn new() -> Result<Self> {
        let sighup = signal(SignalKind::hangup())?;

        Ok(Self { sighup })
    }

    /// Waits for SIGHUP
    pub async fn recv(&mut self) {
        self.sighup.recv().await;
    }
}
