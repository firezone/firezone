# Design: batched TUN I/O on Apple platforms via `recvmsg_x` / `sendmsg_x`

| | |
|---|---|
| Status | Draft |
| Scope | `client-ffi` (Apple platform module); the shared `tun` crate is unchanged |
| Related | firezone/firezone#13667 (`UTUN_OPT_MAX_PENDING_PACKETS`), quinn-udp `fast-apple-datapath` (already shipped) |

All kernel references are to [`xnu-12377.1.9`](https://github.com/apple-oss-distributions/xnu/tree/xnu-12377.1.9) (current macOS line; iOS shares the same code).

## Problem

On Apple platforms, we perform **one syscall per packet** in each direction on the utun file descriptor (`client-ffi/src/platform/apple/tun.rs`: `read` via `recvmsg`, `write` via `sendmsg`). Every other hop in the data path is already batched:

- UDP sockets: quinn-udp with `fast-apple-datapath` (`sendmsg_x`/`recvmsg_x`, batch 32).
- TUN-to-eventloop channel: `poll_recv_many` with `MAX_INBOUND_PACKET_BATCH` (100 desktop / 25 mobile).
- Eventloop-to-UDP channel: `recv_many` with `UDP_SEND_BATCH_LIMIT` (16).

The TUN fd is the remaining unbatched hop. At ~1 Gbit/s with 1280-byte packets this is ~100k syscalls/s per direction, plus the kernel-side per-read flow-control work described below.

## Kernel facts we build on

The utun fd handed to us by the NetworkExtension is a connected `SOCK_DGRAM` kernel-control socket. XNU implements batched syscalls for exactly this kind of socket:

### Reads: `recvmsg_x` is a true kernel-side batch

`recvmsg_x` (`bsd/kern/uipc_syscalls.c:2656`) calls `soreceive_m_list` (`bsd/kern/uipc_socket.c:3960`), which dequeues up to `cnt` packet records under one socket-lock acquisition and fires `pru_rcvd` **once per batch** (`uipc_socket.c:4244`) instead of once per packet. For utun, `pru_rcvd` is `utun_ctl_rcvd` (`bsd/net/if_utun.c:2804`), which takes the ifnet lock, walks the receive buffer to count records, and re-enables interface output — meaning batching reduces not just syscalls but the per-packet flow-control churn between the ifnet start thread and our reader.

Read batches only materialize if the kernel is allowed to queue more than one packet for us: `utun_max_pending_packets` defaults to **1** and is raised to 128 by #13667. This design depends on that change.

### Writes: `sendmsg_x` amortizes the syscall

`sendmsg_x` (`uipc_syscalls.c:1870`) takes its fast path for sockets that are `SOCK_DGRAM` + `PR_ATOMIC` + connected — all true for kernel-control sockets (`bsd/kern/kern_control.c:191`). It internalizes all datagrams into one mbuf packet list and hands it to `pru_send_list = ctl_send_list` (`kern_control.c:181`). utun registers no `send_list` callback, so `ctl_send_list` loops over `utun_ctl_send` per packet (`kern_control.c:886-901`) — kernel-side per-packet costs (`ifnet_input` per packet) remain, but N-1 syscalls disappear. The win is therefore smaller than on the read side, but it is the same plumbing and nearly free to add once `msghdr_x` support exists.

### Syscall contract (from `bsd/sys/socket_private.h:773-835`)

```c
struct msghdr_x {
    void            *msg_name;       /* must be NULL (send) */
    socklen_t        msg_namelen;    /* must be 0 (send) */
    struct iovec    *msg_iov;        /* scatter/gather array */
    int              msg_iovlen;     /* # elements in msg_iov */
    void            *msg_control;    /* must be NULL (send) */
    socklen_t        msg_controllen; /* must be 0 (send) */
    int              msg_flags;      /* must be 0 on input; out: may contain MSG_TRUNC (recv) */
    size_t           msg_datalen;    /* must be 0 on input (send); out: datagram length (recv) */
};

ssize_t recvmsg_x(int s, const struct msghdr_x *msgp, u_int cnt, int flags);
ssize_t sendmsg_x(int s, const struct msghdr_x *msgp, u_int cnt, int flags);
```

Semantics we rely on:

- Both return the **number of datagrams** processed, or -1 with `errno` (`EWOULDBLOCK` on a non-blocking fd with nothing to do). `flags` supports only `MSG_DONTWAIT`; we pass 0 and rely on `O_NONBLOCK` (already set on the fd).
- `recvmsg_x` may return fewer than `cnt` datagrams. `msg_datalen` is set per message to the record length, which for utun **includes the 4-byte AF header** (same as `recvmsg` today). `MSG_TRUNC` is set per message if a buffer was too small, and the call "returns as soon as a datagram is truncated".
- `sendmsg_x` can succeed partially: after ≥ 1 datagram is sent, `EWOULDBLOCK`/`ENOBUFS`/`EMSGSIZE` are suppressed and the count is returned (`uipc_syscalls.c:1946-1951`). Callers must resubmit the tail.
- Batch sizes are clamped by `kern.ipc.somaxrecvmsgx` / `kern.ipc.somaxsendmsgx` (default 256, `uipc_syscalls.c:189-195`). Per-datagram size is bounded by `so_snd.sb_hiwat` (512 KiB for utun) — irrelevant at our MTU.
- The header marks both as **private system calls** ("API is subject to change"). Mitigation: resolve symbols at runtime and keep the existing per-packet path as fallback. We already accept this risk class via quinn-udp's `fast-apple-datapath`.
- Sysctls can alter the kernel path (`kern.ipc.sendmsg_x_mode=1` forces a kernel-internal sendit loop; `kern.ipc.do_recvmsg_x_donttrunc=1` forces the per-message receive path). Both remain semantically compatible — still one syscall per batch.

## Goals / non-goals

Goals:

1. ~1 syscall per *batch* instead of per packet on the utun fd, both directions.
2. Bit-identical packet handling (AF-header split, parse policy, backpressure) to today.
3. Automatic fallback to the current path when the syscalls are unavailable.

Non-goals:

- Linux/Android batching. Those fds are character devices — socket batch syscalls don't apply; Linux batching means vnet_hdr/GSO and deserves its own design. The change is additive and Apple-only; `tun_send`/`tun_recv` are untouched and remain in use for these platforms and as the Apple fallback.
- Buffer-pool changes. `IpPacketBuf` is already pool-backed (`ip-packet/src/lib.rs:103-123`); batching pulls N buffers per batch, the same per-packet cost as today.
- Skywalk channel mode (`UTUN_OPT_ENABLE_CHANNEL`): requires the Apple-private `PRIV_SKYWALK_REGISTER_KERNEL_PIPE` entitlement (`if_utun.c:1546`). Unreachable for third parties; documented here so nobody re-litigates it.
- Moving TUN I/O onto the main event loop.

## Design

### 1. Batched loops live in `client-ffi/src/platform/apple/`

The batched path is Apple-only, so it lives **entirely in the Apple platform module** — there is no new public API in the `tun` crate. An earlier draft put `tun_send_batched`/`tun_recv_batched` in `tun/src/unix.rs` behind `write_many`/`read_many` closures, to keep orchestration (runtime, `AsyncFd`, channel, parsing) in the shared crate and the syscalls in the platform crate. With a single consumer that split buys nothing and costs a crate boundary plus `impl Fn` indirection, so we drop it: two module-private functions own the whole pipeline and call the syscalls directly. `tun/src/unix.rs` is otherwise untouched — its `tun_send`/`tun_recv` stay in use by Linux and Android and serve as the Apple fallback.

The fd is a `RawFd` (`Copy`), so unlike the shared helpers these need no `T: AsRawFd + Clone` generic. Per-packet parsing and the `Fragmented` log policy are inlined here rather than shared, since this is now the only batched consumer (the small duplication against `tun_recv` is the price of not adding to the `tun` crate).

Send loop (module-private `tun_send_batched(fd: RawFd, outbound_rx)`; per-thread current-thread runtime + `AsyncFd`, as today):

```rust
let mut batch = Vec::with_capacity(BATCH_SIZE);
loop {
    if outbound_rx.recv_many(&mut batch, BATCH_SIZE).await == 0 {
        break; // Channel closed.
    }
    let mut offset = 0;
    while offset < batch.len() {
        match fd.async_io(Interest::WRITABLE, |fd| {
            // `send_batch` (same module) builds the `msghdr_x` array for
            // `batch[offset..]` and calls `sys::sendmsg_x`, returning the count.
            match send_batch(fd.as_raw_fd(), &batch[offset..]) {
                Ok(0) => Err(io::ErrorKind::WouldBlock.into()), // Defensive: avoid a busy-loop.
                other => other,
            }
        }).await {
            Ok(n) => offset += n, // Partial send: resubmit the tail.
            Err(e) => {
                tracing::warn!(dropped = batch.len() - offset, "Failed to write to TUN FD: {e}");
                break;
            }
        }
    }
    batch.clear();
}
```

Error policy matches today's `tun_send`: a hard error is logged and the affected packets are dropped (today: 1 packet, here: the remaining tail). Per the XNU analysis, utun's legacy write path reports no per-packet errors (`utun_pkt_input` swallows `ifnet_input` failures), so hard errors here are exceptional.

Receive loop:

```rust
loop {
    let mut bufs: Vec<IpPacketBuf> = (0..BATCH_SIZE).map(|_| IpPacketBuf::new()).collect();
    let mut lens = vec![0usize; BATCH_SIZE];

    let n = fd.async_io(Interest::READABLE, |fd| {
        // `recv_batch` (same module) builds the `msghdr_x` array over `bufs`,
        // calls `sys::recvmsg_x`, and writes each `msg_datalen - 4` into `lens`.
        recv_batch(fd.as_raw_fd(), &mut bufs, &mut lens)
    }).await.context("Failed to read from TUN FD")?;

    let Ok(permits) = inbound_tx.reserve_many(n).await else {
        break; // Receiver gone, shut down.
    };

    for (permit, (buf, len)) in permits.zip(bufs.drain(..).zip(lens).take(n)) {
        match IpPacket::new(buf, len) {
            Ok(packet) => permit.send(packet),
            Err(e) if e.is::<ip_packet::Fragmented>() => tracing::debug!("{e:#}"),
            Err(e) => tracing::warn!("{e:#}"),
        }
    }
}
```

Notes:

- `reserve_many` (tokio ≥ 1.37; workspace is on 1.52) preserves today's backpressure: we block on channel capacity *before* consuming packets, instead of reading and then stalling per packet.
- Per-packet parse failures keep today's policy (debug for `Fragmented`, warn otherwise) and do not abort the batch.
- `recv_batch` returning 0 packets is treated as `WouldBlock`, so the loop cannot spin.

### 2. Private-API surface (`apple/sys.rs`)

New `sys` submodule owning the private-API surface, used by `send_batch`/`recv_batch` above:

```rust
#[repr(C)]
struct msghdr_x {
    msg_name: *mut c_void,
    msg_namelen: libc::socklen_t,
    msg_iov: *mut libc::iovec,
    msg_iovlen: c_int,
    msg_control: *mut c_void,
    msg_controllen: libc::socklen_t,
    msg_flags: c_int,
    msg_datalen: usize,
}

const _: () = assert!(size_of::<msghdr_x>() == 56); // LP64 layout, matches socket_private.h.

type RecvmsgX = unsafe extern "C" fn(c_int, *mut msghdr_x, c_uint, c_int) -> isize;
type SendmsgX = unsafe extern "C" fn(c_int, *const msghdr_x, c_uint, c_int) -> isize;

/// Resolved once via `dlsym(RTLD_DEFAULT, ...)`; `None` if either symbol is missing.
fn batch_syscalls() -> Option<(RecvmsgX, SendmsgX)>;
```

(The header declares `msgp` as `const` even for `recvmsg_x`, but the kernel writes the per-message out-fields `msg_datalen`/`msg_flags`, hence `*mut` on the receive type — same as quinn-udp.)

`recv_batch` builds, per message, the same two-iovec split used today (reusable `[[u8; 4]; N]` AF-header scratch + the `IpPacketBuf`), zeroes `msg_flags`/`msg_datalen`, and calls `recvmsg_x(fd, msgs.as_mut_ptr(), n, 0)`. Per received message: `lens[i] = msg_datalen - 4` (a record shorter than 4 bytes or one flagged `MSG_TRUNC` is dropped with a debug log; truncation is impossible while the interface MTU is ≤ `MAX_IP_SIZE`, since each buffer holds 4 + 1280 bytes).

`send_batch` fills the AF header from `packet.version()`, sets `msg_name`/`msg_control` to null and `msg_flags`/`msg_datalen` to 0 as the contract requires, and returns the syscall's count.

### 3. Wiring (`from_fd_inner`)

`from_fd_inner` picks the path at startup:

```rust
match sys::batch_syscalls() {
    Some(_) => /* spawn tun_send_batched / tun_recv_batched threads */,
    None => /* spawn tun_send / tun_recv threads (today's code, unchanged) */,
}
```

The decision is logged once on `info` (it is a significant, user-impacting property of the session). An environment-variable escape hatch (e.g. `FIREZONE_NO_BATCHED_TUN_IO=1`) forces the fallback for field debugging; cheap to add, easy to remove later.

### 4. Batch size

```rust
const BATCH_SIZE: usize = if cfg!(target_os = "ios") { 25 } else { 100 };
```

- Mirrors the rationale of `MAX_INBOUND_PACKET_BATCH` (`tunnel/src/io.rs:40-46`): mobile is memory-constrained. Per-batch resident scratch is ~134 KiB on desktop, ~34 KiB on iOS — negligible against the NE memory limit.
- 100 < 128 (`UTUN_OPT_MAX_PENDING_PACKETS` after #13667), so a full kernel queue fits in one read; and well below the kernel clamp of 256.
- Keeping the TUN batch ≥ the event-loop batch means the channel never becomes the bottleneck hop.

Unifying this constant with `MAX_INBOUND_PACKET_BATCH` is desirable but orthogonal; proposed as a follow-up.

## Observability

- New histogram metric for packets-per-syscall, attributed by direction (reuses the `telemetry::otel` patterns already used for queue lengths in `apple/tun.rs`). This is the direct success metric: today it would read exactly 1.0; after this change plus #13667 it should approach the batch size under load.
- The per-packet `wire::dev::send/recv` trace logs (debug builds) move into the batch loops unchanged.

## Testing

1. **Layout tests**: compile-time assert on `msghdr_x` size (and `offset_of!` for the out-fields) on Apple targets.
2. **Integration test (macOS CI)**: runners have passwordless sudo, and creating a utun directly via `socket(PF_SYSTEM, SOCK_DGRAM, SYSPROTO_CONTROL)` + `connect` requires root (`CTL_FLAG_PRIVILEGED`). The test assigns an address/route to the utun, sends a burst of UDP datagrams from a regular socket routed into it, and asserts that `recvmsg_x` on the utun fd returns multi-packet batches — which regression-tests #13667 (without raising `UTUN_OPT_MAX_PENDING_PACKETS`, batches of 1 are expected) and the read path in one go. The write path is covered by injecting batches and asserting receipt on the UDP socket.
3. **Manual benchmark**: iperf3 upload + download through a tunnel on macOS, before/after, including syscall counts via Instruments/`ktrace`. (Per #13667 discussion, @jamilbk has a speed-test setup.)

## Alternatives considered

- **Batched helpers in the shared `tun` crate (closure-based)**: rejected — Apple is the only consumer, so the orchestration belongs next to the syscalls in `client-ffi`; passing `write_many`/`read_many` closures across the crate boundary added indirection for no reuse. The only thing genuinely shared with the fallback is the parse/log policy, which is small enough to inline.
- **Only #13667, no syscall batching**: removes the kernel-side lock-step but leaves ~1 syscall/packet; measurably worse ceiling.
- **`NEPacketTunnelFlow.readPackets` (ObjC batching)**: puts Swift/ObjC and per-packet `NSData` copies in the hot path; we already hold the raw fd.
- **Multiple packets per plain `read`/`readv`**: a kernel-control socket returns exactly one record per call regardless of iovec space; not possible.
- **Skywalk channel rings**: entitlement-gated, see non-goals.

## Open questions

1. Drop-the-tail on hard write errors (proposed, matches today's drop-one) vs. retrying the tail packet-by-packet through the legacy path?
2. Is the env-var escape hatch wanted, and under what name?
3. Should the new histogram be sampled (it is per-syscall, not per-packet, so likely cheap enough unsampled)?
