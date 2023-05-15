use anyhow::{Context, Result};
use futures::channel::mpsc;
use futures::{FutureExt, SinkExt, StreamExt};
use relay::{AllocationId, Command, Server, Sleep};
use std::collections::HashMap;
use std::convert::Infallible;
use std::error::Error;
use std::io;
use std::net::{Ipv4Addr, SocketAddr, SocketAddrV4};
use std::pin::Pin;
use std::str::FromStr;
use std::task::{ready, Poll};
use std::time::Instant;
use tokio::io::ReadBuf;
use tokio::net::UdpSocket;
use tokio::task;
use tracing::level_filters::LevelFilter;
use tracing::Level;
use tracing_subscriber::EnvFilter;

const MAX_UDP_SIZE: usize = 65536;

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::builder()
                .with_default_directive(LevelFilter::INFO.into())
                .from_env_lossy(),
        )
        .init();

    let public_ip4_addr = parse_env_var::<Ipv4Addr>("RELAY_PUBLIC_IP4_ADDR")?;
    let listen_ip4_addr = parse_env_var::<Ipv4Addr>("RELAY_LISTEN_IP4_ADDR")?;

    let mut recv_buf = [0u8; MAX_UDP_SIZE];

    let mut eventloop = Eventloop::new(
        public_ip4_addr,
        listen_ip4_addr,
        ReadBuf::new(&mut recv_buf),
    )
    .await?;

    tracing::info!("Listening for incoming traffic on UDP port 3478");

    futures::future::poll_fn(|cx| eventloop.poll(cx))
        .await
        .context("event loop failed")?;

    Ok(())
}

struct Eventloop<'a> {
    ip4_socket: UdpSocket,
    listen_ip4_address: Ipv4Addr,
    server: Server,
    allocations: HashMap<AllocationId, task::JoinHandle<()>>,
    relay_data_sender: mpsc::Sender<(Vec<u8>, SocketAddr, AllocationId)>,
    relay_data_receiver: mpsc::Receiver<(Vec<u8>, SocketAddr, AllocationId)>,
    sleep: Sleep,
    recv_buf: ReadBuf<'a>,
}

impl<'a> Eventloop<'a> {
    async fn new(
        public_ip4_address: Ipv4Addr,
        listen_ip4_address: Ipv4Addr,
        recv_buf: ReadBuf<'a>,
    ) -> io::Result<Eventloop<'a>> {
        let (sender, receiver) = mpsc::channel(1);

        Ok(Self {
            ip4_socket: UdpSocket::bind((listen_ip4_address, 3478)).await?,
            listen_ip4_address,
            server: Server::new(SocketAddrV4::new(public_ip4_address, 3478)),
            allocations: Default::default(),
            relay_data_sender: sender,
            relay_data_receiver: receiver,
            sleep: Sleep::default(),
            recv_buf,
        })
    }

    fn poll(&mut self, cx: &mut std::task::Context<'_>) -> Poll<Result<()>> {
        loop {
            // Priority 1: Execute the pending commands of the server.
            // This may require us to be able to send data into the socket.
            // If the socket is not ready, don't poll new commands from the server.
            ready!(self.ip4_socket.poll_send_ready(cx)?);

            if let Some(next_command) = self.server.next_command() {
                match next_command {
                    Command::SendMessage { payload, recipient } => {
                        if tracing::enabled!(target: "wire", Level::TRACE) {
                            let hex_bytes = hex::encode(&payload);
                            tracing::trace!(target: "wire", r#"Output::SendMessage("{recipient}","{hex_bytes}")"#);
                        }

                        let bytes_sent = self
                            .ip4_socket
                            .try_send_to(&payload, recipient)
                            .expect("TODO: error handling");

                        debug_assert_eq!(bytes_sent, payload.len());
                    }
                    Command::AllocateAddresses { id, port } => {
                        self.allocations.insert(id, tokio::spawn({
                            let sender = self.relay_data_sender.clone();
                            let listen_ip4_addr = self.listen_ip4_address;

                            async move {
                                let Err(e) = forward_incoming_relay_data(sender, id, listen_ip4_addr, port).await else {
                                    unreachable!()
                                };

                                // TODO: Do we need to clean this up in the server? It will eventually timeout if not refreshed.
                                tracing::warn!("Allocation task for {id} failed: {e}");
                            }
                        }));
                    }
                    Command::FreeAddresses { id } => {
                        let Some(task) = self.allocations.remove(&id) else {
                            tracing::debug!("Unknown allocation {id}");
                            continue;
                        };

                        tracing::info!("Freeing addresses of allocation {id}");
                        task.abort();
                    }
                    Command::Wake { deadline } => {
                        Pin::new(&mut self.sleep).reset(deadline);
                    }
                }

                continue; // Attempt to process more commands.
            }

            // Priority 2: Handle time-sensitive tasks:
            if self.sleep.poll_unpin(cx).is_ready() {
                self.server.handle_deadline_reached(Instant::now());
                continue; // Handle potentially new commands.
            }

            // Priority 3: Handle relayed data (we prioritize latency for existing allocations over making new ones)
            if let Poll::Ready(Some((data, sender, allocation))) =
                self.relay_data_receiver.poll_next_unpin(cx)
            {
                self.server.handle_relay_input(&data, sender, allocation);
                continue; // Handle potentially new commands.
            }

            // Priority 4: Accept new allocations / answer STUN requests etc

            if let Poll::Ready(sender) = self.ip4_socket.poll_recv_from(cx, &mut self.recv_buf)? {
                self.server
                    .handle_client_input(self.recv_buf.filled(), sender, Instant::now())?;
                continue; // Handle potentially new commands.
            }

            return Poll::Pending;
        }
    }
}

fn parse_env_var<T>(key: &str) -> Result<T>
where
    T: FromStr,
    T::Err: Error + Send + Sync + 'static,
{
    let addr = std::env::var(key)
        .with_context(|| format!("`{key}` env variable is unset"))?
        .parse()
        .with_context(|| format!("failed to parse {key} env variable"))?;

    Ok(addr)
}

async fn forward_incoming_relay_data(
    mut relayed_data_sender: mpsc::Sender<(Vec<u8>, SocketAddr, AllocationId)>,
    id: AllocationId,
    listen_ip4_addr: Ipv4Addr,
    port: u16,
) -> Result<Infallible> {
    let socket = UdpSocket::bind((listen_ip4_addr, port)).await?;
    let mut recv_buf = [0u8; MAX_UDP_SIZE];

    let ip4 = socket.local_addr()?;

    tracing::info!("Listening for relayed data on {ip4} for allocation {id}");

    loop {
        let (length, sender) = socket.recv_from(&mut recv_buf).await?;
        let data = recv_buf[..length].to_vec();

        relayed_data_sender.send((data, sender, id)).await?;
    }
}
