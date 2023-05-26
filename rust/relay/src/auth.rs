use std::time::Instant;
use stun_codec::rfc5389::attributes::MessageIntegrity;

pub trait MessageIntegrityExt {
    fn verify(&self, relay_secret: &[u8], now: Instant) -> Result<(), Error>;
}

impl MessageIntegrityExt for MessageIntegrity {
    fn verify(&self, relay_secret: &[u8], now: Instant) -> Result<(), Error> {
        // 1. Extract username and split into expiry and username.
        // 2. Verify username not expired
        // 3. Compute password based on relay secret
        // 4. Verify message integrity

        todo!()
    }
}

pub enum Error {
    Expired,
    InvalidPassword,
    InvalidUsername,
}

fn generate_password(relay_secret: &[u8], expiry: Instant, username_salt: &str) -> Vec<u8> {}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Attribute;
    use stun_codec::rfc5389::attributes::{Realm, Username};
    use stun_codec::rfc5389::methods::BINDING;
    use stun_codec::{Message, MessageClass, TransactionId};

    #[test]
    fn smoke() {
        let username = Username::new("test".to_owned()).unwrap();
        let realm = Realm::new("firezone".to_owned()).unwrap();

        let mut message = sample_message();
        MessageIntegrity::new_long_term_credential(&message, &username, &realm, "")
    }

    fn sample_message() -> Message<Attribute> {
        Message::new(
            MessageClass::Request,
            BINDING,
            TransactionId::new([0u8; 12]),
        )
    }
}
