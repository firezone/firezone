#![cfg(target_os = "windows")]
#![cfg_attr(test, allow(clippy::unwrap_used))]

use anyhow::{Context as _, Result};
use ip_packet::{IpPacket, IpPacketBuf};
use opentelemetry::{KeyValue, metrics::Histogram};
use std::{
    env::VarError,
    sync::{Arc, Weak},
    time::Duration,
};

pub struct Io {
    name: String,
    session: Arc<wintun::Session>,
    workers: tun::Workers,
}

impl Io {
    pub fn new(
        name: impl Into<String>,
        adapter: &Arc<wintun::Adapter>,
        should_coalesce_tcp: fn() -> bool,
        runtime: &tokio::runtime::Handle,
    ) -> Result<Self> {
        let capacity = ring_capacity_override()
            .inspect_err(|e| {
                tracing::warn!("Ignoring `{RING_CAPACITY_ENV_VAR}`: {e:#}");
            })
            .unwrap_or_default()
            .unwrap_or(RING_BUFFER_SIZE);

        tracing::debug!(%capacity, "Wintun ring buffer capacity");

        let session = Arc::new(
            adapter
                .start_session(capacity)
                .with_context(|| format!("Failed to start session with capacity {capacity}"))?,
        );
        let send_session = Arc::downgrade(&session);
        let recv_session = Arc::downgrade(&session);

        let workers = tun::Workers::spawn(
            runtime,
            move |outbound_rx| {
                send_worker(outbound_rx, send_session, should_coalesce_tcp);

                Ok(())
            },
            move |inbound_tx| {
                recv_worker(inbound_tx, recv_session);

                Ok(())
            },
        )
        .context("Failed to start TUN worker threads")?;

        Ok(Self {
            name: name.into(),
            session,
            workers,
        })
    }
}

impl Drop for Io {
    fn drop(&mut self) {
        // Cancel blocking reads before closing channels and joining the workers.
        let _ = self.session.shutdown();
    }
}

impl tun::Tun for Io {
    fn sender(&self) -> &tun::OutboundTx {
        self.workers.sender()
    }
    fn receiver(&mut self) -> &mut tun::InboundRx {
        self.workers.receiver()
    }
    fn name(&self) -> &str {
        &self.name
    }
}

/// Capacity of each of Wintun's two ring buffers.
///
/// Must be a power of two between [`wintun::MIN_RING_CAPACITY`] and [`wintun::MAX_RING_CAPACITY`];
/// a session allocates one ring per direction, so the figure is charged twice.
///
/// Sized for 10 Gbit/s: a ring bridges the
/// gap between two turns of the thread draining it. The receive ring sets the requirement, because
/// Wintun keeps filling it while our recv thread is descheduled or blocked on a full channel.
/// [`MAX_EXPECTED_TUN_BITS_PER_SECOND`] for one [`RING_SERVICE_GAP`] is 12.5 MB, which rounds up to
/// 16 MiB: about 13,000 packets at the 1280-byte TUN MTU, and therefore also more than the outbound
/// TUN channel can hand to the send ring while the Windows network stack is not draining it.
const RING_BUFFER_SIZE: u32 = ring_capacity_for_service_gap(RING_SERVICE_GAP);

/// Largest traffic rate in either direction for which we size the ring buffers.
///
/// Matches the rate the UDP socket buffers are sized for: the TUN device carries the same traffic,
/// only decrypted.
const MAX_EXPECTED_TUN_BITS_PER_SECOND: u64 = 10_000_000_000;

/// How long a normally-scheduled TUN worker thread may reasonably go without servicing its ring.
const RING_SERVICE_GAP: Duration = Duration::from_millis(10);

const fn ring_capacity_for_service_gap(service_gap: Duration) -> u32 {
    const BITS_PER_BYTE: u128 = 8;
    const NANOS_PER_SECOND: u128 = 1_000_000_000;

    let bytes = (MAX_EXPECTED_TUN_BITS_PER_SECOND as u128 * service_gap.as_nanos())
        .div_ceil(BITS_PER_BYTE * NANOS_PER_SECOND) as u32;

    bytes.next_power_of_two()
}

const _: () = assert!(RING_BUFFER_SIZE.is_power_of_two());
const _: () = assert!(RING_BUFFER_SIZE >= wintun::MIN_RING_CAPACITY);
const _: () = assert!(RING_BUFFER_SIZE <= wintun::MAX_RING_CAPACITY);

const RING_CAPACITY_ENV_VAR: &str = "FIREZONE_WINTUN_RINGBUFFER_SIZE";

/// Reads the ring buffer capacity that [`RING_CAPACITY_ENV_VAR`] asks for, if any.
///
/// # Errors
///
/// Errors if the variable is set to something Wintun would reject, so the caller can say so instead
/// of failing to start the session.
fn ring_capacity_override() -> Result<Option<u32>> {
    let var = match std::env::var(RING_CAPACITY_ENV_VAR) {
        Ok(var) => var,
        Err(VarError::NotPresent) => return Ok(None),
        Err(e @ VarError::NotUnicode(_)) => return Err(anyhow::Error::new(e)),
    };

    let capacity = parse_ring_capacity(&var)?;

    Ok(Some(capacity))
}

fn parse_ring_capacity(var: &str) -> Result<u32> {
    let capacity = var.parse::<u32>().context("Failed to parse as u32")?;

    anyhow::ensure!(
        capacity.is_power_of_two(),
        "{capacity} is not a power of two"
    );
    anyhow::ensure!(
        capacity >= wintun::MIN_RING_CAPACITY,
        "{capacity} is below the minimum of {}",
        wintun::MIN_RING_CAPACITY
    );
    anyhow::ensure!(
        capacity <= wintun::MAX_RING_CAPACITY,
        "{capacity} is above the maximum of {}",
        wintun::MAX_RING_CAPACITY
    );

    Ok(capacity)
}

/// How many times we at most try to re-write a packet if the WinTUN ring buffer is full.
///
/// This is the WinTUN twin of the `ENOBUFS` (UDP) and `ENOSPC` (TUN on MacOS / iOS) conditions:
/// transient, clears off-thread, and not observable via a readiness signal. Kept in sync with
/// the retry budgets of those paths.
const MAX_RING_FULL_RETRIES: u32 = 24;

/// Upper bound (as a power of two) for how many times we busy-spin between write retries.
///
/// `2^6 = 64` iterations of [`std::hint::spin_loop`] stay well below a microsecond.
const SPIN_LIMIT: u32 = 6;

// Moves packets from Internet towards the user
fn send_worker(
    mut packet_rx: tun::OutboundRx,
    session: Weak<wintun::Session>,
    should_coalesce_tcp: fn() -> bool,
) {
    let batch_size_histogram = otel_instruments::network_packets_batch_count();
    let write_retry_histogram = otel_instruments::network_retries();
    let dropped_packets_counter = otel_instruments::network_packet_dropped();

    let mut tcp_coalescer = packet_coalescer::PacketCoalescer::new(
        [packet_coalescer::Protocol::Tcp],
        packet_coalescer::ChecksumMode::Complete,
    );
    let mut passthrough = packet_coalescer::PacketCoalescer::passthrough();

    while let Some(mut batch) = packet_rx.blocking_recv() {
        let coalesce_tcp = should_coalesce_tcp();
        let coalescer = if coalesce_tcp {
            &mut tcp_coalescer
        } else {
            &mut passthrough
        };

        for packet in batch.drain() {
            #[cfg(debug_assertions)]
            tracing::trace!(target: "wire::dev::send", ?packet);

            coalescer.enqueue(packet);
        }

        'next_packet: for packet in coalescer.drain() {
            let bytes = packet.packet();
            let num_segments = packet.num_segments();

            let Ok(len) = bytes.len().try_into() else {
                tracing::warn!("Packet too large; length does not fit into u16");
                dropped_packets_counter.add(num_segments as u64, &drop_attributes_without_error());
                continue 'next_packet;
            };

            let mut attempt = 0;

            loop {
                let Some(session) = session.upgrade() else {
                    tracing::debug!(
                        "Stopping TUN send worker thread because the `wintun::Session` was dropped"
                    );
                    return;
                };

                match session.allocate_send_packet(len) {
                    Ok(mut pkt) => {
                        pkt.bytes_mut().copy_from_slice(bytes);
                        // `send_packet` cannot fail to enqueue the packet, since we already allocated
                        // space in the ring buffer.
                        session.send_packet(pkt);

                        if num_segments > 1 {
                            batch_size_histogram.record(num_segments as u64, &metric_attributes());
                        }
                        record_write_retries(&write_retry_histogram, attempt);

                        continue 'next_packet;
                    }
                    Err(e) if is_ring_full(&e) && attempt < MAX_RING_FULL_RETRIES => {
                        if attempt == 0 {
                            tracing::trace!("WinTUN ring buffer is full");
                        }

                        spin_and_yield(attempt);

                        attempt += 1;
                    }
                    Err(e) => {
                        record_write_retries(&write_retry_histogram, attempt);
                        dropped_packets_counter.add(num_segments as u64, &drop_attributes(&e));

                        if is_ring_full(&e) {
                            // The ring buffer is still full after all retries; dropping is by design, like for any congested network device.
                            tracing::debug!("Failed to write to WinTUN ring buffer: {e}");
                        } else {
                            tracing::warn!("Failed to allocate WinTUN packet: {e}");
                        }

                        continue 'next_packet;
                    }
                }
            }
        }
    }

    tracing::debug!("Stopping TUN send worker thread because the packet channel closed");
}

/// Whether the write failed because the WinTUN ring buffer is full.
///
/// Dropping in this case is expected back-pressure; any other error is a genuine failure.
fn is_ring_full(e: &wintun::Error) -> bool {
    // See <https://learn.microsoft.com/en-us/windows/win32/debug/system-error-codes--0-499->.
    const ERROR_BUFFER_OVERFLOW: i32 = 0x6F;

    matches!(e, wintun::Error::Io(io) if io.raw_os_error() == Some(ERROR_BUFFER_OVERFLOW))
}

/// Briefly back off after a full ring buffer before trying again.
///
/// We avoid [`std::thread::sleep`]: on Windows the timer resolution rounds sub-millisecond
/// durations up to ~15ms, far longer than the microseconds the ring buffer needs to drain.
/// Instead we busy-spin an escalating number of times and then yield the thread, letting the
/// OS run whichever thread is draining the ring buffer.
fn spin_and_yield(attempt: u32) {
    for _ in 0..(1u32 << attempt.min(SPIN_LIMIT)) {
        std::hint::spin_loop();
    }

    std::thread::yield_now();
}

/// Records how many times a single packet write had to be retried before it went through or was dropped.
///
/// Writes that succeed on the first try (the common case) are not recorded, keeping the hot path cheap.
fn record_write_retries(histogram: &Histogram<u64>, attempt: u32) {
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

/// Attributes for a dropped packet, including the OS error code so ring-full
/// drops can be told apart from other write failures.
fn drop_attributes(e: &wintun::Error) -> [KeyValue; 3] {
    let error_code = if let wintun::Error::Io(io) = e {
        io.raw_os_error().unwrap_or_default() as i64
    } else {
        0
    };

    [
        KeyValue::new("system.device", "tun"),
        KeyValue::new("network.io.direction", "transmit"),
        KeyValue::new("error.code", error_code),
    ]
}

fn drop_attributes_without_error() -> [KeyValue; 3] {
    [
        KeyValue::new("system.device", "tun"),
        KeyValue::new("network.io.direction", "transmit"),
        KeyValue::new("error.code", 0),
    ]
}

fn recv_worker(packet_tx: tun::InboundTx, session: Weak<wintun::Session>) {
    let mut batch = tun::PacketBatch::default();

    'recv: loop {
        let Some(session) = session.upgrade() else {
            tracing::debug!(
                "Stopping TUN recv worker thread because the `wintun::Session` was dropped"
            );
            break;
        };

        // Block for the first packet of a batch.
        let pkt = match session.receive_blocking() {
            Ok(pkt) => pkt,
            Err(wintun::Error::ShuttingDown) => {
                tracing::debug!("Stopping TUN recv worker thread because Wintun is shutting down");
                break;
            }
            Err(e) => {
                tracing::error!("Failed to receive from wintun session: {e}");
                break;
            }
        };

        if let Some(packet) = parse_packet(&pkt)
            && push_or_start_new_batch(&mut batch, packet, &packet_tx).is_err()
        {
            break 'recv;
        }

        // Drain whatever else is already in the ring buffer, so one channel item
        // carries the whole burst.
        loop {
            match session.try_receive() {
                Ok(Some(pkt)) => {
                    if let Some(packet) = parse_packet(&pkt)
                        && push_or_start_new_batch(&mut batch, packet, &packet_tx).is_err()
                    {
                        break 'recv;
                    }
                }
                // Ring buffer is drained; hand off what we have.
                Ok(None) => break,
                // Any genuine error will surface via `receive_blocking` above.
                Err(_) => break,
            }
        }

        if batch.is_empty() {
            continue;
        }

        if packet_tx.blocking_send(std::mem::take(&mut batch)).is_err() {
            tracing::debug!("Stopping TUN recv worker thread because the packet channel closed");
            break 'recv;
        }
    }
}

/// Appends the packet to the batch; if the batch is full, hands it off and starts a
/// new one with the packet.
///
/// Uses `blocking_send` so that if connlib is behind by a few packets, Wintun will
/// queue up new packets in its ring buffer while we wait for our MPSC channel to
/// clear. Unfortunately we don't know if Wintun is dropping packets, since it
/// doesn't expose a sequence number or anything.
///
/// Errors if the channel is closed.
fn push_or_start_new_batch(
    batch: &mut tun::PacketBatch,
    packet: IpPacket,
    packet_tx: &tun::InboundTx,
) -> Result<(), ()> {
    let Err(packet) = batch.try_push(packet) else {
        return Ok(());
    };

    packet_tx
        .blocking_send(std::mem::replace(
            &mut *batch,
            tun::PacketBatch::new(packet),
        ))
        .map_err(|_| {
            tracing::debug!("Stopping TUN recv worker thread because the packet channel closed");
        })
}

fn parse_packet(pkt: &wintun::Packet) -> Option<IpPacket> {
    let mut ip_packet_buf = IpPacketBuf::new();

    let src = pkt.bytes();
    let dst = ip_packet_buf.buf();

    if src.len() > dst.len() {
        tracing::warn!(len = %src.len(), "Received too large packet");
        return None;
    }

    dst[..src.len()].copy_from_slice(src);

    let pkt = match IpPacket::new(ip_packet_buf, src.len()) {
        Ok(pkt) => pkt,
        Err(e) => {
            tracing::debug!("Failed to parse IP packet: {e:#}");
            return None;
        }
    };

    #[cfg(debug_assertions)]
    tracing::trace!(target: "wire::dev::recv", ?pkt);

    Some(pkt)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ring_capacity_tracks_line_rate_and_service_gap() {
        const MIB: u32 = 1024 * 1024;

        assert_eq!(
            ring_capacity_for_service_gap(Duration::from_millis(1)),
            2 * MIB
        );
        assert_eq!(
            ring_capacity_for_service_gap(Duration::from_millis(10)),
            16 * MIB
        );

        assert_eq!(RING_BUFFER_SIZE, 16 * MIB);
    }

    #[test]
    fn ring_capacity_override_must_satisfy_wintun_constraints() {
        assert!(parse_ring_capacity("2097152").is_ok());

        assert!(parse_ring_capacity("banana").is_err());
        assert!(parse_ring_capacity("3145728").is_err()); // Not a power of two.
        assert!(parse_ring_capacity("65536").is_err()); // Below `wintun::MIN_RING_CAPACITY`.
        assert!(parse_ring_capacity("134217728").is_err()); // Above `wintun::MAX_RING_CAPACITY`.
    }
}
