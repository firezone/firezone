//! Implements sending and receiving of DNS messages over TCP.
//!
//! TCP's stream-oriented nature requires us to know how long the encoded DNS message is before we can read it.
//! For this purpose, DNS messages over TCP are prefixed using a big-endian encoded u16.
//!
//! Source: <https://datatracker.ietf.org/doc/html/rfc1035#section-4.2.2>.

use anyhow::{Context as _, Result};

pub fn try_send(socket: &mut l3_tcp::Socket, message: &[u8]) -> Result<()> {
    let dns_message_length = (message.len() as u16).to_be_bytes();

    let written = socket
        .send_slice(&dns_message_length)
        .context("Failed to write TCP DNS length header")?;

    anyhow::ensure!(
        written == 2,
        "Not enough space in write buffer for TCP DNS length header"
    );

    let written = socket
        .send_slice(message)
        .context("Failed to write DNS message")?;

    anyhow::ensure!(
        written == message.len(),
        "Not enough space in write buffer for DNS message"
    );

    // if tracing::event_enabled!(target: "wire::dns::tcp::send", tracing::Level::TRACE) {
    //     if let Some(ParsedMessage {
    //         qid,
    //         qname,
    //         qtype,
    //         response,
    //         rcode,
    //         records,
    //     }) = parse(message)
    //     {
    //         if response {
    //             let records = records.into_iter().join(" | ");
    //             tracing::trace!(target: "wire::dns::tcp::send", %qid, %rcode, "{:5} {qname} => [{records}]", qtype.to_string());
    //         } else {
    //             tracing::trace!(target: "wire::dns::tcp::send", %qid, "{:5} {qname}", qtype.to_string());
    //         }
    //     }
    // }

    Ok(())
}

pub fn try_recv<'b, M>(socket: &'b mut l3_tcp::Socket) -> Result<Option<M>>
where
    M: TryFrom<&'b [u8], Error: std::error::Error + Send + Sync + 'static>,
{
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

            (2 + dns_message_length, Some(M::try_from(message)))
        })
        .context("Failed to recv TCP data")?
        .transpose()
        .context("Failed to parse DNS message")?;

    // if tracing::event_enabled!(target: "wire::dns::tcp::recv", tracing::Level::TRACE) {
    //     if let Some(ParsedMessage {
    //         qid,
    //         qname,
    //         qtype,
    //         rcode,
    //         response,
    //         records,
    //     }) = maybe_message.and_then(parse)
    //     {
    //         if response {
    //             let records = records.into_iter().join(" | ");
    //             tracing::trace!(target: "wire::dns::tcp::recv", %qid, %rcode, "{:5} {qname} => [{records}]", qtype.to_string());
    //         } else {
    //             tracing::trace!(target: "wire::dns::tcp::recv", %qid, "{:5} {qname}", qtype.to_string());
    //         }
    //     }
    // }

    Ok(maybe_message)
}
