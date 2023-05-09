use crate::attributes::Attribute;
use anyhow::Result;
use bytecodec::{DecodeExt, EncodeExt};
use std::net::SocketAddr;
use stun_codec::rfc5389::attributes::{ErrorCode, MessageIntegrity, XorMappedAddress};
use stun_codec::rfc5389::errors::Unauthorized;
use stun_codec::rfc5389::methods::BINDING;
use stun_codec::rfc5766::methods::ALLOCATE;
use stun_codec::{Message, MessageClass, MessageDecoder, MessageEncoder};

/// A sans-IO STUN & TURN server.
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

        tracing::trace!("Received message {message:?} from {sender}");

        let Some((recipient, response)) = self.handle_message(message, sender) else {
            return Ok(None);
        };

        let bytes = self.encoder.encode_into_bytes(response)?;

        Ok(Some((bytes, recipient)))
    }

    fn handle_message(
        &mut self,
        message: Message<Attribute>,
        sender: SocketAddr,
    ) -> Option<(SocketAddr, Message<Attribute>)> {
        if message.class() == MessageClass::Request && message.method() == BINDING {
            return Some(self.handle_binding_request(message, sender));
        }

        if message.class() == MessageClass::Request && message.method() == ALLOCATE {
            return self.handle_allocate_request(message, sender);
        }

        tracing::debug!(
            "Unhandled message of type {:?} and method {:?} from {}",
            message.class(),
            message.method(),
            sender
        );

        None
    }

    fn handle_binding_request(
        &self,
        message: Message<Attribute>,
        sender: SocketAddr,
    ) -> (SocketAddr, Message<Attribute>) {
        tracing::debug!("Received STUN binding request from: {sender}");

        let mut message = Message::new(
            MessageClass::SuccessResponse,
            BINDING,
            message.transaction_id(),
        );
        message.add_attribute(XorMappedAddress::new(sender).into());

        (sender, message)
    }

    fn handle_allocate_request(
        &self,
        message: Message<Attribute>,
        sender: SocketAddr,
    ) -> Option<(SocketAddr, Message<Attribute>)> {
        tracing::debug!("Received TURN allocate request from: {sender}");

        let Some(_mi) = message.get_attribute::<MessageIntegrity>() else {
            tracing::debug!("Turning down allocate request from {sender} because it is not authenticated");

            let mut message = Message::new(
                MessageClass::ErrorResponse,
                ALLOCATE,
                message.transaction_id(),
            );
            message.add_attribute(ErrorCode::from(Unauthorized).into());

            return Some((sender, message));
        };

        None
    }
}
