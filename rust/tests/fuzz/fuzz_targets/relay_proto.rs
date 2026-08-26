#![no_main]

//! Drives the relay's message handling with arbitrary datagrams.
//!
//! `handle_client_input` is what the relay calls on every datagram, so anything
//! reachable here is reachable pre-authentication from the open internet.
//!
//! The fuzzer decides how much help a datagram gets. Left alone, it exercises
//! the decoder with bytes that are unlikely to be a well-formed message. Asked
//! to authenticate, the harness repairs the two fields no mutation could ever
//! guess, the nonce the relay minted and the HMAC over the message, so the
//! fuzzer reaches the code behind the authentication check. Everything else,
//! the username and its expiry included, stays fuzzer-controlled bytes.
//!
//! The repair deliberately goes through `stun_codec` rather than the relay's own
//! decoder: using the code under test to decide what to feed it would hide its
//! bugs from us.

use arbitrary::Arbitrary;
use bytecodec::{DecodeExt as _, EncodeExt as _};
use libfuzzer_sys::fuzz_target;
use rand::{SeedableRng as _, rngs::StdRng};
use relay_proto::{Attribute, ClientSocket, Command, Server, auth::generate_password};
use secrecy::SecretString;
use std::net::{Ipv4Addr, SocketAddr};
use std::time::Instant;
use stun_codec::rfc5389::attributes::{MessageIntegrity, Nonce, Realm, Username};
use stun_codec::{Message, MessageDecoder, MessageEncoder};

const RELAY_IP: Ipv4Addr = Ipv4Addr::new(10, 0, 0, 1);
const CLIENT: SocketAddr = SocketAddr::new(std::net::IpAddr::V4(Ipv4Addr::new(10, 0, 0, 2)), 51820);

#[derive(Arbitrary, Debug)]
struct Input<'a> {
    /// Re-encode the datagram through an independent STUN codec first.
    reencode: bool,
    /// Give the message a nonce the relay issued and a matching HMAC.
    authenticate: bool,
    datagram: &'a [u8],
}

fuzz_target!(|input: Input<'_>| {
    let mut server = Server::new(RELAY_IP, StdRng::seed_from_u64(0), 3478, 49152..=65535);
    let client = ClientSocket::new(CLIENT);
    let now = Instant::now();

    let nonce = issued_nonce(&mut server, client, now);

    let datagram = match input.reencode {
        false => input.datagram.to_vec(),
        true => match repair(
            input.datagram,
            input.authenticate.then_some(&nonce),
            &server,
        ) {
            Some(repaired) => repaired,
            None => return,
        },
    };

    server.handle_client_input(&datagram, client, now);
});

/// Replaces the fields a fuzzer cannot guess, leaving the rest of the message alone.
fn repair(datagram: &[u8], nonce: Option<&Nonce>, server: &Server<StdRng>) -> Option<Vec<u8>> {
    let message: Message<Attribute> = MessageDecoder::new()
        .decode_from_bytes(datagram)
        .ok()?
        .ok()?;

    let Some(nonce) = nonce else {
        return MessageEncoder::new().encode_into_bytes(message).ok();
    };

    let username = message.get_attribute::<Username>().cloned()?;

    // A wrong password still reaches the expiry check, which runs first, so a
    // username the relay could never have issued must not stop us here.
    let password = password_for(&username, server.auth_secret()).unwrap_or_default();

    let realm = Realm::new("firezone".to_owned()).ok()?;
    let mut authenticated =
        Message::<Attribute>::new(message.class(), message.method(), message.transaction_id());
    for attribute in message
        .attributes()
        .filter(|a| !matches!(a, Attribute::Nonce(_) | Attribute::MessageIntegrity(_)))
        .cloned()
        .collect::<Vec<_>>()
    {
        authenticated.add_attribute(attribute);
    }
    authenticated.add_attribute(nonce.clone());

    let integrity =
        MessageIntegrity::new_long_term_credential(&authenticated, &username, &realm, &password)
            .ok()?;
    authenticated.add_attribute(integrity);

    MessageEncoder::new().encode_into_bytes(authenticated).ok()
}

/// Derives the password for a username in the relay's `{expiry}:{salt}` form.
///
/// Returns [`None`] for any other shape, which the relay rejects before it ever
/// looks at the password.
fn password_for(username: &Username, secret: &SecretString) -> Option<String> {
    let (expiry, salt) = username.name().split_once(':')?;

    Some(generate_password(secret, expiry.parse().ok()?, salt))
}

/// Obtains a nonce the way a client does, by provoking a `401` and reading it back.
fn issued_nonce(server: &mut Server<StdRng>, client: ClientSocket, now: Instant) -> Nonce {
    let mut allocate = Message::<Attribute>::new(
        stun_codec::MessageClass::Request,
        stun_codec::rfc5766::methods::ALLOCATE,
        stun_codec::TransactionId::new([0u8; 12]),
    );
    allocate.add_attribute(stun_codec::rfc5766::attributes::RequestedTransport::new(17));

    let bytes = MessageEncoder::new()
        .encode_into_bytes(allocate)
        .expect("a well-formed ALLOCATE encodes");
    server.handle_client_input(&bytes, client, now);

    let Some(Command::SendMessage { payload, .. }) = server.next_command() else {
        panic!("the relay answers an unauthenticated ALLOCATE");
    };

    MessageDecoder::<Attribute>::new()
        .decode_from_bytes(&payload)
        .expect("the relay's response decodes")
        .expect("the relay's response is well-formed")
        .get_attribute::<Nonce>()
        .cloned()
        .expect("a `401` carries a nonce")
}
