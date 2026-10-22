//! The Apple clients handle this in `PacketTunnelProvider.wake`, not here.

use anyhow::Result;
use futures::stream::BoxStream;

#[expect(
    clippy::unused_async,
    reason = "Must match the Linux implementation, which needs to connect to DBus."
)]
pub(crate) async fn resume_stream() -> Result<BoxStream<'static, Result<()>>> {
    Err(anyhow::anyhow!("Not implemented"))
}
