use proptest::arbitrary::any;
use proptest::strategy::Strategy;
use stun_codec::TransactionId;
use crate::server::

pub fn transaction_id() -> impl Strategy<Value = TransactionId> {
    any::<[u8; 12]>().prop_map(|bytes| TransactionId::new(bytes))
}

pub fn binding() -> impl Strategy<Value = Binding> {
    transaction_id().prop_map(|id| Binding::new(id))
}
