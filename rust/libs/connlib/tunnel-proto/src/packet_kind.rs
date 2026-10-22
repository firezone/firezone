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
    /// All variants, in declaration order.
    pub const ALL: [Kind; 6] = [
        Kind::Stun,
        Kind::Wireguard,
        Kind::Unknown,
        Kind::StunOverTurn,
        Kind::WireguardOverTurn,
        Kind::UnknownOverTurn,
    ];

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
        payload if is_wireguard(payload) => Kind::Wireguard,
        [64..=79, _, _, _, payload @ ..] if is_wireguard(payload) => Kind::WireguardOverTurn,
        [0..=3, ..] => Kind::Stun,
        // Channel-data is a 4-byte header so the actual payload starts on the 5th byte
        [64..=79, _, _, _, 0..=3, ..] => Kind::StunOverTurn,
        [64..=79, _, _, _, ..] => Kind::UnknownOverTurn,
        _ => Kind::Unknown,
    }
}

/// Returns whether `payload` has the type and length of a WireGuard message.
///
/// This does not authenticate the message.
fn is_wireguard(payload: &[u8]) -> bool {
    let Some((ty, _)) = payload.split_first_chunk::<4>() else {
        return false;
    };

    matches!(
        (u32::from_le_bytes(*ty), payload.len()),
        (1, 148) | (2, 92) | (3, 64) | (4, 32..)
    )
}
