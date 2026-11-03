const WG_HANDSHAKE_INIT: u32 = 1;
const WG_HANDSHAKE_RESP: u32 = 2;
const WG_COOKIE_REPLY: u32 = 3;
const WG_DATA: u32 = 4;

const WG_HANDSHAKE_INIT_LEN: usize = 148;
const WG_HANDSHAKE_RESP_LEN: usize = 92;
const WG_COOKIE_REPLY_LEN: usize = 64;
const WG_DATA_MIN_LEN: usize = 32;

const STUN_HEADER_LEN: usize = 20;
const STUN_MAGIC_COOKIE: u32 = 0x2112_A442;

/// Whether the relay may forward this payload between a client and a peer.
///
/// We only relay WireGuard messages and STUN messages (used for ICE connectivity checks).
/// The eBPF data path applies the same check in `ebpf-turn-router`.
pub(crate) fn is_relayable(payload: &[u8]) -> bool {
    is_wireguard(payload) || is_stun(payload)
}

fn is_wireguard(payload: &[u8]) -> bool {
    let Some(message_type) = payload.first_chunk::<4>() else {
        return false;
    };

    match (u32::from_le_bytes(*message_type), payload.len()) {
        (WG_HANDSHAKE_INIT, WG_HANDSHAKE_INIT_LEN)
        | (WG_HANDSHAKE_RESP, WG_HANDSHAKE_RESP_LEN)
        | (WG_COOKIE_REPLY, WG_COOKIE_REPLY_LEN) => true,
        (WG_DATA, len) => len >= WG_DATA_MIN_LEN,
        _ => false,
    }
}

fn is_stun(payload: &[u8]) -> bool {
    let Some(header) = payload.first_chunk::<STUN_HEADER_LEN>() else {
        return false;
    };

    let first_two_bits_zero = header[0] & 0b1100_0000 == 0;
    let length = u16::from_be_bytes([header[2], header[3]]) as usize;
    let cookie = u32::from_be_bytes([header[4], header[5], header[6], header[7]]);

    first_two_bits_zero
        && cookie == STUN_MAGIC_COOKIE
        && length.is_multiple_of(4)
        && length == payload.len() - STUN_HEADER_LEN
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn accepts_wireguard_messages() {
        assert!(is_relayable(&wg(WG_HANDSHAKE_INIT, WG_HANDSHAKE_INIT_LEN)));
        assert!(is_relayable(&wg(WG_HANDSHAKE_RESP, WG_HANDSHAKE_RESP_LEN)));
        assert!(is_relayable(&wg(WG_COOKIE_REPLY, WG_COOKIE_REPLY_LEN)));
        assert!(is_relayable(&wg(WG_DATA, WG_DATA_MIN_LEN)));
        assert!(is_relayable(&wg(WG_DATA, 1300)));
    }

    #[test]
    fn rejects_wireguard_messages_with_wrong_length() {
        assert!(!is_relayable(&wg(
            WG_HANDSHAKE_INIT,
            WG_HANDSHAKE_INIT_LEN + 1
        )));
        assert!(!is_relayable(&wg(
            WG_HANDSHAKE_RESP,
            WG_HANDSHAKE_RESP_LEN - 1
        )));
        assert!(!is_relayable(&wg(WG_COOKIE_REPLY, WG_COOKIE_REPLY_LEN + 4)));
        assert!(!is_relayable(&wg(WG_DATA, WG_DATA_MIN_LEN - 1)));
    }

    #[test]
    fn rejects_unknown_wireguard_message_types() {
        assert!(!is_relayable(&wg(0, 64)));
        assert!(!is_relayable(&wg(5, 64)));
        assert!(!is_relayable(&wg(0x0100_0004, 64))); // Reserved bytes are not zero.
    }

    #[test]
    fn accepts_stun_messages() {
        assert!(is_relayable(&stun(0)));
        assert!(is_relayable(&stun(48)));
    }

    #[test]
    fn rejects_malformed_stun_messages() {
        let mut bad_cookie = stun(8);
        bad_cookie[4] = 0;
        assert!(!is_relayable(&bad_cookie));

        let mut bad_type = stun(8);
        bad_type[0] = 0b1000_0000;
        assert!(!is_relayable(&bad_type));

        let mut bad_length = stun(8);
        bad_length[3] = 12;
        assert!(!is_relayable(&bad_length));
    }

    #[test]
    fn rejects_other_payloads() {
        assert!(!is_relayable(&[]));
        assert!(!is_relayable(&[4, 0, 0]));

        // A DNS query for `example.com`.
        assert!(!is_relayable(&[
            0x12, 0x34, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x07, b'e',
            b'x', b'a', b'm', b'p', b'l', b'e', 0x03, b'c', b'o', b'm', 0x00, 0x00, 0x01, 0x00,
            0x01,
        ]));
    }

    fn wg(message_type: u32, len: usize) -> Vec<u8> {
        let mut payload = vec![0xAB; len];
        payload[..4].copy_from_slice(&message_type.to_le_bytes());

        payload
    }

    fn stun(attributes_len: u16) -> Vec<u8> {
        let mut payload = vec![0xAB; STUN_HEADER_LEN + attributes_len as usize];
        payload[..2].copy_from_slice(&0x0001_u16.to_be_bytes()); // Binding request
        payload[2..4].copy_from_slice(&attributes_len.to_be_bytes());
        payload[4..8].copy_from_slice(&STUN_MAGIC_COOKIE.to_be_bytes());

        payload
    }
}
