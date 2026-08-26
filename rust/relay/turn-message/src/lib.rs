#![cfg_attr(test, allow(clippy::unwrap_used))]

//! Parsing of the STUN & TURN messages a TURN client sends to a server.
//!
//! This crate only decodes; it holds no server state and performs no
//! authentication. A message that decodes but is not a valid request comes back
//! as a [`Rejection`], leaving it to the server to render an error response.

mod channel_data;
mod client_message;

pub use channel_data::ChannelData;
pub use client_message::{
    Allocate, Binding, ChannelBind, ClientMessage, CreatePermission, DecodeError, Refresh, decode,
};

use stun_codec::rfc5389::attributes::{
    ErrorCode, MessageIntegrity, Nonce, Realm, Software, Username, XorMappedAddress,
};
use stun_codec::rfc5766::attributes::{
    ChannelNumber, Lifetime, RequestedTransport, XorPeerAddress, XorRelayAddress,
};
use stun_codec::rfc8656::attributes::{AdditionalAddressFamily, RequestedAddressFamily};
use stun_codec::{Method, TransactionId};

stun_codec::define_attribute_enums!(
    Attribute,
    AttributeDecoder,
    AttributeEncoder,
    [
        MessageIntegrity,
        XorMappedAddress,
        ErrorCode,
        RequestedTransport,
        XorRelayAddress,
        Lifetime,
        ChannelNumber,
        XorPeerAddress,
        Nonce,
        Realm,
        Username,
        RequestedAddressFamily,
        AdditionalAddressFamily,
        Software
    ]
);

/// A message that decoded but is not a request we can serve.
///
/// Carries what an error response needs, so the server can render one with its
/// own `SOFTWARE` attribute.
#[derive(Debug)]
pub struct Rejection {
    method: Method,
    transaction_id: TransactionId,
    error_code: ErrorCode,
}

impl Rejection {
    pub fn new(
        method: Method,
        transaction_id: TransactionId,
        error_code: impl Into<ErrorCode>,
    ) -> Self {
        Self {
            method,
            transaction_id,
            error_code: error_code.into(),
        }
    }

    pub fn method(&self) -> Method {
        self.method
    }

    pub fn transaction_id(&self) -> TransactionId {
        self.transaction_id
    }

    pub fn error_code(&self) -> &ErrorCode {
        &self.error_code
    }
}
