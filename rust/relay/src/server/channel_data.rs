use bytes::{BufMut, BytesMut};
use std::io;

const HEADER_LEN: usize = 4;

pub fn decode(data: &[u8]) -> Result<(u16, &[u8]), io::Error> {
    if data.len() < HEADER_LEN {
        return Err(io::Error::new(
            io::ErrorKind::UnexpectedEof,
            "channel data messages are at least 4 bytes long",
        ));
    }

    let (header, payload) = data.split_at(HEADER_LEN);

    let channel_number = u16::from_be_bytes([header[0], header[1]]);
    if !(0x4000..=0x7FFF).contains(&channel_number) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "channel number out of bounds",
        ));
    }

    let length = u16::from_be_bytes([header[2], header[3]]) as usize;

    if payload.len() < length {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!(
                "channel data message specified {length} bytes but the payload is only {} bytes",
                payload.len()
            ),
        ));
    }

    Ok((channel_number, &payload[..length]))
}

pub fn encode(channel: u16, data: &[u8]) -> Vec<u8> {
    debug_assert!(channel > 0x400);
    debug_assert!(channel < 0x7FFF);
    debug_assert!(data.len() <= u16::MAX as usize);

    to_bytes(channel, data.len() as u16, data)
}

fn to_bytes(channel: u16, len: u16, payload: &[u8]) -> Vec<u8> {
    let mut message = BytesMut::with_capacity(HEADER_LEN + (len as usize));

    message.put_u16(channel);
    message.put_u16(len);
    message.put_slice(payload);

    message.freeze().into()
}

#[cfg(all(test, feature = "proptest"))]
mod tests {
    use super::*;
    use stun_codec::rfc5766::attributes::ChannelNumber;

    #[test_strategy::proptest]
    fn channel_data_encoding_roundtrip(
        #[strategy(crate::proptest::channel_number())] channel: ChannelNumber,
        payload: Vec<u8>,
    ) {
        let encoded = encode(channel.value(), &payload);

        let (decoded_number, decoded_payload) = decode(&encoded).unwrap();

        assert_eq!(decoded_number, channel.value());
        assert_eq!(decoded_payload, payload);
    }

    #[test_strategy::proptest]
    fn channel_data_decoding(
        #[strategy(crate::proptest::channel_number())] channel: ChannelNumber,
        #[strategy(crate::proptest::channel_payload())] payload: (Vec<u8>, usize),
    ) {
        let encoded = to_bytes(channel.value(), payload.1 as u16, &payload.0);
        let (decoded_number, decoded_payload) = decode(&encoded).unwrap();

        assert_eq!(channel.value(), decoded_number);
        assert_eq!(&payload.0[..payload.1], decoded_payload)
    }
}
