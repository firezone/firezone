//! Owned Compio operations on the same thread as the client state machine.

mod ancillary;
#[cfg(any(target_os = "android", all(test, target_os = "linux")))]
mod android_tun;
mod buffer;
mod local_queue;
#[cfg(target_os = "android")]
use android_tun::AndroidTun;
#[cfg(windows)]
mod windows_tun;
#[cfg(windows)]
pub use windows_tun::Wintun;
#[cfg(target_os = "linux")]
mod linux_tun;
#[cfg(target_os = "linux")]
pub use linux_tun::OffloadedTun;

use super::{
    PacketIo,
    completion::{
        CompletionIo, CompletionPort, Operation, Payload, ReceivedDatagram, ReceivedNetwork,
    },
};
use anyhow::{Context as _, Result};
use buffer::UdpBuffer;
use bufferpool::BufferPool;
use compio::{
    BufResult,
    buf::{IntoInner, IoBuf},
    compat::{RuntimeCompat, TokioAdapter},
    net::UdpSocket,
};
use futures::{FutureExt as _, future::LocalBoxFuture};
use local_queue::LocalQueue;
use socket_factory::DatagramOut;
use socket_factory::{SocketFactory, SourceIpResolver};
use std::{cell::Cell, future::Future, net::SocketAddr, rc::Rc};
use std::{
    cell::RefCell,
    sync::Arc,
    task::{Context, Poll, Waker},
};
use tun::PacketBatch;

/// Owns packet state, device buffers, and completion operations on one thread.
pub struct Native {
    io: CompletionIo,
    port: CompletionPort,
    device: DeviceSlot,
    factory: Rc<RefCell<Arc<dyn SocketFactory<socket_factory::UdpSocket>>>>,
    driver: Option<LocalBoxFuture<'static, Result<()>>>,
    error: Option<anyhow::Error>,
}

impl Native {
    pub fn new(factory: Arc<dyn SocketFactory<socket_factory::UdpSocket>>) -> Self {
        let (io, port) = CompletionIo::new();
        let device = DeviceSlot::default();
        let factory = Rc::new(RefCell::new(factory));
        let driver =
            drive_with_factory(port.clone(), device.clone(), factory.clone()).boxed_local();
        Self {
            io,
            port,
            device,
            factory,
            driver: Some(driver),
            error: None,
        }
    }

    fn poll_driver(&mut self, cx: &mut Context<'_>) {
        let Some(driver) = &mut self.driver else {
            return;
        };
        if let Poll::Ready(result) = driver.as_mut().poll(cx) {
            self.driver = None;
            self.error = result
                .err()
                .map(|error| super::PacketIoFailed(error).into());
            self.port.close();
        }
    }
}

impl PacketIo for Native {
    type Network = ReceivedNetwork;
    fn poll_network(&mut self, cx: &mut Context<'_>) -> Poll<Self::Network> {
        self.poll_driver(cx);
        self.io.poll_network(cx)
    }
    fn poll_tun(&mut self, cx: &mut Context<'_>) -> Poll<Result<PacketBatch>> {
        self.poll_driver(cx);
        self.io.poll_tun(cx)
    }
    fn poll_error(&mut self, cx: &mut Context<'_>) -> Poll<anyhow::Error> {
        self.poll_driver(cx);
        if let Some(error) = self.error.take() {
            return Poll::Ready(error);
        }
        self.io.poll_error(cx)
    }
    fn poll_send_ready(&mut self, cx: &mut Context<'_>) -> Poll<Result<()>> {
        self.poll_driver(cx);
        self.io.poll_send_ready(cx)
    }
    fn send(&mut self, datagram: DatagramOut) -> Result<()> {
        self.io.send(datagram)?;
        Ok(())
    }
    fn queue_tun(&mut self, packet: ip_packet::IpPacket) {
        self.io.queue_tun(packet);
    }
    fn flush_tun_batch(&mut self) {
        self.io.flush_tun_batch();
    }
    fn poll_flush(&mut self, cx: &mut Context<'_>) -> Poll<Result<()>> {
        self.poll_driver(cx);
        self.io.poll_flush(cx)
    }
    fn poll_shutdown(&mut self, cx: &mut Context<'_>) -> Poll<Result<()>> {
        self.poll_driver(cx);
        if self.driver.is_none() {
            return Poll::Ready(self.error.take().map_or(Ok(()), Err));
        }
        std::task::ready!(self.io.poll_shutdown(cx))?;
        self.port.close();
        self.poll_driver(cx);
        if let Some(error) = self.error.take() {
            return Poll::Ready(Err(error));
        }
        if self.driver.is_some() {
            return Poll::Pending;
        }
        Poll::Ready(Ok(()))
    }
    fn set_tun(&mut self, tun: Box<dyn tun::Tun>) {
        match InstalledDevice::new(tun.into_io()) {
            Ok(device) => {
                *self.device.device.borrow_mut() = Some(Rc::new(device));
                if let Some(waker) = self.device.waker.borrow_mut().take() {
                    waker.wake();
                }
                self.io.reset(self.factory.borrow().clone());
            }
            Err(error) => self.error = Some(error),
        }
    }
    fn reset(&mut self, factory: Arc<dyn SocketFactory<socket_factory::UdpSocket>>) {
        factory.reset();
        *self.factory.borrow_mut() = factory.clone();
        self.io.reset(factory);
    }
}

#[derive(Clone, Default)]
struct DeviceSlot {
    device: Rc<RefCell<Option<Rc<InstalledDevice>>>>,
    waker: Rc<RefCell<Option<Waker>>>,
}

impl DeviceSlot {
    async fn get(&self) -> Rc<InstalledDevice> {
        std::future::poll_fn(|cx| match self.device.borrow().as_ref() {
            Some(device) => Poll::Ready(device.clone()),
            None => {
                *self.waker.borrow_mut() = Some(cx.waker().clone());
                Poll::Pending
            }
        })
        .await
    }
}
impl PacketDevice for DeviceSlot {
    async fn read(&self) -> Result<PacketBatch> {
        let device = self.get().await;
        let batch = match &device.device {
            #[cfg(target_os = "android")]
            Device::Android(tun) => tun.read().await?,
            #[cfg(target_os = "linux")]
            Device::Linux(tun) => tun.read().await?,
            #[cfg(windows)]
            Device::Windows { tun, .. } => tun.read().await?,
        };
        for inspect in &device.inspectors {
            for packet in batch.iter() {
                inspect(packet);
            }
        }
        Ok(batch)
    }
    async fn write(&self, batch: PacketBatch) -> Result<()> {
        let device = self.get().await;
        match &device.device {
            #[cfg(target_os = "android")]
            Device::Android(tun) => tun.write(batch).await?,
            #[cfg(target_os = "linux")]
            Device::Linux(tun) => tun.write(batch).await?,
            #[cfg(windows)]
            Device::Windows { tun, .. } => tun.write(batch).await?,
        }
        Ok(())
    }
}
struct InstalledDevice {
    device: Device,
    inspectors: Vec<fn(&ip_packet::IpPacket)>,
}
enum Device {
    #[cfg(target_os = "android")]
    Android(AndroidTun),
    #[cfg(target_os = "linux")]
    Linux(OffloadedTun),
    #[cfg(windows)]
    Windows { tun: Wintun },
}
impl InstalledDevice {
    #[cfg_attr(
        windows,
        expect(clippy::unnecessary_wraps, reason = "Fallible on Unix")
    )]
    fn new(mut io: tun::TunIo) -> Result<Self> {
        let mut inspectors = Vec::new();
        while let tun::TunIo::Inspect { inner, inspect } = io {
            inspectors.push(inspect);
            io = *inner;
        }
        let device = match io {
            #[cfg(target_os = "android")]
            tun::TunIo::Android(fd) => Device::Android(AndroidTun::from_fd(fd)?),
            #[cfg(target_os = "linux")]
            tun::TunIo::Linux(fd) => Device::Linux(OffloadedTun::from_fd(fd)?),
            #[cfg(windows)]
            tun::TunIo::Windows { session, owner } => Device::Windows {
                tun: Wintun::new(session, owner),
            },
            tun::TunIo::Inspect { .. } => unreachable!(),
        };
        Ok(Self { device, inspectors })
    }
}

pub trait PacketDevice: 'static {
    fn read(&self) -> impl Future<Output = Result<PacketBatch>>;
    fn write(&self, batch: PacketBatch) -> impl Future<Output = Result<()>>;
}

/// Runs control tasks and packet completions on one current-thread executor.
pub fn run<F: Future>(future: F, core: Option<usize>) -> Result<F::Output> {
    let core = core.or(std::env::var("FIREZONE_PACKET_CORE")
        .ok()
        .map(|core| core.parse())
        .transpose()?);
    if let Some(core) = core {
        pin_thread(core)?;
    }
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()?;
    let result = runtime.block_on(async {
        let completion = compio::runtime::Runtime::new()?;
        let completion = RuntimeCompat::<TokioAdapter>::new(completion)?;
        // Arm the driver's wake notification before Tokio can wake the externally polled future.
        completion.poll_with(Some(std::time::Duration::ZERO));
        anyhow::Ok(completion.execute(future).await)
    })?;
    Ok(result)
}

struct BoundSocket {
    socket: std::net::UdpSocket,
    resolve: Option<SourceIpResolver>,
}

async fn drive_with_factory<D: PacketDevice>(
    port: CompletionPort,
    device: D,
    factory: Rc<RefCell<Arc<dyn SocketFactory<socket_factory::UdpSocket>>>>,
) -> Result<()> {
    loop {
        let bind = |address| -> Result<BoundSocket> {
            let (socket, resolve) = factory.borrow().bind(address)?.into_completion()?;
            Ok(BoundSocket { socket, resolve })
        };
        let v4 = bind("0.0.0.0:52625".parse()?)
            .map_err(|error| port.report_error(error))
            .ok();
        let v6 = bind("[::]:52625".parse()?)
            .map_err(|error| port.report_error(error))
            .ok();
        if !drive_generation(&port, &device, v4, v6).await? {
            return Ok(());
        }
    }
}

async fn drive_generation<D: PacketDevice>(
    port: &CompletionPort,
    device: &D,
    mut v4: Option<BoundSocket>,
    mut v6: Option<BoundSocket>,
) -> Result<bool> {
    let resolve_v4 = v4.as_mut().and_then(|socket| socket.resolve.take());
    let resolve_v6 = v6.as_mut().and_then(|socket| socket.resolve.take());
    let v4 = v4
        .map(|socket| UdpSocket::from_std(socket.socket))
        .transpose()?
        .map(Rc::new);
    let v6 = v6
        .map(|socket| UdpSocket::from_std(socket.socket))
        .transpose()?
        .map(Rc::new);
    let send_v4 = LocalQueue::new();
    let send_v6 = LocalQueue::new();
    let send_tun = LocalQueue::new();
    let receive_v4 = async {
        match &v4 {
            Some(socket) => receive_network(port, socket).await,
            None => std::future::pending().await,
        }
    };
    let write_v4 = async {
        match &v4 {
            Some(socket) => send_network(port, socket, &send_v4, resolve_v4.as_ref()).await,
            None => std::future::pending().await,
        }
    };
    let receive_v6 = async {
        match &v6 {
            Some(socket) => receive_network(port, socket).await,
            None => std::future::pending().await,
        }
    };
    let write_v6 = async {
        match &v6 {
            Some(socket) => send_network(port, socket, &send_v6, resolve_v6.as_ref()).await,
            None => std::future::pending().await,
        }
    };
    let tasks = async {
        futures::try_join!(
            receive_v4,
            receive_v6,
            receive_tun(port, device),
            write_v4,
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
                Payload::Network(datagram) if datagram.dst.is_ipv4() && v4.is_some() => {
                    send_v4.push(tracked)
                }
                Payload::Network(datagram) if datagram.dst.is_ipv6() && v6.is_some() => {
                    send_v6.push(tracked)
                }
                Payload::Network(_) => {
                    tracked
                        .guard
                        .complete(Err(anyhow::anyhow!("UDP address family unavailable")))?;
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
    if let Some(v4) = v4 {
        Rc::try_unwrap(v4)
            .map_err(|_| anyhow::anyhow!("IPv4 socket still referenced"))?
            .close()
            .await?;
    }
    if let Some(v6) = v6 {
        Rc::try_unwrap(v6)
            .map_err(|_| anyhow::anyhow!("IPv6 socket still referenced"))?
            .close()
            .await?;
    }
    Ok(reset)
}

/// Configures metadata reception and segmentation before transferring the socket to Compio.
#[cfg(all(test, target_os = "linux"))]
fn bind_udp(address: SocketAddr) -> Result<std::net::UdpSocket> {
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
    let pool = BufferPool::<Vec<u8>>::new(ip_packet::MAX_FZ_PAYLOAD * 64, "completion-udp-receive");
    let local_port = socket.local_addr()?.port();
    let generation = port.generation();
    loop {
        std::future::poll_fn(|cx| port.poll_receive_ready(cx, true)).await;
        let mut inner = pool.pull();
        inner.resize(ip_packet::MAX_FZ_PAYLOAD * 64, 0);
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
    resolve: Option<&SourceIpResolver>,
) -> Result<()> {
    let gso = Cell::new(true);
    loop {
        let TrackedOperation { operation, guard } = queue.pop().await;
        let Payload::Network(mut datagram) = operation.payload else {
            unreachable!()
        };
        if datagram.src.is_none()
            && let Some(resolve) = resolve
        {
            match resolve(datagram.dst.ip()) {
                Ok(ip) => datagram.src = Some(SocketAddr::new(ip, socket.local_addr()?.port())),
                Err(error) => {
                    guard.complete(Err(error.into()))?;
                    continue;
                }
            }
        }
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

#[cfg(test)]
mod tests {
    use super::*;
    #[cfg(target_os = "linux")]
    use ip_packet::Ecn;

    #[test]
    fn completion_runtime_keeps_servicing_tokio_channels() {
        run(
            async {
                let (sender, mut receiver) = tokio::sync::mpsc::channel(1);
                let sending = tokio::spawn(async move {
                    for value in 0..1024 {
                        sender.send(value).await.unwrap();
                    }
                });
                for expected in 0..1024 {
                    let value =
                        tokio::time::timeout(std::time::Duration::from_secs(1), receiver.recv())
                            .await
                            .unwrap();
                    assert_eq!(value, Some(expected));
                }
                sending.await.unwrap();
            },
            None,
        )
        .unwrap();
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn native_driver_rebinds_and_drains_before_shutdown() {
        use crate::packet_io::NetworkInput as _;
        use std::sync::atomic::{AtomicUsize, Ordering};

        run(
            async {
                tokio::time::timeout(std::time::Duration::from_secs(3), async {
                    let bindings = Arc::new(AtomicUsize::new(0));
                    let factory = Arc::new({
                        let bindings = bindings.clone();
                        move |address: SocketAddr| {
                            if address.is_ipv6() {
                                return Err(std::io::ErrorKind::Unsupported.into());
                            }
                            bindings.fetch_add(1, Ordering::Relaxed);
                            socket_factory::udp("127.0.0.1:0".parse().unwrap())
                        }
                    });
                    let peer =
                        UdpSocket::from_std(bind_udp("127.0.0.1:0".parse().unwrap()).unwrap())
                            .unwrap();
                    let destination = peer.local_addr().unwrap();
                    let pool = BufferPool::<Vec<u8>>::new(64, "test-native-lifecycle");
                    let mut packets = Native::new(factory.clone());
                    for sequence in 0..2 {
                        if sequence > 0 {
                            packets.reset(factory.clone());
                        }
                        let mut packet = pool.pull();
                        packet.clear();
                        packet.extend_from_slice(&[sequence; 8]);
                        packets
                            .send(DatagramOut {
                                src: None,
                                dst: destination,
                                packet,
                                segment_size: 8,
                                ecn: Ecn::NonEct,
                            })
                            .unwrap();
                        let echo = async {
                            let BufResult(result, bytes) =
                                peer.recv_from(Vec::with_capacity(64)).await;
                            let (_, from) = result.unwrap();
                            let BufResult(result, _) = peer.send_to(bytes, from).await;
                            result.unwrap();
                        };
                        let (_, mut received) = futures::join!(
                            echo,
                            std::future::poll_fn(|cx| packets.poll_network(cx))
                        );
                        let mut count = 0;
                        received.for_each(|datagram| {
                            assert_eq!(datagram.packet, &[sequence; 8]);
                            assert_eq!(datagram.from, destination);
                            count += 1;
                        });
                        assert_eq!(count, 1);
                    }
                    std::future::poll_fn(|cx| packets.poll_shutdown(cx))
                        .await
                        .unwrap();
                    assert_eq!(bindings.load(Ordering::Relaxed), 2);
                })
                .await
                .unwrap();
            },
            None,
        )
        .unwrap();
    }

    #[cfg(target_os = "linux")]
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
