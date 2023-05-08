use nom::{
    branch::alt, bytes::complete::tag, bytes::complete::take, combinator::map, combinator::verify,
    number::complete::be_u16, sequence::tuple, IResult,
};

const MAGIC_COOKIE: [u8; 4] = [0x21, 0x12, 0xA4, 0x42];

#[derive(Debug, PartialEq)]
pub struct Message<'a> {
    message_type: MessageType,
    transaction_id: &'a [u8],
}

impl<'a> Message<'a> {
    pub fn message_type(&self) -> &MessageType {
        &self.message_type
    }

    pub fn transaction_id(&self) -> &'a [u8] {
        self.transaction_id
    }
}

#[derive(Debug, PartialEq)]
pub enum MessageType {
    BindingRequest,
    BindingResponse,
    BindingErrorResponse,
}

pub fn parse(input: &[u8]) -> IResult<&[u8], Message<'_>> {
    let (input, (message_type, _message_length, _, transaction_id)) = tuple((
        alt((
            map(tag([0x01, 0x01]), |_| MessageType::BindingRequest),
            map(tag([0x01, 0x02]), |_| MessageType::BindingResponse),
            map(tag([0x01, 0x11]), |_| MessageType::BindingErrorResponse),
        )),
        verify(be_u16, |len| len % 4 == 0),
        tag(MAGIC_COOKIE),
        take(12usize),
    ))(input)?;

    Ok((
        input,
        Message {
            message_type,
            transaction_id,
        },
    ))
}
