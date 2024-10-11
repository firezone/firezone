//! Implements sending and receiving of DNS messages over TCP.
//!
//! TCP's stream-oriented nature requires us to know how long the encoded DNS message is before we can read it.
//! For this purpose, DNS messages over TCP are prefixed using a big-endian encoded u16.
//!
//! Source: <https://datatracker.ietf.org/doc/html/rfc1035#section-4.2.2>.

use anyhow::{Context as _, Result};
use domain::base::Message;
use smoltcp::socket::tcp;

pub fn try_send(socket: &mut tcp::Socket, message: Message<&[u8]>) -> Result<()> {
    let response = message.as_slice();

    let dns_message_length = (response.len() as u16).to_be_bytes();

    let written = socket
        .send_slice(&dns_message_length)
        .context("Failed to write TCP DNS length header")?;

    anyhow::ensure!(
        written == 2,
        "Not enough space in write buffer for TCP DNS length header"
    );

    let written = socket
        .send_slice(response)
        .context("Failed to write DNS message")?;

    anyhow::ensure!(
        written == response.len(),
        "Not enough space in write buffer for DNS message"
    );

    Ok(())
}

pub fn try_recv<'b>(socket: &'b mut tcp::Socket) -> Result<Option<Message<&'b [u8]>>> {
    let maybe_message = socket
        .recv(|r| {
            // DNS over TCP has a 2-byte length prefix at the start, see <https://datatracker.ietf.org/doc/html/rfc1035#section-4.2.2>.
            let Some((header, message)) = r.split_first_chunk::<2>() else {
                return (0, None);
            };
            let dns_message_length = u16::from_be_bytes(*header) as usize;
            if message.len() < dns_message_length {
                return (0, None); // Don't consume any bytes unless we can read the full message at once.
            }

            (2 + dns_message_length, Some(Message::from_octets(message)))
        })
        .context("Failed to recv TCP data")?
        .transpose()
        .context("Failed to parse DNS message")?;

    Ok(maybe_message)
}
