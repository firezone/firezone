use aya_ebpf::programs::XdpContext;
use ebpf_shared::{RELAYABLE_HEADER_LEN, is_relayable};

use crate::try_handle_turn::{Error, ref_mut_at::ref_mut_at};

/// Ensures the `len` bytes at `offset` are a WireGuard or a STUN message.
#[inline(always)]
pub fn ensure_relayable(ctx: &XdpContext, offset: usize, len: u16) -> Result<(), Error> {
    // SAFETY: The offset must point to the start of the relayed payload.
    let header = unsafe { ref_mut_at::<[u8; RELAYABLE_HEADER_LEN]>(ctx, offset)? };

    if !is_relayable(*header, len) {
        return Err(Error::NotRelayable);
    }

    Ok(())
}
