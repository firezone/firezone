//! Additions to the `stun-codec` crate for RFC 8656.
//
// TODO: Upstream this to `stun-codec`.

use stun_codec::rfc5389::attributes::ErrorCode;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct PeerAddressFamilyMismatch;
impl PeerAddressFamilyMismatch {
    /// The codepoint of the error.
    pub const CODEPOINT: u16 = 443;
}
impl From<PeerAddressFamilyMismatch> for ErrorCode {
    fn from(_: PeerAddressFamilyMismatch) -> Self {
        ErrorCode::new(
            PeerAddressFamilyMismatch::CODEPOINT,
            "Peer Address Family Mismatch".to_owned(),
        )
        .expect("never fails")
    }
}
