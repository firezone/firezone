use bytes::BufMut;
use std::io;

const HEADER_LEN: usize = 4;

pub struct Packet<'a> {
    channel: u16,
    payload: &'a [u8],
}

impl<'a> Packet<'a> {
    pub(crate) fn channel(&self) -> u16 {
        self.channel
    }

    pub(crate) fn payload(&self) -> &'a [u8] {
        self.payload
    }
}

pub fn decode(data: &[u8]) -> Result<Packet<'_>, io::Error> {
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

    if payload.len() != length {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!(
                "channel data message specified {length} bytes but the payload is {} bytes",
                payload.len()
            ),
        ));
    }

    Ok(Packet {
        channel: channel_number,
        payload,
    })
}

/// Encode the channel data header (number + length) to the given slice.
///
/// Returns the total length of the packet (i.e. the encoded header + data).
pub fn encode_header_to_slice(mut slice: &mut [u8], channel: u16, payload_length: usize) -> usize {
    assert_eq!(slice.len(), HEADER_LEN);

    debug_assert!(channel > 0x400);
    debug_assert!(channel < 0x7FFF);
    debug_assert!(payload_length <= u16::MAX as usize);

    slice.put_u16(channel);
    slice.put_u16(payload_length as u16);

    HEADER_LEN + payload_length
}
