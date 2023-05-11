use anyhow::{Context, Result};
use futures::channel::mpsc::Sender;
use futures::{SinkExt, StreamExt};
use relay::{AllocationId, Command, DualStackSocket, Server, Sleep};
use std::collections::HashMap;
use std::convert::Infallible;
use std::error::Error;
use std::net::{SocketAddr, SocketAddrV4, SocketAddrV6};
use std::pin::pin;
use std::str::FromStr;
use std::time::Instant;
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

    let mut socket = DualStackSocket::listen_on(3478).await?;

    let mut server = Server::new(
        SocketAddrV4::new(parse_env_var("RELAY_PUBLIC_IP4_ADDR")?, 3478),
        SocketAddrV6::new(parse_env_var("RELAY_PUBLIC_IP6_ADDR")?, 3478, 0, 0),
    );

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
            receive_result = pin!(socket.receive()) => {
                let (sender, payload) = receive_result.context("Failed to receive from socket")?;

                if tracing::enabled!(target: "wire", Level::TRACE) {
                    let hex_bytes = hex::encode(&payload);
                    tracing::trace!(target: "wire", r#"Input::Client("{sender}","{hex_bytes}")"#);
                }

                if let Err(e) = server.handle_client_input(&payload, sender, Instant::now()) {
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
                            let Err(e) = forward_incoming_relay_data(sender, id, port).await else {
                                unreachable!()
                            };

                            // TODO: Do we need to clean this up in the server? It will eventually timeout if not refreshed.
                            tracing::warn!("Allocation task for {id} failed: {e}");
                        }
                    }));
                }
                Command::FreeAddresses { id } => {
                    if let Some(task) = allocation_tasks.remove(&id) {
                        tracing::info!("Freeing addresses of allocation {id}");
                        task.abort();

                        continue;
                    }

                    tracing::debug!("Unknown allocation {id}")
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
    port: u16,
) -> Result<Infallible> {
    let mut socket = DualStackSocket::listen_on(port).await?;
    let (ip4, ip6) = socket.local_addr();

    tracing::info!("Listening for relayed data on {ip4} and {ip6} for allocation {id}");

    loop {
        let (sender, data) = socket.receive().await?;

        relayed_data_sender.send((data, sender, id)).await?;
    }
}
