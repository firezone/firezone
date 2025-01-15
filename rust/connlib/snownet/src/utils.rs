pub fn channel_data_packet_buffer(payload: &[u8]) -> Vec<u8> {
    [&[0u8; 4] as &[u8], payload].concat()
}
