use anyhow::Result;
use compio::{
    buf::{IoBuf, IoBufMut, SetBufInit},
    driver::{SharedFd, ToSharedFd},
    runtime::Task,
};
use lockfree_object_pool::SpinLockOwnedReusable;
use socket2::Socket;
use std::{
    any::Any,
    collections::HashMap,
    io,
    net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr},
    sync::Arc,
    task::{ready, Context, Poll},
};
use stun_codec::rfc8656::attributes::AddressFamily;
use tokio::sync::mpsc;

/// A dynamic collection of UDP sockets, listening on all interfaces of a particular IP family.
pub struct Sockets {
    buffer_pool: Arc<lockfree_object_pool::SpinLockObjectPool<Vec<u8>>>,

    /// All currently active sockets.
    inner: HashMap<
        (u16, AddressFamily),
        (
            compio::runtime::Task<Result<(), Box<dyn Any + Send>>>,
            SharedFd<Socket>,
        ),
    >,

    cmd_tx: mpsc::Sender<Command>,
    event_rx: mpsc::Receiver<Event>,
}

pub struct Packet {
    inner: Buffer,
    pub length: usize,
}

impl std::fmt::Debug for Packet {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Packet")
            .field("length", &self.length)
            .finish_non_exhaustive()
    }
}

impl Packet {
    pub fn payload(&self) -> &[u8] {
        &self.inner.0[..self.length]
    }

    pub fn inner_mut(&mut self) -> &mut Vec<u8> {
        &mut self.inner.0
    }
}

impl Default for Sockets {
    fn default() -> Self {
        Self::new()
    }
}

impl Sockets {
    pub fn new() -> Self {
        let (cmd_tx, mut cmd_rx) = mpsc::channel(1_000_000); // Commands are really small and this channel should really never fill up unless we have serious problems in the "mio" worker thread.
        let (event_tx, event_rx) = mpsc::channel(1_024);

        let buffer_pool = Arc::new(lockfree_object_pool::SpinLockObjectPool::new(
            || Vec::<u8>::with_capacity(1500),
            |b| b.fill(0),
        ));

        std::thread::spawn({
            let buffer_pool = Arc::clone(&buffer_pool);

            move || {
                compio::runtime::Runtime::new()
                    .unwrap()
                    .block_on(async move {
                        loop {
                            let Some(cmd) = cmd_rx.recv().await else {
                                break;
                            };

                            match cmd {
                                Command::NewSocket((port, family)) => {
                                    let udp_socket = compio::net::UdpSocket::from_std(
                                        make_wildcard_socket(family, port).unwrap(),
                                    )
                                    .unwrap();
                                    let fd = udp_socket.to_shared_fd();

                                    let task = compio::runtime::spawn({
                                        let buffer_pool = Arc::clone(&buffer_pool);
                                        let event_tx = event_tx.clone();

                                        async move {
                                            loop {
                                                let buffer = Buffer(buffer_pool.pull_owned());

                                                let ((length, from), buffer) =
                                                    udp_socket.recv_from(buffer).await.unwrap();

                                                event_tx
                                                    .send(Event::Received(Received {
                                                        port,
                                                        from,
                                                        packet: Packet {
                                                            inner: buffer,
                                                            length,
                                                        },
                                                    }))
                                                    .await
                                                    .unwrap()
                                            }
                                        }
                                    });

                                    event_tx
                                        .send(Event::NewSocket(port, family, task, fd))
                                        .await;
                                }
                                Command::SendPacket {
                                    fd,
                                    dest,
                                    mut packet,
                                } => {
                                    packet.inner.0.truncate(packet.length);

                                    compio::runtime::spawn(compio::runtime::submit(
                                        compio::driver::op::SendTo::new(
                                            fd,
                                            packet.inner,
                                            dest.into(),
                                        ),
                                    ))
                                    .detach();
                                }
                                Command::SendVec { fd, dest, packet } => {
                                    compio::runtime::spawn(compio::runtime::submit(
                                        compio::driver::op::SendTo::new(fd, packet, dest.into()),
                                    ))
                                    .detach();
                                }
                            }
                        }
                    })
            }
        });

        Self {
            buffer_pool,
            inner: Default::default(),
            cmd_tx,
            event_rx,
        }
    }

    /// Attempts to bind a new socket on the given port and address family.
    ///
    /// Fails if the channel is:
    ///  - full (not expected to happen in production)
    ///  - disconnected (we can't operate without the [`mio`] worker thread)
    pub fn bind(&mut self, port: u16, address_family: AddressFamily) -> Result<()> {
        self.cmd_tx
            .try_send(Command::NewSocket((port, address_family)))?;

        Ok(())
    }

    /// Attempts to unbind a socket on the given port and address family.
    ///
    /// Fails if the channel is:
    ///  - full (not expected to happen in production)
    ///  - disconnected (we can't operate without the [`mio`] worker thread)
    pub fn unbind(&mut self, port: u16, address_family: AddressFamily) -> Result<()> {
        // let token = token_from_port_and_address_family(port, address_family);

        // let Some(socket) = self.inner.remove(&token) else {
        //     return Ok(());
        // };

        // self.cmd_tx.try_send(Command::DisposeSocket(socket))?;

        Ok(())
    }

    pub fn send(&mut self, port: u16, dest: SocketAddr, packet: Packet) -> io::Result<()> {
        let address_family = match dest {
            SocketAddr::V4(_) => AddressFamily::V4,
            SocketAddr::V6(_) => AddressFamily::V6,
        };

        let (_, fd) = self.inner.get(&(port, address_family)).unwrap();

        self.cmd_tx
            .try_send(Command::SendPacket {
                fd: fd.clone(),
                dest,
                packet,
            })
            .unwrap();

        Ok(())
    }

    pub fn send_vec(&mut self, port: u16, dest: SocketAddr, packet: Vec<u8>) -> io::Result<()> {
        let address_family = match dest {
            SocketAddr::V4(_) => AddressFamily::V4,
            SocketAddr::V6(_) => AddressFamily::V6,
        };

        let (_, fd) = self.inner.get(&(port, address_family)).unwrap();

        self.cmd_tx
            .try_send(Command::SendVec {
                fd: fd.clone(),
                dest,
                packet,
            })
            .unwrap();

        Ok(())
    }

    pub fn poll_recv_from(&mut self, cx: &mut Context<'_>) -> Poll<Result<Received, Error>> {
        loop {
            match ready!(self.event_rx.poll_recv(cx)) {
                Some(Event::NewSocket(port, af, task, fd)) => {
                    self.inner.insert((port, af), (task, fd));
                    continue;
                }
                Some(Event::Received(received)) => return Poll::Ready(Ok(received)),
                Some(Event::Crashed(error)) => {
                    return Poll::Ready(Err(Error::MioTaskCrashed(error)));
                }
                None => {
                    panic!("must not poll `Sockets` after mio task exited")
                }
            };
        }
    }
}

/// A packet read from a socket.
#[derive(Debug)]
pub struct Received {
    pub port: u16,
    pub from: SocketAddr,
    pub packet: Packet,
}

#[derive(Debug)]
pub enum Error {
    Io(io::Error),
    MioTaskCrashed(anyhow::Error),
}

enum Command {
    NewSocket((u16, AddressFamily)),
    SendPacket {
        fd: SharedFd<Socket>,
        dest: SocketAddr,
        packet: Packet,
    },
    SendVec {
        fd: SharedFd<Socket>,
        dest: SocketAddr,
        packet: Vec<u8>,
    },
}

enum Event {
    NewSocket(
        u16,
        AddressFamily,
        Task<Result<(), Box<dyn Any + Send>>>,
        SharedFd<Socket>,
    ),
    Received(Received),
    Crashed(anyhow::Error),
}

fn not_connected(port: u16, address_family: AddressFamily) -> io::Error {
    io::Error::new(
        io::ErrorKind::NotConnected,
        format!("No socket for port {port} on address family {address_family}"),
    )
}

/// Creates an [std::net::UdpSocket] via the [socket2] library that is configured for our needs.
///
/// Most importantly, this sets the `IPV6_V6ONLY` flag to ensure we disallow IP4-mapped IPv6 addresses and can bind to IP4 and IP6 addresses on the same port.
fn make_wildcard_socket(family: AddressFamily, port: u16) -> io::Result<std::net::UdpSocket> {
    use socket2::*;

    let domain = match family {
        AddressFamily::V4 => Domain::IPV4,
        AddressFamily::V6 => Domain::IPV6,
    };
    let address = match family {
        AddressFamily::V4 => IpAddr::from(Ipv4Addr::UNSPECIFIED),
        AddressFamily::V6 => IpAddr::from(Ipv6Addr::UNSPECIFIED),
    };

    let socket = Socket::new(domain, Type::DGRAM, Some(Protocol::UDP))?;
    if family == AddressFamily::V6 {
        socket.set_only_v6(true)?;
    }

    socket.set_nonblocking(true)?;
    socket.bind(&SockAddr::from(SocketAddr::new(address, port)))?;

    Ok(socket.into())
}

struct Buffer(SpinLockOwnedReusable<Vec<u8>>);

impl SetBufInit for Buffer {
    unsafe fn set_buf_init(&mut self, len: usize) {
        self.0.set_buf_init(len);
    }
}

unsafe impl IoBuf for Buffer {
    fn as_buf_ptr(&self) -> *const u8 {
        self.0.as_buf_ptr()
    }

    fn buf_len(&self) -> usize {
        self.0.buf_len()
    }

    fn buf_capacity(&self) -> usize {
        self.0.buf_capacity()
    }
}

unsafe impl IoBufMut for Buffer {
    fn as_buf_mut_ptr(&mut self) -> *mut u8 {
        self.0.as_buf_mut_ptr()
    }
}
