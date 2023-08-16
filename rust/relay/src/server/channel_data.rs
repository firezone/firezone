use bytes::{BufMut, BytesMut};
use std::io;

#[derive(Debug, PartialEq)]
pub struct ChannelData<'a> {
    channel: u16,
    data: &'a [u8],
}

impl<'a> ChannelData<'a> {
    pub fn parse(data: &'a [u8]) -> Result<Self, io::Error> {
        if data.len() < 4 {
            return Err(io::Error::new(
                io::ErrorKind::UnexpectedEof,
                "channel data messages are at least 4 bytes long",
            ));
        }

        let channel_number = u16::from_be_bytes([data[0], data[1]]);
        if !(0x4000..=0x7FFF).contains(&channel_number) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "channel number out of bounds",
            ));
        }

        let length = u16::from_be_bytes([data[2], data[3]]);
        let full_msg_length = 4usize + length as usize;

        let actual_payload_length = data.len() - 4;

        if data.len() < full_msg_length {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!(
                    "channel data message specified {length} bytes but the payload is only {actual_payload_length} bytes"
                ),
            ));
        }

        Ok(ChannelData {
            channel: channel_number,
            data: &data[4..full_msg_length],
        })
    }

    pub fn new(channel: u16, data: &'a [u8]) -> Self {
        debug_assert!(channel > 0x400);
        debug_assert!(channel < 0x7FFF);
        ChannelData { channel, data }
    }

    pub fn to_bytes(&self) -> Vec<u8> {
        let mut message = BytesMut::with_capacity(2 + 2 + self.data.len());

        message.put_slice(&self.channel.to_be_bytes());
        message.put_u16(self.data.len() as u16);
        message.put_slice(self.data);

        message.freeze().into()
    }

    pub fn channel(&self) -> u16 {
        self.channel
    }

    pub fn data(&self) -> &[u8] {
        self.data
    }
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
}
