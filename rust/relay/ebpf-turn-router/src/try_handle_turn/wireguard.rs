use aya_ebpf::programs::XdpContext;

use crate::try_handle_turn::{Error, ref_mut_at::ref_mut_at};

const HANDSHAKE_INIT: u32 = 1;
const HANDSHAKE_RESP: u32 = 2;
const COOKIE_REPLY: u32 = 3;
const DATA: u32 = 4;

const HANDSHAKE_INIT_LEN: u16 = 148;
const HANDSHAKE_RESP_LEN: u16 = 92;
const COOKIE_REPLY_LEN: u16 = 64;
const DATA_MIN_LEN: u16 = 32;

/// Ensures the `len` bytes at `offset` are a WireGuard message.
///
/// Anything else (like STUN) is passed to userspace, which decides whether to relay it.
#[inline(always)]
pub fn ensure_wireguard(ctx: &XdpContext, offset: usize, len: u16) -> Result<(), Error> {
    // SAFETY: The offset must point to the start of the relayed payload.
    let message_type = unsafe { ref_mut_at::<[u8; 4]>(ctx, offset)? };

    match (u32::from_le_bytes(*message_type), len) {
        (HANDSHAKE_INIT, HANDSHAKE_INIT_LEN)
        | (HANDSHAKE_RESP, HANDSHAKE_RESP_LEN)
        | (COOKIE_REPLY, COOKIE_REPLY_LEN) => Ok(()),
        (DATA, len) if len >= DATA_MIN_LEN => Ok(()),
        _ => Err(Error::NotWireGuard),
    }
}
