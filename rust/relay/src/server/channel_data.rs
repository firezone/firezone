use bytes::{BufMut, BytesMut};
use std::io;

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
        let length = u16::from_be_bytes([data[2], data[3]]);

        let actual_payload_length = data.len() - 4;

        if actual_payload_length != length as usize {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!(
                    "channel data message specified {length} bytes but got {actual_payload_length}"
                ),
            ));
        }

        Ok(ChannelData {
            channel: channel_number,
            data: &data[4..],
        })
    }

    pub fn new(channel: u16, data: &'a [u8]) -> Self {
        ChannelData { channel, data }
    }

    pub fn to_bytes(&self) -> Vec<u8> {
        let mut message = BytesMut::with_capacity(2 + 2 + self.data.len());

        message.put_u16(self.channel);
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

// TODO: tests
