use anyhow::{Context as _, ErrorExt, Result, bail};
use ip_packet::{IpPacket, IpPacketBuf};
use opentelemetry::KeyValue;
use std::io;
use std::mem;
use std::os::fd::AsRawFd;
use tokio::io::unix::AsyncFd;

use crate::PacketBatch;

/// How many times we at most try to re-write a packet if the TUN queue is full (`ENOSPC` on MacOS / iOS).
#[cfg(any(target_os = "macos", target_os = "ios"))]
const MAX_ENOSPC_RETRIES: u32 = 24;

/// Upper bound (as a power of two) for how many times we busy-spin between write retries.
///
/// `2^6 = 64` iterations of [`std::hint::spin_loop`] stay well below a microsecond.
const SPIN_LIMIT: u32 = 6;

pub fn tun_send<T>(
    fd: T,
    mut outbound_rx: crate::OutboundRx,
    write: impl Fn(i32, &IpPacket) -> std::result::Result<usize, io::Error>,
) -> Result<()>
where
    T: AsRawFd + Clone,
{
    let write_retry_histogram = otel_instruments::network_retries();
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

                    let mut attempt = 0;

                    loop {
                        match fd
                            .async_io(tokio::io::Interest::WRITABLE, |fd| {
                                write(fd.as_raw_fd(), &packet)
                            })
                            .await
                        {
                            Ok(_) => {
                                record_write_retries(&write_retry_histogram, attempt);

                                break;
                            }
                            Err(e) if should_retry(&e, attempt) => {
                                spin_and_yield(attempt).await;

                                attempt += 1;
                            }
                            Err(e) => {
                                record_write_retries(&write_retry_histogram, attempt);
                                dropped_packets_counter.add(1, &drop_attributes(&e));

                                if is_queue_full(&e) {
                                    // The TUN queue is still full after all retries; dropping is by design, like for any congested network device.
                                    tracing::debug!("Failed to write to TUN FD: {e}");
                                } else {
                                    tracing::warn!("Failed to write to TUN FD: {e}");
                                }

                                break;
                            }
                        }
                    }
                }
            }

            anyhow::Ok(())
        })?;

    anyhow::Ok(())
}

/// Whether a failed TUN write should be retried for the given attempt.
fn should_retry(e: &io::Error, attempt: u32) -> bool {
    // On MacOS / iOS, the kernel returns `ENOSPC` when the TUN queue fills up.
    // It's transient and clears off this thread, and isn't observable
    // via write-readiness, so we retry rather than suspend.
    #[cfg(any(target_os = "macos", target_os = "ios"))]
    if is_queue_full(e) && attempt < MAX_ENOSPC_RETRIES {
        return true;
    }

    let _ = (e, attempt);

    false
}

/// Whether the write failed because the TUN queue is full (`ENOSPC` on MacOS / iOS).
///
/// Dropping in this case is expected back-pressure; any other error is a genuine failure.
#[cfg(any(target_os = "macos", target_os = "ios"))]
fn is_queue_full(e: &io::Error) -> bool {
    e.raw_os_error() == Some(libc::ENOSPC)
}

#[cfg(not(any(target_os = "macos", target_os = "ios")))]
fn is_queue_full(_e: &io::Error) -> bool {
    false
}

/// Briefly back off after a retryable write error before trying again.
///
/// We avoid `tokio::time::sleep`: its timer wheel rounds up to ~1ms, far longer
/// than the microseconds an `ENOSPC` needs to clear. Instead we spin a few
/// (escalating) times and then cooperatively yield to not starve other tasks.
async fn spin_and_yield(attempt: u32) {
    for _ in 0..(1u32 << attempt.min(SPIN_LIMIT)) {
        std::hint::spin_loop();
    }

    tokio::task::yield_now().await;
}

/// Records how many times a single packet write had to be retried before it went through or was dropped.
///
/// Writes that succeed on the first try (the common case) are not recorded, keeping the hot path cheap.
fn record_write_retries(histogram: &opentelemetry::metrics::Histogram<u64>, attempt: u32) {
    if attempt == 0 {
        return;
    }

    histogram.record(attempt as u64, &metric_attributes());
}

fn metric_attributes() -> [KeyValue; 2] {
    [
        KeyValue::new("system.device", "tun"),
        KeyValue::new("network.io.direction", "transmit"),
    ]
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
    inbound_tx: crate::InboundTx,
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
                let mut guard = fd.readable().await?;

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
