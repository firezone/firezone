use crate::server::channel_data::ChannelData;
use crate::Attribute;
use bytecodec::DecodeExt;
use std::io;
use stun_codec::rfc5389::attributes::{MessageIntegrity, Username};
use stun_codec::rfc5389::methods::BINDING;
use stun_codec::rfc5766::attributes::{
    ChannelNumber, Lifetime, RequestedTransport, XorPeerAddress,
};
use stun_codec::rfc5766::methods::{ALLOCATE, CHANNEL_BIND, CREATE_PERMISSION, REFRESH};
use stun_codec::{BrokenMessage, Message, MessageClass, Method, TransactionId};

#[derive(Default)]
pub struct Decoder {
    stun_message_decoder: stun_codec::MessageDecoder<Attribute>,
}

impl Decoder {
    pub fn decode<'a>(&mut self, input: &'a [u8]) -> Result<Option<ClientMessage<'a>>, Error> {
        // De-multiplex as per <https://www.rfc-editor.org/rfc/rfc8656#name-channels-2>.
        let client_message = match input.first() {
            Some(0..=3) => {
                let message = self.stun_message_decoder.decode_from_bytes(input)??;

                use MessageClass::*;
                match (message.method(), message.class()) {
                    (BINDING, Request) => {
                        ClientMessage::BindingRequest(BindingRequest::from_message(message))
                    }
                    (ALLOCATE, Request) => {
                        ClientMessage::AllocateRequest(AllocateRequest::from_message(message)?)
                    }
                    (REFRESH, Request) => {
                        ClientMessage::RefreshRequest(RefreshRequest::from_message(message)?)
                    }
                    (CHANNEL_BIND, Request) => ClientMessage::ChannelBindRequest(
                        ChannelBindRequest::from_message(message)?,
                    ),
                    (CREATE_PERMISSION, Request) => ClientMessage::CreatePermissionRequest(
                        CreatePermissionRequest::from_message(message)?,
                    ),
                    (method, class) => {
                        return Err(Error::UnsupportedMethodClassCombination(method, class))
                    }
                }
            }
            Some(64..=79) => ClientMessage::ChannelData(ChannelData::parse(input)?),
            _ => return Ok(None),
        };

        Ok(Some(client_message))
    }
}

pub enum ClientMessage<'a> {
    ChannelData(ChannelData<'a>),
    BindingRequest(BindingRequest),
    AllocateRequest(AllocateRequest),
    RefreshRequest(RefreshRequest),
    ChannelBindRequest(ChannelBindRequest),
    CreatePermissionRequest(CreatePermissionRequest),
}

pub struct BindingRequest {
    transaction_id: TransactionId,
}

impl BindingRequest {
    pub fn new(transaction_id: TransactionId) -> Self {
        Self { transaction_id }
    }

    pub fn from_message(message: Message<Attribute>) -> Self {
        let transaction_id = message.transaction_id();

        BindingRequest { transaction_id }
    }

    pub fn transaction_id(&self) -> TransactionId {
        self.transaction_id
    }
}

pub struct AllocateRequest {
    transaction_id: TransactionId,
    message_integrity: MessageIntegrity,
    requested_transport: RequestedTransport,
    lifetime: Option<Lifetime>,
}

impl AllocateRequest {
    pub fn new(
        transaction_id: TransactionId,
        message_integrity: MessageIntegrity,
        requested_transport: RequestedTransport,
        lifetime: Option<Lifetime>,
    ) -> Self {
        Self {
            transaction_id,
            message_integrity,
            requested_transport,
            lifetime,
        }
    }

    pub fn from_message(message: Message<Attribute>) -> Result<Self, Error> {
        let transaction_id = message.transaction_id();
        let message_integrity = message
            .get_attribute::<MessageIntegrity>()
            .ok_or(Error::MissingMessageIntegrity)?
            .clone();
        let requested_transport = message
            .get_attribute::<RequestedTransport>()
            .ok_or(Error::MissingRequiredAttribute)?
            .clone();
        let lifetime = message.get_attribute::<Lifetime>().cloned();

        Ok(AllocateRequest {
            transaction_id,
            message_integrity,
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
        todo!("move function from `server` module here")
    }
}

pub struct RefreshRequest {
    transaction_id: TransactionId,
    message_integrity: MessageIntegrity,
    lifetime: Option<Lifetime>,
}

impl RefreshRequest {
    pub fn new(
        transaction_id: TransactionId,
        message_integrity: MessageIntegrity,
        lifetime: Option<Lifetime>,
    ) -> Self {
        Self {
            transaction_id,
            message_integrity,
            lifetime,
        }
    }

    pub fn from_message(message: Message<Attribute>) -> Result<Self, Error> {
        let transaction_id = message.transaction_id();
        let message_integrity = message
            .get_attribute::<MessageIntegrity>()
            .ok_or(Error::MissingMessageIntegrity)?
            .clone();
        let lifetime = message.get_attribute::<Lifetime>().cloned();

        Ok(RefreshRequest {
            transaction_id,
            message_integrity,
            lifetime,
        })
    }

    pub fn transaction_id(&self) -> TransactionId {
        self.transaction_id
    }

    pub fn effective_lifetime(&self) -> Lifetime {
        todo!("move function from `server` module here")
    }
}

pub struct ChannelBindRequest {
    transaction_id: TransactionId,
    channel_number: ChannelNumber,
    message_integrity: MessageIntegrity,
    xor_peer_address: XorPeerAddress,
    username: Username,
}

impl ChannelBindRequest {
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

    pub fn from_message(message: Message<Attribute>) -> Result<Self, Error> {
        let transaction_id = message.transaction_id();
        let channel_number = message
            .get_attribute::<ChannelNumber>()
            .copied()
            .ok_or(Error::MissingRequiredAttribute)?;
        let message_integrity = message
            .get_attribute::<MessageIntegrity>()
            .ok_or(Error::MissingMessageIntegrity)?
            .clone();
        let username = message
            .get_attribute::<Username>()
            .ok_or(Error::MissingRequiredAttribute)?
            .clone();
        let xor_peer_address = message
            .get_attribute::<XorPeerAddress>()
            .ok_or(Error::MissingRequiredAttribute)?
            .clone();

        Ok(ChannelBindRequest {
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

pub struct CreatePermissionRequest {
    transaction_id: TransactionId,
    message_integrity: MessageIntegrity,
    username: Username,
}

impl CreatePermissionRequest {
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

    pub fn from_message(message: Message<Attribute>) -> Result<Self, Error> {
        let transaction_id = message.transaction_id();
        let message_integrity = message
            .get_attribute::<MessageIntegrity>()
            .ok_or(Error::MissingMessageIntegrity)?
            .clone();
        let username = message
            .get_attribute::<Username>()
            .ok_or(Error::MissingRequiredAttribute)?
            .clone();

        Ok(CreatePermissionRequest {
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

#[derive(Debug)]
pub enum Error {
    BadChannelData(io::Error),
    DecodeStun(bytecodec::Error),
    MissingMessageIntegrity,
    MissingRequiredAttribute,
    UnsupportedMethodClassCombination(Method, MessageClass),
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
