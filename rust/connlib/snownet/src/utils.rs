use std::time::Instant;

pub fn earliest(left: Option<Instant>, right: Option<Instant>) -> Option<Instant> {
    match (left, right) {
        (None, None) => None,
        (Some(left), Some(right)) => Some(std::cmp::min(left, right)),
        (Some(left), None) => Some(left),
        (None, Some(right)) => Some(right),
    }
}

pub fn channel_data_packet_buffer(payload: &[u8]) -> Vec<u8> {
    [&[0u8; 4] as &[u8], payload].concat()
}
