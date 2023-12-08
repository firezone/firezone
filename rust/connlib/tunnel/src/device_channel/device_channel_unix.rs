use std::io;
use std::sync::{
    atomic::{AtomicUsize, Ordering::Relaxed},
    Arc,
};
use std::task::{ready, Context, Poll};

use connlib_shared::{messages::Interface, Callbacks, Error, Result};
use ip_network::IpNetwork;
use tokio::io::{unix::AsyncFd, Ready};

use tun::{IfaceDevice, IfaceStream};

use crate::device_channel::{Device, Packet};
use crate::DnsFallbackStrategy;

mod tun;

pub(crate) struct IfaceConfig {
    mtu: AtomicUsize,
    iface: IfaceDevice,
}

pub(crate) struct DeviceIo(Arc<AsyncFd<IfaceStream>>);

impl DeviceIo {
    pub fn poll_read(&self, out: &mut [u8], cx: &mut Context<'_>) -> Poll<io::Result<usize>> {
        loop {
            let mut guard = ready!(self.0.poll_read_ready(cx))?;

            match guard.get_inner().read(out) {
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

    // Note: write is synchronous because it's non-blocking
    // and some losiness is acceptable and increseases performance
    // since we don't block the reading loops.
    pub fn write(&self, packet: Packet<'_>) -> io::Result<usize> {
        match packet {
            Packet::Ipv4(msg) => self.0.get_ref().write4(&msg),
            Packet::Ipv6(msg) => self.0.get_ref().write6(&msg),
        }
    }
}

impl IfaceConfig {
    pub(crate) fn mtu(&self) -> usize {
        self.mtu.load(Relaxed)
    }

    pub(crate) async fn refresh_mtu(&self) -> Result<usize> {
        let mtu = self.iface.mtu().await?;
        self.mtu.store(mtu, Relaxed);
        Ok(mtu)
    }

    pub(crate) async fn add_route(
        &self,
        route: IpNetwork,
        callbacks: &impl Callbacks<Error = Error>,
    ) -> Result<Option<Device>> {
        let Some((iface, stream)) = self.iface.add_route(route, callbacks).await? else {
            return Ok(None);
        };
        let io = DeviceIo(stream);
        let mtu = iface.mtu().await?;
        let config = IfaceConfig {
            iface,
            mtu: AtomicUsize::new(mtu),
        };
        Ok(Some(Device { io, config }))
    }
}

pub(crate) async fn create_iface(
    config: &Interface,
    callbacks: &impl Callbacks<Error = Error>,
    fallback_strategy: DnsFallbackStrategy,
) -> Result<Device> {
    let (iface, stream) = IfaceDevice::new(config, callbacks, fallback_strategy).await?;
    iface.up().await?;
    let io = DeviceIo(stream);
    let mtu = iface.mtu().await?;
    let config = IfaceConfig {
        iface,
        mtu: AtomicUsize::new(mtu),
    };

    Ok(Device { io, config })
}
