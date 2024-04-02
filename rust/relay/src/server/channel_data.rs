use bytes::BufMut;
use std::io;

const HEADER_LEN: usize = 4;

#[derive(Debug, PartialEq, Clone)]
pub struct ChannelData {
    channel: u16,
    length: usize,
    msg: Vec<u8>,
}

impl ChannelData {
    pub fn parse(msg: Vec<u8>) -> Result<Self, io::Error> {
        if msg.len() < HEADER_LEN {
            return Err(io::Error::new(
                io::ErrorKind::UnexpectedEof,
                "channel data messages are at least 4 bytes long",
            ));
        }

        let (header, payload) = msg.split_at(HEADER_LEN);

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
            msg,
            length,
        })
    }

    pub fn channel(&self) -> u16 {
        self.channel
    }

    pub fn data(&self) -> &[u8] {
        let (_, payload) = self.msg.split_at(HEADER_LEN);

        &payload[..self.length]
    }

    pub fn encode_header_to_slice(channel: u16, data_len: u16, mut header: &mut [u8]) -> usize {
        header.put_u16(channel);
        header.put_u16(data_len);

        data_len as usize + HEADER_LEN
    }
}
