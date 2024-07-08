use anyhow::Result;
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

        Ok(Self {
            sighup,
            sigint,
            sigterm,
        })
    }

    /// Waits for SIGINT or SIGTERM
    pub(crate) async fn recv(&mut self) {
        futures::select! {
            _ = pin!(self.sigint.recv().fuse()) => {},
            _ = pin!(self.sigterm.recv().fuse()) => {},
        }
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
        Kind::Hangup
    }
}
