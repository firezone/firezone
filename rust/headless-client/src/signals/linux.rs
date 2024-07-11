use anyhow::Result;
use futures::{
    future::poll_fn,
    task::{Context, Poll},
};
use std::pin::pin;
use tokio::signal::unix::{signal, Signal, SignalKind};

pub(crate) struct Terminate {
    /// For Ctrl+C from a terminal
    sigint: Signal,
    /// For systemd service stopping
    sigterm: Signal,
}

pub(crate) struct Hangup {
    /// For reloading settings in the standalone Client
    sighup: Signal,
}

impl Terminate {
    pub(crate) fn new() -> Result<Self> {
        let sigint = signal(SignalKind::interrupt())?;
        let sigterm = signal(SignalKind::terminate())?;

        Ok(Self { sigint, sigterm })
    }

    pub(crate) fn poll_recv(&mut self, cx: &mut Context<'_>) -> Poll<()> {
        if let Poll::Ready(_) = self.sigint.poll_recv(cx) {
            Poll::Ready(())
        } else if let Poll::Ready(_) = self.sigterm.poll_recv(cx) {
            Poll::Ready(())
        } else {
            Poll::Pending
        }
    }

    /// Waits for SIGINT or SIGTERM
    pub(crate) async fn recv(&mut self) {
        poll_fn(|cx| self.poll_recv(cx)).await
    }
}

impl Hangup {
    pub(crate) fn new() -> Result<Self> {
        let sighup = signal(SignalKind::hangup())?;

        Ok(Self { sighup })
    }

    /// Waits for SIGHUP
    pub(crate) async fn recv(&mut self) {
        self.sighup.recv().await;
    }
}
