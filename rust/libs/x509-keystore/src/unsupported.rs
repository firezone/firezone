//! The keystore backend for platforms Firezone has no X.509 client identities on.

use anyhow::Result;

use crate::{Identity, Status};

#[expect(
    clippy::unnecessary_wraps,
    reason = "Keep the signature identical to the keystore backends"
)]
pub(crate) fn identity(_subject_cn: &str) -> Result<Option<Identity>> {
    Ok(None)
}

#[expect(
    clippy::unnecessary_wraps,
    reason = "Keep the signature identical to the keystore backends"
)]
pub(crate) fn status(_subject_cn: &str) -> Result<Status> {
    Ok(Status {
        summary: "This platform has no X.509 keystore backend.".to_owned(),
        sections: Vec::new(),
    })
}
