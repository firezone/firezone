use crate::DatagramSegmentIter;
use bufferpool::Buffer;
use std::mem::size_of;
use std::time::Duration;

/// Kernel queue for a UDP socket's controlled egress.
///
/// Unlike the receive buffer, this does not need to bridge scheduler stalls: our bounded userspace
/// send channel applies backpressure while the send task is not running. It only needs to fit one
/// complete GSO / USO send and enough data to keep the interface busy while send completions are
/// processed. At 10 Gbit/s, the 1 ms queue window is 1.25 MB and rounds up to 2 MiB.
///
/// On Apple platforms UDP datagrams are handed straight to the interface and `SO_SNDBUF` primarily
/// caps the maximum datagram size, so 64 KiB is sufficient for one complete send.
pub const SEND_BUFFER_SIZE: usize = cfg_select! {
    apple => { MAX_ATOMIC_UDP_SEND_BYTES.next_power_of_two() }
    _ => { send_buffer_size_for_queue_window(SEND_QUEUE_WINDOW) }
};

/// Kernel backlog for a UDP socket, sized by ingress rate and receive-service gap.
///
/// This is deliberately independent of the capacity of one receive syscall: `SO_RCVBUF` bridges
/// scheduler and application stalls, while GRO / `recvmsg_x` batching determines how quickly the
/// receive thread can drain that backlog once it runs. At 10 Gbit/s, one 10 ms service-gap window is
/// 12.5 MB, which rounds up to 16 MiB. Apple and Windows reserve two windows (32 MiB) because their
/// uncoalesced receive batches and userspace receive queues carry much less traffic than a
/// GRO-enabled batch.
pub const RECV_BUFFER_SIZE: usize = recv_buffer_size_for_service_gap(
    RECV_SERVICE_GAP.saturating_mul(RECV_SERVICE_GAP_WINDOWS as u32),
);

/// Worst-case heap that a single received batch ([`DatagramSegmentIter`]) pins.
///
/// A batch owns [`quinn_udp::BATCH_SIZE`] receive buffers plus their handles and metadata. Each buffer
/// is sized to hold a full coalesced batch - up to `MAX_RECV_BUFFER_SEGMENTS` datagrams of at most
/// [`ip_packet::MAX_FZ_PAYLOAD`] bytes - so on Linux / Android and Windows a single buffer is 64x the
/// size of the datagram it might actually carry. That factor dominates this figure even on Windows,
/// where Quinn currently leaves URO disabled but allocates URO-capable buffers.
pub const MAX_RECV_BATCH_MEMORY: usize = size_of::<DatagramSegmentIter>()
    + quinn_udp::BATCH_SIZE
        * (ip_packet::MAX_FZ_PAYLOAD * MAX_RECV_BUFFER_SEGMENTS
            + size_of::<Buffer<Vec<u8>>>()
            + size_of::<quinn_udp::RecvMeta>());

/// Largest traffic rate in either direction for which we size the UDP socket buffers.
const MAX_EXPECTED_UDP_BITS_PER_SECOND: u64 = 10_000_000_000;
/// Largest payload handed to the kernel by one GSO / USO send.
const MAX_ATOMIC_UDP_SEND_BYTES: usize = u16::MAX as usize;
/// Time worth of controlled egress that may be queued in the kernel.
const SEND_QUEUE_WINDOW: Duration = Duration::from_millis(1);
/// How long a normally-scheduled receive thread may reasonably go without servicing its socket.
const RECV_SERVICE_GAP: Duration = Duration::from_millis(10);
/// Apple has no UDP GRO, and Quinn leaves Windows URO disabled because some Windows systems omit the
/// coalesced-segment metadata. Their userspace receive queues therefore drain much less traffic at
/// once than Linux / Android GRO. Keep a second service-gap window in the kernel so they can catch up.
const RECV_SERVICE_GAP_WINDOWS: u64 = cfg_select! {
    any(apple, target_os = "windows") => { 2 }
    _ => { 1 }
};

/// A compile-time upper bound on the runtime `gro_segments()`: the largest number of datagrams for
/// which Quinn sizes a single receive buffer.
///
/// Linux / Android enable `UDP_GRO` (up to `UDP_GRO_CNT_MAX` = 64). Quinn leaves Windows URO disabled
/// due to unreliable `UDP_COALESCED_INFO`, but still reports 64 from `gro_segments()` and allocates
/// buffers large enough to enable it. Runtime `gro_segments()` never exceeds this bound.
const MAX_RECV_BUFFER_SEGMENTS: usize = cfg_select! {
    any(target_os = "linux", target_os = "android", target_os = "windows") => { 64 }
    _ => { 1 }
};

const fn recv_buffer_size_for_service_gap(service_gap: Duration) -> usize {
    buffer_size_for_line_rate(service_gap, 0)
}

const fn send_buffer_size_for_queue_window(queue_window: Duration) -> usize {
    buffer_size_for_line_rate(queue_window, MAX_ATOMIC_UDP_SEND_BYTES)
}

const fn buffer_size_for_line_rate(duration: Duration, minimum_bytes: usize) -> usize {
    const BITS_PER_BYTE: u128 = 8;
    const NANOS_PER_SECOND: u128 = 1_000_000_000;

    let bytes = (MAX_EXPECTED_UDP_BITS_PER_SECOND as u128 * duration.as_nanos())
        .div_ceil(BITS_PER_BYTE * NANOS_PER_SECOND) as usize;
    let bytes = if bytes < minimum_bytes {
        minimum_bytes
    } else {
        bytes
    };

    bytes.next_power_of_two()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn socket_buffer_sizes_track_line_rate_and_queue_time() {
        const MIB: usize = 1024 * 1024;

        assert_eq!(
            send_buffer_size_for_queue_window(Duration::from_millis(1)),
            2 * MIB
        );
        assert_eq!(
            recv_buffer_size_for_service_gap(Duration::from_millis(10)),
            16 * MIB
        );
        assert_eq!(
            recv_buffer_size_for_service_gap(Duration::from_millis(20)),
            32 * MIB
        );

        let expected_send_buffer_size = cfg_select! {
            apple => { 64 * 1024 }
            _ => { 2 * MIB }
        };
        let expected_recv_buffer_size = cfg_select! {
            any(apple, target_os = "windows") => { 32 * MIB }
            _ => { 16 * MIB }
        };
        let expected_recv_buffer_segments = cfg_select! {
            any(target_os = "linux", target_os = "android", target_os = "windows") => { 64 }
            _ => { 1 }
        };

        assert_eq!(SEND_BUFFER_SIZE, expected_send_buffer_size);
        assert_eq!(RECV_BUFFER_SIZE, expected_recv_buffer_size);
        assert_eq!(MAX_RECV_BUFFER_SEGMENTS, expected_recv_buffer_segments);
    }
}
