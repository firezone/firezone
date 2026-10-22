use anyhow::{Context as _, ErrorExt, Result, bail};
use futures::future::{self, Either};
use ip_packet::{IpPacket, IpPacketBuf};
use opentelemetry::KeyValue;
use std::io;
use std::mem;
use std::os::fd::AsRawFd;
use std::pin::pin;
use tokio::io::unix::AsyncFd;

use tun::PacketBatch;

pub fn tun_send<T>(
    fd: T,
    mut outbound_rx: tun::OutboundRx,
    write: impl Fn(i32, &IpPacket) -> std::result::Result<usize, io::Error>,
) -> Result<()>
where
    T: AsRawFd + Clone,
{
    let dropped_packets_counter = otel_instruments::network_packet_dropped();

    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .context("Failed to create runtime")?
        .block_on(async move {
            let fd = AsyncFd::with_interest(fd, tokio::io::Interest::WRITABLE)?;

            while let Some(mut batch) = outbound_rx.recv().await {
                for packet in batch.drain() {
                    #[cfg(debug_assertions)]
                    tracing::trace!(target: "wire::dev::send", ?packet);

                    if let Err(e) = fd
                        .async_io(tokio::io::Interest::WRITABLE, |fd| {
                            write(fd.as_raw_fd(), &packet)
                        })
                        .await
                    {
                        dropped_packets_counter.add(1, &drop_attributes(&e));
                        tracing::warn!("Failed to write to TUN FD: {e}");
                    }
                }
            }

            anyhow::Ok(())
        })?;

    anyhow::Ok(())
}

/// Attributes for a dropped packet, including the OS error code so queue-full
/// (`ENOSPC`) drops can be told apart from other write failures.
fn drop_attributes(e: &io::Error) -> [KeyValue; 3] {
    [
        KeyValue::new("system.device", "tun"),
        KeyValue::new("network.io.direction", "transmit"),
        KeyValue::new("error.code", e.raw_os_error().unwrap_or_default() as i64),
    ]
}

pub fn tun_recv<T>(
    fd: T,
    inbound_tx: tun::InboundTx,
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
            let mut batch = PacketBatch::default();

            loop {
                let readable = pin!(fd.readable());
                let closed = pin!(inbound_tx.closed());

                let mut guard = match future::select(readable, closed).await {
                    Either::Left((guard, _)) => guard?,
                    Either::Right(((), _)) => {
                        tracing::debug!("Inbound packet receiver gone, shutting down task");

                        return anyhow::Ok(());
                    }
                };

                // Drain the FD before handing the packets off as a single batch, so one
                // channel item feeds a whole read burst into the state loop instead of
                // one packet.
                loop {
                    let mut ip_packet_buf = IpPacketBuf::new();

                    let len = match guard
                        .try_io(|fd| read(fd.get_ref().as_raw_fd(), &mut ip_packet_buf))
                    {
                        Ok(Ok(0)) => bail!("TUN file descriptor is closed"),
                        Ok(Ok(len)) => len,
                        Ok(Err(e)) => {
                            return Err(anyhow::Error::new(e))
                                .context("Failed to read from TUN FD");
                        }
                        Err(_would_block) => break, // FD is drained; hand off what we have.
                    };

                    match IpPacket::new(ip_packet_buf, len) {
                        Ok(packet) => {
                            #[cfg(debug_assertions)]
                            tracing::trace!(target: "wire::dev::recv", ?packet);

                            let Err(packet) = batch.try_push(packet) else {
                                continue;
                            };

                            // The batch is full: hand it off and start a new one.
                            if inbound_tx
                                .send(mem::replace(&mut batch, PacketBatch::new(packet)))
                                .await
                                .is_err()
                            {
                                tracing::debug!("Inbound packet receiver gone, shutting down task");

                                return anyhow::Ok(());
                            }
                        }
                        Err(e) if e.any_is::<ip_packet::Fragmented>() => {
                            tracing::debug!("{e:#}") // Log on debug to be less noisy.
                        }
                        Err(e) => tracing::warn!("{e:#}"),
                    }
                }

                if batch.is_empty() {
                    continue;
                }

                if inbound_tx.send(mem::take(&mut batch)).await.is_err() {
                    tracing::debug!("Inbound packet receiver gone, shutting down task");

                    return anyhow::Ok(());
                }
            }
        })?;

    anyhow::Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn can_detect_ip_fragmented_error() {
        let ip_packet_error =
            anyhow::Error::new(ip_packet::Fragmented).context("Failed to parse IP packet");
        let io_error = io::Error::new(io::ErrorKind::InvalidInput, ip_packet_error);

        let final_error = anyhow::Error::new(io_error).context("Failed to read from TUN fd");

        assert!(final_error.any_is::<ip_packet::Fragmented>())
    }
}
