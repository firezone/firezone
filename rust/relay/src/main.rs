use anyhow::Result;
use tokio::net::UdpSocket;
use tracing::level_filters::LevelFilter;

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_max_level(LevelFilter::INFO)
        .init();

    let socket = UdpSocket::bind("0.0.0.0:3478").await?;

    tracing::info!("Listening on: {addr}", addr = socket.local_addr()?);

    let mut buf = [0u8; 1024];

    loop {
        let (recv_len, _sender) = socket.recv_from(&mut buf).await?;

        let message = match relay::stun::parse_binding_request(&buf[..recv_len]) {
            Ok((input, message)) => {
                if !input.is_empty() {
                    tracing::warn!(
                        "Received STUN message with trailing data that will be discarded"
                    );
                }

                message
            }
            Err(nom::Err::Incomplete(_)) => {
                break;
            }
            Err(nom::Err::Failure(nom::error::Error { code, .. })) => {
                tracing::trace!("Received invalid STUN message: {code:?}");
                break;
            }
            Err(nom::Err::Error(nom::error::Error { code, .. })) => {
                tracing::trace!("Received invalid STUN message: {code:?}");
                break;
            }
        };

        tracing::info!("Received STUN message: {message:?}");
    }

    Ok(())
}
