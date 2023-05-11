extern crate core;

use anyhow::{Context, Result};
use futures::channel::mpsc::Sender;
use futures::{SinkExt, StreamExt};
use relay::{AllocationId, Command, Server, Sleep};
use std::collections::HashMap;
use std::convert::Infallible;
use std::net::{Ipv4Addr, Ipv6Addr, SocketAddr, SocketAddrV4, SocketAddrV6};
use std::pin::pin;
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

    let socket = UdpSocket::bind("0.0.0.0:3478").await?;

    // TODO: Either configure or resolve our public addresses.
    let mut server = Server::new(
        SocketAddrV4::new(Ipv4Addr::UNSPECIFIED, 3478),
        SocketAddrV6::new(Ipv6Addr::UNSPECIFIED, 3478, 0, 0),
    );

    let mut buf = [0u8; MAX_UDP_SIZE];

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
            receive_result = pin!(socket.recv_from(&mut buf)) => {
                let (recv_len, sender) = receive_result.context("Failed to receive from socket")?;
                let payload = &buf[..recv_len];

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
                Command::AllocateAddresses { id, ip4, ip6 } => {
                    allocation_tasks.insert(id, tokio::spawn({
                        let sender = relayed_data_sender.clone();

                        async move {
                            let Err(e) = forward_incoming_relay_data(sender, id, ip4, ip6).await else {
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

async fn forward_incoming_relay_data(
    mut relayed_data_sender: Sender<(Vec<u8>, SocketAddr, AllocationId)>,
    id: AllocationId,
    ip4: SocketAddrV4,
    ip6: SocketAddrV6,
) -> Result<Infallible> {
    let mut ip4_buf = [0u8; MAX_UDP_SIZE];
    let mut ip6_buf = [0u8; MAX_UDP_SIZE];

    let ip4_socket = UdpSocket::bind(ip4).await?;
    let ip6_socket = UdpSocket::bind(ip6).await?;

    tracing::info!(
        "Listening for relayed data on {} and {} for allocation {id}",
        ip6_socket.local_addr()?,
        ip4_socket.local_addr()?
    );

    loop {
        let ((data, sender), _) = futures::future::try_select(
            pin!(async {
                let (size, sender) = ip4_socket.recv_from(&mut ip4_buf).await?;

                anyhow::Ok((ip4_buf[..size].to_vec(), sender))
            }),
            pin!(async {
                let (size, sender) = ip6_socket.recv_from(&mut ip6_buf).await?;

                anyhow::Ok((ip6_buf[..size].to_vec(), sender))
            }),
        )
        .await
        .map_err(|err| err.factor_first().0)?
        .factor_first();

        relayed_data_sender.send((data, sender, id)).await?;
    }
}
