use std::{
    future::poll_fn,
    io,
    net::IpAddr,
    str::FromStr,
    task::{Context, Poll},
    time::Instant,
};

use anyhow::{bail, Context as _, Result};
use boringtun::x25519::StaticSecret;
use firezone_connection::{ClientConnectionPool, ConnectionPool, ServerConnectionPool};
use futures::{future::BoxFuture, FutureExt};
use tokio::{io::ReadBuf, net::UdpSocket};

const MAX_UDP_SIZE: usize = (1 << 16) - 1;

#[tokio::main]
async fn main() -> Result<()> {
    let role = std::env::var("ROLE")
        .context("Missing ROLE env variable")?
        .parse::<Role>()?;
    let listen_addr = std::env::var("LISTEN_ADDR")
        .context("Missing LISTEN_ADDR env var")?
        .parse::<IpAddr>()?;

    let redis_client = redis::Client::open("redis://localhost:6379")?;
    let mut redis_connection = redis_client.get_async_connection().await?;

    let socket = UdpSocket::bind((listen_addr, 0)).await?;
    let socket_addr = socket.local_addr()?;
    let private_key = StaticSecret::random_from_rng(&mut rand::thread_rng());

    match role {
        Role::Dialer => {
            let mut pool = ClientConnectionPool::<u64>::new(private_key);
            pool.add_local_interface(socket_addr);

            let offer = pool.new_connection(1, vec![], vec![]);

            // TODO: Send offer via redis and receive response

            let mut eventloop = Eventloop::new(socket, pool);

            loop {
                // TODO: Select with listening for ice candidates

                match poll_fn(|cx| eventloop.poll(cx)).await? {
                    Event::Incoming { conn, from, packet } => {
                        // TODO: Check if corresponds to pong, measure RTT and exit if successful
                    }
                    Event::SignalIceCandidate { conn, candidate } => {
                        todo!("send candidate to redis")
                    }
                    Event::ConnectionEstablished { conn } => {
                        // TODO: Start timer, send ping
                    }
                }
            }
        }
        Role::Listener => {
            let mut pool = ServerConnectionPool::<u64>::new(private_key);
            pool.add_local_interface(socket_addr);

            // TODO: Handshake via redis here

            let mut eventloop = Eventloop::new(socket, pool);

            loop {
                // TODO: Select with listening for ice candidates

                match poll_fn(|cx| eventloop.poll(cx)).await? {
                    Event::Incoming { conn, from, packet } => {
                        // TODO: Echo back packet
                    }
                    Event::SignalIceCandidate { conn, candidate } => {
                        todo!("send candidate to redis")
                    }
                    Event::ConnectionEstablished { .. } => {}
                }
            }
        }
    };

    Ok(())
}

enum Role {
    Dialer,
    Listener,
}

impl FromStr for Role {
    type Err = anyhow::Error;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "dialer" => Ok(Self::Dialer),
            "listener" => Ok(Self::Listener),
            other => bail!("unknown role: {other}"),
        }
    }
}

struct Eventloop<T> {
    socket: UdpSocket,
    pool: ConnectionPool<T, u64>,
    timeout: BoxFuture<'static, Instant>,
    read_buffer: Box<[u8; MAX_UDP_SIZE]>,
    write_buffer: Box<[u8; MAX_UDP_SIZE]>,
}

impl<T> Eventloop<T> {
    fn new(socket: UdpSocket, pool: ConnectionPool<T, u64>) -> Self {
        Self {
            socket,
            pool,
            timeout: sleep_until(Instant::now()).boxed(),
            read_buffer: Box::new([0u8; MAX_UDP_SIZE]),
            write_buffer: Box::new([0u8; MAX_UDP_SIZE]),
        }
    }

    fn poll(&mut self, cx: &mut Context<'_>) -> Poll<Result<Event>> {
        if let Poll::Ready(instant) = self.timeout.poll_unpin(cx) {
            self.pool.handle_timeout(instant);
            if let Some(timeout) = self.pool.poll_timeout() {
                self.timeout = sleep_until(timeout).boxed();
            }

            cx.waker().wake_by_ref();
            return Poll::Pending;
        }

        while let Some(transmit) = self.pool.poll_transmit() {
            self.socket.try_send_to(&transmit.payload, transmit.dst)?;
        }

        match self.pool.poll_event() {
            Some(firezone_connection::Event::SignalIceCandidate {
                connection,
                candidate,
            }) => {
                return Poll::Ready(Ok(Event::SignalIceCandidate {
                    conn: connection,
                    candidate,
                }))
            }
            Some(firezone_connection::Event::ConnectionEstablished(conn)) => {
                return Poll::Ready(Ok(Event::ConnectionEstablished { conn }))
            }
            None => {}
        }

        let mut read_buf = ReadBuf::new(self.read_buffer.as_mut());
        if let Poll::Ready(from) = self.socket.poll_recv_from(cx, &mut read_buf)? {
            if let Some((conn, ip, packet)) = self.pool.decapsulate(
                self.socket.local_addr()?,
                from,
                read_buf.filled(),
                Instant::now(),
                self.write_buffer.as_mut(),
            )? {
                return Poll::Ready(Ok(Event::Incoming {
                    conn,
                    from: ip,
                    packet: packet.to_vec(),
                }));
            }
        }

        Poll::Pending
    }
}

enum Event {
    Incoming {
        conn: u64,
        from: IpAddr,
        packet: Vec<u8>, // For simplicity, we allocate here
    },
    SignalIceCandidate {
        conn: u64,
        candidate: String,
    },
    ConnectionEstablished {
        conn: u64,
    },
}

async fn sleep_until(deadline: Instant) -> Instant {
    tokio::time::sleep_until(deadline.into()).await;

    deadline
}
