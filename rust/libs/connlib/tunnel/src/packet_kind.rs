use std::fmt;

#[derive(Debug)]
pub enum Kind {
    Stun,
    Wireguard,
    Unknown,
    StunOverTurn,
    WireguardOverTurn,
    UnknownOverTurn,
}

impl fmt::Display for Kind {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.as_str())
    }
}

impl Kind {
    pub fn as_str(&self) -> &'static str {
        match self {
            Kind::Stun => "stun",
            Kind::Wireguard => "wireguard",
            Kind::Unknown => "unknown",
            Kind::StunOverTurn => "stun-over-turn",
            Kind::WireguardOverTurn => "wireguard-over-turn",
            Kind::UnknownOverTurn => "unknown-over-turn",
        }
    }
}

impl From<Kind> for opentelemetry::Value {
    fn from(val: Kind) -> Self {
        opentelemetry::Value::String(opentelemetry::StringValue::from(val.as_str()))
    }
}

pub fn classify(packet: &[u8]) -> Kind {
    match packet {
        payload if snownet::is_wireguard(payload) => Kind::Wireguard,
        [64..=79, _, _, _, payload @ ..] if snownet::is_wireguard(payload) => {
            Kind::WireguardOverTurn
        }
        [0..=3, ..] => Kind::Stun,
        // Channel-data is a 4-byte header so the actual payload starts on the 5th byte
        [64..=79, _, _, _, 0..=3, ..] => Kind::StunOverTurn,
        [64..=79, _, _, _, ..] => Kind::UnknownOverTurn,
        _ => Kind::Unknown,
    }
}
