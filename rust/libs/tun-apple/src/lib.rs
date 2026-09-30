#![cfg(any(target_os = "macos", target_os = "ios"))]
#![cfg_attr(test, allow(clippy::unwrap_used))]

//! Apple-specific TUN I/O on the `utun` file descriptor handed to us by the
//! NetworkExtension.
//!
//! macOS and iOS poll I/O on the packet-processing thread using Apple's batched
//! `recvmsg_x` / `sendmsg_x` syscalls (see [`sys`] / [`bulk`])
//! when available and fall back to per-packet I/O ([`per_packet`]) otherwise.
//!

mod bulk;
mod per_packet;
mod sys;

#[cfg(test)]
mod tests;

use anyhow::Result;
use libc::{F_GETFL, F_SETFL, O_NONBLOCK, fcntl};
use std::{io, os::fd::RawFd};

impl Io {
    /// Creates local IO for a borrowed utun descriptor.
    ///
    /// # Safety
    ///
    /// The descriptor must remain open until this IO is dropped.
    pub unsafe fn new(fd: RawFd) -> Result<Self> {
        use futures::StreamExt as _;
        use ip_packet::IpPacketBuf;
        use std::rc::Rc;
        use tokio::io::unix::AsyncFd;
        let fd = Rc::new(AsyncFd::new(fd)?);
        let syscalls = sys::batch_syscalls();
        let batch_histogram = otel_instruments::network_packets_batch_count();
        let read_fd = fd.clone();
        let reader = futures::stream::try_unfold(
            (
                read_fd,
                (0..tun::MAX_BATCH_SIZE)
                    .map(|_| IpPacketBuf::new())
                    .collect::<Vec<_>>(),
                batch_histogram.clone(),
            ),
            move |(fd, mut buffers, batch_histogram)| async move {
                let batch = receive_batch(&fd, syscalls, &mut buffers, &batch_histogram).await?;
                anyhow::Ok(Some((batch, (fd, buffers, batch_histogram))))
            },
        )
        .boxed_local();
        Ok(Self {
            fd,
            syscalls,
            reader,
            batch_histogram,
            dropped_packets: otel_instruments::network_packet_dropped(),
            write_retries: otel_instruments::network_retries(),
        })
    }
}

pub struct Io {
    fd: std::rc::Rc<tokio::io::unix::AsyncFd<RawFd>>,
    syscalls: Option<&'static sys::BatchSyscalls>,
    reader: futures::stream::LocalBoxStream<'static, Result<tun::PacketBatch>>,
    batch_histogram: opentelemetry::metrics::Histogram<u64>,
    dropped_packets: opentelemetry::metrics::Counter<u64>,
    write_retries: opentelemetry::metrics::Histogram<u64>,
}

impl tun::TunIo for Io {
    fn poll_read(
        &mut self,
        cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<Result<tun::PacketBatch>> {
        use futures::StreamExt as _;
        let batch = std::task::ready!(self.reader.poll_next_unpin(cx));
        std::task::Poll::Ready(batch.unwrap_or_else(|| Err(anyhow::anyhow!("TUN reader stopped"))))
    }

    fn send(
        &self,
        mut batch: tun::PacketBatch,
    ) -> futures::future::LocalBoxFuture<'static, Result<()>> {
        use futures::FutureExt as _;
        use std::os::fd::AsRawFd as _;
        use tokio::io::Interest;
        let fd = self.fd.clone();
        let syscalls = self.syscalls;
        let batch_histogram = self.batch_histogram.clone();
        let dropped_packets = self.dropped_packets.clone();
        let write_retries = self.write_retries.clone();
        async move {
            match syscalls {
                Some(syscalls) => {
                    let mut offset = 0;
                    while offset < batch.len() {
                        let result = fd
                            .async_io(Interest::WRITABLE, |fd| {
                                // SAFETY: The NetworkExtension keeps the descriptor open for the session.
                                unsafe {
                                    bulk::send_batch(syscalls, fd.as_raw_fd(), &batch[offset..])
                                }
                            })
                            .await;
                        match result {
                            Ok(0) => {
                                record_drop(
                                    batch.len() - offset,
                                    &std::io::Error::from(std::io::ErrorKind::WriteZero),
                                    &dropped_packets,
                                );
                                break;
                            }
                            Ok(sent) => {
                                batch_histogram.record(
                                    sent as u64,
                                    &[
                                        opentelemetry::KeyValue::new("system.device", "tun"),
                                        opentelemetry::KeyValue::new(
                                            "network.io.direction",
                                            "transmit",
                                        ),
                                    ],
                                );
                                offset += sent;
                            }
                            Err(error) => {
                                record_drop(batch.len() - offset, &error, &dropped_packets);
                                break;
                            }
                        }
                    }
                }
                None => {
                    for packet in batch.drain() {
                        let mut attempt = 0;
                        loop {
                            match fd
                                .async_io(Interest::WRITABLE, |fd| {
                                    per_packet::write(fd.as_raw_fd(), &packet)
                                })
                                .await
                            {
                                Ok(_) => break,
                                Err(error)
                                    if error.raw_os_error() == Some(libc::ENOSPC)
                                        && attempt < 24 =>
                                {
                                    for _ in 0..(1 << attempt.min(6)) {
                                        std::hint::spin_loop();
                                    }
                                    tokio::task::yield_now().await;
                                    attempt += 1;
                                }
                                Err(error) => {
                                    record_drop(1, &error, &dropped_packets);
                                    break;
                                }
                            }
                        }
                        if attempt > 0 {
                            write_retries.record(
                                attempt as u64,
                                &[
                                    opentelemetry::KeyValue::new("system.device", "tun"),
                                    opentelemetry::KeyValue::new(
                                        "network.io.direction",
                                        "transmit",
                                    ),
                                ],
                            );
                        }
                    }
                }
            }
            Ok(())
        }
        .boxed_local()
    }
}

async fn receive_batch(
    fd: &tokio::io::unix::AsyncFd<RawFd>,
    syscalls: Option<&'static sys::BatchSyscalls>,
    buffers: &mut [ip_packet::IpPacketBuf],
    batch_histogram: &opentelemetry::metrics::Histogram<u64>,
) -> Result<tun::PacketBatch> {
    use anyhow::ErrorExt as _;
    use ip_packet::IpPacket;
    use std::os::fd::AsRawFd as _;
    use tokio::io::Interest;
    loop {
        let mut batch = tun::PacketBatch::default();
        let mut lengths = [0; tun::MAX_BATCH_SIZE];
        let count = match syscalls {
            Some(syscalls) => {
                fd.async_io(Interest::READABLE, |fd| {
                    // SAFETY: All buffers are writable and the descriptor belongs to the session.
                    unsafe { bulk::recv_batch(syscalls, fd.as_raw_fd(), buffers, &mut lengths) }
                })
                .await?
            }
            None => {
                let mut guard = fd.readable().await?;
                let mut count = 0;
                for (buffer, length) in buffers.iter_mut().zip(&mut lengths) {
                    match guard.try_io(|fd| per_packet::read(fd.get_ref().as_raw_fd(), buffer)) {
                        Ok(Ok(len)) => {
                            *length = len;
                            count += 1;
                        }
                        Ok(Err(error)) => return Err(error.into()),
                        Err(_) => break,
                    }
                }
                if count == 0 {
                    continue;
                }
                count
            }
        };
        anyhow::ensure!(count != 0, "TUN file descriptor is closed");
        if syscalls.is_some() {
            batch_histogram.record(
                count as u64,
                &[
                    opentelemetry::KeyValue::new("system.device", "tun"),
                    opentelemetry::KeyValue::new("network.io.direction", "receive"),
                ],
            );
        }
        for (buffer, &length) in buffers.iter_mut().zip(&lengths).take(count) {
            if length == 0 {
                continue;
            }
            match IpPacket::new(std::mem::take(buffer), length) {
                Ok(packet) => {
                    #[cfg(debug_assertions)]
                    tracing::trace!(target: "wire::dev::recv", ?packet);
                    assert!(batch.try_push(packet).is_ok());
                }
                Err(error) if error.any_is::<ip_packet::Fragmented>() => {
                    tracing::debug!("{error:#}")
                }
                Err(error) => tracing::warn!("{error:#}"),
            }
        }
        if !batch.is_empty() {
            return Ok(batch);
        }
        tokio::task::yield_now().await;
    }
}

fn record_drop(
    count: usize,
    error: &std::io::Error,
    dropped_packets: &opentelemetry::metrics::Counter<u64>,
) {
    dropped_packets.add(
        count as u64,
        &[
            opentelemetry::KeyValue::new("system.device", "tun"),
            opentelemetry::KeyValue::new("network.io.direction", "transmit"),
            opentelemetry::KeyValue::new(
                "error.code",
                error.raw_os_error().unwrap_or_default() as i64,
            ),
        ],
    );
    tracing::debug!(count, %error, "Failed to write to TUN FD");
}

pub struct Tun {
    name: String,
    fd: RawFd,
}

impl Tun {
    /// Configures the descriptor owned by NetworkExtension.
    ///
    /// # Safety
    ///
    /// The descriptor must remain open until this TUN and its local IO are dropped.
    pub unsafe fn new(name: String, fd: RawFd) -> io::Result<Self> {
        set_non_blocking(fd)?;
        raise_recv_buffer(fd);
        raise_max_pending_packets(fd);

        Ok(Self { name, fd })
    }
}

impl tun::Tun for Tun {
    fn name(&self) -> &str {
        &self.name
    }

    fn into_io(self: Box<Self>) -> Result<Box<dyn tun::TunIo>> {
        // Safety: `Tun::new` requires the descriptor to outlive its local IO.
        let io = unsafe { Io::new(self.fd)? };

        Ok(Box::new(io))
    }
}

/// Receive buffer we request for the utun control socket via `SO_RCVBUF`.
///
/// The kernel default (`ctl_recvsize`) is 512 KiB, only a few hundred MTU-sized
/// packets, after which inbound packets are backpressured. A larger buffer lets the kernel
/// queue more while we drain it. 8 MiB matches the default `kern.ipc.maxsockbuf`
/// ceiling, the most the kernel grants without raising that system-wide limit.
const RECV_BUFFER_SIZE: libc::c_int = if cfg!(target_os = "ios") {
    2 * 1024 * 1024
} else {
    8 * 1024 * 1024
};

/// How many packets the kernel may park in the socket receive buffer before it pauses
/// the interface's output queue until we read them.
///
/// XNU defaults this to 1, so every packet costs a full read + flow-control roundtrip
/// before the kernel hands us the next one. We size it to [`RECV_BUFFER_SIZE`] at the
/// TUN MTU ([`ip_packet::MAX_IP_SIZE`]), rounded up to a power of two, leaving the byte
/// buffer as the limit that actually governs how much is queued.
const MAX_PENDING_PACKETS: u32 =
    (RECV_BUFFER_SIZE as u32 / ip_packet::MAX_IP_SIZE as u32).next_power_of_two();

/// From XNU's `bsd/net/if_utun.h`.
const UTUN_OPT_MAX_PENDING_PACKETS: libc::c_int = 16;

fn get_last_error() -> io::Error {
    io::Error::last_os_error()
}

fn set_non_blocking(fd: RawFd) -> io::Result<()> {
    match unsafe { fcntl(fd, F_GETFL) } {
        -1 => Err(get_last_error()),
        flags => match unsafe { fcntl(fd, F_SETFL, flags | O_NONBLOCK) } {
            -1 => Err(get_last_error()),
            _ => Ok(()),
        },
    }
}

/// Raises the limit of packets the kernel buffers on the utun socket so it can run
/// ahead of our reads instead of in lock-step.
fn raise_max_pending_packets(fd: RawFd) {
    let current = match get_sockopt::<u32>(fd, libc::SYSPROTO_CONTROL, UTUN_OPT_MAX_PENDING_PACKETS)
    {
        Ok(current) => current,
        Err(e) => {
            tracing::warn!(error = %e, "Failed to get `UTUN_OPT_MAX_PENDING_PACKETS`");
            return;
        }
    };

    tracing::debug!(current, "Queried `UTUN_OPT_MAX_PENDING_PACKETS`");

    if current >= MAX_PENDING_PACKETS {
        return;
    }

    if let Err(e) = set_sockopt(
        fd,
        libc::SYSPROTO_CONTROL,
        UTUN_OPT_MAX_PENDING_PACKETS,
        &MAX_PENDING_PACKETS,
    ) {
        tracing::warn!(error = %e, "Failed to set `UTUN_OPT_MAX_PENDING_PACKETS`");
        return;
    }

    tracing::debug!(
        previous = current,
        new = MAX_PENDING_PACKETS,
        "Raised `UTUN_OPT_MAX_PENDING_PACKETS`"
    );
}

/// Raises the utun socket's receive buffer so the kernel can queue more inbound
/// packets between our reads.
fn raise_recv_buffer(fd: RawFd) {
    if let Err(e) = set_sockopt(fd, libc::SOL_SOCKET, libc::SO_RCVBUF, &RECV_BUFFER_SIZE) {
        tracing::warn!(error = %e, "Failed to set TUN socket receive buffer");
        return;
    }

    // The kernel clamps to `kern.ipc.maxsockbuf`; read back what it actually applied.
    match get_sockopt::<libc::c_int>(fd, libc::SOL_SOCKET, libc::SO_RCVBUF) {
        Ok(actual) => {
            tracing::debug!(
                requested = RECV_BUFFER_SIZE,
                actual,
                "Set TUN socket receive buffer"
            )
        }
        Err(e) => tracing::warn!(error = %e, "Failed to read back TUN socket receive buffer"),
    }
}

/// Sets an integer-valued socket option.
fn set_sockopt<T>(fd: RawFd, level: libc::c_int, name: libc::c_int, value: &T) -> io::Result<()> {
    // Safety: `value` points to a `T`, matching the `size_of::<T>()` length we pass.
    let ret = unsafe {
        libc::setsockopt(
            fd,
            level,
            name,
            (value as *const T).cast(),
            size_of::<T>() as libc::socklen_t,
        )
    };

    if ret < 0 {
        return Err(get_last_error());
    }

    Ok(())
}

/// Reads an integer-valued socket option.
fn get_sockopt<T>(fd: RawFd, level: libc::c_int, name: libc::c_int) -> io::Result<T> {
    let mut value = std::mem::MaybeUninit::<T>::uninit();
    let mut len = size_of::<T>() as libc::socklen_t;

    // Safety: `value` has room for the `size_of::<T>()` length we pass.
    let ret = unsafe { libc::getsockopt(fd, level, name, value.as_mut_ptr().cast(), &mut len) };

    if ret < 0 {
        return Err(get_last_error());
    }

    // Safety: `getsockopt` succeeded; these integer options return a fully-initialized `T`.
    Ok(unsafe { value.assume_init() })
}
