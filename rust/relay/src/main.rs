use anyhow::{Context, Result};
use futures::channel::mpsc;
use futures::{FutureExt, SinkExt, StreamExt};
use relay::{AllocationId, Command, Server, Sleep, UdpSocket};
use std::collections::{HashMap, VecDeque};
use std::convert::Infallible;
use std::error::Error;
use std::net::{Ipv4Addr, SocketAddr, SocketAddrV4};
use std::pin::Pin;
use std::str::FromStr;
use std::task::Poll;
use std::time::Instant;
use tokio::task;
use tracing::level_filters::LevelFilter;
use tracing::Level;
use tracing_subscriber::EnvFilter;

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

    let mut eventloop = Eventloop::new(public_ip4_addr, listen_ip4_addr).await?;

    tracing::info!("Listening for incoming traffic on UDP port 3478");

    futures::future::poll_fn(|cx| eventloop.poll(cx))
        .await
        .context("event loop failed")?;

    Ok(())
}

struct Eventloop {
    ip4_socket: UdpSocket,
    listen_ip4_address: Ipv4Addr,
    server: Server,
    allocations: HashMap<AllocationId, Allocation>,
    relay_data_sender: mpsc::Sender<(Vec<u8>, SocketAddr, AllocationId)>,
    relay_data_receiver: mpsc::Receiver<(Vec<u8>, SocketAddr, AllocationId)>,
    sleep: Sleep,

    client_send_buffer: VecDeque<(Vec<u8>, SocketAddr)>,
    allocation_send_buffer: VecDeque<(Vec<u8>, SocketAddr, AllocationId)>,
}

struct Allocation {
    /// The handle to the task that is running the allocation.
    ///
    /// Stored here to make resource-cleanup easy.
    handle: task::JoinHandle<()>,
    sender: mpsc::Sender<(Vec<u8>, SocketAddr)>,
}

impl Eventloop {
    async fn new(public_ip4_address: Ipv4Addr, listen_ip4_address: Ipv4Addr) -> Result<Self> {
        let (sender, receiver) = mpsc::channel(1);

        Ok(Self {
            ip4_socket: UdpSocket::bind((listen_ip4_address, 3478)).await?,
            listen_ip4_address,
            server: Server::new(SocketAddrV4::new(public_ip4_address, 3478)),
            allocations: Default::default(),
            relay_data_sender: sender,
            relay_data_receiver: receiver,
            sleep: Sleep::default(),
            client_send_buffer: Default::default(),
            allocation_send_buffer: Default::default(),
        })
    }

    fn poll(&mut self, cx: &mut std::task::Context<'_>) -> Poll<Result<()>> {
        loop {
            // Priority 1: Execute the pending commands of the server.
            if let Some(next_command) = self.server.next_command() {
                match next_command {
                    Command::SendMessage { payload, recipient } => {
                        self.client_send_buffer.push_back((payload, recipient));
                    }
                    Command::AllocateAddresses { id, port } => {
                        self.allocations.insert(
                            id,
                            Allocation::new(
                                self.relay_data_sender.clone(),
                                id,
                                self.listen_ip4_address,
                                port,
                            ),
                        );
                    }
                    Command::FreeAddresses { id } => {
                        if self.allocations.remove(&id).is_none() {
                            tracing::debug!("Unknown allocation {id}");
                            continue;
                        };

                        tracing::info!("Freeing addresses of allocation {id}");
                    }
                    Command::Wake { deadline } => {
                        Pin::new(&mut self.sleep).reset(deadline);
                    }
                    Command::ForwardData { id, data, receiver } => {
                        self.allocation_send_buffer.push_back((data, receiver, id));
                    }
                }

                continue; // Attempt to process more commands.
            }

            // Priority 2: Flush data to the socket.
            if let Some((payload, recipient)) = self.client_send_buffer.pop_front() {
                match self.ip4_socket.try_send_to(&payload, recipient, cx)? {
                    Poll::Ready(()) => {
                        if tracing::enabled!(target: "wire", Level::TRACE) {
                            let hex_bytes = hex::encode(&payload);
                            tracing::trace!(target: "wire", r#"Output::SendMessage("{recipient}","{hex_bytes}")"#);
                        }
                        continue;
                    }
                    Poll::Pending => {
                        // Yield early if we cannot send data.
                        // Continuing the event loop here would cause `client_send_buffer` to potentially grow faster than we can send data.

                        self.client_send_buffer.push_front((payload, recipient));
                        return Poll::Pending;
                    }
                }
            }

            // Priority 3: Forward data to allocations.
            if let Some((data, receiver, id)) = self.allocation_send_buffer.pop_front() {
                let Some(allocation) = self.allocations.get_mut(&id) else {
                    tracing::debug!("Unknown allocation {id}");
                    continue;
                };

                match allocation.sender.poll_ready(cx) {
                    Poll::Ready(Ok(())) => {}
                    Poll::Ready(Err(_)) => {
                        debug_assert!(
                            false,
                            "poll_ready to never fail because we own the other end of the channel"
                        );
                    }
                    Poll::Pending => {
                        // Same as above, we need to yield early if we cannot send data.
                        // The task will be woken up once there is space in the channel.

                        self.allocation_send_buffer.push_front((data, receiver, id));
                        return Poll::Pending;
                    }
                }

                match allocation.sender.try_send((data, receiver)) {
                    Ok(()) => {}
                    Err(e) if e.is_full() => {
                        let (data, receiver) = e.into_inner();

                        self.allocation_send_buffer.push_front((data, receiver, id));
                        return Poll::Pending;
                    }
                    Err(_) => {
                        debug_assert!(
                            false,
                            "try_send to never fail because we own the other end of the channel"
                        );
                    }
                };

                continue;
            }

            // Priority 4: Handle time-sensitive tasks:
            if self.sleep.poll_unpin(cx).is_ready() {
                self.server.handle_deadline_reached(Instant::now());
                continue; // Handle potentially new commands.
            }

            // Priority 5: Handle relayed data (we prioritize latency for existing allocations over making new ones)
            if let Poll::Ready(Some((data, sender, allocation))) =
                self.relay_data_receiver.poll_next_unpin(cx)
            {
                self.server.handle_relay_input(&data, sender, allocation);
                continue; // Handle potentially new commands.
            }

            // Priority 6: Accept new allocations / answer STUN requests etc
            if let Poll::Ready((buffer, sender)) = self.ip4_socket.poll_recv(cx)? {
                self.server
                    .handle_client_input(buffer.filled(), sender, Instant::now())?;
                continue; // Handle potentially new commands.
            }

            return Poll::Pending;
        }
    }
}

impl Allocation {
    fn new(
        relay_data_sender: mpsc::Sender<(Vec<u8>, SocketAddr, AllocationId)>,
        id: AllocationId,
        listen_ip4_addr: Ipv4Addr,
        port: u16,
    ) -> Self {
        let (client_to_peer_sender, client_to_peer_receiver) = mpsc::channel(1);

        let task = tokio::spawn(async move {
            let Err(e) = forward_incoming_relay_data(relay_data_sender, client_to_peer_receiver, id, listen_ip4_addr, port).await else {
                unreachable!()
            };

            // TODO: Do we need to clean this up in the server? It will eventually timeout if not refreshed.
            tracing::warn!("Allocation task for {id} failed: {e}");
        });

        Self {
            handle: task,
            sender: client_to_peer_sender,
        }
    }
}

impl Drop for Allocation {
    fn drop(&mut self) {
        self.handle.abort();
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
    mut client_to_peer_receiver: mpsc::Receiver<(Vec<u8>, SocketAddr)>,
    id: AllocationId,
    listen_ip4_addr: Ipv4Addr,
    port: u16,
) -> Result<Infallible> {
    let mut socket = UdpSocket::bind((listen_ip4_addr, port)).await?;

    tracing::info!("Listening for relayed data on {listen_ip4_addr} for allocation {id}");

    loop {
        tokio::select! {
            result = socket.recv() => {
                let (data, sender) = result?;

                tracing::debug!("Received {} bytes from {}", data.len(), sender);

                relayed_data_sender.send((data.to_vec(), sender, id)).await?;
            }

            Some((data, recipient)) = client_to_peer_receiver.next() => {

                tracing::debug!("Relaying {} bytes to {}", data.len(), recipient);

                socket.send_to(&data, recipient).await?;
            }
        }
    }
}
