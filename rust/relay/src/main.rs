extern crate core;

use anyhow::{Context, Result};
use relay::{Command, Server, Sleep};
use std::net::{Ipv4Addr, Ipv6Addr, SocketAddrV4, SocketAddrV6};
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

    loop {
        tokio::select! {
            () = &mut wake => {
                server.handle_deadline_reached(Instant::now());
            }
            receive_result = pin!(socket.recv_from(&mut buf)) => {
                let (recv_len, sender) = receive_result.context("Failed to receive from socket")?;

                if let Err(e) = server.handle_client_input(&buf[..recv_len], sender, Instant::now()) {
                    tracing::debug!("Failed to handle datagram from {sender}: {e}")
                }
            }
        }

        while let Some(event) = server.next_command() {
            match event {
                Command::SendMessage { payload, recipient } => {
                    if tracing::enabled!(target: "wire", Level::TRACE) {
                        let hex_bytes = hex::encode(&payload);
                        tracing::trace!(target: "wire", r#"Output::SendMessage("{recipient}","{}")"#, hex_bytes);
                    }

                    socket.send_to(&payload, recipient).await?;
                }
                Command::AllocateAddresses { .. } => {
                    tracing::warn!("Allocating addresses is not yet implemented")
                }
                Command::FreeAddresses { .. } => {
                    tracing::warn!("Freeing addresses is not yet implemented")
                }
                Command::Wake { deadline } => {
                    wake.as_mut().reset(deadline);
                }
            }
        }
    }
}
