use anyhow::{Result, bail};
use futures::task::{Context, Poll};

pub struct Terminate {}

pub struct Hangup {}

impl Terminate {
    pub fn new() -> Result<Self> {
        bail!("Not implemented")
    }

    pub fn poll_recv(&mut self, _cx: &mut Context<'_>) -> Poll<()> {
        Poll::Pending
    }

    #[expect(
        clippy::unused_async,
        reason = "Signture must match other operating systems"
    )]
    pub async fn recv(&mut self) {}
}

impl Hangup {
    pub fn new() -> Result<Self> {
        bail!("Not implemented")
    }

    #[expect(
        clippy::unused_async,
        reason = "Signture must match other operating systems"
    )]
    pub async fn recv(&mut self) {}
}
