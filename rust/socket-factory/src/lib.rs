use std::net::{IpAddr, SocketAddr};
use std::{
    borrow::Cow,
    collections::VecDeque,
    io::{self, IoSliceMut},
    net::SocketAddr,
    slice,
    task::{ready, Context, Poll},
};

use socket2::SockAddr;
use tokio::io::Interest;

pub trait SocketFactory<S>: Fn(&SocketAddr) -> io::Result<S> + Send + Sync + 'static {}

impl<F, S> SocketFactory<S> for F where F: Fn(&SocketAddr) -> io::Result<S> + Send + Sync + 'static {}

pub fn tcp(addr: &SocketAddr) -> io::Result<TcpSocket> {
    let socket = match addr {
        SocketAddr::V4(_) => tokio::net::TcpSocket::new_v4()?,
        SocketAddr::V6(_) => tokio::net::TcpSocket::new_v6()?,
    };

    socket.set_nodelay(true)?;

    Ok(TcpSocket { inner: socket })
}

pub fn udp(addr: &SocketAddr) -> io::Result<UdpSocket> {
    let addr: SockAddr = (*addr).into();
    let socket = socket2::Socket::new(addr.domain(), socket2::Type::DGRAM, None)?;

    // Note: for AF_INET sockets IPV6_V6ONLY is not a valid flag
    if addr.is_ipv6() {
        socket.set_only_v6(true)?;
    }

    socket.set_nonblocking(true)?;
    socket.bind(&addr)?;

    let socket = std::net::UdpSocket::from(socket);
    let socket = tokio::net::UdpSocket::try_from(socket)?;
    let socket = UdpSocket::new(socket)?;

    Ok(socket)
}

pub struct TcpSocket {
    inner: tokio::net::TcpSocket,
}

impl TcpSocket {
    pub async fn connect(self, addr: SocketAddr) -> io::Result<tokio::net::TcpStream> {
        self.inner.connect(addr).await
    }
}

#[cfg(unix)]
impl std::os::fd::AsRawFd for TcpSocket {
    fn as_raw_fd(&self) -> std::os::fd::RawFd {
        self.inner.as_raw_fd()
    }
}

#[cfg(unix)]
impl std::os::fd::AsFd for TcpSocket {
    fn as_fd(&self) -> std::os::fd::BorrowedFd<'_> {
        self.inner.as_fd()
    }
}

pub struct UdpSocket {
    inner: tokio::net::UdpSocket,
    state: quinn_udp::UdpSocketState,

    port: u16,

    buffered_datagrams: VecDeque<DatagramOut<'static>>,
}

impl UdpSocket {
    fn new(inner: tokio::net::UdpSocket) -> io::Result<Self> {
        let port = inner.local_addr()?.port();

        Ok(UdpSocket {
            state: quinn_udp::UdpSocketState::new(quinn_udp::UdpSockRef::from(&inner))?,
            port,
            inner,
            buffered_datagrams: VecDeque::new(),
        })
    }
}

#[cfg(unix)]
impl std::os::fd::AsRawFd for UdpSocket {
    fn as_raw_fd(&self) -> std::os::fd::RawFd {
        self.inner.as_raw_fd()
    }
}

#[cfg(unix)]
impl std::os::fd::AsFd for UdpSocket {
    fn as_fd(&self) -> std::os::fd::BorrowedFd<'_> {
        self.inner.as_fd()
    }
}

/// An inbound UDP datagram.
pub struct DatagramIn<'a> {
    pub local: SocketAddr,
    pub from: SocketAddr,
    pub packet: &'a [u8],
}

/// An outbound UDP datagram.
pub struct DatagramOut<'a> {
    pub src: Option<SocketAddr>,
    pub dst: SocketAddr,
    pub packet: Cow<'a, [u8]>,
}

impl<'a> DatagramOut<'a> {
    fn into_owned(self) -> DatagramOut<'static> {
        DatagramOut {
            src: self.src,
            dst: self.dst,
            packet: Cow::Owned(self.packet.into_owned()),
        }
    }
}

impl UdpSocket {
    #[allow(clippy::type_complexity)]
    pub fn poll_recv_from<'b>(
        &self,
        buffer: &'b mut [u8],
        cx: &mut Context<'_>,
    ) -> Poll<io::Result<impl Iterator<Item = DatagramIn<'b>>>> {
        let Self {
            port, inner, state, ..
        } = self;

        let bufs = &mut [IoSliceMut::new(buffer)];
        let mut meta = quinn_udp::RecvMeta::default();

        loop {
            ready!(inner.poll_recv_ready(cx))?;

            if let Ok(len) = inner.try_io(Interest::READABLE, || {
                state.recv((&inner).into(), bufs, slice::from_mut(&mut meta))
            }) {
                debug_assert_eq!(len, 1);

                if meta.len == 0 {
                    continue;
                }

                let Some(local_ip) = meta.dst_ip else {
                    tracing::warn!("Skipping packet without local IP");
                    continue;
                };

                let local = SocketAddr::new(local_ip, *port);

                let iter = buffer[..meta.len]
                    .chunks(meta.stride)
                    .map(move |packet| DatagramIn {
                        local,
                        from: meta.addr,
                        packet,
                    })
                    .inspect(|r| {
                        tracing::trace!(target: "wire::net::recv", src = %r.from, dst = %r.local, num_bytes = %r.packet.len());
                    });

                return Poll::Ready(Ok(iter));
            }
        }
    }

    pub fn poll_flush(&mut self, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        loop {
            ready!(self.inner.poll_send_ready(cx))?; // Ensure we are ready to send.

            let Some(transmit) = self.buffered_datagrams.pop_front() else {
                break;
            };

            match self.try_send(&transmit) {
                Ok(()) => continue, // Try to send another packet.
                Err(e) => {
                    self.buffered_datagrams.push_front(transmit); // Don't lose the packet if we fail.

                    if e.kind() == io::ErrorKind::WouldBlock {
                        continue; // False positive send-readiness: Loop to `poll_send_ready` and return `Pending`.
                    }

                    return Poll::Ready(Err(e));
                }
            }
        }

        assert!(self.buffered_datagrams.is_empty());

        Poll::Ready(Ok(()))
    }

    pub fn send(&mut self, datagram: DatagramOut) -> io::Result<()> {
        tracing::trace!(target: "wire::net::send", src = ?datagram.src, dst = %datagram.dst, num_bytes = %datagram.packet.len());

        debug_assert!(
            self.buffered_datagrams.len() < 10_000,
            "We are not flushing the packets for some reason"
        );

        match self.try_send(&datagram) {
            Ok(()) => Ok(()),
            Err(e) if e.kind() == io::ErrorKind::WouldBlock => {
                tracing::trace!("Buffering packet because socket is busy");

                self.buffered_datagrams.push_back(datagram.into_owned());
                Ok(())
            }
            Err(e) => Err(e),
        }
    }

    pub fn try_send(&self, transmit: &DatagramOut) -> io::Result<()> {
        let transmit = quinn_udp::Transmit {
            destination: transmit.dst,
            ecn: None,
            contents: &transmit.packet,
            segment_size: None,
            src_ip: transmit.src.map(|s| s.ip()),
        };

        self.inner.try_io(Interest::WRITABLE, || {
            self.state.send((&self.inner).into(), &transmit)
        })
    }
}

#[cfg(feature = "hickory")]
mod hickory {
    use super::*;
    use hickory_proto::{
        udp::DnsUdpSocket as DnsUdpSocketTrait, udp::UdpSocket as UdpSocketTrait, TokioTime,
    };
    use tokio::net::UdpSocket as TokioUdpSocket;

    #[async_trait::async_trait]
    impl UdpSocketTrait for crate::UdpSocket {
        /// setups up a "client" udp connection that will only receive packets from the associated address
        async fn connect(addr: SocketAddr) -> io::Result<Self> {
            let inner = <TokioUdpSocket as UdpSocketTrait>::connect(addr).await?;
            let socket = Self::new(inner)?;

            Ok(socket)
        }

        /// same as connect, but binds to the specified local address for sending address
        async fn connect_with_bind(addr: SocketAddr, bind_addr: SocketAddr) -> io::Result<Self> {
            let inner =
                <TokioUdpSocket as UdpSocketTrait>::connect_with_bind(addr, bind_addr).await?;
            let socket = Self::new(inner)?;

            Ok(socket)
        }

        /// a "server" UDP socket, that bind to the local listening address, and unbound remote address (can receive from anything)
        async fn bind(addr: SocketAddr) -> io::Result<Self> {
            let inner = <TokioUdpSocket as UdpSocketTrait>::bind(addr).await?;
            let socket = Self::new(inner)?;

            Ok(socket)
        }
    }

    #[cfg(feature = "hickory")]
    impl DnsUdpSocketTrait for crate::UdpSocket {
        type Time = TokioTime;

        fn poll_recv_from(
            &self,
            cx: &mut Context<'_>,
            buf: &mut [u8],
        ) -> Poll<io::Result<(usize, SocketAddr)>> {
            <TokioUdpSocket as DnsUdpSocketTrait>::poll_recv_from(&self.inner, cx, buf)
        }

        fn poll_send_to(
            &self,
            cx: &mut Context<'_>,
            buf: &[u8],
            target: SocketAddr,
        ) -> Poll<io::Result<usize>> {
            <TokioUdpSocket as DnsUdpSocketTrait>::poll_send_to(&self.inner, cx, buf, target)
        }
    }
}

#[cfg(target_os = "windows")]
fn get_best_route(dst: IpAddr) -> IpAddr {
    use std::mem::{size_of, size_of_val, MaybeUninit};
    use std::net::{Ipv4Addr, Ipv6Addr};
    use std::ptr::null;

    use windows::Win32::NetworkManagement::IpHelper::GetAdaptersAddresses;
    use windows::Win32::NetworkManagement::IpHelper::GetBestRoute2;
    use windows::Win32::NetworkManagement::IpHelper::GET_ADAPTERS_ADDRESSES_FLAGS;
    use windows::Win32::NetworkManagement::IpHelper::IP_ADAPTER_ADDRESSES_LH;
    use windows::Win32::NetworkManagement::IpHelper::MIB_IPFORWARD_ROW2;
    use windows::Win32::Networking::WinSock::ADDRESS_FAMILY;
    use windows::Win32::Networking::WinSock::AF_UNSPEC;
    use windows::Win32::Networking::WinSock::SOCKADDR_INET;
    // SAFETY: lol
    unsafe {
        // TODO: iterate until it doesn't overflow
        let mut addresses: Vec<u8> = vec![0u8; 15000];
        let mut addresses_len = size_of_val(&addresses) as u32;
        GetAdaptersAddresses(
            AF_UNSPEC.0 as u32,
            GET_ADAPTERS_ADDRESSES_FLAGS(0),
            Some(null()),
            Some(addresses.as_mut_ptr() as *mut _),
            &mut addresses_len as *mut _,
        );

        let mut next_address = addresses.as_ptr() as *const _;
        let mut luids = Vec::new();
        loop {
            let address: &IP_ADAPTER_ADDRESSES_LH = std::mem::transmute(next_address);
            luids.push(address.Luid);
            if address.Next.is_null() {
                break;
            }
            next_address = address.Next;
        }

        let mut routes: Vec<(MIB_IPFORWARD_ROW2, SOCKADDR_INET)> = Vec::new();
        for luid in &luids {
            let addr: SOCKADDR_INET = SocketAddr::from((dst, 0)).into();
            let mut best_route: MaybeUninit<MIB_IPFORWARD_ROW2> = MaybeUninit::zeroed();
            let mut best_src: MaybeUninit<SOCKADDR_INET> = MaybeUninit::zeroed();

            GetBestRoute2(
                Some(luid as *const _),
                0,
                None,
                &addr as *const _,
                0,
                best_route.as_mut_ptr(),
                best_src.as_mut_ptr(),
            );

            let best_route = best_route.assume_init();
            let best_src = best_src.assume_init();
            routes.push((best_route, best_src));
        }

        routes.sort_by(|(a, _), (b, _)| a.Metric.cmp(&b.Metric));

        let addr = routes.first().unwrap().1;
        match addr.si_family {
            ADDRESS_FAMILY(0) => todo!(),
            ADDRESS_FAMILY(2) => Ipv4Addr::from(addr.Ipv4.sin_addr).into(),
            ADDRESS_FAMILY(23) => Ipv6Addr::from(addr.Ipv6.sin6_addr).into(),
            _ => panic!("Invalid address"),
        }
    }
}

#[cfg(test)]
mod test {
    use super::*;
    #[cfg(target_os = "windows")]
    #[test]
    fn best_route_works() {
        dbg!(get_best_route("8.8.8.8".parse().unwrap()));
    }
}
