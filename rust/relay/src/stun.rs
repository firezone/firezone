use nom::{
    bytes::complete::tag, bytes::complete::take, combinator::map, combinator::verify,
    number::complete::be_u16, sequence::tuple, IResult,
};

const MAGIC_COOKIE: [u8; 4] = [0x21, 0x12, 0xA4, 0x42];
const BINDING_REQUEST_TYPE: [u8; 2] = [0x01, 0x01];
const LEN_TRANSACTION_ID: usize = 12;

#[derive(Debug)]
pub struct BindingRequest<'a> {
    pub transaction_id: &'a [u8; LEN_TRANSACTION_ID],
}

pub fn parse_binding_request(input: &[u8]) -> IResult<&[u8], BindingRequest<'_>> {
    let (input, (_, message_length, _, transaction_id)) = tuple((
        tag(BINDING_REQUEST_TYPE), // we only support parsing BindingRequest messages
        verify(be_u16, |len| len % 4 == 0),
        tag(MAGIC_COOKIE),
        map(take(LEN_TRANSACTION_ID), |bytes| {
            <&[u8; LEN_TRANSACTION_ID]>::try_from(bytes).expect("we always read 12 bytes")
        }),
    ))(input)?;

    let _attributes = take(message_length)(input)?; // read attributes if there are any

    Ok((input, BindingRequest { transaction_id }))
}
