//! Builds the STUN messages that the relay simulation injects.
//!
//! Everything goes through `stun_codec` rather than the decoders of the client or the relay:
//! using the code under test to decide what to feed it would hide its bugs from us.

use bytecodec::{DecodeExt as _, EncodeExt as _};
use relay_server_proto::Attribute;
use stun_codec::{
    Message, MessageClass, MessageDecoder, MessageEncoder, TransactionId,
    rfc5389::attributes::{ErrorCode, MessageIntegrity, Nonce, Realm, Username},
    rfc5766::{
        attributes::{ChannelNumber, Lifetime, RequestedTransport, XorPeerAddress},
        methods::{ALLOCATE, CHANNEL_BIND, REFRESH},
    },
};

use crate::relay_transition::ForeignRequest;

/// Decodes a STUN message and encodes it again.
///
/// Left alone, the bytes of an input are unlikely to be a well-formed message and exercise the
/// decoders.
pub(crate) fn round_trip(datagram: &[u8]) -> Option<Vec<u8>> {
    encode(decode(datagram)?)
}

/// Builds an error response to the request that `response` answers.
///
/// It carries a nonce and a realm like a `401` does, but no `MESSAGE-INTEGRITY`.
pub(crate) fn error_response(response: &[u8], code: u16) -> Option<Vec<u8>> {
    let response = decode(response)?;

    let mut forged = Message::new(
        MessageClass::ErrorResponse,
        response.method(),
        response.transaction_id(),
    );
    forged.add_attribute(ErrorCode::new(code, "Forged".to_owned()).ok()?);
    forged.add_attribute(Realm::new("forged".to_owned()).ok()?);
    forged.add_attribute(Nonce::new("forged".to_owned()).ok()?);

    encode(forged)
}

/// Builds a request, signed with the long-term credentials if there are any.
pub(crate) fn request(
    request: ForeignRequest,
    credentials: Option<(&str, &str, Nonce)>,
) -> Option<Vec<u8>> {
    let method = match request {
        ForeignRequest::Allocate => ALLOCATE,
        ForeignRequest::Refresh { .. } => REFRESH,
        ForeignRequest::ChannelBind { .. } => CHANNEL_BIND,
    };
    let mut message = Message::new(
        MessageClass::Request,
        method,
        TransactionId::new([0xf0; 12]),
    );

    match request {
        ForeignRequest::Allocate => message.add_attribute(RequestedTransport::new(17)),
        ForeignRequest::Refresh { lifetime } => {
            message.add_attribute(Lifetime::new(lifetime).ok()?)
        }
        ForeignRequest::ChannelBind { channel, peer } => {
            message.add_attribute(ChannelNumber::new(channel).ok()?);
            message.add_attribute(XorPeerAddress::new(peer));
        }
    }

    if let Some((username, password, nonce)) = credentials {
        let username = Username::new(username.to_owned()).ok()?;
        let realm = Realm::new("firezone".to_owned()).ok()?;

        message.add_attribute(username.clone());
        message.add_attribute(realm.clone());
        message.add_attribute(nonce);
        message.add_attribute(
            MessageIntegrity::new_long_term_credential(&message, &username, &realm, password)
                .ok()?,
        );
    }

    encode(message)
}

/// The nonce that a response of the relay carries.
pub(crate) fn nonce(response: &[u8]) -> Option<Nonce> {
    decode(response)?.get_attribute::<Nonce>().cloned()
}

fn decode(datagram: &[u8]) -> Option<Message<Attribute>> {
    MessageDecoder::<Attribute>::new()
        .decode_from_bytes(datagram)
        .ok()?
        .ok()
}

fn encode(message: Message<Attribute>) -> Option<Vec<u8>> {
    MessageEncoder::new().encode_into_bytes(message).ok()
}
