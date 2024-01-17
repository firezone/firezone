use std::{
    future::poll_fn,
    net::Ipv4Addr,
    str::FromStr,
    task::{Context, Poll},
    time::{Duration, Instant},
};

use anyhow::{bail, Context as _, Result};
use boringtun::x25519::{PublicKey, StaticSecret};
use firezone_connection::{
    Answer, ClientConnectionPool, ConnectionPool, Credentials, IpPacket, Offer,
    ServerConnectionPool,
};
use futures::{future::BoxFuture, FutureExt};
use pnet_packet::{ip::IpNextHeaderProtocols, ipv4::Ipv4Packet};
use redis::AsyncCommands;
use secrecy::{ExposeSecret as _, Secret};
use tokio::{io::ReadBuf, net::UdpSocket};
use tracing_subscriber::EnvFilter;

const MAX_UDP_SIZE: usize = (1 << 16) - 1;

#[tokio::main]
async fn main() -> Result<()> {
    tokio::time::sleep(Duration::from_secs(1)).await; // Until redis is up.

    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::builder().parse("info,boringtun=debug,str0m=debug")?)
        .init();

    let role = std::env::var("ROLE")
        .context("Missing ROLE env variable")?
        .parse::<Role>()?;

    let listen_addr = system_info::NetworkInterfaces::new()
        .context("Failed to get network interfaces")?
        .iter()
        .find_map(|i| i.addresses().find(|a| !a.ip.is_loopback()))
        .context("Failed to find interface with non-loopback address")?
        .ip
        .to_std();

    tracing::info!(%listen_addr);

    let redis_host = std::env::var("REDIS_HOST").context("Missing REDIS_HOST env var")?;

    let redis_client = redis::Client::open(format!("redis://{redis_host}:6379"))?;
    let mut redis_connection = redis_client.get_async_connection().await?;

    let socket = UdpSocket::bind((listen_addr, 0)).await?;
    let socket_addr = socket.local_addr()?;
    let private_key = StaticSecret::random_from_rng(rand::thread_rng());
    let public_key = PublicKey::from(&private_key);

    // The source and dst of our dummy IP packet that we send via the wireguard tunnel.
    let source = Ipv4Addr::new(172, 16, 0, 1);
    let dst = Ipv4Addr::new(10, 0, 0, 1);

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
                .await
                .context("Failed to push offer")?;

            let answer = redis_connection
                .blpop::<_, (String, wire::Answer)>("answers", 10.0)
                .await
                .context("Failed to pop answer")?
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

            let ping_body = rand::random::<[u8; 32]>();
            let mut start = Instant::now();

            loop {
                tokio::select! {
                    event = poll_fn(|cx| eventloop.poll(cx)) => {
                        match event? {
                            Event::Incoming { conn, packet } => {
                                anyhow::ensure!(conn == 1);
                                anyhow::ensure!(packet == IpPacket::Ipv4(ip4_udp_ping_packet(dst, source, packet.udp_payload()))); // Expect the listener to flip src and dst

                                let rtt = start.elapsed();

                                tracing::info!("RTT is {rtt:?}");

                                return Ok(())
                            }
                            Event::SignalIceCandidate { conn, candidate } => {
                                redis_connection
                                    .rpush("dialer_candidates", wire::Candidate { conn, candidate })
                                    .await
                                    .context("Failed to push candidate")?;
                            }
                            Event::ConnectionEstablished { conn } => {
                                start = Instant::now();
                                eventloop.send_to(conn, ip4_udp_ping_packet(source, dst, &ping_body).into())?;
                            }
                        }
                    }

                    response = redis_connection.blpop::<_, Option<(String, wire::Candidate)>>("listener_candidates", 1.0) => {
                        let Ok(Some((_, wire::Candidate { conn, candidate }))) = response else {
                            continue;
                        };
                        eventloop.pool.add_remote_candidate(conn, candidate);
                    }
                }
            }
        }
        Role::Listener => {
            let mut pool = ServerConnectionPool::<u64>::new(private_key);
            pool.add_local_interface(socket_addr);

            let offer = redis_connection
                .blpop::<_, (String, wire::Offer)>("offers", 10.0)
                .await
                .context("Failed to pop offer")?
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
                .await
                .context("Failed to push answer")?;

            let mut eventloop = Eventloop::new(socket, pool);

            loop {
                tokio::select! {
                    event = poll_fn(|cx| eventloop.poll(cx)) => {
                        match event? {
                            Event::Incoming { conn, packet } => {
                                eventloop.send_to(conn, ip4_udp_ping_packet(dst, source, packet.udp_payload()).into())?;
                            }
                            Event::SignalIceCandidate { conn, candidate } => {
                                redis_connection
                                    .rpush("listener_candidates", wire::Candidate { conn, candidate })
                                    .await
                                    .context("Failed to push candidate")?;
                            }
                            Event::ConnectionEstablished { .. } => { }
                        }
                    }

                    response = redis_connection.blpop::<_, Option<(String, wire::Candidate)>>("dialer_candidates", 1.0) => {
                        let Ok(Some((_, wire::Candidate { conn, candidate }))) = response else {
                            continue;
                        };
                        eventloop.pool.add_remote_candidate(conn, candidate);
                    }
                }
            }
        }
    };
}

fn ip4_udp_ping_packet(source: Ipv4Addr, dst: Ipv4Addr, body: &[u8]) -> Ipv4Packet<'static> {
    assert_eq!(body.len(), 32);

    let mut packet_buffer = [0u8; 60];

    let mut ip4_header =
        pnet_packet::ipv4::MutableIpv4Packet::new(&mut packet_buffer[..20]).unwrap();
    ip4_header.set_version(4);
    ip4_header.set_source(source);
    ip4_header.set_destination(dst);
    ip4_header.set_next_level_protocol(IpNextHeaderProtocols::Udp);
    ip4_header.set_ttl(10);
    ip4_header.set_total_length(20 + 8 + 32); // IP4 + UDP + payload.
    ip4_header.set_header_length(5); // Length is in number of 32bit words, i.e. 5 means 20 bytes.
    ip4_header.set_checksum(pnet_packet::ipv4::checksum(&ip4_header.to_immutable()));

    let mut udp_header =
        pnet_packet::udp::MutableUdpPacket::new(&mut packet_buffer[20..28]).unwrap();
    udp_header.set_source(9999);
    udp_header.set_destination(9999);
    udp_header.set_length(8 + 32);
    udp_header.set_checksum(0); // Not necessary for IPv4, let's keep it simple.

    packet_buffer[28..60].copy_from_slice(body);

    Ipv4Packet::owned(packet_buffer.to_vec()).unwrap()
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

    fn send_to(&mut self, id: u64, packet: IpPacket<'_>) -> Result<()> {
        let Some((addr, msg)) = self.pool.encapsulate(id, packet)? else {
            return Ok(());
        };

        tracing::trace!(target = "wire::out", to = %addr, packet = %hex::encode(msg));

        self.socket.try_send_to(msg, addr)?;

        Ok(())
    }

    fn poll(&mut self, cx: &mut Context<'_>) -> Poll<Result<Event>> {
        while let Some(transmit) = self.pool.poll_transmit() {
            tracing::trace!(target = "wire::out", to = %transmit.dst, packet = %hex::encode(&transmit.payload));

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

        if let Poll::Ready(instant) = self.timeout.poll_unpin(cx) {
            self.pool.handle_timeout(instant);
            if let Some(timeout) = self.pool.poll_timeout() {
                self.timeout = sleep_until(timeout).boxed();
            }

            cx.waker().wake_by_ref();
            return Poll::Pending;
        }

        let mut read_buf = ReadBuf::new(self.read_buffer.as_mut());
        if let Poll::Ready(from) = self.socket.poll_recv_from(cx, &mut read_buf)? {
            let packet = read_buf.filled();

            tracing::trace!(target = "wire::in", %from, packet = %hex::encode(packet));

            if let Some((conn, packet)) = self.pool.decapsulate(
                self.socket.local_addr()?,
                from,
                packet,
                Instant::now(),
                self.write_buffer.as_mut(),
            )? {
                return Poll::Ready(Ok(Event::Incoming {
                    conn,
                    packet: packet.to_owned(),
                }));
            }
        }

        Poll::Pending
    }
}

enum Event {
    Incoming {
        conn: u64,
        packet: IpPacket<'static>,
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
