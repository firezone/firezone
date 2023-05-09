use anyhow::Result;
use tokio::net::UdpSocket;
use tracing::level_filters::LevelFilter;

const MAX_UDP_SIZE: usize = 65536;

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_max_level(LevelFilter::INFO)
        .init();

    let socket = UdpSocket::bind("0.0.0.0:3478").await?;

    tracing::info!("Listening on: {addr}", addr = socket.local_addr()?);

    let mut buf = [0u8; MAX_UDP_SIZE];

    loop {
        let (recv_len, sender) = socket.recv_from(&mut buf).await?;

        let message = match relay::stun::parse_binding_request(&buf[..recv_len]) {
            Ok((input, message)) => {
                if !input.is_empty() {
                    tracing::warn!(
                        "Received STUN message with trailing data that will be discarded"
                    );
                }

                message
            }
            // TODO: I think `Incomplete` can never happen:
            // 1. STUN messages always fit into a single UDP datagram
            // 2. We can never receive less than a single UDP datagram
            Err(nom::Err::Incomplete(_)) => continue,
            Err(e) => {
                tracing::trace!("Received invalid STUN message: {e:?}");
                continue;
            }
        };

        tracing::info!("Received STUN binding request from: {sender}");

        socket
            .send_to(
                &relay::stun::write_binding_response(message.transaction_id, sender),
                sender,
            )
            .await?;
    }
}
