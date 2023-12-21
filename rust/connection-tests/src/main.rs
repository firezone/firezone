use std::{
    future::poll_fn,
    net::IpAddr,
    str::FromStr,
    task::{Context, Poll},
    time::Instant,
};

use anyhow::{bail, Context as _, Result};
use boringtun::x25519::{PublicKey, StaticSecret};
use firezone_connection::{
    Answer, ClientConnectionPool, ConnectionPool, Credentials, Offer, ServerConnectionPool,
};
use futures::{future::BoxFuture, FutureExt};
use redis::AsyncCommands;
use secrecy::{ExposeSecret as _, Secret};
use tokio::{io::ReadBuf, net::UdpSocket};
use tracing_subscriber::EnvFilter;

const MAX_UDP_SIZE: usize = (1 << 16) - 1;

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::builder().parse("debug")?)
        .init();

    let role = std::env::var("ROLE")
        .context("Missing ROLE env variable")?
        .parse::<Role>()?;
    let listen_addr = std::env::var("LISTEN_ADDR")
        .context("Missing LISTEN_ADDR env var")?
        .parse::<IpAddr>()?;

    let redis_client = redis::Client::open("redis://redis:6379")?;
    let mut redis_connection = redis_client.get_async_connection().await?;

    let socket = UdpSocket::bind((listen_addr, 0)).await?;
    let socket_addr = socket.local_addr()?;
    let private_key = StaticSecret::random_from_rng(&mut rand::thread_rng());
    let public_key = PublicKey::from(&private_key);

    match role {
        Role::Dialer => {
            let mut pool = ClientConnectionPool::<u64>::new(private_key);
            pool.add_local_interface(socket_addr);

            let offer = pool.new_connection(1, vec![], vec![]);

            redis_connection
                .rpush(
                    "offers",
                    wire::Offer {
                        session_key: *offer.session_key.expose_secret(),
                        username: offer.credentials.username,
                        password: offer.credentials.password,
                        public_key: public_key.to_bytes(),
                    },
                )
                .await?;

            let answer = redis_connection
                .blpop::<_, (String, wire::Answer)>("answers", 10)
                .await?
                .1;

            pool.accept_answer(
                1,
                answer.public_key.into(),
                Answer {
                    credentials: Credentials {
                        username: answer.username,
                        password: answer.password,
                    },
                },
            );

            let mut eventloop = Eventloop::new(socket, pool);

            let ping = rand::random::<[u8; 32]>();
            let mut start = Instant::now();

            loop {
                tokio::select! {
                    event = poll_fn(|cx| eventloop.poll(cx)) => {
                        match event? {
                            Event::Incoming { conn, packet, from } => {
                                println!("Received {} bytes from {from} on connection {conn}", packet.len());

                                anyhow::ensure!(conn == 1);
                                anyhow::ensure!(packet == &ping);

                                let rtt = start.elapsed();

                                println!("RTT is {rtt:?}");

                                return Ok(())
                            }
                            Event::SignalIceCandidate { conn, candidate } => {
                                redis_connection
                                    .rpush("dialer_candidates", wire::Candidate { conn, candidate })
                                    .await?;
                            }
                            Event::ConnectionEstablished { conn } => {
                                start = Instant::now();
                                eventloop.send_to(conn, &ping)?;
                            }
                        }
                    }

                    response = redis_connection.blpop::<_, (String, wire::Candidate)>("listener_candidates", 10) => {
                        let (_, wire::Candidate { conn, candidate }) = response?;
                        eventloop.pool.add_remote_candidate(conn, candidate);
                    }
                }
            }
        }
        Role::Listener => {
            let mut pool = ServerConnectionPool::<u64>::new(private_key);
            pool.add_local_interface(socket_addr);

            let offer = redis_connection
                .blpop::<_, (String, wire::Offer)>("offers", 10)
                .await?
                .1;

            let answer = pool.accept_connection(
                1,
                Offer {
                    session_key: Secret::new(offer.session_key),
                    credentials: Credentials {
                        username: offer.username,
                        password: offer.password,
                    },
                },
                offer.public_key.into(),
                vec![],
                vec![],
            );

            redis_connection
                .rpush(
                    "answers",
                    wire::Answer {
                        public_key: public_key.to_bytes(),
                        username: answer.credentials.username,
                        password: answer.credentials.password,
                    },
                )
                .await?;

            let mut eventloop = Eventloop::new(socket, pool);

            loop {
                tokio::select! {
                    event = poll_fn(|cx| eventloop.poll(cx)) => {
                        match event? {
                            Event::Incoming { conn, packet, from } => {
                                println!("Received {} bytes from {from} on connection {conn}", packet.len());

                                eventloop.send_to(conn, &packet)?;
                            }
                            Event::SignalIceCandidate { conn, candidate } => {
                                redis_connection
                                    .rpush("listener_candidates", wire::Candidate { conn, candidate })
                                    .await?;
                            }
                            Event::ConnectionEstablished { .. } => { }
                        }
                    }

                    response = redis_connection.blpop::<_, (String, wire::Candidate)>("dialer_candidates", 10) => {
                        let (_, wire::Candidate { conn, candidate }) = response?;
                        eventloop.pool.add_remote_candidate(conn, candidate);
                    }
                }
            }
        }
    };
}

mod wire {
    #[derive(
        serde::Serialize,
        serde::Deserialize,
        redis_macros::FromRedisValue,
        redis_macros::ToRedisArgs,
    )]
    pub struct Offer {
        #[serde(with = "serde_hex::SerHex::<serde_hex::StrictPfx>")]
        pub session_key: [u8; 32],
        #[serde(with = "serde_hex::SerHex::<serde_hex::StrictPfx>")]
        pub public_key: [u8; 32],
        pub username: String,
        pub password: String,
    }

    #[derive(
        serde::Serialize,
        serde::Deserialize,
        redis_macros::FromRedisValue,
        redis_macros::ToRedisArgs,
    )]
    pub struct Answer {
        #[serde(with = "serde_hex::SerHex::<serde_hex::StrictPfx>")]
        pub public_key: [u8; 32],
        pub username: String,
        pub password: String,
    }

    #[derive(
        serde::Serialize,
        serde::Deserialize,
        redis_macros::FromRedisValue,
        redis_macros::ToRedisArgs,
    )]
    pub struct Candidate {
        pub conn: u64,
        pub candidate: String,
    }
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

    fn send_to(&mut self, id: u64, msg: &[u8]) -> Result<()> {
        let Some((addr, msg)) = self.pool.encapsulate(id, msg)? else {
            return Ok(());
        };

        self.socket.try_send_to(msg, addr)?;

        Ok(())
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
