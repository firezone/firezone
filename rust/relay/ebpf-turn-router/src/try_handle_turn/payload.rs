use aya_ebpf::programs::XdpContext;

use crate::try_handle_turn::{Error, ref_mut_at::ref_mut_at};

const WG_HANDSHAKE_INIT: u32 = 1;
const WG_HANDSHAKE_RESP: u32 = 2;
const WG_COOKIE_REPLY: u32 = 3;
const WG_DATA: u32 = 4;

const WG_HANDSHAKE_INIT_LEN: u16 = 148;
const WG_HANDSHAKE_RESP_LEN: u16 = 92;
const WG_COOKIE_REPLY_LEN: u16 = 64;
const WG_DATA_MIN_LEN: u16 = 32;

const STUN_HEADER_LEN: u16 = 20;
const STUN_MAGIC_COOKIE: u32 = 0x2112_A442;

/// Ensures the `len` bytes at `offset` are a WireGuard or a STUN message.
///
/// The userspace data path applies the same check in `relay-proto`.
#[inline(always)]
pub fn ensure_relayable(ctx: &XdpContext, offset: usize, len: u16) -> Result<(), Error> {
    // SAFETY: The offset must point to the start of the relayed payload.
    let header = unsafe { ref_mut_at::<[u8; 8]>(ctx, offset)? };

    let wg_message_type = u32::from_le_bytes([header[0], header[1], header[2], header[3]]);

    match (wg_message_type, len) {
        (WG_HANDSHAKE_INIT, WG_HANDSHAKE_INIT_LEN)
        | (WG_HANDSHAKE_RESP, WG_HANDSHAKE_RESP_LEN)
        | (WG_COOKIE_REPLY, WG_COOKIE_REPLY_LEN) => return Ok(()),
        (WG_DATA, len) if len >= WG_DATA_MIN_LEN => return Ok(()),
        _ => {}
    }

    let stun_length = u16::from_be_bytes([header[2], header[3]]);
    let stun_cookie = u32::from_be_bytes([header[4], header[5], header[6], header[7]]);

    if header[0] & 0b1100_0000 == 0
        && stun_cookie == STUN_MAGIC_COOKIE
        && stun_length.is_multiple_of(4)
        && len >= STUN_HEADER_LEN
        && stun_length == len - STUN_HEADER_LEN
    {
        return Ok(());
    }

    Err(Error::NotRelayable)
}
