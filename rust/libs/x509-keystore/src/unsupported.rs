//! The keystore backend for platforms Firezone has no X.509 client identities on.

use crate::{Error, Loaded};

#[expect(
    clippy::unnecessary_wraps,
    reason = "Keep the signature identical to the keystore backends"
)]
pub(crate) fn load(_subject_cn: &str) -> Result<Loaded, Error> {
    Ok(Loaded::default())
}
