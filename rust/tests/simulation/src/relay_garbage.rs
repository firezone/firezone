//! Datagrams that neither the client nor the relay sent.
//!
//! Left alone, the bytes of the input are unlikely to be a well-formed message
//! and exercise the decoders. Asked to authenticate, [`repair`] fills in the two
//! fields no mutation could ever guess, the nonce the relay minted and the HMAC
//! over the message, so the input reaches the code behind the authentication check.
//!
//! The repair deliberately goes through `stun_codec` rather than the relay's own
//! decoder: using the code under test to decide what to feed it would hide its
//! bugs from us.

use std::{
    net::SocketAddr,
    time::{Instant, SystemTime},
};

use bytecodec::{DecodeExt as _, EncodeExt as _};
use rand::rngs::StdRng;
use relay_server_proto::{Attribute, ClientSocket, Command, Server, auth::generate_password};
use stun_codec::{
    Message, MessageClass, MessageDecoder, MessageEncoder, TransactionId,
    rfc5389::attributes::{MessageIntegrity, Nonce, Realm, Username},
    rfc5766::{attributes::RequestedTransport, methods::ALLOCATE},
};

/// Flips the bits of `template` that are set in `mask`; what `mask` has beyond it is appended.
pub(crate) fn mutate(template: &[u8], mask: &[u8]) -> Vec<u8> {
    let mut datagram = template.to_vec();
    datagram.resize(template.len().max(mask.len()), 0);

    for (byte, mask) in datagram.iter_mut().zip(mask) {
        *byte ^= mask;
    }

    datagram
}

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

/// Obtains a nonce the way a client does, by provoking a `401` and reading it back.
pub(crate) fn issued_nonce(
    server: &mut Server<StdRng>,
    sender: SocketAddr,
    now: Instant,
    now_utc: SystemTime,
) -> Nonce {
    let mut allocate = Message::<Attribute>::new(
        MessageClass::Request,
        ALLOCATE,
        TransactionId::new([0u8; 12]),
    );
    allocate.add_attribute(RequestedTransport::new(17));

    let bytes = MessageEncoder::new()
        .encode_into_bytes(allocate)
        .expect("a well-formed ALLOCATE encodes");
    server.handle_client_input(&bytes, ClientSocket::new(sender), now, now_utc);

    let Some(Command::SendMessage { payload, .. }) = server.next_command() else {
        panic!("the relay answers an unauthenticated ALLOCATE");
    };

    decode(&payload)
        .expect("the relay's response decodes")
        .get_attribute::<Nonce>()
        .cloned()
        .expect("a `401` carries a nonce")
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

    Username::new(crate::relay::username(expiry, device)).ok()
}
