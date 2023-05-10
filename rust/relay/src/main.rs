mod server;

use crate::server::Command;
use anyhow::Result;
use server::Server;
use std::net::{Ipv4Addr, Ipv6Addr, SocketAddrV4, SocketAddrV6};
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

    let ip4_socket = UdpSocket::bind("0.0.0.0:3478").await?;

    let mut server = Server::new(
        SocketAddrV4::new(Ipv4Addr::UNSPECIFIED, 3478),
        SocketAddrV6::new(Ipv6Addr::UNSPECIFIED, 3478, 0, 0),
    );

    let mut buf = [0u8; MAX_UDP_SIZE];

    tracing::info!("Listening for incoming traffic on UDP port 3478");

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
