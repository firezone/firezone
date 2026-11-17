//! Turns a fuzzer's bytes into well-formed STUN messages for the relay.
//!
//! Left alone, the bytes of an input are unlikely to be a well-formed message and exercise
//! the decoders. [`reencode`] goes through `stun_codec` rather than the relay's own decoder:
//! using the code under test to decide what to feed it would hide its bugs from us.

use bytecodec::{DecodeExt as _, EncodeExt as _};
use relay_server_proto::Attribute;
use stun_codec::{MessageDecoder, MessageEncoder};

/// Decodes a STUN message and encodes it again.
pub(crate) fn reencode(datagram: &[u8]) -> Option<Vec<u8>> {
    let message = MessageDecoder::<Attribute>::new()
        .decode_from_bytes(datagram)
        .ok()?
        .ok()?;

    MessageEncoder::new().encode_into_bytes(message).ok()
}
