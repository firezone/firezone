use anyhow::{Context as _, Result, bail};
use futures::StreamExt as _;
use ip_packet::{IpPacket, IpPacketBuf};
use std::io;
use std::os::fd::AsRawFd;
use tokio::io::unix::AsyncFd;
use tokio::sync::mpsc;

pub fn tun_send<T>(
    fd: T,
    mut outbound_rx: flume::r#async::RecvStream<'_, IpPacket>,
    write: impl Fn(i32, &IpPacket) -> std::result::Result<usize, io::Error>,
) -> Result<()>
where
    T: AsRawFd + Clone,
{
    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .context("Failed to create runtime")?
        .block_on(async move {
            let fd = AsyncFd::with_interest(fd, tokio::io::Interest::WRITABLE)?;

            while let Some(packet) = outbound_rx.next().await {
                if let Err(e) = fd
                    .async_io(tokio::io::Interest::WRITABLE, |fd| {
                        write(fd.as_raw_fd(), &packet)
                    })
                    .await
                {
                    tracing::warn!("Failed to write to TUN FD: {e}");
                }
            }

            anyhow::Ok(())
        })?;

    anyhow::Ok(())
}

pub fn tun_recv<T>(
    fd: T,
    inbound_tx: mpsc::Sender<IpPacket>,
    read: impl Fn(i32, &mut IpPacketBuf) -> std::result::Result<usize, io::Error>,
) -> Result<()>
where
    T: AsRawFd + Clone,
{
    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .context("Failed to create runtime")?
        .block_on(async move {
            let fd = AsyncFd::with_interest(fd, tokio::io::Interest::READABLE)?;

            loop {
                let next_inbound_packet = fd
                    .async_io(tokio::io::Interest::READABLE, |fd| {
                        let mut ip_packet_buf = IpPacketBuf::new();

                        let len = read(fd.as_raw_fd(), &mut ip_packet_buf)?;

                        if len == 0 {
                            return Ok(None);
                        }

                        let packet = IpPacket::new(ip_packet_buf, len)
                            .map_err(|e| io::Error::new(io::ErrorKind::InvalidInput, e))?;

                        Ok(Some(packet))
                    })
                    .await;

                match next_inbound_packet {
                    Ok(None) => bail!("TUN file descriptor is closed"),
                    Ok(Some(packet)) => {
                        if inbound_tx.send(packet).await.is_err() {
                            tracing::debug!("Inbound packet receiver gone, shutting down task");

                            break;
                        };
                    }
                    Err(e) => {
                        tracing::warn!("Failed to read from TUN FD: {e}");
                        continue;
                    }
                }
            }

            anyhow::Ok(())
        })?;

    anyhow::Ok(())
}
