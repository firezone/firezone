//! The keystore backend for platforms Firezone has no X.509 client identities on.

use crate::{Error, Identity};

#[expect(
    clippy::unnecessary_wraps,
    reason = "Keep the signature identical to the keystore backends"
)]
pub(crate) fn identity(_subject_cn: &str) -> Result<Option<Identity>, Error> {
    Ok(None)
}
