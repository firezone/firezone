use anyhow::{Context, Result};
use futures::channel::mpsc::Sender;
use futures::{SinkExt, StreamExt};
use relay::{AllocationId, Command, Server, Sleep};
use std::collections::HashMap;
use std::convert::Infallible;
use std::error::Error;
use std::net::{Ipv4Addr, SocketAddr, SocketAddrV4};
use std::pin::pin;
use std::str::FromStr;
use std::time::Instant;
use tokio::net::UdpSocket;
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

    let socket = UdpSocket::bind((listen_ip4_addr, 3478)).await?;
    let mut recv_buf = [0u8; MAX_UDP_SIZE];

    let mut server = Server::new(SocketAddrV4::new(public_ip4_addr, 3478));

    tracing::info!("Listening for incoming traffic on UDP port 3478");

    let mut wake = pin!(Sleep::default());
    let (relayed_data_sender, mut relayed_data_receiver) =
        futures::channel::mpsc::channel::<(Vec<u8>, SocketAddr, AllocationId)>(10);
    let mut allocation_tasks = HashMap::<AllocationId, tokio::task::JoinHandle<()>>::default();

    loop {
        tokio::select! {
            () = &mut wake => {
                server.handle_deadline_reached(Instant::now());
            }
            (payload, sender, allocation_id) = relayed_data_receiver.select_next_some() => {
                if tracing::enabled!(target: "wire", Level::TRACE) {
                    let hex_bytes = hex::encode(&payload);
                    tracing::trace!(target: "wire", r#"Input::Relay("{sender}","{hex_bytes}")"#);
                }

                server.handle_relay_input(&payload, sender, allocation_id);
            }
            receive_result = pin!(socket.recv_from(&mut recv_buf)) => {
                let (length, sender) = receive_result.context("Failed to receive from socket")?;
                let payload = &recv_buf[..length];

                if tracing::enabled!(target: "wire", Level::TRACE) {
                    let hex_bytes = hex::encode(payload);
                    tracing::trace!(target: "wire", r#"Input::Client("{sender}","{hex_bytes}")"#);
                }

                if let Err(e) = server.handle_client_input(payload, sender, Instant::now()) {
                    tracing::debug!("Failed to handle datagram from {sender}: {e}")
                }
            }
        }

        while let Some(event) = server.next_command() {
            match event {
                Command::SendMessage { payload, recipient } => {
                    if tracing::enabled!(target: "wire", Level::TRACE) {
                        let hex_bytes = hex::encode(&payload);
                        tracing::trace!(target: "wire", r#"Output::SendMessage("{recipient}","{hex_bytes}")"#);
                    }

                    socket.send_to(&payload, recipient).await?;
                }
                Command::AllocateAddresses { id, port } => {
                    allocation_tasks.insert(id, tokio::spawn({
                        let sender = relayed_data_sender.clone();

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
                    let Some(task) = allocation_tasks.remove(&id) else {
                        tracing::debug!("Unknown allocation {id}");
                        continue;
                    };

                    tracing::info!("Freeing addresses of allocation {id}");
                    task.abort();
                }
                Command::Wake { deadline } => {
                    wake.as_mut().reset(deadline);
                }
            }
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
    mut relayed_data_sender: Sender<(Vec<u8>, SocketAddr, AllocationId)>,
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
