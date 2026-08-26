#![no_main]

//! Exercises the relay's STUN & TURN message parsing with arbitrary bytes.
//!
//! `decode` is what the relay calls on every datagram before it looks at any
//! state, so anything reachable here is reachable pre-authentication from the
//! open internet.

use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    let _ = relay_proto::decode(data);
});
