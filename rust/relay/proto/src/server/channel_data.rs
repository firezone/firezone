use std::io;
use stun_codec::rfc5766::attributes::ChannelNumber;

const HEADER_LEN: usize = 4;

#[derive(Debug, PartialEq, Clone)]
pub struct ChannelData<'a> {
    channel: ChannelNumber,
    length: usize,
    msg: &'a [u8],
}

impl<'a> ChannelData<'a> {
    pub fn parse(msg: &'a [u8]) -> Result<Self, io::Error> {
        if msg.len() < HEADER_LEN {
            return Err(io::Error::new(
                io::ErrorKind::UnexpectedEof,
                "channel data messages are at least 4 bytes long",
            ));
        }

        let (header, payload) = msg.split_at(HEADER_LEN);

        let channel_number = u16::from_be_bytes([header[0], header[1]]);
        let channel_number = match ChannelNumber::new(channel_number) {
            Ok(c) => c,
            Err(e) => return Err(io::Error::new(io::ErrorKind::InvalidInput, e)),
        };

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

        Ok(ChannelData {
            channel: channel_number,
            msg,
            length,
        })
    }

    pub fn channel(&self) -> ChannelNumber {
        self.channel
    }

    pub fn data(&self) -> &'a [u8] {
        let (_, payload) = self.msg.split_at(HEADER_LEN);

        &payload[..self.length]
    }

    pub fn as_msg(&self) -> &'a [u8] {
        self.msg
    }

    pub fn encode_header_to_slice(
        channel: ChannelNumber,
        data_len: u16,
        header: &mut [u8],
    ) -> usize {
        let [c1, c2] = channel.value().to_be_bytes();
        let [l1, l2] = data_len.to_be_bytes();

        header[0] = c1;
        header[1] = c2;
        header[2] = l1;
        header[3] = l2;

        data_len as usize + HEADER_LEN
    }
}

#[cfg(all(test, feature = "proptest"))]
mod tests {
    use super::*;

    #[test_strategy::proptest]
    fn can_reparse_encoded_header(
        #[strategy(crate::proptest::channel_number())] channel: ChannelNumber,
        payload: Vec<u8>,
    ) {
        let mut msg = vec![0; payload.len() + 4];
        msg[4..].copy_from_slice(&payload);

        ChannelData::encode_header_to_slice(channel, payload.len() as u16, &mut msg[..4]);

        let parsed = ChannelData::parse(&msg).unwrap();

        assert_eq!(parsed.data(), payload);
        assert_eq!(parsed.channel(), channel);
    }
}
