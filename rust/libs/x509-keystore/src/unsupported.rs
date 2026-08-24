//! The keystore backend for platforms Firezone has no X.509 client identities on.

use anyhow::Result;

use crate::{DetailSection, Identity, Status, field};

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
        warning: Some("This platform has no X.509 keystore backend.".to_owned()),
        sections: vec![DetailSection {
            title: "Keystore".to_owned(),
            fields: vec![field("Platform", std::env::consts::OS)],
        }],
    })
}
