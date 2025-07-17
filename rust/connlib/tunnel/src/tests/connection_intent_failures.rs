use std::collections::VecDeque;

use proptest::{collection, prelude::*};

/// The failure-mode of a connection intent sent to the portal.
///
/// TODO: As we extend the test-suite to not just send individual packets but have a
/// simulated networking stack that re-sends packets, we can extend this to also drop
/// entire intents to retry sending them.
#[derive(Debug, Clone, Copy)]
pub(crate) struct ConnectionIntentFailure {
    /// Replace the Client's public key given to the Gateway.
    pub(crate) replace_client_pubkey: Option<[u8; 32]>,
    /// Replace the Gateway's public key given to the Client.
    pub(crate) replace_gateway_pubkey: Option<[u8; 32]>,
}

pub fn connection_intent_failures()
-> impl Strategy<Value = VecDeque<Option<ConnectionIntentFailure>>> {
    collection::vec_deque(
        prop_oneof![
            5 => Just(None),
            1 => connection_intent_failure().prop_map(Some)
        ],
        0..=50,
    )
}

fn connection_intent_failure() -> impl Strategy<Value = ConnectionIntentFailure> {
    (any::<Option<[u8; 32]>>(), any::<Option<[u8; 32]>>()).prop_map(
        |(replace_client_pubkey, replace_gateway_pubkey)| ConnectionIntentFailure {
            replace_client_pubkey,
            replace_gateway_pubkey,
        },
    )
}
