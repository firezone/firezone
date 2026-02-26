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
            let mut pending_packet = None;

            loop {
                let mut packet =
                    match next_outbound_packet(&mut pending_packet, &mut outbound_rx).await {
                        Some(packet) => packet,
                        None => return anyhow::Ok(()),
                    };

                let mut guard = match fd.writable().await {
                    Ok(guard) => guard,
                    Err(e) => {
                        tracing::warn!("Failed to await TUN fd writability: {e}");
                        pending_packet = Some(packet);
                        continue;
                    }
                };

                loop {
                    #[cfg(debug_assertions)]
                    tracing::trace!(target: "wire::dev::send", ?packet);

                    match guard.try_io(|inner_fd| write(inner_fd.as_raw_fd(), &packet)) {
                        Err(_would_block) => {
                            pending_packet = Some(packet);
                            break;
                        }
                        Ok(Ok(_bytes_written)) => match next_queued_packet(&mut outbound_rx) {
                            Some(next_packet) => packet = next_packet,
                            None => break,
                        },
                        Ok(Err(e)) => {
                            tracing::warn!("Failed to write to TUN FD: {e}");
                            match next_queued_packet(&mut outbound_rx) {
                                Some(next_packet) => packet = next_packet,
                                None => break,
                            }
                        }
                    }
                }
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

                loop {
                    let result = guard.try_io(|inner_fd| read_packet(&read, inner_fd.as_raw_fd()));

                    match result {
                        Err(_would_block) => break,
                        Ok(Ok(None)) => bail!("TUN file descriptor is closed"),
                        Ok(Ok(Some(packet))) => {
                            #[cfg(debug_assertions)]
                            tracing::trace!(target: "wire::dev::recv", ?packet);

                            if inbound_tx.send(packet).await.is_err() {
                                tracing::debug!("Inbound packet receiver gone, shutting down task");
                                return anyhow::Ok(());
                            }
                        }
                        Ok(Err(e)) => log_read_error(e),
                    }
                }
            }
        })?;

    anyhow::Ok(())
}

async fn next_outbound_packet(
    pending_packet: &mut Option<IpPacket>,
    outbound_rx: &mut mpsc::Receiver<IpPacket>,
) -> Option<IpPacket> {
    if let Some(packet) = pending_packet.take() {
        return Some(packet);
    }

    outbound_rx.recv().await
}

fn next_queued_packet(outbound_rx: &mut mpsc::Receiver<IpPacket>) -> Option<IpPacket> {
    match outbound_rx.try_recv() {
        Ok(packet) => Some(packet),
        Err(mpsc::error::TryRecvError::Empty) => None,
        Err(mpsc::error::TryRecvError::Disconnected) => None,
    }
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

fn log_read_error(error: io::Error) {
    let error = anyhow::Error::new(error).context("Failed to read from TUN FD");

    if error.any_is::<ip_packet::Fragmented>() {
        tracing::debug!("{error:#}"); // Log on debug to be less noisy.
    } else {
        tracing::warn!("{error:#}");
    }
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
