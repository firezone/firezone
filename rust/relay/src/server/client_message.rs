use crate::server::channel_data::ChannelData;
use crate::Attribute;
use bytecodec::DecodeExt;
use std::io;
use std::time::Duration;
use stun_codec::rfc5389::attributes::{ErrorCode, MessageIntegrity, Username};
use stun_codec::rfc5389::errors::{BadRequest, Unauthorized};
use stun_codec::rfc5389::methods::BINDING;
use stun_codec::rfc5766::attributes::{
    ChannelNumber, Lifetime, RequestedTransport, XorPeerAddress,
};
use stun_codec::rfc5766::methods::{ALLOCATE, CHANNEL_BIND, CREATE_PERMISSION, REFRESH};
use stun_codec::{BrokenMessage, Message, MessageClass, TransactionId};

/// The maximum lifetime of an allocation.
const MAX_ALLOCATION_LIFETIME: Duration = Duration::from_secs(3600);

/// The default lifetime of an allocation.
///
/// See <https://www.rfc-editor.org/rfc/rfc8656#name-allocations-2>.
const DEFAULT_ALLOCATION_LIFETIME: Duration = Duration::from_secs(600);

#[derive(Default)]
pub struct Decoder {
    stun_message_decoder: stun_codec::MessageDecoder<Attribute>,
}

impl Decoder {
    pub fn decode<'a>(
        &mut self,
        input: &'a [u8],
    ) -> Result<Result<ClientMessage<'a>, Message<Attribute>>, Error> {
        // De-multiplex as per <https://www.rfc-editor.org/rfc/rfc8656#name-channels-2>.
        match input.first() {
            Some(0..=3) => {
                let message = self.stun_message_decoder.decode_from_bytes(input)??;

                use MessageClass::*;
                match (message.method(), message.class()) {
                    (BINDING, Request) => Ok(Ok(ClientMessage::Binding(Binding::parse(&message)))),
                    (ALLOCATE, Request) => {
                        Ok(Allocate::parse(&message).map(ClientMessage::Allocate))
                    }
                    (REFRESH, Request) => Ok(Refresh::parse(&message).map(ClientMessage::Refresh)),
                    (CHANNEL_BIND, Request) => {
                        Ok(ChannelBind::parse(&message).map(ClientMessage::ChannelBind))
                    }
                    (CREATE_PERMISSION, Request) => {
                        Ok(CreatePermission::parse(&message).map(ClientMessage::CreatePermission))
                    }
                    (_, Request) => Ok(Err(bad_request(&message))),
                    (method, class) => {
                        Err(Error::DecodeStun(bytecodec::Error::from(io::Error::new(
                            io::ErrorKind::Unsupported,
                            format!(
                                "handling method {} and {class:?} is not implemented",
                                method.as_u16()
                            ),
                        ))))
                    }
                }
            }
            Some(64..=79) => Ok(Ok(ClientMessage::ChannelData(ChannelData::parse(input)?))),
            Some(other) => Err(Error::UnknownMessageType(*other)),
            None => Err(Error::Eof),
        }
    }
}

pub enum ClientMessage<'a> {
    ChannelData(ChannelData<'a>),
    Binding(Binding),
    Allocate(Allocate),
    Refresh(Refresh),
    ChannelBind(ChannelBind),
    CreatePermission(CreatePermission),
}

pub struct Binding {
    transaction_id: TransactionId,
}

impl Binding {
    pub fn new(transaction_id: TransactionId) -> Self {
        Self { transaction_id }
    }

    pub fn parse(message: &Message<Attribute>) -> Self {
        let transaction_id = message.transaction_id();

        Binding { transaction_id }
    }

    pub fn transaction_id(&self) -> TransactionId {
        self.transaction_id
    }
}

pub struct Allocate {
    transaction_id: TransactionId,
    message_integrity: MessageIntegrity,
    requested_transport: RequestedTransport,
    lifetime: Option<Lifetime>,
    username: Username,
}

impl Allocate {
    pub fn new(
        transaction_id: TransactionId,
        message_integrity: MessageIntegrity,
        username: Username,
        requested_transport: RequestedTransport,
        lifetime: Option<Lifetime>,
    ) -> Self {
        Self {
            transaction_id,
            message_integrity,
            requested_transport,
            lifetime,
            username,
        }
    }

    pub fn parse(message: &Message<Attribute>) -> Result<Self, Message<Attribute>> {
        let transaction_id = message.transaction_id();
        let message_integrity = message
            .get_attribute::<MessageIntegrity>()
            .ok_or(unauthorized(message))?
            .clone();
        let username = message
            .get_attribute::<Username>()
            .ok_or(bad_request(message))?
            .clone();
        let requested_transport = message
            .get_attribute::<RequestedTransport>()
            .ok_or(bad_request(message))?
            .clone();
        let lifetime = message.get_attribute::<Lifetime>().cloned();

        Ok(Allocate {
            transaction_id,
            message_integrity,
            username,
            requested_transport,
            lifetime,
        })
    }

    pub fn transaction_id(&self) -> TransactionId {
        self.transaction_id
    }

    pub fn message_integrity(&self) -> &MessageIntegrity {
        &self.message_integrity
    }

    pub fn requested_transport(&self) -> &RequestedTransport {
        &self.requested_transport
    }

    pub fn effective_lifetime(&self) -> Lifetime {
        compute_effective_lifetime(self.lifetime.as_ref())
    }

    pub fn username(&self) -> &Username {
        &self.username
    }
}

pub struct Refresh {
    transaction_id: TransactionId,
    message_integrity: MessageIntegrity,
    lifetime: Option<Lifetime>,
    username: Username,
}

impl Refresh {
    pub fn new(
        transaction_id: TransactionId,
        message_integrity: MessageIntegrity,
        username: Username,
        lifetime: Option<Lifetime>,
    ) -> Self {
        Self {
            transaction_id,
            message_integrity,
            lifetime,
            username,
        }
    }

    pub fn parse(message: &Message<Attribute>) -> Result<Self, Message<Attribute>> {
        let transaction_id = message.transaction_id();
        let message_integrity = message
            .get_attribute::<MessageIntegrity>()
            .ok_or(unauthorized(message))?
            .clone();
        let username = message
            .get_attribute::<Username>()
            .ok_or(bad_request(message))?
            .clone();
        let lifetime = message.get_attribute::<Lifetime>().cloned();

        Ok(Refresh {
            transaction_id,
            message_integrity,
            username,
            lifetime,
        })
    }

    pub fn transaction_id(&self) -> TransactionId {
        self.transaction_id
    }

    pub fn message_integrity(&self) -> &MessageIntegrity {
        &self.message_integrity
    }

    pub fn effective_lifetime(&self) -> Lifetime {
        compute_effective_lifetime(self.lifetime.as_ref())
    }

    pub fn username(&self) -> &Username {
        &self.username
    }
}

pub struct ChannelBind {
    transaction_id: TransactionId,
    channel_number: ChannelNumber,
    message_integrity: MessageIntegrity,
    xor_peer_address: XorPeerAddress,
    username: Username,
}

impl ChannelBind {
    pub fn new(
        transaction_id: TransactionId,
        channel_number: ChannelNumber,
        message_integrity: MessageIntegrity,
        username: Username,
        xor_peer_address: XorPeerAddress,
    ) -> Self {
        Self {
            transaction_id,
            channel_number,
            message_integrity,
            xor_peer_address,
            username,
        }
    }

    pub fn parse(message: &Message<Attribute>) -> Result<Self, Message<Attribute>> {
        let transaction_id = message.transaction_id();
        let channel_number = message
            .get_attribute::<ChannelNumber>()
            .copied()
            .ok_or(bad_request(message))?;
        let message_integrity = message
            .get_attribute::<MessageIntegrity>()
            .ok_or(unauthorized(message))?
            .clone();
        let username = message
            .get_attribute::<Username>()
            .ok_or(bad_request(message))?
            .clone();
        let xor_peer_address = message
            .get_attribute::<XorPeerAddress>()
            .ok_or(bad_request(message))?
            .clone();

        Ok(ChannelBind {
            transaction_id,
            channel_number,
            message_integrity,
            xor_peer_address,
            username,
        })
    }

    pub fn transaction_id(&self) -> TransactionId {
        self.transaction_id
    }

    pub fn channel_number(&self) -> ChannelNumber {
        self.channel_number
    }

    pub fn message_integrity(&self) -> &MessageIntegrity {
        &self.message_integrity
    }

    pub fn xor_peer_address(&self) -> &XorPeerAddress {
        &self.xor_peer_address
    }

    pub fn username(&self) -> &Username {
        &self.username
    }
}

pub struct CreatePermission {
    transaction_id: TransactionId,
    message_integrity: MessageIntegrity,
    username: Username,
}

impl CreatePermission {
    pub fn new(
        transaction_id: TransactionId,
        message_integrity: MessageIntegrity,
        username: Username,
    ) -> Self {
        Self {
            transaction_id,
            message_integrity,
            username,
        }
    }

    pub fn parse(message: &Message<Attribute>) -> Result<Self, Message<Attribute>> {
        let transaction_id = message.transaction_id();
        let message_integrity = message
            .get_attribute::<MessageIntegrity>()
            .ok_or(unauthorized(message))?
            .clone();
        let username = message
            .get_attribute::<Username>()
            .ok_or(bad_request(message))?
            .clone();

        Ok(CreatePermission {
            transaction_id,
            message_integrity,
            username,
        })
    }

    pub fn transaction_id(&self) -> TransactionId {
        self.transaction_id
    }

    pub fn message_integrity(&self) -> &MessageIntegrity {
        &self.message_integrity
    }

    pub fn username(&self) -> &Username {
        &self.username
    }
}

/// Computes the effective lifetime of an allocation.
fn compute_effective_lifetime(requested_lifetime: Option<&Lifetime>) -> Lifetime {
    let Some(requested) = requested_lifetime else {
        return Lifetime::new(DEFAULT_ALLOCATION_LIFETIME).unwrap();
    };

    let effective_lifetime = requested.lifetime().min(MAX_ALLOCATION_LIFETIME);

    Lifetime::new(effective_lifetime).unwrap()
}

fn bad_request(message: &Message<Attribute>) -> Message<Attribute> {
    let mut message = Message::new(
        MessageClass::ErrorResponse,
        message.method(),
        message.transaction_id(),
    );
    message.add_attribute(ErrorCode::from(BadRequest).into());

    message
}

fn unauthorized(message: &Message<Attribute>) -> Message<Attribute> {
    let mut message = Message::new(
        MessageClass::ErrorResponse,
        message.method(),
        message.transaction_id(),
    );
    message.add_attribute(ErrorCode::from(Unauthorized).into());

    message
}

#[derive(Debug)]
pub enum Error {
    BadChannelData(io::Error),
    DecodeStun(bytecodec::Error),
    UnknownMessageType(u8),
    Eof,
}

impl From<BrokenMessage> for Error {
    fn from(msg: BrokenMessage) -> Self {
        Error::DecodeStun(msg.into())
    }
}

impl From<bytecodec::Error> for Error {
    fn from(error: bytecodec::Error) -> Self {
        Error::DecodeStun(error)
    }
}

impl From<io::Error> for Error {
    fn from(error: io::Error) -> Self {
        Error::BadChannelData(error)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn requested_lifetime_is_capped_at_max_lifetime() {
        let requested_lifetime = Lifetime::new(Duration::from_secs(10_000_000)).unwrap();

        let effective_lifetime = compute_effective_lifetime(Some(&requested_lifetime));

        assert_eq!(effective_lifetime.lifetime(), MAX_ALLOCATION_LIFETIME)
    }
}
