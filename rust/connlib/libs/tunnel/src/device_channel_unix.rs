use std::{
    sync::atomic::{AtomicUsize, Ordering::Relaxed},
    task::Poll,
    time::Duration,
};

use futures_util::ready;
use ip_network::IpNetwork;
use libs_common::{messages::Interface, CallbackErrorFacade, Callbacks, Result};
use tokio::{
    io::{unix::AsyncFd, AsyncRead, AsyncWrite, AsyncWriteExt, BufReader, BufWriter},
    sync::mpsc::Sender,
    time::Instant,
};

use crate::tun::{IfaceDevice, IfaceStream};

const WRITER_CHANNEL_SIZE: usize = 1024;

pub(crate) struct IfaceConfig {
    mtu: AtomicUsize,
    iface: IfaceDevice,
}

pub(crate) struct DeviceIo(AsyncFd<IfaceStream>);

impl AsyncWrite for DeviceIo {
    fn poll_write(
        self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
        buf: &[u8],
    ) -> std::task::Poll<std::result::Result<usize, std::io::Error>> {
        loop {
            let mut guard = ready!(self.0.poll_write_ready(cx))?;

            match guard.try_io(|inner| inner.get_ref().write(buf)) {
                Ok(result) => return Poll::Ready(result),
                Err(_would_block) => continue,
            }
        }
    }

    fn poll_flush(
        self: std::pin::Pin<&mut Self>,
        _: &mut std::task::Context<'_>,
    ) -> std::task::Poll<std::result::Result<(), std::io::Error>> {
        Poll::Ready(Ok(()))
    }

    fn poll_shutdown(
        self: std::pin::Pin<&mut Self>,
        _: &mut std::task::Context<'_>,
    ) -> std::task::Poll<std::result::Result<(), std::io::Error>> {
        Poll::Ready(Ok(()))
    }
}

impl AsyncRead for DeviceIo {
    fn poll_read(
        self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
        buf: &mut tokio::io::ReadBuf<'_>,
    ) -> Poll<std::io::Result<()>> {
        loop {
            let mut guard = ready!(self.0.poll_read_ready(cx))?;

            let unfilled = buf.initialize_unfilled();
            match guard.try_io(|inner| inner.get_ref().read(unfilled)) {
                Ok(Ok(len)) => {
                    buf.advance(len);
                    return Poll::Ready(Ok(()));
                }
                Ok(Err(err)) => return Poll::Ready(Err(err)),
                Err(_would_block) => continue,
            }
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
        callbacks: &CallbackErrorFacade<impl Callbacks>,
    ) -> Result<()> {
        self.iface.add_route(route, callbacks).await
    }
}

pub(crate) async fn create_iface(
    config: &Interface,
    callbacks: &CallbackErrorFacade<impl Callbacks>,
) -> Result<(
    IfaceConfig,
    Sender<Vec<u8>>,
    BufReader<tokio::io::ReadHalf<DeviceIo>>,
)> {
    let (stream, iface) = IfaceDevice::new(config, callbacks).await?;
    iface.up().await?;
    let device_io = DeviceIo(AsyncFd::new(stream)?);
    let (device_reader, mut device_writer) = tokio::io::split(device_io);
    let device_reader = BufReader::new(device_reader);
    //let mut device_writer = BufWriter::new(device_writer);
    let (writer_tx, mut writer_rx) = tokio::sync::mpsc::channel::<Vec<u8>>(WRITER_CHANNEL_SIZE);
    tokio::spawn(async move {
        let sleep = tokio::time::sleep(Duration::from_millis(5));
        tokio::pin!(sleep);
        loop {
            tokio::select! {
                Some(rx) = writer_rx.recv() => {
                    device_writer.write_all(&rx).await;
                    sleep.as_mut().reset(Instant::now() + Duration::from_millis(5));
                }
                () = &mut sleep => {
                    device_writer.flush().await;
                    sleep.as_mut().reset(Instant::now() + Duration::from_millis(5));
                }
                else => break
            }
        }
        device_writer.flush().await;
    });
    let mtu = iface.mtu().await?;
    let iface_config = IfaceConfig {
        iface,
        mtu: AtomicUsize::new(mtu),
    };

    Ok((iface_config, writer_tx, device_reader))
}
