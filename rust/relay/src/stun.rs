use bytes::{BufMut, Bytes, BytesMut};
use nom::{
    bytes::complete::tag, bytes::complete::take, combinator::map, combinator::verify,
    number::complete::be_u16, sequence::tuple, IResult,
};
use std::net::{Ipv4Addr, Ipv6Addr, SocketAddr};

const MAGIC_COOKIE: u32 = 0x2112A442;
const BINDING_REQUEST_TYPE: u16 = 0x0001;
const BINDING_RESPONSE_TYPE: u16 = 0x0101;
const LEN_TRANSACTION_ID: usize = 12;

const STUN_HEADER_LENGTH: usize = 20;
const XOR_MAPPED_ADDRESS_ATTRIBUTE: u16 = 0x0020;

#[derive(Debug)]
pub struct BindingRequest<'a> {
    pub transaction_id: &'a [u8; LEN_TRANSACTION_ID],
}

/// Parse a [`BindingRequest`] from the given slice of data.
///
/// This is a [`nom`]-based parser, meaning it can "fail" if there isn't yet enough data in the buffer to parse a single message.
/// This parser also operates in a zero-copy fashion. It is up to the caller to correctly advance the buffer once a message has been parsed.
pub fn parse_binding_request(input: &[u8]) -> IResult<&[u8], BindingRequest<'_>> {
    let (remaining_after_header, (_, message_length, _, transaction_id)) = tuple((
        tag(BINDING_REQUEST_TYPE.to_be_bytes()), // TODO: Extend this to support more message types once we also parse TURN messages.
        verify(be_u16, |len| len % 4 == 0),
        tag(MAGIC_COOKIE.to_be_bytes()),
        map(take(LEN_TRANSACTION_ID), |bytes| {
            <&[u8; LEN_TRANSACTION_ID]>::try_from(bytes).expect("we always read 12 bytes")
        }),
    ))(input)?;

    // TODO: Implement support for the following attributes
    // - USERNAME
    // - MESSAGE-INTEGRITY
    let (remaining_after_attributes, _attributes) = take(message_length)(remaining_after_header)?; // read attributes if there are any

    Ok((
        remaining_after_attributes,
        BindingRequest { transaction_id },
    ))
}

/// Generate a STUN Binding Response for the given transaction ID and address.
pub fn write_binding_response(
    transaction_id: &[u8; LEN_TRANSACTION_ID],
    addr: SocketAddr,
) -> Bytes {
    let mut buffer = BytesMut::with_capacity(32);

    buffer.put_u16(BINDING_RESPONSE_TYPE);

    // Placeholder for Message Length (2 bytes), will be updated later
    // TODO: Can we implement this in a nicer way?
    buffer.put_u16(0);

    buffer.put_u32(MAGIC_COOKIE);
    buffer.put_slice(transaction_id);

    // TODO: Create an abstraction once we emit more attributes.
    buffer.put_u16(XOR_MAPPED_ADDRESS_ATTRIBUTE);
    match addr {
        SocketAddr::V4(addr) => {
            buffer.put_u16(8); // Attribute Length
            buffer.put_u8(0); // Reserved
            buffer.put_u8(0x01); // Address Family
            buffer.put_slice(&xor_port(addr.port()).to_be_bytes());
            buffer.put_slice(&xor_ip4(addr.ip()));
        }
        SocketAddr::V6(addr) => {
            buffer.put_u16(20); // Attribute Length
            buffer.put_u8(0); // Reserved
            buffer.put_u8(0x02); // Address Family
            buffer.put_slice(&xor_port(addr.port()).to_be_bytes());
            buffer.put_slice(&xor_ip6(addr.ip(), transaction_id));
        }
    }

    // FIXME: This isn't very clean :(
    let msg_len = (buffer.len() - STUN_HEADER_LENGTH) as u16;
    (&mut buffer[2..4]).put_u16(msg_len);

    buffer.freeze()
}

fn xor_port(port: u16) -> u16 {
    let msb_magic_cookie = (MAGIC_COOKIE >> 16) as u16;

    msb_magic_cookie ^ port
}

fn xor_ip4(ip: &Ipv4Addr) -> [u8; 4] {
    let magic_cookie = MAGIC_COOKIE.to_be_bytes();
    let ip = ip.octets();

    [
        ip[0] ^ magic_cookie[0],
        ip[1] ^ magic_cookie[1],
        ip[2] ^ magic_cookie[2],
        ip[3] ^ magic_cookie[3],
    ]
}

fn xor_ip6(ip: &Ipv6Addr, transaction_id: &[u8; 12]) -> [u8; 16] {
    let magic_cookie = MAGIC_COOKIE.to_be_bytes();
    let ip = ip.octets();

    [
        ip[0] ^ magic_cookie[0],
        ip[1] ^ magic_cookie[1],
        ip[2] ^ magic_cookie[2],
        ip[3] ^ magic_cookie[3],
        ip[4] ^ transaction_id[0],
        ip[5] ^ transaction_id[1],
        ip[6] ^ transaction_id[2],
        ip[7] ^ transaction_id[3],
        ip[8] ^ transaction_id[4],
        ip[9] ^ transaction_id[5],
        ip[10] ^ transaction_id[6],
        ip[11] ^ transaction_id[7],
        ip[12] ^ transaction_id[8],
        ip[13] ^ transaction_id[9],
        ip[14] ^ transaction_id[10],
        ip[15] ^ transaction_id[11],
    ]
}
