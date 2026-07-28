//! Process-wide kill switch for URO (UDP receive coalescing) on Windows.
//!
//! Some Windows machines coalesce received UDP datagrams without attaching the
//! `UDP_COALESCED_INFO` metadata required to split the buffer back into datagrams,
//! turning every packet train into one unusable blob
//! (<https://github.com/quinn-rs/quinn/issues/2041>).
//!
//! No Firezone peer sends a datagram larger than [`ip_packet::MAX_FZ_PAYLOAD`] and
//! correct coalescing reports the size of the original datagrams as the segment size,
//! so receiving a segment above that bound proves that coalescing on this machine is
//! broken. Once that happens, URO stays off for the remainder of the process.

use std::sync::atomic::{AtomicBool, Ordering};

static TRIPPED: AtomicBool = AtomicBool::new(false);

/// Whether broken coalescing has been observed in this process.
pub fn is_tripped() -> bool {
    TRIPPED.load(Ordering::Relaxed)
}

/// Records an observation of broken coalescing.
///
/// The first observation logs a warning; later ones are silent.
pub(crate) fn trip(meta: &quinn_udp::RecvMeta) {
    if TRIPPED.swap(true, Ordering::Relaxed) {
        return;
    }

    tracing::warn!(
        stride = %meta.stride,
        len = %meta.len,
        interface_index = ?meta.interface_index,
        "Received a datagram segment larger than any Firezone peer sends; disabling URO to work around broken receive coalescing"
    );
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn trips_once() {
        assert!(!is_tripped());

        trip(&quinn_udp::RecvMeta::default());
        trip(&quinn_udp::RecvMeta::default());

        assert!(is_tripped());
    }
}
