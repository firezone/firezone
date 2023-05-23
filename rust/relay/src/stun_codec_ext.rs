use stun_codec::rfc5389::methods::BINDING;
use stun_codec::rfc5766::methods::{
    ALLOCATE, CHANNEL_BIND, CREATE_PERMISSION, DATA, REFRESH, SEND,
};
use stun_codec::{MessageClass, Method};

pub trait MethodExt {
    fn as_str(&self) -> &'static str;
}

pub trait MessageClassExt {
    fn as_str(&self) -> &'static str;
}

impl MethodExt for Method {
    fn as_str(&self) -> &'static str {
        match *self {
            BINDING => "binding",
            ALLOCATE => "allocate",
            REFRESH => "refresh",
            CHANNEL_BIND => "channel bind",
            CREATE_PERMISSION => "create permission",
            DATA => "data",
            SEND => "send",
            _ => "unknown",
        }
    }
}

impl MessageClassExt for MessageClass {
    fn as_str(&self) -> &'static str {
        match self {
            MessageClass::Request => "request",
            MessageClass::Indication => "indication",
            MessageClass::SuccessResponse => "success response",
            MessageClass::ErrorResponse => "error response",
        }
    }
}
