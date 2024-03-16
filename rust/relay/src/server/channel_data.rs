use bytes::{BufMut, BytesMut};
use std::io;

const HEADER_LEN: usize = 4;

#[derive(Debug, PartialEq)]
pub struct ChannelData<'a> {
    channel: u16,
    data: &'a [u8],
}

impl<'a> ChannelData<'a> {
    pub fn parse(data: &'a [u8]) -> Result<Self, io::Error> {
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
                    "channel data message specified {length} bytes but the payload is only {} bytes", payload.len()
                ),
            ));
        }

        Ok(ChannelData {
            channel: channel_number,
            data: &payload[..length],
        })
    }

    pub fn new(channel: u16, data: &'a [u8]) -> Self {
        debug_assert!(channel > 0x400);
        debug_assert!(channel < 0x7FFF);
        debug_assert!(data.len() <= u16::MAX as usize);
        ChannelData { channel, data }
    }

    // Panics if self.data.len() > u16::MAX
    pub fn to_bytes(&self) -> Vec<u8> {
        to_bytes(self.channel, self.data.len() as u16, self.data)
    }

    pub fn channel(&self) -> u16 {
        self.channel
    }

    pub fn data(&self) -> &[u8] {
        self.data
    }
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
        let channel_data = ChannelData::new(channel.value(), &payload);
        let encoded = channel_data.to_bytes();

        let parsed = ChannelData::parse(&encoded).unwrap();

        assert_eq!(channel_data, parsed)
    }

    #[test_strategy::proptest]
    fn channel_data_decoding(
        #[strategy(crate::proptest::channel_number())] channel: ChannelNumber,
        #[strategy(crate::proptest::channel_payload())] payload: (Vec<u8>, u16),
    ) {
        let encoded = to_bytes(channel.value(), payload.1, &payload.0);
        let parsed = ChannelData::parse(&encoded).unwrap();

        assert_eq!(channel.value(), parsed.channel);
        assert_eq!(&payload.0[..(payload.1 as usize)], parsed.data)
    }
}
