//! CLI subcommands used to test features / dependencies before integrating
//! them with the GUI, or to exercise features programmatically.

use anyhow::Result;

#[derive(clap::Subcommand)]
pub enum Cmd {}

pub fn run(cmd: Cmd) -> Result<()> {
    match cmd {}
}
