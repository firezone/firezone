use super::{CompletionPort, LocalQueue, Payload, TrackedOperation};
use super::{ancillary, buffer::UdpBuffer};
use crate::packet_io::completion::ReceivedDatagram;
use anyhow::Result;
use bufferpool::BufferPool;
use compio::{
    BufResult,
    buf::{IntoInner, IoBuf},
    net::UdpSocket as CompioUdpSocket,
};
use socket_factory::{DatagramOut, SocketFactory, SourceIpResolver};
use std::{cell::Cell, net::SocketAddr, sync::Arc};

pub(super) struct UdpSocket {
    inner: CompioUdpSocket,
    resolve: Option<SourceIpResolver>,
}

impl UdpSocket {
    pub(super) fn bind(
        factory: &Arc<dyn SocketFactory<socket_factory::UdpSocket>>,
        address: SocketAddr,
    ) -> Result<Self> {
        let (socket, resolve) = factory.bind(address)?.into_completion()?;
        Ok(Self {
            inner: CompioUdpSocket::from_std(socket)?,
            resolve,
        })
    }

    pub(super) async fn receive(&self, port: &CompletionPort) -> Result<()> {
        receive_network(port, &self.inner).await?;
        Ok(())
    }

    pub(super) async fn send(
        &self,
        port: &CompletionPort,
        queue: &LocalQueue<TrackedOperation>,
    ) -> Result<()> {
        send_network(port, &self.inner, queue, self.resolve.as_ref()).await?;
        Ok(())
    }

    pub(super) async fn close(self) -> Result<()> {
        self.inner.close().await?;
        Ok(())
    }
}

async fn receive_network(port: &CompletionPort, socket: &CompioUdpSocket) -> Result<()> {
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

async fn send_network(
    _port: &CompletionPort,
    socket: &CompioUdpSocket,
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

pub(super) async fn send_datagram(
    socket: &CompioUdpSocket,
    datagram: DatagramOut,
    gso: &Cell<bool>,
) -> Result<()> {
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

#[cfg(unix)]
fn offload_unsupported(error: &std::io::Error) -> bool {
    [libc::EINVAL, libc::EIO, libc::ENOPROTOOPT].contains(&error.raw_os_error().unwrap_or_default())
}
#[cfg(windows)]
fn offload_unsupported(error: &std::io::Error) -> bool {
    use windows_sys::Win32::Networking::WinSock::{WSAEINVAL, WSAENOPROTOOPT, WSAEOPNOTSUPP};
    [WSAEINVAL, WSAENOPROTOOPT, WSAEOPNOTSUPP].contains(&error.raw_os_error().unwrap_or_default())
}
