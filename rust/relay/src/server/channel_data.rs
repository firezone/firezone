use anyhow::{bail, Result};
use bytes::{BufMut, BytesMut};

pub(crate) fn make(channel: u16, data: &[u8]) -> Vec<u8> {
    let mut message = BytesMut::with_capacity(2 + 2 + data.len());

    message.put_u16(channel);
    message.put_u16(data.len() as u16);
    message.put_slice(data);

    message.freeze().to_vec()
}

pub(crate) fn parse(data: &[u8]) -> Result<(u16, &[u8])> {
    if data.len() < 4 {
        bail!("must have at least 4 bytes for channel data message")
    }

    let channel_number = u16::from_be_bytes([data[0], data[1]]);
    let length = u16::from_be_bytes([data[2], data[3]]);

    anyhow::ensure!((data.len() - 4) == length as usize);

    Ok((channel_number, &data[4..]))
}

// TODO: tests
