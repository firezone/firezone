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

static BROKEN: AtomicBool = AtomicBool::new(false);

/// Whether broken coalescing has been observed in this process.
pub(crate) fn is_broken() -> bool {
    BROKEN.load(Ordering::Relaxed)
}

/// Detects receives that prove coalescing on this machine is broken.
///
/// Returns `true` if any of the receives has a segment size above
/// [`ip_packet::MAX_FZ_PAYLOAD`], meaning the socket should opt out of URO.
/// The first detection is logged; later ones are silent.
pub(crate) fn detect_broken_coalescing<'a>(
    mut metas: impl Iterator<Item = &'a quinn_udp::RecvMeta>,
) -> bool {
    let Some(meta) = metas.find(|meta| meta.stride > ip_packet::MAX_FZ_PAYLOAD) else {
        return false;
    };

    if BROKEN.swap(true, Ordering::Relaxed) {
        return true;
    }

    tracing::info!(
        stride = %meta.stride,
        len = %meta.len,
        interface_index = ?meta.interface_index,
        "Disabling URO"
    );

    true
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detects_broken_coalescing_from_oversized_segment() {
        let ok = meta_with_stride(ip_packet::MAX_FZ_PAYLOAD);
        let oversized = meta_with_stride(ip_packet::MAX_FZ_PAYLOAD + 1);

        assert!(!detect_broken_coalescing([&ok].into_iter()));
        assert!(!is_broken());

        assert!(detect_broken_coalescing([&ok, &oversized].into_iter()));
        assert!(is_broken());
    }

    fn meta_with_stride(stride: usize) -> quinn_udp::RecvMeta {
        let mut meta = quinn_udp::RecvMeta::default();
        meta.len = stride;
        meta.stride = stride;

        meta
    }
}
