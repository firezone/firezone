mod server;

use crate::server::Command;
use anyhow::{Context, Result};
use relay::SocketAddrExt;
use server::Server;
use std::net::{Ipv4Addr, Ipv6Addr};
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

    let ip4_socket = UdpSocket::bind((Ipv4Addr::UNSPECIFIED, 3478)).await?;
    let ip6_socket = UdpSocket::bind((Ipv6Addr::UNSPECIFIED, 3478)).await?;
    let local_ip4_addr = ip4_socket.local_addr()?;
    let local_ip6_addr = ip6_socket.local_addr()?;

    tracing::info!("Listening on: {local_ip4_addr}");
    tracing::info!("Listening on: {local_ip6_addr}");

    let mut server = Server::new(
        local_ip4_addr
            .try_into_v4_socket()
            .context("Server is not listening on IPv4")?,
        local_ip6_addr
            .try_into_v6_socket()
            .context("Server is not listening on IPv6")?,
    );

    let mut buf = [0u8; MAX_UDP_SIZE];

    loop {
        // TODO: Listen for websocket commands here and update the server state accordingly.
        let (recv_len, sender) = ip4_socket.recv_from(&mut buf).await?;

        if tracing::enabled!(target: "wire", Level::TRACE) {
            let hex_bytes = hex::encode(&buf[..recv_len]);
            tracing::trace!(target: "wire", r#"Input("{sender}","{}")"#, hex_bytes);
        }

        if let Err(e) = server.handle_client_input(&buf[..recv_len], sender) {
            tracing::debug!("Failed to handle datagram from {sender}: {e}")
        }

        while let Some(event) = server.next_command() {
            match event {
                Command::SendMessage { payload, recipient } => {
                    if tracing::enabled!(target: "wire", Level::TRACE) {
                        let hex_bytes = hex::encode(&payload);
                        tracing::trace!(target: "wire", r#"Output("{recipient}","{}")"#, hex_bytes);
                    }

                    ip4_socket.send_to(&payload, recipient).await?;
                }
                Command::AllocateAddresses { .. } => {
                    unimplemented!()
                }
            }
        }
    }
}
