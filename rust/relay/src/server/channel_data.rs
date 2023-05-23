use anyhow::{bail, Result};
use bytes::{BufMut, BytesMut};

pub(crate) struct ChannelData<'a> {
    channel: u16,
    data: &'a [u8],
}

impl<'a> ChannelData<'a> {
    pub(crate) fn parse(data: &'a [u8]) -> Result<Self> {
        if data.len() < 4 {
            bail!("must have at least 4 bytes for channel data message")
        }

        let channel_number = u16::from_be_bytes([data[0], data[1]]);
        let length = u16::from_be_bytes([data[2], data[3]]);

        anyhow::ensure!((data.len() - 4) == length as usize);

        Ok(ChannelData {
            channel: channel_number,
            data: &data[4..],
        })
    }

    pub(crate) fn new(channel: u16, data: &'a [u8]) -> Self {
        ChannelData { channel, data }
    }

    pub(crate) fn to_bytes(&self) -> Vec<u8> {
        let mut message = BytesMut::with_capacity(2 + 2 + self.data.len());

        message.put_u16(self.channel);
        message.put_u16(self.data.len() as u16);
        message.put_slice(self.data);

        message.freeze().into()
    }

    pub(crate) fn channel(&self) -> u16 {
        self.channel
    }

    pub(crate) fn data(&self) -> &[u8] {
        self.data
    }
}

// TODO: tests
