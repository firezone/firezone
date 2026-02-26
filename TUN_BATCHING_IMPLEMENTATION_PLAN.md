# TUN Device Batching Implementation Plan

## Overview

Implement TUN device write batching similar to the existing `GsoQueue` for UDP sockets. This will enable Generic Segmentation Offload (GSO) / TCP Segmentation Offload (TSO) on the TUN write path for Linux, improving performance by reducing syscalls and leveraging kernel offloads.

## Background

### Current State
- **Read path**: Already implements GSO/TSO parsing in `linux.rs` (`parse_vnet_packet`, `segment_packet`)
- **Write path**: Sends packets one at a time via `tun_send` function
- **GsoQueue**: Exists for UDP sockets, batches packets by connection and segment size

### Target
- Implement batching on TUN write path for Linux only
- Support GSO/TSO on Linux TUN devices
- Maintain single-packet behavior on non-Linux platforms (no batching overhead)
- Follow the same pattern as `GsoQueue` for UDP datagrams
- Use platform-specific APIs to ensure compile-time guarantees

## Key Learnings from Tailscale's Implementation

After reviewing Tailscale's wireguard-go TUN implementation:

1. **Flow-based batching**: Packets are grouped by TCP/IP flow using a `flowKey`:
   - Source and destination IP addresses (16 bytes each for IPv4/IPv6)
   - Source and destination ports
   - TCP ACK number (for TCP flows)

2. **Coalescing logic**: Packets can be coalesced if:
   - They belong to the same flow
   - TCP sequence numbers are adjacent
   - Payload sizes are compatible (larger packet can't follow smaller)
   - TCP flags are compatible (PSH only on final segment)
   - IP header fields match (TTL, ToS, etc.)

3. **virtio_net_hdr on write**: When writing batched packets:
   - Set `flags = VIRTIO_NET_HDR_F_NEEDS_CSUM`
   - Set `gsoType` based on protocol (TCPV4/TCPV6)
   - Set `hdrLen` = IP header + TCP header length
   - Set `gsoSize` = size of each segment
   - Set `csumStart` = offset to TCP header
   - Set `csumOffset` = 16 for TCP, 6 for UDP

4. **Platform differences**: Only Linux supports GSO on TUN devices.

## Implementation Steps

### Step 0: Rename `GsoQueue` to `UdpGsoQueue`
**File**: `rust/libs/connlib/tunnel/src/io/gso_queue.rs`

Rename the struct and update all references:
- `GsoQueue` → `UdpGsoQueue`
- Update `io.rs` struct field: `gso_queue: UdpGsoQueue`
- Update all method calls

This clarifies the purpose and makes room for `TunGsoQueue`.

### Step 1: Create `IpPacketOut` Type
**File**: `rust/libs/connlib/tun/src/lib.rs`

Create a single type that works on all platforms:

```rust
use bufferpool::Buffer;
use bytes::BytesMut;

/// Represents one or more IP packets to be sent to a TUN device.
/// On Linux, this can represent a batch of packets (segment_size > 0).
/// On other platforms, only single packets are used (segment_size = 0).
pub struct IpPacketOut {
    /// Buffer containing one or more IP packet payloads
    pub packet: Buffer<BytesMut>,
    /// Size of each segment in the buffer. 0 means single packet (no GSO).
    pub segment_size: usize,
}
```

**Rationale**: Single type works everywhere. Non-Linux code paths always create with `segment_size: 0`.

### Step 2: Create TUN GSO Queue
**File**: `rust/libs/connlib/tunnel/src/io/tun_gso_queue.rs` (new file)

Implement `TunGsoQueue` similar to `UdpGsoQueue`:

```rust
use std::collections::{BTreeMap, VecDeque};
use bufferpool::{Buffer, BufferPool};
use bytes::BytesMut;
use ip_packet::IpPacket;

use super::MAX_INBOUND_PACKET_BATCH;

const MAX_SEGMENT_SIZE: usize = ip_packet::MAX_IP_SIZE;

/// Key for grouping packets that can be coalesced via GSO
#[derive(Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Clone, Copy)]
struct FlowKey {
    src_addr: [u8; 16],    // Source IP (IPv4 mapped to IPv6 format)
    dst_addr: [u8; 16],    // Destination IP (IPv4 mapped to IPv6 format)
    src_port: u16,         // Source port (0 for non-TCP/UDP)
    dst_port: u16,         // Destination port (0 for non-TCP/UDP)
    protocol: u8,          // IP protocol number (6=TCP, 17=UDP)
}

/// Holds IP packets that need to be sent, indexed by flow and segment size.
/// On Linux, packets are batched by flow for GSO. On other platforms, this
/// queue exists but is not used.
pub struct TunGsoQueue {
    inner: BTreeMap<FlowKey, VecDeque<(usize, Buffer<BytesMut>)>>,
    buffer_pool: BufferPool<BytesMut>,
}

impl TunGsoQueue {
    pub fn new() -> Self {
        Self {
            inner: Default::default(),
            buffer_pool: BufferPool::new(
                MAX_SEGMENT_SIZE * MAX_INBOUND_PACKET_BATCH,
                "tun-gso-queue"
            ),
        }
    }

    pub fn enqueue(&mut self, packet: IpPacket) {
        // Parse packet to extract flow key
        let key = match extract_flow_key(&packet) {
            Some(k) => k,
            None => {
                tracing::debug!("Failed to extract flow key, skipping packet");
                return;
            }
        };

        let payload_len = packet.len();
        let packet_bytes = packet.packet(); // Use packet() to get buffer

        // Get or create batch for this flow
        let batches = self.inner.entry(key).or_default();

        // Check if we can append to existing batch
        let Some((batch_size, buffer)) = batches.back_mut() else {
            // No existing batch, create new one
            batches.push_back((payload_len, self.buffer_pool.pull_initialised(packet_bytes)));
            return;
        };

        let batch_size = *batch_size;
        let batch_is_ongoing = buffer.len() % batch_size == 0;

        // Can only batch packets of same size
        if batch_is_ongoing && payload_len <= batch_size {
            buffer.extend_from_slice(packet_bytes);
            return;
        }

        // Different size, start new batch
        batches.push_back((payload_len, self.buffer_pool.pull_initialised(packet_bytes)));
    }

    pub fn packets(&mut self) -> impl Iterator<Item = IpPacketOut> + '_ {
        DrainPacketsIter { queue: self }
    }

    pub fn clear(&mut self) {
        self.inner.clear()
    }
}

/// Extract flow key from IP packet for batching
fn extract_flow_key(packet: &IpPacket) -> Option<FlowKey> {
    // IpPacket provides getters for all fields we need
    let src_addr = packet.source();
    let dst_addr = packet.destination();
    let protocol = packet.protocol();
    
    // Map IPv4 addresses to IPv6 format for unified key
    let mut src_bytes = [0u8; 16];
    let mut dst_bytes = [0u8; 16];
    
    match (src_addr, dst_addr) {
        (IpAddr::V4(src), IpAddr::V4(dst)) => {
            // IPv4-mapped IPv6 address: ::ffff:x.x.x.x
            src_bytes[10] = 0xff;
            src_bytes[11] = 0xff;
            src_bytes[12..16].copy_from_slice(&src.octets());
            dst_bytes[10] = 0xff;
            dst_bytes[11] = 0xff;
            dst_bytes[12..16].copy_from_slice(&dst.octets());
        }
        (IpAddr::V6(src), IpAddr::V6(dst)) => {
            src_bytes.copy_from_slice(&src.octets());
            dst_bytes.copy_from_slice(&dst.octets());
        }
        _ => return None, // Mixed v4/v6 shouldn't happen
    }
    
    // Extract ports for TCP/UDP
    let (src_port, dst_port) = match protocol {
        6 | 17 => {  // TCP or UDP
            // Use IpPacket getters to extract port information
            let src_port = packet.source_port()?;
            let dst_port = packet.destination_port()?;
            (src_port, dst_port)
        }
        _ => (0, 0),  // Other protocols don't have ports
    };
    
    Some(FlowKey {
        src_addr: src_bytes,
        dst_addr: dst_bytes,
        src_port,
        dst_port,
        protocol,
    })
}

struct DrainPacketsIter<'a> {
    queue: &'a mut TunGsoQueue,
}

impl Iterator for DrainPacketsIter<'_> {
    type Item = IpPacketOut;

    fn next(&mut self) -> Option<Self::Item> {
        loop {
            let mut entry = self.queue.inner.first_entry()?;
            let Some((segment_size, buffer)) = entry.get_mut().pop_front() else {
                entry.remove();
                continue;
            };

            return Some(IpPacketOut {
                packet: buffer,
                segment_size,
            });
        }
    }
}
```

**Key Points**:
- Compiles on all platforms but only used on Linux
- `FlowKey` based on Tailscale's approach
- Similar batching logic to `UdpGsoQueue`

### Step 3: Update `Tun` Trait with Platform-Specific `send()`
**File**: `rust/libs/connlib/tun/src/lib.rs`

Make the `send()` method different per platform:

```rust
pub trait Tun: Send + Sync + 'static {
    /// Check if more packets can be sent.
    fn poll_send_ready(&mut self, cx: &mut Context) -> Poll<io::Result<()>>;
    
    #[cfg(target_os = "linux")]
    /// Send a packet or batch (Linux only).
    fn send(&mut self, packet: IpPacketOut) -> io::Result<()>;
    
    #[cfg(not(target_os = "linux"))]
    /// Send a single packet (non-Linux platforms).
    fn send(&mut self, packet: IpPacket) -> io::Result<()>;

    /// Receive a batch of packets up to `max`.
    fn poll_recv_many(
        &mut self,
        cx: &mut Context,
        buf: &mut Vec<IpPacket>,
        max: usize,
    ) -> Poll<usize>;

    /// The name of the TUN device.
    fn name(&self) -> &str;
}
```

**Note**: The signature is different per platform - Linux takes `IpPacketOut`, others take `IpPacket`.

### Step 4: Implement Linux TUN Batching with `writev`
**File**: `rust/libs/connlib/tun/src/linux.rs`

Update `tun_send` to handle `IpPacketOut` using `writev` for efficiency:

```rust
use libc::writev;
use std::io::IoSlice;

pub fn tun_send<T>(
    fd: T,
    mut outbound_rx: mpsc::Receiver<IpPacketOut>,
    write: impl Fn(i32, &[u8]) -> std::result::Result<usize, io::Error>,
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

            while let Some(packet_out) = outbound_rx.recv().await {
                if let Err(e) = fd
                    .async_io(tokio::io::Interest::WRITABLE, |fd| {
                        write_packet_out(fd.as_raw_fd(), &packet_out)
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

fn write_packet_out(fd: i32, packet_out: &IpPacketOut) -> io::Result<usize> {
    // Build vnet header
    let vnet_hdr = if packet_out.segment_size == 0 {
        // Single packet - empty vnet header
        VirtioNetHdr::default()
    } else {
        // Batched packet - build GSO vnet header
        build_gso_vnet_hdr(&packet_out.packet, packet_out.segment_size)?
    };

    // Encode header
    let mut hdr_buf = [0u8; VIRTIO_NET_HDR_SIZE];
    encode_vnet_hdr(&vnet_hdr, &mut hdr_buf);

    // Use writev to avoid copying
    let iov = [
        IoSlice::new(&hdr_buf),
        IoSlice::new(&packet_out.packet),
    ];

    // SAFETY: fd is valid, iov is valid for the duration of the call
    let result = unsafe {
        writev(fd, iov.as_ptr() as *const libc::iovec, iov.len() as i32)
    };

    if result < 0 {
        Err(io::Error::last_os_error())
    } else {
        let written = result as usize;
        let expected = hdr_buf.len() + packet_out.packet.len();
        if written != expected {
            tracing::warn!("Partial write to TUN: wrote {}, expected {}", written, expected);
        }
        Ok(written)
    }
}

fn build_gso_vnet_hdr(packet_data: &[u8], segment_size: usize) -> io::Result<VirtioNetHdr> {
    if packet_data.is_empty() {
        return Err(io::Error::new(io::ErrorKind::InvalidInput, "Empty packet"));
    }

    // Parse IP version
    let ip_version = packet_data[0] >> 4;
    
    // TODO: Parse packet to determine:
    // - Protocol (TCP vs UDP)
    // - IP header length
    // - TCP/UDP header length
    // - Set appropriate gso_type, hdr_len, csum_start, csum_offset
    
    // Placeholder implementation
    let (ip_hdr_len, protocol) = if ip_version == 4 {
        let ihl = (packet_data[0] & 0x0F) as usize * 4;
        let proto = packet_data[9];
        (ihl, proto)
    } else if ip_version == 6 {
        (40, packet_data[6])
    } else {
        return Err(io::Error::new(io::ErrorKind::InvalidInput, "Invalid IP version"));
    };

    let gso_type = match (ip_version, protocol) {
        (4, 6) => VIRTIO_NET_HDR_GSO_TCPV4,   // IPv4 TCP
        (6, 6) => VIRTIO_NET_HDR_GSO_TCPV6,   // IPv6 TCP
        (4, 17) | (6, 17) => VIRTIO_NET_HDR_GSO_UDP_L4,  // IPv4/IPv6 UDP
        _ => return Err(io::Error::new(io::ErrorKind::InvalidInput, "Unsupported protocol for GSO")),
    };

    // For TCP: get TCP header length
    let tcp_hdr_len = if protocol == 6 && packet_data.len() > ip_hdr_len + 12 {
        ((packet_data[ip_hdr_len + 12] >> 4) as usize) * 4
    } else {
        20  // Minimum TCP header
    };

    let hdr_len = ip_hdr_len + tcp_hdr_len;
    
    // Checksum offset within L4 header: TCP=16, UDP=6
    let csum_offset = if protocol == 6 { 16 } else { 6 };

    Ok(VirtioNetHdr {
        flags: VIRTIO_NET_HDR_F_NEEDS_CSUM,
        gso_type,
        hdr_len: hdr_len as u16,
        gso_size: segment_size as u16,
        csum_start: ip_hdr_len as u16,
        csum_offset,
        num_buffers: 0,
    })
}

fn encode_vnet_hdr(hdr: &VirtioNetHdr, buf: &mut [u8]) {
    buf[0] = hdr.flags;
    buf[1] = hdr.gso_type;
    buf[2..4].copy_from_slice(&hdr.hdr_len.to_le_bytes());
    buf[4..6].copy_from_slice(&hdr.gso_size.to_le_bytes());
    buf[6..8].copy_from_slice(&hdr.csum_start.to_le_bytes());
    buf[8..10].copy_from_slice(&hdr.csum_offset.to_le_bytes());
    buf[10..12].copy_from_slice(&hdr.num_buffers.to_le_bytes());
}

const VIRTIO_NET_HDR_F_NEEDS_CSUM: u8 = 0x01;
const VIRTIO_NET_HDR_GSO_TCPV4: u8 = 1;
const VIRTIO_NET_HDR_GSO_TCPV6: u8 = 4;
const VIRTIO_NET_HDR_GSO_UDP_L4: u8 = 5;
```

### Step 5: Implement Non-Linux Platforms
**Files**: Platform-specific TUN implementations

For non-Linux platforms, `send()` still takes `IpPacket` (no change to signature):

```rust
#[cfg(not(target_os = "linux"))]
impl Tun for SomePlatformTun {
    fn send(&mut self, packet: IpPacket) -> io::Result<()> {
        // Existing implementation unchanged
        send_single_packet(packet)
    }
    
    // ... other methods
}
```

**Note**: Non-Linux implementations require no changes since the trait signature for them stays the same.

### Step 6: Update `Io` in `tunnel/src/io.rs`
**File**: `rust/libs/connlib/tunnel/src/io.rs`

1. Add conditional `TunGsoQueue` field:
```rust
pub struct Io {
    // ... existing fields
    gso_queue: UdpGsoQueue,       // Renamed from GsoQueue
    
    #[cfg(target_os = "linux")]
    tun_gso_queue: TunGsoQueue,   // Only on Linux
    // ... rest
}
```

2. Update `send_tun()` method with conditional compilation:
```rust
pub fn send_tun(&mut self, packet: IpPacket) {
    #[cfg(target_os = "linux")]
    {
        // On Linux: enqueue for batching
        self.tun_gso_queue.enqueue(packet);
    }
    #[cfg(not(target_os = "linux"))]
    {
        // On other platforms: send directly (existing behavior)
        if let Some(tun) = &mut self.tun {
            if let Err(e) = tun.send(packet) {
                tracing::warn!("Failed to send to TUN: {}", e);
                self.inc_dropped_packet();
            }
        }
    }
}
```

3. Update `flush()` method:
```rust
pub fn flush(&mut self) {
    // ... existing UDP flush code ...
    
    // Flush TUN packets (Linux only)
    #[cfg(target_os = "linux")]
    {
        for packet_out in self.tun_gso_queue.packets() {
            if let Some(tun) = &mut self.tun {
                if let Err(e) = tun.send(packet_out) {
                    tracing::warn!("Failed to send to TUN: {}", e);
                    self.inc_dropped_packet();
                }
            }
        }
    }
}
```

4. Update `reset()`:
```rust
pub fn reset(&mut self) {
    self.gso_queue.clear();
    #[cfg(target_os = "linux")]
    self.tun_gso_queue.clear();
    // ... rest
}
```

**Key Point**: Non-Linux behavior stays exactly the same - packets are sent directly in `send_tun()`.

## Incremental Implementation Order

1. **Phase 1**: Rename existing queue
   - Rename `GsoQueue` → `UdpGsoQueue`
   - Update all references in `io.rs`
   - Ensure everything still compiles

2. **Phase 2**: Create types (no behavior change)
   - Add `IpPacketOut` type to `tun/src/lib.rs`
   - Create `tun_gso_queue.rs` module
   - Implement basic structure (stub `extract_flow_key` returns None)
   - Add field to `Io` struct with `#[cfg(target_os = "linux")]`

3. **Phase 3**: Update Tun trait
   - Add conditional `send()` signatures to trait
   - Update Linux implementation to accept `IpPacketOut`
   - Verify non-Linux implementations still compile (unchanged signatures)

4. **Phase 4**: Wire up Linux batching path
   - Route `send_tun()` through `TunGsoQueue` on Linux
   - Update `flush()` to drain queue on Linux
   - Update `reset()` to clear queue on Linux
   - At this point batching infrastructure exists but doesn't actually batch (returns None from extract_flow_key)

5. **Phase 5**: Implement flow key extraction
   - Implement `extract_flow_key()` using IpPacket getters
   - Use `source()`, `destination()`, `protocol()` getters
   - Use `source_port()`, `destination_port()` for TCP/UDP
   - Map IPv4 addresses to IPv6 format for unified key

6. **Phase 6**: Implement GSO vnet header construction
   - Implement `build_gso_vnet_hdr()` fully
   - Parse packets to determine header lengths
   - Set appropriate `gso_type` based on protocol (TCPV4/TCPV6/UDP_L4)
   - Set correct `csum_offset`: 16 for TCP, 6 for UDP
   - Test batched packets are written correctly for both TCP and UDP

7. **Phase 7**: Optimize with writev
   - Replace write with writev to avoid buffer copies
   - Verify performance improvement

## Open Questions & Design Decisions

1. **TCP ACK in flow key**: Should we include TCP ACK number like Tailscale?
   - **Recommendation**: Start without it, add later if needed

2. **Buffer pool sizing**: Use same as UDP GSO queue?
   - **Recommendation**: Yes, `MAX_SEGMENT_SIZE * MAX_INBOUND_PACKET_BATCH`

3. **Max batch size**: Should we limit batches?
   - **Recommendation**: Use same `MAX_INBOUND_PACKET_BATCH` as UDP

4. **IpPacket API**: Use `packet()` method to get buffer from `IpPacket`.

5. **Error handling**: `IpPacket` is always valid - can access all details via getters.

6. **UDP batching**: Yes, batch both TCP and UDP packets.

7. **Partial writes**: Log warning with tracing and continue (kernel may accept partial data).

## Performance Considerations

- **Pros**: 
  - Reduced syscalls on Linux (major benefit for TCP flows)
  - Kernel can optimize GSO packets better
  - `writev` avoids buffer copies
  - No overhead on non-Linux platforms (different code paths)
  
- **Cons**:
  - More complex code on Linux path
  - Additional memory for batching buffer (Linux only)
  - Slight latency increase from batching

- **Mitigation**: 
  - Follow same flush pattern as UDP (flush on every poll cycle)
  - Use conditional compilation to avoid overhead on non-Linux
  - Platform-specific APIs provide compile-time guarantees

## References

- Cloudflare blog: https://blog.cloudflare.com/virtual-networking-101-understanding-tap/
- Tailscale wireguard-go implementation: https://github.com/tailscale/wireguard-go
  - `tun/tun_linux.go` - Main TUN device implementation
  - `tun/tcp_offload_linux.go` - GSO/GRO implementation with flow-based batching
- Existing `UdpGsoQueue` implementation: `rust/libs/connlib/tunnel/src/io/gso_queue.rs`
- Linux vnet header parsing: `rust/libs/connlib/tun/src/linux.rs`
- `DatagramOut` definition: `rust/libs/connlib/socket-factory/src/lib.rs`
- virtio_net_hdr spec: https://docs.oasis-open.org/virtio/virtio/v1.1/csprd01/virtio-v1.1-csprd01.html