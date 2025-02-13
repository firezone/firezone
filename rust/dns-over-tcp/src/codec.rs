//! Implements sending and receiving of DNS messages over TCP.
//!
//! TCP's stream-oriented nature requires us to know how long the encoded DNS message is before we can read it.
//! For this purpose, DNS messages over TCP are prefixed using a big-endian encoded u16.
//!
//! Source: <https://datatracker.ietf.org/doc/html/rfc1035#section-4.2.2>.

use anyhow::{Context as _, Result};
use domain::{
    base::{iana::Rcode, Message, ParsedName, Rtype},
    rdata::AllRecordData,
};
use itertools::Itertools as _;
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

    if tracing::event_enabled!(target: "wire::dns::tcp::send", tracing::Level::TRACE) {
        if let Some(ParsedMessage {
            qid,
            qname,
            qtype,
            response,
            rcode,
            records,
        }) = parse(message)
        {
            if response {
                let records = records.into_iter().join(" | ");
                tracing::trace!(target: "wire::dns::tcp::send", %qid, %rcode, "{:5} {qname} => [{records}]", qtype.to_string());
            } else {
                tracing::trace!(target: "wire::dns::tcp::send", %qid, "{:5} {qname}", qtype.to_string());
            }
        }
    }

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

    if tracing::event_enabled!(target: "wire::dns::tcp::recv", tracing::Level::TRACE) {
        if let Some(ParsedMessage {
            qid,
            qname,
            qtype,
            rcode,
            response,
            records,
        }) = maybe_message.and_then(parse)
        {
            if response {
                let records = records.into_iter().join(" | ");
                tracing::trace!(target: "wire::dns::tcp::recv", %qid, %rcode, "{:5} {qname} => [{records}]", qtype.to_string());
            } else {
                tracing::trace!(target: "wire::dns::tcp::recv", %qid, "{:5} {qname}", qtype.to_string());
            }
        }
    }

    Ok(maybe_message)
}

fn parse(message: Message<&[u8]>) -> Option<ParsedMessage<'_>> {
    let question = message.sole_question().ok()?;
    let answers = message.answer().ok()?;

    let qtype = question.qtype();
    let qname = question.into_qname();
    let qid = message.header().id();
    let response = message.header().qr();
    let rcode = message.header().rcode();
    let records = answers
        .into_iter()
        .filter_map(|r| {
            let data = r
                .ok()?
                .into_any_record::<AllRecordData<_, _>>()
                .ok()?
                .data()
                .clone();

            Some(data)
        })
        .collect();

    Some(ParsedMessage {
        qid,
        qname,
        rcode,
        qtype,
        response,
        records,
    })
}

struct ParsedMessage<'a> {
    qid: u16,
    qname: ParsedName<&'a [u8]>,
    qtype: Rtype,
    rcode: Rcode,
    response: bool,
    records: Vec<AllRecordData<&'a [u8], ParsedName<&'a [u8]>>>,
}
