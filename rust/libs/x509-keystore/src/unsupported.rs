//! The keystore backend for platforms Firezone has no X.509 client identities on.

use anyhow::Result;

use crate::{ClientIdentity, Config, DetailSection, Identity, Problem, Status, field};

#[expect(
    clippy::unnecessary_wraps,
    reason = "Keep the signature identical to the keystore backends"
)]
pub(crate) fn identity(_config: &Config, _subject_cn: &str) -> Result<Option<Identity>> {
    Ok(None)
}

#[expect(
    clippy::unnecessary_wraps,
    reason = "Keep the signature identical to the keystore backends"
)]
pub(crate) fn status(_config: &Config, _subject_cn: &str) -> Result<Status> {
    Ok(Status {
        problems: vec![Problem::UnsupportedPlatform],
        sections: vec![DetailSection {
            title: "Keystore".to_owned(),
            fields: vec![field("Platform", std::env::consts::OS)],
        }],
        identity: ClientIdentity::Absent,
    })
}
