//! Process-wide kill switch for URO (UDP receive coalescing) on Windows.
//!
//! Some Windows machines coalesce received UDP datagrams without attaching the
//! `UDP_COALESCED_INFO` metadata required to split the buffer back into datagrams,
//! turning every packet train into one unusable blob
//! (<https://github.com/quinn-rs/quinn/issues/2041>).
//!
//! Correct coalescing reports the size of the original datagrams as the segment size,
//! so a receive that violates that proves that coalescing on this machine is broken:
//! either a segment is larger than [`MAX_FZ_PAYLOAD`] (no Firezone peer sends a
//! datagram that big) or a receive reported as a single datagram is provably a train
//! of several Firezone datagrams. Once either happens, URO stays off for the
//! remainder of the process.
//!
//! Firezone sockets only ever receive WireGuard messages (direct traffic) and STUN /
//! TURN channel-data messages (relay traffic), all of which leave the datagram
//! boundaries of a merged train recoverable: WireGuard handshake messages have fixed
//! sizes, WireGuard data packets have a recognizable header, and STUN and
//! channel-data messages carry their own length. Where the boundaries can be
//! recovered, the receive is salvaged by reporting the recovered segment size;
//! otherwise it is dropped and the tunneled protocols retransmit.

use std::sync::atomic::{AtomicBool, Ordering};

use ip_packet::{DATA_CHANNEL_OVERHEAD, MAX_FZ_PAYLOAD, WG_OVERHEAD};

static BROKEN: AtomicBool = AtomicBool::new(false);

/// Whether broken coalescing has been observed in this process.
pub(crate) fn is_broken() -> bool {
    BROKEN.load(Ordering::Relaxed)
}

/// Detects receives that prove coalescing on this machine is broken.
///
/// Returns `true` if any of the receives proves broken coalescing, meaning the socket
/// should opt out of URO. Receives whose datagram boundaries can be recovered from
/// the payload are salvaged by rewriting their segment size to the recovered one.
/// The first detection is logged; later ones are silent.
pub(crate) fn detect_broken_coalescing<'a>(
    receives: impl Iterator<Item = (&'a [u8], &'a mut quinn_udp::RecvMeta)>,
) -> bool {
    let mut any_broken = false;

    for (buf, meta) in receives {
        let Some(datagram) = buf.get(..meta.len) else {
            continue;
        };
        let Some(detection) = classify(datagram, meta.stride) else {
            continue;
        };

        any_broken = true;

        if !BROKEN.swap(true, Ordering::Relaxed) {
            tracing::info!(
                stride = %meta.stride,
                len = %meta.len,
                interface_index = ?meta.interface_index,
                reason = ?detection.reason,
                salvaged_segment_size = ?detection.segment_size,
                "Received a datagram that proves broken coalescing; disabling URO"
            );
        }

        if let Some(segment_size) = detection.segment_size {
            meta.stride = segment_size;
        }
    }

    any_broken
}

/// Proof that coalescing on this machine is broken, derived from a single receive.
#[derive(Debug, PartialEq)]
struct Detection {
    reason: Reason,
    /// The segment size recovered from the payload, if the receive is salvageable.
    segment_size: Option<usize>,
}

#[derive(Debug, PartialEq)]
enum Reason {
    OversizedSegment,
    MergedWgHandshakes,
    MergedWgDataPackets,
    MergedStunMessages,
    MergedChannelData,
}

fn classify(datagram: &[u8], stride: usize) -> Option<Detection> {
    // A receive with coalescing metadata (stride < len) is already split correctly;
    // only a receive reported as a single datagram can be an unsplit train.
    if stride == datagram.len()
        && let Some(detection) = detect_merged_datagrams(datagram)
    {
        return Some(detection);
    }

    (stride > MAX_FZ_PAYLOAD).then_some(Detection {
        reason: Reason::OversizedSegment,
        segment_size: None,
    })
}

/// Detects a receive whose payload is a train of several Firezone datagrams.
fn detect_merged_datagrams(datagram: &[u8]) -> Option<Detection> {
    let (reason, segment_size) = wg_handshake_train(datagram)
        .map(|s| (Reason::MergedWgHandshakes, s))
        .or_else(|| wg_data_train(datagram).map(|s| (Reason::MergedWgDataPackets, s)))
        .or_else(|| stun_train(datagram).map(|s| (Reason::MergedStunMessages, s)))
        .or_else(|| channel_data_train(datagram).map(|s| (Reason::MergedChannelData, s)))?;

    Some(Detection {
        reason,
        segment_size: Some(segment_size),
    })
}

/// A train of WireGuard handshake messages: a fixed-size handshake message with more
/// payload after it, every segment starting like a WireGuard message.
fn wg_handshake_train(datagram: &[u8]) -> Option<usize> {
    let segment_size = wg_handshake_size(wg_message_type(datagram)?)?;

    if datagram.len() <= segment_size {
        return None;
    }

    segment_starts(datagram, segment_size)
        .all(|s| wg_message_type(&datagram[s..]).is_some())
        .then_some(segment_size)
}

/// A train of WireGuard data packets: data-packet headers repeating at a fixed
/// distance.
///
/// Unlike the other trains, the segment size is not known up front, so we scan for
/// the second packet's header. The header check is strong enough (see
/// [`starts_wg_data_packet`]) that random ciphertext practically never produces a
/// false boundary.
fn wg_data_train(datagram: &[u8]) -> Option<usize> {
    if !starts_wg_data_packet(datagram) {
        return None;
    }

    let max_segment_size = std::cmp::min(MAX_FZ_PAYLOAD, datagram.len() - MIN_WG_DATA_PACKET);

    if max_segment_size < MIN_WG_DATA_PACKET {
        return None;
    }

    memchr::memchr_iter(4, &datagram[MIN_WG_DATA_PACKET..=max_segment_size])
        .map(|candidate| MIN_WG_DATA_PACKET + candidate)
        .find(|&segment_size| {
            segment_starts(datagram, segment_size).all(|s| starts_wg_data_packet(&datagram[s..]))
        })
}

/// A train of STUN messages: a STUN message with more payload after it.
fn stun_train(datagram: &[u8]) -> Option<usize> {
    message_train(datagram, stun_message_size)
}

/// A train of TURN channel-data messages: a channel-data message with more payload
/// after it.
fn channel_data_train(datagram: &[u8]) -> Option<usize> {
    message_train(datagram, channel_data_message_size)
}

/// A train of self-delimiting messages: the first message's size is the segment size
/// (coalescing only merges equal-sized datagrams; only the last may be shorter) and
/// every further segment is a whole message, either `segment_size` long or closing
/// the train exactly.
fn message_train(datagram: &[u8], message_size: impl Fn(&[u8]) -> Option<usize>) -> Option<usize> {
    let segment_size = message_size(datagram)?;

    if datagram.len() <= segment_size {
        return None;
    }

    segment_starts(datagram, segment_size)
        .all(|s| {
            let Some(size) = message_size(&datagram[s..]) else {
                return false;
            };

            size == segment_size || s + size == datagram.len()
        })
        .then_some(segment_size)
}

/// The start offsets of all segments after the first, splitting `datagram` every
/// `segment_size` bytes.
fn segment_starts(datagram: &[u8], segment_size: usize) -> impl Iterator<Item = usize> {
    (segment_size..datagram.len()).step_by(segment_size)
}

/// The message type of a WireGuard message: the first byte, followed by three
/// reserved zero bytes.
fn wg_message_type(buf: &[u8]) -> Option<u8> {
    match buf {
        [t @ 1..=4, 0, 0, 0, ..] => Some(*t),
        _ => None,
    }
}

/// The fixed wire sizes of the WireGuard handshake messages.
fn wg_handshake_size(message_type: u8) -> Option<usize> {
    match message_type {
        1 => Some(148), // Handshake initiation.
        2 => Some(92),  // Handshake response.
        3 => Some(64),  // Cookie reply.
        _ => None,
    }
}

/// The smallest WireGuard data packet: a 16-byte header plus the AEAD tag of an empty
/// payload, i.e. a keepalive.
const MIN_WG_DATA_PACKET: usize = WG_OVERHEAD;

/// Whether the buffer starts like a WireGuard data packet: the type-4 header and a
/// zero upper half of the little-endian packet counter.
///
/// Sessions rekey long before 2^32 packets, so the upper counter half of a genuine
/// data packet is always zero. Together with the header this makes 8 fixed bytes;
/// without the counter check, random ciphertext would produce a false packet boundary
/// (and thus needlessly disable URO) every few million data packets.
fn starts_wg_data_packet(buf: &[u8]) -> bool {
    if buf.len() < MIN_WG_DATA_PACKET {
        return false;
    }

    buf[..4] == [4, 0, 0, 0] && buf[12..16] == [0, 0, 0, 0]
}

const STUN_MAGIC_COOKIE: [u8; 4] = [0x21, 0x12, 0xA4, 0x42];
const STUN_HEADER_LEN: usize = 20;

/// The wire size of the STUN message at the start of the buffer, if it plausibly is
/// one: zero upper type bits, the magic cookie and an attribute length that is a
/// multiple of four (attributes are padded), bounded by what Firezone peers send.
fn stun_message_size(buf: &[u8]) -> Option<usize> {
    if buf.len() < STUN_HEADER_LEN || buf[0] & 0b1100_0000 != 0 || buf[4..8] != STUN_MAGIC_COOKIE {
        return None;
    }

    let attribute_len = u16::from_be_bytes([buf[2], buf[3]]) as usize;

    if !attribute_len.is_multiple_of(4) {
        return None;
    }

    let size = STUN_HEADER_LEN + attribute_len;

    (size <= MAX_FZ_PAYLOAD).then_some(size)
}

/// The wire size of the TURN channel-data message at the start of the buffer, if it
/// plausibly is one: a channel number in the 0x4000..=0x7FFF range plus the length of
/// the application data it carries, bounded by what Firezone peers send.
fn channel_data_message_size(buf: &[u8]) -> Option<usize> {
    let &[channel, _, l1, l2, ..] = buf else {
        return None;
    };

    if !(0x40..=0x7F).contains(&channel) {
        return None;
    }

    let size = DATA_CHANNEL_OVERHEAD + u16::from_be_bytes([l1, l2]) as usize;

    (size <= MAX_FZ_PAYLOAD).then_some(size)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn single_wg_data_packet_is_not_merged() {
        assert_eq!(classify(&wg_data_packet(1312), 1312), None);
    }

    #[test]
    fn merged_wg_data_packets_are_salvaged() {
        let blob = merged(&[&wg_data_packet(1312), &wg_data_packet(1312)]);

        assert_eq!(
            classify(&blob, blob.len()),
            Some(Detection {
                reason: Reason::MergedWgDataPackets,
                segment_size: Some(1312),
            })
        );
    }

    #[test]
    fn merged_keepalives_are_salvaged() {
        let blob = merged(&[
            &wg_data_packet(32),
            &wg_data_packet(32),
            &wg_data_packet(32),
        ]);

        assert_eq!(
            classify(&blob, blob.len()),
            Some(Detection {
                reason: Reason::MergedWgDataPackets,
                segment_size: Some(32),
            })
        );
    }

    #[test]
    fn fake_boundary_in_ciphertext_does_not_confuse_the_scan() {
        let mut first = wg_data_packet(100);
        first[40..44].copy_from_slice(&[4, 0, 0, 0]);
        first[52..56].copy_from_slice(&[0, 0, 0, 0]);

        let blob = merged(&[&first, &wg_data_packet(100)]);

        assert_eq!(
            classify(&blob, blob.len()),
            Some(Detection {
                reason: Reason::MergedWgDataPackets,
                segment_size: Some(100),
            })
        );
    }

    #[test]
    fn single_wg_handshake_initiation_is_not_merged() {
        assert_eq!(classify(&wg_handshake(1, 148), 148), None);
    }

    #[test]
    fn merged_wg_handshake_initiations_are_salvaged() {
        let blob = merged(&[&wg_handshake(1, 148), &wg_handshake(1, 148)]);

        assert_eq!(
            classify(&blob, blob.len()),
            Some(Detection {
                reason: Reason::MergedWgHandshakes,
                segment_size: Some(148),
            })
        );
    }

    #[test]
    fn wg_handshake_with_trailing_junk_is_not_merged() {
        let blob = merged(&[&wg_handshake(1, 148), &[0xEE; 5]]);

        assert_eq!(classify(&blob, blob.len()), None);
    }

    #[test]
    fn single_stun_message_is_not_merged() {
        let message = stun_message(8);

        assert_eq!(classify(&message, message.len()), None);
    }

    #[test]
    fn merged_stun_messages_are_salvaged() {
        let blob = merged(&[&stun_message(8), &stun_message(8)]);

        assert_eq!(
            classify(&blob, blob.len()),
            Some(Detection {
                reason: Reason::MergedStunMessages,
                segment_size: Some(28),
            })
        );
    }

    #[test]
    fn stun_message_with_unaligned_length_is_not_merged() {
        let mut message = stun_message(8);
        message[3] = 6; // Claim 6 bytes of attributes, leaving 2 trailing bytes.

        assert_eq!(classify(&message, message.len()), None);
    }

    #[test]
    fn merged_channel_data_messages_are_salvaged() {
        let blob = merged(&[&channel_data(50), &channel_data(50)]);

        assert_eq!(
            classify(&blob, blob.len()),
            Some(Detection {
                reason: Reason::MergedChannelData,
                segment_size: Some(54),
            })
        );
    }

    #[test]
    fn channel_data_with_padding_is_not_merged() {
        let blob = merged(&[&channel_data(50), &[0, 0]]);

        assert_eq!(classify(&blob, blob.len()), None);
    }

    #[test]
    fn oversized_junk_is_broken_without_salvage() {
        assert_eq!(
            classify(&vec![0xFF; 2000], 2000),
            Some(Detection {
                reason: Reason::OversizedSegment,
                segment_size: None,
            })
        );
    }

    #[test]
    fn receive_with_coalescing_metadata_is_not_merged() {
        let blob = merged(&[&wg_data_packet(1312), &wg_data_packet(1312)]);

        assert_eq!(classify(&blob, 1312), None);
    }

    #[test]
    fn oversized_segment_with_coalescing_metadata_is_broken_without_salvage() {
        assert_eq!(
            classify(&vec![0xFF; 4000], 2000),
            Some(Detection {
                reason: Reason::OversizedSegment,
                segment_size: None,
            })
        );
    }

    /// The only test that may call [`detect_broken_coalescing`]: it touches the
    /// process-global `BROKEN` flag, so a second such test would race with this one.
    #[test]
    fn detect_flips_the_kill_switch_and_salvages() {
        BROKEN.store(false, Ordering::Relaxed);

        let single = wg_data_packet(1312);
        let mut single_meta = meta(single.len(), single.len());

        assert!(!detect_broken_coalescing(
            [(single.as_slice(), &mut single_meta)].into_iter()
        ));
        assert!(!is_broken());
        assert_eq!(single_meta.stride, 1312);

        let blob = merged(&[&wg_data_packet(1312), &wg_data_packet(1312)]);
        let mut blob_meta = meta(blob.len(), blob.len());

        assert!(detect_broken_coalescing(
            [(blob.as_slice(), &mut blob_meta)].into_iter()
        ));
        assert!(is_broken());
        assert_eq!(blob_meta.stride, 1312);

        BROKEN.store(false, Ordering::Relaxed);
    }

    fn wg_data_packet(len: usize) -> Vec<u8> {
        assert!(len >= MIN_WG_DATA_PACKET);

        let mut packet = vec![0xAA; len];
        packet[..4].copy_from_slice(&[4, 0, 0, 0]);
        packet[8..16].copy_from_slice(&1234u64.to_le_bytes());

        packet
    }

    fn wg_handshake(message_type: u8, len: usize) -> Vec<u8> {
        let mut message = vec![0xCC; len];
        message[..4].copy_from_slice(&[message_type, 0, 0, 0]);

        message
    }

    fn stun_message(attribute_len: u8) -> Vec<u8> {
        let mut message = vec![0xBB; STUN_HEADER_LEN + attribute_len as usize];
        message[..2].copy_from_slice(&[0x00, 0x01]);
        message[2..4].copy_from_slice(&[0x00, attribute_len]);
        message[4..8].copy_from_slice(&STUN_MAGIC_COOKIE);

        message
    }

    fn channel_data(data_len: u8) -> Vec<u8> {
        let mut message = vec![0xDD; DATA_CHANNEL_OVERHEAD + data_len as usize];
        message[..2].copy_from_slice(&[0x40, 0x01]);
        message[2..4].copy_from_slice(&[0x00, data_len]);

        message
    }

    fn merged(datagrams: &[&[u8]]) -> Vec<u8> {
        datagrams.concat()
    }

    fn meta(len: usize, stride: usize) -> quinn_udp::RecvMeta {
        let mut meta = quinn_udp::RecvMeta::default();
        meta.len = len;
        meta.stride = stride;

        meta
    }
}
