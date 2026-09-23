#![cfg(feature = "test-utils")]

use ip_packet::{IpPacketBuf, reset_buffer_pool};

#[test]
fn reset_discards_idle_buffers_and_isolates_outstanding_buffers() {
    let mut outstanding = IpPacketBuf::new();
    outstanding.buf().fill(1);
    let mut idle = IpPacketBuf::new();
    idle.buf().fill(2);
    drop(idle);

    reset_buffer_pool();

    assert!(outstanding.buf().iter().all(|byte| *byte == 1));
    drop(outstanding);
    assert!(IpPacketBuf::new().buf().iter().all(|byte| *byte == 0));
}
