use anyhow::{Context as _, ErrorExt, Result, bail};
use ip_packet::{IpPacket, IpPacketBuf};
use std::io;
use std::os::fd::AsRawFd;
use tokio::io::unix::AsyncFd;
use tokio::sync::mpsc;

pub fn tun_send<T>(
    fd: T,
    mut outbound_rx: mpsc::Receiver<IpPacket>,
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
            let mut pending_packets = Vec::with_capacity(128);

            'read: loop {
                // Read a batch of packets.
                let num_read = outbound_rx.recv_many(&mut pending_packets, 128).await;

                if num_read == 0 {
                    return anyhow::Ok(());
                }

                // Wait until fd is writable.
                let mut guard = match fd.writable().await {
                    Ok(guard) => guard,
                    Err(e) => {
                        tracing::warn!("Failed to await TUN fd writability: {e}");
                        continue 'read;
                    }
                };

                let mut idx = 0;

                'write: while idx < num_read {
                    let packet = &pending_packets[idx];

                    // Try and write the current packet.
                    match guard.try_io(|fd| write(fd.as_raw_fd(), packet)) {
                        Err(_would_block) => {
                            // Renew the guard if fd is no longer writable.
                            guard = match fd.writable().await {
                                Ok(guard) => guard,
                                Err(e) => {
                                    // Temporary(?) IO error when waiting for writablility.
                                    // Loop around to try and write the same packet again.
                                    // Most likely, we will end up in this branch again as a result.
                                    tracing::warn!("Failed to await TUN fd writability: {e}");
                                    continue 'write;
                                }
                            };
                        }
                        Ok(Ok(_bytes_written)) => {
                            #[cfg(debug_assertions)]
                            tracing::trace!(target: "wire::dev::send", ?packet);

                            idx += 1; // We sent the packet, go to the next one.
                        }
                        Ok(Err(e)) => {
                            tracing::warn!(?packet, "Failed to write to TUN FD: {e}");

                            idx += 1; // We failed to send the packet, go to the next one.
                        }
                    }
                }

                // Clear the buffer for the next batch.
                pending_packets.clear();
            }
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
                let mut guard = match fd.readable().await {
                    Ok(guard) => guard,
                    Err(e) => {
                        tracing::warn!("Failed to await TUN fd readability: {e}");
                        continue;
                    }
                };

                // `try_io` returns an `Err` only if the fd is not readable anymore.
                // In that case we want to loop around and .await a new read guard.
                while let Ok(res) = guard.try_io(|fd| read_packet(&read, fd.as_raw_fd())) {
                    match res.context("Failed to read from TUN fd") {
                        Ok(Some(packet)) => {
                            #[cfg(debug_assertions)]
                            tracing::trace!(target: "wire::dev::recv", ?packet);

                            if inbound_tx.send(packet).await.is_err() {
                                tracing::debug!("Inbound packet receiver gone, shutting down task");
                                return anyhow::Ok(());
                            }
                        }
                        Ok(None) => bail!("TUN file descriptor is closed"),
                        Err(e) if e.any_is::<ip_packet::Fragmented>() => {
                            tracing::debug!("{e:#}"); // Log on debug to be less noisy.
                        }
                        Err(e) => {
                            tracing::warn!("{e:#}");
                        }
                    }
                }
            }
        })?;

    anyhow::Ok(())
}

fn read_packet(
    read: &impl Fn(i32, &mut IpPacketBuf) -> std::result::Result<usize, io::Error>,
    raw_fd: i32,
) -> std::result::Result<Option<IpPacket>, io::Error> {
    let mut ip_packet_buf = IpPacketBuf::new();
    let len = read(raw_fd, &mut ip_packet_buf)?;

    if len == 0 {
        return Ok(None);
    }

    let packet = IpPacket::new(ip_packet_buf, len)
        .context("Failed to parse IP packet") // Add an extra layer to ensure any inner error is the `cause`
        .map_err(|e| io::Error::new(io::ErrorKind::InvalidInput, e))?;

    Ok(Some(packet))
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
