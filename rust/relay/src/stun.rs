use bytes::{BufMut, BytesMut};
use nom::{
    bytes::complete::tag, bytes::complete::take, combinator::map, combinator::verify,
    number::complete::be_u16, sequence::tuple, IResult,
};
use std::net::{Ipv4Addr, Ipv6Addr, SocketAddr};

const MAGIC_COOKIE: u32 = 0x2112A442;
const BINDING_REQUEST_TYPE: [u8; 2] = [0x01, 0x01];
const BINDING_RESPONSE_TYPE: [u8; 2] = [0x01, 0x02];
const LEN_TRANSACTION_ID: usize = 12;

const XOR_MAPPED_ADDRESS_ATTRIBUTE: [u8; 2] = [0x00, 0x20];

#[derive(Debug)]
pub struct BindingRequest<'a> {
    pub transaction_id: &'a [u8; LEN_TRANSACTION_ID],
}

pub fn parse_binding_request(input: &[u8]) -> IResult<&[u8], BindingRequest<'_>> {
    let (input, (_, message_length, _, transaction_id)) = tuple((
        tag(BINDING_REQUEST_TYPE), // we only support parsing BindingRequest messages
        verify(be_u16, |len| len % 4 == 0),
        tag(MAGIC_COOKIE.to_be_bytes()),
        map(take(LEN_TRANSACTION_ID), |bytes| {
            <&[u8; LEN_TRANSACTION_ID]>::try_from(bytes).expect("we always read 12 bytes")
        }),
    ))(input)?;

    let _attributes = take(message_length)(input)?; // read attributes if there are any

    Ok((input, BindingRequest { transaction_id }))
}

pub fn write_binding_response(
    transaction_id: &[u8; LEN_TRANSACTION_ID],
    addr: SocketAddr,
) -> Vec<u8> {
    let mut buffer = BytesMut::with_capacity(32);

    buffer.put_slice(&BINDING_RESPONSE_TYPE);

    // Placeholder for Message Length (2 bytes), will be updated later
    // TODO: Can we implement this in a nicer way?
    buffer.put_u16(0);

    buffer.put_u32(MAGIC_COOKIE);
    buffer.put_slice(transaction_id);

    buffer.put_slice(&XOR_MAPPED_ADDRESS_ATTRIBUTE);
    match addr {
        SocketAddr::V4(addr) => {
            buffer.put_u16(8); // Attribute Length
            buffer.put_u8(0); // Reserved
            buffer.put_u8(0x01); // Address Family
            buffer.put_u16(xor_port(addr.port()));
            buffer.put_slice(&xor_ip4(addr.ip()));
        }
        SocketAddr::V6(addr) => {
            buffer.put_u16(16); // Attribute Length
            buffer.put_u8(0); // Reserved
            buffer.put_u8(0x02); // Address Family
            buffer.put_u16(xor_port(addr.port()));
            buffer.put_slice(&xor_ip6(addr.ip(), transaction_id));
        }
    }

    // Update Message Length
    let msg_len = (buffer.len() - 20) as u16;
    buffer[2..4].copy_from_slice(&msg_len.to_be_bytes());

    buffer.to_vec()
}

fn xor_port(port: u16) -> u16 {
    let msb_magic_cookie = MAGIC_COOKIE >> 16;

    port ^ ((msb_magic_cookie) as u16)
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
