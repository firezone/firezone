use crate::auth::{generate_password, split_username, systemtime_from_unix, FIREZONE};
use crate::server::channel_data::ChannelData;
use crate::server::UDP_TRANSPORT;
use crate::Attribute;
use anyhow::{Context, Result};
use bytecodec::DecodeExt;
use secrecy::SecretString;
use std::io;
use std::time::Duration;
use stun_codec::rfc5389::attributes::{ErrorCode, MessageIntegrity, Nonce, Software, Username};
use stun_codec::rfc5389::errors::BadRequest;
use stun_codec::rfc5389::methods::BINDING;
use stun_codec::rfc5766::attributes::{
    ChannelNumber, Lifetime, RequestedTransport, XorPeerAddress,
};
use stun_codec::rfc5766::methods::{ALLOCATE, CHANNEL_BIND, CREATE_PERMISSION, REFRESH};
use stun_codec::rfc8656::attributes::{
    AdditionalAddressFamily, AddressFamily, RequestedAddressFamily,
};
use stun_codec::{Message, MessageClass, Method, TransactionId};
use uuid::Uuid;

/// The maximum lifetime of an allocation.
const MAX_ALLOCATION_LIFETIME: Duration = Duration::from_secs(3600);

/// The default lifetime of an allocation.
///
/// See <https://www.rfc-editor.org/rfc/rfc8656#name-allocations-2>.
const DEFAULT_ALLOCATION_LIFETIME: Duration = Duration::from_secs(600);

#[derive(Default, Debug)]
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
                let message = match self.stun_message_decoder.decode_from_bytes(input)? {
                    Ok(message) => message,
                    Err(broken_message) => {
                        let method = broken_message.method();
                        let transaction_id = broken_message.transaction_id();
                        let error = broken_message.error().clone();

                        tracing::debug!(transaction_id = ?transaction_id, %method, %error, "Failed to decode attributes of message");

                        let error_code = ErrorCode::from(error);

                        return Ok(Err(error_response(method, transaction_id, error_code)));
                    }
                };

                use MessageClass::*;
                match (message.method(), message.class()) {
                    (BINDING, Request) => Ok(Ok(ClientMessage::Binding(Binding::parse(&message)))),
                    (ALLOCATE, Request) => {
                        Ok(Allocate::parse(&message).map(ClientMessage::Allocate))
                    }
                    (REFRESH, Request) => Ok(Ok(ClientMessage::Refresh(Refresh::parse(&message)))),
                    (CHANNEL_BIND, Request) => {
                        Ok(ChannelBind::parse(&message).map(ClientMessage::ChannelBind))
                    }
                    (CREATE_PERMISSION, Request) => Ok(Ok(ClientMessage::CreatePermission(
                        CreatePermission::parse(&message),
                    ))),
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

#[derive(derive_more::From, Debug)]
pub enum ClientMessage<'a> {
    ChannelData(ChannelData<'a>),
    Binding(Binding),
    Allocate(Allocate),
    Refresh(Refresh),
    ChannelBind(ChannelBind),
    CreatePermission(CreatePermission),
}

impl ClientMessage<'_> {
    pub fn transaction_id(&self) -> Option<TransactionId> {
        match self {
            ClientMessage::Binding(request) => Some(request.transaction_id),
            ClientMessage::Allocate(request) => Some(request.transaction_id),
            ClientMessage::Refresh(request) => Some(request.transaction_id),
            ClientMessage::ChannelBind(request) => Some(request.transaction_id),
            ClientMessage::CreatePermission(request) => Some(request.transaction_id),
            ClientMessage::ChannelData(_) => None,
        }
    }

    pub fn username(&self) -> Option<&Username> {
        match self {
            ClientMessage::ChannelData(_) | ClientMessage::Binding(_) => None,
            ClientMessage::Allocate(request) => request.username(),
            ClientMessage::Refresh(request) => request.username(),
            ClientMessage::ChannelBind(request) => request.username(),
            ClientMessage::CreatePermission(request) => request.username(),
        }
    }
}

#[derive(Debug)]
pub struct Binding {
    transaction_id: TransactionId,
    software: Option<Software>,
}

impl Binding {
    pub fn new(transaction_id: TransactionId) -> Self {
        Self {
            transaction_id,
            software: None,
        }
    }

    pub fn parse(message: &Message<Attribute>) -> Self {
        let transaction_id = message.transaction_id();
        let software = message.get_attribute::<Software>().cloned();

        Binding {
            transaction_id,
            software,
        }
    }

    pub fn transaction_id(&self) -> TransactionId {
        self.transaction_id
    }

    pub fn software(&self) -> Option<&Software> {
        self.software.as_ref()
    }
}

#[derive(Debug)]
pub struct Allocate {
    transaction_id: TransactionId,
    message_integrity: Option<MessageIntegrity>,
    requested_transport: RequestedTransport,
    lifetime: Option<Lifetime>,
    username: Option<Username>,
    nonce: Option<Nonce>,
    requested_address_family: Option<RequestedAddressFamily>,
    additional_address_family: Option<AdditionalAddressFamily>,
    software: Option<Software>,
}

impl Allocate {
    pub fn new_authenticated_udp_implicit_ip4(
        transaction_id: TransactionId,
        lifetime: Option<Lifetime>,
        username: Username,
        relay_secret: &SecretString,
        nonce: Uuid,
    ) -> Result<Self> {
        let (requested_transport, nonce, message_integrity) = Self::make_attributes(
            transaction_id,
            &lifetime,
            &username,
            relay_secret,
            nonce,
            None,
        )?;

        Ok(Self {
            transaction_id,
            message_integrity: Some(message_integrity),
            requested_transport,
            lifetime,
            username: Some(username),
            nonce: Some(nonce),
            requested_address_family: None, // IPv4 is the default.
            additional_address_family: None,
            software: None,
        })
    }

    pub fn new_authenticated_udp_ip6(
        transaction_id: TransactionId,
        lifetime: Option<Lifetime>,
        username: Username,
        relay_secret: &SecretString,
        nonce: Uuid,
    ) -> Result<Self> {
        let requested_address_family = RequestedAddressFamily::new(AddressFamily::V6);

        let (requested_transport, nonce, message_integrity) = Self::make_attributes(
            transaction_id,
            &lifetime,
            &username,
            relay_secret,
            nonce,
            Some(requested_address_family.clone()),
        )?;

        Ok(Self {
            transaction_id,
            message_integrity: Some(message_integrity),
            requested_transport,
            lifetime,
            username: Some(username),
            nonce: Some(nonce),
            requested_address_family: Some(requested_address_family),
            additional_address_family: None,
            software: None,
        })
    }

    pub fn new_unauthenticated_udp(
        transaction_id: TransactionId,
        lifetime: Option<Lifetime>,
    ) -> Self {
        let requested_transport = RequestedTransport::new(UDP_TRANSPORT);

        let mut message =
            Message::<Attribute>::new(MessageClass::Request, ALLOCATE, transaction_id);
        message.add_attribute(requested_transport.clone());

        if let Some(lifetime) = &lifetime {
            message.add_attribute(lifetime.clone());
        }

        Self {
            transaction_id,
            message_integrity: None,
            requested_transport,
            lifetime,
            username: None,
            nonce: None,
            requested_address_family: None,
            additional_address_family: None,
            software: None,
        }
    }

    fn make_attributes(
        transaction_id: TransactionId,
        lifetime: &Option<Lifetime>,
        username: &Username,
        relay_secret: &SecretString,
        nonce: Uuid,
        requested_address_family: Option<RequestedAddressFamily>,
    ) -> Result<(RequestedTransport, Nonce, MessageIntegrity)> {
        let requested_transport = RequestedTransport::new(UDP_TRANSPORT);
        let nonce = Nonce::new(nonce.as_hyphenated().to_string()).context("Invalid nonce")?;

        let mut message =
            Message::<Attribute>::new(MessageClass::Request, ALLOCATE, transaction_id);
        message.add_attribute(requested_transport.clone());
        message.add_attribute(username.clone());
        message.add_attribute(nonce.clone());

        if let Some(requested_address_family) = requested_address_family {
            message.add_attribute(requested_address_family);
        }

        if let Some(lifetime) = &lifetime {
            message.add_attribute(lifetime.clone());
        }

        let (expiry, salt) = split_username(username.name())?;
        let expiry_systemtime = systemtime_from_unix(expiry);

        let password = generate_password(relay_secret, expiry_systemtime, salt);

        let message_integrity =
            MessageIntegrity::new_long_term_credential(&message, username, &FIREZONE, &password)?;

        Ok((requested_transport, nonce, message_integrity))
    }

    pub fn parse(message: &Message<Attribute>) -> Result<Self, Message<Attribute>> {
        let transaction_id = message.transaction_id();
        let message_integrity = message.get_attribute::<MessageIntegrity>().cloned();
        let nonce = message.get_attribute::<Nonce>().cloned();
        let requested_transport = message
            .get_attribute::<RequestedTransport>()
            .ok_or(bad_request(message))?
            .clone();
        let lifetime = message.get_attribute::<Lifetime>().cloned();
        let username = message.get_attribute::<Username>().cloned();
        let requested_address_family = message.get_attribute::<RequestedAddressFamily>().cloned();
        let additional_address_family = message.get_attribute::<AdditionalAddressFamily>().cloned();
        let software = message.get_attribute::<Software>().cloned();

        Ok(Allocate {
            transaction_id,
            message_integrity,
            requested_transport,
            lifetime,
            username,
            nonce,
            requested_address_family,
            additional_address_family,
            software,
        })
    }

    pub fn transaction_id(&self) -> TransactionId {
        self.transaction_id
    }

    pub fn message_integrity(&self) -> Option<&MessageIntegrity> {
        self.message_integrity.as_ref()
    }

    pub fn requested_transport(&self) -> &RequestedTransport {
        &self.requested_transport
    }

    pub fn effective_lifetime(&self) -> Lifetime {
        compute_effective_lifetime(self.lifetime.as_ref())
    }

    pub fn username(&self) -> Option<&Username> {
        self.username.as_ref()
    }

    pub fn nonce(&self) -> Option<&Nonce> {
        self.nonce.as_ref()
    }

    pub fn requested_address_family(&self) -> Option<&RequestedAddressFamily> {
        self.requested_address_family.as_ref()
    }

    pub fn additional_address_family(&self) -> Option<&AdditionalAddressFamily> {
        self.additional_address_family.as_ref()
    }

    pub fn software(&self) -> Option<&Software> {
        self.software.as_ref()
    }
}

#[derive(Debug)]
pub struct Refresh {
    transaction_id: TransactionId,
    message_integrity: Option<MessageIntegrity>,
    lifetime: Option<Lifetime>,
    username: Option<Username>,
    nonce: Option<Nonce>,
    software: Option<Software>,
}

impl Refresh {
    pub fn new(
        transaction_id: TransactionId,
        lifetime: Option<Lifetime>,
        username: Username,
        relay_secret: &SecretString,
        nonce: Uuid,
    ) -> Result<Self> {
        let nonce = Nonce::new(nonce.as_hyphenated().to_string()).context("Invalid nonce")?;

        let mut message = Message::<Attribute>::new(MessageClass::Request, REFRESH, transaction_id);
        message.add_attribute(username.clone());
        message.add_attribute(nonce.clone());

        if let Some(lifetime) = &lifetime {
            message.add_attribute(lifetime.clone());
        }

        let (expiry, salt) = split_username(username.name())?;
        let expiry_systemtime = systemtime_from_unix(expiry);

        let password = generate_password(relay_secret, expiry_systemtime, salt);

        let message_integrity =
            MessageIntegrity::new_long_term_credential(&message, &username, &FIREZONE, &password)?;

        Ok(Self {
            transaction_id,
            message_integrity: Some(message_integrity),
            lifetime,
            username: Some(username),
            nonce: Some(nonce),
            software: None,
        })
    }

    pub fn parse(message: &Message<Attribute>) -> Self {
        let transaction_id = message.transaction_id();
        let message_integrity = message.get_attribute::<MessageIntegrity>().cloned();
        let nonce = message.get_attribute::<Nonce>().cloned();
        let lifetime = message.get_attribute::<Lifetime>().cloned();
        let username = message.get_attribute::<Username>().cloned();
        let software = message.get_attribute::<Software>().cloned();

        Refresh {
            transaction_id,
            message_integrity,
            lifetime,
            username,
            nonce,
            software,
        }
    }

    pub fn transaction_id(&self) -> TransactionId {
        self.transaction_id
    }

    pub fn message_integrity(&self) -> Option<&MessageIntegrity> {
        self.message_integrity.as_ref()
    }

    pub fn effective_lifetime(&self) -> Lifetime {
        compute_effective_lifetime(self.lifetime.as_ref())
    }

    pub fn username(&self) -> Option<&Username> {
        self.username.as_ref()
    }

    pub fn nonce(&self) -> Option<&Nonce> {
        self.nonce.as_ref()
    }

    pub fn software(&self) -> Option<&Software> {
        self.software.as_ref()
    }
}

#[derive(Debug)]
pub struct ChannelBind {
    transaction_id: TransactionId,
    channel_number: ChannelNumber,
    message_integrity: Option<MessageIntegrity>,
    nonce: Option<Nonce>,
    xor_peer_address: XorPeerAddress,
    username: Option<Username>,
    software: Option<Software>,
}

impl ChannelBind {
    pub fn new(
        transaction_id: TransactionId,
        channel_number: ChannelNumber,
        xor_peer_address: XorPeerAddress,
        username: Username,
        relay_secret: &SecretString,
        nonce: Uuid,
    ) -> Result<Self> {
        let nonce = Nonce::new(nonce.as_hyphenated().to_string()).context("Invalid nonce")?;

        let mut message =
            Message::<Attribute>::new(MessageClass::Request, CHANNEL_BIND, transaction_id);
        message.add_attribute(username.clone());
        message.add_attribute(channel_number);
        message.add_attribute(xor_peer_address.clone());
        message.add_attribute(nonce.clone());

        let (expiry, salt) = split_username(username.name())?;
        let expiry_systemtime = systemtime_from_unix(expiry);

        let password = generate_password(relay_secret, expiry_systemtime, salt);

        let message_integrity =
            MessageIntegrity::new_long_term_credential(&message, &username, &FIREZONE, &password)?;

        Ok(Self {
            transaction_id,
            channel_number,
            message_integrity: Some(message_integrity),
            xor_peer_address,
            username: Some(username),
            nonce: Some(nonce),
            software: None,
        })
    }

    pub fn parse(message: &Message<Attribute>) -> Result<Self, Message<Attribute>> {
        let transaction_id = message.transaction_id();
        let channel_number = message
            .get_attribute::<ChannelNumber>()
            .copied()
            .ok_or(bad_request(message))?;
        let message_integrity = message.get_attribute::<MessageIntegrity>().cloned();
        let nonce = message.get_attribute::<Nonce>().cloned();
        let username = message.get_attribute::<Username>().cloned();
        let xor_peer_address = message
            .get_attribute::<XorPeerAddress>()
            .ok_or(bad_request(message))?
            .clone();
        let software = message.get_attribute::<Software>().cloned();

        Ok(ChannelBind {
            transaction_id,
            channel_number,
            message_integrity,
            nonce,
            xor_peer_address,
            username,
            software,
        })
    }

    pub fn transaction_id(&self) -> TransactionId {
        self.transaction_id
    }

    pub fn channel_number(&self) -> ChannelNumber {
        self.channel_number
    }

    pub fn message_integrity(&self) -> Option<&MessageIntegrity> {
        self.message_integrity.as_ref()
    }

    pub fn xor_peer_address(&self) -> &XorPeerAddress {
        &self.xor_peer_address
    }

    pub fn username(&self) -> Option<&Username> {
        self.username.as_ref()
    }

    pub fn nonce(&self) -> Option<&Nonce> {
        self.nonce.as_ref()
    }

    pub fn software(&self) -> Option<&Software> {
        self.software.as_ref()
    }
}

#[derive(Debug)]
pub struct CreatePermission {
    transaction_id: TransactionId,
    message_integrity: Option<MessageIntegrity>,
    username: Option<Username>,
    nonce: Option<Nonce>,
    software: Option<Software>,
}

impl CreatePermission {
    pub fn parse(message: &Message<Attribute>) -> Self {
        let transaction_id = message.transaction_id();
        let message_integrity = message.get_attribute::<MessageIntegrity>().cloned();
        let username = message.get_attribute::<Username>().cloned();
        let nonce = message.get_attribute::<Nonce>().cloned();
        let software = message.get_attribute::<Software>().cloned();

        CreatePermission {
            transaction_id,
            message_integrity,
            username,
            nonce,
            software,
        }
    }

    pub fn transaction_id(&self) -> TransactionId {
        self.transaction_id
    }

    pub fn message_integrity(&self) -> Option<&MessageIntegrity> {
        self.message_integrity.as_ref()
    }

    pub fn username(&self) -> Option<&Username> {
        self.username.as_ref()
    }

    pub fn nonce(&self) -> Option<&Nonce> {
        self.nonce.as_ref()
    }

    pub fn software(&self) -> Option<&Software> {
        self.software.as_ref()
    }
}

/// Computes the effective lifetime of an allocation.
fn compute_effective_lifetime(requested_lifetime: Option<&Lifetime>) -> Lifetime {
    let Some(requested) = requested_lifetime else {
        return Lifetime::new(DEFAULT_ALLOCATION_LIFETIME)
            .expect("Default lifetime is less than 0xFFFF_FFFF");
    };

    let effective_lifetime = requested.lifetime().min(MAX_ALLOCATION_LIFETIME);

    Lifetime::new(effective_lifetime)
        .expect("lifetime is at most MAX_ALLOCATION_LIFETIME which is less than 0xFFFF_FFFF")
}

fn bad_request(message: &Message<Attribute>) -> Message<Attribute> {
    error_response(
        message.method(),
        message.transaction_id(),
        ErrorCode::from(BadRequest),
    )
}

fn error_response(
    method: Method,
    transaction_id: TransactionId,
    error_code: ErrorCode,
) -> Message<Attribute> {
    let mut message = Message::new(MessageClass::ErrorResponse, method, transaction_id);
    message.add_attribute(error_code);

    message
}

#[derive(Debug)]
pub enum Error {
    BadChannelData(io::Error),
    DecodeStun(bytecodec::Error),
    UnknownMessageType(u8),
    Eof,
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
