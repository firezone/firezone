mod server;

use crate::server::Command;
use anyhow::{bail, Context, Error, Result};
use server::Server;
use std::net::{SocketAddr, SocketAddrV4, SocketAddrV6};
use std::time::Duration;
use tokio::net::UdpSocket;
use tracing::level_filters::LevelFilter;
use tracing::Level;
use tracing_subscriber::EnvFilter;

const MAX_UDP_SIZE: usize = 65536;

/// The address of the STUN server we'll use so WE now our public IP address.
///
/// We are a STUN server that uses a STUN server. STUNing.
const STUN_SERVER: &'static str = "stun.l.google.com";
const STUN_SERVER_PORT: u16 = 19302;

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
    let (local_ip4_addr, local_ip6_addr) = resolve_public_addresses(&ip4_socket).await?;

    tracing::info!("Listening on: {local_ip4_addr}");
    tracing::info!("Listening on: {local_ip6_addr}");

    let mut server = Server::new(local_ip4_addr, local_ip6_addr);

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

/// Resolves the public IPv4 and IPv6 address.
async fn resolve_public_addresses(socket: &UdpSocket) -> Result<(SocketAddrV4, SocketAddrV6)> {
    tracing::info!("Resolving our own public IP address via {STUN_SERVER}:{STUN_SERVER_PORT}");

    let resolver = trust_dns_resolver::AsyncResolver::tokio(
        trust_dns_resolver::config::ResolverConfig::default(),
        trust_dns_resolver::config::ResolverOpts::default(),
    )?;

    let ip4_address = resolver
        .ipv4_lookup(STUN_SERVER)
        .await?
        .iter()
        .next()
        .context("Failed to lookup IPv4 address of STUN server")?
        .clone();
    let ip4_socket = SocketAddrV4::new(ip4_address, STUN_SERVER_PORT);

    let ip6_address = resolver
        .ipv6_lookup(STUN_SERVER)
        .await?
        .iter()
        .next()
        .context("Failed to lookup IPv6 address of STUN server")?
        .clone();
    let ip6_socket = SocketAddrV6::new(ip6_address, STUN_SERVER_PORT, 0, 0);

    socket
        .send_to(&new_binding_request()?, ip4_socket)
        .await
        .with_context(|| format!("Failed to send STUN packet to {ip4_socket}"))?;

    socket
        .send_to(&new_binding_request()?, ip6_socket)
        .await
        .with_context(|| format!("Failed to send STUN packet to {ip6_socket}"))?;

    let (ipv4_addr, ipv6_addr) =
        tokio::time::timeout(Duration::from_secs(5), await_stun_response(socket))
            .await
            .context("No STUN response received after 5 seconds")??;

    Ok((ipv4_addr, ipv6_addr))
}

async fn await_stun_response(socket: &UdpSocket) -> Result<(SocketAddrV4, SocketAddrV6), Error> {
    use bytecodec::DecodeExt;
    use stun_codec::rfc5389::attributes::XorMappedAddress;
    use stun_codec::rfc5389::methods::BINDING;
    use stun_codec::rfc5389::Attribute;
    use stun_codec::{MessageClass, MessageDecoder};

    let mut decoder = MessageDecoder::<Attribute>::default();

    let mut buffer = [0u8; MAX_UDP_SIZE];

    let mut ipv4_addr = None;
    let mut ipv6_addr = None;

    loop {
        let (size, _) = socket.recv_from(&mut buffer).await?;

        let Ok(message) = decoder.decode_from_bytes(&buffer[..size])? else {
            bail!("Received broken message")
        };

        anyhow::ensure!(
            message.class() == MessageClass::SuccessResponse,
            "Unexpected STUN message class"
        );
        anyhow::ensure!(message.method() == BINDING, "Unexpected STUN message class");

        match message
            .get_attribute::<XorMappedAddress>()
            .context("No address in STUN response")?
            .address()
        {
            SocketAddr::V4(addr) => ipv4_addr = Some(addr),
            SocketAddr::V6(addr) => ipv6_addr = Some(addr),
        }

        match (ipv4_addr, ipv6_addr) {
            (Some(ipv4_addr), Some(ipv6_addr)) => break Ok((ipv4_addr, ipv6_addr)),
            _ => continue,
        }
    }
}

fn new_binding_request() -> Result<Vec<u8>> {
    use bytecodec::EncodeExt;
    use stun_codec::rfc5389::methods::BINDING;
    use stun_codec::rfc5389::Attribute;
    use stun_codec::{Message, MessageClass, MessageEncoder, TransactionId};

    Ok(
        MessageEncoder::<Attribute>::default().encode_into_bytes(Message::<Attribute>::new(
            MessageClass::Request,
            BINDING,
            TransactionId::new(rand::random()),
        ))?,
    )
}
