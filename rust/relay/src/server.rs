use crate::attributes::Attribute;
use anyhow::Result;
use bytecodec::{DecodeExt, EncodeExt};
use std::net::SocketAddr;
use stun_codec::rfc5389::attributes::{ErrorCode, MessageIntegrity, XorMappedAddress};
use stun_codec::rfc5389::errors::Unauthorized;
use stun_codec::rfc5389::methods::BINDING;
use stun_codec::rfc5766::methods::ALLOCATE;
use stun_codec::{Message, MessageClass, MessageDecoder, MessageEncoder};

/// A sans-IO STUN server.
#[derive(Default)]
pub struct Server {
    decoder: MessageDecoder<Attribute>,
    encoder: MessageEncoder<Attribute>,
}

impl Server {
    // TODO: Fuzz this interface.
    pub fn handle_received_bytes(
        &mut self,
        bytes: &[u8],
        sender: SocketAddr,
    ) -> Result<Option<(Vec<u8>, SocketAddr)>> {
        let Ok(message) = self.decoder.decode_from_bytes(bytes)? else {
            tracing::trace!("received broken STUN message from {sender}");
            return Ok(None);
        };
        let Some(response) = self.handle_message(message, sender) else {
            return Ok(None);
        };
        let bytes = self.encoder.encode_into_bytes(response)?;

        Ok(Some((bytes, sender)))
    }

    fn handle_message(
        &mut self,
        message: Message<Attribute>,
        sender: SocketAddr,
    ) -> Option<Message<Attribute>> {
        tracing::trace!("Received STUN message {message:?} from {sender}");

        let message = match (message.class(), message.method()) {
            (MessageClass::Request, BINDING) => {
                tracing::debug!("Received STUN binding request from: {sender}");

                let mut message = Message::new(
                    MessageClass::SuccessResponse,
                    BINDING,
                    message.transaction_id(),
                );
                message.add_attribute(XorMappedAddress::new(sender).into());

                message
            }
            (MessageClass::Request, ALLOCATE) => {
                tracing::debug!("Received TURN allocate request from: {sender}");

                let Some(_mi) = message.get_attribute::<MessageIntegrity>() else {
                    tracing::debug!("Turning down allocate request from {sender} because it is not authenticated");

                    let mut message = Message::new(
                        MessageClass::ErrorResponse,
                        ALLOCATE,
                        message.transaction_id(),
                    );
                    message.add_attribute(ErrorCode::from(Unauthorized).into());

                    return Some(message);
                };

                return None;
            }
            _ => return None,
        };

        Some(message)
    }
}
