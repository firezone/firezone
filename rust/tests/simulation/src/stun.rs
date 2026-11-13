//! Makes a fuzzer's STUN messages acceptable to the relay.
//!
//! Left alone, the bytes of an input are unlikely to be a well-formed message and exercise
//! the decoders. [`repair`] fills in the two fields no mutation could ever guess, the nonce
//! the relay minted and the HMAC over the message, so the input reaches the code behind the
//! authentication check.
//!
//! The repair deliberately goes through `stun_codec` rather than the relay's own decoder:
//! using the code under test to decide what to feed it would hide its bugs from us.

use bytecodec::{DecodeExt as _, EncodeExt as _};
use rand::rngs::StdRng;
use relay_server_proto::{
    Attribute, Server,
    auth::{AccountId, generate_password, hash_account_id},
};
use stun_codec::{
    Message, MessageDecoder, MessageEncoder,
    rfc5389::attributes::{MessageIntegrity, Nonce, Realm, Username},
};
use uuid::Uuid;

/// Re-encodes a STUN message, optionally replacing the fields a fuzzer cannot guess.
///
/// An authenticated message is sent in the name of `device`.
pub(crate) fn repair(
    datagram: &[u8],
    nonce: Option<&Nonce>,
    device: &str,
    server: &Server<StdRng>,
) -> Option<Vec<u8>> {
    let message = decode(datagram)?;

    let Some(nonce) = nonce else {
        return MessageEncoder::new().encode_into_bytes(message).ok();
    };

    let username = account_bound_username(message.get_attribute::<Username>()?, device)?;
    let password = generate_password(server.auth_secret(), username.name());
    let realm = Realm::new("firezone".to_owned()).ok()?;

    let mut authenticated =
        Message::<Attribute>::new(message.class(), message.method(), message.transaction_id());
    for attribute in message.attributes().filter(|a| {
        !matches!(
            a,
            Attribute::Nonce(_) | Attribute::MessageIntegrity(_) | Attribute::Username(_)
        )
    }) {
        authenticated.add_attribute(attribute.clone());
    }
    authenticated.add_attribute(username.clone());
    authenticated.add_attribute(nonce.clone());

    let integrity =
        MessageIntegrity::new_long_term_credential(&authenticated, &username, &realm, &password)
            .ok()?;
    authenticated.add_attribute(integrity);

    MessageEncoder::new().encode_into_bytes(authenticated).ok()
}

fn decode(datagram: &[u8]) -> Option<Message<Attribute>> {
    MessageDecoder::<Attribute>::new()
        .decode_from_bytes(datagram)
        .ok()?
        .ok()
}

/// Replaces the account and the device of a username, keeping its expiry.
///
/// Like the nonce and HMAC, this lets the fuzzer reach authenticated paths while keeping the
/// expiry under its control.
fn account_bound_username(username: &Username, device: &str) -> Option<Username> {
    let parts = username.name().split(':').collect::<Vec<_>>();
    let [expiry, _account_hash, _device] = parts.as_slice() else {
        return None;
    };

    if expiry.is_empty() {
        return None;
    }

    let account = hash_account_id(&AccountId::from(Uuid::nil()));

    Username::new(format!("{expiry}:{account}:{device}")).ok()
}
