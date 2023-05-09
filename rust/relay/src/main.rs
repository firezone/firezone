use anyhow::Result;
use bytecodec::{DecodeExt as _, EncodeExt as _};
use std::net::SocketAddr;
use stun_codec::{rfc5389, Message, MessageClass, MessageDecoder, MessageEncoder};
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

    let mut decoder = MessageDecoder::<rfc5389::Attribute>::new();
    let mut encoder = MessageEncoder::<rfc5389::Attribute>::new();

    let mut buf = [0u8; MAX_UDP_SIZE];

    loop {
        let (recv_len, sender) = socket.recv_from(&mut buf).await?;

        let Ok(Ok(message)) = decoder.decode_from_bytes(&buf[..recv_len]) else {
            continue;
        };

        let Some(response) = handle_message(message, sender) else {
            continue;
        };

        socket
            .send_to(&encoder.encode_into_bytes(response)?, sender)
            .await?;
    }
}

fn handle_message(
    message: Message<rfc5389::Attribute>,
    sender: SocketAddr,
) -> Option<Message<rfc5389::Attribute>> {
    let message = match (message.class(), message.method()) {
        (MessageClass::Request, rfc5389::methods::BINDING) => {
            tracing::info!("Received STUN binding request from: {sender}");

            let mut message = Message::new(
                MessageClass::SuccessResponse,
                rfc5389::methods::BINDING,
                message.transaction_id(),
            );
            message.add_attribute(rfc5389::attributes::XorMappedAddress::new(sender).into());

            message
        }
        _ => return None,
    };

    Some(message)
}
