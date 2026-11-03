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

/// The number of leading payload bytes [`is_relayable`] inspects.
pub const RELAYABLE_HEADER_LEN: usize = 8;

/// Whether the relay may forward a payload of `len` bytes that starts with `header` between a client and a peer.
///
/// We only relay WireGuard messages and STUN messages (used for ICE connectivity checks).
#[inline(always)]
pub fn is_relayable(header: [u8; RELAYABLE_HEADER_LEN], len: u16) -> bool {
    is_wireguard(header, len) || is_stun(header, len)
}

#[inline(always)]
fn is_wireguard(header: [u8; RELAYABLE_HEADER_LEN], len: u16) -> bool {
    let message_type = u32::from_le_bytes([header[0], header[1], header[2], header[3]]);

    match (message_type, len) {
        (WG_HANDSHAKE_INIT, WG_HANDSHAKE_INIT_LEN)
        | (WG_HANDSHAKE_RESP, WG_HANDSHAKE_RESP_LEN)
        | (WG_COOKIE_REPLY, WG_COOKIE_REPLY_LEN) => true,
        (WG_DATA, len) => len >= WG_DATA_MIN_LEN,
        _ => false,
    }
}

#[inline(always)]
fn is_stun(header: [u8; RELAYABLE_HEADER_LEN], len: u16) -> bool {
    let length = u16::from_be_bytes([header[2], header[3]]);
    let cookie = u32::from_be_bytes([header[4], header[5], header[6], header[7]]);

    header[0] & 0b1100_0000 == 0
        && cookie == STUN_MAGIC_COOKIE
        && length.is_multiple_of(4)
        && len >= STUN_HEADER_LEN
        && length == len - STUN_HEADER_LEN
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn accepts_wireguard_messages() {
        assert!(is_relayable(wg(WG_HANDSHAKE_INIT), WG_HANDSHAKE_INIT_LEN));
        assert!(is_relayable(wg(WG_HANDSHAKE_RESP), WG_HANDSHAKE_RESP_LEN));
        assert!(is_relayable(wg(WG_COOKIE_REPLY), WG_COOKIE_REPLY_LEN));
        assert!(is_relayable(wg(WG_DATA), WG_DATA_MIN_LEN));
        assert!(is_relayable(wg(WG_DATA), 1300));
    }

    #[test]
    fn rejects_wireguard_messages_with_wrong_length() {
        assert!(!is_relayable(
            wg(WG_HANDSHAKE_INIT),
            WG_HANDSHAKE_INIT_LEN + 1
        ));
        assert!(!is_relayable(
            wg(WG_HANDSHAKE_RESP),
            WG_HANDSHAKE_RESP_LEN - 1
        ));
        assert!(!is_relayable(wg(WG_COOKIE_REPLY), WG_COOKIE_REPLY_LEN + 4));
        assert!(!is_relayable(wg(WG_DATA), WG_DATA_MIN_LEN - 1));
    }

    #[test]
    fn rejects_unknown_wireguard_message_types() {
        assert!(!is_relayable(wg(0), 64));
        assert!(!is_relayable(wg(5), 64));
        assert!(!is_relayable(wg(0x0100_0004), 64)); // Reserved bytes are not zero.
    }

    #[test]
    fn accepts_stun_messages() {
        assert!(is_relayable(stun(0), STUN_HEADER_LEN));
        assert!(is_relayable(stun(48), STUN_HEADER_LEN + 48));
    }

    #[test]
    fn rejects_malformed_stun_messages() {
        let mut bad_cookie = stun(8);
        bad_cookie[4] = 0;
        assert!(!is_relayable(bad_cookie, STUN_HEADER_LEN + 8));

        let mut bad_type = stun(8);
        bad_type[0] = 0b1000_0000;
        assert!(!is_relayable(bad_type, STUN_HEADER_LEN + 8));

        assert!(!is_relayable(stun(8), STUN_HEADER_LEN + 12)); // Length does not match.
        assert!(!is_relayable(stun(6), STUN_HEADER_LEN + 6)); // Length is not a multiple of 4.
        assert!(!is_relayable(stun(0), STUN_HEADER_LEN - 1));
    }

    #[test]
    fn rejects_other_payloads() {
        // The first bytes of a 29-byte DNS query for `example.com`.
        assert!(!is_relayable(
            [0x12, 0x34, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00],
            29
        ));
    }

    fn wg(message_type: u32) -> [u8; RELAYABLE_HEADER_LEN] {
        let mut header = [0xAB; RELAYABLE_HEADER_LEN];
        header[..4].copy_from_slice(&message_type.to_le_bytes());

        header
    }

    fn stun(attributes_len: u16) -> [u8; RELAYABLE_HEADER_LEN] {
        let mut header = [0xAB; RELAYABLE_HEADER_LEN];
        header[..2].copy_from_slice(&0x0001_u16.to_be_bytes()); // Binding request
        header[2..4].copy_from_slice(&attributes_len.to_be_bytes());
        header[4..8].copy_from_slice(&STUN_MAGIC_COOKIE.to_be_bytes());

        header
    }
}
