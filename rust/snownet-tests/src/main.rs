use std::{
    future::poll_fn,
    net::{IpAddr, Ipv4Addr, SocketAddr},
    str::FromStr,
    task::{Context, Poll},
    time::Instant,
};

use anyhow::{bail, Context as _, Result};
use boringtun::x25519::{PublicKey, StaticSecret};
use futures::{channel::mpsc, future::BoxFuture, FutureExt, SinkExt, StreamExt};
use pnet_packet::{ip::IpNextHeaderProtocols, ipv4::Ipv4Packet};
use redis::{aio::MultiplexedConnection, AsyncCommands};
use secrecy::{ExposeSecret as _, Secret};
use snownet::{Answer, ClientNode, Credentials, IpPacket, Node, Offer, ServerNode};
use tokio::{io::ReadBuf, net::UdpSocket};
use tracing_subscriber::EnvFilter;

const MAX_UDP_SIZE: usize = (1 << 16) - 1;

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::builder().parse("info,boringtun=debug,str0m=debug,snownet=debug")?,
        )
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

    let stun_server = std::env::var("STUN_SERVER")
        .ok()
        .map(|a| a.parse::<IpAddr>())
        .transpose()
        .context("Failed to parse `STUN_SERVER`")?
        .map(|ip| SocketAddr::new(ip, 3478));
    let turn_server = std::env::var("TURN_SERVER")
        .ok()
        .map(|a| a.parse::<IpAddr>())
        .transpose()
        .context("Failed to parse `TURNERVER`")?
        .map(|ip| {
            (
                SocketAddr::new(ip, 3478),
                "2000000000:client".to_owned(), // TODO: Use different credentials per role.
                "+Qou8TSjw9q3JMnWET7MbFsQh/agwz/LURhpfX7a0hE".to_owned(),
                "firezone".to_owned(),
            )
        });

    tracing::info!(%listen_addr);

    let redis_host = std::env::var("REDIS_HOST").context("Missing REDIS_HOST env var")?;

    let redis_client = redis::Client::open(format!("redis://{redis_host}:6379"))?;
    let mut redis_connection = redis_client.get_multiplexed_async_connection().await?;

    let socket = UdpSocket::bind((listen_addr, 0)).await?;
    let private_key = StaticSecret::random_from_rng(rand::thread_rng());
    let public_key = PublicKey::from(&private_key);

    // The source and dst of our dummy IP packet that we send via the wireguard tunnel.
    let source = Ipv4Addr::new(172, 16, 0, 1);
    let dst = Ipv4Addr::new(10, 0, 0, 1);

    match role {
        Role::Dialer => {
            let mut pool = ClientNode::<u64>::new(private_key, Instant::now());

            let offer = pool.new_connection(
                1,
                stun_server.into_iter().collect(),
                turn_server.into_iter().collect(),
            );

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

            let rx = spawn_candidate_task(redis_connection.clone(), "listener_candidates");

            let mut eventloop = Eventloop::new(socket, pool, rx);

            let ping_body = rand::random::<[u8; 32]>();
            let mut start = Instant::now();

            loop {
                match poll_fn(|cx| eventloop.poll(cx)).await? {
                    Event::Incoming { conn, packet } => {
                        anyhow::ensure!(conn == 1);
                        anyhow::ensure!(
                            packet
                                == IpPacket::Ipv4(ip4_udp_ping_packet(
                                    dst,
                                    source,
                                    packet.udp_payload()
                                ))
                        ); // Expect the listener to flip src and dst

                        let rtt = start.elapsed();

                        tracing::info!("RTT is {rtt:?}");

                        return Ok(());
                    }
                    Event::SignalIceCandidate { conn, candidate } => {
                        redis_connection
                            .rpush("dialer_candidates", wire::Candidate { conn, candidate })
                            .await
                            .context("Failed to push candidate")?;
                    }
                    Event::ConnectionEstablished { conn } => {
                        start = Instant::now();
                        eventloop
                            .send_to(conn, ip4_udp_ping_packet(source, dst, &ping_body).into())?;
                    }
                    Event::ConnectionFailed { conn } => {
                        anyhow::bail!("Failed to establish connection: {conn}");
                    }
                }
            }
        }
        Role::Listener => {
            let mut pool = ServerNode::<u64>::new(private_key, Instant::now());

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
                stun_server.into_iter().collect(),
                turn_server.into_iter().collect(),
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

            let rx = spawn_candidate_task(redis_connection.clone(), "dialer_candidates");

            let mut eventloop = Eventloop::new(socket, pool, rx);

            loop {
                match poll_fn(|cx| eventloop.poll(cx)).await? {
                    Event::Incoming { conn, packet } => {
                        eventloop.send_to(
                            conn,
                            ip4_udp_ping_packet(dst, source, packet.udp_payload()).into(),
                        )?;
                    }
                    Event::SignalIceCandidate { conn, candidate } => {
                        redis_connection
                            .rpush("listener_candidates", wire::Candidate { conn, candidate })
                            .await
                            .context("Failed to push candidate")?;
                    }
                    Event::ConnectionEstablished { .. } => {}
                    Event::ConnectionFailed { conn } => {
                        anyhow::bail!("Failed to establish connection: {conn}");
                    }
                }
            }
        }
    };
}

fn spawn_candidate_task(
    mut conn: MultiplexedConnection,
    topic: &'static str,
) -> mpsc::Receiver<wire::Candidate> {
    let (mut sender, receiver) = mpsc::channel(0);
    tokio::spawn(async move {
        loop {
            let candidate = conn
                .blpop::<_, Option<(String, wire::Candidate)>>(topic, 1.0)
                .await
                .unwrap();

            if let Some((_, candidate)) = candidate {
                sender.send(candidate).await.unwrap();
            }
        }
    });

    receiver
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
        Debug,
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
    pool: Node<T, u64>,
    timeout: BoxFuture<'static, Instant>,
    candidate_rx: mpsc::Receiver<wire::Candidate>,
    read_buffer: Box<[u8; MAX_UDP_SIZE]>,
    write_buffer: Box<[u8; MAX_UDP_SIZE]>,
}

impl<T> Eventloop<T> {
    fn new(
        socket: UdpSocket,
        pool: Node<T, u64>,
        candidate_rx: mpsc::Receiver<wire::Candidate>,
    ) -> Self {
        Self {
            socket,
            pool,
            timeout: sleep_until(Instant::now()).boxed(),
            read_buffer: Box::new([0u8; MAX_UDP_SIZE]),
            write_buffer: Box::new([0u8; MAX_UDP_SIZE]),
            candidate_rx,
        }
    }

    fn send_to(&mut self, id: u64, packet: IpPacket<'_>) -> Result<()> {
        let Some(transmit) = self.pool.encapsulate(id, packet)? else {
            return Ok(());
        };

        tracing::trace!(target = "wire::out", to = %transmit.dst, packet = %hex::encode(&transmit.payload));

        self.socket.try_send_to(&transmit.payload, transmit.dst)?;

        Ok(())
    }

    fn poll(&mut self, cx: &mut Context<'_>) -> Poll<Result<Event>> {
        while let Some(transmit) = self.pool.poll_transmit() {
            tracing::trace!(target = "wire::out", to = %transmit.dst, packet = %hex::encode(&transmit.payload));

            if let Some(src) = transmit.src {
                assert_eq!(src, self.socket.local_addr()?);
            }

            self.socket.try_send_to(&transmit.payload, transmit.dst)?;
        }

        match self.pool.poll_event() {
            Some(snownet::Event::SignalIceCandidate {
                connection,
                candidate,
            }) => {
                return Poll::Ready(Ok(Event::SignalIceCandidate {
                    conn: connection,
                    candidate,
                }))
            }
            Some(snownet::Event::ConnectionEstablished(conn)) => {
                return Poll::Ready(Ok(Event::ConnectionEstablished { conn }))
            }
            Some(snownet::Event::ConnectionFailed(conn)) => {
                return Poll::Ready(Ok(Event::ConnectionFailed { conn }))
            }
            None => {}
        }

        if let Poll::Ready(Some(wire::Candidate { conn, candidate })) =
            self.candidate_rx.poll_next_unpin(cx)
        {
            self.pool.add_remote_candidate(conn, candidate);

            cx.waker().wake_by_ref();
            return Poll::Pending;
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

            cx.waker().wake_by_ref();
            return Poll::Pending;
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
    ConnectionFailed {
        conn: u64,
    },
}

async fn sleep_until(deadline: Instant) -> Instant {
    tokio::time::sleep_until(deadline.into()).await;

    deadline
}
