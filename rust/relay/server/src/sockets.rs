use anyhow::{Result, bail};
use std::{
    borrow::Cow,
    collections::{BTreeSet, HashMap, VecDeque},
    io,
    net::{IpAddr, SocketAddr},
    task::{Context, Poll, Waker},
    time::Duration,
};
use stun_codec::rfc8656::attributes::AddressFamily;
use tokio::sync::mpsc;

/// A dynamic collection of UDP sockets, listening on all interfaces of a particular IP family.
///
/// Internally, [`Sockets`] is powered by [`mio`] and uses a separate thread to poll for readiness of a socket.
/// Whenever a socket is ready for reading, we send a message to the foreground task which then reads from the socket until it emits [`io::ErrorKind::WouldBlock`].
pub struct Sockets {
    /// All currently active sockets.
    ///
    /// [`mio`] operates with a concept of [`mio::Token`]s so we need to store our sockets indexed by those tokens.
    inner: HashMap<mio::Token, mio::net::UdpSocket>,

    /// Which sockets we should still be reading from.
    ///
    /// [`mio`] sends us a signal when a socket is ready for reading.
    /// We must read from it until it returns [`io::ErrorKind::WouldBlock`].
    ///
    /// We store each socket with the number of packets that we read.
    /// This allows us to always prioritize a socket that we haven't read any packets
    /// from but is ready.
    current_ready_sockets: BTreeSet<(usize, mio::Token)>,

    /// If we are waiting to flush packets, this waker tracks the suspended task.
    flush_waker: Option<Waker>,

    cmd_tx: mpsc::Sender<Command>,
    event_rx: mpsc::Receiver<Event>,

    pending_packets: VecDeque<PendingPacket>,
}

/// A packet that could not be sent and is buffered until the socket is ready again.
struct PendingPacket {
    src: u16,
    dst: SocketAddr,
    payload: Vec<u8>,
}

impl Default for Sockets {
    fn default() -> Self {
        Self::new()
    }
}

impl Sockets {
    pub fn new() -> Self {
        let (cmd_tx, cmd_rx) = mpsc::channel(1_000_000); // Commands are really small and this channel should really never fill up unless we have serious problems in the "mio" worker thread.
        let (event_tx, event_rx) = mpsc::channel(1_024);

        std::thread::spawn(move || {
            if let Err(e) = mio_worker_task(event_tx.clone(), cmd_rx) {
                let _ = event_tx.blocking_send(Event::Crashed(e));
            }
        });

        Self {
            inner: Default::default(),
            cmd_tx,
            event_rx,
            current_ready_sockets: Default::default(),
            pending_packets: Default::default(),
            flush_waker: None,
        }
    }

    /// Attempts to bind a new socket on the given port and address.
    ///
    /// Fails if the channel is:
    ///  - full (not expected to happen in production)
    ///  - disconnected (we can't operate without the [`mio`] worker thread)
    pub fn bind(&mut self, port: u16, bind_addr: IpAddr) -> Result<()> {
        self.cmd_tx
            .try_send(Command::NewSocket { port, bind_addr })?;

        Ok(())
    }

    /// Attempts to unbind a socket on the given port and address family.
    ///
    /// Fails if the channel is:
    ///  - full (not expected to happen in production)
    ///  - disconnected (we can't operate without the [`mio`] worker thread)
    pub fn unbind(&mut self, port: u16, address_family: AddressFamily) -> Result<()> {
        let token = token_from_port_and_address_family(port, address_family);

        let Some(socket) = self.inner.remove(&token) else {
            return Ok(());
        };

        self.cmd_tx.try_send(Command::DisposeSocket(socket))?;

        Ok(())
    }

    /// Flush all buffered packets.
    pub fn flush(&mut self, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        while let Some(packet) = self.pending_packets.pop_front() {
            match self.try_send_internal(packet.src, packet.dst, &packet.payload) {
                Ok(()) => continue,
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => {
                    self.flush_waker = Some(cx.waker().clone());
                    self.pending_packets.push_front(packet);

                    return Poll::Pending;
                }
                Err(e) => return Poll::Ready(Err(e)),
            };
        }

        Poll::Ready(Ok(()))
    }

    pub fn try_send(&mut self, port: u16, dest: SocketAddr, msg: Cow<'_, [u8]>) -> io::Result<()> {
        match self.try_send_internal(port, dest, msg.as_ref()) {
            Ok(()) => Ok(()),
            Err(e) if e.kind() == io::ErrorKind::WouldBlock => {
                self.pending_packets.push_back(PendingPacket {
                    src: port,
                    dst: dest,
                    payload: msg.into_owned(),
                });

                Ok(())
            }
            Err(e) => Err(e),
        }
    }

    fn try_send_internal(&mut self, port: u16, dest: SocketAddr, msg: &[u8]) -> io::Result<()> {
        let address_family = match dest {
            SocketAddr::V4(_) => AddressFamily::V4,
            SocketAddr::V6(_) => AddressFamily::V6,
        };
        let token = token_from_port_and_address_family(port, address_family);

        let socket = self
            .inner
            .get(&token)
            .ok_or_else(|| not_connected(port, address_family))?;

        let num_sent = socket.send_to(msg, dest)?;

        debug_assert_eq!(num_sent, msg.len());

        Ok(())
    }

    pub fn poll_recv_from<'b>(
        &mut self,
        buf: &'b mut [u8],
        cx: &mut Context<'_>,
    ) -> Poll<Result<Received<'b>, Error>> {
        loop {
            match self.event_rx.poll_recv(cx) {
                Poll::Ready(Some(Event::NewSocket(token, socket))) => {
                    self.inner.insert(token, socket);
                    continue;
                }
                Poll::Ready(Some(Event::SocketReady {
                    token,
                    readable,
                    writeable,
                })) => {
                    if readable {
                        self.current_ready_sockets.insert((0, token));
                    }

                    if writeable && let Some(waker) = self.flush_waker.take() {
                        waker.wake();
                    }

                    continue;
                }
                Poll::Ready(Some(Event::Crashed(error))) => {
                    return Poll::Ready(Err(Error::MioTaskCrashed(error)));
                }
                Poll::Ready(None) => {
                    panic!("must not poll `Sockets` after mio task exited")
                }
                Poll::Pending => {}
            }

            // Read from all sockets in order of least packets read so far.
            while let Some((num_packets, current)) = self.current_ready_sockets.pop_first() {
                let Some(socket) = self.inner.get(&current) else {
                    continue;
                };

                let (num_bytes, from) = match socket.recv_from(buf) {
                    Ok(ok) => ok,
                    Err(e) if e.kind() == io::ErrorKind::WouldBlock => continue,
                    Err(e) => return Poll::Ready(Err(Error::Io(e))),
                };

                // Bump the number of packets and return.
                self.current_ready_sockets
                    .insert((num_packets + 1, current));

                let (port, _) = token_to_port_and_address_family(current);

                return Poll::Ready(Ok(Received {
                    port,
                    from,
                    packet: &buf[..num_bytes],
                }));
            }

            return Poll::Pending; // This is okay because we only get here if `event_rx` returned pending.
        }
    }
}

/// A packet read from a socket.
#[derive(Debug)]
pub struct Received<'a> {
    pub port: u16,
    pub from: SocketAddr,
    pub packet: &'a [u8],
}

#[derive(Debug)]
pub enum Error {
    Io(io::Error),
    MioTaskCrashed(anyhow::Error),
}

enum Command {
    NewSocket { port: u16, bind_addr: IpAddr },
    DisposeSocket(mio::net::UdpSocket),
}

enum Event {
    NewSocket(mio::Token, mio::net::UdpSocket),
    SocketReady {
        token: mio::Token,
        readable: bool,
        writeable: bool,
    },
    Crashed(anyhow::Error),
}

fn not_connected(port: u16, address_family: AddressFamily) -> io::Error {
    io::Error::new(
        io::ErrorKind::NotConnected,
        format!("No socket for port {port} on address family {address_family}"),
    )
}

/// The [`mio`] worker task which checks for read-readiness on any of our sockets.
///
/// This task is connected with the main eventloop via two channels.
fn mio_worker_task(
    event_tx: mpsc::Sender<Event>,
    mut cmd_rx: mpsc::Receiver<Command>,
) -> Result<()> {
    let mut poll = mio::Poll::new()?;
    let mut events = mio::Events::with_capacity(1024);

    loop {
        // Suspend for up to 1 second to wait for IO events.
        match poll.poll(&mut events, Some(Duration::from_secs(1))) {
            Ok(()) => {}
            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(e.into()),
        };

        // Send all events into the channel, block as necessary.
        for event in events.iter() {
            event_tx.blocking_send(Event::SocketReady {
                token: event.token(),
                readable: event.is_readable(),
                writeable: event.is_writable(),
            })?;
        }

        loop {
            match cmd_rx.try_recv() {
                Err(mpsc::error::TryRecvError::Empty) => break, // Drain all events from the channel until it is empty.

                Ok(Command::NewSocket { port, bind_addr }) => {
                    let mut socket = mio::net::UdpSocket::from_std(make_socket(port, bind_addr)?);
                    let token = token_from_port_and_ip(port, bind_addr);

                    poll.registry().register(
                        &mut socket,
                        token,
                        mio::Interest::READABLE | mio::Interest::WRITABLE,
                    )?;

                    event_tx.blocking_send(Event::NewSocket(token, socket))?;
                }
                Ok(Command::DisposeSocket(mut socket)) => {
                    poll.registry().deregister(&mut socket)?;
                }
                Err(mpsc::error::TryRecvError::Disconnected) => {
                    bail!("Command channel disconnected")
                }
            }
        }
    }
}

/// Encodes a port (u16) and an [`AddressFamily`] into an [`mio::Token`] by flipping the 17th bit of the internal [`usize`] based on the [`AddressFamily`].
fn token_from_port_and_address_family(port: u16, address_family: AddressFamily) -> mio::Token {
    let is_ipv6 = address_family == AddressFamily::V6;

    token_from_port(port, is_ipv6)
}

/// Encodes a port (u16) and an [`IpAddr`] into an [`mio::Token`] by flipping the 17th bit of the internal [`usize`] based on whether the IP is v6.
fn token_from_port_and_ip(port: u16, ip: IpAddr) -> mio::Token {
    let is_ipv6 = ip.is_ipv6();

    token_from_port(port, is_ipv6)
}

fn token_from_port(port: u16, is_ipv6: bool) -> mio::Token {
    let af_bit = (is_ipv6 as usize) << 16;

    let token = port as usize | af_bit;

    mio::Token(token)
}

/// Decodes an [`mio::Token`] into the port and [`AddressFamily`].
fn token_to_port_and_address_family(token: mio::Token) -> (u16, AddressFamily) {
    let port = (token.0 & 0xFFFF) as u16;

    let is_ipv6 = (token.0 >> 16) & 1 != 0;

    let address_family = if is_ipv6 {
        AddressFamily::V6
    } else {
        AddressFamily::V4
    };

    (port, address_family)
}

/// Creates an [std::net::UdpSocket] via the [socket2] library that is configured for our needs.
///
/// Most importantly, this sets the `IPV6_V6ONLY` flag to ensure we disallow IP4-mapped IPv6 addresses and can bind to IP4 and IP6 addresses on the same port.
fn make_socket(port: u16, bind_addr: IpAddr) -> io::Result<std::net::UdpSocket> {
    use socket2::*;

    let (domain, is_ipv6) = match bind_addr {
        IpAddr::V4(_) => (Domain::IPV4, false),
        IpAddr::V6(_) => (Domain::IPV6, true),
    };

    let socket = Socket::new(domain, Type::DGRAM, Some(Protocol::UDP))?;
    if is_ipv6 {
        socket.set_only_v6(true)?;
    }

    socket.set_nonblocking(true)?;
    socket.bind(&SockAddr::from(SocketAddr::new(bind_addr, port)))?;

    Ok(socket.into())
}
