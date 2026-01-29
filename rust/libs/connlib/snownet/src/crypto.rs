use hmac::{Hmac, Mac};
use sha1::Sha1;

use str0m::crypto::Sha1HmacProvider;

type HmacSha1 = Hmac<Sha1>;

pub(crate) static CRYPTO_PROVIDER: RustCryptoSha1HmacProvider = RustCryptoSha1HmacProvider;

#[derive(Debug)]
pub(super) struct RustCryptoSha1HmacProvider;

impl Sha1HmacProvider for RustCryptoSha1HmacProvider {
    fn sha1_hmac(&self, key: &[u8], payloads: &[&[u8]]) -> [u8; 20] {
        let mut mac = HmacSha1::new_from_slice(key).expect("HMAC can take key of any size");

        for payload in payloads {
            mac.update(payload);
        }

        let result = mac.finalize();
        let bytes = result.into_bytes();
        let mut output = [0u8; 20];
        output.copy_from_slice(&bytes);
        output
    }
}
