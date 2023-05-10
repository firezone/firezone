use anyhow::Result;
use bytecodec::{DecodeExt, EncodeExt};
use std::fmt;
use std::net::SocketAddr;
use stun_codec::rfc5389::attributes::{ErrorCode, MessageIntegrity, XorMappedAddress};
use stun_codec::rfc5389::methods::BINDING;
use stun_codec::rfc5766::methods::ALLOCATE;
use stun_codec::{Message, MessageClass, MessageDecoder, MessageEncoder};

/// A sans-IO STUN & TURN server.
///
/// A server is bound to a particular address kind (either IPv4 or IPv6).
/// If you listen on both interfaces, you should create two instances of [`Server`].
pub struct Server<TAddressKind> {
    decoder: MessageDecoder<Attribute>,
    encoder: MessageEncoder<Attribute>,

    #[allow(dead_code)]
    local_address: TAddressKind,
}

impl<TAddressKind> Server<TAddressKind>
where
    TAddressKind: fmt::Display + Into<SocketAddr> + Copy,
{
    pub fn new(local_address: TAddressKind) -> Self {
        Self {
            decoder: Default::default(),
            encoder: Default::default(),
            local_address,
        }
    }

    /// Process the bytes received from one node and optionally return bytes to send back to the same or a different node.
    pub fn handle_received_bytes(
        &mut self,
        bytes: &[u8],
        sender: TAddressKind,
    ) -> Result<Option<(Vec<u8>, TAddressKind)>> {
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
        sender: TAddressKind,
    ) -> Option<(TAddressKind, Message<Attribute>)> {
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
        sender: TAddressKind,
    ) -> (TAddressKind, Message<Attribute>) {
        tracing::debug!("Received STUN binding request from: {sender}");

        let mut message = Message::new(
            MessageClass::SuccessResponse,
            BINDING,
            message.transaction_id(),
        );
        message.add_attribute(XorMappedAddress::new(sender.into()).into());

        (sender, message)
    }

    fn handle_allocate_request(
        &self,
        _message: Message<Attribute>,
        sender: TAddressKind,
    ) -> Option<(TAddressKind, Message<Attribute>)> {
        tracing::debug!("Received TURN allocate request from: {sender}");

        None
    }
}

// Define an enum of all attributes that we care about for our server.
stun_codec::define_attribute_enums!(
    Attribute,
    AttributeDecoder,
    AttributeEncoder,
    [MessageIntegrity, XorMappedAddress, ErrorCode]
);
