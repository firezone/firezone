//! Prelude for common things like `anyhow::Result`

pub use crate::cli::Cli;
pub use anyhow::{anyhow, bail, Result};
pub use firezone_cli_utils::{block_on_ctrl_c, setup_global_subscriber, CommonArgs};
pub use secrecy::SecretString;
pub use serde::{Deserialize, Serialize};
pub use std::{
    path::{Path, PathBuf},
    time::Duration,
};
pub use url::Url;
