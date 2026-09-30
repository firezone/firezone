//! Owned Compio operations on the same thread as the client state machine.

mod ancillary;
mod buffer;
mod local_queue;
#[cfg(windows)]
mod windows_tun;
#[cfg(windows)]
pub use windows_tun::Wintun;
#[cfg(unix)]
mod unix_tun;
#[cfg(unix)]
pub use unix_tun::RawTun;
#[cfg(target_os = "linux")]
mod linux_tun;
#[cfg(target_os = "linux")]
pub use linux_tun::OffloadedTun;

use crate::{CompletionPort, Operation, Payload, ReceivedDatagram};
use anyhow::{Context as _, Result};
use buffer::UdpBuffer;
use bufferpool::BufferPool;
use compio::{
    BufResult,
    buf::{IntoInner, IoBuf},
    compat::{RuntimeCompat, TokioAdapter},
    net::UdpSocket,
};
use local_queue::LocalQueue;
use socket_factory::DatagramOut;
use std::{cell::Cell, future::Future, net::SocketAddr, rc::Rc};
use tun::PacketBatch;

pub trait PacketDevice: 'static {
    fn read(&self) -> impl Future<Output = Result<PacketBatch>>;
    fn write(&self, batch: PacketBatch) -> impl Future<Output = Result<()>>;
}

/// Runs control tasks and packet completions on one current-thread executor.
pub fn run<F: Future>(future: F, core: Option<usize>) -> Result<F::Output> {
    if let Some(core) = core {
        pin_thread(core)?;
    }
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()?;
    let result = runtime.block_on(async {
        let completion = compio::runtime::Runtime::new()?;
        let completion = RuntimeCompat::<TokioAdapter>::new(completion)?;
        anyhow::Ok(completion.execute(future).await)
    })?;
    Ok(result)
}

/// Drives owned packet operations until the host closes the port or I/O fails.
///
/// Each socket and TUN writer has one ordered stream of submissions. Receive,
/// state processing, and sends can overlap without handing payloads to another thread.
pub async fn drive<D: PacketDevice>(
    port: CompletionPort,
    device: D,
    v4: std::net::UdpSocket,
    v6: Option<std::net::UdpSocket>,
) -> Result<()> {
    let address_v4 = v4.local_addr()?;
    let address_v6 = v6
        .as_ref()
        .map(std::net::UdpSocket::local_addr)
        .transpose()?;
    let mut initial = Some((v4, v6));
    drive_with_factory(port, device, move || {
        if let Some(sockets) = initial.take() {
            return Ok(sockets);
        }
        let v4 = bind_udp(address_v4)?;
        let v6 = address_v6.map(bind_udp).transpose()?;
        Ok((v4, v6))
    })
    .await?;
    Ok(())
}

pub async fn drive_with_factory<D: PacketDevice>(
    port: CompletionPort,
    device: D,
    mut bind: impl FnMut() -> Result<(std::net::UdpSocket, Option<std::net::UdpSocket>)>,
) -> Result<()> {
    loop {
        let (v4, v6) = bind()?;
        if !drive_generation(&port, &device, v4, v6).await? {
            return Ok(());
        }
    }
}

async fn drive_generation<D: PacketDevice>(
    port: &CompletionPort,
    device: &D,
    v4: std::net::UdpSocket,
    v6: Option<std::net::UdpSocket>,
) -> Result<bool> {
    let v4 = Rc::new(UdpSocket::from_std(v4)?);
    let v6 = v6.map(UdpSocket::from_std).transpose()?.map(Rc::new);
    let send_v4 = LocalQueue::new();
    let send_v6 = LocalQueue::new();
    let send_tun = LocalQueue::new();
    let receive_v6 = async {
        match &v6 {
            Some(socket) => receive_network(port, socket).await,
            None => std::future::pending().await,
        }
    };
    let write_v6 = async {
        match &v6 {
            Some(socket) => send_network(port, socket, &send_v6).await,
            None => std::future::pending().await,
        }
    };
    let tasks = async {
        futures::try_join!(
            receive_network(port, &v4),
            receive_v6,
            receive_tun(port, device),
            send_network(port, &v4, &send_v4),
            write_v6,
            write_tun(port, device, &send_tun),
        )?;
        anyhow::Ok(())
    };
    let submit = async {
        while let Some(operation) = std::future::poll_fn(|cx| port.poll_operation(cx)).await {
            let operation_id = operation.id;
            let tracked = TrackedOperation {
                operation,
                guard: CompletionGuard {
                    port: port.clone(),
                    id: Some(operation_id),
                },
            };
            match &tracked.operation.payload {
                Payload::Network(datagram) if datagram.dst.is_ipv4() => send_v4.push(tracked),
                Payload::Network(_) if v6.is_some() => send_v6.push(tracked),
                Payload::Network(_) => {
                    tracked
                        .guard
                        .complete(Err(anyhow::anyhow!("IPv6 socket unavailable")))?;
                }
                Payload::Tun(_) => send_tun.push(tracked),
                Payload::Rebind => {
                    tracked.guard.complete(Ok(()))?;
                    return Ok(true);
                }
            }
        }
        anyhow::Ok(false)
    };
    let tasks = Box::pin(tasks);
    let submit = Box::pin(submit);
    let reset = match futures::future::select(tasks, submit).await {
        futures::future::Either::Left((result, submit)) => {
            drop(submit);
            result?;
            false
        }
        futures::future::Either::Right((result, tasks)) => {
            drop(tasks);
            result?
        }
    };
    drop(send_v4);
    drop(send_v6);
    drop(send_tun);
    Rc::try_unwrap(v4)
        .map_err(|_| anyhow::anyhow!("IPv4 socket still referenced"))?
        .close()
        .await?;
    if let Some(v6) = v6 {
        Rc::try_unwrap(v6)
            .map_err(|_| anyhow::anyhow!("IPv6 socket still referenced"))?
            .close()
            .await?;
    }
    Ok(reset)
}

/// Configures metadata reception and segmentation before transferring the socket to Compio.
pub fn bind_udp(address: SocketAddr) -> Result<std::net::UdpSocket> {
    let domain = if address.is_ipv4() {
        socket2::Domain::IPV4
    } else {
        socket2::Domain::IPV6
    };
    let socket = socket2::Socket::new(domain, socket2::Type::DGRAM, Some(socket2::Protocol::UDP))?;
    if address.is_ipv6() {
        socket.set_only_v6(true)?;
    }
    socket.set_nonblocking(true)?;
    socket.bind(&address.into())?;
    let socket: std::net::UdpSocket = socket.into();
    quinn_udp::UdpSocketState::new((&socket).into())?;
    Ok(socket)
}

async fn receive_network(port: &CompletionPort, socket: &UdpSocket) -> Result<()> {
    let pool = BufferPool::<Vec<u8>>::new(u16::MAX as usize, "completion-udp-receive");
    let local_port = socket.local_addr()?.port();
    let generation = port.generation();
    loop {
        std::future::poll_fn(|cx| port.poll_receive_ready(cx, true)).await;
        let mut inner = pool.pull();
        inner.resize(u16::MAX as usize, 0);
        let BufResult(result, (buffer, control)) = socket
            .recv_msg(UdpBuffer { inner, len: 0 }, ancillary::Control::new())
            .await;
        let (len, _, from, flags) = result?;
        if len == 0
            || flags.intersects(
                compio::io::ancillary::ReturnFlags::TRUNC
                    | compio::io::ancillary::ReturnFlags::CTRUNC,
            )
        {
            continue;
        }
        let (local, stride, ecn) = ancillary::decode(control.as_init(), local_port, len)?;
        port.receive_network(
            generation,
            ReceivedDatagram {
                storage: Box::new(buffer),
                local,
                from,
                stride,
                ecn,
            },
        )?;
        tokio::task::yield_now().await;
    }
}

async fn receive_tun<D: PacketDevice>(port: &CompletionPort, device: &D) -> Result<()> {
    let generation = port.generation();
    loop {
        std::future::poll_fn(|cx| port.poll_receive_ready(cx, false)).await;
        port.receive_tun(generation, device.read().await?)?;
        tokio::task::yield_now().await;
    }
}

async fn send_network(
    _port: &CompletionPort,
    socket: &UdpSocket,
    queue: &LocalQueue<TrackedOperation>,
) -> Result<()> {
    let gso = Cell::new(true);
    loop {
        let TrackedOperation { operation, guard } = queue.pop().await;
        let Payload::Network(datagram) = operation.payload else {
            unreachable!()
        };
        let result = send_datagram(socket, datagram, &gso).await;
        guard.complete(result)?;
    }
}

async fn send_datagram(socket: &UdpSocket, datagram: DatagramOut, gso: &Cell<bool>) -> Result<()> {
    let DatagramOut {
        src,
        dst,
        packet,
        segment_size,
        ecn,
    } = datagram;
    if let Some(src) = src {
        anyhow::ensure!(
            src.port() == socket.local_addr()?.port(),
            "Requested UDP source port is not bound"
        );
    }
    let len = packet.len();
    let buffer = UdpBuffer { inner: packet, len };
    let buffer = if gso.get() && len > segment_size {
        let control = ancillary::encode(src, dst, ecn, Some(segment_size))?;
        let BufResult(result, (buffer, _)) = socket.send_msg(buffer, control, dst).await;
        match result {
            Ok(sent) => {
                anyhow::ensure!(sent == len, "Short UDP GSO send");
                return Ok(());
            }
            Err(error) if offload_unsupported(&error) => {
                gso.set(false);
                buffer
            }
            Err(error) => return Err(error.into()),
        }
    } else {
        buffer
    };
    let mut buffer = buffer;
    for offset in (0..len).step_by(segment_size) {
        let end = (offset + segment_size).min(len);
        let control = ancillary::encode(src, dst, ecn, None)?;
        let BufResult(result, (slice, _)) = socket
            .send_msg(buffer.slice(offset..end), control, dst)
            .await;
        buffer = slice.into_inner();
        anyhow::ensure!(result? == end - offset, "Short UDP send");
    }
    Ok(())
}

async fn write_tun<D: PacketDevice>(
    _port: &CompletionPort,
    device: &D,
    queue: &LocalQueue<TrackedOperation>,
) -> Result<()> {
    loop {
        let TrackedOperation { operation, guard } = queue.pop().await;
        let Payload::Tun(batch) = operation.payload else {
            unreachable!()
        };
        guard.complete(device.write(batch).await)?;
    }
}

#[cfg(unix)]
fn offload_unsupported(error: &std::io::Error) -> bool {
    [libc::EINVAL, libc::EIO, libc::ENOPROTOOPT].contains(&error.raw_os_error().unwrap_or_default())
}
#[cfg(windows)]
fn offload_unsupported(error: &std::io::Error) -> bool {
    use windows_sys::Win32::Networking::WinSock::{WSAEINVAL, WSAENOPROTOOPT, WSAEOPNOTSUPP};
    [WSAEINVAL, WSAENOPROTOOPT, WSAEOPNOTSUPP].contains(&error.raw_os_error().unwrap_or_default())
}

#[cfg(any(target_os = "linux", target_os = "android"))]
fn pin_thread(core: usize) -> Result<()> {
    anyhow::ensure!(
        core < libc::CPU_SETSIZE as usize,
        "CPU index exceeds affinity mask"
    );
    let mut mask = unsafe { std::mem::zeroed::<libc::cpu_set_t>() };
    unsafe { libc::CPU_SET(core, &mut mask) };
    let result = unsafe { libc::sched_setaffinity(0, std::mem::size_of_val(&mask), &mask) };
    if result < 0 {
        return Err(std::io::Error::last_os_error()).context("Failed to pin completion thread");
    }
    Ok(())
}
#[cfg(windows)]
fn pin_thread(core: usize) -> Result<()> {
    use windows_sys::Win32::System::Threading::{GetCurrentThread, SetThreadAffinityMask};
    anyhow::ensure!(
        core < usize::BITS as usize,
        "CPU index exceeds processor group"
    );
    if unsafe { SetThreadAffinityMask(GetCurrentThread(), 1usize << core) } == 0 {
        return Err(std::io::Error::last_os_error()).context("Failed to pin completion thread");
    }
    Ok(())
}

struct TrackedOperation {
    operation: Operation,
    guard: CompletionGuard,
}
struct CompletionGuard {
    port: CompletionPort,
    id: Option<u64>,
}
impl CompletionGuard {
    fn complete(mut self, result: Result<()>) -> Result<()> {
        if let Some(id) = self.id.take() {
            self.port.complete(id, result)?;
        }
        Ok(())
    }
}
impl Drop for CompletionGuard {
    fn drop(&mut self) {
        if let Some(id) = self.id.take() {
            let _ = self
                .port
                .complete(id, Err(anyhow::anyhow!("Native operation cancelled")));
        }
    }
}

#[cfg(all(test, target_os = "linux"))]
mod tests {
    use super::*;
    use ip_packet::Ecn;

    #[test]
    fn io_uring_retains_gso_gro_metadata_and_fallback_ordering() {
        run(
            async {
                assert!(
                    compio::runtime::Runtime::current()
                        .driver_type()
                        .is_iouring()
                );
                let receiver =
                    UdpSocket::from_std(bind_udp("127.0.0.1:0".parse().unwrap()).unwrap()).unwrap();
                let sender =
                    UdpSocket::from_std(bind_udp("127.0.0.1:0".parse().unwrap()).unwrap()).unwrap();
                let source = sender.local_addr().unwrap();
                let destination = receiver.local_addr().unwrap();
                let pool = BufferPool::<Vec<u8>>::new(u16::MAX as usize, "test-gso");
                let mut payload = pool.pull();
                payload.clear();
                for sequence in 0..16 {
                    payload.extend(std::iter::repeat_n(sequence, 1200));
                }
                let original = payload.as_ptr();
                let gso = Cell::new(true);

                send_datagram(
                    &sender,
                    DatagramOut {
                        src: Some(source),
                        dst: destination,
                        packet: payload,
                        segment_size: 1200,
                        ecn: Ecn::Ect0,
                    },
                    &gso,
                )
                .await
                .unwrap();
                let mut incoming = pool.pull();
                incoming.resize(u16::MAX as usize, 0);
                assert_eq!(incoming.as_ptr(), original);
                let BufResult(result, (buffer, control)) = receiver
                    .recv_msg(
                        UdpBuffer {
                            inner: incoming,
                            len: 0,
                        },
                        ancillary::Control::new(),
                    )
                    .await;
                let (len, _, from, _) = result.unwrap();
                let (local, stride, ecn) =
                    ancillary::decode(control.as_init(), destination.port(), len).unwrap();

                assert!(
                    gso.get(),
                    "Kernel must support UDP segmentation for this test"
                );
                assert_eq!(len, 16 * 1200);
                assert_eq!(stride, 1200);
                assert_eq!(local, destination);
                assert_eq!(from, source);
                assert_eq!(ecn, Ecn::Ect0);
                for (sequence, segment) in buffer.as_init().chunks(stride).enumerate() {
                    assert!(segment.iter().all(|byte| *byte == sequence as u8));
                }

                let mut payload = pool.pull();
                payload.clear();
                payload.extend([1, 1, 2, 2, 3]);
                send_datagram(
                    &sender,
                    DatagramOut {
                        src: Some(source),
                        dst: destination,
                        packet: payload,
                        segment_size: 2,
                        ecn: Ecn::NonEct,
                    },
                    &Cell::new(false),
                )
                .await
                .unwrap();
                for expected in [&[1, 1][..], &[2, 2][..], &[3][..]] {
                    let BufResult(result, bytes) =
                        receiver.recv_from(Vec::with_capacity(128)).await;
                    assert_eq!(result.unwrap().1, source);
                    assert_eq!(&bytes, expected);
                }
            },
            None,
        )
        .unwrap();
    }
}
